metadata name = 'User-assigned managed identity'
metadata description = 'Deploys a user-assigned managed identity and returns its resource ID, name, client ID and principal ID. Resource attachments and permissions are managed separately.'

@description('Required. Name of the user-assigned managed identity to deploy.')
param name string
@description('Optional. Azure region for the user-assigned managed identity; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the user-assigned managed identity.')
param tags object = {}

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

@description('Resource ID of the user-assigned managed identity.')
output resourceId string = userAssignedIdentity.id
@description('Azure resource name of the user-assigned managed identity.')
output name string = userAssignedIdentity.name
@description('Application client ID of the user-assigned managed identity, for identity selection by clients.')
output clientId string = userAssignedIdentity.properties.clientId
@description('Microsoft Entra service principal object ID of the user-assigned managed identity, for granting permissions.')
output principalId string = userAssignedIdentity.properties.principalId
