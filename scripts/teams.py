"""Team access as code for Azure AI Gateway.

Each file in teams/ onboards one team: the Microsoft Entra principals in it, the model aliases and MCP servers from
platform/catalog.json they can call, and optional daily budgets per identity. Runtime API keys grant access to every
model and tool on a gateway, so teams on a shared gateway are kept apart by roles scoped to single assets instead.

  python scripts/teams.py validate                      check every team file
  python scripts/teams.py render                        print the teams as the Bicep 'teams' parameter
  python scripts/teams.py diff --base origin/main       Markdown summary of the access a change grants and revokes
  python scripts/teams.py quickstart <team>             a developer quick start for one team
  python scripts/teams.py prune <deployment> [--apply]  remove runtime roles that no team grants (reads Azure)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
TEAMS_DIR = ROOT / "teams"
CATALOG_FILE = ROOT / "platform" / "catalog.json"

PRINCIPAL_TYPES = ("User", "Group", "ServicePrincipal")
PLATFORM_PRINCIPALS = {
    "platform:deployer": "the identity that runs scripts/deploy.sh",
    "platform:apps": "the user-assigned identity of this deployment's container apps",
    "platform:returns-agent": "the user-assigned identity of the returns specialist agent",
    "platform:foundry-project": "the managed identity of this deployment's Foundry project",
}
# Managed identities are service principals. The deployer's type comes from the deployment (AZURE_PRINCIPAL_TYPE).
PLATFORM_SERVICE_PRINCIPALS = {"platform:apps", "platform:returns-agent", "platform:foundry-project"}
TEAM_KEYS = {"$schema", "name", "description", "owner", "models", "tools", "members"}
MEMBER_KEYS = {"name", "principalId", "principalType", "dailyBudgetUsd"}
TEAM_NAME = re.compile(r"^[a-z][a-z0-9-]{1,38}[a-z0-9]$")
MEMBER_NAME = re.compile(r"^[a-z][a-z0-9-]*$")
GUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

# Built-in runtime roles, with the same IDs in every tenant. Owner and Contributor don't grant runtime access.
MODELS_USER = "a6b68e3d-a1f0-4c60-8678-237c050cf4ea"
TOOLS_USER = "dce03f8d-857f-4e40-a90d-67770fa6ecd2"
GATEWAY_USER = "caad7a21-134e-43f4-a550-c5ffc17e051c"
RUNTIME_ROLES = {
    MODELS_USER: "AI Gateway Models User",
    TOOLS_USER: "AI Gateway Tools User",
    GATEWAY_USER: "AI Gateway User",
}
GATEWAY_SCOPE = "https://ai.gateway.azure.com/.default"


@dataclass(frozen=True)
class Catalog:
    models: dict[str, str]
    tools: dict[str, str]


@dataclass(frozen=True)
class Member:
    name: str
    principal_id: str
    principal_type: str
    daily_budget_usd: Decimal | None = None


@dataclass(frozen=True)
class Team:
    name: str
    owner: str
    description: str
    models: tuple[str, ...]
    tools: tuple[str, ...]
    members: tuple[Member, ...]


def load_catalog(path: Path = CATALOG_FILE) -> Catalog:
    data = json.loads(path.read_text())
    models = {m["alias"]: m.get("description", "") for m in data.get("models", [])}
    tools = {t["server"]: t.get("description", "") for t in data.get("tools", [])}
    if len(models) != 1 or not tools:
        raise ValueError(f"{path.name}: the templates publish exactly one model alias and at least one MCP server")
    return Catalog(models=models, tools=tools)


def load_budget_ceiling() -> Decimal | None:
    """The gateway-wide daily cost limit per caller in platform/baseline-policies.json. Every policy can block a call,
    so a team budget above it would never be reached."""
    from apply_baseline import daily_cost_ceiling, load_baseline

    ceiling = daily_cost_ceiling(load_baseline())
    return None if ceiling is None else Decimal(str(ceiling))


def _names(value: Any, field: str, known: dict[str, str] | None, errors: list[str]) -> tuple[str, ...]:
    if value is None:
        return ()
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        errors.append(f"'{field}' must be a list of names")
        return ()
    if len(set(value)) != len(value):
        errors.append(f"'{field}' lists a name twice")
    if known is not None:
        errors.extend(f"'{field}' has '{v}', which isn't in platform/catalog.json" for v in value if v not in known)
    return tuple(dict.fromkeys(value))


def _member(data: Any, index: int, errors: list[str]) -> Member | None:
    where = f"members[{index}]"
    if not isinstance(data, dict):
        errors.append(f"{where} must be an object")
        return None
    errors.extend(f"{where} has an unknown key '{k}'" for k in sorted(set(data) - MEMBER_KEYS))
    name, principal_id, principal_type = data.get("name"), data.get("principalId"), data.get("principalType")
    if not isinstance(name, str) or not MEMBER_NAME.match(name):
        errors.append(f"{where}.name must be lowercase letters, digits and hyphens")
    if not isinstance(principal_id, str) or not (GUID.match(principal_id) or principal_id in PLATFORM_PRINCIPALS):
        errors.append(f"{where}.principalId must be an object ID or one of {', '.join(PLATFORM_PRINCIPALS)}")
    if principal_type not in PRINCIPAL_TYPES:
        errors.append(f"{where}.principalType must be one of {', '.join(PRINCIPAL_TYPES)}")
    elif principal_id in PLATFORM_SERVICE_PRINCIPALS and principal_type != "ServicePrincipal":
        errors.append(f"{where}: {principal_id} is a managed identity, so principalType must be ServicePrincipal")
    budget = data.get("dailyBudgetUsd")
    amount = None
    if budget is not None:
        if isinstance(budget, bool) or not isinstance(budget, int | float) or budget <= 0:
            errors.append(f"{where}.dailyBudgetUsd must be a number greater than 0")
        elif principal_type == "Group":
            errors.append(f"{where}: a group can't have a budget, because each identity gets its own counter")
        else:
            amount = Decimal(str(budget))
    if not (isinstance(name, str) and isinstance(principal_id, str) and principal_type in PRINCIPAL_TYPES):
        return None
    return Member(name, principal_id.lower(), principal_type, amount)


def parse_team(data: Any, expected_name: str, catalog: Catalog | None) -> tuple[Team | None, list[str]]:
    """Parses one team file. With catalog=None, asset names aren't checked (used for the base of a diff)."""
    errors: list[str] = []
    if not isinstance(data, dict):
        return None, ["the file must hold a JSON object"]
    errors.extend(f"unknown key '{k}'" for k in sorted(set(data) - TEAM_KEYS))
    name, owner, description = data.get("name"), data.get("owner"), data.get("description", "")
    if not isinstance(name, str) or not TEAM_NAME.match(name):
        errors.append("'name' must be 3-40 lowercase letters, digits and hyphens")
    elif name != expected_name:
        errors.append(f"'name' is '{name}' but the file is {expected_name}.json")
    if not isinstance(owner, str) or not owner.strip():
        errors.append("'owner' is required")
    if not isinstance(description, str):
        errors.append("'description' must be text")
    models = _names(data.get("models"), "models", catalog.models if catalog else None, errors)
    tools = _names(data.get("tools"), "tools", catalog.tools if catalog else None, errors)
    if not models and not tools:
        errors.append("grant at least one model or tool")

    raw_members = data.get("members")
    members: list[Member] = []
    if not isinstance(raw_members, list) or not raw_members:
        errors.append("'members' must list at least one principal")
    else:
        for i, raw in enumerate(raw_members):
            member = _member(raw, i, errors)
            if member:
                members.append(member)
    seen_names = [m.name for m in members]
    if len(set(seen_names)) != len(seen_names):
        errors.append("two members have the same name")
    seen_ids = [m.principal_id for m in members]
    if len(set(seen_ids)) != len(seen_ids):
        errors.append("a principal is listed twice")
    if not models and any(m.daily_budget_usd for m in members):
        errors.append("budgets apply to model calls, and this team has no models")

    if errors:
        return None, errors
    return Team(name, owner.strip(), description, models, tools, tuple(members)), []


def _check_across_teams(teams: list[Team], ceiling: Decimal | None = None) -> list[str]:
    errors: list[str] = []
    types: dict[str, tuple[str, str]] = {}
    budgets: dict[str, tuple[Decimal, str]] = {}
    for team in teams:
        for m in team.members:
            seen = types.setdefault(m.principal_id, (m.principal_type, team.name))
            if seen[0] != m.principal_type:
                errors.append(f"{m.principal_id} is a {seen[0]} in {seen[1]} but a {m.principal_type} in {team.name}")
            if m.daily_budget_usd is not None:
                if ceiling is not None and m.daily_budget_usd > ceiling:
                    errors.append(
                        f"teams/{team.name}.json: {m.name} has a budget of {m.daily_budget_usd}, above the "
                        f"gateway-wide limit of {ceiling} a day in platform/baseline-policies.json, which blocks first"
                    )
                prior = budgets.setdefault(m.principal_id, (m.daily_budget_usd, team.name))
                if prior[0] != m.daily_budget_usd:
                    errors.append(
                        f"{m.principal_id} has a budget of {prior[0]} in {prior[1]} and {m.daily_budget_usd} in "
                        f"{team.name}: an identity has one budget, so give it the same amount in both"
                    )
    return errors


def parse_teams(
    files: dict[str, str], catalog: Catalog | None, ceiling: Decimal | None = None
) -> tuple[list[Team], list[str]]:
    """Parses team files given as {file name: content}. Returns the valid teams and every error, by file."""
    teams: list[Team] = []
    errors: list[str] = []
    for file_name in sorted(files):
        try:
            data = json.loads(files[file_name])
        except json.JSONDecodeError as exc:
            errors.append(f"teams/{file_name}: not valid JSON ({exc.msg}, line {exc.lineno})")
            continue
        team, team_errors = parse_team(data, Path(file_name).stem, catalog)
        errors.extend(f"teams/{file_name}: {e}" for e in team_errors)
        if team:
            teams.append(team)
    errors.extend(_check_across_teams(teams, ceiling))
    return teams, errors


def read_team_files(teams_dir: Path = TEAMS_DIR) -> dict[str, str]:
    return {p.name: p.read_text() for p in sorted(teams_dir.glob("*.json"))}


def read_team_files_at(ref: str) -> dict[str, str]:
    """Team files at a git ref, for example the base branch of a pull request."""

    def git(*args: str) -> str:
        return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout

    names = [n for n in git("ls-tree", "--name-only", ref, "teams/").splitlines() if n.endswith(".json")]
    return {Path(n).name: git("show", f"{ref}:{n}") for n in names}


def _amount(value: Decimal) -> str:
    return format(value.normalize(), "f")


def render(teams: list[Team]) -> list[dict[str, Any]]:
    """The Bicep 'teams' parameter. Budgets are strings: ARM templates have no decimal numbers."""
    return [
        {
            "name": t.name,
            "models": list(t.models),
            "tools": list(t.tools),
            "members": [
                {
                    "name": m.name,
                    "principalId": m.principal_id,
                    "principalType": m.principal_type,
                    **({"dailyBudgetUsd": _amount(m.daily_budget_usd)} if m.daily_budget_usd else {}),
                }
                for m in t.members
            ],
        }
        for t in teams
    ]


def _grants(teams: list[Team]) -> dict[tuple[str, str, str, str, str, str], str]:
    """{(team, member, principal ID, principal type, kind, asset): principal label}, for every model and tool a member
    can call. The principal is part of the key, so pointing a member at another principal shows as revoke + grant."""
    grants = {}
    for t in teams:
        for m in t.members:
            label = f"`{m.principal_id}` ({m.principal_type})"
            for kind, assets in (("model", t.models), ("MCP server", t.tools)):
                for asset in assets:
                    grants[(t.name, m.name, m.principal_id, m.principal_type, kind, asset)] = label
    return grants


def _budgets(teams: list[Team]) -> dict[tuple[str, str, str], Decimal | None]:
    return {(t.name, m.name, m.principal_id): m.daily_budget_usd for t in teams for m in t.members if t.models}


def diff_markdown(base: list[Team], head: list[Team]) -> str:
    before, after = _grants(base), _grants(head)
    rows = [("Granted", k, after[k]) for k in sorted(after.keys() - before.keys())]
    rows += [("Revoked", k, before[k]) for k in sorted(before.keys() - after.keys())]
    old_budgets, new_budgets = _budgets(base), _budgets(head)
    budget_rows = [
        (key, old_budgets.get(key), new_budgets.get(key))
        for key in sorted(old_budgets.keys() | new_budgets.keys())
        if old_budgets.get(key) != new_budgets.get(key)
    ]
    if not rows and not budget_rows:
        return "### Team access\n\nNo access changes.\n"

    def usd(value: Decimal | None) -> str:
        return f"${_amount(value)} a day" if value else "gateway default"

    lines = ["### Team access", ""]
    if rows:
        lines += ["| Change | Team | Member | Principal | Can call |", "|---|---|---|---|---|"]
        lines += [f"| {c} | {t} | {m} | {p} | {k} `{a}` |" for c, (t, m, _, _, k, a), p in rows]
        lines.append("")
    if budget_rows:
        lines += ["| Team | Member | Principal | Daily budget before | After |", "|---|---|---|---|---|"]
        lines += [
            f"| {t} | {m} | `{p}` | {usd(b) if (t, m, p) in old_budgets else '-'} | "
            f"{usd(a) if (t, m, p) in new_budgets else '-'} |"
            for (t, m, p), b, a in budget_rows
        ]
        lines.append("")
    return "\n".join(lines)


def quickstart(team: Team, catalog: Catalog, gateway_url: str) -> str:
    url = gateway_url.rstrip("/")
    lines = [
        f"# Quick start: {team.name}",
        "",
        team.description or "",
        "",
        f"Owner: {team.owner}. Members: "
        + ", ".join(
            f"{m.name} ({PLATFORM_PRINCIPALS.get(m.principal_id, f'{m.principal_type} {m.principal_id}')})"
            for m in team.members
        )
        + ".",
        "",
        "## What you can call",
        "",
        "| Kind | Name | What it is | Endpoint |",
        "|---|---|---|---|",
    ]
    lines += [
        f'| Model | `{a}` | {catalog.models[a]} | `{url}/default/models/openai/v1`, with `"model": "{a}"` |'
        for a in team.models
    ]
    lines += [f"| MCP server | `{s}` | {catalog.tools[s]} | `{url}/default/toolservers/{s}/mcp` |" for s in team.tools]
    lines += [
        "",
        "Every call needs a Microsoft Entra token for the gateway, with no keys: `az login` on your machine, a managed",
        "identity in Azure. Calls to anything else on the gateway return `403`.",
        "",
    ]
    if team.models:
        alias = team.models[0]
        lines += [
            "## Call a model",
            "",
            "```bash",
            f'TOKEN="$(az account get-access-token --scope {GATEWAY_SCOPE} --query accessToken -o tsv)"',
            f'curl -s "{url}/default/models/openai/v1/chat/completions" -H "Authorization: Bearer $TOKEN" \\',
            f'  -H "Content-Type: application/json" -d \'{{"model": "{alias}", "messages": '
            '[{"role": "user", "content": "Hello"}]}\'',
            "```",
            "",
            "```python",
            "# pip install openai azure-identity",
            "from azure.identity import DefaultAzureCredential, get_bearer_token_provider",
            "from openai import OpenAI",
            "",
            f'token = get_bearer_token_provider(DefaultAzureCredential(), "{GATEWAY_SCOPE}")',
            "# Tokens last about an hour: create the client again, or call token(), in long-running apps.",
            f'client = OpenAI(base_url="{url}/default/models/openai/v1", api_key=token())',
            f'reply = client.chat.completions.create(model="{alias}", '
            'messages=[{"role": "user", "content": "Hello"}])',
            "print(reply.choices[0].message.content)",
            "```",
            "",
        ]
    if team.tools:
        lines += [
            "## Use the tools",
            "",
            "Point any MCP client (Streamable HTTP) at the endpoint above, with the header",
            "`Authorization: Bearer <token>`. For an Agent Framework example, see",
            "`clients/aca-agent/gateway_agent.py`.",
            "",
        ]
    return "\n".join(lines)


def _az(*args: str) -> Any:
    result = subprocess.run(["az", *args, "-o", "json"], check=True, capture_output=True, text=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def stale_assignments(
    assignments: list[dict[str, Any]], desired: set[tuple[str, str, str]], scopes: set[str]
) -> list[dict[str, Any]]:
    """Runtime role assignments on the managed scopes that the deployment didn't grant."""
    stale = []
    for a in assignments:
        scope = a["scope"].lower()
        role = a["roleDefinitionId"].rsplit("/", 1)[-1].lower()
        if scope in scopes and role in RUNTIME_ROLES and (scope, a["principalId"].lower(), role) not in desired:
            stale.append(a)
    return stale


def _gateway_assets(gateway_id: str) -> list[str]:
    """Every model alias and MCP server on the gateway, including ones no longer in platform/catalog.json."""
    ids = []
    for kind in ("aliases", "toolServers"):
        url = f"https://management.azure.com{gateway_id}/workspaces/default/{kind}?api-version=2026-11-01"
        while url:
            page = _az("rest", "--method", "get", "--url", url)
            ids += [item["id"] for item in page.get("value", [])]
            url = page.get("nextLink")
    return ids


def managed_scopes(outputs: dict[str, Any], assets: list[str]) -> set[str]:
    """The assets whose runtime roles prune manages. Every asset on the gateway, so a server removed from the catalog
    loses its grants too, but only after a full deployment: one without the apps doesn't output the tool grants."""
    scopes = {s.lower() for s in outputs["ACCESS_SCOPES"] if s}
    full = bool(outputs.get("AI_GATEWAY_MCP_SERVERS"))
    return scopes | {a.lower() for a in assets if full or "/toolservers/" not in a.lower()}


def prune(deployment: str, apply: bool) -> int:
    from outputs import deployment_outputs

    outputs = deployment_outputs(deployment)
    desired = {
        (g["scope"].lower(), g["principalId"].lower(), g["roleDefinitionId"].lower()) for g in outputs["ACCESS_GRANTS"]
    }
    scopes = managed_scopes(outputs, _gateway_assets(outputs["AI_GATEWAY_ID"]))
    # --fill-principal-name false: no Microsoft Graph call, which a short-lived CI sign-in may no longer allow
    assignments = [
        a
        for scope in sorted(scopes)
        for a in _az("role", "assignment", "list", "--scope", scope, "--fill-principal-name", "false")
    ]
    stale = stale_assignments(assignments, desired, scopes)
    for a in stale:
        role = RUNTIME_ROLES[a["roleDefinitionId"].rsplit("/", 1)[-1].lower()]
        action = "Removing" if apply else "Would remove"
        print(f"{action} {role} for {a['principalId']} on {a['scope'].rsplit('/', 1)[-1]}")
    if stale and apply:
        _az("role", "assignment", "delete", "--ids", *[a["id"] for a in stale])
    if not stale:
        print("No runtime role assignments to remove: every one comes from a team file.")
    elif not apply:
        print("Dry run. Add --apply to remove them.")
    return 0


def _gateway_url_from_env() -> str:
    if os.environ.get("AI_GATEWAY_URL"):
        return os.environ["AI_GATEWAY_URL"]
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if line.startswith("AI_GATEWAY_URL="):
                return line.split("=", 1)[1]
    return "https://<gateway-host>"


def _load_or_exit(catalog: Catalog) -> list[Team]:
    teams, errors = parse_teams(read_team_files(), catalog, load_budget_ceiling())
    if errors:
        print("\n".join(f"ERROR {e}" for e in errors), file=sys.stderr)
        sys.exit(1)
    return teams


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate", help="check every team file")
    sub.add_parser("render", help="print the Bicep 'teams' parameter")
    diff = sub.add_parser("diff", help="Markdown summary of access changes against a git ref")
    diff.add_argument("--base", required=True, help="git ref to compare with, for example origin/main")
    qs = sub.add_parser("quickstart", help="a developer quick start for one team")
    qs.add_argument("team")
    qs.add_argument("--gateway-url", help="defaults to AI_GATEWAY_URL or .env")
    pr = sub.add_parser("prune", help="remove runtime role assignments that no team grants")
    pr.add_argument("deployment", help="name of the subscription deployment, AZURE_ENV_NAME")
    pr.add_argument("--apply", action="store_true", help="remove them; without it, only list them")
    args = parser.parse_args(argv)

    if args.command == "prune":
        return prune(args.deployment, args.apply)
    catalog = load_catalog()
    teams = _load_or_exit(catalog)
    if args.command == "validate":
        members = sum(len(t.members) for t in teams)
        print(f"{len(teams)} teams, {members} members: valid")
    elif args.command == "render":
        print(json.dumps(render(teams)))
    elif args.command == "diff":
        base, _ = parse_teams(read_team_files_at(args.base), None)
        print(diff_markdown(base, teams))
    elif args.command == "quickstart":
        team = next((t for t in teams if t.name == args.team), None)
        if not team:
            print(f"ERROR no team '{args.team}' in teams/", file=sys.stderr)
            return 1
        print(quickstart(team, catalog, args.gateway_url or _gateway_url_from_env()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
