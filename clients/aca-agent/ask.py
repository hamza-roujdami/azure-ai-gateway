"""Run the same agent from your laptop with your `az login` identity (hybrid mode, or from inside the VNet).

export AI_GATEWAY_URL=https://<gateway-host>
python ask.py "Which orders does Fabrikam have?"
"""

import asyncio
import sys

from azure.identity import AzureCliCredential

from gateway_agent import Settings, open_agent


async def main() -> None:
    question = " ".join(sys.argv[1:]) or "What's the status of order 1001, and is GADGET-7 in stock?"
    async with open_agent(Settings(), AzureCliCredential()) as agent:
        print((await agent.run(question)).text)


if __name__ == "__main__":
    asyncio.run(main())
