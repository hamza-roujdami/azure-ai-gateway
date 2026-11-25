// The gateway's OpenTelemetry exporter to Application Insights (from Microsoft's AI Gateway lab 21). Deployed by
// scripts/connect-telemetry.sh after Azure has created the component's OTLP endpoints, which Bicep can't wait for.
targetScope = 'resourceGroup'

@description('Name of the existing gateway in this resource group.')
param gatewayName string

@description('Name of the existing Application Insights component in this resource group, with OTLP ingestion on.')
param appInsightsName string

@description('Name of the telemetry exporter. The portal names it appinsights.')
param exporterName string = 'appinsights'

@description('Token claims to add to the telemetry, and the signals that carry each one. The default is the portal\'s "Include recommended token claims in telemetry".')
param claimAttributes array = [
  {
    source: { kind: 'claims', value: 'tid' }
    signals: ['logs', 'traces', 'metrics']
  }
  {
    source: { kind: 'claims', value: 'oid' }
    signals: ['logs', 'traces', 'metrics']
  }
  {
    source: { kind: 'claims', value: 'appid' }
    signals: ['logs', 'traces']
  }
  {
    source: { kind: 'claims', value: 'azp' }
    signals: ['logs', 'traces']
  }
]

#disable-next-line BCP081
resource aiGateway 'Microsoft.ApiManagement/aigateways@2026-11-01' existing = {
  name: gatewayName
}

#disable-next-line BCP081
resource defaultWorkspace 'Microsoft.ApiManagement/aigateways/workspaces@2026-11-01' existing = {
  parent: aiGateway
  name: 'default'
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

// The OTLP properties aren't in the Bicep types for this API version yet. any() skips the type check.
var otlp = any(appInsights.properties)

#disable-next-line BCP081
resource telemetryExporter 'Microsoft.ApiManagement/aigateways/workspaces/telemetryExporters@2026-11-01' = {
  parent: defaultWorkspace
  name: exporterName
  properties: {
    telemetryExporterType: 'OpenTelemetry'
    // Prompts and responses can be sensitive and add volume, so payloads stay out of the telemetry.
    payloadCapture: false
    // No applicationInsights link: the portal finds the component through the Data Collection Rule in the endpoints.
    openTelemetry: {
      metricsEndpoint: {
        url: otlp.OTLPMetricsEndpoint
      }
      logsEndpoint: {
        url: otlp.OTLPLogsEndpoint
      }
      tracesEndpoint: {
        url: otlp.OTLPTracesEndpoint
      }
    }
    authentication: {
      managedIdentity: {
        resource: 'https://monitor.azure.com'
      }
    }
    telemetry: {
      attributes: claimAttributes
    }
  }
}

output telemetryExporterId string = telemetryExporter.id
