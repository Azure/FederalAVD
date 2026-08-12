targetScope = 'subscription'

@description('Required. Resource ID of the Azure Monitor Private Link Scope (AMPLS) to update.')
param privateLinkScopeResourceId string

@description('Required. Array of resource IDs to associate as scoped resources on the AMPLS.')
param scopedResourceIds array

@description('Required. Unique suffix used for deterministic deployment naming and idempotency.')
param deploymentSuffix string

module addScopedResources 'addScopedResources-PrivateLinkScope.bicep' = {
  scope: resourceGroup(split(privateLinkScopeResourceId, '/')[2], split(privateLinkScopeResourceId, '/')[4])
  name: 'addScopedResources-${deploymentSuffix}'
  params: {
    privateLinkScopeResourceId: privateLinkScopeResourceId
    scopedResourceIds: scopedResourceIds
  }
}
