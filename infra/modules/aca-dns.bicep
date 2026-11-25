// Private DNS for the internal Container Apps environment: <default domain> and *.<default domain> resolve to the
// environment's internal IP for everything in the VNet, including the gateway's integration subnet.
targetScope = 'resourceGroup'

param tags object = {}
param defaultDomain string
param staticIp string
param vnetId string

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: defaultDomain
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

resource wildcard 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: zone
  name: '*'
  properties: {
    ttl: 300
    aRecords: [ { ipv4Address: staticIp } ]
  }
}

resource apex 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: zone
  name: '@'
  properties: {
    ttl: 300
    aRecords: [ { ipv4Address: staticIp } ]
  }
}
