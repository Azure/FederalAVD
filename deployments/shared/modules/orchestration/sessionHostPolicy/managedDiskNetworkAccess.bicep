targetScope = 'subscription'

param location string
param targetResourceGroupName string
param policyIdentityResourceId string
param policyIdentityPrincipalId string
param createAssignment bool = true
param createRemediation bool = false
param ownerId string

module definition 'modules/managedDiskNetworkAccess.policyDefinition.bicep' = { params: {} }
module diskOperator '../../resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = if (createAssignment) {
  scope: resourceGroup(targetResourceGroupName)
  params: {
    roleDefinitionId: '60fc6e62-5479-42d4-8bf4-67625fcc2840'
    principalId: policyIdentityPrincipalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Policy to disable public and export access on session host managed disks.'
  }
}
module assignment 'modules/policyAssignment.bicep' = if (createAssignment) {
  scope: resourceGroup(targetResourceGroupName)
  params: {
    name: 'avd-sh-managed-disk-network'
    location: location
    policyIdentityResourceId: policyIdentityResourceId
    policyDefinitionResourceId: definition.outputs.policyDefinitionResourceId
    displayName: 'Disable public access on AVD session host managed disks'
    description: 'Disables public network access and denies network export access on managed disks in the target resource group.'
    parameters: { effect: { value: 'Modify' } }
    nonComplianceMessage: 'Session host managed disks must disable public and export network access.'
    ownerId: ownerId
  }
  dependsOn: [diskOperator]
}
module remediation 'modules/remediation.bicep' = if (createAssignment && createRemediation) {
  scope: resourceGroup(targetResourceGroupName)
  params: { name: 'avd-sh-managed-disk-network', policyAssignmentId: assignment!.outputs.resourceId }
}

output policyDefinitionResourceId string = definition.outputs.policyDefinitionResourceId
output policyAssignmentResourceId string = createAssignment ? assignment!.outputs.resourceId : ''
output remediationResourceId string = createAssignment && createRemediation ? remediation!.outputs.resourceId : ''
