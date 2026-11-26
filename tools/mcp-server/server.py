"""The orders MCP server: a small private MCP server (Streamable HTTP on :8000/mcp) that the AI gateway federates.

It runs in the internal Container Apps environment and only accepts traffic from the gateway's integration subnet
(ingress IP restriction), so agents reach these tools only through the gateway, with Entra ID, RBAC and rate limits.
"""

from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

import orders

# Stateless with JSON responses: any replica can serve any request, so the app can scale to zero and out.
mcp = FastMCP("orders", host="0.0.0.0", port=8000, stateless_http=True, json_response=True)


@mcp.tool()
def get_order(order_id: str) -> dict:
    """Get one order's status, items and estimated delivery date by its order ID, for example 1001."""
    return orders.get_order(order_id)


@mcp.tool()
def list_orders(customer: str) -> list[dict]:
    """List the orders of a customer, for example Contoso or Fabrikam."""
    return orders.list_orders(customer)


@mcp.tool()
def check_stock(sku: str) -> dict:
    """Check whether a product SKU is in stock, how many units are on hand, and where. For example WIDGET-42."""
    return orders.check_stock(sku)


@mcp.custom_route("/healthz", methods=["GET"])
async def healthz(_: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
