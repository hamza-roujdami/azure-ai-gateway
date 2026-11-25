import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("AI_GATEWAY_URL", "https://aigw-x.swedencentral-01.ai.gateway.azure.com/")
    import app

    async def fake_run_agent(message: str) -> str:
        return f"echo: {message}"

    monkeypatch.setattr(app, "run_agent", fake_run_agent)
    with TestClient(app.app) as c:
        yield c


def test_settings_build_gateway_urls(monkeypatch):
    monkeypatch.setenv("AI_GATEWAY_URL", "https://gw.example/")
    from gateway_agent import Settings

    s = Settings()
    assert s.model_base_url == "https://gw.example/default/models/openai/v1/"
    assert s.mcp_url == "https://gw.example/default/toolservers/orders/mcp"
    assert s.ai_gateway_model == "chat"


def test_chat_returns_the_agent_answer(client):
    r = client.post("/chat", json={"message": "status of 1001?"})
    assert r.status_code == 200 and r.json() == {"answer": "echo: status of 1001?"}


def test_chat_rejects_empty_message(client):
    assert client.post("/chat", json={"message": ""}).status_code == 422


def test_healthz(client):
    assert client.get("/healthz").json() == {"status": "ok"}


def test_open_agent_gives_openai_an_async_token_provider(monkeypatch):
    """The OpenAI client awaits api_key before each request; a sync provider fails every model call."""
    import asyncio
    import inspect

    import gateway_agent

    captured = {}

    class FakeClient:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    class FakeTool:
        def __init__(self, **kwargs):
            captured["headers"] = kwargs["header_provider"]({})

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

    class FakeCredential:
        def get_token(self, *scopes, **kwargs):
            from azure.core.credentials import AccessToken

            return AccessToken("tok-123", 9999999999)

    monkeypatch.setattr(gateway_agent, "OpenAIChatClient", FakeClient)
    monkeypatch.setattr(gateway_agent, "MCPStreamableHTTPTool", FakeTool)
    monkeypatch.setattr(gateway_agent, "Agent", lambda **kwargs: kwargs)
    monkeypatch.setenv("AI_GATEWAY_URL", "https://gw.example")

    async def run():
        async with gateway_agent.open_agent(gateway_agent.Settings(), FakeCredential()):
            assert inspect.iscoroutinefunction(captured["api_key"])
            assert await captured["api_key"]() == "tok-123"

    asyncio.run(run())
    assert captured["headers"] == {"Authorization": "Bearer tok-123"}
    assert captured["base_url"] == "https://gw.example/default/models/openai/v1/"
