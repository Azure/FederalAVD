targetScope = 'subscription'

param location string
param targetResourceGroupName string
param policyIdentityResourceId string
param policyIdentityPrincipalId string
param createRemediation bool = false
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

output policyAssignmentResourceId string = assignment.outputs.resourceId
output remediationResourceId string = createRemediation ? remediation!.outputs.resourceId : ''
