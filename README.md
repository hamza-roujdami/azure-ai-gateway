# Enterprise AI Gateway on Azure

Today, AI engineers and developers need fast access to models and tools to build apps and agents, without
managing provider keys, endpoints, or network paths in every project. Platform teams need to decide who can use
which model or tool, cap each caller's usage, keep backends private, and trace every call when something goes wrong.

The goal of this community reference implementation is to build an enterprise-ready
[Azure AI Gateway][overview]: provisioned from [Bicep](infra/), secured with Microsoft Entra ID and private
networking, and operated as a shared service for many teams. AI apps, AI agents, and coding agents then demonstrate it
end to end, calling a Foundry model, MCP servers, a REST API, and a specialist agent through the gateway.

> Community sample, not an official Microsoft product. Test it in a sandbox subscription.

## Architecture

![Azure AI Gateway architecture: three AI workload types connect to models, tools, APIs, and agents through a managed gateway, with enterprise controls above and observability below.](https://learn.microsoft.com/en-us/azure/ai-gateway/media/overview/ai-gateway-architecture.png)

Diagram: Microsoft Learn, [What is AI Gateway?][overview]. What this repo deploys for each part:

| Part | In this repo |
|---|---|
| **AI apps** | A support desk app that summarizes a ticket with one model call ([clients/support-desk](clients/support-desk)) |
| **AI agents** | An order assistant on Agent Framework in internal Container Apps ([clients/aca-agent](clients/aca-agent)), and a Foundry Agent Service prompt agent ([clients/foundry-agent](clients/foundry-agent)) |
| **Coding agents** | GitHub Copilot CLI using the gateway's model and MCP tools, signed in as the developer ([scripts/copilot-with-gateway.sh](scripts/copilot-with-gateway.sh)) |
| **Azure AI Gateway** | One gateway: Microsoft Entra ID only, private routing to the backends, the `chat` model alias, and three MCP servers |
| **Model providers** | Microsoft Foundry (`gpt-5-mini`), with keys and public access off, reached over a private endpoint |
| **MCP servers & APIs** | `orders`: a private MCP server. `shipping`: a private REST API that the gateway publishes as tools from its [OpenAPI description](tools/shipping-api/openapi.json) |
| **Agents** | `returns`: a specialist agent behind an MCP tool. It calls the model through the gateway as its own identity ([agents/returns-agent](agents/returns-agent)) |
| **Enterprise controls** | Entra roles on single assets, per-caller token, request, and cost limits, content safety, and a gateway-wide baseline |
| **Observability** | OpenTelemetry to Application Insights without prompt content, and a usage report by team |

## Why this repo

A runtime API key can call every model and tool on a gateway ([concepts][concepts]), and every gateway has a built-in
`master` key. That's fine for one team. On a gateway that many teams share, the only way to keep them apart is Entra
roles on single assets, and no published sample shows how a platform team runs that for its fifth or twentieth team.
This repo does:

**For platform teams**
- **Onboard a team with a pull request.** One file in [teams/](teams/) says who can call which model and tools, with
  what budget. CI shows the access the change grants and revokes; the deployment applies it and removes anything no
  file grants. Delete the file to offboard the team.
- **Start every asset from a baseline.** Gateway-wide token, request, and cost limits and content safety
  ([platform/baseline-policies.json](platform/baseline-policies.json)), the built-in `master` key suspended, and no
  other keys.
- **Check any gateway.** A read-only compliance check fails on settings that break team isolation or governance.
- **See usage by team.** Requests, denials, throttling, tokens, and estimated cost per team member, from telemetry.

**For AI engineers and developers**
- **A quick start per team:** the endpoints and examples for exactly what the team can call, with no keys to handle.
- **Clear refusals:** the sample app turns a `401`, `403`, `429`, or content-safety `400` into the action to take.
- **The same access in their coding agent:** Copilot CLI uses the gateway's model and tools with their own identity,
  limits, and budget.

## Deploy and test

You need: an Azure subscription where you're **Owner** (the templates assign roles), the Azure CLI 2.75 or later, the
[aigateway extension][cli], and Python 3.13. Optional: [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli),
for the coding agent check. Use a region with Azure AI Gateway and `gpt-5-mini` quota (default: Sweden Central).

```bash
az login
python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements-dev.txt
./scripts/deploy.sh          # about 25 minutes; writes .env
./scripts/test.sh            # about 5 minutes
./scripts/teardown.sh
```

`test.sh` proves, against the live deployment, as you (`platform:deployer` in the team files):

| Area | What it proves |
|---|---|
| Access | No token, or a token for another audience, gets `401`. You can call `chat` and the `shipping` tools, and you get `403` from `orders` and `returns`, which no team grants you |
| Backends | Foundry rejects calls from the internet, and the MCP server has no public DNS name |
| Compliance | The gateway passes [scripts/check_gateway.py](scripts/check_gateway.py) |
| AI app | The support desk summarizes a ticket |
| AI agent | A Container Apps job asks the order assistant a question that needs the orders tools, the returns specialist, and the shipping API |
| Coding agent | Copilot CLI answers from the `shipping` tools, through the gateway's model |
| Foundry agent | A prompt agent answers through the project's gateway connection |

## Onboard a team

Each team is one file in [teams/](teams/): who is in it, the model aliases and MCP servers from
[platform/catalog.json](platform/catalog.json) they can call, and an optional daily budget per identity.
[platform/team.schema.json](platform/team.schema.json) gives editors validation.

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
2. **Deploy after the merge.** [deploy.sh](scripts/deploy.sh), or the [deploy workflow](#automate-with-github-actions),
   assigns **AI Gateway Models User** or **Tools User** on each asset, sets the budgets, and removes runtime roles that
   no team file grants (`scripts/teams.py prune`). Role changes take several minutes to apply.
3. **Send the team its quick start.** `python scripts/teams.py quickstart support-desk` prints its endpoints and
   examples that sign in with `az login` or a managed identity.

Budgets are estimated spend per identity per day ([lab 07][lab07]). Members of a group can't share one budget, so give
each app its own identity; `teams.py` rejects budgets on groups and budgets above the gateway-wide ceiling. The example
files onboard this deployment's identities through `platform:` references: `platform:apps` (the order assistant),
`platform:returns-agent`, `platform:foundry-project`, and `platform:deployer` (you).

## Build on the gateway

Every client authenticates with a Microsoft Entra token for `https://ai.gateway.azure.com/.default`: `az login` on a
laptop, a managed identity in Azure. There are no keys.

| Workload | Run it | Calls |
|---|---|---|
| AI app | `python clients/support-desk/summarize.py "<ticket>"` | The `chat` alias |
| AI agent | `python clients/aca-agent/ask.py "<question>"` (needs the order-assistant access), or the `agent-smoke` job | `chat`, then the `orders`, `shipping`, and `returns` MCP servers |
| Foundry agent | `python clients/foundry-agent/agent.py "<question>"` | `ai-gateway/chat` through the project's connection |
| Coding agent | `./scripts/copilot-with-gateway.sh shipping` | `chat` as Copilot's model, and the `shipping` tools |
| Any OpenAI SDK | `base_url = <gateway>/default/models/openai/v1`, `model = "chat"` | |
| Any MCP client | `<gateway>/default/toolservers/<server>/mcp`, header `Authorization: Bearer <token>` | |

The returns specialist shows an agent as a backend: other agents call it as an MCP tool, and it calls the model as its
own identity, with its own team file and budget. It only recommends; it can't change an order.

## Operate the gateway

| Task | Command |
|---|---|
| Check any gateway you can read, without changing it | `python scripts/check_gateway.py <gateway resource ID> [--expect-private] [--json]` |
| Apply the gateway-wide baseline, merged with existing policies | `python scripts/apply_baseline.py <gateway resource ID> [--dry-run]` |
| See usage by team | `python scripts/usage_report.py <deployment> [--hours 24]` |
| Remove runtime roles that no team file grants | `python scripts/teams.py prune <deployment> [--apply]` |

The compliance check fails on active runtime API keys (including the built-in `master` key), runtime roles on the whole
gateway, a workspace, or anything above them, model aliases without limits or content safety, MCP servers without a
rate limit, and telemetry that captures prompts. Every applicable policy can block a call, so an asset's own policies
can be stricter than the baseline but never looser.

## Automate with GitHub Actions

[ci.yml](.github/workflows/ci.yml) runs on every push and pull request: lint, unit tests, team file validation, the
access diff, and the Bicep builds. [deploy.yml](.github/workflows/deploy.yml) deploys and tests on merges to `main`
that change teams, the platform, or the apps. It signs in with OpenID Connect, so no secret is stored. Set it up once:

```bash
GITHUB_REPO=<owner>/<repo> AZURE_ENV_NAME=aigw-demo ./scripts/setup-github-deploy.sh
```

It creates an app registration trusted only by the repository's `azure` environment, gives it **Contributor** and
**Role Based Access Control Administrator** on the subscription, and stores the IDs as environment variables. Until
then the deploy job is skipped. In the pipeline, `platform:deployer` stays the developer who ran the setup, not the
pipeline's identity.

## Security

| Layer | Control |
|---|---|
| Callers | Microsoft Entra ID only. Roles on single assets from the team files; the built-in `master` key suspended and no other runtime keys |
| Gateway → backends | The gateway's managed identity calls Foundry (**Foundry User**); Foundry keys are disabled |
| Network | The gateway's outbound calls use **private routing** through a dedicated subnet. Foundry has public access off and a private endpoint. The backends run in an **internal** Container Apps environment and accept traffic only from the gateway's subnet |
| AI controls | Per-caller token limit, daily cost limit, and content safety on the model; per-caller request rate limit on each MCP server; a gateway-wide baseline under all of them |
| Visibility | Metrics, logs, and traces over OpenTelemetry to Application Insights, with the caller's tenant and object ID and without prompt content; diagnostic logs from every resource to Log Analytics |
| Delivery | Pull request review of access changes; OpenID Connect sign-in for the pipeline |

## Inbound modes

| `INBOUND_MODE` | Gateway endpoint | Works for |
|---|---|---|
| `hybrid` (default) | Public, Entra ID only, plus an optional private endpoint | VNet clients, your laptop, coding agents, **and Foundry agents** |
| `private` | Public access **off**, private endpoint only | VNet clients (the order assistant) |

- **The gateway's inbound private endpoint is in preview.** Your subscription needs access first: open an Azure support
  request, "Enable private endpoints for Azure AI Gateway" ([how][pe-access]). Then set `GATEWAY_PRIVATE_ENDPOINT=true`.
- **Foundry Agent Service calls connected models from its managed infrastructure, not from your VNet**
  ([Microsoft Learn][byom]). A Foundry agent therefore needs the gateway's public endpoint, which `hybrid` keeps,
  protected by Entra ID.

## Repository

```
infra/            Bicep: main.bicep + modules (network, Foundry, gateway, models, tools, team access, Container Apps, monitoring)
platform/         catalog.json (the published alias and MCP servers), team.schema.json, baseline-policies.json
teams/            one file per team: who can call which assets, and their budgets
clients/          AI app (support-desk), AI agent (aca-agent), Foundry prompt agent (foundry-agent)
tools/            orders MCP server (mcp-server), shipping REST API (shipping-api)
agents/           returns specialist agent (returns-agent)
scripts/          deploy, test, teardown; teams.py, check_gateway.py, apply_baseline.py, usage_report.py;
                  copilot-with-gateway.sh, setup-github-deploy.sh
docs/             demo.md: a 20-minute walkthrough for customer conversations
tests/            unit tests (pytest)
```

## Cost

- **Azure AI Gateway:** 10,000 requests a month free per gateway. Paid billing starts on 1 Jan 2027: $500 a month per
  gateway, including 10 million requests ([announcement][ga]).
- **Everything else is pay-as-you-go:** model tokens, Container Apps (four apps keep one replica each, to avoid cold
  starts; set `minReplicas` to 0 in [aca-apps.bicep](infra/modules/aca-apps.bicep) to scale to zero), the Basic
  container registry, private endpoints, and log ingestion. Run `teardown.sh` when you're done.

## Limitations and known issues

- **Preview features:** the gateway's private routing and inbound private endpoint are in preview ([lab 18][lab18]).
- **Backend authentication:** the private backends rely on network isolation and accept no token from the gateway. For
  production, give the MCP sources managed-identity credentials and validate the token in each server, or use
  on-behalf-of ([lab 33][lab33]) when tools must act as the user.
- **Budgets:** one per caller identity, never pooled across a team. Team totals come from the usage report, not a cap.
- **Previewing access:** `az deployment what-if` can't list the gateway's assets or role assignments, because they
  depend on values from the same deployment. Review the `teams.py diff` summary instead.
- **Not covered here:** Microsoft Agent 365 governance, tool threat protection, and agent hooks ([labs 19, 20,
  30][labs]); model routing and failover ([labs 22, 29][labs]).
- **Container registry:** Basic tier with public access, so `az acr build` works. Use Premium with a private endpoint
  in production. The Foundry agent project keeps public access on, Entra ID only, so you can build agents in the portal.
- **Python on OpenSSL 3.5 or later:** calls to the Foundry project endpoint can fail with
  `SSL: UNEXPECTED_EOF_WHILE_READING`, when the default TLS 1.3 handshake's post-quantum key share is dropped. Run the
  Foundry client with `OPENSSL_CONF=clients/foundry-agent/openssl-classic.cnf`; `test.sh` retries with it.

## Sources

- [What is AI Gateway?][overview], [AI Gateway concepts][concepts], and the
  [Azure AI Gateway documentation](https://ai.gateway.azure.com/docs)
- [Azure AI Gateway GA announcement][ga] and the [official labs][labs]: this repo follows labs [18][lab18] (private
  networking), [21][lab21] (enterprise reference), and [32][lab32] (Foundry gateway connection), and builds the
  multi-team access model on labs [07][lab07] (cost budgets), [09][lab09] (baselines), [10][lab10] (API keys),
  [11][lab11] (Entra ID and RBAC), [14][lab14] (OpenTelemetry chargeback), and [24][lab24] (GitHub Copilot)
- [Bring your own model to Foundry Agent Service, private gateway networking][byom]

[overview]: https://learn.microsoft.com/en-us/azure/ai-gateway/overview
[concepts]: https://learn.microsoft.com/azure/ai-gateway/concepts
[ga]: https://techcommunity.microsoft.com/blog/integrationsonazureblog/azure-ai-gateway-is-now-generally-available-ship-faster-stay-in-control/4572644
[labs]: https://azure.github.io/aigateway/labs/
[cli]: https://github.com/Azure/aigateway#azure-cli
[lab07]: https://github.com/Azure/aigateway/tree/main/labs/07-cost-budgets
[lab09]: https://github.com/Azure/aigateway/tree/main/labs/09-gateway-baselines
[lab10]: https://github.com/Azure/aigateway/tree/main/labs/10-api-keys
[lab11]: https://github.com/Azure/aigateway/tree/main/labs/11-entra-rbac
[lab14]: https://github.com/Azure/aigateway/tree/main/labs/14-otel-chargeback
[lab18]: https://github.com/Azure/aigateway/tree/main/labs/18-private-networking
[lab21]: https://github.com/Azure/aigateway/tree/main/labs/21-enterprise-reference
[lab24]: https://github.com/Azure/aigateway/tree/main/labs/24-github-copilot-byok
[lab32]: https://github.com/Azure/aigateway/tree/main/labs/32-foundry-gateway-connection
[lab33]: https://github.com/Azure/aigateway/tree/main/labs/33-copilot-obo-mcp
[byom]: https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway#configure-private-ai-gateway-networking
[pe-access]: https://ai.gateway.azure.com/docs/networking/request-private-endpoint-access
