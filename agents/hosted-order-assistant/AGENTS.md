# Coding agent instructions: hosted-order-assistant

A Microsoft Foundry hosted agent (Responses protocol, Microsoft Agent Framework, Python) in the azure-ai-gateway
repository. Its code runs on Foundry Agent Service, and every model and tool call goes through the repository's Azure
AI Gateway as the agent's own Microsoft Entra Agent ID. Read `.github/copilot-instructions.md` at the repository root
for the gateway, the team files, and the deployment.

This project was built with the microsoft-foundry skill. Before working on or answering questions about Foundry
agents, read the microsoft-foundry skill first; if you are in VS Code, read the vscode-microsoft-foundry skill first.

## Rules
- **No model deployments in the Foundry project and no keys.** The model is the gateway's `chat` alias
  (`AI_GATEWAY_MODEL`) and the tools are the gateway's `commerce` MCP server (`AI_GATEWAY_TOOLS`). Don't add
  `deployments` to `azure.yaml` or switch to `FoundryChatClient`.
- **Access comes from `teams/foundry-hosted-agents.json`** (member `platform:hosted-agent`). Without it the gateway
  answers 403, which is the point.
- **Pinned to Agent Framework 1.22, `agent-framework-foundry-hosting` 1.0.0b261015, and `mcp` 1.30** (`requirements.txt`).
  mcp 2.x negotiates an MCP protocol version that the gateway's MCP servers reject.
- `"store": False`: Foundry keeps the history, and stateless model calls can fail over between regions.

## Commands (from this folder; prefix azd with `AZURE_DEV_USER_AGENT=microsoft_foundry_skill` when you're a coding agent)
```bash
../../scripts/deploy-hosted-agent.sh                                  # from the repository root: deploy + print the Agent ID
azd ai agent run --no-client                                          # local run on http://localhost:8088, as you:
                                                                      # only your grants (shipping), not commerce
azd ai agent invoke --local "What is the status of order 1001?"
azd ai agent invoke hosted-order-assistant "What is the status of order 1001?"   # the deployed agent
```
