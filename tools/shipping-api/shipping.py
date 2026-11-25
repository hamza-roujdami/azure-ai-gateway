"""A small shipping REST API that the AI gateway publishes as MCP tools from its OpenAPI description.

It has no MCP code: the gateway reads openapi.json (inline in the tool server, with the private URL as the server) and
turns each operation into a tool. It runs in the internal Container Apps environment and only accepts traffic from the
gateway's integration subnet. Sample data only.

  uvicorn shipping:app --port 8000
  python shipping.py --write-spec    # regenerate openapi.json after changing the API
"""

from __future__ import annotations

import json
import sys
from enum import Enum
from pathlib import Path
from typing import Annotated

from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel

SPEC_FILE = Path(__file__).with_name("openapi.json")


class Service(str, Enum):
    standard = "standard"
    express = "express"


class Quote(BaseModel):
    sku: str
    country: str
    service: Service
    carrier: str
    business_days: int
    cost_eur: float


# Business days and cost from the Swedish warehouses, by destination country and service. Synthetic.
RATES: dict[str, dict[Service, tuple[str, int, float]]] = {
    "SE": {Service.standard: ("PostNord", 2, 4.9), Service.express: ("DHL Express", 1, 14.9)},
    "NO": {Service.standard: ("PostNord", 4, 9.9), Service.express: ("DHL Express", 2, 24.9)},
    "DK": {Service.standard: ("PostNord", 3, 7.9), Service.express: ("DHL Express", 1, 19.9)},
    "DE": {Service.standard: ("DHL Parcel", 4, 9.9), Service.express: ("DHL Express", 2, 29.9)},
    "FR": {Service.standard: ("DHL Parcel", 5, 11.9), Service.express: ("DHL Express", 2, 32.9)},
}
BULKY = {"GIZMO-1"}

app = FastAPI(
    title="Shipping API",
    version="1.0.0",
    description="Delivery quotes from the Swedish warehouses. Synthetic sample data.",
)
app.openapi_version = "3.0.3"


@app.get("/healthz", include_in_schema=False)
def healthz() -> dict:
    return {"status": "ok"}


@app.get("/countries", operation_id="list_countries", summary="List the countries the warehouses deliver to.")
def list_countries() -> list[str]:
    return sorted(RATES)


@app.get(
    "/quotes",
    operation_id="get_delivery_quote",
    summary="Get the carrier, delivery time in business days, and cost to ship a product SKU to a country.",
    responses={404: {"description": "The warehouses don't deliver to that country."}},
)
def get_delivery_quote(
    sku: Annotated[str, Query(description="Product SKU, for example WIDGET-42.", min_length=1, max_length=40)],
    country: Annotated[
        str, Query(description="Two-letter destination country code, for example SE.", pattern="^[A-Za-z]{2}$")
    ],
    service: Annotated[Service, Query(description="standard or express.")] = Service.standard,
) -> Quote:
    rates = RATES.get(country.upper())
    if rates is None:
        raise HTTPException(status_code=404, detail=f"No delivery to {country.upper()}. See /countries.")
    carrier, days, cost = rates[service]
    sku = sku.strip().upper()
    if sku in BULKY:
        days, cost = days + 1, cost + 10
    return Quote(sku=sku, country=country.upper(), service=service, carrier=carrier, business_days=days, cost_eur=cost)


def spec() -> dict:
    """The OpenAPI description the gateway publishes. Bicep sets servers to the private URL."""
    return {**app.openapi(), "servers": [{"url": "https://shipping-api.invalid"}]}


if __name__ == "__main__":
    if "--write-spec" in sys.argv:
        SPEC_FILE.write_text(json.dumps(spec(), indent=2) + "\n")
        print(f"Wrote {SPEC_FILE.name}")
    else:
        import uvicorn

        uvicorn.run(app, host="0.0.0.0", port=8000)
