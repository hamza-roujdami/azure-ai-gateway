// Inbound private endpoint to the gateway (group ID 'Gateway') and its private DNS zone, linked to the VNet, so
// clients in the VNet resolve the gateway's usual host name to a private IP.
// Preview: the subscription needs access first (Azure support request "Enable private endpoints for Azure AI
// Gateway"). Until then, creation fails with SubscriptionNotRegisteredForFeature. The gateway approves the
// connection automatically.
targetScope = 'resourceGroup'

param location string
param tags object = {}
param gatewayId string

@description('Gateway host name without https://, e.g. aigw-x.swedencentral-01.ai.gateway.azure.com.')
param hostName string

param subnetId string
param vnetId string

// The zone follows the host name, e.g. privatelink.swedencentral-01.ai.gateway.azure.com, as the gateway's private
// link resource reports in requiredZoneNames.
var zoneName = 'privatelink.${join(skip(split(hostName, '.'), 1), '.')}'

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: zoneName
  location: 'global'
  tags: tags
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: zone
  name: 'link-${last(split(vnetId, '/'))}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${last(split(gatewayId, '/'))}'
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: 'gateway'
        properties: {
          privateLinkServiceId: gatewayId
          groupIds: [ 'Gateway' ]
        }
      }
    ]
  }
}

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: replace(zoneName, '.', '-')
        properties: { privateDnsZoneId: zone.id }
      }
    ]
  }
}

output zoneName string = zone.name
