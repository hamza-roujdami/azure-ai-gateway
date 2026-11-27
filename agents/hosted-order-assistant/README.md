# Foundry hosted agent behind the gateway

An order-support agent built with Microsoft Agent Framework, whose code runs on
[Foundry Agent Service](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents), following Microsoft's
[AI Gateway lab 16](https://azure.github.io/aigateway/labs/16-foundry-hosted-agent/). The Foundry project has no model
deployments, and the agent holds no keys:

| Call | Goes to | Signed in as |
|---|---|---|
| Model | The gateway's `chat` alias (`/default/models/openai/v1`) | The agent's own Microsoft Entra Agent ID |
| Tools | The gateway's `commerce` MCP server: orders, shipping, and the returns specialist | The same Agent ID |

Its access comes from [teams/foundry-hosted-agents.json](../../teams/foundry-hosted-agents.json), like every other
caller's: the gateway answers `403` until that file grants the agent's ID, then applies its own budget and limits.
Lab 16 instead grants the agent **AI Gateway User** on the whole gateway and reaches tools through a Foundry toolbox
that signs in as the project; here each agent gets roles on single assets.

`scripts/deploy.sh` deploys it in phase 3 with azd and passes its Agent ID to the team files. On its own:

```bash
./scripts/deploy-hosted-agent.sh      # from the repository root, after scripts/deploy.sh; prints the Agent ID
cd agents/hosted-order-assistant
azd ai agent invoke hosted-order-assistant "What is the status of order 1001?"
```

To run it locally, as you: create its virtual environment once, then press `F5` in VS Code (the repository's
`.vscode` starts it under the debugger and opens the Foundry Toolkit Agent Inspector), or run
`azd ai agent run --no-client` here and `azd ai agent invoke --local "<question>"`. Locally it reads `AI_GATEWAY_URL`
from the repository's `.env` and signs in as **you**, so it can use only what the team files grant you. With this
repository's team files that's `shipping`, not `commerce`. For `F5` or `python main.py`, copy `.env.example` to
`src/hosted-order-assistant/.env` (it uses `shipping`) and ask for a shipping quote; `azd ai agent run` uses
`commerce` from `azure.yaml` (`AI_GATEWAY_TOOLS`), so add yourself to a team that has it.

```bash
cd agents/hosted-order-assistant/src/hosted-order-assistant
python3.13 -m venv .venv && .venv/bin/pip install -r requirements.txt
```
