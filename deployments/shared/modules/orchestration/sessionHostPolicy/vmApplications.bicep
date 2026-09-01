targetScope = 'subscription'

import { vmApplicationAssignmentType } from 'vmApplicationTypes.bicep'

@description('Required. Azure region for the policy assignment managed identity.')
param location string

@description('Required. Resource group containing only the session host virtual machines governed by this assignment.')
param targetResourceGroupName string

@description('Required. Resource ID of the user-assigned identity used by Azure Policy.')
@metadata({
  strongType: 'Microsoft.ManagedIdentity/userAssignedIdentities'
})
param policyIdentityResourceId string

@description('Required. Principal ID of the policy user-assigned identity.')
param policyIdentityPrincipalId string

@maxLength(25)
@description('Required. Authoritative ordered list of Azure Compute Gallery application version references. References may select an immutable semantic version or use /versions/latest.')
param vmApplications vmApplicationAssignmentType[]

@description('Optional. Create or update a deterministic remediation task for existing noncompliant VMs.')
param createRemediation bool = false

@description('Optional. Grant Virtual Machine Contributor to the policy identity at the target resource group. Disable when the caller already owns this role assignment.')
param manageVirtualMachineContributorRole bool = true

@description('Optional. Stable ownership label recorded in policy assignment metadata. Deployments targeting the same resource group jointly manage the same deterministic assignment.')
param ownerId string = 'FederalAVD'

var virtualMachineContributorRoleDefinitionId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
var readerRoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var validVmApplications = filter(vmApplications, application => contains(toLower(application.packageReferenceId), '/providers/microsoft.compute/galleries/') && contains(toLower(application.packageReferenceId), '/applications/') && contains(toLower(application.packageReferenceId), '/versions/'))
var applicationDefinitionResourceIds = map(vmApplications, application => substring(application.packageReferenceId, 0, lastIndexOf(toLower(application.packageReferenceId), '/versions/')))
var configurationIsValid = !empty(vmApplications) && length(validVmApplications) == length(vmApplications) && length(union(applicationDefinitionResourceIds, [])) == length(applicationDefinitionResourceIds)
  ? true
  : fail('vmApplications must contain 1-25 valid Gallery application version resource IDs and cannot contain more than one version of the same application.')
var galleryResourceIds = union(map(vmApplications, application => substring(application.packageReferenceId, 0, lastIndexOf(toLower(application.packageReferenceId), '/applications/'))), [])
var ownershipTagName = 'FederalAVD-SessionHostPolicy-Owner'

resource targetResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: targetResourceGroupName
}

var existingOwnerId = targetResourceGroup.tags[?ownershipTagName] ?? ''
var ownershipIsValid = empty(existingOwnerId) || existingOwnerId == ownerId
  ? true
  : fail('The target resource group is already managed by session-host policy owner "${existingOwnerId}". Use that ownerId or remove the existing policy deployment before assigning a new owner.')

module policyOwnershipTag '../../resourceModules/resources/resourceGroups/deploy.bicep' = {
  params: {
    name: targetResourceGroupName
    location: targetResourceGroup.location
    tags: union(targetResourceGroup.tags ?? {}, {
      '${ownershipTagName}': ownershipIsValid ? ownerId : ownerId
    })
  }
}

module policyDefinition 'modules/vmApplications.policyDefinition.bicep' = {
  params: {}
}

module policyIdentityVirtualMachineContributor '../../resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = if (manageVirtualMachineContributorRole) {
  scope: targetResourceGroup
  params: {
    roleDefinitionId: virtualMachineContributorRoleDefinitionId
    principalId: policyIdentityPrincipalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Policy to maintain the authoritative VM Application list on targeted session hosts.'
  }
}

module policyIdentityGalleryReaders '../../resourceModules/compute/galleries/roleAssignment.bicep' = [for galleryResourceId in galleryResourceIds: {
  scope: resourceGroup(split(galleryResourceId, '/')[2], split(galleryResourceId, '/')[4])
  params: {
    galleryName: last(split(galleryResourceId, '/'))!
    assignments: [
      {
        roleDefinitionId: readerRoleDefinitionId
        principalId: policyIdentityPrincipalId
        principalType: 'ServicePrincipal'
        description: 'Allows Azure Policy to resolve VM Application versions while updating session hosts.'
      }
    ]
  }
}]

module policyAssignment 'modules/vmApplicationsAssignment.bicep' = {
  scope: targetResourceGroup
  params: {
    location: location
    policyIdentityResourceId: policyIdentityResourceId
    policyDefinitionResourceId: policyDefinition.outputs.policyDefinitionResourceId
    vmApplications: configurationIsValid ? vmApplications : []
    createRemediation: createRemediation
    ownerId: ownerId
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
    policyIdentityGalleryReaders
    policyOwnershipTag
  ]
}

output policyDefinitionResourceId string = policyDefinition.outputs.policyDefinitionResourceId
output policyAssignmentResourceId string = policyAssignment.outputs.policyAssignmentResourceId
output policyIdentityResourceId string = policyIdentityResourceId
output remediationResourceId string = policyAssignment.outputs.remediationResourceId
output targetResourceGroupResourceId string = targetResourceGroup.id
