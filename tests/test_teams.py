import json

import pytest

import teams
from teams import Catalog, parse_teams

CATALOG = Catalog(models={"chat": "Chat model"}, tools={"orders": "Orders tools"})
GROUP = "11111111-1111-1111-1111-111111111111"
APP = "22222222-2222-2222-2222-222222222222"


def team_file(name="alpha", models=("chat",), tools=(), members=None):
    members = members or [{"name": "devs", "principalId": GROUP, "principalType": "Group"}]
    return json.dumps(
        {"name": name, "owner": "leads", "models": list(models), "tools": list(tools), "members": members}
    )


def errors_for(**kwargs):
    return parse_teams({f"{kwargs.get('name', 'alpha')}.json": team_file(**kwargs)}, CATALOG)[1]


def test_repository_team_files_are_valid():
    found, errors = parse_teams(teams.read_team_files(), teams.load_catalog())
    assert errors == [] and found


def test_schema_matches_the_validator():
    schema = json.loads((teams.ROOT / "platform" / "team.schema.json").read_text())
    member = schema["$defs"]["member"]
    assert set(schema["properties"]) == teams.TEAM_KEYS
    assert set(member["properties"]) == teams.MEMBER_KEYS
    assert tuple(member["properties"]["principalType"]["enum"]) == teams.PRINCIPAL_TYPES
    assert all(ref.split(":")[1] in member["properties"]["principalId"]["pattern"] for ref in teams.PLATFORM_PRINCIPALS)


@pytest.mark.parametrize(
    ("kwargs", "expected"),
    [
        ({"models": ("gpt-unknown",)}, "isn't in platform/catalog.json"),
        ({"models": (), "tools": ()}, "grant at least one model or tool"),
        (
            {"members": [{"name": "devs", "principalId": GROUP, "principalType": "Group", "dailyBudgetUsd": 5}]},
            "a group can't have a budget",
        ),
        ({"members": [{"name": "x", "principalId": "not-a-guid", "principalType": "User"}]}, "principalId"),
        (
            {"members": [{"name": "agent", "principalId": "platform:apps", "principalType": "User"}]},
            "must be ServicePrincipal",
        ),
        (
            {
                "models": (),
                "tools": ("orders",),
                "members": [
                    {"name": "app", "principalId": APP, "principalType": "ServicePrincipal", "dailyBudgetUsd": 1}
                ],
            },
            "this team has no models",
        ),
    ],
)
def test_invalid_team_files_are_rejected(kwargs, expected):
    assert any(expected in e for e in errors_for(**kwargs))


def test_team_name_must_match_the_file_name():
    _, errors = parse_teams({"beta.json": team_file(name="alpha")}, CATALOG)
    assert any("the file is beta.json" in e for e in errors)


def test_one_identity_cannot_have_two_budgets():
    def app(budget):
        return [{"name": "app", "principalId": APP, "principalType": "ServicePrincipal", "dailyBudgetUsd": budget}]

    files = {"alpha.json": team_file(members=app(5)), "beta.json": team_file(name="beta", members=app(10))}
    assert any("one budget" in e for e in parse_teams(files, CATALOG)[1])


def test_render_drops_the_schema_and_formats_budgets_as_strings():
    member = {"name": "app", "principalId": APP.upper(), "principalType": "ServicePrincipal", "dailyBudgetUsd": 2.50}
    found, _ = parse_teams({"alpha.json": team_file(members=[member])}, CATALOG)
    assert teams.render(found) == [
        {
            "name": "alpha",
            "models": ["chat"],
            "tools": [],
            "members": [
                {"name": "app", "principalId": APP, "principalType": "ServicePrincipal", "dailyBudgetUsd": "2.5"}
            ],
        }
    ]


def test_diff_lists_granted_and_revoked_access_and_budget_changes():
    base, _ = parse_teams({"alpha.json": team_file(), "gone.json": team_file(name="gone")}, CATALOG)
    app = {"name": "app", "principalId": APP, "principalType": "ServicePrincipal", "dailyBudgetUsd": 3}
    head, _ = parse_teams({"alpha.json": team_file(tools=("orders",), members=[app])}, CATALOG)
    out = teams.diff_markdown(base, head)
    assert "| Granted | alpha | app |" in out and "MCP server `orders`" in out
    assert "| Revoked | gone | devs |" in out
    assert f"| alpha | app | `{APP}` | - | $3 a day |" in out


def test_diff_shows_a_member_pointed_at_another_principal():
    base, _ = parse_teams({"alpha.json": team_file()}, CATALOG)
    swapped = [{"name": "devs", "principalId": APP, "principalType": "ServicePrincipal"}]
    head, _ = parse_teams({"alpha.json": team_file(members=swapped)}, CATALOG)
    out = teams.diff_markdown(base, head)
    assert f"| Revoked | alpha | devs | `{GROUP}` (Group) |" in out
    assert f"| Granted | alpha | devs | `{APP}` (ServicePrincipal) |" in out


def test_diff_reports_no_changes():
    found, _ = parse_teams({"alpha.json": team_file()}, CATALOG)
    assert "No access changes" in teams.diff_markdown(found, found)


def test_stale_assignments_keep_granted_roles_and_ignore_other_roles_and_scopes():
    gateway = "/subscriptions/s/resourcegroups/rg/providers/microsoft.apimanagement/aigateways/gw"
    alias = f"{gateway}/workspaces/default/aliases/chat"

    def assignment(principal, role, scope=alias):
        return {
            "id": f"ra-{principal}-{role}",
            "scope": scope,
            "principalId": principal,
            "roleDefinitionId": f"/x/{role}",
        }

    granted = assignment(APP, teams.MODELS_USER)
    leftover = assignment(GROUP, teams.MODELS_USER)
    owner = assignment(GROUP, "8e3af657-a8ff-443c-a75c-2fe8c4bcb635")
    elsewhere = assignment(GROUP, teams.MODELS_USER, scope="/subscriptions/s")
    desired = {(alias, APP, teams.MODELS_USER)}
    stale = teams.stale_assignments([granted, leftover, owner, elsewhere], desired, {alias})
    assert stale == [leftover]


def test_prune_manages_every_gateway_asset_but_tool_servers_only_after_a_full_deployment():
    gw = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.ApiManagement/aigateways/gw/workspaces/default"
    assets = [f"{gw}/aliases/chat", f"{gw}/toolServers/orders", f"{gw}/toolServers/retired"]
    full = {"ACCESS_SCOPES": [f"{gw}/aliases/chat", f"{gw}/toolServers/orders"], "AI_GATEWAY_MCP_SERVERS": "orders"}
    assert teams.managed_scopes(full, assets) == {a.lower() for a in assets}
    infra_only = {"ACCESS_SCOPES": [f"{gw}/aliases/chat"], "AI_GATEWAY_MCP_SERVERS": ""}
    assert teams.managed_scopes(infra_only, assets) == {f"{gw}/aliases/chat".lower()}


def test_quickstart_shows_only_the_teams_assets():
    found, _ = parse_teams({"alpha.json": team_file()}, CATALOG)
    out = teams.quickstart(found[0], CATALOG, "https://gw.example/")
    assert '`https://gw.example/default/models/openai/v1`, with `"model": "chat"`' in out
    assert "toolservers" not in out
