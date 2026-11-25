#!/usr/bin/env bash
# Proves the security properties and the two agent paths end to end. Reads .env from scripts/deploy.sh.
#   ./scripts/test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Run ./scripts/deploy.sh first (it writes .env)." >&2; exit 1; }
set -a; source .env; set +a

PASS=0; FAILED=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (expected $3, got $2)"; FAILED=$((FAILED+1)); fi; }
status() { curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$@"; }

CHAT="$AI_GATEWAY_URL/default/models/openai/v1/chat/completions"
BODY="{\"model\":\"$AI_GATEWAY_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word: ok\"}]}"

echo "== Gateway: who can call it"
if [[ "$INBOUND_MODE" == "hybrid" ]]; then
  check "no token is rejected" "$(status -X POST "$CHAT" -H 'Content-Type: application/json' -d "$BODY")" 401
  WRONG="$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)"
  check "a token for another audience is rejected" \
    "$(status -X POST "$CHAT" -H "Authorization: Bearer $WRONG" -H 'Content-Type: application/json' -d "$BODY")" 401
  TOKEN="$(az account get-access-token --scope https://ai.gateway.azure.com/.default --query accessToken -o tsv)"
  check "your Entra token is accepted (teams/support-desk.json grants you chat)" \
    "$(status -X POST "$CHAT" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$BODY")" 200
  if [[ -n "${AI_GATEWAY_MCP_URL:-}" ]]; then
    INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
    check "your token is denied the orders tools (support-desk has no tools)" \
      "$(status -X POST "$AI_GATEWAY_MCP_URL" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' -d "$INIT")" 403
  fi
else
  # Run from outside the VNet: the public endpoint answers 403. From inside, the host resolves to the private endpoint.
  check "public endpoint is off (private mode)" \
    "$(status -X POST "$CHAT" -H 'Content-Type: application/json' -d "$BODY")" 403
fi

echo "== Backends: not reachable from the internet"
FTOKEN="$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)"
check "Foundry model account blocks public access" \
  "$(status "${FOUNDRY_MODELS_ENDPOINT%/}/openai/v1/models" -H "Authorization: Bearer $FTOKEN")" 403
MCP_HOST="$(sed -E 's#https://([^/]+).*#\1#' <<<"$MCP_SERVER_PRIVATE_URL")"
resolves="$(python3 -c "import socket,sys
try: socket.gethostbyname(sys.argv[1]); print('yes')
except OSError: print('no')" "$MCP_HOST")"
check "private MCP server has no public DNS name" "$resolves" no

echo "== Gateway: compliance check (scripts/check_gateway.py)"
EXPECT=""; [[ "$INBOUND_MODE" == "private" ]] && EXPECT="--expect-private"
if python3 scripts/check_gateway.py "$AI_GATEWAY_ID" $EXPECT; then check "gateway passes the compliance check" ok ok
else check "gateway passes the compliance check" failed ok; fi

echo "== ACA agent (Agent Framework): job -> agent -> gateway -> Foundry + private MCP server"
EXEC="$(az containerapp job start -n "$AGENT_SMOKE_JOB" -g "$AZURE_RESOURCE_GROUP" --query name -o tsv)"
for _ in $(seq 1 40); do
  state="$(az containerapp job execution show -n "$AGENT_SMOKE_JOB" -g "$AZURE_RESOURCE_GROUP" \
    --job-execution-name "$EXEC" --query properties.status -o tsv)"
  [[ "$state" == "Running" || "$state" == "Processing" ]] || break
  sleep 10
done
az containerapp job logs show -n "$AGENT_SMOKE_JOB" -g "$AZURE_RESOURCE_GROUP" --execution "$EXEC" \
  --container smoke --format text 2>/dev/null | grep -E "^(Q|A):" | sed 's/^/    /'
check "smoke job succeeded" "$state" Succeeded

echo "== Foundry agent: prompt agent -> project connection -> gateway"
if [[ "$INBOUND_MODE" == "private" ]]; then
  echo "  SKIP  Foundry Agent Service can't reach a gateway with public access off (see README, Inbound modes)"
elif python3 -c "import azure.ai.projects" 2>/dev/null; then
  if python3 clients/foundry-agent/agent.py "Reply with one word: ok"; then check "Foundry agent answered" ok ok
  else check "Foundry agent answered" failed ok; fi
else
  echo "  SKIP  pip install -r clients/foundry-agent/requirements.txt to run this check"
fi

echo; echo "$PASS passed, $FAILED failed"
[[ "$FAILED" == 0 ]]
