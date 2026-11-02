metadata name = 'Session host monitoring policy orchestration'
metadata description = 'Composes monitoring definitions, an initiative, scoped identity permissions, and assignments for a dedicated session-host resource group, with optional system identity assignment and remediation tasks.'

targetScope = 'subscription'

@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Name of the existing dedicated session-host resource group in this subscription; unrelated resources must not share this policy boundary.')
param targetResourceGroupName string
@description('Required. Resource ID of the existing user-assigned identity used by Azure Policy for remediation.')
param policyIdentityResourceId string
@description('Required. Principal object ID of the policy user-assigned identity for role assignments.')
param policyIdentityPrincipalId string
@description('Required. Resource ID of the existing system-assigned identity Modify definition; used when assignSystemIdentityPolicy is true.')
param systemIdentityPolicyDefinitionResourceId string
@description('Required. Resource ID of the existing data collection rule to associate with session-host VMs.')
param dataCollectionRuleResourceId string
@description('Optional. Resource ID of an existing data collection endpoint; empty skips its association.')
param dataCollectionEndpointResourceId string = ''
@description('Optional. Whether to assign the supplied system-assigned identity policy before the monitoring initiative.')
param assignSystemIdentityPolicy bool = true
@description('Optional. Whether to create deterministic remediation tasks for existing noncompliant resources.')
param createRemediation bool = false
@description('Required. Stable ownership label recorded in policy assignment metadata.')
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

@description('Resource ID of the monitoring initiative assignment in the target session-host resource group.')
output monitoringPolicyAssignmentResourceId string = monitoringAssignment.outputs.resourceId
@description('Resource ID of the system-assigned identity policy assignment, or an empty string when its assignment is disabled.')
output identityPolicyAssignmentResourceId string = assignSystemIdentityPolicy ? identityAssignment!.outputs.resourceId : ''
@description('Remediation task resource IDs in identity, Agent, DCR, and optional DCE order; empty when remediation is disabled.')
output remediationResourceIds string[] = createRemediation ? concat(assignSystemIdentityPolicy ? [identityRemediation!.outputs.resourceId] : [], [agentRemediation!.outputs.resourceId, dcrRemediation!.outputs.resourceId], !empty(dataCollectionEndpointResourceId) ? [dceRemediation!.outputs.resourceId] : []) : []
