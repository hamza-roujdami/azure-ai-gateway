"""The returns specialist: an agent that the AI gateway publishes as an MCP tool (Streamable HTTP on :8000/mcp).

Other agents delegate one decision to it: should this return get a refund, a replacement, a repair, or be declined?
It reasons over the returns policy with the gateway's chat model, signed in with its own managed identity, so its
model use has its own role, budget, and telemetry. It can't act on an order: it only recommends.

It runs in the internal Container Apps environment and only accepts traffic from the gateway's integration subnet.
"""

from __future__ import annotations

import json
import re
from functools import lru_cache

from agent_framework import Agent
from agent_framework.openai import OpenAIChatClient
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from mcp.server.fastmcp import FastMCP
from pydantic_settings import BaseSettings
from starlette.requests import Request
from starlette.responses import JSONResponse

GATEWAY_SCOPE = "https://ai.gateway.azure.com/.default"
DECISIONS = ("refund", "replacement", "repair", "decline", "escalate")
POLICY_VERSION = "returns-policy-2026-11"
POLICY = """
Returns policy (synthetic sample):
1. Items that arrived damaged or faulty, reported within 30 days of delivery: replacement if in stock, else refund.
2. Unwanted items in their original packaging, within 14 days of delivery: refund, minus shipping.
3. Faults reported between 30 days and 2 years after delivery: repair under warranty.
4. Orders that aren't delivered yet can't be returned: decline, and suggest cancelling instead.
5. Anything unclear, suspected fraud, or orders over 2 years old: escalate to a person.
"""
INSTRUCTIONS = f"""
You are a returns specialist. Apply this policy to the case you get, and nothing else.
{POLICY}
Answer with one JSON object and no other text:
{{"decision": "refund" | "replacement" | "repair" | "decline" | "escalate", "rationale": "<one or two sentences>"}}
"""


class Settings(BaseSettings):
    ai_gateway_url: str
    ai_gateway_model: str = "chat"


def parse_recommendation(text: str) -> dict:
    """The model's JSON answer, or escalate when it isn't one of the allowed decisions."""
    match = re.search(r"\{.*\}", text or "", re.S)
    try:
        data = json.loads(match.group(0)) if match else {}
    except json.JSONDecodeError:
        data = {}
    decision = str(data.get("decision", "")).strip().lower() if isinstance(data, dict) else ""
    if decision not in DECISIONS:
        return {
            "decision": "escalate",
            "rationale": "No clear decision from the specialist; a person should review it.",
        }
    return {"decision": decision, "rationale": str(data.get("rationale", "")).strip()[:600]}


@lru_cache(maxsize=1)
def specialist() -> Agent:
    settings = Settings()
    # DefaultAzureCredential uses the user-assigned identity in AZURE_CLIENT_ID in Azure, or az login locally.
    token = get_bearer_token_provider(DefaultAzureCredential(), GATEWAY_SCOPE)

    async def api_key() -> str:
        return token()

    client = OpenAIChatClient(
        model=settings.ai_gateway_model,
        base_url=f"{settings.ai_gateway_url.rstrip('/')}/default/models/openai/v1/",
        api_key=api_key,
    )
    return Agent(client=client, name="returns-specialist", instructions=INSTRUCTIONS)


mcp = FastMCP("returns", host="0.0.0.0", port=8000, stateless_http=True, json_response=True)


@mcp.tool()
async def recommend_return(
    order_id: str, sku: str, order_status: str, reason: str, days_since_delivery: int | None = None
) -> dict:
    """Ask the returns specialist whether a returned item gets a refund, replacement, repair, or is declined.
    Pass the order's status (for example delivered), the SKU, the customer's reason, and the days since delivery.
    """
    case = {
        "order_id": order_id,
        "sku": sku,
        "order_status": order_status,
        "reason": reason,
        "days_since_delivery": days_since_delivery,
    }
    result = await specialist().run(json.dumps(case))
    return {"order_id": order_id, "sku": sku, **parse_recommendation(result.text), "policy": POLICY_VERSION}


@mcp.custom_route("/healthz", methods=["GET"])
async def healthz(_: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
