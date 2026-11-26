// Azure AI Gateway (Microsoft.ApiManagement/aigateways):
//   - system-assigned managed identity, which gets Foundry User on each model account (no keys between services)
//   - a user-assigned identity, which signs in as the token exchange app for tools that act as the signed-in user
//     (on-behalf-of): Entra trusts it through a federated credential, so there's no client secret
//   - private routing: outbound calls leave through snet-aigw, so the gateway reaches private endpoints
//   - publicNetworkAccess: 'Disabled' only when the inbound private endpoint exists (inboundMode = private)
//   The inbound private endpoint is in gateway-private-endpoint.bicep.
targetScope = 'resourceGroup'

param location string
param tags object = {}

@maxLength(24)
param gatewayName string

param identityName string
param integrationSubnetId string

@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Enabled'

@description('Names of the Foundry accounts (in this resource group) that the gateway calls with its managed identity.')
param foundryAccountNames string[]

var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

// The 2026-11-01 types aren't in every Bicep release yet; the API version is GA.
#disable-next-line BCP081
resource gateway 'Microsoft.ApiManagement/aigateways@2026-11-01' = {
  name: gatewayName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    backend: {
      subnet: { id: integrationSubnetId }
    }
    publicNetworkAccess: publicNetworkAccess
  }
}

resource foundryAccounts 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = [for name in foundryAccountNames: {
  name: name
}]

resource foundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (name, i) in foundryAccountNames: {
  scope: foundryAccounts[i]
  name: guid(foundryAccounts[i].id, gateway.id, foundryUserRoleId)
  properties: {
    principalId: gateway.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
  }
}]

var hostName = gateway.properties.frontend.defaultHostname

output gatewayName string = gateway.name
output gatewayId string = gateway.id
output gatewayUrl string = 'https://${hostName}'
output hostName string = hostName
output gatewayLocation string = gateway.location
output principalId string = gateway.identity.principalId
output identityPrincipalId string = identity.properties.principalId
output identityClientId string = identity.properties.clientId
