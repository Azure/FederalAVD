targetScope = 'subscription'

param privateLinkScopeResourceId string
param scopedResourceIds array
param deploymentSuffix string

module addScopedResources 'addScopedResources-PrivateLinkScope.bicep' = {
  scope: resourceGroup(split(privateLinkScopeResourceId, '/')[2], split(privateLinkScopeResourceId, '/')[4])
  name: 'addScopedResources-${deploymentSuffix}'
  params: {
    privateLinkScopeResourceId: privateLinkScopeResourceId
    scopedResourceIds: scopedResourceIds
  }
}
