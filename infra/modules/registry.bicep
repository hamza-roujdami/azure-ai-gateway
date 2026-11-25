// Container registry for the agent and MCP server images, and the user-assigned identity the container apps run as.
// No admin user (Basic has no anonymous pull): Container Apps pull with the identity (AcrPull).
targetScope = 'resourceGroup'

param location string
param tags object = {}
param registryName string
param identityName string
param logAnalyticsId string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, identity.id, acrPullRoleId)
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: registry
  properties: {
    workspaceId: logAnalyticsId
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
  }
}

output registryName string = registry.name
output loginServer string = registry.properties.loginServer
output identityId string = identity.id
output identityClientId string = identity.properties.clientId
output identityPrincipalId string = identity.properties.principalId
