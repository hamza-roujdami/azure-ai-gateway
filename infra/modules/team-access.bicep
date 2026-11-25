// Turns the teams into the callers and budget overrides of each gateway asset. It deploys nothing: models.bicep and
// tools.bicep create the role assignments and the policies from its outputs.
targetScope = 'resourceGroup'

import { caller, team } from 'types.bicep'

param teams team[]

@description('Principal IDs for the platform:* references in team files. An empty value skips the member.')
param platformPrincipals object

@description('Principal types for the platform:* references: they come from the deployment, not the team file.')
param platformPrincipalTypes object

param aliasName string
param mcpServerName string

var members = flatten(map(teams, t => map(t.members, m => {
  principalId: platformPrincipals[?m.principalId] ?? m.principalId
  principalType: platformPrincipalTypes[?m.principalId] ?? m.principalType
  dailyBudgetUsd: m.?dailyBudgetUsd ?? ''
  models: t.models
  tools: t.tools
})))
var resolved = filter(members, m => !empty(m.principalId))
var modelMembers = filter(resolved, m => contains(m.models, aliasName))
var toolMembers = filter(resolved, m => contains(m.tools, mcpServerName))

// union() drops duplicates, so a principal in two teams gets one role assignment.
output modelCallers caller[] = union(map(modelMembers, m => { principalId: m.principalId, principalType: m.principalType }), [])
output toolCallers caller[] = union(map(toolMembers, m => { principalId: m.principalId, principalType: m.principalType }), [])

// Cost limit overrides match the caller's validated token claims. Each matching identity gets its own counter.
output costOverrides array = union(map(filter(modelMembers, m => !empty(m.dailyBudgetUsd)), m => {
  claims: [
    { name: 'tid', value: tenant().tenantId }
    { name: 'oid', value: m.principalId }
  ]
  amount: json(m.dailyBudgetUsd)
}), [])
