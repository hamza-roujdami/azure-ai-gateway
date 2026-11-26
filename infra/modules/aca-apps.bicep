// The workloads in the internal Container Apps environment:
//   mcp-server     the orders MCP server. VNet-only ingress, restricted to the gateway's integration subnet.
//   shipping-api   a REST API the gateway publishes as MCP tools from its OpenAPI description. Same ingress rule.
//   returns-agent  the returns specialist agent behind an MCP tool. Same ingress rule, and its own identity: it calls
//                  the gateway's model as itself.
//   my-orders      the signed-in user's orders (the mcp-server image, me_server.py). Same ingress rule, and it only
//                  accepts user tokens that the gateway exchanged on-behalf-of. Deployed when myOrders is set.
//   agent          the Agent Framework order agent (POST /chat). Environment-only ingress: not reachable from the VNet.
//   agent-smoke    a manual job that calls the agent from inside the environment, to test the whole private path.
// Every app but returns-agent runs as the shared apps identity.
targetScope = 'resourceGroup'

param location string
param tags object = {}
param environmentId string
param registryServer string
param identityId string
param identityClientId string
param returnsIdentityId string
param returnsIdentityClientId string
param imageTag string

param gatewayUrl string
param aliasName string

@description('MCP servers the order agent uses, comma-separated.')
param agentMcpServers string

@description('Replicas kept running. 1 avoids cold starts, which can time out a chain of tool calls; 0 scales to zero.')
@minValue(0)
param minReplicas int = 1

@description('CIDR of the gateway integration subnet: the only source allowed to call the backends.')
param gatewaySubnetPrefix string

@description('{ backendAppId, tokenExchangeAppId, accountOwners } from infra/entra, or {} to skip my-orders.')
param myOrders object = {}

var registries = [
  {
    server: registryServer
    identity: identityId
  }
]
var userIdentity = {
  type: 'UserAssigned'
  userAssignedIdentities: { '${identityId}': {} }
}
// external = reachable from the VNet. The environment is internal, so never from the internet.
var gatewayOnlyIngress = {
  external: true
  targetPort: 8000
  transport: 'http'
  allowInsecure: false
  ipSecurityRestrictions: [
    {
      name: 'ai-gateway-only'
      description: 'Only the AI gateway integration subnet'
      ipAddressRange: gatewaySubnetPrefix
      action: 'Allow'
    }
  ]
}
var healthProbe = [
  {
    type: 'Liveness'
    httpGet: { path: '/healthz', port: 8000 }
  }
]

resource mcpServer 'Microsoft.App/containerApps@2025-01-01' = {
  name: 'mcp-server'
  location: location
  tags: tags
  identity: userIdentity
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      ingress: gatewayOnlyIngress
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'mcp-server'
          image: '${registryServer}/mcp-server:${imageTag}'
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          probes: healthProbe
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 3 }
    }
  }
}

resource shippingApi 'Microsoft.App/containerApps@2025-01-01' = {
  name: 'shipping-api'
  location: location
  tags: tags
  identity: userIdentity
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      ingress: gatewayOnlyIngress
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'shipping-api'
          image: '${registryServer}/shipping-api:${imageTag}'
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          probes: healthProbe
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 3 }
    }
  }
}

resource returnsAgent 'Microsoft.App/containerApps@2025-01-01' = {
  name: 'returns-agent'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${returnsIdentityId}': {} }
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      ingress: gatewayOnlyIngress
      registries: [ { server: registryServer, identity: returnsIdentityId } ]
    }
    template: {
      containers: [
        {
          name: 'returns-agent'
          image: '${registryServer}/returns-agent:${imageTag}'
          env: [
            { name: 'AI_GATEWAY_URL', value: gatewayUrl }
            { name: 'AI_GATEWAY_MODEL', value: aliasName }
            { name: 'AZURE_CLIENT_ID', value: returnsIdentityClientId }
          ]
          resources: { cpu: json('0.5'), memory: '1Gi' }
          probes: healthProbe
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 3 }
    }
  }
}

resource myOrdersServer 'Microsoft.App/containerApps@2025-01-01' = if (!empty(myOrders)) {
  name: 'my-orders'
  location: location
  tags: tags
  identity: userIdentity
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      ingress: gatewayOnlyIngress
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'my-orders'
          image: '${registryServer}/mcp-server:${imageTag}'
          command: [ 'python', 'me_server.py' ]
          env: [
            { name: 'AZURE_TENANT_ID', value: tenant().tenantId }
            { name: 'BACKEND_APP_ID', value: myOrders.?backendAppId ?? '' }
            { name: 'TOKEN_EXCHANGE_APP_ID', value: myOrders.?tokenExchangeAppId ?? '' }
            { name: 'ACCOUNT_OWNERS', value: string(myOrders.?accountOwners ?? {}) }
          ]
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          probes: healthProbe
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 3 }
    }
  }
}

var agentEnv = [
  { name: 'AI_GATEWAY_URL', value: gatewayUrl }
  { name: 'AI_GATEWAY_MODEL', value: aliasName }
  { name: 'AI_GATEWAY_MCP_SERVERS', value: agentMcpServers }
  // DefaultAzureCredential picks the user-assigned identity with this client ID.
  { name: 'AZURE_CLIENT_ID', value: identityClientId }
]

resource agent 'Microsoft.App/containerApps@2025-01-01' = {
  name: 'agent'
  location: location
  tags: tags
  identity: userIdentity
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      // external = false: only apps and jobs in this environment can call the agent.
      ingress: {
        external: false
        targetPort: 8080
        transport: 'http'
        allowInsecure: false
      }
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'agent'
          image: '${registryServer}/aca-agent:${imageTag}'
          env: agentEnv
          resources: { cpu: json('0.5'), memory: '1Gi' }
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/healthz', port: 8080 }
            }
          ]
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 3 }
    }
  }
}

resource smoke 'Microsoft.App/jobs@2025-01-01' = {
  name: 'agent-smoke'
  location: location
  tags: tags
  identity: userIdentity
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 300
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'smoke'
          image: '${registryServer}/aca-agent:${imageTag}'
          command: [ 'python', '-m', 'smoke' ]
          env: [ { name: 'AGENT_URL', value: 'https://${agent.properties.configuration.ingress.fqdn}' } ]
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
        }
      ]
    }
  }
}

output mcpUrl string = 'https://${mcpServer.properties.configuration.ingress.fqdn}/mcp'
output shippingApiUrl string = 'https://${shippingApi.properties.configuration.ingress.fqdn}'
output returnsUrl string = 'https://${returnsAgent.properties.configuration.ingress.fqdn}/mcp'
output myOrdersUrl string = empty(myOrders) ? '' : 'https://${myOrdersServer!.properties.configuration.ingress.fqdn}/mcp'
output agentUrl string = 'https://${agent.properties.configuration.ingress.fqdn}'
output smokeJobName string = smoke.name
