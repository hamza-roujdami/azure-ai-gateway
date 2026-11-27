"""A Foundry hosted agent whose model and tool calls all go through the AI gateway, as its own Entra Agent ID.

The Foundry project has no model deployment, and the agent holds no keys and has no direct route to a tool:
- Model: the gateway's OpenAI-compatible endpoint, with the alias in AI_GATEWAY_MODEL (chat).
- Tools: the gateway's MCP servers in AI_GATEWAY_TOOLS (commerce), which federates the orders and shipping tools and
  the returns specialist.
Both calls send a Microsoft Entra token for the gateway's audience. In Foundry it's the agent's own identity (its
Entra Agent ID), which teams/foundry-hosted-agents.json grants the chat alias and commerce, with its own budget and
limits; the gateway refuses anything else. Locally, `azd ai agent run` uses your Azure CLI sign-in instead.
"""

from __future__ import annotations

import os
from pathlib import Path

from agent_framework import Agent, MCPStreamableHTTPTool
from agent_framework.openai import OpenAIChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from dotenv import load_dotenv

# Locally: this folder's .env first, then the repository's (AI_GATEWAY_URL); the first value found wins. In Foundry the
# code sits in a shallow folder with no .env, so the lookup stops at the filesystem root.
HERE = Path(__file__).resolve().parent
for folder in (HERE, *HERE.parents[:4]):
    load_dotenv(folder / ".env")

GATEWAY_SCOPE = "https://ai.gateway.azure.com/.default"

INSTRUCTIONS = """
You are an order-support assistant. Use the tools; never guess order, stock, or shipping data.
- orders_* tools: order status, items, and stock levels.
- shipping_* tools: delivery quotes by country and service (standard or express).
- returns_* tools: for any return, refund, or replacement question, ask the returns specialist and pass on its
  decision.
If a tool says something isn't found, say so. Keep answers under 120 words.
"""


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Set {name}. With azd, run: azd env set {name} <value>")
    return value


# Foundry sets FOUNDRY_HOSTING_ENVIRONMENT in the agent's container, where the managed identity is the agent's Entra
# Agent ID. Locally, skip the managed identity probe so that the credential goes straight to your CLI sign-in.
IN_FOUNDRY = bool(os.environ.get("FOUNDRY_HOSTING_ENVIRONMENT"))
credential = DefaultAzureCredential(exclude_managed_identity_credential=not IN_FOUNDRY)
token = get_bearer_token_provider(credential, GATEWAY_SCOPE)


async def api_key() -> str:
    # The OpenAI client awaits its key provider before each request, so a long-running agent always sends a valid token.
    return token()


def create_agent() -> Agent:
    gateway = required("AI_GATEWAY_URL").rstrip("/")
    servers = [s.strip() for s in os.environ.get("AI_GATEWAY_TOOLS", "commerce").split(",") if s.strip()]
    client = OpenAIChatClient(
        model=os.environ.get("AI_GATEWAY_MODEL", "chat"),
        base_url=f"{gateway}/default/models/openai/v1/",
        api_key=api_key,
    )
    tools = [
        MCPStreamableHTTPTool(
            name=name,
            url=f"{gateway}/default/toolservers/{name}/mcp",
            header_provider=lambda _: {"Authorization": f"Bearer {token()}"},
            approval_mode="never_require",
            request_timeout=90,
        )
        for name in servers
    ]
    return Agent(
        client=client,
        name="hosted-order-assistant",
        instructions=INSTRUCTIONS,
        tools=tools,
        # Foundry keeps the conversation history, so the model call doesn't need to store it. Stateless calls also let
        # the gateway fail over between regions: a stored response would pin the conversation to one backend.
        default_options={"store": False},
    )


if __name__ == "__main__":
    # The server creates the agent for each request, and closes its MCP connections afterward.
    ResponsesHostServer(agent=create_agent).run()
