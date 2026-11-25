// The agent side (spoke): a Foundry account + project for Foundry Agent Service, with NO model deployments. Its
// prompt agents use the gateway's model through a connection that signs in with the project's managed identity.
//
// Public network access stays Enabled: you manage agents from the Foundry portal or SDK, and Microsoft documents that
// a connected model's inference comes from the managed Agent Service plane, not from your VNet. Keys are disabled,
// so access is Entra ID only. See the README (Inbound modes).
targetScope = 'resourceGroup'

param location string
param tags object = {}

@description('Account name. Also the custom subdomain, so it must be globally unique.')
param accountName string

param projectName string = 'agents'
param gatewayId string
param gatewayUrl string
param gatewayLocation string
param aliasName string
param modelName string
param modelVersion string
param logAnalyticsId string

@description('Object ID of the person who builds agents in the project. Gets Foundry User on the account. Empty to skip.')
param principalId string = ''

@allowed([ 'User', 'Group', 'ServicePrincipal' ])
param principalType string = 'User'

var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: toLower(accountName)
    allowProjectManagement: true
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: projectName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: projectName
    description: 'Agents that use models published by the AI gateway. No model deployments or keys in this project.'
  }
}

// Same shape as the connection the Foundry portal creates with "Add consuming project" on the gateway.
var gatewayResource = {
  id: gatewayId
  name: last(split(gatewayId, '/'))
  gatewayUrl: gatewayUrl
  location: gatewayLocation
  subscriptionId: subscription().subscriptionId
  resourceGroup: resourceGroup().name
}
var models = [
  {
    name: aliasName
    properties: {
      model: {
        name: modelName
        version: modelVersion
        format: 'OpenAI'
      }
    }
  }
]

resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: 'ai-gateway'
  properties: {
    category: 'ApiManagement'
    target: '${gatewayUrl}/default/models/openai/v1'
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: 'https://azure-api.net/aigateway'
    isSharedToAll: false
    metadata: {
      apimResourceKind: 'AiGateway'
      apimResource: string(gatewayResource)
      deploymentInPath: 'false'
      inferenceAPIVersion: ''
      models: string(models)
      upstreamSurface: 'responses'
    }
  }
}

resource builderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: account
  name: guid(account.id, principalId, foundryUserRoleId)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: account
  properties: {
    workspaceId: logAnalyticsId
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output accountName string = account.name
output projectName string = project.name
output projectEndpoint string = 'https://${account.properties.customSubDomainName}.services.ai.azure.com/api/projects/${project.name}'
output projectPrincipalId string = project.identity.principalId
output connectionName string = connection.name
output foundryModel string = '${connection.name}/${aliasName}'
