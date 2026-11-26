"""The my-orders MCP server: the signed-in user's own orders (Streamable HTTP on :8000/mcp).

Azure AI Gateway calls it on behalf of the user. The gateway exchanges the caller's token with Microsoft Entra ID
(on-behalf-of), so this server receives a token for its own app registration that still names the user. It accepts a
token only when:
  * Microsoft Entra ID issued it for this tenant (signature and iss),
  * it's for this backend (aud) and carries the user_impersonation scope (scp),
  * the gateway's token exchange app requested it (azp).
So the tools are reachable along one path: MCP client -> gateway (role check) -> on-behalf-of exchange -> here. The
container app's ingress also accepts only the gateway's subnet.
"""

from __future__ import annotations

import asyncio
import json
import os
from typing import Any

import jwt
from mcp.server.auth.middleware.auth_context import get_access_token
from mcp.server.auth.provider import AccessToken
from mcp.server.auth.settings import AuthSettings
from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

import orders

REQUIRED_SCOPE = "user_impersonation"


class EntraTokenVerifier:
    """Validates a Microsoft Entra ID v2 access token for this backend, requested by the token exchange app."""

    def __init__(self, tenant_id: str, backend_app_id: str, token_exchange_app_id: str, jwks: Any = None) -> None:
        self.issuer = f"https://login.microsoftonline.com/{tenant_id}/v2.0"
        # A v2 token's audience is the backend's client ID; accept the api:// form too.
        self.audience = [backend_app_id, f"api://{backend_app_id}"]
        self.token_exchange_app_id = token_exchange_app_id.lower()
        self.jwks = jwks or jwt.PyJWKClient(
            f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys", cache_keys=True
        )

    async def verify_token(self, token: str) -> AccessToken | None:
        try:
            key = await asyncio.to_thread(self.jwks.get_signing_key_from_jwt, token)
            claims = jwt.decode(token, key.key, algorithms=["RS256"], audience=self.audience, issuer=self.issuer)
        except (jwt.PyJWTError, OSError):
            return None
        scopes = str(claims.get("scp", "")).split()
        if REQUIRED_SCOPE not in scopes or str(claims.get("azp", "")).lower() != self.token_exchange_app_id:
            return None
        return AccessToken(
            token=token,
            client_id=claims["azp"],
            scopes=scopes,
            expires_at=claims.get("exp"),
            subject=claims.get("oid"),
            claims=claims,
        )


def account_of(object_id: str | None, owners: dict[str, str]) -> str | None:
    """The customer account that a user buys for. Sample data: ACCOUNT_OWNERS maps Entra object IDs to accounts."""
    return owners.get((object_id or "").lower())


def build_server() -> FastMCP:
    tenant_id = os.environ["AZURE_TENANT_ID"]
    owners = {k.lower(): v for k, v in json.loads(os.environ.get("ACCOUNT_OWNERS", "{}")).items()}
    mcp = FastMCP(
        "my-orders",
        instructions="The signed-in user's own orders. Call whoami to see who the backend thinks you are.",
        host="0.0.0.0",
        port=8000,
        stateless_http=True,
        json_response=True,
        token_verifier=EntraTokenVerifier(tenant_id, os.environ["BACKEND_APP_ID"], os.environ["TOKEN_EXCHANGE_APP_ID"]),
        auth=AuthSettings(
            issuer_url=f"https://login.microsoftonline.com/{tenant_id}/v2.0",
            resource_server_url=os.environ.get("RESOURCE_URL", "https://my-orders.internal"),
            required_scopes=[REQUIRED_SCOPE],
        ),
    )

    def caller() -> dict[str, Any]:
        token = get_access_token()
        return (token.claims or {}) if token else {}

    @mcp.tool()
    def whoami() -> dict:
        """Who the orders backend sees as the caller, read from the token that the gateway sent on your behalf."""
        claims = caller()
        return {
            "name": claims.get("name"),
            "username": claims.get("preferred_username"),
            "object_id": claims.get("oid"),
            "requested_by_app": claims.get("azp"),
            "scopes": claims.get("scp"),
        }

    @mcp.tool()
    def my_orders() -> dict:
        """The signed-in user's orders: the orders of the customer account they buy for."""
        claims = caller()
        account = account_of(claims.get("oid"), owners)
        return {
            "user": claims.get("name") or claims.get("preferred_username"),
            "account": account,
            "orders": orders.list_orders(account) if account else [],
        }

    @mcp.custom_route("/healthz", methods=["GET"])
    async def healthz(_: Request) -> JSONResponse:
        return JSONResponse({"status": "ok"})

    return mcp


if __name__ == "__main__":
    build_server().run(transport="streamable-http")
