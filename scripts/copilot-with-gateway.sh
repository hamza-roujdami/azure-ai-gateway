#!/usr/bin/env bash
# Starts GitHub Copilot CLI with the gateway as its model provider and the gateway's MCP servers as its tools, signed
# in with your Microsoft Entra identity: no keys. Copilot gets exactly what your team files grant you, with your
# limits and budget, and every call shows up in the gateway's telemetry under your object ID.
#
#   ./scripts/copilot-with-gateway.sh shipping                         # interactive, with the shipping tools
#   ./scripts/copilot-with-gateway.sh shipping -- -p "Quote express shipping of WIDGET-42 to Norway" --allow-all-tools
#   ./scripts/copilot-with-gateway.sh -m claude shipping               # Claude, when deployed: same tools and limits
#   ./scripts/copilot-with-gateway.sh my-orders -- -p "What are my orders?" --allow-all-tools   # tools that act as you
#
# -m picks the model alias: chat (default) or claude (the Anthropic Messages API, when it's deployed). Not mistral:
# Copilot streams tool calls, and Mistral Large 3's streamed tool calls come back empty (see README, Limitations).
# Arguments before -- are MCP server names (python scripts/teams.py quickstart <team> lists yours); the rest go to
# copilot. Reads AI_GATEWAY_URL from the environment or .env. The Entra token lasts about an hour, so start a new
# session after that.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] && { set -a; source .env; set +a; }
: "${AI_GATEWAY_URL:?Set AI_GATEWAY_URL, or run scripts/deploy.sh to write .env}"
MODEL=chat
if [[ "${1:-}" == "-m" ]]; then MODEL="${2:?-m needs a model alias}"; shift 2; fi

# The model behind each alias, for Copilot's prompts and token limits, and the API it speaks.
GATEWAY="${AI_GATEWAY_URL%/}/default/models"
case "$MODEL" in
  chat)    TYPE=openai;    BASE="$GATEWAY/openai/v1"; WIRE=responses;   MODEL_ID=gpt-5-mini ;;
  claude)  TYPE=anthropic; BASE="$GATEWAY/anthropic"; WIRE=completions; MODEL_ID=claude-haiku-5-5 ;;
  *) echo "Unknown model alias $MODEL: use chat or claude." >&2; exit 1 ;;
esac

servers=()
while [[ $# -gt 0 && "$1" != "--" ]]; do servers+=("$1"); shift; done
[[ "${1:-}" == "--" ]] && shift

command -v copilot >/dev/null || { echo "Install GitHub Copilot CLI first." >&2; exit 1; }
# Data.All is the gateway's delegated scope: tools that act as you (on-behalf-of) need it in your token.
TOKEN="$(az account get-access-token --scope https://ai.gateway.azure.com/Data.All --query accessToken -o tsv)"
export TOKEN

# One session-only MCP entry per server, with the same token. It goes in a file only you can read, never on a command
# line, where other users of the machine could see it, and nothing is written to your Copilot configuration.
umask 077
CONFIG_DIR="$(mktemp -d)"
trap 'rm -rf "$CONFIG_DIR"' EXIT
python3 - "$AI_GATEWAY_URL" ${servers[@]+"${servers[@]}"} > "$CONFIG_DIR/mcp.json" <<'EOF'
import json, os, sys
url, names, token = sys.argv[1].rstrip("/"), sys.argv[2:], os.environ["TOKEN"]
print(json.dumps({"mcpServers": {
    f"gateway-{n}": {"type": "http", "url": f"{url}/default/toolservers/{n}/mcp",
                     "headers": {"Authorization": f"Bearer {token}"}, "tools": ["*"]} for n in names}}))
EOF

export COPILOT_PROVIDER_TYPE="$TYPE"
export COPILOT_PROVIDER_BASE_URL="$BASE"
export COPILOT_PROVIDER_BEARER_TOKEN="$TOKEN"
export COPILOT_PROVIDER_WIRE_API="$WIRE"
export COPILOT_PROVIDER_MODEL_ID="$MODEL_ID"
export COPILOT_MODEL="$MODEL"
unset TOKEN
copilot --additional-mcp-config "@$CONFIG_DIR/mcp.json" "$@"
