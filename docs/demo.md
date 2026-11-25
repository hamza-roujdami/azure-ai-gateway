# Demo: run Azure AI Gateway as a shared platform

A 20-minute walkthrough for a customer conversation with a platform team and their developers. Deploy and run
`./scripts/test.sh` the day before: role changes take several minutes to apply, and the first calls warm the backends.

**The story:** a platform team runs one Azure AI Gateway for many teams. It publishes a model, two tool backends, and a
specialist agent, and decides who can call what with team files in Git. Developers build with what they were granted,
with no keys, and the platform team can explain every call.

Open these before you start: the [AI Gateway portal](https://ai.gateway.azure.com) on your gateway, the repository in
VS Code, and a terminal in the repository folder with `.env` from `deploy.sh`.

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

Open [teams/](../teams/). Each file is a team: its members, the model and tools they can call, and a budget.

| Team | Can call |
|---|---|
| `order-assistant` | `chat`, `orders`, `shipping`, `returns` |
| `returns-specialist` | `chat` (the specialist agent's own identity) |
| `foundry-agents` | `chat` |
| `support-desk`, `coding-agents` | `chat`, `shipping` (that's you) |

Show the review experience. Grant yourself the orders tools in a scratch change, and print what a reviewer would see:

```bash
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path("teams/support-desk.json"); d = json.loads(p.read_text()); d["tools"] = ["orders"]
p.write_text(json.dumps(d, indent=2) + "\n")
EOF
python scripts/teams.py diff --base HEAD
git checkout teams/support-desk.json
```

> In a pull request, CI writes this table to the job summary. After the merge, the deploy workflow applies it, and
> removes any runtime role that no file grants. Offboarding a team is deleting its file.

## 3. A developer builds with it (5 minutes)

Print the quick start the platform team sends the support desk team:

```bash
python scripts/teams.py quickstart support-desk
```

Run the AI app: one model call, signed in with `az login`, no key, no Foundry endpoint.

```bash
python clients/support-desk/summarize.py
```

Now try what you weren't granted. The gateway answers before any backend is called:

```bash
TOKEN="$(az account get-access-token --scope https://ai.gateway.azure.com/.default --query accessToken -o tsv)"
for s in shipping orders returns; do
  printf "%-9s " "$s"; curl -s -o /dev/null -w '%{http_code}\n' -X POST "$AI_GATEWAY_URL/default/toolservers/$s/mcp" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}'
done
```

`shipping` answers `200`, `orders` and `returns` answer `403`.

The same access follows the developer into their coding agent. Copilot CLI uses the gateway's model and the shipping
tools, with the developer's identity, limits, and budget:

```bash
./scripts/copilot-with-gateway.sh shipping -- -p "Get an express quote for WIDGET-42 to Norway" --allow-all-tools
```

> The shipping backend is a plain REST API. The gateway publishes it as MCP tools from its OpenAPI description, so the
> API team changes nothing.

## 4. Agents, including an agent as a backend (4 minutes)

Run the order assistant from inside the private network: a Container Apps job calls it, and its question needs the
orders tools, the shipping API, and the returns specialist.

```bash
EXEC="$(az containerapp job start -n "$AGENT_SMOKE_JOB" -g "$AZURE_RESOURCE_GROUP" --query name -o tsv)"
sleep 90
az containerapp job logs show -n "$AGENT_SMOKE_JOB" -g "$AZURE_RESOURCE_GROUP" --execution "$EXEC" --container smoke --format text | grep -E "Q:|A:"
```

> The returns specialist is an agent behind an MCP tool. The order assistant delegates one decision to it; the
> specialist reasons with the model through the gateway as its own identity, with its own team file and budget. It can
> only recommend.

Then a Foundry prompt agent, which has no model deployment: it uses the gateway's model through the project's
connection.

```bash
python clients/foundry-agent/agent.py "In one sentence, why use an AI gateway?"
```

## 5. The platform team explains every call (4 minutes)

Usage by team, from the gateway's OpenTelemetry data, with denials and throttling per identity:

```bash
python scripts/usage_report.py "$AZURE_ENV_NAME" --hours 24
```

The compliance check, which works on any gateway the customer can read:

```bash
python scripts/check_gateway.py "$AI_GATEWAY_ID"
```

In the portal, open **Monitoring** for usage and estimated cost, and **Policies** for the gateway-wide baseline: token,
request, and cost limits and content safety under every model and tool, including ones added later.

## Questions you'll get

- **Can a team share one budget?** No: budgets count per identity. Give each app its own identity, and use the usage
  report for team totals.
- **Is it private?** The backends are: Foundry and the Container Apps backends accept only the gateway. The gateway's
  inbound private endpoint is in preview; `hybrid` mode keeps an Entra-only public endpoint, which Foundry agents need.
- **What about Agent 365, tool threat protection, routing, and failover?** Not in this repo; see Microsoft's
  [labs](https://azure.github.io/aigateway/labs/) 19, 20, 22, 29, and 30.
- **What does it cost?** See **Cost** in the README.
