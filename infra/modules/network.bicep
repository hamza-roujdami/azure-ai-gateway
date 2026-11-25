// Virtual network for the AI gateway and its private backends:
//   snet-aigw   delegated to Microsoft.App/environments, dedicated to the gateway's outbound integration (private routing)
//   snet-aca    delegated to Microsoft.App/environments, for the internal Container Apps environment (agent, MCP server)
//   snet-pe     private endpoints: Foundry, and the gateway's inbound endpoint when enabled
targetScope = 'resourceGroup'

param location string
param tags object = {}
param vnetName string
param addressPrefix string = '10.40.0.0/16'
param gatewaySubnetPrefix string = '10.40.0.0/24'
param privateEndpointSubnetPrefix string = '10.40.1.0/24'
param acaSubnetPrefix string = '10.40.2.0/23'

// AI Gateway needs no custom NSG rules on its integration subnet; the NSG is there so rules can be added centrally.
resource gatewayNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${vnetName}-aigw'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource acaNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${vnetName}-aca'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${vnetName}-pe'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

// Subnets are declared inline so a redeployment never tries to delete them.
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ addressPrefix ]
    }
    subnets: [
      {
        name: 'snet-aigw'
        properties: {
          addressPrefix: gatewaySubnetPrefix
          networkSecurityGroup: { id: gatewayNsg.id }
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          networkSecurityGroup: { id: privateEndpointNsg.id }
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: 'snet-aca'
        properties: {
          addressPrefix: acaSubnetPrefix
          networkSecurityGroup: { id: acaNsg.id }
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output gatewaySubnetId string = '${vnet.id}/subnets/snet-aigw'
output gatewaySubnetPrefix string = gatewaySubnetPrefix
output privateEndpointSubnetId string = '${vnet.id}/subnets/snet-pe'
output acaSubnetId string = '${vnet.id}/subnets/snet-aca'
