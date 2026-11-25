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
param modelCapacity = 50
param tokensPerMinutePerCaller = 20000
param contentSafetySeverity = 'Medium'
param dailyBudgetPerCallerUsd = '5'

// Who can call what: scripts/deploy.sh sets AI_GATEWAY_TEAMS from the files in teams/ (scripts/teams.py render).
param teams = json(readEnvironmentVariable('AI_GATEWAY_TEAMS', '[]'))
