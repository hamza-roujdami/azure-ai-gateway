// The workloads in the internal Container Apps environment, all running as one user-assigned identity:
//   mcp-server   the private MCP tool backend. VNet-only ingress, restricted to the gateway's integration subnet.
//   agent        the Agent Framework agent (POST /chat). Environment-only ingress: not reachable from the VNet.
//   agent-smoke  a manual job that calls the agent from inside the environment, to test the whole private path.
targetScope = 'resourceGroup'

param location string
param tags object = {}
param environmentId string
param registryServer string
param identityId string
param identityClientId string
param imageTag string

param gatewayUrl string
param aliasName string
param mcpServerName string

@description('CIDR of the gateway integration subnet: the only source allowed to call the MCP server.')
param gatewaySubnetPrefix string

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

resource mcpServer 'Microsoft.App/containerApps@2025-01-01' = {
  name: 'mcp-server'
  location: location
  tags: tags
  identity: userIdentity
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      // external = reachable from the VNet. The environment is internal, so never from the internet.
      ingress: {
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
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'mcp-server'
          image: '${registryServer}/mcp-server:${imageTag}'
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/healthz', port: 8000 }
            }
          ]
        }
      ]
      scale: { minReplicas: 0, maxReplicas: 3 }
    }
  }
}

var agentEnv = [
  { name: 'AI_GATEWAY_URL', value: gatewayUrl }
  { name: 'AI_GATEWAY_MODEL', value: aliasName }
  { name: 'AI_GATEWAY_MCP_SERVER', value: mcpServerName }
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
      scale: { minReplicas: 0, maxReplicas: 3 }
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
output agentUrl string = 'https://${agent.properties.configuration.ingress.fqdn}'
output smokeJobName string = smoke.name
