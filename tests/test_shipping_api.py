import json

import pytest
from fastapi.testclient import TestClient

import shipping

client = TestClient(shipping.app)


def test_committed_openapi_matches_the_api():
    """The gateway publishes openapi.json, not the running app: regenerate it with python shipping.py --write-spec."""
    assert json.loads(shipping.SPEC_FILE.read_text()) == shipping.spec()


def test_quote_for_a_bulky_item_by_express():
    r = client.get("/quotes", params={"sku": "gizmo-1", "country": "no", "service": "express"})
    assert r.status_code == 200
    assert r.json() == {
        "sku": "GIZMO-1",
        "country": "NO",
        "service": "express",
        "carrier": "DHL Express",
        "business_days": 3,
        "cost_eur": 34.9,
    }


@pytest.mark.parametrize(("params", "status"), [({"sku": "WIDGET-42", "country": "US"}, 404), ({"sku": "X"}, 422)])
def test_unknown_country_or_missing_parameters_are_rejected(params, status):
    assert client.get("/quotes", params=params).status_code == status


def test_every_operation_has_an_id_for_its_tool_name():
    ops = [op for path in shipping.spec()["paths"].values() for op in path.values()]
    assert {op["operationId"] for op in ops} == {"list_countries", "get_delivery_quote"}
