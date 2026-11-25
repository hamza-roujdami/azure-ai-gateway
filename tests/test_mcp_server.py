import orders


def test_get_order_found_and_not_found():
    assert orders.get_order(" 1001 ")["status"] == "shipped"
    assert orders.get_order("9999") == {"order_id": "9999", "found": False}


def test_list_orders_is_case_insensitive():
    assert [o["order_id"] for o in orders.list_orders("fabrikam")] == ["1003", "1004"]
    assert orders.list_orders("Nobody") == []


def test_check_stock_reports_availability():
    assert orders.check_stock("widget-42")["in_stock"] is True
    out = orders.check_stock("GADGET-7")
    assert out["in_stock"] is False and out["restock"] == "2026-12-10"
    assert orders.check_stock("NOPE")["found"] is False


def test_server_exposes_the_three_tools():
    import asyncio

    import server

    names = {t.name for t in asyncio.run(server.mcp.list_tools())}
    assert names == {"get_order", "list_orders", "check_stock"}
