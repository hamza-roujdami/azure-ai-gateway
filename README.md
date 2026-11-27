# Enterprise AI Gateway on Azure

Today, AI engineers and developers need fast access to models and tools to build apps and agents, without
managing provider keys, endpoints, or network paths in every project. Platform teams need to decide who can use
which model or tool, cap each caller's usage, keep backends private, and trace every call when something goes wrong.

The goal of this community reference implementation is to build an enterprise-ready
[Azure AI Gateway][overview]: provisioned from [Bicep](infra/), secured with Microsoft Entra ID and private
networking, and operated as a shared service for many teams. Users, AI apps, AI agents, and coding agents then
demonstrate it end to end: two model families behind stable aliases, with failover across regions, and MCP tools
federated from an MCP server, a REST API, and a specialist agent, including a tool that acts as the signed-in user.

> Community sample, not an official Microsoft product. Test it in a sandbox subscription.

## Architecture

![Azure AI Gateway architecture: three AI workload types connect to models, tools, APIs, and agents through a managed gateway, with enterprise controls above and observability below.](https://learn.microsoft.com/en-us/azure/ai-gateway/media/overview/ai-gateway-architecture.png)

Diagram: Microsoft Learn, [What is AI Gateway?][overview]. What this repo deploys for each part:

| Part | In this repo |
|---|---|
| **Users** | An employee asks for their own orders from any MCP client. The `my-orders` tool runs as that user (on-behalf-of), so the backend only ever sees and returns their data |
| **AI apps** | A support desk app that summarizes a ticket with one model call ([clients/support-desk](clients/support-desk)) |
| **AI agents** | An order assistant on Agent Framework in internal Container Apps ([clients/aca-agent](clients/aca-agent)); the same assistant as a **Foundry hosted agent**, whose code runs on Foundry and calls the gateway as its own Entra Agent ID ([agents/hosted-order-assistant](agents/hosted-order-assistant)); and a Foundry Agent Service prompt agent ([clients/foundry-agent](clients/foundry-agent)) |
| **Coding agents** | GitHub Copilot CLI using the gateway's models and MCP tools, signed in as the developer ([scripts/copilot-with-gateway.sh](scripts/copilot-with-gateway.sh)) |
| **Azure AI Gateway** | One gateway: Microsoft Entra ID only, private routing to the backends, three model aliases, and three MCP servers |
| **Model providers** | Two Microsoft Foundry accounts with keys and public access off, reached over private endpoints. `chat` (`gpt-5-mini`) prefers Sweden Central and **fails over to France Central** when the primary is throttled, missing, paused, or failing; a **CEL condition** sends `x-workload: batch` traffic straight to France Central. `mistral` (Mistral Large 3) is a second model family. `claude` (Anthropic Messages API) is optional |
| **MCP servers & APIs** | `commerce` **federates three backends behind one endpoint**: `orders_*` from a private MCP server, `shipping_*` from a private REST API published from its [OpenAPI description](tools/shipping-api/openapi.json), and `returns_*`. `shipping` publishes the API on its own. `my-orders` calls its backend **as the signed-in user** |
| **Agents** | `returns`: a specialist agent behind an MCP tool. It calls the model through the gateway as its own identity ([agents/returns-agent](agents/returns-agent)) |
| **Enterprise controls** | Entra roles on single assets, per-caller token, request, and cost limits, content safety, and a gateway-wide baseline |
| **Observability** | OpenTelemetry to Application Insights without prompt content, and a usage report by team |

## Why this repo

Microsoft's [official labs][labs] teach each capability on its own, and [lab 21][lab21] puts one team's gateway into
code. This repo shows the **operating model** that the Foundry guidance calls centralized hub-and-spoke: a platform
team runs one gateway that many teams share, and every kind of caller in the product's picture uses it at once.

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
- **Keep apps running when a region throttles.** One alias, two regions, a failure rule, and a CEL condition that
  keeps batch jobs off the primary's capacity, with no change in the apps.

**For AI engineers and developers**
- **A quick start per team:** the endpoints and examples for exactly what the team can call, with no keys to handle.
- **Clear refusals:** the sample app turns a `401`, `403`, `429`, or content-safety `400` into the action to take.
- **The same access in their coding agent:** Copilot CLI uses the gateway's models and tools with their own identity,
  limits, and budget. Apps switch model families by alias: `AI_GATEWAY_MODEL=mistral`.
- **One endpoint for an agent's tools:** the agent connects once to `commerce` and gets tools from three backends.
- **Tools that act as the user:** `my-orders` passes the user's identity to the backend, not a shared account.

## Deploy and test

You need: an Azure subscription where you're **Owner** (the templates assign roles), the Azure CLI 2.75 or later, the
[aigateway extension][cli], and Python 3.13. Optional: [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli),
for the coding agent check, and the [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
with `azd extension install microsoft.foundry`, for the Foundry hosted agent. Use a region with Azure AI Gateway, `gpt-5-mini`, and Mistral Large 3 (default: Sweden
Central), and a backup region with `gpt-5-mini` (default: France Central, `AZURE_BACKUP_LOCATION`).

For `my-orders`, `deploy.sh` also creates two Microsoft Entra app registrations ([infra/entra](infra/entra)), which needs
only permission to register applications: they pre-authorize each other, so there's no tenant-wide consent. Where you
can't register apps, set `SKIP_ENTRA_APPS=true` and ask an identity administrator to deploy that template.
To add the optional `claude` alias, set `CLAUDE_ORGANIZATION_NAME`, `CLAUDE_COUNTRY_CODE`, and `CLAUDE_INDUSTRY`:
Foundry sends this attestation about your organization to Anthropic, so use your real details.

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
| Access | No token, or a token for another audience, gets `401`. You can call `chat`, `mistral`, and the `shipping` tools, and you get `403` from `commerce`, which no team grants you |
| Routing | `chat` is served from the primary region, and `x-workload: batch` from the backup region, according to the `x-ms-region` response header |
| Users | Through the gateway, the `my-orders` backend sees you (your object ID), not a shared account, and returns only your account's orders |
| Backends | Foundry rejects calls from the internet, and the MCP server has no public DNS name |
| Compliance | The gateway passes [scripts/check_gateway.py](scripts/check_gateway.py) |
| AI app | The support desk summarizes a ticket |
| AI agent | A Container Apps job asks the order assistant a question that needs all three backends of the federated `commerce` server |
| Coding agent | Copilot CLI answers from the `shipping` tools, through the gateway's model |
| Foundry agent | A prompt agent answers through the project's gateway connection |
| Foundry hosted agent | The hosted agent answers an order question from the `commerce` tools, as its own Entra Agent ID |

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

Budgets are estimated spend per identity per day on each model alias ([lab 07][lab07]). Members of a group can't share one budget, so give
each app its own identity; `teams.py` rejects budgets on groups and budgets above the gateway-wide ceiling. The example
files onboard this deployment's identities through `platform:` references: `platform:apps` (the order assistant),
`platform:returns-agent`, `platform:foundry-project`, `platform:hosted-agent` (the hosted agent's Entra Agent ID, which
exists only after Foundry deploys it: `deploy.sh` deploys the agent first, in the same run), and `platform:deployer`
(you). [employees.json](teams/employees.json)
grants `my-orders` to people: in production, put a group of users there.

## Build on the gateway

Every client authenticates with a Microsoft Entra token for `https://ai.gateway.azure.com/.default`: `az login` on a
laptop, a managed identity in Azure. There are no keys. Tools that act as you need the gateway's delegated scope,
`https://ai.gateway.azure.com/Data.All`, in a user's token.

| Workload | Run it | Calls |
|---|---|---|
| User | `./scripts/copilot-with-gateway.sh my-orders -- -p "What are my orders?" --allow-all-tools`, or `python scripts/mcp_call.py my-orders my-orders_my_orders` | `my-orders`, which reaches its backend as you |
| AI app | `python clients/support-desk/summarize.py "<ticket>"` (`AI_GATEWAY_MODEL=mistral` for the other family) | The `chat` alias |
| AI agent | `python clients/aca-agent/ask.py "<question>"` (needs the order-assistant access), or the `agent-smoke` job | `chat`, then the `commerce` MCP server: `orders_*`, `shipping_*`, and `returns_*` tools |
| Foundry agent | `python clients/foundry-agent/agent.py "<question>"` | `ai-gateway/chat` through the project's connection |
| Foundry hosted agent | `cd agents/hosted-order-assistant && azd ai agent invoke hosted-order-assistant "<question>"`, or `F5` in VS Code to run it locally | `chat` and `commerce`, as its Entra Agent ID |
| Coding agent | `./scripts/copilot-with-gateway.sh [-m claude] shipping` | `chat` (or `claude`, when deployed) as Copilot's model, and the `shipping` tools |
| Any OpenAI SDK | `base_url = <gateway>/default/models/openai/v1`, `model = "chat"` or `"mistral"` | |
| Any Anthropic SDK | `base_url = <gateway>/default/models/anthropic`, `model = "claude"` (when deployed) | |
| Any MCP client | `<gateway>/default/toolservers/<server>/mcp`, header `Authorization: Bearer <token>` | |

To see routing and failover, run `./scripts/demo-failover.sh`: it prints the `chat` alias's rules and the region that
served each call. With `--outage`, it takes the primary out for about a minute (the gateway's primary backend model
points at a deployment that doesn't exist, so Foundry answers `404`), and you watch every call fail over to the backup
region and still return `200`; then it puts the primary back. The failure rule ([lab 29][lab29]) covers backend
outages only (no response, `404`, `408`, `423`, `429`, `5xx`); client errors such as a content safety `400` still
reach the caller. Multi-turn Responses API calls that continue a stored response (`previous_response_id`) stay on the
backend that stored it, so they can't fail over: send the conversation history instead where failover matters.

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
gateway, a workspace, or anything above them, model aliases without limits or content safety (a backend model's policy
counts only when every backend of the alias has it, so a failover can't skip it), MCP servers without a rate limit, and
telemetry that captures prompts. It warns about aliases with a single backend. Every applicable policy can block a
call, so an asset's own policies can be stricter than the baseline but never looser.

## Automate with GitHub Actions

[ci.yml](.github/workflows/ci.yml) runs on every push and pull request: lint, unit tests, team file validation, the
access diff, and the Bicep builds. [deploy.yml](.github/workflows/deploy.yml) deploys and tests on merges to `main`
that change teams, the platform, or the apps. It signs in with OpenID Connect, so no secret is stored. Set it up once:

```bash
GITHUB_REPO=<owner>/<repo> AZURE_ENV_NAME=aigw-demo ./scripts/setup-github-deploy.sh
```

It creates an app registration trusted only by the repository's `azure` environment, which only `main` can use, gives
it **Contributor** and **Role Based Access Control Administrator** on the subscription, and stores the IDs as
variables. Until then the deploy job is skipped. In the pipeline, `platform:deployer` stays the developer who ran the
setup, not the pipeline's identity, and the scripts sign in again with a fresh GitHub token before each phase
([ci-login.sh](scripts/ci-login.sh)), because the first sign-in lasts only a few minutes. To remove the pipeline's
access, delete the app registration: `az ad app delete --id <AZURE_CLIENT_ID>`.

## Security

| Layer | Control |
|---|---|
| Callers | Microsoft Entra ID only. Roles on single assets from the team files; the built-in `master` key suspended and no other runtime keys |
| Gateway → backends | The gateway's managed identity calls both Foundry accounts (**Foundry User**); Foundry keys are disabled. For `my-orders`, the gateway exchanges the caller's token **on-behalf-of** through a token exchange app that trusts the gateway's user-assigned identity: no client secret anywhere, and the backend validates issuer, audience, scope, and the requesting app |
| Network | The gateway's outbound calls use **private routing** through a dedicated subnet. Foundry has public access off and a private endpoint. The backends run in an **internal** Container Apps environment and accept traffic only from the gateway's subnet |
| AI controls | Per-caller token limit and content safety on every backend model, so failover keeps them; a daily cost limit per caller on each alias; a per-caller request rate limit on each MCP server; a gateway-wide baseline under all of them |
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
infra/entra/      Bicep (Microsoft Graph): the Entra apps for on-behalf-of, an identity administrator's step
platform/         catalog.json (the published aliases, MCP servers, and their backends), team.schema.json, baseline-policies.json
teams/            one file per team: who can call which assets, and their budgets
clients/          AI app (support-desk), AI agent (aca-agent), Foundry prompt agent (foundry-agent)
agents/           returns specialist agent (returns-agent); Foundry hosted agent (hosted-order-assistant, azd)
tools/            orders and my-orders MCP servers (mcp-server), shipping REST API (shipping-api)
scripts/          deploy, deploy-hosted-agent, test, teardown; teams.py, check_gateway.py, apply_baseline.py,
                  usage_report.py; copilot-with-gateway.sh, mcp_call.py, demo-failover.sh, setup-github-deploy.sh,
                  ci-login.sh
.vscode/          F5: run the hosted agent locally with the Foundry Toolkit Agent Inspector
docs/             demo.md: a 20-minute walkthrough for customer conversations
tests/            unit tests (pytest)
```

## Cost

- **Azure AI Gateway:** 10,000 requests a month free per gateway. Paid billing starts on 1 Jan 2027: $500 a month per
  gateway, including 10 million requests ([announcement][ga]).
- **Everything else is pay-as-you-go:** model tokens in both regions, Container Apps (five apps keep one replica each, to avoid cold
  starts; set `minReplicas` to 0 in [aca-apps.bicep](infra/modules/aca-apps.bicep) to scale to zero), the Basic
  container registry, private endpoints, and log ingestion. Run `teardown.sh` when you're done.

## Limitations and known issues

- **Preview features:** the gateway's private routing and inbound private endpoint are in preview ([lab 18][lab18]).
- **Backend authentication:** `my-orders` validates the user token that the gateway exchanges for it. The other private
  backends rely on network isolation and accept no token from the gateway. For production, give those MCP sources
  managed-identity credentials and validate the token in each server.
- **Failover:** each gateway is regional. The alias fails over across Foundry regions, not across gateway regions: for
  that, run a second gateway and route between them (Azure Front Door), keeping both in sync from this repository.
- **Budgets:** one per caller identity, never pooled across a team. Team totals come from the usage report, not a cap.
- **Previewing access:** `az deployment what-if` can't list the gateway's assets or role assignments, because they
  depend on values from the same deployment. Review the `teams.py diff` summary instead.
- **Not covered here:** Microsoft Agent 365 governance, tool threat protection, and agent hooks ([labs 19, 20,
  30][labs]); Model Router ([lab 28][labs]).
- **Foundry hosted agent:** deployed with azd when you run `deploy.sh` signed in as a user. In GitHub Actions, the
  pipeline keeps the agent's last version and re-grants its Entra Agent ID from the previous deployment; to ship new
  agent code, run `scripts/deploy-hosted-agent.sh`. It calls the gateway's public endpoint, so it needs `hybrid` mode.
- **Claude:** optional and not part of the tested reference deployment, because it needs your organization's
  attestation to Anthropic.
- **Mistral Large 3 and streamed tool calls:** through the gateway, its streamed responses with tool calls come back
  empty, while non-streamed tool calls work. Coding agents stream, so Copilot CLI uses `chat`; use `mistral` from apps.
- **Container registry:** Basic tier with public access, so `az acr build` works. Use Premium with a private endpoint
  in production. The Foundry agent project keeps public access on, Entra ID only, so you can build agents in the portal.
- **Python on OpenSSL 3.5 or later:** calls to the Foundry project endpoint can fail with
  `SSL: UNEXPECTED_EOF_WHILE_READING`, when the default TLS 1.3 handshake's post-quantum key share is dropped. Run the
  Foundry client with `OPENSSL_CONF=clients/foundry-agent/openssl-classic.cnf`; `test.sh` retries with it.

## Sources

- [What is AI Gateway?][overview], [AI Gateway concepts][concepts], and the
  [Azure AI Gateway documentation](https://ai.gateway.azure.com/docs)
- [Azure AI Gateway GA announcement][ga] and the [official labs][labs]: this repo follows labs [18][lab18] (private
  networking), [21][lab21] (enterprise reference), [32][lab32] (Foundry gateway connection), [04][lab04] (federated
  MCP), [16][lab16] (Foundry hosted agent), [27][lab27] (conditional routing), [29][lab29] (failover), and [33][lab33]
  (on-behalf-of), and builds the
  multi-team access model on labs [07][lab07] (cost budgets), [09][lab09] (baselines), [10][lab10] (API keys),
  [11][lab11] (Entra ID and RBAC), [14][lab14] (OpenTelemetry chargeback), and [24][lab24] (GitHub Copilot)
- [Bring your own model to Foundry Agent Service, private gateway networking][byom]

[overview]: https://learn.microsoft.com/en-us/azure/ai-gateway/overview
[concepts]: https://learn.microsoft.com/azure/ai-gateway/concepts
[ga]: https://techcommunity.microsoft.com/blog/integrationsonazureblog/azure-ai-gateway-is-now-generally-available-ship-faster-stay-in-control/4572644
[labs]: https://azure.github.io/aigateway/labs/
[cli]: https://github.com/Azure/aigateway#azure-cli
[lab04]: https://github.com/Azure/aigateway/tree/main/labs/04-federate-mcp-tools
[lab07]: https://github.com/Azure/aigateway/tree/main/labs/07-cost-budgets
[lab09]: https://github.com/Azure/aigateway/tree/main/labs/09-gateway-baselines
[lab10]: https://github.com/Azure/aigateway/tree/main/labs/10-api-keys
[lab11]: https://github.com/Azure/aigateway/tree/main/labs/11-entra-rbac
[lab14]: https://github.com/Azure/aigateway/tree/main/labs/14-otel-chargeback
[lab16]: https://github.com/Azure/aigateway/tree/main/labs/16-foundry-hosted-agent
[lab18]: https://github.com/Azure/aigateway/tree/main/labs/18-private-networking
[lab21]: https://github.com/Azure/aigateway/tree/main/labs/21-enterprise-reference
[lab24]: https://github.com/Azure/aigateway/tree/main/labs/24-github-copilot-byok
[lab27]: https://github.com/Azure/aigateway/tree/main/labs/27-conditional-routing
[lab29]: https://github.com/Azure/aigateway/tree/main/labs/29-model-failover
[lab32]: https://github.com/Azure/aigateway/tree/main/labs/32-foundry-gateway-connection
[lab33]: https://github.com/Azure/aigateway/tree/main/labs/33-copilot-obo-mcp
[byom]: https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway#configure-private-ai-gateway-networking
[pe-access]: https://ai.gateway.azure.com/docs/networking/request-private-endpoint-access
