import asyncio
import json

import pytest

import returns_agent


@pytest.mark.parametrize(
    ("text", "decision"),
    [
        ('{"decision": "Replacement", "rationale": "Arrived broken."}', "replacement"),
        ('Sure! ```json\n{"decision": "refund", "rationale": "Within 14 days."}\n```', "refund"),
        ('{"decision": "give them a car", "rationale": "x"}', "escalate"),
        ("I can't decide.", "escalate"),
        ("", "escalate"),
    ],
)
def test_only_allowed_decisions_come_back(text, decision):
    assert returns_agent.parse_recommendation(text)["decision"] == decision


def test_server_exposes_one_tool():
    names = {t.name for t in asyncio.run(returns_agent.mcp.list_tools())}
    assert names == {"recommend_return"}


def test_recommend_return_sends_the_case_and_wraps_the_answer(monkeypatch):
    seen = {}

    class FakeResult:
        text = '{"decision": "repair", "rationale": "Fault after 3 months: warranty."}'

    class FakeAgent:
        async def run(self, prompt):
            seen.update(json.loads(prompt))
            return FakeResult()

    monkeypatch.setattr(returns_agent, "specialist", lambda: FakeAgent())
    out = asyncio.run(returns_agent.recommend_return("1003", "GIZMO-1", "delivered", "stopped working", 90))
    assert seen == {
        "order_id": "1003",
        "sku": "GIZMO-1",
        "order_status": "delivered",
        "reason": "stopped working",
        "days_since_delivery": 90,
    }
    assert out["decision"] == "repair" and out["policy"] == returns_agent.POLICY_VERSION
