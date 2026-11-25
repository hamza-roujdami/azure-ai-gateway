"""An AI app: the support desk summarizes a ticket with the gateway's chat model. One model call, no tools.

It shows what a team's developers need: the gateway URL and a model alias, a Microsoft Entra token instead of a key,
and a clear message when the gateway says no.

  export AI_GATEWAY_URL=https://<gateway-host>          # scripts/deploy.sh writes it to .env
  python summarize.py "Order 1002 still says processing after a week and the customer wants it before Friday."
"""

from __future__ import annotations

import os
import sys

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import APIStatusError, OpenAI

GATEWAY_SCOPE = "https://ai.gateway.azure.com/.default"
INSTRUCTIONS = (
    "Summarize the support ticket for an agent in two short lines: the customer's problem, then the next step. "
    "Don't invent order details."
)
SAMPLE = (
    "Hi, I ordered a Gadget 7 (order 1002) more than a week ago and it still says processing. "
    "I need it before Friday for a client demo. Can you ship it express or should I cancel?"
)


def explain(error: APIStatusError) -> str:
    """Turns a gateway refusal into the action a developer should take."""
    body = str(error.body or error.message)
    status = error.status_code
    if status == 401:
        return (
            "401: no valid Microsoft Entra token for https://ai.gateway.azure.com. Run az login, or check the identity."
        )
    if status == 403 and "LlmCostQuotaExceeded" in body:
        return (
            "403: this identity has used its budget for the period. Wait for the next period or ask the platform team."
        )
    if status == 403:
        return (
            "403: this identity has no role on the model alias. Ask the platform team to add it to a team file in "
            "teams/. New roles take several minutes to apply."
        )
    if status == 429:
        retry = error.response.headers.get("retry-after", "a few")
        return f"429: token or request limit reached. Retry after {retry} seconds."
    if status == 400 and "content" in body.lower():
        return "400: content safety blocked the prompt or the response."
    return f"{status}: {error.message}"


def summarize(client: OpenAI, model: str, ticket: str) -> str:
    reply = client.chat.completions.create(
        model=model,
        messages=[{"role": "system", "content": INSTRUCTIONS}, {"role": "user", "content": ticket}],
    )
    return reply.choices[0].message.content or ""


def main() -> int:
    url = os.environ.get("AI_GATEWAY_URL")
    if not url:
        print("Set AI_GATEWAY_URL (scripts/deploy.sh writes it to .env).", file=sys.stderr)
        return 2
    token = get_bearer_token_provider(DefaultAzureCredential(), GATEWAY_SCOPE)
    # A token lasts about an hour: a long-running app creates the client again, or passes a fresh token() per call.
    client = OpenAI(base_url=f"{url.rstrip('/')}/default/models/openai/v1", api_key=token())
    try:
        print(summarize(client, os.environ.get("AI_GATEWAY_MODEL", "chat"), " ".join(sys.argv[1:]) or SAMPLE))
    except APIStatusError as error:
        print(explain(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
