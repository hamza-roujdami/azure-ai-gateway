// Secure end-to-end AI gateway on Azure, built on Azure AI Gateway (Microsoft.ApiManagement/aigateways).
// One subscription-scope deployment creates one resource group:
//
//   network          VNet: snet-aigw (gateway private routing), snet-aca (Container Apps), snet-pe (private endpoints)
//   monitoring       Log Analytics + Application Insights (OTLP)
//   foundry-models   Foundry account + model deployments: keys off, public access off, private endpoint
//   foundry-backup   a second Foundry account in another region, for failover, with its private endpoint in the VNet
//   gateway          AI Gateway with private routing; managed identity has Foundry User on both model accounts, and a
//                    user-assigned identity signs in for tools that act as the signed-in user (on-behalf-of)
//   models           providers (managed identity) + backend models (token limit, content safety) + aliases (cost
//                    limit, priority routing, a CEL condition, failover) + roles
//   foundry-agents   Foundry project for Agent Service, connected to the gateway (no model deployments)
//   registry         container registry + the apps' user-assigned identity
//   aca-env/-dns     internal Container Apps environment + private DNS
//   aca-apps         private MCP servers, shipping API, returns agent, Agent Framework agent, smoke-test job
//                                                                                         (deployApps = true)
//   tools            the MCP servers from platform/catalog.json, each federating one or more backends, + Tools
//                    User roles                                                           (deployApps = true)
//
// Who can call what comes from the team files in teams/ (the teams parameter, rendered by scripts/teams.py):
// team-access turns them into the role assignments and budgets of each asset. The asset names come from
// platform/catalog.json. The Microsoft Entra apps for on-behalf-of come from infra/entra (an identity
// administrator's step), passed in as onBehalfOfBackendAppId and onBehalfOfTokenExchangeAppId. scripts/deploy.sh runs the deployment twice: first without the apps, then builds the images
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

@description('Region of the backup Foundry account that the chat alias fails over to. It must offer the model.')
param backupLocation string = 'francecentral'

@description('Backup model capacity in thousands of tokens per minute.')
@minValue(1)
param backupModelCapacity int = 100

@description('Second model family, behind the mistral alias. A model that Azure sells directly: no Marketplace terms.')
param mistralModel object = { name: 'Mistral-Large-3', format: 'Mistral AI', version: '1', capacity: 100 }

@description('Your organization\'s legal name. Anthropic requires it to deploy Claude; empty skips the claude alias.')
param claudeOrganizationName string = ''

@description('Two-letter country code of your organization, for the Claude attestation.')
param claudeCountryCode string = 'US'

@description('Your organization\'s industry in lowercase, for the Claude attestation, for example technology.')
param claudeIndustry string = 'technology'

param claudeModel object = { name: 'claude-haiku-5-5', version: '2', capacity: 50 }

@description('App ID of the my-orders API app (infra/entra). Empty skips the my-orders MCP server.')
param onBehalfOfBackendAppId string = ''

@description('App ID of the token exchange app (infra/entra).')
param onBehalfOfTokenExchangeAppId string = ''

@description('Which customer account each user buys for, by Entra object ID: sample data for my-orders. The deployer gets Contoso.')
param accountOwners object = {}

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
var claudeEnabled = !empty(claudeOrganizationName)
var onBehalfOfEnabled = !empty(onBehalfOfBackendAppId) && !empty(onBehalfOfTokenExchangeAppId)
var aliasNames = filter(map(catalog.models, m => m.alias), a => a != 'claude' || claudeEnabled)
var toolNames = map(catalog.tools, t => t.server)
var enabledToolNames = filter(toolNames, n => n != 'my-orders' || onBehalfOfEnabled)
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

var claudeDeployment = {
  name: claudeModel.name
  format: 'Anthropic'
  model: claudeModel.name
  version: claudeModel.version
  capacity: claudeModel.capacity
  modelProviderData: {
    organizationName: claudeOrganizationName
    countryCode: claudeCountryCode
    industry: claudeIndustry
  }
}

module foundryModels 'modules/foundry-models.bicep' = {
  scope: rg
  name: 'foundry-models'
  params: {
    location: location
    tags: allTags
    accountName: 'aifm-${token}'
    deployments: concat(
      [
        { name: modelName, format: 'OpenAI', model: modelName, version: modelVersion, capacity: modelCapacity }
        {
          name: mistralModel.name
          format: mistralModel.format
          model: mistralModel.name
          version: mistralModel.version
          capacity: mistralModel.capacity
        }
      ],
      claudeEnabled ? [ claudeDeployment ] : []
    )
    vnetId: network.outputs.vnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    logAnalyticsId: monitoring.outputs.logAnalyticsId
  }
}

// The failover target: the same model in another region. Its private endpoint is in this VNet, so the gateway still
// reaches it privately, and its records go into the private DNS zones that foundry-models created.
module foundryBackup 'modules/foundry-models.bicep' = {
  scope: rg
  name: 'foundry-backup'
  dependsOn: [ foundryModels ]
  params: {
    location: backupLocation
    privateEndpointLocation: location
    tags: allTags
    accountName: 'aifb-${token}'
    deployments: [
      { name: modelName, format: 'OpenAI', model: modelName, version: modelVersion, capacity: backupModelCapacity }
    ]
    createDnsZones: false
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
    identityName: 'id-aigw-${environmentName}'
    integrationSubnetId: network.outputs.gatewaySubnetId
    publicNetworkAccess: inboundMode == 'private' ? 'Disabled' : 'Enabled'
    foundryAccountNames: [ foundryModels.outputs.accountName, foundryBackup.outputs.accountName ]
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
    aliasNames: aliasNames
    toolNames: toolNames
  }
}

var primaryDeployments = foundryModels.outputs.deployments
var backupDeployments = foundryBackup.outputs.deployments
var openAiEndpoints = [ '/openai/v1/chat/completions', '/openai/v1/responses' ]
// Requests that carry x-workload: batch skip the primary, so batch jobs never use its capacity.
var notBatch = '@cel(!(\'x-workload\' in request.headers && request.headers[\'x-workload\'][0] == \'batch\'))'

module models 'modules/models.bicep' = {
  scope: rg
  name: 'models'
  params: {
    gatewayName: gateway.outputs.gatewayName
    providers: [
      {
        name: 'foundry'
        displayName: 'Foundry ${location} (private endpoint)'
        endpoint: foundryModels.outputs.endpoint
        accountId: foundryModels.outputs.accountId
      }
      {
        name: 'foundry-backup'
        displayName: 'Foundry ${backupLocation} (private endpoint)'
        endpoint: foundryBackup.outputs.endpoint
        accountId: foundryBackup.outputs.accountId
      }
    ]
    models: concat(
      [
        {
          provider: 'foundry'
          name: modelName
          deploymentId: primaryDeployments[modelName].id
          deploymentName: modelName
          version: modelVersion
          endpoints: openAiEndpoints
        }
        {
          provider: 'foundry-backup'
          name: '${modelName}-${backupLocation}'
          deploymentId: backupDeployments[modelName].id
          deploymentName: modelName
          version: modelVersion
          endpoints: openAiEndpoints
        }
        {
          provider: 'foundry'
          name: toLower(mistralModel.name)
          deploymentId: primaryDeployments[mistralModel.name].id
          deploymentName: mistralModel.name
          version: mistralModel.version
          endpoints: [ '/openai/v1/chat/completions' ]
        }
      ],
      claudeEnabled
        ? [
            {
              provider: 'foundry'
              name: claudeModel.name
              deploymentId: '${foundryModels.outputs.accountId}/deployments/${claudeModel.name}'
              deploymentName: claudeModel.name
              version: claudeModel.version
              endpoints: [ '/anthropic/v1/messages' ]
            }
          ]
        : []
    )
    aliases: concat(
      [
        {
          name: aliasName
          description: 'Prefers ${location}; fails over to ${backupLocation}. x-workload: batch goes to ${backupLocation}.'
          backends: [
            { model: 'foundry/${modelName}', priority: 0, when: notBatch }
            { model: 'foundry-backup/${modelName}-${backupLocation}', priority: 1 }
          ]
          failover: true
        }
        {
          name: 'mistral'
          description: 'Mistral Large 3, a second model family.'
          backends: [ { model: 'foundry/${toLower(mistralModel.name)}', priority: 0 } ]
          failover: false
        }
      ],
      claudeEnabled
        ? [
            {
              name: 'claude'
              description: 'Claude Haiku on the Anthropic Messages API.'
              backends: [ { model: 'foundry/${claudeModel.name}', priority: 0 } ]
              failover: false
            }
          ]
        : []
    )
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
    agentMcpServers: 'commerce'
    gatewaySubnetPrefix: network.outputs.gatewaySubnetPrefix
    myOrders: onBehalfOfEnabled
      ? {
          backendAppId: onBehalfOfBackendAppId
          tokenExchangeAppId: onBehalfOfTokenExchangeAppId
          accountOwners: union(empty(principalId) ? {} : { '${principalId}': 'Contoso' }, accountOwners)
        }
      : {}
  }
}

// Where each backend in platform/catalog.json lives. The shipping API is published from its OpenAPI description,
// with its private URL as the server the gateway calls. my-orders gets the caller's identity: the gateway exchanges
// the caller's token for one for the my-orders API (on-behalf-of), signing in as the token exchange app with its
// user-assigned identity.
var backendSources = {
  orders: { url: apps.?outputs.mcpUrl ?? '' }
  shipping: {
    specBase64: base64(string(union(shippingSpec, { servers: [ { url: apps.?outputs.shippingApiUrl ?? '' } ] })))
  }
  returns: { url: apps.?outputs.returnsUrl ?? '' }
  'my-orders': {
    url: apps.?outputs.myOrdersUrl ?? ''
    authentication: {
      oauth2: {
        grantType: 'tokenExchange'
        tokenExchange: {
          profile: 'entraOnBehalfOf'
          federatedClientApplication: {
            applicationId: onBehalfOfTokenExchangeAppId
            appCredential: { type: 'userAssignedManagedIdentity', clientId: gateway.outputs.identityClientId }
          }
          scopes: [ 'api://${onBehalfOfBackendAppId}/user_impersonation' ]
        }
      }
    }
  }
}

module tools 'modules/tools.bicep' = [for t in catalog.tools: if (deployApps && contains(enabledToolNames, t.server)) {
  scope: rg
  name: 'tools-${t.server}'
  params: {
    gatewayName: gateway.outputs.gatewayName
    serverName: t.server
    displayName: t.displayName
    serverDescription: t.description
    backends: map(t.backends, b => union(
      { namespace: b, kind: catalog.backends[b].kind, required: catalog.backends[b].required },
      backendSources[b]
    ))
    callers: teamAccess.outputs.toolCallers[t.server]
  }
}]

// Computed rather than read from the tools modules, which don't exist on the first pass (deployApps = false).
var toolServerIds = map(enabledToolNames, n => '${gateway.outputs.gatewayId}/workspaces/default/toolServers/${n}')
var toolGrants = flatten(map(enabledToolNames, n => map(teamAccess.outputs.toolCallers[n], c => {
  scope: '${gateway.outputs.gatewayId}/workspaces/default/toolServers/${n}'
  principalId: c.principalId
  roleDefinitionId: toolsUserRoleId
})))

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AZURE_BACKUP_LOCATION string = backupLocation
output AI_GATEWAY_ID string = gateway.outputs.gatewayId
output AI_GATEWAY_NAME string = gateway.outputs.gatewayName
output AI_GATEWAY_URL string = gateway.outputs.gatewayUrl
output AI_GATEWAY_MODEL string = aliasName
output AI_GATEWAY_MODEL_ID string = modelName
output AI_GATEWAY_MODELS string = join(models.outputs.aliasNames, ',')
output AI_GATEWAY_MCP_SERVERS string = deployApps ? join(enabledToolNames, ',') : ''
output AI_GATEWAY_IDENTITY_PRINCIPAL_ID string = gateway.outputs.identityPrincipalId
output AI_GATEWAY_PRIVATE_DNS_ZONE string = gatewayPe.?outputs.zoneName ?? ''
output FOUNDRY_MODELS_ACCOUNT string = foundryModels.outputs.accountName
output FOUNDRY_MODELS_ENDPOINT string = foundryModels.outputs.endpoint
output FOUNDRY_BACKUP_ACCOUNT string = foundryBackup.outputs.accountName
output FOUNDRY_PROJECT_ENDPOINT string = foundryAgents.outputs.projectEndpoint
output FOUNDRY_AGENTS_ACCOUNT string = foundryAgents.outputs.accountName
output FOUNDRY_MODEL string = foundryAgents.outputs.foundryModel
output ACR_NAME string = registry.outputs.registryName
output APPLICATION_INSIGHTS_NAME string = monitoring.outputs.appInsightsName
output AGENT_SMOKE_JOB string = apps.?outputs.smokeJobName ?? ''
output MCP_SERVER_PRIVATE_URL string = apps.?outputs.mcpUrl ?? ''

// For scripts/teams.py prune: the runtime roles the team files grant, and the assets whose roles they manage.
output ACCESS_GRANTS array = concat(models.outputs.grants, deployApps ? toolGrants : [])
output ACCESS_SCOPES array = concat(models.outputs.aliasIds, deployApps ? toolServerIds : [])

// For scripts/teams.py report: which object ID belongs to which team member.
output TEAM_MEMBERS array = teamAccess.outputs.members
