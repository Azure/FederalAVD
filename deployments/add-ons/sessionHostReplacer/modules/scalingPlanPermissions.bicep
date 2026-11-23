metadata name = 'SHR scaling plan configuration permissions'
metadata description = 'Grants scaling-plan read/write operations to the SHR identity in the host-pool subscription.'

targetScope = 'subscription'

@description('Required. Principal ID of the SHR managed identity.')
param principalId string

// Plans can live outside the host-pool resource group. Runtime guards limit automatic
// repair to plans assigned only to that pool; RBAC cannot constrain individual properties.
resource role 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, 'FederalAVD.SHR.ScalingPlanConfiguration')
  properties: {
    roleName: 'FederalAVD SHR Scaling Plan Configuration (${subscription().subscriptionId})'
    description: 'Read and update scaling plans for guarded SHR exclusion-tag repair; no delete or role management.'
    type: 'CustomRole'
    assignableScopes: [subscription().id]
    permissions: [
      {
        actions: [
          'Microsoft.DesktopVirtualization/scalingPlans/read'
          'Microsoft.DesktopVirtualization/scalingPlans/write'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

module assignment '../../../shared/modules/resourceModules/authorization/roleAssignments/subscription/deploy.bicep' = {
  params: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: role.id
    assignmentDescription: 'Allow guarded SHR repair of an unshared scaling plan exclusion tag.'
  }
}
