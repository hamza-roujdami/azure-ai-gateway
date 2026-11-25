"""Smoke test run as a Container Apps job inside the environment: calls the agent's internal /chat endpoint.

A pass proves the whole private path: job -> agent -> gateway (Entra ID) -> Foundry (private endpoint), and
gateway -> the private orders MCP server, shipping API and returns agent. Exits non-zero on failure.
"""

import os
import sys

import httpx

DEFAULT_QUESTION = (
    "Order 1003 was delivered 10 days ago and one Gizmo 1 in it stopped working. "
    "What does the returns specialist recommend, and how fast could a replacement reach Norway by express?"
)
QUESTION = os.environ.get("QUESTION", DEFAULT_QUESTION)


def main() -> int:
    url = os.environ["AGENT_URL"].rstrip("/") + "/chat"
    print(f"Q: {QUESTION}")
    try:
        response = httpx.post(url, json={"message": QUESTION}, timeout=240)
        response.raise_for_status()
    except httpx.HTTPError as error:
        print(f"SMOKE FAILED: {error}", file=sys.stderr)
        return 1
    print(f"A: {response.json()['answer']}")
    print("SMOKE PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
