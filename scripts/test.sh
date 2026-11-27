#!/usr/bin/env bash
# Proves the access model and every workload end to end. Reads .env from scripts/deploy.sh.
#   ./scripts/test.sh
# You are platform:deployer in the team files: support-desk, coding-agents and employees grant you the chat and mistral
# models, the shipping tools, and my-orders, which acts as you. Nothing else: not the commerce tools that the order
# agent uses. Run it as the identity that deployed. Role changes take several minutes to apply.
set -uo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Run ./scripts/deploy.sh first (it writes .env)." >&2; exit 1; }
set -a; source .env; set +a
if [[ -n "${AZURE_RELOGIN_SCRIPT:-}" ]]; then "$AZURE_RELOGIN_SCRIPT"; fi  # GitHub Actions: fresh OIDC sign-in
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
served_from() {  # the region that answered a chat call, from the x-ms-region response header, as in swedencentral
  curl -s -o /dev/null -D - --max-time 90 -X POST "$CHAT" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' "${@:2}" -d "$BODY" | tr -d '\r' |
    awk -F': ' 'tolower($1)=="x-ms-region" {gsub(/ /, "", $2); print tolower($2)}'
}

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
    MISTRAL="${BODY/\"model\":\"$AI_GATEWAY_MODEL\"/\"model\":\"mistral\"}"
    check "you can call a second model family (mistral, coding-agents)" \
      "$(status -X POST "$CHAT" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$MISTRAL")" 200
    check "you can use the shipping tools (coding-agents)" "$(mcp_status shipping "$TOKEN")" 200
    check "you're denied the commerce tools (no team grants them to you)" "$(mcp_status commerce "$TOKEN")" 403
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

echo "== Model routing: one alias, two regions (scripts/demo-failover.sh shows failover under throttling)"
if [[ "$INBOUND_MODE" != "hybrid" || "$AS_DEVELOPER" != true ]]; then skip "runs from your machine, as the developer"
else
  # Right after an outage (demo-failover.sh --outage), calls keep failing over until the primary is back on every node.
  for _ in 1 2 3 4 5 6; do region="$(served_from "$TOKEN")"; [[ "$region" == "$AZURE_LOCATION" ]] && break; sleep 10; done
  check "chat is served from the primary region" "$region" "$AZURE_LOCATION"
  check "x-workload: batch skips the primary (CEL condition)" \
    "$(served_from "$TOKEN" -H 'x-workload: batch')" "$AZURE_BACKUP_LOCATION"
fi

echo "== Users: a tool that acts as the signed-in user (on-behalf-of)"
if [[ "$INBOUND_MODE" != "hybrid" || "$AS_DEVELOPER" != true ]]; then skip "runs from your machine, as the developer"
elif [[ ",$AI_GATEWAY_MCP_SERVERS," != *",my-orders,"* ]]; then skip "my-orders isn't deployed: no Entra apps (see deploy.sh)"
elif "$PY" -c "import mcp" 2>/dev/null; then
  ME="$(az ad signed-in-user show --query id -o tsv)"
  if who="$("$PY" scripts/mcp_call.py my-orders my-orders_whoami 2>&1)" && grep -q "$ME" <<<"$who"; then
    check "the backend sees you, not a shared account" ok ok
  else echo "$who" | tail -3 | sed 's/^/    /'; check "the backend sees you, not a shared account" failed ok; fi
  if mine="$("$PY" scripts/mcp_call.py my-orders my-orders_my_orders 2>&1)" && grep -q '"account": "Contoso"' <<<"$mine"; then
    check "my-orders returns only your account's orders" ok ok
  else echo "$mine" | tail -3 | sed 's/^/    /'; check "my-orders returns only your account's orders" failed ok; fi
else skip "pip install mcp to run this check"; fi

echo "== Backends: not reachable from the internet"
FTOKEN="$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${FOUNDRY_MODELS_ENDPOINT%/}/openai/v1/models" \
  -H "Authorization: Bearer $FTOKEN")"
# Public access off: a call from outside the VNet gets 401 or 403, or no answer at all (000). Anything but 2xx counts.
[[ "$code" != 2* ]] && code=rejected
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

echo "== Foundry hosted agent: its code on Foundry -> gateway (chat, commerce) as its own Entra Agent ID"
if [[ "$INBOUND_MODE" == "private" ]]; then
  skip "a Foundry hosted agent reaches the gateway's public endpoint (see README, Inbound modes)"
elif [[ "$AS_DEVELOPER" != true ]] || ! command -v azd >/dev/null; then
  skip "invoking the hosted agent needs azd and the developer's Foundry access"
elif ! (cd agents/hosted-order-assistant && azd env select "${AZURE_RESOURCE_GROUP#rg-}" >/dev/null 2>&1); then
  skip "the hosted agent isn't deployed from this machine (scripts/deploy-hosted-agent.sh)"
else
  out="$(cd agents/hosted-order-assistant && AZURE_DEV_USER_AGENT=microsoft_foundry_skill azd ai agent invoke \
    hosted-order-assistant --new-conversation "What is the status of order 1001? Reply in one sentence." 2>&1)"
  grep '^\[hosted-order-assistant\]' <<<"$out" | sed 's/^/    /'
  if grep -qi "shipped" <<<"$out"; then check "hosted agent answered from the commerce tools" ok ok
  else check "hosted agent answered from the commerce tools" failed ok; fi
fi

echo; echo "$PASS passed, $FAILED failed"
[[ "$FAILED" == 0 ]]
