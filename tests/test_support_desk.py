import httpx
import pytest
from openai import APIStatusError

import summarize


def gateway_error(status, body, headers=None):
    request = httpx.Request("POST", "https://gw.example/default/models/openai/v1/chat/completions")
    response = httpx.Response(status, headers=headers or {}, json=body, request=request)
    return APIStatusError(str(body), response=response, body=body)


@pytest.mark.parametrize(
    ("status", "body", "headers", "expected"),
    [
        (401, {"error": "Unauthorized"}, None, "az login"),
        (403, {"error": {"code": "LlmCostQuotaExceeded"}}, None, "budget"),
        (403, {"error": "Access denied"}, None, "team file"),
        (429, {"error": "Too many tokens"}, {"retry-after": "12"}, "Retry after 12 seconds"),
        (400, {"error": "Blocked by content safety"}, None, "content safety"),
    ],
)
def test_explain_tells_the_developer_what_to_do(status, body, headers, expected):
    assert expected in summarize.explain(gateway_error(status, body, headers))


def test_summarize_sends_the_alias_and_the_ticket():
    sent = {}

    class Completions:
        def create(self, **kwargs):
            sent.update(kwargs)
            message = type("M", (), {"content": "Late order; offer express."})
            return type("R", (), {"choices": [type("C", (), {"message": message})]})

    client = type("Client", (), {"chat": type("Chat", (), {"completions": Completions()})})
    assert summarize.summarize(client, "chat", "ticket text") == "Late order; offer express."
    assert sent["model"] == "chat" and sent["messages"][-1] == {"role": "user", "content": "ticket text"}
