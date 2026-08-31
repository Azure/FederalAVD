@description('Required. Azure Monitor Private Link Scope name.')
param name string

@description('Required. Azure region for the Azure Monitor Private Link Scope.')
param location string

@description('Optional. Default access mode for ingestion through associated private endpoints.')
@allowed([
  'Open'
  'PrivateOnly'
])
param ingestionAccessMode string = 'PrivateOnly'

@description('Optional. Default access mode for queries through associated private endpoints.')
@allowed([
  'Open'
  'PrivateOnly'
])
param queryAccessMode string = 'PrivateOnly'

@description('Optional. Resource tags.')
param tags object = {}

resource privateLinkScope 'Microsoft.Insights/privateLinkScopes@2021-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    accessModeSettings: {
      ingestionAccessMode: ingestionAccessMode
      queryAccessMode: queryAccessMode
      exclusions: []
    }
  }
}

output resourceId string = privateLinkScope.id
output resourceName string = privateLinkScope.name
