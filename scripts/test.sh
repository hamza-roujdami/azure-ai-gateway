#!/usr/bin/env bash
# Proves the access model and every workload end to end. Reads .env from scripts/deploy.sh.
#   ./scripts/test.sh
# You are platform:deployer in the team files: support-desk and coding-agents grant you the chat model and the
# shipping tools, and nothing else. Run it as the identity that deployed. Role changes take several minutes to apply.
set -uo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Run ./scripts/deploy.sh first (it writes .env)." >&2; exit 1; }
set -a; source .env; set +a
PY="$(command -v python3)"
# In the deploy pipeline the caller is a service principal, not the developer that the team files grant access to.
AS_DEVELOPER=true
[[ "$(az account show --query user.type -o tsv)" == "user" ]] || AS_DEVELOPER=false

PASS=0; FAILED=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (expected $3, got $2)"; FAILED=$((FAILED+1)); fi; }
skip() { echo "  SKIP  $1"; }
status() { curl -s -o /dev/null -w '%{http_code}' --max-time 90 "$@"; }
mcp_status() {  # HTTP status of an MCP initialize call to one of the gateway's MCP servers
  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
  status -X POST "$AI_GATEWAY_URL/default/toolservers/$1/mcp" -H "Authorization: Bearer $2" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$init"
}

CHAT="$AI_GATEWAY_URL/default/models/openai/v1/chat/completions"
BODY="{\"model\":\"$AI_GATEWAY_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word: ok\"}]}"

echo "== Gateway: who can call what"
if [[ "$INBOUND_MODE" == "hybrid" ]]; then
  check "no token is rejected" "$(status -X POST "$CHAT" -H 'Content-Type: application/json' -d "$BODY")" 401
  WRONG="$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)"
  check "a token for another audience is rejected" \
    "$(status -X POST "$CHAT" -H "Authorization: Bearer $WRONG" -H 'Content-Type: application/json' -d "$BODY")" 401
  if [[ "$AS_DEVELOPER" == true ]]; then
    TOKEN="$(az account get-access-token --scope https://ai.gateway.azure.com/.default --query accessToken -o tsv)"
    check "you can call the chat model" \
      "$(status -X POST "$CHAT" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$BODY")" 200
    check "you can use the shipping tools (coding-agents)" "$(mcp_status shipping "$TOKEN")" 200
    check "you're denied the orders tools (no team grants them to you)" "$(mcp_status orders "$TOKEN")" 403
    check "you're denied the returns specialist" "$(mcp_status returns "$TOKEN")" 403
  else
    TOKEN="$(az account get-access-token --scope https://ai.gateway.azure.com/.default --query accessToken -o tsv)"
    check "the pipeline's identity has no runtime access" \
      "$(status -X POST "$CHAT" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$BODY")" 403
  fi
else
  # Run from outside the VNet: the public endpoint answers 403. From inside, the host resolves to the private endpoint.
  check "public endpoint is off (private mode)" \
    "$(status -X POST "$CHAT" -H 'Content-Type: application/json' -d "$BODY")" 403
fi

echo "== Backends: not reachable from the internet"
FTOKEN="$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)"
code="$(status "${FOUNDRY_MODELS_ENDPOINT%/}/openai/v1/models" -H "Authorization: Bearer $FTOKEN")"
[[ "$code" == 401 || "$code" == 403 ]] && code=rejected  # public access off: no model call from outside the VNet
check "Foundry model account rejects public calls" "$code" rejected
MCP_HOST="$(sed -E 's#https://([^/]+).*#\1#' <<<"$MCP_SERVER_PRIVATE_URL")"
resolves="$("$PY" -c "import socket,sys
try: socket.gethostbyname(sys.argv[1]); print('yes')
except OSError: print('no')" "$MCP_HOST")"
check "private MCP server has no public DNS name" "$resolves" no

echo "== Gateway: compliance check (scripts/check_gateway.py)"
EXPECT=""; [[ "$INBOUND_MODE" == "private" ]] && EXPECT="--expect-private"
if "$PY" scripts/check_gateway.py "$AI_GATEWAY_ID" $EXPECT; then check "gateway passes the compliance check" ok ok
else check "gateway passes the compliance check" failed ok; fi

echo "== AI app (support desk): one model call, signed in as you"
if [[ "$INBOUND_MODE" != "hybrid" || "$AS_DEVELOPER" != true ]]; then skip "runs from your machine, as the developer"
elif "$PY" -c "import openai, azure.identity" 2>/dev/null; then
  if answer="$("$PY" clients/support-desk/summarize.py)"; then
    echo "$answer" | sed 's/^/    /'; check "support desk summarized a ticket" ok ok
  else check "support desk summarized a ticket" failed ok; fi
else skip "pip install -r clients/support-desk/requirements.txt to run this check"; fi

echo "== AI agent (order assistant): job -> agent -> gateway -> model, orders, shipping and the returns agent"
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

echo "== Coding agent: GitHub Copilot CLI on the gateway's model and shipping tools, signed in as you"
if [[ "$INBOUND_MODE" != "hybrid" || "$AS_DEVELOPER" != true ]]; then skip "runs from your machine, as the developer"
elif command -v copilot >/dev/null; then
  PROMPT="Use the shipping tools to get an express quote for SKU WIDGET-42 to Norway. Reply with the carrier and business days only."
  if out="$(./scripts/copilot-with-gateway.sh shipping -- -p "$PROMPT" --allow-all-tools --no-color 2>&1)" &&
     grep -qi "DHL" <<<"$out"; then
    grep -v '^\s*$' <<<"$out" | tail -3 | sed 's/^/    /'; check "Copilot answered from the shipping tools" ok ok
  else
    tail -5 <<<"$out" | sed 's/^/    /'; check "Copilot answered from the shipping tools" failed ok
  fi
else skip "install GitHub Copilot CLI to run this check"; fi

echo "== Foundry agent: prompt agent -> project connection -> gateway"
if [[ "$INBOUND_MODE" == "private" ]]; then
  skip "Foundry Agent Service can't reach a gateway with public access off (see README, Inbound modes)"
elif [[ "$AS_DEVELOPER" != true ]]; then
  skip "creating a prompt agent needs the developer's Foundry access"
elif "$PY" -c "import azure.ai.projects" 2>/dev/null; then
  out="$("$PY" clients/foundry-agent/agent.py "Reply with one word: ok" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]] && grep -q UNEXPECTED_EOF <<<"$out"; then
    echo "    TLS 1.3 handshake dropped (OpenSSL 3.5+ key share): retrying with clients/foundry-agent/openssl-classic.cnf"
    out="$(OPENSSL_CONF=clients/foundry-agent/openssl-classic.cnf "$PY" clients/foundry-agent/agent.py "Reply with one word: ok" 2>&1)"; rc=$?
  fi
  tail -1 <<<"$out" | sed 's/^/    /'
  if [[ $rc -eq 0 ]]; then check "Foundry agent answered" ok ok; else check "Foundry agent answered" failed ok; fi
else
  skip "pip install -r clients/foundry-agent/requirements.txt to run this check"
fi

echo; echo "$PASS passed, $FAILED failed"
[[ "$FAILED" == 0 ]]
