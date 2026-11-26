import pytest

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


TENANT = "11111111-1111-1111-1111-111111111111"
BACKEND = "22222222-2222-2222-2222-222222222222"
EXCHANGE = "33333333-3333-3333-3333-333333333333"


class _Keys:
    """Stands in for PyJWKClient: returns the test key for any token."""

    def __init__(self, public_key):
        self.public_key = public_key

    def get_signing_key_from_jwt(self, _token):
        from types import SimpleNamespace

        return SimpleNamespace(key=self.public_key)


def _verifier_and_signer():
    import time

    import jwt
    from cryptography.hazmat.primitives.asymmetric import rsa

    import me_server

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    verifier = me_server.EntraTokenVerifier(TENANT, BACKEND, EXCHANGE, jwks=_Keys(key.public_key()))

    def sign(**overrides):
        claims = {
            "iss": f"https://login.microsoftonline.com/{TENANT}/v2.0",
            "aud": BACKEND,
            "azp": EXCHANGE,
            "scp": "user_impersonation",
            "oid": "user-1",
            "name": "Ada",
            "exp": int(time.time()) + 300,
            **overrides,
        }
        return jwt.encode(claims, key, algorithm="RS256")

    return verifier, sign


@pytest.mark.parametrize(
    ("overrides", "accepted"),
    [
        ({}, True),
        ({"aud": f"api://{BACKEND}"}, True),
        ({"aud": "another-api"}, False),  # issued for another app
        ({"azp": "44444444-4444-4444-4444-444444444444"}, False),  # not requested by the gateway's exchange app
        ({"scp": "User.Read"}, False),  # no user_impersonation scope
        ({"iss": "https://login.microsoftonline.com/other-tenant/v2.0"}, False),
    ],
)
def test_my_orders_accepts_only_tokens_the_gateway_exchanged_for_this_api(overrides, accepted):
    import asyncio

    verifier, sign = _verifier_and_signer()
    token = asyncio.run(verifier.verify_token(sign(**overrides)))
    assert (token is not None) is accepted
    if accepted:
        assert token.claims["oid"] == "user-1"


def test_my_orders_maps_users_to_their_account_only():
    import me_server

    owners = {"user-1": "Contoso"}
    assert me_server.account_of("USER-1", owners) == "Contoso"
    assert me_server.account_of("user-2", owners) is None
    assert me_server.account_of(None, owners) is None
