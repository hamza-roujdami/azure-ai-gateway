"""A Foundry Agent Service prompt agent that uses the AI gateway's model through the project's gateway connection.

The project has no model deployments and no keys: Foundry calls the gateway with the project's managed identity,
which has AI Gateway Models User on the alias. The model name is <connection>/<alias>, e.g. ai-gateway/chat.

    export FOUNDRY_PROJECT_ENDPOINT=https://<account>.services.ai.azure.com/api/projects/agents
    export FOUNDRY_MODEL=ai-gateway/chat
    python agent.py "What does an AI gateway do?"    # creates the agent, asks, then deletes it
    python agent.py --keep                           # keep the agent to try it in the Foundry portal
"""

import argparse
import os
import sys

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition
from azure.identity import DefaultAzureCredential

AGENT_NAME = "gateway-agent"
INSTRUCTIONS = "You are a concise assistant for an internal platform team. Answer in at most three sentences."
QUESTION = "In two sentences, why route agents' model calls through a central AI gateway?"


def main() -> None:
    parser = argparse.ArgumentParser(description="Run a Foundry prompt agent on the gateway's model.")
    parser.add_argument("question", nargs="*", help="question to ask")
    parser.add_argument("--keep", action="store_true", help="don't delete the agent afterwards")
    args = parser.parse_args()

    missing = [v for v in ("FOUNDRY_PROJECT_ENDPOINT", "FOUNDRY_MODEL") if not os.environ.get(v)]
    if missing:
        sys.exit(f"Set {', '.join(missing)} (scripts/deploy.sh writes them to .env).")

    project = AIProjectClient(endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"], credential=DefaultAzureCredential())
    openai = project.get_openai_client()

    agent = project.agents.create_version(
        agent_name=AGENT_NAME,
        definition=PromptAgentDefinition(model=os.environ["FOUNDRY_MODEL"], instructions=INSTRUCTIONS),
    )
    try:
        reply = openai.responses.create(
            input=" ".join(args.question) or QUESTION,
            extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
        )
        print(f"{agent.name} (v{agent.version}, model {os.environ['FOUNDRY_MODEL']}): {reply.output_text}")
    finally:
        if not args.keep:
            project.agents.delete_version(agent_name=agent.name, agent_version=agent.version)


if __name__ == "__main__":
    main()
