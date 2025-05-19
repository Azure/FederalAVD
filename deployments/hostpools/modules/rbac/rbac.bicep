targetScope = 'subscription'

param avdObjectId string
param deployScalingPlan bool
param startVmOnConnect bool

// Role Assignment required for Start VM On Connect
resource roleAssignment_PowerOnContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!deployScalingPlan && startVmOnConnect) {
  name: guid(avdObjectId, '489581de-a3bd-480d-9518-53dea7416b33', subscription().id)
  properties: {
    roleDefinitionId: resourceId(
      'Microsoft.Authorization/roleDefinitions',
      '489581de-a3bd-480d-9518-53dea7416b33' // Desktop Virtualization Power On Contributor
    )
    principalId: avdObjectId
  }
}

// Role Assignment required for Scaling Plans
resource roleAssignment_PowerOnOffContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployScalingPlan) {
  name: guid(avdObjectId, '40c5ff49-9181-41f8-ae61-143b0e78555e', subscription().id)
  properties: {
    roleDefinitionId: resourceId(
      'Microsoft.Authorization/roleDefinitions',
     '40c5ff49-9181-41f8-ae61-143b0e78555e' // Desktop Virtualization Power On Off Contributor
    )
    principalId: avdObjectId
  }
}
