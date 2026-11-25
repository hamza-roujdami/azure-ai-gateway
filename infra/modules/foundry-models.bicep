// The model backend: a Microsoft Foundry account that only hosts model deployments.
//   - Keys are disabled: only Entra identities (the gateway's managed identity) can call it.
//   - Public network access is disabled: it's reachable only through its private endpoint in snet-pe.
//   - The three Foundry private DNS zones are linked to the VNet, so the gateway resolves the usual host name to the
//     private IP.
targetScope = 'resourceGroup'

param location string
param tags object = {}

@description('Account name. Also the custom subdomain, so it must be globally unique.')
param accountName string

param modelName string
param modelVersion string
param deploymentName string
param skuName string = 'GlobalStandard'

@minValue(1)
param capacity int = 50

param vnetId string
param privateEndpointSubnetId string
param logAnalyticsId string

var dnsZoneNames = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
]

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: toLower(accountName)
    allowProjectManagement: false
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: deploymentName
  sku: {
    name: skuName
    capacity: capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zone in dnsZoneNames: {
  name: zone
  location: 'global'
  tags: tags
}]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zone, i) in dnsZoneNames: {
  parent: dnsZones[i]
  name: 'link-${last(split(vnetId, '/'))}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}]

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${accountName}'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'foundry'
        properties: {
          privateLinkServiceId: account.id
          groupIds: [ 'account' ]
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zone, i) in dnsZoneNames: {
      name: replace(zone, '.', '-')
      properties: { privateDnsZoneId: dnsZones[i].id }
    }]
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

output accountId string = account.id
output accountName string = account.name
output endpoint string = account.properties.endpoint
output deploymentId string = deployment.id
output deploymentName string = deployment.name
