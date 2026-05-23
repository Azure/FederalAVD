targetScope = 'subscription'

param resourceGroupHosts string
param appGroupSecurityGroups array
param deploymentSuffix string

module roleAssignment '../../../../.common/bicepModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = [
  for i in range(0, length(appGroupSecurityGroups)): {
    name: 'RA-Hosts-VMLoginUser-${i}-${deploymentSuffix}'
    scope: resourceGroup(resourceGroupHosts)
    params: {
      principalId: appGroupSecurityGroups[i]
      principalType: 'Group'
      roleDefinitionId: 'fb879df8-f326-4884-b1cf-06f3ad86be52' // Virtual Machine User Login
    }
  }
]
