"""Smoke test run as a Container Apps job inside the environment: calls the agent's internal /chat endpoint.

A pass proves the whole private path: job -> agent -> gateway (Entra ID) -> Foundry (private endpoint) and
gateway -> private MCP server. Exits non-zero on failure.
"""

import os
import sys

import httpx

QUESTION = os.environ.get("QUESTION", "What's the status of order 1001, and is GADGET-7 in stock?")


def main() -> int:
    url = os.environ["AGENT_URL"].rstrip("/") + "/chat"
    print(f"Q: {QUESTION}")
    try:
        response = httpx.post(url, json={"message": QUESTION}, timeout=120)
        response.raise_for_status()
    except httpx.HTTPError as error:
        print(f"SMOKE FAILED: {error}", file=sys.stderr)
        return 1
    print(f"A: {response.json()['answer']}")
    print("SMOKE PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
