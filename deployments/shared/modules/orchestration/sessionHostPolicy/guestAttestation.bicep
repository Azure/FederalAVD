metadata name = 'Guest Attestation policy orchestration'
metadata description = 'Creates the subscription Guest Attestation policy definition, grants remediation permissions, assigns it to a dedicated session-host resource group, and optionally creates a remediation task.'

targetScope = 'subscription'

@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Name of the existing dedicated session-host resource group in this subscription; unrelated resources must not share this policy boundary.')
param targetResourceGroupName string
@description('Required. Resource ID of the existing user-assigned identity used by Azure Policy for remediation.')
param policyIdentityResourceId string
@description('Required. Principal object ID of the policy user-assigned identity for role assignments.')
param policyIdentityPrincipalId string
@description('Optional. Whether to create deterministic remediation tasks for existing noncompliant resources.')
param createRemediation bool = false
@description('Required. Stable ownership label recorded in policy assignment metadata.')
param ownerId string

module definition 'modules/guestAttestation.policyDefinition.bicep' = { params: {} }
module vmContributor '../../resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  scope: resourceGroup(targetResourceGroupName)
  params: {
    roleDefinitionId: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
    principalId: policyIdentityPrincipalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Policy to deploy Guest Attestation on eligible session hosts.'
  }
}
module assignment 'modules/policyAssignment.bicep' = {
  scope: resourceGroup(targetResourceGroupName)
  params: {
    name: 'avd-sh-attest'
    location: location
    policyIdentityResourceId: policyIdentityResourceId
    policyDefinitionResourceId: definition.outputs.policyDefinitionResourceId
    displayName: 'Deploy Guest Attestation on AVD session hosts'
    description: 'Deploys Guest Attestation to Trusted Launch and Confidential VM session hosts.'
    parameters: { effect: { value: 'DeployIfNotExists' } }
    nonComplianceMessage: 'Trusted Launch and Confidential VM session hosts must run Guest Attestation.'
    ownerId: ownerId
  }
  dependsOn: [vmContributor]
}
module remediation 'modules/remediation.bicep' = if (createRemediation) {
  scope: resourceGroup(targetResourceGroupName)
  params: { name: 'avd-sh-attest', policyAssignmentId: assignment.outputs.resourceId }
}

@description('Resource ID of the session-host policy assignment.')
output policyAssignmentResourceId string = assignment.outputs.resourceId
@description('Resource ID of the remediation task, or an empty string when remediation is not requested.')
output remediationResourceId string = createRemediation ? remediation!.outputs.resourceId : ''
