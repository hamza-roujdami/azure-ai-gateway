// Publishes one MCP server on the gateway, with a per-caller request rate limit, and grants AI Gateway Tools User on
// this MCP server only, to the callers from the team files. Its backend is either
//   - a remote MCP server (Streamable HTTP):        source = { kind: 'mcp', url }
//   - a REST API described by OpenAPI:              source = { kind: 'openApi', specBase64 }
//     The gateway turns each operation into a tool and calls the API at the spec's servers[0].url.
// Clients connect to https://<gateway-host>/default/toolservers/<serverName>/mcp and see <namespace>_<tool>.
// The backends here are private and accept only the gateway's subnet, so the gateway sends them no credentials.
targetScope = 'resourceGroup'

import { caller } from 'types.bicep'

param gatewayName string

@description('MCP server name. Part of the endpoint URL; can\'t be changed after creation.')
param serverName string

@description('Unique among the gateway\'s MCP servers. Shown in the portal catalog.')
param displayName string

@description('Helps people and agents understand what the tools do.')
param serverDescription string

param namespace string = serverName

@description('{ kind: \'mcp\', url } or { kind: \'openApi\', specBase64 }.')
param source object

@minValue(1)
param callsPerMinutePerCaller int = 60

@description('Callers that get AI Gateway Tools User on this MCP server.')
param callers caller[] = []

var toolsUserRoleId = 'dce03f8d-857f-4e40-a90d-67770fa6ecd2'

var mcpEndpoint = {
  namespace: namespace
  kind: 'mcp'
  mode: 'failClosed'
  mcp: {
    endpoint: { url: source.?url ?? '' }
    transport: 'streamableHttp'
  }
}
var openApiEndpoint = {
  namespace: namespace
  kind: 'openApi'
  mode: 'failClosed'
  openApi: {
    specSource: {
      type: 'inline'
      contentBase64: source.?specBase64 ?? ''
    }
  }
}

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
    displayName: displayName
    description: serverDescription
    toolServerType: source.kind
    endpoints: [ source.kind == 'openApi' ? openApiEndpoint : mcpEndpoint ]
    policies: [
      {
        type: 'requestRateLimit'
        count: callsPerMinutePerCaller
        period: 'minute'
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
