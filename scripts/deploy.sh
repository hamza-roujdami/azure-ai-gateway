#!/usr/bin/env bash
# Deploys the AI gateway end to end:
#   1. infrastructure (network, Foundry, gateway, model and alias, Foundry project, registry, Container Apps environment)
#   2. builds the images in the registry (az acr build, no local Docker needed)
#   3. the container apps, and the orders, shipping and returns MCP servers behind the gateway
#   4. removes runtime roles that no team file grants, and suspends the built-in all-access key
#   5. the gateway-wide baseline policies
#   6. the gateway's OpenTelemetry exporter to Application Insights
# Who can call what comes from the team files in teams/. Then writes the outputs to .env for scripts/test.sh.
#
#   AZURE_ENV_NAME=aigw-demo AZURE_LOCATION=swedencentral ./scripts/deploy.sh
#   INBOUND_MODE=private GATEWAY_PRIVATE_ENDPOINT=true ./scripts/deploy.sh   # needs private endpoint preview access
set -euo pipefail
cd "$(dirname "$0")/.."

export AZURE_ENV_NAME="${AZURE_ENV_NAME:-aigw-demo}"
export AZURE_LOCATION="${AZURE_LOCATION:-swedencentral}"
export INBOUND_MODE="${INBOUND_MODE:-hybrid}"
export GATEWAY_PRIVATE_ENDPOINT="${GATEWAY_PRIVATE_ENDPOINT:-false}"

fail() { echo "ERROR: $*" >&2; exit 1; }

az account show -o none 2>/dev/null || fail "Sign in first: az login"
az extension show -n aigateway -o none 2>/dev/null ||
  fail "Install the aigateway CLI extension: curl -fsSL https://aka.ms/aigateway-cli-install -o install.sh && sh install.sh"
[[ "$INBOUND_MODE" == "private" && "$GATEWAY_PRIVATE_ENDPOINT" != "true" ]] &&
  fail "INBOUND_MODE=private turns the public endpoint off, so it needs GATEWAY_PRIVATE_ENDPOINT=true."
if [[ "$GATEWAY_PRIVATE_ENDPOINT" == "true" ]]; then
  state="$(az feature show --namespace Microsoft.Network --name AllowPrivateEndpoints --query properties.state -o tsv)"
  [[ "$state" == "Registered" ]] || fail "The gateway's inbound private endpoint is in preview and this subscription \
doesn't have access yet ($state). Request it with an Azure support request: 'Enable private endpoints for Azure AI Gateway'."
fi

if [[ -z "${AZURE_PRINCIPAL_ID:-}" ]]; then
  AZURE_PRINCIPAL_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
  [[ -n "$AZURE_PRINCIPAL_ID" ]] || fail "Set AZURE_PRINCIPAL_ID (and AZURE_PRINCIPAL_TYPE=ServicePrincipal) when not signed in as a user."
fi
export AZURE_PRINCIPAL_ID

echo "Subscription: $(az account show --query '[name, id]' -o tsv | paste -sd' ' -)"
echo "Environment:  $AZURE_ENV_NAME in $AZURE_LOCATION, inbound mode $INBOUND_MODE"

echo "== Team files"
python3 scripts/teams.py validate
AI_GATEWAY_TEAMS="$(python3 scripts/teams.py render)"
export AI_GATEWAY_TEAMS

echo "== Registering resource providers"
for ns in Microsoft.ApiManagement Microsoft.App Microsoft.CognitiveServices Microsoft.ContainerRegistry \
  Microsoft.Network Microsoft.OperationalInsights Microsoft.Insights Microsoft.ManagedIdentity Microsoft.Monitor; do
  az provider register -n "$ns" --wait -o none
done

deploy() {
  az deployment sub create -n "$AZURE_ENV_NAME" -l "$AZURE_LOCATION" \
    -f infra/main.bicep -p infra/main.bicepparam -o none
}
output() { python3 scripts/outputs.py "$AZURE_ENV_NAME" "$1"; }

echo "== 1/6 Infrastructure (about 10 minutes)"
DEPLOY_APPS=false deploy
RG="$(output AZURE_RESOURCE_GROUP)"
ACR="$(output ACR_NAME)"
GATEWAY="$(output AI_GATEWAY_NAME)"
GATEWAY_ID="$(output AI_GATEWAY_ID)"

echo "== 2/6 Building images in $ACR"
export IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d%H%M%S)}"
az acr build -r "$ACR" -t "mcp-server:$IMAGE_TAG" tools/mcp-server -o none
az acr build -r "$ACR" -t "shipping-api:$IMAGE_TAG" tools/shipping-api -o none
az acr build -r "$ACR" -t "returns-agent:$IMAGE_TAG" agents/returns-agent -o none
az acr build -r "$ACR" -t "aca-agent:$IMAGE_TAG" clients/aca-agent -o none

echo "== 3/6 Container apps and the MCP servers behind the gateway"
DEPLOY_APPS=true deploy

echo "== 4/6 Access: runtime roles that no team file grants, and the built-in all-access key"
python3 scripts/teams.py prune "$AZURE_ENV_NAME" --apply
# Every gateway has a built-in key named master that can call every model and tool. Callers here use Entra ID only.
az aigateway api-key update -g "$RG" --gateway-name "$GATEWAY" -n master --state suspended -o none
echo "Suspended the built-in master key."

echo "== 5/6 Gateway-wide baseline policies (platform/baseline-policies.json)"
python3 scripts/apply_baseline.py "$GATEWAY_ID" > /dev/null
echo "Applied."

echo "== 6/6 Gateway telemetry"
RG="$RG" GATEWAY="$GATEWAY" APP_INSIGHTS_NAME="$(output APPLICATION_INSIGHTS_NAME)" \
  infra/scripts/connect-telemetry.sh

python3 scripts/outputs.py "$AZURE_ENV_NAME" --env > .env
echo "INBOUND_MODE=$INBOUND_MODE" >> .env
echo "Done. Outputs written to .env. Next: ./scripts/test.sh"
