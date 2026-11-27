// Parameters for scripts/deploy.sh. Values come from environment variables so one file serves every environment.
using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'aigw-demo')
param location = readEnvironmentVariable('AZURE_LOCATION', 'swedencentral')
param principalId = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')
param principalType = readEnvironmentVariable('AZURE_PRINCIPAL_TYPE', 'User')

// hybrid (default) or private. private needs GATEWAY_PRIVATE_ENDPOINT=true, which needs preview access.
param inboundMode = readEnvironmentVariable('INBOUND_MODE', 'hybrid')
param gatewayPrivateEndpoint = bool(readEnvironmentVariable('GATEWAY_PRIVATE_ENDPOINT', 'false'))

param deployApps = bool(readEnvironmentVariable('DEPLOY_APPS', 'false'))
param imageTag = readEnvironmentVariable('IMAGE_TAG', 'latest')

param modelName = 'gpt-5-mini'
param modelVersion = '2025-08-07'
// Coding agents send about 45,000 tokens a turn, so the per-caller limit and the capacity leave room for them.
param modelCapacity = 300
param tokensPerMinutePerCaller = 150000
param contentSafetySeverity = 'Medium'
param dailyBudgetPerCallerUsd = '5'

// The chat alias fails over to the same model in this region.
param backupLocation = readEnvironmentVariable('AZURE_BACKUP_LOCATION', 'francecentral')
param backupModelCapacity = 100

// Optional: Claude needs your organization's attestation, which Foundry sends to Anthropic. Set all three to deploy
// the claude alias; leave CLAUDE_ORGANIZATION_NAME empty to skip it.
param claudeOrganizationName = readEnvironmentVariable('CLAUDE_ORGANIZATION_NAME', '')
param claudeCountryCode = readEnvironmentVariable('CLAUDE_COUNTRY_CODE', 'US')
param claudeIndustry = readEnvironmentVariable('CLAUDE_INDUSTRY', 'technology')

// Microsoft Entra apps for the my-orders MCP server (on-behalf-of), from infra/entra. scripts/deploy.sh sets them.
param onBehalfOfBackendAppId = readEnvironmentVariable('ON_BEHALF_OF_BACKEND_APP_ID', '')
param onBehalfOfTokenExchangeAppId = readEnvironmentVariable('ON_BEHALF_OF_TOKEN_EXCHANGE_APP_ID', '')

// The Foundry hosted agent's Entra Agent ID, for platform:hosted-agent. scripts/deploy.sh sets it.
param hostedAgentPrincipalId = readEnvironmentVariable('HOSTED_AGENT_PRINCIPAL_ID', '')

// Who can call what: scripts/deploy.sh sets AI_GATEWAY_TEAMS from the files in teams/ (scripts/teams.py render).
param teams = json(readEnvironmentVariable('AI_GATEWAY_TEAMS', '[]'))
