"""Calls one tool on one of the gateway's MCP servers, as you, and prints the result. For tests and demos.

  python scripts/mcp_call.py my-orders my_orders
  python scripts/mcp_call.py shipping shipping_quote '{"sku": "WIDGET-42", "country": "NO", "service": "express"}'
  python scripts/mcp_call.py commerce --list                 # the tools the server exposes, with their namespaces

Signs in with your Azure CLI session for the gateway's delegated scope (Data.All), which MCP servers that act as you
(on-behalf-of) need. Reads AI_GATEWAY_URL from the environment or .env. Needs: pip install mcp
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

SCOPE = "https://ai.gateway.azure.com/Data.All"


def gateway_url() -> str:
    if os.environ.get("AI_GATEWAY_URL"):
        return os.environ["AI_GATEWAY_URL"]
    env = Path(__file__).resolve().parent.parent / ".env"
    for line in env.read_text().splitlines() if env.exists() else []:
        if line.startswith("AI_GATEWAY_URL="):
            return line.split("=", 1)[1]
    sys.exit("Set AI_GATEWAY_URL, or run scripts/deploy.sh to write .env")


def token() -> str:
    return subprocess.run(
        ["az", "account", "get-access-token", "--scope", SCOPE, "--query", "accessToken", "-o", "tsv"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


async def run(server: str, tool: str | None, arguments: dict) -> int:
    url = f"{gateway_url().rstrip('/')}/default/toolservers/{server}/mcp"
    async with streamablehttp_client(url, headers={"Authorization": f"Bearer {token()}"}) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            if tool is None:
                listed = await session.list_tools()
                print("\n".join(t.name for t in listed.tools))
                return 0
            result = await session.call_tool(tool, arguments)
            for part in result.content:
                print(getattr(part, "text", part))
            return 1 if result.isError else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("server")
    parser.add_argument("tool", nargs="?")
    parser.add_argument("arguments", nargs="?", default="{}", help="tool arguments as JSON")
    parser.add_argument("--list", action="store_true", help="list the tools instead of calling one")
    args = parser.parse_args(argv)
    if not args.list and not args.tool:
        parser.error("give a tool name, or --list")
    try:
        return asyncio.run(run(args.server, None if args.list else args.tool, json.loads(args.arguments)))
    except BaseException as error:  # the MCP client raises HTTP errors inside exception groups
        status = _http_status(error)
        if status is None:
            raise
        print(f"HTTP {status}: the gateway refused the call", file=sys.stderr)
        return 1


def _http_status(error: BaseException) -> int | None:
    if isinstance(error, httpx.HTTPStatusError):
        return error.response.status_code
    for inner in getattr(error, "exceptions", ()):
        if (status := _http_status(inner)) is not None:
            return status
    return _http_status(error.__cause__) if error.__cause__ else None


if __name__ == "__main__":
    sys.exit(main())
