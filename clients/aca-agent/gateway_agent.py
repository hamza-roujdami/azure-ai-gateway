"""An Agent Framework agent whose model AND tool calls all go through the AI gateway, with no keys.

- Model: the gateway's OpenAI-compatible endpoint, called with the alias (e.g. "chat").
- Tools:  one gateway MCP endpoint per MCP server it's granted: orders (an MCP server), shipping (a REST API published
          from its OpenAPI description), and returns (a specialist agent behind an MCP tool).
All send a Microsoft Entra token for the gateway's audience. In Container Apps the token comes from the app's
managed identity (AZURE_CLIENT_ID); on a laptop, from `az login`. The token provider caches and refreshes it.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import AsyncExitStack, asynccontextmanager

from agent_framework import Agent, MCPStreamableHTTPTool
from agent_framework.openai import OpenAIChatClient
from azure.core.credentials import TokenCredential
from azure.identity import get_bearer_token_provider
from pydantic_settings import BaseSettings

GATEWAY_SCOPE = "https://ai.gateway.azure.com/.default"

INSTRUCTIONS = """
You are an order-support assistant. Use the tools; never guess order, stock, or shipping data.
- orders: order status, items, and stock levels.
- shipping: delivery quotes by country and service (standard or express).
- returns: for any return, refund, or replacement question, ask the returns specialist and pass on its decision.
If a tool says something isn't found, say so. Keep answers under 120 words.
"""


class Settings(BaseSettings):
    ai_gateway_url: str
    ai_gateway_model: str = "chat"
    ai_gateway_mcp_servers: str = "orders"

    @property
    def model_base_url(self) -> str:
        return f"{self.ai_gateway_url.rstrip('/')}/default/models/openai/v1/"

    @property
    def mcp_urls(self) -> dict[str, str]:
        names = [n.strip() for n in self.ai_gateway_mcp_servers.split(",") if n.strip()]
        return {n: f"{self.ai_gateway_url.rstrip('/')}/default/toolservers/{n}/mcp" for n in names}


@asynccontextmanager
async def open_agent(settings: Settings, credential: TokenCredential) -> AsyncIterator[Agent]:
    token = get_bearer_token_provider(credential, GATEWAY_SCOPE)

    # The OpenAI client awaits its key provider before each request, so it needs an async callable.
    async def api_key() -> str:
        return token()

    client = OpenAIChatClient(model=settings.ai_gateway_model, base_url=settings.model_base_url, api_key=api_key)
    async with AsyncExitStack() as stack:
        tools = [
            await stack.enter_async_context(
                MCPStreamableHTTPTool(
                    name=name,
                    url=url,
                    # Called for every MCP request, so a long-running app always sends a valid token.
                    header_provider=lambda _: {"Authorization": f"Bearer {token()}"},
                    approval_mode="never_require",
                    request_timeout=90,
                )
            )
            for name, url in settings.mcp_urls.items()
        ]
        yield Agent(client=client, name="orders-agent", instructions=INSTRUCTIONS, tools=tools)
