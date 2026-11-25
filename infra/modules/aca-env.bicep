// Internal Container Apps environment in snet-aca: no public IP, apps are reachable only from the VNet.
// Logs go to Log Analytics through diagnostic settings (azure-monitor destination), so no workspace key is needed.
targetScope = 'resourceGroup'

param location string
param tags object = {}
param environmentName string
param subnetId string
param logAnalyticsId string

resource env 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: subnetId
      internal: true
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    zoneRedundant: false
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: env
  properties: {
    workspaceId: logAnalyticsId
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output environmentId string = env.id
output defaultDomain string = env.properties.defaultDomain
output staticIp string = env.properties.staticIp
