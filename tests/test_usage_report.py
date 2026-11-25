from usage_report import build_rows, markdown

MEMBERS = [
    {"team": "support-desk", "member": "developer", "principalId": "AAAA"},
    {"team": "coding-agents", "member": "developer", "principalId": "aaaa"},
    {"team": "order-assistant", "member": "agent", "principalId": "bbbb"},
]


def test_rows_are_per_identity_with_every_team_it_belongs_to():
    results = [
        {"ObjectId": "aaaa", "Requests": 10, "ModelCalls": 4, "ToolCalls": 2, "Denied": 2, "CostUsd": 0.01},
        {"ObjectId": "bbbb", "Requests": 3, "ModelCalls": 2, "ToolCalls": 1, "Throttled": 1, "CostUsd": 0.002},
        {"ObjectId": "", "Requests": 2},
        {"ObjectId": "cccc", "Requests": 1},
    ]
    rows = {(r.teams, r.members): r.values for r in build_rows(results, MEMBERS)}
    assert rows[("coding-agents, support-desk", "developer")]["Denied"] == 2
    assert rows[("order-assistant", "agent")]["Throttled"] == 1
    assert rows[("(not in a team file)", "no token")]["Requests"] == 2
    assert rows[("(not in a team file)", "unknown identity")]["Requests"] == 1


def test_markdown_formats_cost_and_handles_no_traffic():
    rows = build_rows([{"ObjectId": "bbbb", "Requests": 3, "CostUsd": 0.0021}], MEMBERS)
    out = markdown(rows, 24)
    assert "| order-assistant | agent | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0.0021 |" in out
    assert "No gateway traffic" in markdown([], 24)
