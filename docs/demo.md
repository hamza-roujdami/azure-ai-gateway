# Demo: run Azure AI Gateway as a shared platform

A 25-minute walkthrough for a customer conversation with a platform team and their developers. Deploy and run
`./scripts/test.sh` the day before: role changes take several minutes to apply, and the first calls warm the backends.

**The story:** a platform team runs one Azure AI Gateway for many teams, the hub-and-spoke model from Microsoft's
Foundry guidance. It publishes two model families behind stable names, tools from an MCP server, a REST API, and a
specialist agent, and decides who can call what with team files in Git. Users, apps, agents, and coding agents build
with what they were granted, with no keys, and the platform team can explain every call.

The scenes follow the four reasons Microsoft gives for adding the gateway to Foundry: per-caller limits on shared
capacity, failover across regions, policies across projects and agents, and usage by caller.

Open these before you start: the [AI Gateway portal](https://ai.gateway.azure.com) on your gateway, the repository in
VS Code, and a terminal in the repository folder with `.env` from `deploy.sh` loaded (`set -a; source .env; set +a`).

## 1. The problem (2 minutes)

Show [Microsoft's architecture](https://learn.microsoft.com/azure/ai-gateway/overview) and the table under
**Architecture** in the README: every box is deployed. Then make the point that shapes the rest of the demo:

> A runtime API key can call every model and tool on the gateway, and every gateway has a built-in `master` key. With
> one team, that's fine. With twenty, a key handed to one team works for all the others' tools. So this platform uses
> no keys at all: every caller signs in with Entra ID and gets roles on single assets.

```bash
az aigateway api-key list -g "$AZURE_RESOURCE_GROUP" --gateway-name "$AI_GATEWAY_NAME" --query "[].{key:name, state:properties.state}" -o table
```

The built-in `master` key shows as `suspended`: `deploy.sh` suspends it.

## 2. Who can call what lives in Git (4 minutes)

Open [teams/](../teams/). Each file is a team: its members, the models and tools they can call, and a budget.

| Team | Kind of caller | Can call |
|---|---|---|
| `order-assistant` | AI agent | `chat`, `commerce` |
| `returns-specialist` | An agent behind a tool, as its own identity | `chat` |
| `foundry-agents` | Foundry prompt agents | `chat` |
| `support-desk` | AI app | `chat` |
| `coding-agents` | Coding agents | `chat`, `mistral`, `shipping` |
| `employees` | Users | `my-orders` |

You are the developer in the last three. Show the review experience: in VS Code, add `"commerce"` to `tools` in
[teams/support-desk.json](../teams/support-desk.json), and print what a reviewer would see. Then undo it.

```bash
python scripts/teams.py diff --base HEAD
git checkout teams/support-desk.json
```

> In a pull request, CI writes this table to the job summary. After the merge, the deploy workflow applies it, and
> removes any runtime role that no file grants. Offboarding a team is deleting its file.

## 3. Developers build with it (5 minutes)

Print the quick start the platform team sends a team, then run the AI app: one model call, signed in with `az login`,
no key, no Foundry endpoint.

```bash
python scripts/teams.py quickstart coding-agents
python clients/support-desk/summarize.py
```

Now try what you weren't granted. The gateway answers before any backend is called:

```bash
python scripts/mcp_call.py shipping --list     # the shipping_* tools
python scripts/mcp_call.py commerce --list     # 403: no team grants you commerce
```

Switch model family by name: the same app on `mistral`, with the same identity, limits, and telemetry.

```bash
AI_GATEWAY_MODEL=mistral python clients/support-desk/summarize.py
```

The same access follows the developer into their coding agent, with their identity, limits, and budget:

```bash
./scripts/copilot-with-gateway.sh shipping -- -p "Get an express quote for WIDGET-42 to Norway" --allow-all-tools
```

> The shipping backend is a plain REST API. The gateway publishes it as MCP tools from its OpenAPI description, so the
> API team changes nothing.

## 4. Resilience: one alias, two regions (4 minutes)

Apps always send `"model": "chat"`. Show what the platform team put behind that name, and which backend answers:

```bash
./scripts/demo-failover.sh --outage
```

It prints the alias's rules, then three kinds of traffic, reading the `x-ms-region` response header:

1. **Interactive calls** go to Sweden Central, priority 0.
2. **`x-workload: batch` calls** go to France Central: a CEL condition makes the primary ineligible for them, so batch
   jobs never use the capacity interactive users need.
3. **An outage of the primary:** the script points the gateway's primary backend model at a deployment that doesn't
   exist in Sweden Central, as when a model is retired or removed in one region, then sends a burst. Foundry answers
   `404`; the failure rule sends each call on to France Central and keeps the primary out for 30 seconds. The client
   sees only `200`s. Then the script puts the primary back. In **Monitoring** > **Traces**, show a call with a `404`
   from the primary and a `200` from the backup.

> The failure rule covers backend outages only: no response, `404`, `408`, `423`, `429`, and `5xx`. A content safety
> `400` still reaches the caller, because another backend wouldn't help. A multi-turn Responses API conversation that
> continues a stored response stays on the backend that stored it, so it can't fail over.

> Token limits and content safety are on both backend models, so a failover never skips them. The compliance check
> verifies that, and warns about any alias with a single backend.

## 5. Agents and tools (4 minutes)

Run the order assistant from inside the private network: a Container Apps job calls it, and its question needs all
three backends of the `commerce` MCP server.

```bash
EXEC="$(az containerapp job start -n "$AGENT_SMOKE_JOB" -g "$AZURE_RESOURCE_GROUP" --query name -o tsv)"
sleep 90
az containerapp job logs show -n "$AGENT_SMOKE_JOB" -g "$AZURE_RESOURCE_GROUP" --execution "$EXEC" --container smoke --format text | grep -E "Q:|A:"
```

> `commerce` is one endpoint that federates three backends: `orders_*` from an MCP server, `shipping_*` from a REST
> API, and `returns_*` from a specialist agent. The agent connects once. The returns specialist reasons with the model
> through the gateway as its own identity, with its own team file and budget, and can only recommend.

Then a Foundry prompt agent, which has no model deployment: it uses the gateway's model through the project's
connection.

```bash
python clients/foundry-agent/agent.py "In one sentence, why use an AI gateway?"
```

## 6. Users: a tool that acts as you (3 minutes)

Ask Copilot for your own orders. The `my-orders` tool runs as you:

```bash
./scripts/copilot-with-gateway.sh my-orders -- -p "Who am I to the orders system, and what are my orders?" --allow-all-tools
```

> The gateway checks your role on `my-orders`, then exchanges your token with Microsoft Entra ID on-behalf-of, signing
> in with its managed identity: no secret. The backend receives a token for itself that still names you, checks who
> requested it, and returns only your account's orders. A colleague gets theirs, from the same tool.

## 7. The platform team explains every call (3 minutes)

Usage by team, from the gateway's OpenTelemetry data, with denials and throttling per identity:

```bash
python scripts/usage_report.py "$AZURE_ENV_NAME" --hours 24
```

The compliance check, which works on any gateway the customer can read:

```bash
python scripts/check_gateway.py "$AI_GATEWAY_ID"
```

In the portal, open **Monitoring** for usage, estimated cost, and the failover you just caused, and **Policies** for
the gateway-wide baseline: token, request, and cost limits and content safety under every model and tool, including
ones added later.

## Questions you'll get

- **Can a team share one budget?** No: budgets count per identity. Give each app its own identity, and use the usage
  report for team totals.
- **Is it private?** The backends are: both Foundry accounts and the Container Apps backends accept only the gateway.
  The gateway's private routing and inbound private endpoint are in preview; `hybrid` mode keeps an Entra-only public
  endpoint, which Foundry agents need.
- **What if the gateway's region fails?** Failover here is across model regions. For the gateway itself, deploy a
  second gateway from this repository in another region and route between them with Azure Front Door.
- **What about Claude?** Set `CLAUDE_ORGANIZATION_NAME` and the two other attestation values, and `deploy.sh` adds a
  `claude` alias on the Anthropic Messages API (`copilot-with-gateway.sh -m claude`).
- **What about Agent 365, tool threat protection, agent hooks, and Model Router?** Not in this repo; see Microsoft's
  [labs](https://azure.github.io/aigateway/labs/) 19, 20, 28, and 30.
- **What does it cost?** See **Cost** in the README.
