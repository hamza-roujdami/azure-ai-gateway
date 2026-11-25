// Container registry for the images, and the user-assigned identities the container apps run as:
//   apps            the order agent, the smoke job, the orders MCP server and the shipping API
//   returns-agent   the returns specialist only, so its model use has its own role, budget, and telemetry
// No admin user (Basic has no anonymous pull): Container Apps pull with the identity (AcrPull).
targetScope = 'resourceGroup'

param location string
param tags object = {}
param registryName string
param identityName string
param returnsIdentityName string
param logAnalyticsId string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource returnsIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: returnsIdentityName
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

resource returnsAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, returnsIdentity.id, acrPullRoleId)
  properties: {
    principalId: returnsIdentity.properties.principalId
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
output returnsIdentityId string = returnsIdentity.id
output returnsIdentityClientId string = returnsIdentity.properties.clientId
output returnsIdentityPrincipalId string = returnsIdentity.properties.principalId
