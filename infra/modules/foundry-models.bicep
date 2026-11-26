// A model backend: a Microsoft Foundry account that only hosts model deployments.
//   - Keys are disabled: only Entra identities (the gateway's managed identity) can call it.
//   - Public network access is disabled: it's reachable only through its private endpoint in snet-pe, which can be in
//     the VNet's region even when the account is in another one.
//   - The three Foundry private DNS zones are linked to the VNet, so the gateway resolves the usual host name to the
//     private IP. The first account creates them; the others add their records to the same zones.
targetScope = 'resourceGroup'

param location string
param tags object = {}

@description('Account name. Also the custom subdomain, so it must be globally unique.')
param accountName string

@description('Model deployments, created one at a time: [{ name, format, model, version, capacity, sku?, modelProviderData? }].')
param deployments array

@description('Create the private DNS zones and link them to the VNet. False when another account already did.')
param createDnsZones bool = true

param vnetId string
param privateEndpointSubnetId string

@description('Region of the private endpoint: the VNet\'s region.')
param privateEndpointLocation string = location

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

// Foundry accepts one deployment change at a time per account, and none while the account itself is updating, which
// the private endpoint and diagnostic settings can cause: so the deployments go last, one by one. modelProviderData is
// the attestation that Anthropic (Claude) deployments require; other models don't take it.
@batchSize(1)
resource modelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = [for d in deployments: {
  parent: account
  name: d.name
  dependsOn: [ dnsZoneGroup, diagnostics ]
  sku: {
    name: d.?sku ?? 'GlobalStandard'
    capacity: d.capacity
  }
  properties: union(
    {
      model: {
        format: d.format
        name: d.model
        version: d.version
      }
    },
    contains(d, 'modelProviderData') ? { modelProviderData: d.modelProviderData } : {}
  )
}]

resource newZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zone in dnsZoneNames: if (createDnsZones) {
  name: zone
  location: 'global'
  tags: tags
}]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zone, i) in dnsZoneNames: if (createDnsZones) {
  parent: newZones[i]
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
  location: privateEndpointLocation
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
  dependsOn: [ newZones ]
  properties: {
    privateDnsZoneConfigs: [for zone in dnsZoneNames: {
      name: replace(zone, '.', '-')
      properties: { privateDnsZoneId: resourceId('Microsoft.Network/privateDnsZones', zone) }
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
@description('{ <deployment name>: { id, model, version } }')
output deployments object = toObject(deployments, d => d.name, d => {
  id: '${account.id}/deployments/${d.name}'
  model: d.model
  version: d.version
})
