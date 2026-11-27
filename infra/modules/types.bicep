// Shapes shared by main.bicep and the modules. scripts/teams.py render turns the files in teams/ into a team[].

@export()
@description('A Microsoft Entra principal that gets a runtime role on a gateway asset.')
type caller = {
  principalId: string
  principalType: ('User' | 'Group' | 'ServicePrincipal')
}

@export()
@description('A principal that a team onboards.')
type teamMember = {
  name: string
  @description('Object ID, or platform:deployer, platform:apps, platform:returns-agent, platform:foundry-project or platform:hosted-agent.')
  principalId: string
  principalType: ('User' | 'Group' | 'ServicePrincipal')
  @description('Daily budget for this identity in US dollars, as a string so that it can hold decimals.')
  dailyBudgetUsd: string?
}

@export()
@description('One team file: the model aliases and MCP servers its members can call.')
type team = {
  name: string
  models: string[]
  tools: string[]
  members: teamMember[]
}
