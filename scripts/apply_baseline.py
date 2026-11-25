"""Applies the gateway-wide baseline in platform/baseline-policies.json to an Azure AI Gateway.

Gateway-scope policies live in the policies array of the gateway's default workspace. Bicep can't declare that
workspace (it accepts PATCH, not PUT), and a PATCH replaces the whole array, so this script merges, as in Microsoft's
lab 21:
  - a baseline policy whose type already exists updates that policy in place, keeping its id and overrides, so a cost
    limit keeps the spend it has counted
  - a new baseline policy is appended; a new cost limit gets a stable id
  - policies of other types, for example ones added in the portal, stay as they are
Running it twice gives the same result. Every applicable policy can block a call, so asset policies can only be
stricter than the baseline.

  python scripts/apply_baseline.py <gateway resource ID> [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
BASELINE_FILE = ROOT / "platform" / "baseline-policies.json"
API_VERSION = "2026-11-01"


def load_baseline(path: Path = BASELINE_FILE) -> list[dict[str, Any]]:
    data = json.loads(path.read_text())
    if not isinstance(data, list) or not all(isinstance(p, dict) and p.get("type") for p in data):
        raise ValueError(f"{path.name} must be a JSON array of policies, each with a type")
    types = [p["type"] for p in data]
    if len(set(types)) != len(types):
        raise ValueError(f"{path.name} lists a policy type twice")
    return data


def daily_cost_ceiling(baseline: list[dict[str, Any]]) -> float | None:
    """The gateway-wide daily cost limit per caller, which no team budget can exceed."""
    for p in baseline:
        if p["type"] == "costLimit" and p.get("period") == "day":
            return float(p["amount"])
    return None


def merge(current: list[dict[str, Any]], baseline: list[dict[str, Any]], gateway_id: str) -> list[dict[str, Any]]:
    merged = [dict(p) for p in current]
    for policy in baseline:
        existing = next((p for p in merged if p.get("type") == policy["type"]), None)
        if existing is not None:
            existing.update(policy)
        elif policy["type"] == "costLimit" and not policy.get("id"):
            merged.append({**policy, "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{gateway_id.lower()}/baseline"))})
        else:
            merged.append(dict(policy))
    return merged


def _rest(method: str, url: str, body: dict[str, Any] | None = None) -> Any:
    args = ["az", "rest", "--method", method, "--url", url, "-o", "json"]
    if body is not None:
        args += ["--body", json.dumps(body)]
    out = subprocess.run(args, check=True, capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("gateway_id", help="/subscriptions/.../providers/Microsoft.ApiManagement/aigateways/<name>")
    parser.add_argument("--dry-run", action="store_true", help="print the merged policies without changing anything")
    args = parser.parse_args(argv)

    url = f"https://management.azure.com{args.gateway_id}/workspaces/default?api-version={API_VERSION}"
    current = (_rest("get", url).get("properties") or {}).get("policies") or []
    merged = merge(current, load_baseline(), args.gateway_id)
    print(json.dumps(merged, indent=2))
    if args.dry_run:
        print("Dry run: nothing was changed.")
        return 0
    if merged == current:
        print("The gateway already has this baseline.")
        return 0
    _rest("patch", url, {"properties": {"policies": merged}})
    print(f"Applied {len(merged)} gateway-wide policies.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
