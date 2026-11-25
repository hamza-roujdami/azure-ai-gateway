#!/usr/bin/env bash
# Deletes the resource group and purges the soft-deleted Foundry accounts, so their names can be reused.
#   ./scripts/teardown.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "No .env: nothing to tear down from this folder." >&2; exit 1; }
set -a; source .env; set +a

read -rp "Delete resource group $AZURE_RESOURCE_GROUP and everything in it? [y/N] " answer
[[ "$answer" == "y" ]] || exit 0
az group delete -n "$AZURE_RESOURCE_GROUP" --yes
for account in "$FOUNDRY_MODELS_ACCOUNT" "$FOUNDRY_AGENTS_ACCOUNT"; do
  az cognitiveservices account purge -n "$account" -g "$AZURE_RESOURCE_GROUP" -l "$AZURE_LOCATION" 2>/dev/null || true
done
rm -f .env
echo "Deleted."
