targetScope = 'subscription'

import { vmApplicationAssignmentType } from '../../shared/modules/orchestration/sessionHostPolicy/vmApplicationTypes.bicep'

@description('Required. Azure region for the policy assignment managed identity.')
param location string

@description('Required. Dedicated resource group containing the session host VMs to govern. Every VM in this resource group is in scope.')
param targetResourceGroupName string

@description('Optional. Name of the user-assigned identity used for Azure Policy remediation. A deterministic name is generated when empty.')
param policyIdentityName string = ''

@maxLength(25)
@description('Optional. Authoritative ordered VM Application list assigned to every VM in the target resource group. Leave empty to omit this capability.')
param vmApplications vmApplicationAssignmentType[] = []

@description('Optional. Deploy Azure Monitor Agent and associate the selected Data Collection Rule and optional Data Collection Endpoint.')
param enableMonitoring bool = false

@description('Conditional. Data Collection Rule resource ID. Required when enableMonitoring is true.')
param dataCollectionRuleResourceId string = ''

@description('Optional. Data Collection Endpoint resource ID associated when monitoring is enabled.')
param dataCollectionEndpointResourceId string = ''

@description('Optional. Deploy Guest Attestation to eligible Trusted Launch and Confidential VMs.')
param enableGuestAttestation bool = false

@description('Optional. Disable public network and export access on managed disks in the target resource group.')
param enableManagedDiskNetworkAccess bool = false

@description('Optional. Create or update a deterministic policy remediation task for existing noncompliant VMs.')
param createRemediation bool = false

@description('Optional. Stable owner label recorded on the shared deterministic policy assignment.')
param ownerId string = 'FederalAVD-StandaloneSessionHostPolicy'

var atLeastOneCapabilityEnabled = !empty(vmApplications) || enableMonitoring || enableGuestAttestation || enableManagedDiskNetworkAccess
  ? true
  : fail('Select at least one policy capability: VM Applications, monitoring, Guest Attestation, or managed-disk network isolation.')
var monitoringConfigurationIsValid = !enableMonitoring || !empty(dataCollectionRuleResourceId)
  ? true
  : fail('dataCollectionRuleResourceId is required when enableMonitoring is true.')
var ownershipTagName = 'FederalAVD-SessionHostPolicy-Owner'

resource targetResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: targetResourceGroupName
}

var existingOwnerId = targetResourceGroup.tags[?ownershipTagName] ?? ''
var ownershipIsValid = empty(existingOwnerId) || existingOwnerId == ownerId
  ? true
  : fail('The target resource group is already managed by session-host policy owner "${existingOwnerId}". Use that ownerId or remove the existing policy deployment before assigning a new owner.')
var resolvedPolicyIdentityName = empty(policyIdentityName)
  ? take('${targetResourceGroupName}-policy-remediation', 128)
  : policyIdentityName

module policyOwnershipTag '../../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = {
  params: {
    name: targetResourceGroupName
    location: targetResourceGroup.location
    tags: union(targetResourceGroup.tags ?? {}, {
      '${ownershipTagName}': ownershipIsValid && atLeastOneCapabilityEnabled ? ownerId : ownerId
    })
  }
}

module policyIdentity '../../shared/modules/resourceModules/managedIdentity/userAssignedIdentities/deploy.bicep' = {
  scope: resourceGroup(targetResourceGroupName)
  params: {
    name: resolvedPolicyIdentityName
    location: location
  }
}

module systemIdentityPolicyDefinition '../../shared/modules/orchestration/sessionHostPolicy/modules/systemAssignedIdentity.policyDefinition.bicep' = if (enableMonitoring) {
  params: {}
}

module vmApplicationPolicy '../../shared/modules/orchestration/sessionHostPolicy/vmApplications.bicep' = if (!empty(vmApplications)) {
  params: {
    location: location
    targetResourceGroupName: targetResourceGroupName
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyIdentityPrincipalId: policyIdentity.outputs.principalId
    vmApplications: vmApplications
    createRemediation: createRemediation
    manageVirtualMachineContributorRole: true
    ownerId: ownerId
  }
  dependsOn: [policyOwnershipTag]
}

module monitoringPolicy '../../shared/modules/orchestration/sessionHostPolicy/monitoring.bicep' = if (enableMonitoring) {
  params: {
    location: location
    targetResourceGroupName: targetResourceGroupName
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyIdentityPrincipalId: policyIdentity.outputs.principalId
    systemIdentityPolicyDefinitionResourceId: systemIdentityPolicyDefinition!.outputs.policyDefinitionResourceId
    dataCollectionRuleResourceId: monitoringConfigurationIsValid ? dataCollectionRuleResourceId : dataCollectionRuleResourceId
    dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
    assignSystemIdentityPolicy: true
    createRemediation: createRemediation
    ownerId: ownerId
  }
  dependsOn: [policyOwnershipTag]
}

module guestAttestationPolicy '../../shared/modules/orchestration/sessionHostPolicy/guestAttestation.bicep' = if (enableGuestAttestation) {
  params: {
    location: location
    targetResourceGroupName: targetResourceGroupName
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyIdentityPrincipalId: policyIdentity.outputs.principalId
    createRemediation: createRemediation
    ownerId: ownerId
  }
  dependsOn: [policyOwnershipTag]
}

module managedDiskNetworkAccessPolicy '../../shared/modules/orchestration/sessionHostPolicy/managedDiskNetworkAccess.bicep' = if (enableManagedDiskNetworkAccess) {
  params: {
    location: location
    targetResourceGroupName: targetResourceGroupName
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyIdentityPrincipalId: policyIdentity.outputs.principalId
    createAssignment: true
    createRemediation: createRemediation
    ownerId: ownerId
  }
  dependsOn: [policyOwnershipTag]
}

output policyIdentityResourceId string = policyIdentity.outputs.resourceId
output vmApplicationPolicyDefinitionResourceId string = !empty(vmApplications) ? vmApplicationPolicy!.outputs.policyDefinitionResourceId : ''
output vmApplicationPolicyAssignmentResourceId string = !empty(vmApplications) ? vmApplicationPolicy!.outputs.policyAssignmentResourceId : ''
output vmApplicationRemediationResourceId string = !empty(vmApplications) ? vmApplicationPolicy!.outputs.remediationResourceId : ''
output monitoringPolicyAssignmentResourceId string = enableMonitoring ? monitoringPolicy!.outputs.monitoringPolicyAssignmentResourceId : ''
output monitoringRemediationResourceIds string[] = enableMonitoring ? monitoringPolicy!.outputs.remediationResourceIds : []
output guestAttestationPolicyAssignmentResourceId string = enableGuestAttestation ? guestAttestationPolicy!.outputs.policyAssignmentResourceId : ''
output guestAttestationRemediationResourceId string = enableGuestAttestation ? guestAttestationPolicy!.outputs.remediationResourceId : ''
output managedDiskNetworkAccessPolicyAssignmentResourceId string = enableManagedDiskNetworkAccess ? managedDiskNetworkAccessPolicy!.outputs.policyAssignmentResourceId : ''
output managedDiskNetworkAccessRemediationResourceId string = enableManagedDiskNetworkAccess ? managedDiskNetworkAccessPolicy!.outputs.remediationResourceId : ''
output targetResourceGroupResourceId string = targetResourceGroup.id
