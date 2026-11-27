#!/usr/bin/env bash
# Deploys the Foundry hosted agent (agents/hosted-order-assistant) into this deployment's Foundry project with azd, and
# prints the principal ID of its Microsoft Entra Agent ID on the last line, for teams/foundry-hosted-agents.json
# (platform:hosted-agent). The agent's code runs on Foundry; its model and tools come only from the gateway.
#
#   ./scripts/deploy-hosted-agent.sh          # after scripts/deploy.sh wrote .env; deploy.sh also calls it
#
# Reads the deployment's values from the environment, or from .env when they aren't set. Creates the azd environment
# on first use, so no `azd ai agent init` is needed. Needs azd with the
# azure.ai.agents extension, and Foundry User on the Foundry project (deploy.sh grants it to platform:deployer).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${AI_GATEWAY_URL:-}" || -z "${FOUNDRY_AGENTS_ACCOUNT:-}" ]]; then
  [[ -f .env ]] || { echo "Run ./scripts/deploy.sh first (it writes .env)." >&2; exit 1; }
  set -a; source .env; set +a
fi

AZURE_ENV_NAME="${AZURE_ENV_NAME:-${AZURE_RESOURCE_GROUP#rg-}}"  # the resource group is rg-<environment name>
AGENT_DIR=agents/hosted-order-assistant
SERVICE=hosted-order-assistant
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
PROJECT_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.CognitiveServices/accounts/$FOUNDRY_AGENTS_ACCOUNT/projects/${FOUNDRY_PROJECT_ENDPOINT##*/}"
export AZURE_DEV_USER_AGENT=microsoft_foundry_skill  # identifies this tooling in azd telemetry; not persisted

cd "$AGENT_DIR"
if ! azd env select "$AZURE_ENV_NAME" >/dev/null 2>&1; then
  azd env new "$AZURE_ENV_NAME" --no-prompt >/dev/null
fi
# The existing Foundry project, as `azd ai agent init --project-id` records it: code deploy, no container registry.
for pair in "AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID" "AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)" \
  "AZURE_RESOURCE_GROUP=$AZURE_RESOURCE_GROUP" "AZURE_LOCATION=$AZURE_LOCATION" "AZURE_AI_PROJECT_ID=$PROJECT_ID" \
  "AZURE_AI_ACCOUNT_NAME=$FOUNDRY_AGENTS_ACCOUNT" "AZURE_AI_PROJECT_NAME=${FOUNDRY_PROJECT_ENDPOINT##*/}" \
  "FOUNDRY_PROJECT_ENDPOINT=$FOUNDRY_PROJECT_ENDPOINT" "USE_EXISTING_AI_PROJECT=true" "AZD_AGENT_SKIP_ACR=true" \
  "AZD_FOUNDRY_ACR_MODE=none" "AI_GATEWAY_URL=$AI_GATEWAY_URL"; do
  azd env set "${pair%%=*}" "${pair#*=}" >/dev/null
done

echo "Deploying $SERVICE to the Foundry project $PROJECT_ID" >&2
azd deploy "$SERVICE" --no-prompt >&2
VAR="AGENT_$(tr '[:lower:]-' '[:upper:]_' <<<"$SERVICE")_INSTANCE_IDENTITY_PRINCIPAL_ID"
PRINCIPAL_ID="$(azd env get-value "$VAR" 2>/dev/null || true)"
[[ -n "$PRINCIPAL_ID" ]] || { echo "azd didn't record $VAR: check the deploy output." >&2; exit 1; }
echo "$PRINCIPAL_ID"
