// Publishes the Foundry deployments through the gateway:
//   providers  one per Foundry account; each signs in with the gateway's managed identity (no keys)
//   models     one backend model per deployment, each with a per-caller token limit and content safety
//   aliases    the stable names apps send in the "model" field, each with a daily cost limit per caller. An alias can
//              route across backends by priority, skip a backend with a CEL condition, and fail over on errors.
//   roles      AI Gateway Models User on each alias only (least privilege), for each caller from the team files
targetScope = 'resourceGroup'

param gatewayName string

@description('[{ name, displayName, endpoint, accountId }]: one model provider per Foundry account.')
param providers array

@description('[{ name, provider, deploymentId, deploymentName, version, endpoints }]: the backend models.')
param models array

@description('[{ name, description, backends: [{ model, priority, when? }], failover }]. model is <provider>/<model>.')
param aliases array

@minValue(1)
param tokensPerMinutePerCaller int = 150000

@allowed([ 'None', 'Low', 'Medium', 'High' ])
param contentSafetySeverity string = 'Medium'

@description('Estimated spend each caller can use per day on each alias, in US dollars, as a string for decimals.')
param dailyBudgetPerCallerUsd string = '5'

@description('Budgets for specific identities: [{ claims, amount }]. The first match wins.')
param costOverrides array = []

@description('{ <alias>: caller[] }: the callers that get AI Gateway Models User on each alias.')
param callers object

// Backend outages only: no response, a deployment missing in that region (404), a timeout (408), a paused or locked
// deployment (423), throttling (429), or a server error. Client errors such as a content safety 400 go back to the
// caller: another backend wouldn't help.
@description('A failed send that matches moves the request to the next backend.')
param failureCondition string = '@cel(response == null || response.status_code in [404, 408, 423, 429] || response.status_code >= 500)'

@description('How long a failing backend stays out of the alias, as an ISO 8601 duration.')
param excludeFor string = 'PT30S'

var modelsUserRoleId = 'a6b68e3d-a1f0-4c60-8678-237c050cf4ea'
var workspaceId = resourceId('Microsoft.ApiManagement/aigateways/workspaces', gatewayName, 'default')

#disable-next-line BCP081
resource gateway 'Microsoft.ApiManagement/aigateways@2026-11-01' existing = {
  name: gatewayName
}

#disable-next-line BCP081
resource modelProviders 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders@2026-11-01' = [for p in providers: {
  name: '${gatewayName}/default/${p.name}'
  properties: {
    modelProviderType: 'Foundry'
    displayName: p.displayName
    foundry: {
      endpoint: { url: endsWith(p.endpoint, '/') ? p.endpoint : '${p.endpoint}/' }
      resourceIds: [ p.accountId ]
    }
    authentication: {
      managedIdentity: { resource: 'https://cognitiveservices.azure.com/' }
    }
  }
}]

#disable-next-line BCP081
resource backendModels 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models@2026-11-01' = [for m in models: {
  name: '${gatewayName}/default/${m.provider}/${m.name}'
  dependsOn: [ modelProviders ]
  properties: {
    displayName: m.name
    supportedEndpoints: m.endpoints
    deployment: {
      resourceId: m.deploymentId
      modelName: m.deploymentName
      modelVersion: m.version
    }
    policies: [
      {
        type: 'tokenLimit'
        period: 'minute'
        count: tokensPerMinutePerCaller
        counterKey: [ 'identity' ]
      }
      {
        type: 'contentSafety'
        hateSeverity: contentSafetySeverity
        violenceSeverity: contentSafetySeverity
        sexualSeverity: contentSafetySeverity
        selfHarmSeverity: contentSafetySeverity
      }
    ]
  }
}]

var modelIds = toObject(models, m => '${m.provider}/${m.name}', m => '${workspaceId}/modelProviders/${m.provider}/models/${m.name}')

#disable-next-line BCP081
resource aliasResources 'Microsoft.ApiManagement/aigateways/workspaces/aliases@2026-11-01' = [for a in aliases: {
  name: '${gatewayName}/default/${a.name}'
  dependsOn: [ backendModels ]
  properties: union(
    {
      description: a.description
      backendModels: map(a.backends, b => union(
        { resourceId: modelIds[b.model], priority: b.priority, weight: 1 },
        contains(b, 'when') ? { when: b.when } : {}
      ))
      selectionOrder: [ 'priority' ]
      policies: [
        {
          type: 'costLimit'
          // A stable ID: changing the amount on a later deployment keeps the spend counted so far.
          id: guid(gateway.id, a.name, 'costLimit')
          amount: json(dailyBudgetPerCallerUsd)
          period: 'day'
          counterKey: [ 'identity' ]
          overrides: costOverrides
        }
      ]
    },
    a.failover ? { maxRetryAttempts: 3, failures: [ { when: failureCondition, excludeFor: excludeFor } ] } : {}
  )
}]

var grants = flatten(map(range(0, length(aliases)), i => map(callers[?aliases[i].name] ?? [], c => {
  alias: i
  scope: '${workspaceId}/aliases/${aliases[i].name}'
  principalId: c.principalId
  principalType: c.principalType
  roleDefinitionId: modelsUserRoleId
})))

resource modelsUsers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for g in grants: {
  scope: aliasResources[g.alias]
  name: guid(g.scope, g.principalId, modelsUserRoleId)
  properties: {
    principalId: g.principalId
    principalType: g.principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', modelsUserRoleId)
  }
}]

output aliasNames string[] = map(aliases, a => a.name)
output aliasIds string[] = map(aliases, a => '${workspaceId}/aliases/${a.name}')
output grants array = map(grants, g => { scope: g.scope, principalId: g.principalId, roleDefinitionId: g.roleDefinitionId })
