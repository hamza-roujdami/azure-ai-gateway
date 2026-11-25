"""Run the same agent from your laptop with your `az login` identity (hybrid mode, or from inside the VNet).

export AI_GATEWAY_URL=https://<gateway-host>
python ask.py "Which orders does Fabrikam have?"
"""

import asyncio
import sys

from azure.identity import AzureCliCredential

from gateway_agent import Settings, open_agent

QUESTION = (
    "Order 1003 was delivered 10 days ago and one Gizmo 1 in it stopped working. "
    "What does the returns specialist recommend, and how fast could a replacement reach Norway by express?"
)


async def main() -> None:
    question = " ".join(sys.argv[1:]) or QUESTION
    async with open_agent(Settings(), AzureCliCredential()) as agent:
        print((await agent.run(question)).text)


if __name__ == "__main__":
    asyncio.run(main())
