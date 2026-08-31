@description('Required. Name of the existing automated host pool.')
param hostPoolName string

@description('Required. Principal ID of the automated host-pool managed identity.')
param principalId string

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview' existing = {
  name: hostPoolName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: hostPool
  name: guid(hostPool.id, principalId, 'a959dbd1-f747-45e3-8ba6-dd80f235f97c')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'a959dbd1-f747-45e3-8ba6-dd80f235f97c'
    )
    principalId: principalId
    principalType: 'ServicePrincipal'
    description: 'Allows Azure Virtual Desktop to manage virtual machines for this automated host pool.'
  }
}

output resourceId string = roleAssignment.id
