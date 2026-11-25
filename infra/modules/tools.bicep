// Federates the private MCP server (Container Apps, internal) behind the gateway, with a per-caller request rate
// limit, and grants AI Gateway Tools User on this MCP server only, to the callers from the team files. Clients connect to
//   https://<gateway-host>/default/toolservers/<serverName>/mcp
// and see the backend's tools as <namespace>_<tool>.
targetScope = 'resourceGroup'

import { caller } from 'types.bicep'

param gatewayName string

@description('MCP server name. Part of the endpoint URL; can\'t be changed after creation.')
param serverName string = 'orders'

param namespace string = 'orders'

@description('Private URL of the backend MCP server (Streamable HTTP).')
param mcpUrl string

@minValue(1)
param callsPerMinutePerCaller int = 60

@description('Callers that get AI Gateway Tools User on this MCP server.')
param callers caller[] = []

var toolsUserRoleId = 'dce03f8d-857f-4e40-a90d-67770fa6ecd2'

#disable-next-line BCP081
resource gateway 'Microsoft.ApiManagement/aigateways@2026-11-01' existing = {
  name: gatewayName
}

#disable-next-line BCP081
resource workspace 'Microsoft.ApiManagement/aigateways/workspaces@2026-11-01' existing = {
  parent: gateway
  name: 'default'
}

#disable-next-line BCP081
resource toolServer 'Microsoft.ApiManagement/aigateways/workspaces/toolServers@2026-11-01' = {
  parent: workspace
  name: serverName
  properties: {
    displayName: 'Orders (private)'
    description: 'Look up orders and stock levels. Synthetic sample data, served privately from the VNet.'
    toolServerType: 'mcp'
    endpoints: [
      {
        namespace: namespace
        kind: 'mcp'
        mcp: {
          endpoint: { url: mcpUrl }
          transport: 'streamableHttp'
        }
      }
    ]
    policies: [
      {
        type: 'requestRateLimit'
        scope: 'resource'
        callsPerPeriod: callsPerMinutePerCaller
        periodSeconds: 60
        counterKey: [ 'identity' ]
      }
    ]
  }
}

resource toolsUsers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for caller in callers: {
  scope: toolServer
  name: guid(toolServer.id, caller.principalId, toolsUserRoleId)
  properties: {
    principalId: caller.principalId
    principalType: caller.principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', toolsUserRoleId)
  }
}]

output serverName string = toolServer.name
output toolServerId string = toolServer.id
output mcpEndpoint string = 'https://${gateway.properties.frontend.defaultHostname}/default/toolservers/${serverName}/mcp'
output grants array = [for c in callers: { scope: toolServer.id, principalId: c.principalId, roleDefinitionId: toolsUserRoleId }]
