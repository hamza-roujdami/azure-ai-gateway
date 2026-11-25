"""Read-only compliance check for an Azure AI Gateway that many teams share.

  python scripts/check_gateway.py <gateway resource ID> [--expect-private] [--json]

It reads the gateway with your Azure sign-in, changes nothing, and fails when it finds:
  - active runtime API keys, including the built-in master key: each one can call every model and tool on the gateway
  - runtime roles granted on the whole gateway, on a workspace, or on anything above the gateway
  - model aliases without a token or cost limit, or without content safety
  - MCP servers without a request rate limit
  - telemetry that captures prompt and response payloads
  - public network access, with --expect-private
It warns when no telemetry exporter exists, or when a model provider doesn't sign in with a managed identity.
Policies count when they're on the asset, on the alias's backend model, or on the workspace.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from typing import Any

from teams import RUNTIME_ROLES

API_VERSION = "2026-11-01"
GATEWAY_ID = re.compile(
    r"^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ApiManagement/aigateways/[^/]+$", re.I
)


@dataclass(frozen=True)
class Finding:
    status: str  # PASS, WARN or FAIL
    check: str
    message: str


def _policy_types(resource: dict[str, Any]) -> set[str]:
    return {p.get("type", "") for p in (resource.get("properties") or {}).get("policies") or []}


def _name(resource: dict[str, Any]) -> str:
    return resource.get("name") or resource.get("id", "").rsplit("/", 1)[-1]


def check_api_keys(keys: list[dict[str, Any]]) -> Finding:
    active = [k for k in keys if ((k.get("properties") or {}).get("state") or "active").lower() == "active"]
    if active:
        names = ", ".join(sorted(_name(k) for k in active))
        return Finding(
            "FAIL",
            "no-runtime-api-keys",
            f"{len(active)} active runtime API keys ({names}) can call every asset. Every gateway has a built-in "
            "master key: suspend it with az aigateway api-key update -n master --state suspended",
        )
    if keys:
        return Finding("PASS", "no-runtime-api-keys", f"No active runtime API keys ({len(keys)} suspended)")
    return Finding("PASS", "no-runtime-api-keys", "No runtime API keys: callers use Microsoft Entra ID")


def check_runtime_roles(assignments: list[dict[str, Any]], gateway_id: str) -> Finding:
    gateway = gateway_id.lower().rstrip("/")
    broad = []
    for a in assignments:
        role = a.get("roleDefinitionId", "").rsplit("/", 1)[-1].lower()
        if role not in RUNTIME_ROLES:
            continue
        scope = a.get("scope", "").lower().rstrip("/")
        # The listing holds the gateway's own scope, its workspaces, and everything above it, including management
        # groups, whose IDs aren't a prefix of the gateway's. Anything not below the gateway reaches every asset.
        below = scope.startswith(gateway + "/")
        depth = scope.count("/") - gateway.count("/")
        on_workspace = scope.startswith(gateway + "/workspaces/") and depth == 2
        if not below or on_workspace:
            broad.append(f"{RUNTIME_ROLES[role]} for {a.get('principalName') or a.get('principalId')} on {scope}")
    if broad:
        return Finding("FAIL", "runtime-roles-scoped", "Runtime roles cover every asset: " + "; ".join(sorted(broad)))
    return Finding("PASS", "runtime-roles-scoped", "Runtime roles are granted on single assets only")


def check_models(workspaces: list[dict[str, Any]]) -> list[Finding]:
    findings = []
    aliases = 0
    for ws in workspaces:
        inherited = _policy_types(ws)
        models = {m.get("id", "").lower(): _policy_types(m) for m in ws.get("models", [])}
        for alias in ws.get("aliases", []):
            aliases += 1
            backends = (alias.get("properties") or {}).get("backendModels") or []
            types = inherited | _policy_types(alias)
            for b in backends:
                types |= models.get(b.get("resourceId", "").lower(), set())
            if not types & {"tokenLimit", "costLimit"}:
                findings.append(Finding("FAIL", "model-limits", f"Alias '{_name(alias)}' has no token or cost limit"))
            if "contentSafety" not in types:
                findings.append(Finding("FAIL", "content-safety", f"Alias '{_name(alias)}' has no content safety"))
    if not aliases:
        return [Finding("WARN", "model-limits", "No model aliases to check")]
    if not findings:
        findings.append(Finding("PASS", "model-limits", f"{aliases} model aliases have limits and content safety"))
    return findings


def check_tools(workspaces: list[dict[str, Any]]) -> list[Finding]:
    findings = []
    servers = 0
    for ws in workspaces:
        inherited = _policy_types(ws)
        for server in ws.get("toolServers", []):
            servers += 1
            if "requestRateLimit" not in inherited | _policy_types(server):
                findings.append(
                    Finding("FAIL", "tool-limits", f"MCP server '{_name(server)}' has no request rate limit")
                )
    if not findings:
        findings.append(Finding("PASS", "tool-limits", f"{servers} MCP servers have a request rate limit"))
    return findings


def check_telemetry(workspaces: list[dict[str, Any]]) -> Finding:
    exporters = [e for ws in workspaces for e in ws.get("telemetryExporters", [])]
    if not exporters:
        return Finding("WARN", "telemetry", "No telemetry exporter: usage and denials aren't recorded")
    capturing = [_name(e) for e in exporters if (e.get("properties") or {}).get("payloadCapture")]
    if capturing:
        return Finding("FAIL", "telemetry", f"Exporters capture prompts and responses: {', '.join(capturing)}")
    return Finding("PASS", "telemetry", f"{len(exporters)} telemetry exporters, payload capture off")


def check_providers(workspaces: list[dict[str, Any]]) -> Finding:
    with_secrets = [
        _name(p)
        for ws in workspaces
        for p in ws.get("modelProviders", [])
        if "managedIdentity" not in ((p.get("properties") or {}).get("authentication") or {})
    ]
    if with_secrets:
        return Finding(
            "WARN",
            "backend-identity",
            f"Providers that don't use a managed identity: {', '.join(with_secrets)}. "
            "Fine for providers outside Azure; use one where the backend supports it",
        )
    return Finding("PASS", "backend-identity", "Model providers sign in with a managed identity")


def check_network(gateway: dict[str, Any], expect_private: bool) -> Finding:
    access = (gateway.get("properties") or {}).get("publicNetworkAccess") or "Enabled"
    if expect_private and access != "Disabled":
        return Finding("FAIL", "public-access", f"Public network access is {access}; expected Disabled")
    return Finding("PASS", "public-access", f"Public network access is {access}")


def evaluate(snapshot: dict[str, Any], expect_private: bool = False) -> list[Finding]:
    workspaces = snapshot["workspaces"]
    return [
        check_api_keys(snapshot["apiKeys"]),
        check_runtime_roles(snapshot["roleAssignments"], snapshot["gateway"]["id"]),
        *check_models(workspaces),
        *check_tools(workspaces),
        check_telemetry(workspaces),
        check_providers(workspaces),
        check_network(snapshot["gateway"], expect_private),
    ]


def _az(*args: str) -> Any:
    result = subprocess.run(["az", *args, "-o", "json"], check=True, capture_output=True, text=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def _get(path: str) -> dict[str, Any]:
    return _az("rest", "--method", "get", "--url", f"https://management.azure.com{path}?api-version={API_VERSION}")


def _list(path: str) -> list[dict[str, Any]]:
    url = f"https://management.azure.com{path}?api-version={API_VERSION}"
    items: list[dict[str, Any]] = []
    while url:
        page = _az("rest", "--method", "get", "--url", url)
        items += page.get("value", [])
        url = page.get("nextLink")
    return items


def collect(gateway_id: str) -> dict[str, Any]:
    """Reads everything evaluate() needs. Only GET calls and role assignment listings."""
    gateway = _get(gateway_id)
    try:
        listed = _list(f"{gateway_id}/workspaces")
    except subprocess.CalledProcessError:
        # The CLI only addresses the default workspace; fall back to it if listing isn't available.
        listed = [_get(f"{gateway_id}/workspaces/default")]
    workspaces = []
    for ws in listed:
        ws_id = ws["id"]
        providers = _list(f"{ws_id}/modelProviders")
        workspaces.append(
            {
                **ws,
                "aliases": _list(f"{ws_id}/aliases"),
                "modelProviders": providers,
                "models": [m for p in providers for m in _list(f"{p['id']}/models")],
                "toolServers": _list(f"{ws_id}/toolServers"),
                "telemetryExporters": _list(f"{ws_id}/telemetryExporters"),
            }
        )
    assignments = {
        a["id"]: a
        for a in _az(
            "role", "assignment", "list", "--scope", gateway_id, "--include-inherited", "--fill-principal-name", "false"
        )
    }
    for ws in workspaces:
        assignments.update(
            {
                a["id"]: a
                for a in _az("role", "assignment", "list", "--scope", ws["id"], "--fill-principal-name", "false")
            }
        )
    return {
        "gateway": gateway,
        "apiKeys": _list(f"{gateway_id}/apiKeys"),
        "workspaces": workspaces,
        "roleAssignments": list(assignments.values()),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("gateway_id", help="/subscriptions/.../providers/Microsoft.ApiManagement/aigateways/<name>")
    parser.add_argument("--expect-private", action="store_true", help="fail if public network access is on")
    parser.add_argument("--json", action="store_true", help="print the findings as JSON")
    args = parser.parse_args(argv)
    if not GATEWAY_ID.match(args.gateway_id):
        parser.error("gateway_id must be the gateway's full Azure resource ID")

    try:
        findings = evaluate(collect(args.gateway_id), args.expect_private)
    except subprocess.CalledProcessError as exc:
        print(f"ERROR reading the gateway: {exc.stderr.strip() or exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps([asdict(f) for f in findings], indent=2))
    else:
        for f in findings:
            print(f"  {f.status:<4}  {f.check:<20} {f.message}")
        counts = {s: sum(f.status == s for f in findings) for s in ("PASS", "WARN", "FAIL")}
        print(f"\n{counts['PASS']} passed, {counts['WARN']} warnings, {counts['FAIL']} failed")
    return 1 if any(f.status == "FAIL" for f in findings) else 0


if __name__ == "__main__":
    sys.exit(main())
