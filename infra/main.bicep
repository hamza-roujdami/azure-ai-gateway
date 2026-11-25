// Secure end-to-end AI gateway on Azure, built on Azure AI Gateway (Microsoft.ApiManagement/aigateways).
// One subscription-scope deployment creates one resource group:
//
//   network          VNet: snet-aigw (gateway private routing), snet-aca (Container Apps), snet-pe (private endpoints)
//   monitoring       Log Analytics + Application Insights (OTLP)
//   foundry-models   Foundry account + model deployment: keys off, public access off, private endpoint
//   gateway          AI Gateway with private routing; managed identity has Foundry User on the model account
//   models           provider (managed identity) + model (token limit, content safety) + alias (cost limit) + roles
//   foundry-agents   Foundry project for Agent Service, connected to the gateway (no model deployments)
//   registry         container registry + the apps' user-assigned identity
//   aca-env/-dns     internal Container Apps environment + private DNS
//   aca-apps         private MCP server, Agent Framework agent, smoke-test job           (deployApps = true)
//   tools            the MCP server federated behind the gateway + Tools User roles       (deployApps = true)
//
// Who can call what comes from the team files in teams/ (the teams parameter, rendered by scripts/teams.py):
// team-access turns them into the role assignments and budgets of each asset. The asset names come from
// platform/catalog.json. scripts/deploy.sh runs the deployment twice: first without the apps, then builds the images
// and deploys again with them.
targetScope = 'subscription'

import { team } from 'modules/types.bicep'

@minLength(1)
@maxLength(20)
@description('Short environment name. The resource group is rg-<environmentName>.')
param environmentName string

@description('Region for everything. It must offer Azure AI Gateway, Container Apps and the model.')
param location string = 'swedencentral'

@description('Object ID of the person deploying. Gets Foundry User to build agents; team files refer to it as platform:deployer. Empty in CI.')
param principalId string = ''

@allowed([ 'User', 'Group', 'ServicePrincipal' ])
param principalType string = 'User'

@allowed([ 'hybrid', 'private' ])
@description('hybrid: public endpoint on (Entra ID only) + optional private endpoint. private: public endpoint off; needs gatewayPrivateEndpoint.')
param inboundMode string = 'hybrid'

@description('Create the gateway\'s inbound private endpoint. Preview: needs access for the subscription first.')
param gatewayPrivateEndpoint bool = false

@description('Deploy the container apps and the MCP tool server. Needs the images in the registry (scripts/deploy.sh).')
param deployApps bool = false

@description('Image tag for the agent and MCP server images.')
param imageTag string = 'latest'

param modelName string = 'gpt-5-mini'
param modelVersion string = '2025-08-07'

@description('Model capacity in thousands of tokens per minute.')
@minValue(1)
param modelCapacity int = 300

@minValue(1)
param tokensPerMinutePerCaller int = 150000

@allowed([ 'None', 'Low', 'Medium', 'High' ])
param contentSafetySeverity string = 'Medium'

@description('Estimated spend each caller can use per day on the model alias, in US dollars. Team files can override it per identity.')
param dailyBudgetPerCallerUsd string = '5'

@description('Teams and the assets their members can call, from scripts/teams.py render. Nobody gets runtime access without one.')
param teams team[] = []

param tags object = {}

var token = take(uniqueString(subscription().id, environmentName, location), 6)
var allTags = union({ 'azd-env-name': environmentName, workload: 'ai-gateway' }, tags)
var catalog = loadJsonContent('../platform/catalog.json')
var aliasName = catalog.models[0].alias
var toolNames = map(catalog.tools, t => t.server)
var shippingSpec = loadJsonContent('../tools/shipping-api/openapi.json')
var toolsUserRoleId = 'dce03f8d-857f-4e40-a90d-67770fa6ecd2'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: allTags
}

module network 'modules/network.bicep' = {
  scope: rg
  name: 'network'
  params: {
    location: location
    tags: allTags
    vnetName: 'vnet-${environmentName}'
  }
}

module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    location: location
    tags: allTags
    logAnalyticsName: 'log-${environmentName}'
    appInsightsName: 'appi-${environmentName}'
  }
}

module foundryModels 'modules/foundry-models.bicep' = {
  scope: rg
  name: 'foundry-models'
  params: {
    location: location
    tags: allTags
    accountName: 'aifm-${token}'
    modelName: modelName
    modelVersion: modelVersion
    deploymentName: modelName
    capacity: modelCapacity
    vnetId: network.outputs.vnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    logAnalyticsId: monitoring.outputs.logAnalyticsId
  }
}

module gateway 'modules/gateway.bicep' = {
  scope: rg
  name: 'gateway'
  params: {
    location: location
    tags: allTags
    gatewayName: 'aigw-${token}'
    integrationSubnetId: network.outputs.gatewaySubnetId
    publicNetworkAccess: inboundMode == 'private' ? 'Disabled' : 'Enabled'
    foundryAccountName: foundryModels.outputs.accountName
  }
}

module gatewayPe 'modules/gateway-private-endpoint.bicep' = if (gatewayPrivateEndpoint) {
  scope: rg
  name: 'gateway-private-endpoint'
  params: {
    location: location
    tags: allTags
    gatewayId: gateway.outputs.gatewayId
    hostName: gateway.outputs.hostName
    subnetId: network.outputs.privateEndpointSubnetId
    vnetId: network.outputs.vnetId
  }
}

module registry 'modules/registry.bicep' = {
  scope: rg
  name: 'registry'
  params: {
    location: location
    tags: allTags
    registryName: 'acraigw${token}'
    identityName: 'id-apps-${environmentName}'
    returnsIdentityName: 'id-returns-${environmentName}'
    logAnalyticsId: monitoring.outputs.logAnalyticsId
  }
}

module acaEnv 'modules/aca-env.bicep' = {
  scope: rg
  name: 'aca-env'
  params: {
    location: location
    tags: allTags
    environmentName: 'cae-${environmentName}'
    subnetId: network.outputs.acaSubnetId
    logAnalyticsId: monitoring.outputs.logAnalyticsId
  }
}

module acaDns 'modules/aca-dns.bicep' = {
  scope: rg
  name: 'aca-dns'
  params: {
    tags: allTags
    defaultDomain: acaEnv.outputs.defaultDomain
    staticIp: acaEnv.outputs.staticIp
    vnetId: network.outputs.vnetId
  }
}

module foundryAgents 'modules/foundry-agents.bicep' = {
  scope: rg
  name: 'foundry-agents'
  params: {
    location: location
    tags: allTags
    accountName: 'aifa-${token}'
    gatewayId: gateway.outputs.gatewayId
    gatewayUrl: gateway.outputs.gatewayUrl
    gatewayLocation: gateway.outputs.gatewayLocation
    aliasName: aliasName
    modelName: modelName
    modelVersion: modelVersion
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    principalId: principalId
    principalType: principalType
  }
}

module teamAccess 'modules/team-access.bicep' = {
  scope: rg
  name: 'team-access'
  params: {
    teams: teams
    platformPrincipals: {
      'platform:deployer': principalId
      'platform:apps': registry.outputs.identityPrincipalId
      'platform:returns-agent': registry.outputs.returnsIdentityPrincipalId
      'platform:foundry-project': foundryAgents.outputs.projectPrincipalId
    }
    platformPrincipalTypes: {
      'platform:deployer': principalType
      'platform:apps': 'ServicePrincipal'
      'platform:returns-agent': 'ServicePrincipal'
      'platform:foundry-project': 'ServicePrincipal'
    }
    aliasName: aliasName
    toolNames: toolNames
  }
}

module models 'modules/models.bicep' = {
  scope: rg
  name: 'models'
  params: {
    gatewayName: gateway.outputs.gatewayName
    foundryEndpoint: foundryModels.outputs.endpoint
    foundryAccountId: foundryModels.outputs.accountId
    deploymentId: foundryModels.outputs.deploymentId
    modelName: modelName
    modelVersion: modelVersion
    aliasName: aliasName
    tokensPerMinutePerCaller: tokensPerMinutePerCaller
    contentSafetySeverity: contentSafetySeverity
    dailyBudgetPerCallerUsd: dailyBudgetPerCallerUsd
    costOverrides: teamAccess.outputs.costOverrides
    callers: teamAccess.outputs.modelCallers
  }
}

module apps 'modules/aca-apps.bicep' = if (deployApps) {
  scope: rg
  name: 'aca-apps'
  dependsOn: [ acaDns, models ]
  params: {
    location: location
    tags: allTags
    environmentId: acaEnv.outputs.environmentId
    registryServer: registry.outputs.loginServer
    identityId: registry.outputs.identityId
    identityClientId: registry.outputs.identityClientId
    returnsIdentityId: registry.outputs.returnsIdentityId
    returnsIdentityClientId: registry.outputs.returnsIdentityClientId
    imageTag: imageTag
    gatewayUrl: gateway.outputs.gatewayUrl
    aliasName: aliasName
    agentMcpServers: join(toolNames, ',')
    gatewaySubnetPrefix: network.outputs.gatewaySubnetPrefix
  }
}

// The backend of each MCP server in platform/catalog.json. The shipping API is published from its OpenAPI
// description, with its private URL as the server the gateway calls.
var toolSources = {
  orders: { kind: 'mcp', url: apps.?outputs.mcpUrl ?? '' }
  shipping: {
    kind: 'openApi'
    specBase64: base64(string(union(shippingSpec, { servers: [ { url: apps.?outputs.shippingApiUrl ?? '' } ] })))
  }
  returns: { kind: 'mcp', url: apps.?outputs.returnsUrl ?? '' }
}

module tools 'modules/tools.bicep' = [for t in catalog.tools: if (deployApps) {
  scope: rg
  name: 'tools-${t.server}'
  params: {
    gatewayName: gateway.outputs.gatewayName
    serverName: t.server
    displayName: t.displayName
    serverDescription: t.description
    source: toolSources[t.server]
    callers: teamAccess.outputs.toolCallers[t.server]
  }
}]

// Computed rather than read from the tools modules, which don't exist on the first pass (deployApps = false).
var toolServerIds = map(toolNames, n => '${gateway.outputs.gatewayId}/workspaces/default/toolServers/${n}')
var toolGrants = flatten(map(toolNames, n => map(teamAccess.outputs.toolCallers[n], c => {
  scope: '${gateway.outputs.gatewayId}/workspaces/default/toolServers/${n}'
  principalId: c.principalId
  roleDefinitionId: toolsUserRoleId
})))

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AI_GATEWAY_ID string = gateway.outputs.gatewayId
output AI_GATEWAY_NAME string = gateway.outputs.gatewayName
output AI_GATEWAY_URL string = gateway.outputs.gatewayUrl
output AI_GATEWAY_MODEL string = models.outputs.aliasName
output AI_GATEWAY_MODEL_ID string = modelName
output AI_GATEWAY_MCP_SERVERS string = deployApps ? join(toolNames, ',') : ''
output AI_GATEWAY_PRIVATE_DNS_ZONE string = gatewayPe.?outputs.zoneName ?? ''
output FOUNDRY_MODELS_ACCOUNT string = foundryModels.outputs.accountName
output FOUNDRY_MODELS_ENDPOINT string = foundryModels.outputs.endpoint
output FOUNDRY_PROJECT_ENDPOINT string = foundryAgents.outputs.projectEndpoint
output FOUNDRY_AGENTS_ACCOUNT string = foundryAgents.outputs.accountName
output FOUNDRY_MODEL string = foundryAgents.outputs.foundryModel
output ACR_NAME string = registry.outputs.registryName
output APPLICATION_INSIGHTS_NAME string = monitoring.outputs.appInsightsName
output AGENT_SMOKE_JOB string = apps.?outputs.smokeJobName ?? ''
output MCP_SERVER_PRIVATE_URL string = apps.?outputs.mcpUrl ?? ''

// For scripts/teams.py prune: the runtime roles the team files grant, and the assets whose roles they manage.
output ACCESS_GRANTS array = concat(models.outputs.grants, deployApps ? toolGrants : [])
output ACCESS_SCOPES array = concat([ models.outputs.aliasId ], deployApps ? toolServerIds : [])

// For scripts/teams.py report: which object ID belongs to which team member.
output TEAM_MEMBERS array = teamAccess.outputs.members
