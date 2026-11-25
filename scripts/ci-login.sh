#!/usr/bin/env bash
# Signs the Azure CLI in again inside GitHub Actions, with a fresh GitHub OIDC token. The token that azure/login
# exchanges is valid for about 5 minutes, and the deployment runs much longer, so deploy.sh and test.sh call this at
# the start of each phase when AZURE_RELOGIN_SCRIPT points to it. No secret is involved: the job's id-token
# permission lets it ask GitHub for a new token.
set -euo pipefail
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?Run this inside a GitHub Actions job with permissions: id-token: write}"
: "${AZURE_CLIENT_ID:?}" "${AZURE_TENANT_ID:?}" "${AZURE_SUBSCRIPTION_ID:?}"

TOKEN="$(curl -fsS -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')"
az login --service-principal -u "$AZURE_CLIENT_ID" --tenant "$AZURE_TENANT_ID" --federated-token "$TOKEN" -o none
az account set -s "$AZURE_SUBSCRIPTION_ID"
