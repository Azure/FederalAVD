// Role Assignment Module
// Resource-group-scoped role assignment helper used by the AVD Alerts add-on
// to grant the Automation Account managed identity the necessary permissions.

// ========== //
// Parameters //
// ========== //

@description('Required. Principal ID (object ID) of the managed identity.')
param principalId string

@description('Required. GUID of the built-in role definition to assign.')
param roleDefinitionId string

@description('Required. Name of the resource group (used as part of the role assignment name to ensure uniqueness).')
param resourceGroupName string

@description('Required. Additional suffix to disambiguate the role assignment when the same role is assigned multiple times in different resource groups.')
param nameSuffix string

// ========== //
// Resources  //
// ========== //

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, roleDefinitionId, resourceGroupName, nameSuffix)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
