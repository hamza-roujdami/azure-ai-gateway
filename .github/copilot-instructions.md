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
- **Backends, added one at a time with a test:** Foundry model (later a second deployment for failover), private
  `orders` MCP server, then a shipping API exposed as a tool, then a returns specialist agent behind an MCP tool.
- **Budgets are per caller identity, never pooled per team** (lab 07: claim overrides give each matching identity
  its own counter). Enforce per workload identity; report team totals via telemetry (lab 14).
- **Team files are JSON, not Bicep parameter files:** every team's budget override lives in one alias policy, and
  Bicep can't load a folder, so `scripts/teams.py render` merges them into the `teams` parameter (env var
  `AI_GATEWAY_TEAMS`, read by `main.bicepparam`). Teams supply existing Entra object IDs; the repo doesn't create
  groups. `platform/team.schema.json` and `teams.py` must agree (`tests/test_teams.py` guards it).
- **Next, in order:** gateway-wide baseline policies (lab 09, merge script, since declaring the `default` workspace
  in Bicep would replace it); keyless starters for the AI app and the coding agent; telemetry claims for per-team
  reports (lab 14); OIDC deploy pipeline (lab 21); then the extra backends. Don't claim "production-ready" until the
  matching test passes.

## Architecture (see README.md)
- **Gateway:** system-assigned managed identity with Foundry User on the model account, private routing through
  `snet-aigw` (delegated `Microsoft.App/environments`), `publicNetworkAccess` set from `inboundMode`.
- **Model backend:** Foundry account with `disableLocalAuth: true`, `publicNetworkAccess: Disabled`, a private
  endpoint, and the 3 Foundry private DNS zones.
- **Gateway assets:** names come from `platform/catalog.json` (one alias, one MCP server today)
  - provider `foundry` (managed identity)
  - model with `tokenLimit` + `contentSafety` policies
  - alias `chat` with a per-caller daily `costLimit` and the team budget overrides (`tid` + `oid` claims)
  - toolServer `orders` with `requestRateLimit`
- **Callers:** Entra ID only. No runtime API keys are ever created. `modules/team-access.bicep` turns the `teams`
  parameter into callers: Models User on the alias, Tools User on the toolServer, never the workspace or gateway.
  `platform:deployer|apps|foundry-project` in team files resolve to this deployment's identities. Token scope:
  `https://ai.gateway.azure.com/.default`. Runtime role IDs: Models User `a6b68e3d-…`, Tools User `dce03f8d-…`,
  AI Gateway User `caad7a21-…` (every asset; never grant it broadly).
- **Private MCP server:** `tools/mcp-server`, on an internal Container Apps environment. VNet ingress restricted to
  the gateway subnet CIDR.
- **Clients:**
  - `clients/aca-agent`: Agent Framework + FastAPI, user-assigned identity, environment-only ingress, plus the
    `agent-smoke` job.
  - `clients/foundry-agent`: a prompt agent using the project's gateway connection; model `ai-gateway/chat`.

## Decisions and constraints (keep them; they come from Microsoft docs)
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
- **Reference material:** Microsoft's labs in github.com/Azure/aigateway (18 private networking, 21 enterprise
  reference, 32 Foundry connection). Check them before changing resource shapes.

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
- Verified offline: Bicep build and lint, `build-params` with the rendered teams, 35 unit tests, a local MCP server
  run. A read-only what-if succeeds (34 creates, 4 unsupported Container Apps DNS records); it can't expand the
  gateway's child assets or the team role assignments, because they depend on values from the same deployment.
- **Not yet deployed.** Unproven until a deployment:
  - the gateway resolving the internal Container Apps DNS
  - the MCP ingress IP restriction allowing the gateway subnet
  - `publicNetworkAccess` on the gateway at creation
  - the alias `costLimit` with claim overrides, and `teams.py prune` and `check_gateway.py` against a live gateway
    (REST list paths taken from the `az aigateway` extension)
  - the 403 for a token without Tools User on the MCP endpoint

## Working rules
- Don't deploy without explicit approval; deployments cost money. Commit and push only when the user asks.
- Claims in the README must be sourced from Microsoft docs or the official labs.
- Keep the README short. Put design detail in code comments.
