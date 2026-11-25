// Publishes the Foundry deployment through the gateway:
//   provider  'foundry'   signs in to Foundry with the gateway's managed identity (no key)
//   model     per-caller token limit + content safety on prompts and responses
//   alias     'chat'      the stable name apps send in the "model" field, with a daily cost limit per caller
//   roles     AI Gateway Models User on the alias only (least privilege), for each caller from the team files
targetScope = 'resourceGroup'

import { caller } from 'types.bicep'

param gatewayName string
param foundryEndpoint string
param foundryAccountId string
param deploymentId string
param modelName string
param modelVersion string
param aliasName string = 'chat'

@minValue(1)
param tokensPerMinutePerCaller int = 150000

@allowed([ 'None', 'Low', 'Medium', 'High' ])
param contentSafetySeverity string = 'Medium'

@description('Estimated spend each caller can use per day on the alias, in US dollars, as a string for decimals.')
param dailyBudgetPerCallerUsd string = '5'

@description('Budgets for specific identities: [{ claims, amount }]. The first match wins.')
param costOverrides array = []

@description('Callers that get AI Gateway Models User on the alias.')
param callers caller[] = []

var modelsUserRoleId = 'a6b68e3d-a1f0-4c60-8678-237c050cf4ea'
var endpoint = endsWith(foundryEndpoint, '/') ? foundryEndpoint : '${foundryEndpoint}/'

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
resource provider 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders@2026-11-01' = {
  parent: workspace
  name: 'foundry'
  properties: {
    modelProviderType: 'Foundry'
    displayName: 'Foundry (private endpoint)'
    foundry: {
      endpoint: { url: endpoint }
      resourceIds: [ foundryAccountId ]
    }
    authentication: {
      managedIdentity: { resource: 'https://cognitiveservices.azure.com/' }
    }
  }
}

#disable-next-line BCP081
resource model 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models@2026-11-01' = {
  parent: provider
  name: last(split(deploymentId, '/'))
  properties: {
    displayName: modelName
    supportedEndpoints: [
      '/openai/v1/chat/completions'
      '/openai/v1/responses'
    ]
    deployment: {
      resourceId: deploymentId
      modelName: last(split(deploymentId, '/'))
      modelVersion: modelVersion
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
}

#disable-next-line BCP081
resource alias 'Microsoft.ApiManagement/aigateways/workspaces/aliases@2026-11-01' = {
  parent: workspace
  name: aliasName
  properties: {
    backendModels: [ { resourceId: model.id } ]
    policies: [
      {
        type: 'costLimit'
        // A stable ID: changing the amount on a later deployment keeps the spend counted so far.
        id: guid(gateway.id, aliasName, 'costLimit')
        amount: json(dailyBudgetPerCallerUsd)
        period: 'day'
        counterKey: [ 'identity' ]
        overrides: costOverrides
      }
    ]
  }
}

resource modelsUsers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for caller in callers: {
  scope: alias
  name: guid(alias.id, caller.principalId, modelsUserRoleId)
  properties: {
    principalId: caller.principalId
    principalType: caller.principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', modelsUserRoleId)
  }
}]

output aliasName string = alias.name
output aliasId string = alias.id
output grants array = [for c in callers: { scope: alias.id, principalId: c.principalId, roleDefinitionId: modelsUserRoleId }]
