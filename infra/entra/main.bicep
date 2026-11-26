// Microsoft Entra apps for MCP servers that act as the signed-in user (on-behalf-of), from Microsoft's AI Gateway
// lab 33. An identity administrator deploys it once per environment; scripts/deploy.sh does it when you can.
//
//   backend app         the my-orders API. It accepts only delegated user tokens for its user_impersonation scope,
//                       and pre-authorizes the token exchange app for that scope.
//   token exchange app  the app the gateway exchanges the caller's token through. It pre-authorizes Azure AI Gateway,
//                       and trusts the gateway's user-assigned identity with a federated credential instead of a
//                       client secret.
//
// Pre-authorization stands in for consent on both hops, so no tenant-wide admin consent is needed: permission to
// register applications is enough (the default for users in many tenants, or Application Developer).
targetScope = 'resourceGroup'

extension microsoftGraphV1

@description('Prefix of the app names, for example aigw-demo. A resource group token is added: app names are tenant-wide.')
param baseName string

@description('Principal ID of the gateway\'s user-assigned identity (gateway.bicep).')
param gatewayIdentityPrincipalId string

param ownerObjectId string = deployer().objectId

var tenantId = tenant().tenantId
var aiGatewayAppId = '18550318-e177-4205-a743-6816d6fcdc3f'
var backendScopeName = 'user_impersonation'
var backendScope = {
  id: backendScopeId
  value: backendScopeName
  type: 'User'
  isEnabled: true
  adminConsentDisplayName: 'Read your orders'
  adminConsentDescription: 'Allows the AI Gateway token exchange app to read orders as the signed-in user.'
  userConsentDisplayName: 'Read your orders'
  userConsentDescription: 'Allows the app to read your orders on your behalf.'
}
var tokenExchangeApi = {
  requestedAccessTokenVersion: 2
  oauth2PermissionScopes: [
    {
      id: federationScopeId
      value: 'FederationApp.Access'
      type: 'User'
      isEnabled: true
      adminConsentDisplayName: 'Exchange user tokens through Azure AI Gateway'
      adminConsentDescription: 'Allows Azure AI Gateway to exchange the signed-in user\'s token through this app.'
      userConsentDisplayName: 'Let Azure AI Gateway act on your behalf'
      userConsentDescription: 'Allows Azure AI Gateway to call backend tools on your behalf.'
    }
  ]
  // Azure AI Gateway's first-party app. Pre-authorizing it needs only its app ID: a tenant may not have its service
  // principal, and only Microsoft can create one for a first-party app.
  preAuthorizedApplications: [ { appId: aiGatewayAppId, delegatedPermissionIds: [ federationScopeId ] } ]
}
var owners = { relationships: [ ownerObjectId ] }
var prefix = '${baseName}-${take(uniqueString(resourceGroup().id), 6)}'
var backendName = '${prefix}-my-orders-api'
var tokenExchangeName = '${prefix}-token-exchange'
var backendScopeId = guid(tenantId, backendName, backendScopeName)
var federationScopeId = guid(tenantId, tokenExchangeName, 'FederationApp.Access')

resource backendApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: backendName
  displayName: backendName
  signInAudience: 'AzureADMyOrg'
  owners: owners
  api: {
    requestedAccessTokenVersion: 2
    oauth2PermissionScopes: [ backendScope ]
  }
}

resource backendSp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: backendApp.appId
  owners: owners
}

resource tokenExchangeApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: tokenExchangeName
  displayName: tokenExchangeName
  signInAudience: 'AzureADMyOrg'
  owners: owners
  api: tokenExchangeApi
  requiredResourceAccess: [
    {
      resourceAppId: backendApp.appId
      resourceAccess: [ { id: backendScopeId, type: 'Scope' } ]
    }
  ]

  resource gatewayCredential 'federatedIdentityCredentials@v1.0' = {
    name: '${tokenExchangeApp.uniqueName}/ai-gateway'
    description: 'Azure AI Gateway user-assigned managed identity'
    audiences: [ 'api://AzureADTokenExchange' ]
    issuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
    subject: gatewayIdentityPrincipalId
  }
}

resource tokenExchangeSp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: tokenExchangeApp.appId
  owners: owners
}

// An app can't reference its own appId in identifierUris on create, so a module sets api://<appId> afterwards. For the
// backend, it also pre-authorizes the token exchange app, which only exists after the backend.
module backendUri 'app-identifier-uri.bicep' = {
  name: 'aigw-my-orders-api-uri'
  params: {
    uniqueName: backendApp.uniqueName
    displayName: backendApp.displayName
    appId: backendApp.appId
    api: {
      requestedAccessTokenVersion: 2
      oauth2PermissionScopes: [ backendScope ]
      preAuthorizedApplications: [
        { appId: tokenExchangeApp.appId, delegatedPermissionIds: [ backendScopeId ] }
      ]
    }
  }
}

module tokenExchangeUri 'app-identifier-uri.bicep' = {
  name: 'aigw-token-exchange-uri'
  params: {
    uniqueName: tokenExchangeApp.uniqueName
    displayName: tokenExchangeApp.displayName
    appId: tokenExchangeApp.appId
    api: tokenExchangeApi
  }
}

output backendAppId string = backendUri.outputs.appId
output backendScope string = '${backendUri.outputs.identifierUri}/${backendScopeName}'
output tokenExchangeAppId string = tokenExchangeUri.outputs.appId
