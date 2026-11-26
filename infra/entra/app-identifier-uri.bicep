// Sets an app's identifier URI to api://<appId>, which needs the appId that Microsoft Graph assigned on create, and
// its api settings, such as pre-authorized client apps.
extension microsoftGraphV1

param uniqueName string
param displayName string
param appId string

@description('The app\'s whole api block: Microsoft Graph replaces it, so pass all of it.')
param api object

resource application 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: uniqueName
  displayName: displayName
  identifierUris: [ 'api://${appId}' ]
  api: api
}

output appId string = application.appId
output identifierUri string = 'api://${appId}'
