metadata name = 'Managed disk network policy orchestration'
metadata description = 'Creates the subscription managed-disk network-access policy definition and optionally provisions resource-group assignment, remediation identity permissions, and remediation.'

targetScope = 'subscription'

@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Name of the existing dedicated session-host resource group in this subscription; unrelated resources must not share this policy boundary.')
param targetResourceGroupName string
@description('Required. Resource ID of the existing user-assigned identity used by Azure Policy for remediation.')
param policyIdentityResourceId string
@description('Required. Principal object ID of the policy user-assigned identity for role assignments.')
param policyIdentityPrincipalId string
@description('Optional. Whether to create the resource-group policy assignment and its remediation permissions; the subscription definition is always created.')
param createAssignment bool = true
@description('Optional. Whether to create deterministic remediation tasks for existing noncompliant resources.')
param createRemediation bool = false
@description('Required. Stable ownership label recorded in policy assignment metadata.')
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

@description('Resource ID of the subscription policy definition created by this module.')
output policyDefinitionResourceId string = definition.outputs.policyDefinitionResourceId
@description('Resource ID of the managed-disk policy assignment, or an empty string when createAssignment is false.')
output policyAssignmentResourceId string = createAssignment ? assignment!.outputs.resourceId : ''
@description('Remediation task resource ID, or an empty string unless both assignment and remediation are requested.')
output remediationResourceId string = createAssignment && createRemediation ? remediation!.outputs.resourceId : ''
