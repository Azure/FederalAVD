targetScope = 'subscription'

param location string
param targetResourceGroupName string
param policyIdentityResourceId string
param policyIdentityPrincipalId string
param systemIdentityPolicyDefinitionResourceId string
param dataCollectionRuleResourceId string
param dataCollectionEndpointResourceId string = ''
param assignSystemIdentityPolicy bool = true
param createRemediation bool = false
param ownerId string

var virtualMachineContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
var monitoringContributorRoleId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'

module agentDefinition 'modules/azureMonitorAgent.policyDefinition.bicep' = { params: {} }
module associationDefinition 'modules/monitoringAssociation.policyDefinition.bicep' = { params: {} }
module monitoringInitiative 'modules/monitoring.policySetDefinition.bicep' = {
  params: {
    azureMonitorAgentPolicyDefinitionResourceId: agentDefinition.outputs.policyDefinitionResourceId
    monitoringAssociationPolicyDefinitionResourceId: associationDefinition.outputs.policyDefinitionResourceId
  }
}

module vmContributor '../../resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  scope: resourceGroup(targetResourceGroupName)
  params: {
    roleDefinitionId: virtualMachineContributorRoleId
    principalId: policyIdentityPrincipalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Policy to configure session host identity and monitoring extensions.'
  }
}

module monitoringContributor '../../resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  scope: resourceGroup(targetResourceGroupName)
  params: {
    roleDefinitionId: monitoringContributorRoleId
    principalId: policyIdentityPrincipalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Policy to deploy session host monitoring associations.'
  }
}

module dcrReader 'modules/dataCollectionRuleReader.bicep' = {
  scope: resourceGroup(split(dataCollectionRuleResourceId, '/')[2], split(dataCollectionRuleResourceId, '/')[4])
  params: {
    dataCollectionRuleName: last(split(dataCollectionRuleResourceId, '/'))!
    principalId: policyIdentityPrincipalId
  }
}

module dceContributor 'modules/dataCollectionEndpointContributor.bicep' = if (!empty(dataCollectionEndpointResourceId)) {
  scope: resourceGroup(split(dataCollectionEndpointResourceId, '/')[2], split(dataCollectionEndpointResourceId, '/')[4])
  params: {
    dataCollectionEndpointName: last(split(dataCollectionEndpointResourceId, '/'))!
    principalId: policyIdentityPrincipalId
  }
}

module identityAssignment 'modules/policyAssignment.bicep' = if (assignSystemIdentityPolicy) {
  scope: resourceGroup(targetResourceGroupName)
  params: {
    name: 'avd-sh-monitor-identity'
    location: location
    policyIdentityResourceId: policyIdentityResourceId
    policyDefinitionResourceId: systemIdentityPolicyDefinitionResourceId
    displayName: 'Enable system-assigned identity on AVD session hosts'
    description: 'Enables the VM identity required by Azure Monitor Agent identity authentication.'
    parameters: { effect: { value: 'Modify' } }
    nonComplianceMessage: 'The session host must have a system-assigned managed identity for monitoring.'
    ownerId: ownerId
  }
  dependsOn: [vmContributor]
}

module monitoringAssignment 'modules/policyAssignment.bicep' = {
  scope: resourceGroup(targetResourceGroupName)
  params: {
    name: 'avd-sh-monitor'
    location: location
    policyIdentityResourceId: policyIdentityResourceId
    policyDefinitionResourceId: monitoringInitiative.outputs.policySetDefinitionResourceId
    displayName: 'Deploy monitoring on AVD session hosts'
    description: 'Deploys Azure Monitor Agent and associates the selected Data Collection Rule and optional Data Collection Endpoint.'
    parameters: {
      effect: { value: 'DeployIfNotExists' }
      dataCollectionRuleResourceId: { value: dataCollectionRuleResourceId }
      dataCollectionEndpointResourceId: { value: dataCollectionEndpointResourceId }
      dataCollectionEndpointEffect: { value: empty(dataCollectionEndpointResourceId) ? 'Disabled' : 'DeployIfNotExists' }
    }
    nonComplianceMessage: 'The session host must run Azure Monitor Agent and have the selected monitoring associations.'
    ownerId: ownerId
  }
  dependsOn: [identityAssignment, vmContributor, monitoringContributor, dcrReader, dceContributor]
}

module identityRemediation 'modules/remediation.bicep' = if (createRemediation && assignSystemIdentityPolicy) {
  scope: resourceGroup(targetResourceGroupName)
  params: { name: 'avd-sh-monitor-identity', policyAssignmentId: identityAssignment!.outputs.resourceId }
}
module agentRemediation 'modules/remediation.bicep' = if (createRemediation) {
  scope: resourceGroup(targetResourceGroupName)
  params: { name: 'avd-sh-monitor-agent', policyAssignmentId: monitoringAssignment.outputs.resourceId, policyDefinitionReferenceId: 'deployAzureMonitorAgent' }
  dependsOn: [identityRemediation]
}
module dcrRemediation 'modules/remediation.bicep' = if (createRemediation) {
  scope: resourceGroup(targetResourceGroupName)
  params: { name: 'avd-sh-monitor-dcr', policyAssignmentId: monitoringAssignment.outputs.resourceId, policyDefinitionReferenceId: 'associateDataCollectionRule' }
  dependsOn: [agentRemediation]
}
module dceRemediation 'modules/remediation.bicep' = if (createRemediation && !empty(dataCollectionEndpointResourceId)) {
  scope: resourceGroup(targetResourceGroupName)
  params: { name: 'avd-sh-monitor-dce', policyAssignmentId: monitoringAssignment.outputs.resourceId, policyDefinitionReferenceId: 'associateDataCollectionEndpoint' }
  dependsOn: [agentRemediation]
}

output monitoringPolicyAssignmentResourceId string = monitoringAssignment.outputs.resourceId
output identityPolicyAssignmentResourceId string = assignSystemIdentityPolicy ? identityAssignment!.outputs.resourceId : ''
output remediationResourceIds string[] = createRemediation ? concat(assignSystemIdentityPolicy ? [identityRemediation!.outputs.resourceId] : [], [agentRemediation!.outputs.resourceId, dcrRemediation!.outputs.resourceId], !empty(dataCollectionEndpointResourceId) ? [dceRemediation!.outputs.resourceId] : []) : []
