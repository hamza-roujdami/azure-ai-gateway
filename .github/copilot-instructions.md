# Copilot instructions: azure-ai-gateway

A public community reference implementation: an enterprise-ready **Azure AI Gateway** (standalone service,
`Microsoft.ApiManagement/aigateways`, GA API version `2026-11-01`). Keep everything generic. No customer, tenant,
subscription or personal identifiers in any file.

## Goal (agreed direction)
- **Problem:** run Azure AI Gateway as a shared platform for many teams. Runtime API keys grant gateway-wide access
  ([concepts](https://learn.microsoft.com/azure/ai-gateway/concepts)), so teams are kept apart only by Entra roles
  scoped to individual aliases and MCP servers. Microsoft's labs show each capability for one team; lab 21 is their
  single-team enterprise reference. Don't rebuild lab 21: build the multi-team operating model on top of it.
- **Core idea: onboarding as a pull request.** One file per team in `teams/` (owner, members, allowed aliases and MCP
  servers, per-identity budgets). PR = `teams.py validate` + `teams.py diff` in the job summary; merge = deploy
  (roles, budgets, `teams.py prune`) + end-to-end tests. A team developer then builds keyless with `az login`; an
  ungranted tool returns 403; deleting the file removes access.
- **Platform side:** gateway baseline (private backends, Entra only, gateway-wide policies incl. content safety,
  telemetry with token claims); team files → scoped roles + limits + cost attribution; a read-only **compliance
  check** usable against any gateway (fails on runtime API keys, gateway- or workspace-scoped runtime roles, assets
  without policies, payload capture on, public access not matching the inbound mode); OIDC pipeline as in lab 21.
- **Developer side:** keyless starters for the three workload types (AI app: models only; AI agent: models + MCP;
  coding agent: plugin + MCP, not Copilot BYOK, which needs a runtime key) and a generated per-team quick start.
- **Cover every box in the product's picture** (users, apps, agents, coding agents → models from more than one family
  with routing and failover, federated MCP servers and APIs, an agent as a tool), aligned with the four reasons
  Microsoft's Foundry page gives for the gateway: per-caller limits on shared capacity, failover across regions,
  policies across projects and agents, usage by caller.
- **Budgets are per caller identity, never pooled per team** (lab 07: claim overrides give each matching identity
  its own counter). Enforce per workload identity; report team totals via telemetry (lab 14).
- **Team files are JSON, not Bicep parameter files:** every team's budget override lives in one alias policy, and
  Bicep can't load a folder, so `scripts/teams.py render` merges them into the `teams` parameter (env var
  `AI_GATEWAY_TEAMS`, read by `main.bicepparam`). Teams supply existing Entra object IDs; the repo doesn't create
  groups. `platform/team.schema.json` and `teams.py` must agree (`tests/test_teams.py` guards it).
- **Built so far (all deployed and tested live):** team files and onboarding by pull request; the gateway-wide
  baseline (`platform/baseline-policies.json`, applied by `scripts/apply_baseline.py`); the built-in `master` key
  suspended by `deploy.sh`; three MCP servers (orders MCP, shipping REST API published from OpenAPI, returns
  specialist agent with its own identity); keyless clients for the three workload types; the usage report by team;
  the OIDC deploy workflow; failover across two Foundry regions with a CEL condition (labs 27, 29); a second model
  family (`mistral`) and an optional `claude` alias; the federated `commerce` MCP server (lab 04); the `my-orders`
  on-behalf-of tool for users (lab 33). **Next ideas:** a Foundry hosted agent (lab 16), managed-identity
  authentication for the other MCP sources, Agent 365 and agent hooks (labs 19, 20, 30). Don't claim
  "production-ready" until the matching test passes.

## Architecture (see README.md)
- **Gateway:** system-assigned managed identity with Foundry User on both model accounts, a user-assigned identity
  (`id-aigw-<env>`) for the on-behalf-of token exchange, private routing through `snet-aigw` (delegated
  `Microsoft.App/environments`), `publicNetworkAccess` set from `inboundMode`.
- **Model backends:** `modules/foundry-models.bicep`, twice: `aifm-*` in the main region (gpt-5-mini, Mistral-Large-3,
  optional claude-haiku-5-5) and `aifb-*` in `backupLocation` (gpt-5-mini). Keys off, public access off, private
  endpoints in the main VNet (a cross-region PE is fine), and the 3 Foundry private DNS zones created once. Capacity
  300k TPM, per-caller token limit 150k/min: one Copilot CLI turn sends ~45k tokens, and 20k/min throttled it.
- **Gateway assets:** names come from `platform/catalog.json` (aliases chat, mistral, claude; MCP servers commerce,
  shipping, my-orders; `backends` maps each backend name to its kind and required flag)
  - providers `foundry` and `foundry-backup` (managed identity)
  - backend models, each with `tokenLimit` + `contentSafety`: put policies on every backend, or failover skips them
  - alias `chat`: backends `foundry/gpt-5-mini` (priority 0, `when` = not `x-workload: batch`) and
    `foundry-backup/gpt-5-mini-<backupLocation>` (priority 1), `selectionOrder: ['priority']`, `maxRetryAttempts: 3`,
    `failures: [{ when: response == null || status in [404, 408, 423, 429] || >= 500, excludeFor: 'PT30S' }]` (lab
    29: without `maxRetryAttempts` a failure rule returns an empty 503). A paused Foundry deployment answers **423**
    and a missing one **404**, which a 429/5xx-only rule passes straight to clients. Responses API continuations
    (`previous_response_id`) are pinned to the backend that stored them and never fail over: Copilot CLI hit this.
  - **Simulating an outage:** lowering a deployment's capacity took minutes to throttle, and the preview deployment
    pause/resume reached serving nodes unevenly (the primary kept answering 423 for 40 minutes after a resume). So
    `demo-failover.sh --outage` points the gateway's primary backend model at a missing deployment (404) and puts the
    saved definition back: deterministic, gateway-only, seconds to apply. OTelSpans client spans
    (`server.address`, `http.response.status_code`) show each failed send and its retry on the backup.
  - every alias: a per-caller daily `costLimit` and the team budget overrides (`tid` + `oid` claims)
  - toolServers from `modules/tools.bicep`: `toolServerType: 'mcp'` and one endpoint per backend, namespace = backend
    name (`orders_get_order`), `failClosed` when required, `failOpen` when optional. `mcp` endpoints take `url`,
    `openApi` an inline spec whose `servers[0].url` is the private URL. Each server has `requestRateLimit` as
    `{count, period: 'minute'}`; `callsPerPeriod`/`periodSeconds` are rejected by the GA API.
  - `my-orders`: endpoint `authentication.oauth2` with `grantType: tokenExchange`, profile `entraOnBehalfOf`, the
    token exchange app, and the gateway's user-assigned identity as its credential (lab 33).
- **Callers:** Entra ID only. No runtime API keys are ever created, and the built-in `master` key is suspended.
  `modules/team-access.bicep` turns the `teams` parameter into callers: Models User on the alias, Tools User per
  toolServer, never the workspace or gateway. `platform:deployer|apps|returns-agent|foundry-project` resolve to this
  deployment's identities. Token scope: `https://ai.gateway.azure.com/.default`. Runtime role IDs: Models User
  `a6b68e3d-…`, Tools User `dce03f8d-…`, AI Gateway User `caad7a21-…` (every asset; never grant it broadly).
- **Entra apps (`infra/entra`, Microsoft Graph Bicep):** the my-orders API app and the token exchange app, with a
  federated credential for the gateway's user-assigned identity. **Pre-authorization replaces consent on both hops**
  (exchange app pre-authorizes AI Gateway `18550318-…`; the API pre-authorizes the exchange app), so only app
  registration rights are needed. Tenants may have no service principal for the AI Gateway app, and nobody but
  Microsoft can create one: reference its app ID only. `oauth2PermissionGrants` need an admin; don't use them.
  `deploy.sh` runs it when signed in as a user, otherwise reads the outputs of `entra-<env>` (CI).
- **Backends:** `tools/mcp-server` (orders; `me_server.py` is my-orders, which validates iss, aud, scp and azp of the
  exchanged token), `tools/shipping-api` (FastAPI; `openapi.json` is committed and must match:
  `python shipping.py --write-spec`), `agents/returns-agent` (its own user-assigned identity). All on internal
  Container Apps, VNet ingress restricted to the gateway subnet CIDR, `minReplicas: 1` (cold starts made the gateway
  return 504 to the agent's MCP calls).
- **Clients:**
  - `clients/support-desk`: AI app, one model call, `explain()` maps gateway refusals to actions.
  - `clients/aca-agent`: Agent Framework + FastAPI, user-assigned identity, environment-only ingress, one MCP tool per
    server in `AI_GATEWAY_MCP_SERVERS` (`commerce`), plus the `agent-smoke` job.
  - `clients/foundry-agent`: a prompt agent using the project's gateway connection; model `ai-gateway/chat`.
  - `scripts/copilot-with-gateway.sh`: Copilot CLI with `COPILOT_PROVIDER_BEARER_TOKEN` (an Entra token for
    `Data.All`, which on-behalf-of tools need) and `--additional-mcp-config` for the granted MCP servers; `-m claude`
    uses `COPILOT_PROVIDER_TYPE=anthropic` and `/default/models/anthropic`. Not mistral: through the gateway, Mistral
    Large 3's streamed responses with tool calls come back empty (non-streamed tool calls work), and Copilot streams.
  - `scripts/mcp_call.py`: one MCP tool call as you; `scripts/demo-failover.sh`: routing, batch, and `--outage`.
    The `x-ms-region` response header names the region that served a model call (`x-ms-served-model` names the model).

## Decisions and constraints (keep them; they come from Microsoft docs or live testing)
- **Azure CLI 2.87 changes the case of deployment output names** (`ACR_NAME` → `acR_NAME`). Read outputs with
  `scripts/outputs.py`, never `az deployment sub show --query properties.outputs.X`.
- **In CI, `platform:deployer` is the developer** (`DEVELOPER_PRINCIPAL_ID`), not the pipeline's service principal,
  or `prune` would revoke the developer's access. `test.sh` skips its as-the-developer checks for service principals.
- **Foundry with public access off answers `401`** to calls from the internet (auth is checked first), not 403.
- **Python on OpenSSL 3.5+ fails TLS 1.3 to `*.services.ai.azure.com`** from some networks (post-quantum key share);
  `clients/foundry-agent/openssl-classic.cnf` works around it.
- **Gateway telemetry:** request spans (`OTelSpans`, Kind Server, `POST /default/...`) carry status codes including
  403 and the `oid` claim; request logs (`OTelLogs`) carry model and tool calls (`gen_ai.operation.name =
  execute_tool`) and the cost estimate.
- **Default `INBOUND_MODE=hybrid`.** Foundry Agent Service calls connected models from its managed plane, not the
  VNet, so a Foundry agent needs the gateway's public endpoint (Entra ID only). `private` mode turns the public
  endpoint off and needs the inbound private endpoint.
- **The gateway's inbound private endpoint is preview.** The subscription needs access via an Azure support request
  (feature `Microsoft.Network/AllowPrivateEndpoints` = Registered). It stays off by default
  (`GATEWAY_PRIVATE_ENDPOINT=false`).
- **Resource names that depend on runtime values go in their own module, with the value passed as a parameter.**
  This applies to the gateway's private DNS zone and the Container Apps DNS zone; Bicep error BCP120 otherwise.
- **Telemetry exporter:** deployed by `infra/scripts/connect-telemetry.sh` after the OTLP endpoints exist. Bicep can't
  wait for them.
- **`OpenAIChatClient(api_key=...)` must get an async callable.** A sync token provider fails every model call
  (`tests/test_aca_agent.py` guards this). `MCPStreamableHTTPTool.header_provider` is sync and called per request.
- **Pinned to the versions in Microsoft's lab 15:** `agent-framework-core` 1.22, `mcp` 1.30. Newer `mcp` 2.x needs the
  legacy handshake against the gateway's MCP endpoint.
- **Claude on Foundry needs `modelProviderData` (organizationName, countryCode, industry)**, an attestation Foundry
  sends to Anthropic. Never fill it in for the user: the `claude` alias deploys only when `CLAUDE_ORGANIZATION_NAME`
  is set. Mistral Large 3 is sold by Azure and needs nothing.
- **Foundry deployments fail while the account is `Accepted`** (updating, for example after private endpoint or
  diagnostic changes): they depend on those, and run one at a time.
- **Don't edit `scripts/deploy.sh` while it runs:** bash reads scripts as it goes.
- **Reference material:** Microsoft's labs in github.com/Azure/aigateway (04 federation, 18 private networking, 21
  enterprise reference, 27 conditions, 29 failover, 32 Foundry connection, 33 on-behalf-of). Check them before
  changing resource shapes.

## Tooling
- `az aigateway` CLI extension (preview, install with `https://aka.ms/aigateway-cli-install`): used by the scripts
  and for reading a deployed gateway.
- Copilot CLI plugin `aigateway@azure` (`/plugin marketplace add Azure/aigateway`, `/plugin install aigateway@azure`):
  use `manage-ai-gateway` for resource shapes and `/aigateway:discover <gateway resource ID>` to compare a
  deployment with the Bicep. **Bicep is the source of truth:** don't change gateways with `/aigateway:create`,
  `/aigateway:manage` or `az aigateway` write commands.

## Commands
```bash
python3.13 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
ruff check . && ruff format --check . && pytest -q
python scripts/teams.py validate
az bicep build -f infra/main.bicep --stdout > /dev/null
AI_GATEWAY_TEAMS="$(python scripts/teams.py render)" az bicep build-params -f infra/main.bicepparam --stdout > /dev/null
AZURE_ENV_NAME=aigw-whatif DEPLOY_APPS=true AI_GATEWAY_TEAMS="$(python scripts/teams.py render)" \
  az deployment sub what-if -l swedencentral -f infra/main.bicep -p infra/main.bicepparam   # read-only
./scripts/deploy.sh && ./scripts/test.sh && ./scripts/teardown.sh   # creates Azure resources: ask first
```

## Status
- **Deployed and tested live** (Sweden Central): `scripts/test.sh` passes every check: 401 without a token or with a
  wrong audience; the developer allowed `chat`, `mistral` and `shipping`, denied `commerce` (403); `chat` served
  from the primary region and `x-workload: batch` from the backup (CEL); `my-orders` sees the developer's object ID
  and returns only their account's orders (on-behalf-of); Foundry and the
  MCP server not reachable from the internet; the compliance check; the AI app, the order agent across the three
  backends of the federated `commerce` server, Copilot CLI on the gateway's model and shipping tools, and the Foundry
  prompt agent. Also proven live: `demo-failover.sh --outage` (primary answers 404, every client call 200 from the
  backup, then restored); Copilot CLI listing the developer's own orders through `my-orders`; the
  `master` key answers 401 once suspended; `teams.py prune` removed a stray grant and the gateway answered 403 about a
  minute later; `usage_report.py` shows denials, throttling and 5xx per team member; the deploy workflow signs in
  with OIDC (new role assignments need a couple of minutes before the first sign-in finds the subscription).
- A read-only what-if can't expand the gateway's child assets or the team role assignments, because they depend on
  values from the same deployment.

## Working rules
- Don't deploy without explicit approval; deployments cost money. Commit and push only when the user asks.
- Claims in the README must be sourced from Microsoft docs or the official labs.
- Keep the README short. Put design detail in code comments.
