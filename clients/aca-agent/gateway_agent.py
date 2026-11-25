"""An Agent Framework agent whose model AND tool calls both go through the AI gateway, with no keys.

- Model: the gateway's OpenAI-compatible endpoint, called with the alias (e.g. "chat").
- Tools:  the gateway's MCP endpoint for the private "orders" MCP server.
Both send a Microsoft Entra token for the gateway's audience. In Container Apps the token comes from the app's
managed identity (AZURE_CLIENT_ID); on a laptop, from `az login`. The token provider caches and refreshes it.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from agent_framework import Agent, MCPStreamableHTTPTool
from agent_framework.openai import OpenAIChatClient
from azure.core.credentials import TokenCredential
from azure.identity import get_bearer_token_provider
from pydantic_settings import BaseSettings

GATEWAY_SCOPE = "https://ai.gateway.azure.com/.default"

INSTRUCTIONS = """
You are an order-support assistant. Use the orders tools to look up orders and stock; never guess order data.
If a tool says an order or SKU isn't found, say so. Keep answers under 100 words.
"""


class Settings(BaseSettings):
    ai_gateway_url: str
    ai_gateway_model: str = "chat"
    ai_gateway_mcp_server: str = "orders"

    @property
    def model_base_url(self) -> str:
        return f"{self.ai_gateway_url.rstrip('/')}/default/models/openai/v1/"

    @property
    def mcp_url(self) -> str:
        return f"{self.ai_gateway_url.rstrip('/')}/default/toolservers/{self.ai_gateway_mcp_server}/mcp"


@asynccontextmanager
async def open_agent(settings: Settings, credential: TokenCredential) -> AsyncIterator[Agent]:
    token = get_bearer_token_provider(credential, GATEWAY_SCOPE)

    # The OpenAI client awaits its key provider before each request, so it needs an async callable.
    async def api_key() -> str:
        return token()

    client = OpenAIChatClient(model=settings.ai_gateway_model, base_url=settings.model_base_url, api_key=api_key)
    tools = MCPStreamableHTTPTool(
        name="orders",
        url=settings.mcp_url,
        # Called for every MCP request, so a long-running app always sends a valid token.
        header_provider=lambda _: {"Authorization": f"Bearer {token()}"},
        approval_mode="never_require",
        request_timeout=60,
    )
    async with tools:
        yield Agent(client=client, name="orders-agent", instructions=INSTRUCTIONS, tools=tools)
