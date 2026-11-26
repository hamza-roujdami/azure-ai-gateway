#!/usr/bin/env bash
# Deletes the resource group, purges the soft-deleted Foundry accounts so their names can be reused, and deletes the
# Microsoft Entra apps for on-behalf-of (infra/entra), which live in the tenant, not the resource group.
#   ./scripts/teardown.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "No .env: nothing to tear down from this folder." >&2; exit 1; }
set -a; source .env; set +a

read -rp "Delete resource group $AZURE_RESOURCE_GROUP and everything in it? [y/N] " answer
[[ "$answer" == "y" ]] || exit 0
apps="$(az deployment group show -g "$AZURE_RESOURCE_GROUP" -n "entra-$AZURE_ENV_NAME" \
  --query "[properties.outputs.backendAppId.value, properties.outputs.tokenExchangeAppId.value]" -o tsv 2>/dev/null || true)"
az group delete -n "$AZURE_RESOURCE_GROUP" --yes
for account in "$FOUNDRY_MODELS_ACCOUNT:$AZURE_LOCATION" "$FOUNDRY_AGENTS_ACCOUNT:$AZURE_LOCATION" \
  "${FOUNDRY_BACKUP_ACCOUNT:-}:${AZURE_BACKUP_LOCATION:-}"; do
  [[ "$account" == ":" ]] && continue
  az cognitiveservices account purge -n "${account%%:*}" -g "$AZURE_RESOURCE_GROUP" -l "${account#*:}" 2>/dev/null || true
done
for app in $apps; do
  az ad app delete --id "$app" 2>/dev/null && echo "Deleted the Entra app $app." ||
    echo "Couldn't delete the Entra app $app: ask an identity administrator to." >&2
done
rm -f .env
echo "Deleted."
