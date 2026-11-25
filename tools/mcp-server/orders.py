"""Synthetic order and stock data, and the lookups the MCP tools expose. Sample data only."""

from __future__ import annotations

ORDERS: dict[str, dict] = {
    "1001": {"customer": "Contoso", "status": "shipped", "items": {"WIDGET-42": 3}, "eta": "2026-12-02"},
    "1002": {"customer": "Contoso", "status": "processing", "items": {"GADGET-7": 1}, "eta": "2026-12-05"},
    "1003": {"customer": "Fabrikam", "status": "delivered", "items": {"WIDGET-42": 10, "GIZMO-1": 2}, "eta": None},
    "1004": {"customer": "Fabrikam", "status": "on hold", "items": {"GIZMO-1": 5}, "eta": None},
}

STOCK: dict[str, dict] = {
    "WIDGET-42": {"name": "Widget 42", "on_hand": 120, "warehouse": "Gothenburg"},
    "GADGET-7": {"name": "Gadget 7", "on_hand": 0, "warehouse": "Stockholm", "restock": "2026-12-10"},
    "GIZMO-1": {"name": "Gizmo 1", "on_hand": 8, "warehouse": "Malmo"},
}


def get_order(order_id: str) -> dict:
    order = ORDERS.get(order_id.strip())
    if order is None:
        return {"order_id": order_id, "found": False}
    return {"order_id": order_id.strip(), "found": True, **order}


def list_orders(customer: str) -> list[dict]:
    wanted = customer.strip().lower()
    return [{"order_id": oid, **o} for oid, o in ORDERS.items() if o["customer"].lower() == wanted]


def check_stock(sku: str) -> dict:
    item = STOCK.get(sku.strip().upper())
    if item is None:
        return {"sku": sku, "found": False}
    return {"sku": sku.strip().upper(), "found": True, "in_stock": item["on_hand"] > 0, **item}
