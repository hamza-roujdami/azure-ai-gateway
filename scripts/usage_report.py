"""Usage by team, from the gateway's OpenTelemetry data in Log Analytics.

The gateway exports each caller's Microsoft Entra object ID (the oid claim) with its request spans and logs. This
report maps those IDs to the members of the team files, so a platform team sees, per team member: requests, model and
tool calls, denials (403), throttling (429), backend errors (5xx), tokens, and the gateway's estimated cost.

  python scripts/usage_report.py <deployment> [--hours 24]

Estimated cost is the gateway's estimate from observed tokens and public prices; your Azure bill is the source of truth.
An identity in two teams is shown once, with both teams. Telemetry arrives a few minutes after the calls.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from typing import Any

from outputs import deployment_outputs

QUERY = """
let since = ago({hours}h);
let requests = OTelSpans
    | where TimeGenerated > since and Kind == "Server" and Name startswith "POST /default/"
    | extend a = parse_json(Attributes)
    | extend ObjectId = tostring(a["azure.ai_gateway.identity.claims.oid"]),
             Status = toint(a["http.response.status_code"])
    | summarize Requests = count(), Denied = countif(Status == 403), Throttled = countif(Status == 429),
                BackendErrors = countif(Status >= 500) by ObjectId;
let calls = OTelLogs
    | where TimeGenerated > since
    | extend a = parse_json(Attributes)
    | extend ObjectId = tostring(a["azure.ai_gateway.identity.claims.oid"]),
             IsModel = isnotempty(tostring(a["gen_ai.request.model"])),
             IsTool = tostring(a["gen_ai.operation.name"]) == "execute_tool",
             Tokens = coalesce(tolong(a["azure.ai_gateway.client.usage.prompt_tokens"]),
                               tolong(a["azure.ai_gateway.client.usage.input_tokens"]), long(0))
                    + coalesce(tolong(a["azure.ai_gateway.client.usage.completion_tokens"]),
                               tolong(a["azure.ai_gateway.client.usage.output_tokens"]), long(0)),
             Cost = coalesce(todouble(a["azure.ai_gateway.client.token.cost"]), 0.0)
    | summarize ModelCalls = countif(IsModel), ToolCalls = countif(IsTool), Tokens = sum(Tokens),
                CostUsd = round(sum(Cost), 4) by ObjectId;
requests
| join kind=fullouter calls on ObjectId
| extend ObjectId = coalesce(ObjectId, ObjectId1)
| project ObjectId, Requests = coalesce(Requests, long(0)), ModelCalls = coalesce(ModelCalls, long(0)),
          ToolCalls = coalesce(ToolCalls, long(0)), Denied = coalesce(Denied, long(0)),
          Throttled = coalesce(Throttled, long(0)), BackendErrors = coalesce(BackendErrors, long(0)),
          Tokens = coalesce(Tokens, long(0)), CostUsd = coalesce(CostUsd, 0.0)
"""
COLUMNS = ("Requests", "ModelCalls", "ToolCalls", "Denied", "Throttled", "BackendErrors", "Tokens", "CostUsd")
HEADERS = ("Requests", "Model calls", "Tool calls", "Denied (403)", "Throttled (429)", "Backend 5xx", "Tokens")


@dataclass(frozen=True)
class Row:
    teams: str
    members: str
    values: dict[str, float]


def build_rows(results: list[dict[str, Any]], members: list[dict[str, str]]) -> list[Row]:
    """One row per caller identity, labelled with its teams and member names. Unknown callers are grouped."""
    by_id: dict[str, list[dict[str, str]]] = {}
    for m in members:
        by_id.setdefault(m["principalId"].lower(), []).append(m)
    rows: dict[tuple[str, str], dict[str, float]] = {}
    for r in results:
        found = by_id.get(str(r.get("ObjectId") or "").lower())
        if found:
            key = (", ".join(sorted({m["team"] for m in found})), ", ".join(sorted({m["member"] for m in found})))
        else:
            key = ("(not in a team file)", "no token" if not r.get("ObjectId") else "unknown identity")
        totals = rows.setdefault(key, dict.fromkeys(COLUMNS, 0.0))
        for c in COLUMNS:
            totals[c] += float(r.get(c) or 0)
    return [Row(t, m, v) for (t, m), v in sorted(rows.items())]


def markdown(rows: list[Row], hours: int) -> str:
    if not rows:
        return f"No gateway traffic in the last {hours} hours (telemetry arrives a few minutes after the calls)."
    lines = [
        f"### Gateway usage by team, last {hours} hours",
        "",
        "| Team | Member | " + " | ".join(HEADERS) + " | Estimated cost (USD) |",
        "|---|---|" + "---:|" * (len(HEADERS) + 1),
    ]
    for r in rows:
        counts = " | ".join(str(int(r.values[c])) for c in COLUMNS[:-1])
        lines.append(f"| {r.teams} | {r.members} | {counts} | {r.values['CostUsd']:.4f} |")
    return "\n".join(lines) + "\n"


def _workspace_id(outputs: dict[str, Any]) -> str:
    if outputs.get("LOG_ANALYTICS_WORKSPACE_ID"):
        return outputs["LOG_ANALYTICS_WORKSPACE_ID"]
    result = subprocess.run(
        ["az", "monitor", "log-analytics", "workspace", "list", "-g", outputs["AZURE_RESOURCE_GROUP"],
         "--query", "[0].customerId", "-o", "tsv"],
        check=True, capture_output=True, text=True,
    )  # fmt: skip
    return result.stdout.strip()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("deployment", help="name of the subscription deployment, AZURE_ENV_NAME")
    parser.add_argument("--hours", type=int, default=24)
    args = parser.parse_args(argv)

    outputs = deployment_outputs(args.deployment)
    result = subprocess.run(
        ["az", "monitor", "log-analytics", "query", "-w", _workspace_id(outputs),
         "--analytics-query", QUERY.replace("{hours}", str(args.hours)), "-o", "json"],
        capture_output=True, text=True,
    )  # fmt: skip
    if result.returncode != 0:
        print(f"ERROR querying Log Analytics: {result.stderr.strip()}", file=sys.stderr)
        return 1
    rows = build_rows(json.loads(result.stdout or "[]"), outputs.get("TEAM_MEMBERS") or [])
    print(markdown(rows, args.hours))
    return 0


if __name__ == "__main__":
    sys.exit(main())
