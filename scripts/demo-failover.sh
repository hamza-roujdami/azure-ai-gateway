#!/usr/bin/env bash
# Shows how the chat alias routes and fails over, from the client's side: every call sends "model": "chat", and the
# x-ms-region response header names the region of the Foundry deployment that answered.
#
#   ./scripts/demo-failover.sh           # the routing rules, then normal and batch traffic
#   ./scripts/demo-failover.sh --outage  # also take the primary out for about a minute, and watch failover
#
# --outage simulates the primary deployment going missing in its region, for every caller of the chat alias, then
# puts it back. Run it as a developer whom the team files grant the chat model, with Contributor on the gateway.
# Reads .env from scripts/deploy.sh. (Pausing the Foundry deployment instead isn't reliable: in our tests, the preview
# pause and resume actions reached serving nodes unevenly and left the primary answering 423 for 40 minutes.)
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Run ./scripts/deploy.sh first (it writes .env)." >&2; exit 1; }
set -a; source .env; set +a

CHAT="$AI_GATEWAY_URL/default/models/openai/v1/chat/completions"
TOKEN="$(az account get-access-token --scope https://ai.gateway.azure.com/.default --query accessToken -o tsv)"
BODY='{"model":"chat","messages":[{"role":"user","content":"Reply with one word: ok"}],"max_completion_tokens":200}'

call() {  # prints "<status> <region that answered>"
  curl -s -o /dev/null -D - --max-time 90 -X POST "$CHAT" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' "$@" -d "$BODY" | tr -d '\r' |
    awk -F': ' 'toupper($1) ~ /^HTTP/ {split($0, a, " "); code=a[2]} tolower($1)=="x-ms-region" {m=$2; gsub(/ /, "", m)}
                END {print code, (m ? m : "-")}'
}
burst() {  # <count> <pause> [curl args]: one line per call, then the totals
  local n="$1" pause="$2"; shift 2
  for i in $(seq 1 "$n"); do printf '  %2d  %s\n' "$i" "$(call "$@")"; sleep "$pause"; done | tee /tmp/burst.$$
  echo "  totals: $(awk '{print "HTTP " $2 " from " $3}' /tmp/burst.$$ | sort | uniq -c | awk '{$1 = $1 " x"; print}' |
    paste -sd';' -)"
  rm -f /tmp/burst.$$
}

echo "== The chat alias: backends, priorities, the CEL condition, and the failure rule"
az rest --method get --url "https://management.azure.com$AI_GATEWAY_ID/workspaces/default/aliases/chat?api-version=2026-11-01" \
  --query "properties.{backends: backendModels[].{model: resourceId, priority: priority, when: when}, \
failures: failures, maxRetryAttempts: maxRetryAttempts}" -o json |
  sed -E 's#/subscriptions/[^"]*/modelProviders/([^/"]+)/models/([^"]+)#\1/\2#'

echo; echo "== Interactive traffic: served from $AZURE_LOCATION"
burst 3 1
echo; echo "== x-workload: batch: the CEL condition skips the primary, so batch jobs never use its capacity"
burst 3 1 -H 'x-workload: batch'

[[ "${1:-}" == "--outage" ]] || { echo; echo "Add --outage to watch failover when the primary is down."; exit 0; }

# The outage: the gateway's primary backend model points at a deployment that doesn't exist in the primary region, so
# Foundry answers 404 DeploymentNotFound, as when a model is retired or removed in one region. It changes only the
# gateway, takes effect in seconds, and the saved definition is put back on exit, also on Ctrl+C.
MODEL="https://management.azure.com$AI_GATEWAY_ID/workspaces/default/modelProviders/foundry/models/$AI_GATEWAY_MODEL_ID?api-version=2026-11-01"
SAVED="$(mktemp)"; BROKEN="$(mktemp)"
az rest --method get --url "$MODEL" -o json > "$SAVED"
python3 - "$SAVED" "$BROKEN" <<'PY'
import json, sys
saved = json.load(open(sys.argv[1]))["properties"]
saved.pop("provisioningState", None)
json.dump({"properties": saved}, open(sys.argv[1], "w"))
broken = json.loads(json.dumps(saved))
broken["deployment"]["resourceId"] += "-unavailable"
broken["deployment"]["modelName"] += "-unavailable"
json.dump({"properties": broken}, open(sys.argv[2], "w"))
PY
restore() {  # Retries: the broken definition may still be applying. Keeps the saved copy if it can't put it back.
  local attempt restored
  for attempt in 1 2 3 4 5; do
    if restored="$(az rest --method put --url "$MODEL" --body "@$SAVED" --query properties.deployment.modelName \
      -o tsv)"; then
      echo "== Restored the primary backend model: $restored"; rm -f "$SAVED" "$BROKEN"; return 0
    fi
    sleep 10
  done
  echo "RESTORE FAILED: the primary backend model still points at a missing deployment. Put it back with:" >&2
  echo "  az rest --method put --url '$MODEL' --body @$SAVED     (or run ./scripts/deploy.sh)" >&2
  exit 1
}
trap restore EXIT

echo; echo "== Outage: the primary backend model now points at a deployment that doesn't exist in $AZURE_LOCATION:" \
  "$(az rest --method put --url "$MODEL" --body "@$BROKEN" --query properties.deployment.modelName -o tsv)"
echo "   Foundry answers 404; the failure rule sends each call on to $AZURE_BACKUP_LOCATION and keeps the primary out"
echo "   for 30 seconds. The change takes a few seconds to reach the gateway. Clients only ever see 200."
sleep 10
burst 10 2
echo "   The gateway's traces show each failed send: in Application Insights, or OTelSpans in Log Analytics, the client"
echo "   spans to $FOUNDRY_MODELS_ACCOUNT with status 404, each followed by a 200 from $FOUNDRY_BACKUP_ACCOUNT."
