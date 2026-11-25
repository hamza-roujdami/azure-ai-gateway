// Log Analytics + workspace-based Application Insights with OTLP ingestion on. The gateway exports metrics, logs and
// traces over OpenTelemetry to this component (scripts/connect-telemetry.sh), and every other resource sends its
// diagnostic logs to the workspace.
targetScope = 'resourceGroup'

param location string
param tags object = {}
param logAnalyticsName string
param appInsightsName string

@minValue(30)
@maxValue(730)
param retentionInDays int = 30

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    retentionInDays: retentionInDays
    sku: { name: 'PerGB2018' }
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  // AzureMonitorWorkspaceIngestionMode turns on OTLP ingestion; it isn't in the Bicep types yet, so union() adds it.
  properties: union(
    {
      Application_Type: 'web'
      WorkspaceResourceId: logAnalytics.id
      DisableLocalAuth: true
    },
    { AzureMonitorWorkspaceIngestionMode: 'Enabled' }
  )
}

output logAnalyticsId string = logAnalytics.id
output appInsightsName string = appInsights.name
