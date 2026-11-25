#!/usr/bin/env bash
# One-time setup for .github/workflows/deploy.yml: lets GitHub Actions deploy this repo to your subscription with
# OpenID Connect, so no secret is stored anywhere (as in Microsoft's AI Gateway lab 21).
#   1. an app registration and service principal that the workflow signs in as
#   2. a federated credential that trusts only this repository's "azure" GitHub environment, which only main can use
#   3. Contributor and Role Based Access Control Administrator on the subscription (the templates assign roles)
#   4. the "azure" environment and its variables in the GitHub repository
#
#   GITHUB_REPO=<owner>/<repo> AZURE_ENV_NAME=aigw-demo ./scripts/setup-github-deploy.sh
#
# Needs: az (signed in as an Owner of the subscription who can register applications) and gh (signed in to GitHub
# with admin rights on the repository). Running it twice gives the same result.
set -euo pipefail

: "${GITHUB_REPO:?Set GITHUB_REPO to <owner>/<repo>}"
AZURE_ENV_NAME="${AZURE_ENV_NAME:-aigw-demo}"
AZURE_LOCATION="${AZURE_LOCATION:-swedencentral}"
APP_NAME="${APP_NAME:-github-${GITHUB_REPO//\//-}-deploy}"
ENVIRONMENT=azure

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
# platform:deployer in the team files: the developer who gets the example access, not the pipeline's identity
DEVELOPER_ID="${DEVELOPER_PRINCIPAL_ID:-$(az ad signed-in-user show --query id -o tsv)}"
DEVELOPER_TYPE="${DEVELOPER_PRINCIPAL_TYPE:-User}"

echo "== 1/4 App registration $APP_NAME"
APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
[[ -n "$APP_ID" ]] || APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
SP_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || az ad sp create --id "$APP_ID" --query id -o tsv)"

echo "== 2/4 Federated credential for the $ENVIRONMENT environment of $GITHUB_REPO"
SUBJECT_PREFIX="$(gh api "repos/$GITHUB_REPO/actions/oidc/customization/sub" --jq .sub_claim_prefix 2>/dev/null || true)"
[[ -n "$SUBJECT_PREFIX" ]] || SUBJECT_PREFIX="repo:$GITHUB_REPO"
if [[ -z "$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='github-$ENVIRONMENT'].name" -o tsv)" ]]; then
  az ad app federated-credential create --id "$APP_ID" -o none --parameters "{
    \"name\": \"github-$ENVIRONMENT\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$SUBJECT_PREFIX:environment:$ENVIRONMENT\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
fi

echo "== 3/4 Roles on the subscription"
for ROLE in "Contributor" "Role Based Access Control Administrator"; do
  az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal \
    --role "$ROLE" --scope "/subscriptions/$SUBSCRIPTION_ID" -o none
done

echo "== 4/4 GitHub environment $ENVIRONMENT, limited to the main branch, and its variables"
# Only workflows running on main can use the environment, so only they get a token for the deployment identity.
gh api -X PUT "repos/$GITHUB_REPO/environments/$ENVIRONMENT" --silent --input - <<'EOF'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
if [[ -z "$(gh api "repos/$GITHUB_REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
  --jq '.branch_policies[] | select(.name == "main" and .type == "branch") | .name')" ]]; then
  gh api -X POST "repos/$GITHUB_REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
    -f name=main -f type=branch --silent
fi
# They identify the identity but can't authenticate anyone on their own, so they're variables, not secrets.
for pair in "AZURE_CLIENT_ID=$APP_ID" "AZURE_TENANT_ID=$TENANT_ID" "AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID" \
  "AZURE_ENV_NAME=$AZURE_ENV_NAME" "AZURE_LOCATION=$AZURE_LOCATION" \
  "DEVELOPER_PRINCIPAL_ID=$DEVELOPER_ID" "DEVELOPER_PRINCIPAL_TYPE=$DEVELOPER_TYPE"; do
  gh variable set "${pair%%=*}" --env "$ENVIRONMENT" --body "${pair#*=}" -R "$GITHUB_REPO"
done
# A job's if: can't read environment variables, so the workflow checks this repository variable instead.
gh variable set DEPLOY_ENABLED --body true -R "$GITHUB_REPO"
echo "Done. Merges to main that change teams/, platform/, infra/ or the apps now deploy to $AZURE_ENV_NAME."
