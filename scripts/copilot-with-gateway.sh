#!/usr/bin/env bash
# Starts GitHub Copilot CLI with the gateway as its model provider and the gateway's MCP servers as its tools, signed
# in with your Microsoft Entra identity: no keys. Copilot gets exactly what your team files grant you, with your
# limits and budget, and every call shows up in the gateway's telemetry under your object ID.
#
#   ./scripts/copilot-with-gateway.sh shipping                         # interactive, with the shipping tools
#   ./scripts/copilot-with-gateway.sh shipping -- -p "Quote express shipping of WIDGET-42 to Norway" --allow-all-tools
#
# Arguments before -- are MCP server names (python scripts/teams.py quickstart <team> lists yours); the rest go to
# copilot. Reads AI_GATEWAY_URL and AI_GATEWAY_MODEL from the environment or .env. The Entra token lasts about an
# hour, so start a new session after that.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] && { set -a; source .env; set +a; }
: "${AI_GATEWAY_URL:?Set AI_GATEWAY_URL, or run scripts/deploy.sh to write .env}"
MODEL="${AI_GATEWAY_MODEL:-chat}"
MODEL_ID="${AI_GATEWAY_MODEL_ID:-gpt-5-mini}"   # the model behind the alias, for Copilot's prompts and token limits

servers=()
while [[ $# -gt 0 && "$1" != "--" ]]; do servers+=("$1"); shift; done
[[ "${1:-}" == "--" ]] && shift

command -v copilot >/dev/null || { echo "Install GitHub Copilot CLI first." >&2; exit 1; }
TOKEN="$(az account get-access-token --scope https://ai.gateway.azure.com/.default --query accessToken -o tsv)"
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

export COPILOT_PROVIDER_BASE_URL="${AI_GATEWAY_URL%/}/default/models/openai/v1"
export COPILOT_PROVIDER_BEARER_TOKEN="$TOKEN"
export COPILOT_PROVIDER_WIRE_API=responses
export COPILOT_PROVIDER_MODEL_ID="$MODEL_ID"
export COPILOT_MODEL="$MODEL"
unset TOKEN
copilot --additional-mcp-config "@$CONFIG_DIR/mcp.json" "$@"
