param scopedResourceIds array
param privateLinkScopeResourceId string

#disable-next-line BCP081
resource privateLinkScope 'Microsoft.Insights/privateLinkScopes@2021-09-01' existing = {
  name: last(split(privateLinkScopeResourceId, '/'))
}

resource scopedResources 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = [for resourceId in scopedResourceIds: {
  parent: privateLinkScope
  name: uniqueString(resourceId)
  properties: {
    linkedResourceId: resourceId
  }
}]
