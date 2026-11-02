metadata name = 'Azure Monitor scoped resources'
metadata description = 'Adds linked resources to an existing Azure Monitor Private Link Scope in the deployment resource group. The caller must select the resource group containing the scope.'

@description('Required. Resource IDs of existing Azure Monitor resources to link to the private link scope.')
param scopedResourceIds array
@description('Required. Resource ID of the existing Azure Monitor Private Link Scope; it must be in the deployment resource group.')
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
