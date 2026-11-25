# Enterprise AI Gateway on Azure

Today, AI engineers and developers need fast access to models and tools to build apps and agents, without
managing provider keys, endpoints, or network paths in every project. Platform teams need to decide who can use
which model or tool, cap each caller's usage, keep backends private, and trace every call when something goes wrong.

The goal of this community reference implementation is to build an enterprise-ready
[Azure AI Gateway][overview]: provisioned from [Bicep](infra/), secured with Microsoft Entra ID and private
networking, and operated as a shared service. Client apps and agents then demonstrate it end to end, calling a
Foundry model and a private MCP server through the gateway.

> Community sample, not an official Microsoft product. Test it in a sandbox subscription.

## Architecture

![Azure AI Gateway architecture: three AI workload types connect to models, tools, APIs, and agents through a managed gateway, with enterprise controls above and observability below.](https://learn.microsoft.com/en-us/azure/ai-gateway/media/overview/ai-gateway-architecture.png)

Diagram: Microsoft Learn, [What is AI Gateway?][overview]

## What this reference aims to demonstrate

| Workload | Example using synthetic order data |
|---|---|
| AI app | A support desk app summarizes an order note through a model alias. The app does not need the provider's endpoint or credentials. |
| AI agent | An order assistant checks stock through an MCP server, gets a shipping estimate from an OpenAPI-described API published as a tool, and consults a returns specialist through a tool interface. The gateway governs these calls; it does not host the specialist. |
| Coding agent | A developer discovers approved tools in the catalog and connects a coding agent to the gateway to look up a test order using its own permissions. |

Across these examples, the goal is to show how a platform team can:

- **Connect models and tools:** publish model aliases, route or fail over between approved deployments, and federate tools from MCP servers and APIs.
- **Govern each call:** enforce identity and access rules, budgets and quotas, policy expressions, and content guardrails. Agent 365 policies and agent hooks extend control over tool use.
- **Operate the gateway:** reach private backends, track usage and estimated cost by caller, and investigate model and tool calls through OpenTelemetry.

The [deployment below](#deploy) provisions a Foundry model and a private orders MCP server. An Agent Framework agent on Container Apps calls both; a Foundry prompt agent calls the model through the gateway in hybrid mode.

## What makes it secure

| Layer | Control |
|---|---|
| Callers | Microsoft Entra ID only: no runtime API keys are created. [Team files](#onboard-a-team) grant **AI Gateway Models User** on the `chat` alias or **Tools User** on the `orders` MCP server, never the whole gateway |
| Gateway → backends | The gateway's managed identity calls Foundry (**Foundry User** role). Foundry keys are disabled |
| Network | The gateway's outbound calls use **private routing** through a dedicated subnet. Foundry has **public access disabled** and a private endpoint. The MCP server runs in an **internal** Container Apps environment and accepts traffic only from the gateway's subnet |
| AI controls | Per-caller **token limit**, **content safety** and a **daily cost limit** (team files can set one per identity) on the model; per-caller **request rate limit** on the MCP server |
| Visibility | Gateway metrics, logs and traces over OpenTelemetry to Application Insights (no prompt payloads); diagnostic logs from every resource to Log Analytics |
| Secrets | No gateway or model API keys. The orders MCP backend relies on network isolation, not token authentication |

## Inbound modes

| `INBOUND_MODE` | Gateway endpoint | Works for |
|---|---|---|
| `hybrid` (default) | Public, Entra ID only, plus an optional private endpoint | VNet clients, your laptop, **and Foundry agents** |
| `private` | Public access **off**, private endpoint only | VNet clients (the ACA agent) |

Why two modes:
- **The gateway's inbound private endpoint is in preview.** Your subscription needs access first: open an Azure support
  request, "Enable private endpoints for Azure AI Gateway" ([how][pe-access]). Then set `GATEWAY_PRIVATE_ENDPOINT=true`.
- **Foundry Agent Service calls connected models from its managed infrastructure, not from your VNet**
  ([Microsoft Learn][byom]). A Foundry agent therefore needs the gateway's public endpoint, which `hybrid` keeps,
  protected by Entra ID.

## Deploy

You need: the Azure CLI, the [aigateway extension][cli] and Python 3.13. Use a region with Azure AI Gateway and
model quota (default: Sweden Central).

```bash
az login
./scripts/deploy.sh                                     # about 15 minutes; writes .env
pip install -r clients/foundry-agent/requirements.txt
./scripts/test.sh                                       # security checks + both agents end to end
./scripts/teardown.sh
```

`test.sh` checks that:
- calls with no token, or a token for the wrong audience, get `401`
- your token is accepted for `chat` and denied the `orders` tools (hybrid mode)
- Foundry rejects public calls
- the MCP server has no public DNS name
- the gateway passes the [compliance check](#check-any-gateway)
- the ACA agent answers using the model **and** the private MCP tool
- the Foundry agent answers through the gateway

## Onboard a team

Each team is one file in [teams/](teams/): who is in it, the model aliases and MCP servers from
[platform/catalog.json](platform/catalog.json) they can call, and an optional daily budget per identity. A runtime API
key can call every model and tool on a gateway ([concepts][concepts]), so this repo creates none. It grants
**AI Gateway Models User** or **Tools User** on single assets instead.

```json
{
  "$schema": "../platform/team.schema.json",
  "name": "support-desk",
  "owner": "support-desk-leads",
  "models": ["chat"],
  "tools": [],
  "members": [
    { "name": "developers", "principalId": "<Entra group object ID>", "principalType": "Group" },
    { "name": "app", "principalId": "<managed identity principal ID>", "principalType": "ServicePrincipal", "dailyBudgetUsd": 2 }
  ]
}
```

1. **Propose it in a pull request.** CI validates the file and writes the access it grants and revokes to the job
   summary (`python scripts/teams.py diff --base origin/main`).
2. **Deploy after the merge.** `./scripts/deploy.sh` assigns the roles, sets the budgets, and removes runtime roles
   that no team file grants (`scripts/teams.py prune`). Delete a file to offboard a team. Role changes take several
   minutes to apply.
3. **Send the team its quick start.** `python scripts/teams.py quickstart support-desk` prints its endpoints and
   examples that sign in with `az login` or a managed identity, with no keys.

Budgets are estimated spend per identity per day ([lab 07][lab07]): members of a group can't share one budget, so give
each app its own identity. The example files onboard this deployment's callers: `platform:apps` (the Container Apps
agent), `platform:foundry-project` (the Foundry project), and `platform:deployer`, which puts you in `support-desk`, so
`test.sh` can prove that you're denied the `orders` tools.

## Check any gateway

[scripts/check_gateway.py](scripts/check_gateway.py) reads a gateway, changes nothing, and fails on settings that break
team isolation or governance: runtime API keys, runtime roles on the whole gateway or above it, model aliases without
limits or content safety, MCP servers without a rate limit, and telemetry that captures prompts. It works on any Azure
AI Gateway that you can read:

```bash
python scripts/check_gateway.py /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ApiManagement/aigateways/<name>
```

Add `--expect-private` when public access must be off, and `--json` for pipelines.

## Use it from your code

| Client | Code | How it authenticates |
|---|---|---|
| Agent Framework on Container Apps | [clients/aca-agent](clients/aca-agent) | App's managed identity → token for `https://ai.gateway.azure.com/.default` |
| Foundry prompt agent | [clients/foundry-agent](clients/foundry-agent) | Project's managed identity, through the project's gateway connection (model `ai-gateway/chat`) |
| Any OpenAI-compatible SDK | `base_url = <gateway>/default/models/openai/v1`, `model = "chat"` | Entra token as the bearer |

## Repository

```
infra/            Bicep: main.bicep + modules (network, Foundry, gateway, models, tools, team access, Container Apps, monitoring)
platform/         catalog.json (the published model alias and MCP server) and team.schema.json
teams/            one file per team: who can call which assets, and their budgets
clients/          aca-agent (Agent Framework + FastAPI) and foundry-agent (prompt agent)
tools/mcp-server  private MCP server with synthetic order data
scripts/          deploy.sh, test.sh, teardown.sh; teams.py (validate, render, diff, quickstart, prune); check_gateway.py
tests/            unit tests (pytest); CI also validates the team files and builds the Bicep
```

## Cost

- **Azure AI Gateway:** 10,000 requests a month free per gateway. Paid billing starts on 1 Jan 2027: $500 a month per
  gateway, including 10 million requests ([announcement][ga]).
- **Everything else is pay-as-you-go:** model tokens, Container Apps (scales to zero), the Basic container registry,
  private endpoints and log ingestion. Run `teardown.sh` when you're done.

## Limitations and next steps

- **Preview features:** the gateway's private routing and inbound private endpoint are in preview ([lab 18][lab18]).
- **MCP server:** it relies on network isolation. For production, also give the gateway's MCP source managed-identity
  credentials and validate the token in the server.
- **Container registry:** Basic tier with public access, so `az acr build` works. Use Premium with a private endpoint
  in production.
- **Foundry agent project:** public network access stays on, Entra ID only, so you can build agents from the portal.
- **Previewing access:** `az deployment what-if` doesn't list the gateway's assets or their role assignments, because
  they depend on values from the same deployment. Review the `teams.py diff` summary instead.
- **Budgets:** one per caller identity, never pooled across a team. Team totals come from telemetry, not a cap.

## Sources

- [Azure AI Gateway documentation](https://ai.gateway.azure.com/docs) for product guides and quickstarts.
- [Azure AI Gateway GA announcement][ga] and the [official labs][labs]: this repo follows labs [18][lab18] (private
  networking), [21][lab21] (enterprise reference) and [32][lab32] (Foundry gateway connection), and builds the
  multi-team access model on [AI Gateway concepts][concepts], [lab 07][lab07] (cost budgets) and [lab 11][lab11] (Entra
  ID and RBAC)
- [Bring your own model to Foundry Agent Service, private gateway networking][byom]

[overview]: https://learn.microsoft.com/en-us/azure/ai-gateway/overview
[concepts]: https://learn.microsoft.com/azure/ai-gateway/concepts
[ga]: https://techcommunity.microsoft.com/blog/integrationsonazureblog/azure-ai-gateway-is-now-generally-available-ship-faster-stay-in-control/4572644
[labs]: https://github.com/Azure/aigateway
[cli]: https://github.com/Azure/aigateway#azure-cli
[lab07]: https://github.com/Azure/aigateway/tree/main/labs/07-cost-budgets
[lab11]: https://github.com/Azure/aigateway/tree/main/labs/11-entra-rbac
[lab18]: https://github.com/Azure/aigateway/tree/main/labs/18-private-networking
[lab21]: https://github.com/Azure/aigateway/tree/main/labs/21-enterprise-reference
[lab32]: https://github.com/Azure/aigateway/tree/main/labs/32-foundry-gateway-connection
[byom]: https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway#configure-private-ai-gateway-networking
[pe-access]: https://ai.gateway.azure.com/docs/networking/request-private-endpoint-access
