targetScope = 'subscription'

import { artifactCustomizationType } from '../../shared/modules/resourceModules/types/customizationTypes.bicep'
import { vmApplicationAssignmentType } from '../../shared/modules/orchestration/sessionHostPolicy/vmApplicationTypes.bicep'

type fslogixConfigurationType = {
  identitySolution: 'ActiveDirectoryDomainServices' | 'EntraDomainServices' | 'EntraKerberos-CloudOnly' | 'EntraKerberos-Hybrid'
  storageService: 'AzureFiles' | 'AzureNetAppFiles'
  containerType: 'CloudCacheProfileContainer' | 'CloudCacheProfileOfficeContainer' | 'ProfileContainer' | 'ProfileOfficeContainer'
  fileShareNames: string[]
  localStorageAccountResourceIds: string[]
  remoteStorageAccountResourceIds: string[]
  localNetAppServerFqdns: string[]
  remoteNetAppServerFqdns: string[]
  objectSpecificSettingsGroups: string[]
  profileSizeInMBs: int
}

@description('Required. Azure region for the policy assignment managed identity.')
param location string

@description('Required. Resource group containing the automated session host virtual machines.')
param sessionHostResourceGroupName string

@description('Optional. Resource ID of the automated AVD host pool associated with resources created by this policy stage.')
@metadata({
  strongType: 'Microsoft.DesktopVirtualization/hostPools'
})
param hostPoolResourceId string = ''

@description('Required. Name of the user-assigned identity used by Azure Policy remediation.')
param policyIdentityName string

@description('Optional. Resource ID of the Disk Encryption Set enforced on session host OS disks.')
@metadata({
  strongType: 'Microsoft.Compute/diskEncryptionSets'
})
param diskEncryptionSetResourceId string = ''

@description('Optional. Resource ID of the managed Availability Set enforced on session host virtual machines.')
@metadata({
  strongType: 'Microsoft.Compute/availabilitySets'
})
param availabilitySetResourceId string = ''

@description('Optional. Deploy Azure Monitor Agent and associate automated session hosts with the selected Data Collection Rule.')
param enableMonitoring bool = true

@description('Conditional. Resource ID of the Data Collection Rule associated with automated session hosts. Required when enableMonitoring is true.')
@metadata({
  strongType: 'Microsoft.Insights/dataCollectionRules'
})
param dataCollectionRuleResourceId string = ''

@description('Optional. Resource ID of the Data Collection Endpoint associated with automated session hosts.')
@metadata({
  strongType: 'Microsoft.Insights/dataCollectionEndpoints'
})
param dataCollectionEndpointResourceId string = ''

@description('Optional. Deploy Guest Attestation to Trusted Launch and Confidential VM session hosts for integrity monitoring.')
param integrityMonitoring bool = true

@description('Optional. Enforce encryption at host on session hosts. When false, the creation-settings initiative does not manage this property.')
param encryptionAtHost bool = true

@minValue(0)
@description('Optional. OS disk size in GB. Set to zero to preserve the image default.')
param diskSizeGB int = 0

@description('Optional. Enforce accelerated networking on session host network interfaces. When false, the creation-settings initiative disables this member. The selected VM size must support accelerated networking.')
param enableAcceleratedNetworking bool = true

@description('Optional. Windows time zone configured on automated session hosts.')
param virtualMachinesTimeZone string = 'Eastern Standard Time'

@description('Optional. Disable public network access and deny all network export access on session host managed disks.')
param disableManagedDiskPublicNetworkAccess bool = false

@description('Optional. Configure identity-based FSLogix settings on automated session hosts.')
param configureFSLogix bool = false

@description('Optional. Identity-based FSLogix configuration applied when configureFSLogix is true.')
param fslogixConfiguration fslogixConfigurationType = {
  identitySolution: 'EntraKerberos-CloudOnly'
  storageService: 'AzureFiles'
  containerType: 'ProfileContainer'
  fileShareNames: ['profile-containers']
  localStorageAccountResourceIds: []
  remoteStorageAccountResourceIds: []
  localNetAppServerFqdns: []
  remoteNetAppServerFqdns: []
  objectSpecificSettingsGroups: []
  profileSizeInMBs: 30000
}

@description('Optional. HTTPS URI of the private Azure Blob container holding session host customization artifacts.')
param artifactsContainerUri string = ''

@description('Optional. Resource ID of the user-assigned identity with read access to the private artifact container.')
param artifactsUserAssignedIdentityResourceId string = ''

@description('Optional. Ordered, idempotent customizations applied to automated session hosts. Uses the same object shape and execution order as the host pool and session hosts add-on.')
param sessionHostCustomizations artifactCustomizationType[] = []

@minLength(0)
@maxLength(25)
@description('Optional. Authoritative ordered list of Azure Compute Gallery application version references assigned to automated session hosts through Azure Policy. References may select a specific version or use /versions/latest.')
param sessionHostVmApplications vmApplicationAssignmentType[] = []

@description('Optional. Tags applied to resources created by this policy stage.')
param tags object = {}

var virtualMachineContributorRoleDefinitionId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
var tagContributorRoleDefinitionId = '4a9ae827-6dc8-4573-8ac7-8239d42aa03f'
var managedIdentityOperatorRoleDefinitionId = 'f1a07417-d97a-45cb-824c-7a7467783830'
var policyOwnerId = empty(hostPoolResourceId) ? 'FederalAVD-AutomatedHostPool' : hostPoolResourceId
var inheritResourceGroupTagPolicyResourceId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  'cd3aa116-8754-49c9-a813-ad46512ece54'
)
var monitoringConfigurationIsValid = !enableMonitoring || !empty(dataCollectionRuleResourceId)
  ? true
  : fail('dataCollectionRuleResourceId is required when enableMonitoring is true.')
var relativeSessionHostCustomizations = filter(sessionHostCustomizations, customization => !startsWith(customization.blobNameOrUri, 'https://'))
var sessionHostCustomizationConfigurationIsValid = empty(sessionHostCustomizations) || (!empty(artifactsUserAssignedIdentityResourceId) && (empty(relativeSessionHostCustomizations) || !empty(artifactsContainerUri)))
  ? true
  : fail('artifactsUserAssignedIdentityResourceId is required for sessionHostCustomizations, and artifactsContainerUri is required when any blobNameOrUri is relative.')
var validVmApplications = filter(sessionHostVmApplications, application => contains(toLower(application.packageReferenceId), '/providers/microsoft.compute/galleries/') && contains(toLower(application.packageReferenceId), '/applications/') && contains(toLower(application.packageReferenceId), '/versions/'))
var vmApplicationDefinitionResourceIds = map(sessionHostVmApplications, application => contains(toLower(application.packageReferenceId), '/versions/')
  ? substring(application.packageReferenceId, 0, lastIndexOf(toLower(application.packageReferenceId), '/versions/'))
  : application.packageReferenceId)
var vmApplicationConfigurationIsValid = length(validVmApplications) == length(sessionHostVmApplications) && length(union(vmApplicationDefinitionResourceIds, [])) == length(vmApplicationDefinitionResourceIds)
  ? true
  : fail('sessionHostVmApplications must contain valid Gallery application version resource IDs and cannot contain more than one version of the same application.')
var normalizedArtifactsContainerUri = endsWith(artifactsContainerUri, '/')
  ? take(artifactsContainerUri, max(length(artifactsContainerUri) - 1, 0))
  : artifactsContainerUri
var finalSessionHostCustomizationName = !empty(sessionHostCustomizations)
  ? replace(last(sessionHostCustomizations)!.name, ' ', '-')
  : 'PrivateCustomization-Final'
var parentResourceTags = empty(hostPoolResourceId) ? {} : { 'cm-resource-parent': hostPoolResourceId }
var resourceGroupTags = union(tags[?'Microsoft.Resources/resourceGroups'] ?? {}, parentResourceTags, empty(hostPoolResourceId) ? {} : {
  'FederalAVD-SessionHostPolicy-Owner': hostPoolResourceId
})
var managedIdentityTags = union(tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {}, parentResourceTags)

resource existingSessionHostResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: sessionHostResourceGroupName
}

module sessionHostResourceGroupTags '../../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (!empty(hostPoolResourceId)) {
  params: {
    name: sessionHostResourceGroupName
    location: existingSessionHostResourceGroup.location
    tags: union(existingSessionHostResourceGroup.tags ?? {}, resourceGroupTags)
  }
}

module policyIdentity '../../shared/modules/resourceModules/managedIdentity/userAssignedIdentities/deploy.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: policyIdentityName
    location: location
    tags: managedIdentityTags
  }
}

module diskEncryptionSetPolicyDefinition '../../shared/modules/orchestration/sessionHostPolicy/modules/virtualMachine-diskEncryptionSet.policyDefinition.bicep' = {
  params: {}
}

module sessionHostConfigurationPolicyDefinition '../../shared/modules/orchestration/sessionHostPolicy/modules/configureSessionHost.policyDefinition.bicep' = {
  params: {}
}

module privateCustomizationPolicyDefinition '../../shared/modules/orchestration/sessionHostPolicy/modules/privateCustomization.policyDefinition.bicep' = if (!empty(sessionHostCustomizations)) {
  params: {}
}

module managedDiskNetworkAccessPolicyDefinition '../../shared/modules/orchestration/sessionHostPolicy/modules/managedDiskNetworkAccess.policyDefinition.bicep' = {
  params: {}
}

module sessionHostComputePolicyDefinition '../../shared/modules/orchestration/sessionHostPolicy/modules/sessionHostCompute.policyDefinition.bicep' = {
  params: {}
}

module availabilitySetPolicyDefinition '../../shared/modules/orchestration/sessionHostPolicy/modules/virtualMachine-availabilitySet.policyDefinition.bicep' = {
  params: {}
}

module sessionHostSystemAssignedIdentityPolicyDefinition '../../shared/modules/orchestration/sessionHostPolicy/modules/systemAssignedIdentity.policyDefinition.bicep' = {
  params: {}
}

module acceleratedNetworkingPolicyDefinition '../../shared/modules/orchestration/sessionHostPolicy/modules/networkInterfaceAcceleratedNetworking.policyDefinition.bicep' = {
  params: {}
}

module sessionHostCreationSettingsPolicySetDefinition '../../shared/modules/orchestration/sessionHostPolicy/modules/sessionHostCreationSettings.policySetDefinition.bicep' = {
  params: {
    diskEncryptionSetPolicyDefinitionResourceId: diskEncryptionSetPolicyDefinition.outputs.policyDefinitionResourceId
    sessionHostComputePolicyDefinitionResourceId: sessionHostComputePolicyDefinition.outputs.policyDefinitionResourceId
    sessionHostSystemAssignedIdentityPolicyDefinitionResourceId: sessionHostSystemAssignedIdentityPolicyDefinition.outputs.policyDefinitionResourceId
    acceleratedNetworkingPolicyDefinitionResourceId: acceleratedNetworkingPolicyDefinition.outputs.policyDefinitionResourceId
    managedDiskNetworkAccessPolicyDefinitionResourceId: managedDiskNetworkAccessPolicyDefinition.outputs.policyDefinitionResourceId
    availabilitySetPolicyDefinitionResourceId: availabilitySetPolicyDefinition.outputs.policyDefinitionResourceId
  }
}

module policyIdentityVirtualMachineContributor '../../shared/modules/resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    roleDefinitionId: virtualMachineContributorRoleDefinitionId
    principalId: policyIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Policy to configure automated AVD session host virtual machines.'
  }
}

module policyIdentityNetworkContributor '../../shared/modules/resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = if (enableAcceleratedNetworking) {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    roleDefinitionId: '4d97b98b-1d4f-4787-a291-c67834d212e7'
    principalId: policyIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Policy to enforce network interface settings for automated AVD session hosts.'
  }
}

module policyIdentityTagContributor '../../shared/modules/resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = if (!empty(hostPoolResourceId)) {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    roleDefinitionId: tagContributorRoleDefinitionId
    principalId: policyIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Policy to inherit the host pool ownership tag on automated AVD session host resources.'
  }
}

module policyIdentityDiskPoolOperator '../../shared/modules/resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = if (disableManagedDiskPublicNetworkAccess) {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    roleDefinitionId: '60fc6e62-5479-42d4-8bf4-67625fcc2840'
    principalId: policyIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Policy to disable public network access on automated AVD session host managed disks.'
  }
}

module policyIdentityArtifactManagedIdentityOperator '../../shared/modules/resourceModules/managedIdentity/userAssignedIdentities/roleAssignment.bicep' = if (!empty(sessionHostCustomizations)) {
  scope: resourceGroup(
    split(artifactsUserAssignedIdentityResourceId, '/')[2],
    split(artifactsUserAssignedIdentityResourceId, '/')[4]
  )
  params: {
    identityName: last(split(artifactsUserAssignedIdentityResourceId, '/'))!
    assignments: [
      {
        roleDefinitionId: managedIdentityOperatorRoleDefinitionId
        principalId: policyIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        description: 'Allows Azure Policy to attach the private artifact identity to automated AVD session hosts.'
      }
    ]
  }
}

module sessionHostCreationSettingsPolicyAssignment '../../shared/modules/orchestration/sessionHostPolicy/modules/policyAssignment.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-creation-settings'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: sessionHostCreationSettingsPolicySetDefinition.outputs.policySetDefinitionResourceId
    displayName: 'Configure AVD session host creation settings'
    description: 'Configures compute security, optional Disk Encryption Set and Availability Set placement, system-assigned identity, accelerated networking, and optional managed-disk network access during resource creation or update.'
    parameters: {
      effect: {
        value: 'Modify'
      }
      encryptionAtHost: {
        value: encryptionAtHost
      }
      diskSizeGB: {
        value: diskSizeGB
      }
      enableAcceleratedNetworking: {
        value: enableAcceleratedNetworking
      }
      acceleratedNetworkingEffect: {
        value: enableAcceleratedNetworking ? 'Modify' : 'Disabled'
      }
      diskEncryptionSetEffect: {
        value: empty(diskEncryptionSetResourceId) ? 'Disabled' : 'Modify'
      }
      diskEncryptionSetResourceId: {
        value: diskEncryptionSetResourceId
      }
      managedDiskNetworkAccessEffect: {
        value: disableManagedDiskPublicNetworkAccess ? 'Modify' : 'Disabled'
      }
      availabilitySetEffect: {
        value: empty(availabilitySetResourceId) ? 'Disabled' : 'Modify'
      }
      availabilitySetResourceId: {
        value: availabilitySetResourceId
      }
    }
    nonComplianceMessage: 'Session host resources must use the selected creation-time compute, identity, networking, availability, encryption, and managed-disk settings.'
    ownerId: policyOwnerId
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
    policyIdentityNetworkContributor
    policyIdentityDiskPoolOperator
  ]
}

module resourceOwnershipTagPolicyAssignment '../../shared/modules/orchestration/sessionHostPolicy/modules/policyAssignment.bicep' = if (!empty(hostPoolResourceId)) {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-parent-tag'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: inheritResourceGroupTagPolicyResourceId
    displayName: 'Inherit the automated AVD host pool ownership tag'
    description: 'Copies cm-resource-parent from the dedicated session host resource group to service-created virtual machines, network interfaces, and managed disks.'
    parameters: {
      tagName: {
        value: 'cm-resource-parent'
      }
    }
    nonComplianceMessage: 'Session host resources must inherit the cm-resource-parent tag from their resource group.'
    ownerId: policyOwnerId
  }
  dependsOn: [
    policyIdentityTagContributor
    sessionHostResourceGroupTags
  ]
}

module monitoringPolicyAssignment '../../shared/modules/orchestration/sessionHostPolicy/monitoring.bicep' = if (enableMonitoring) {
  params: {
    location: location
    targetResourceGroupName: sessionHostResourceGroupName
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyIdentityPrincipalId: policyIdentity.outputs.principalId
    systemIdentityPolicyDefinitionResourceId: sessionHostSystemAssignedIdentityPolicyDefinition.outputs.policyDefinitionResourceId
    dataCollectionRuleResourceId: monitoringConfigurationIsValid ? dataCollectionRuleResourceId : dataCollectionRuleResourceId
    dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
    assignSystemIdentityPolicy: false
    createRemediation: false
    ownerId: policyOwnerId
  }
  dependsOn: [
    sessionHostCreationSettingsPolicyAssignment
  ]
}

module guestAttestationPolicyAssignment '../../shared/modules/orchestration/sessionHostPolicy/guestAttestation.bicep' = if (integrityMonitoring) {
  params: {
    location: location
    targetResourceGroupName: sessionHostResourceGroupName
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyIdentityPrincipalId: policyIdentity.outputs.principalId
    createRemediation: false
    ownerId: policyOwnerId
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
  ]
}

module sessionHostVmApplicationPolicyAssignment '../../shared/modules/orchestration/sessionHostPolicy/vmApplications.bicep' = if (!empty(sessionHostVmApplications)) {
  params: {
    location: location
    targetResourceGroupName: sessionHostResourceGroupName
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyIdentityPrincipalId: policyIdentity.outputs.principalId
    vmApplications: vmApplicationConfigurationIsValid ? sessionHostVmApplications : []
    createRemediation: false
    manageVirtualMachineContributorRole: false
    ownerId: policyOwnerId
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
  ]
}

module sessionHostConfigurationPolicyAssignment '../../shared/modules/orchestration/sessionHostPolicy/modules/policyAssignment.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-config'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: sessionHostConfigurationPolicyDefinition.outputs.policyDefinitionResourceId
    displayName: 'Configure automated AVD session hosts'
    description: 'Configures the time zone, enables time zone redirection, optionally configures FSLogix, and expands the OS partition.'
    parameters: {
      effect: {
        value: 'DeployIfNotExists'
      }
      configureFSLogix: {
        value: configureFSLogix
      }
      timeZone: {
        value: virtualMachinesTimeZone
      }
      runCommandName: {
        value: 'ConfigureSessionHost'
      }
      identitySolution: {
        value: fslogixConfiguration.identitySolution
      }
      fslogixStorageService: {
        value: fslogixConfiguration.storageService
      }
      fslogixContainerType: {
        value: fslogixConfiguration.containerType
      }
      fslogixFileShareNames: {
        value: fslogixConfiguration.fileShareNames
      }
      fslogixLocalStorageAccountResourceIds: {
        value: fslogixConfiguration.localStorageAccountResourceIds
      }
      fslogixRemoteStorageAccountResourceIds: {
        value: fslogixConfiguration.remoteStorageAccountResourceIds
      }
      fslogixLocalNetAppServerFqdns: {
        value: fslogixConfiguration.localNetAppServerFqdns
      }
      fslogixRemoteNetAppServerFqdns: {
        value: fslogixConfiguration.remoteNetAppServerFqdns
      }
      fslogixOSSGroups: {
        value: fslogixConfiguration.objectSpecificSettingsGroups
      }
      profileSizeInMBs: {
        value: fslogixConfiguration.profileSizeInMBs
      }
    }
    nonComplianceMessage: 'The session host must have successfully completed the FederalAVD session host configuration.'
    ownerId: policyOwnerId
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
  ]
}

module privateCustomizationPolicyAssignment '../../shared/modules/orchestration/sessionHostPolicy/modules/policyAssignment.bicep' = if (!empty(sessionHostCustomizations)) {
    scope: resourceGroup(sessionHostResourceGroupName)
    params: {
      name: 'avd-sh-customize'
      location: location
      policyIdentityResourceId: policyIdentity.outputs.resourceId
      policyDefinitionResourceId: privateCustomizationPolicyDefinition!.outputs.policyDefinitionResourceId
      displayName: 'Run ordered private customizations on automated AVD session hosts'
      description: 'Preserves existing VM identities, attaches the artifact identity, and runs private customizations in the supplied order.'
      parameters: {
        effect: {
          value: 'DeployIfNotExists'
        }
        customizations: {
          value: [
            for customization in sessionHostCustomizations: {
              name: replace(customization.name, ' ', '-')
              artifactUri: startsWith(customization.blobNameOrUri, 'https://')
                ? customization.blobNameOrUri
                : '${normalizedArtifactsContainerUri}/${sessionHostCustomizationConfigurationIsValid ? customization.blobNameOrUri : customization.blobNameOrUri}'
              arguments: customization.?arguments ?? ''
            }
          ]
        }
        finalRunCommandName: {
          value: finalSessionHostCustomizationName
        }
        userAssignedIdentityResourceId: {
          value: artifactsUserAssignedIdentityResourceId
        }
      }
      nonComplianceMessage: 'The session host must have successfully completed the ordered private customization sequence.'
      ownerId: policyOwnerId
    }
    dependsOn: [
      policyIdentityVirtualMachineContributor
      policyIdentityArtifactManagedIdentityOperator
    ]
}

output diskEncryptionSetPolicyAssignmentResourceId string = !empty(diskEncryptionSetResourceId)
  ? sessionHostCreationSettingsPolicyAssignment.outputs.resourceId
  : ''
output diskEncryptionSetResourceId string = diskEncryptionSetResourceId
output acceleratedNetworkingPolicyAssignmentResourceId string = sessionHostCreationSettingsPolicyAssignment.outputs.resourceId
output dataCollectionEndpointPolicyAssignmentResourceId string = enableMonitoring && !empty(dataCollectionEndpointResourceId)
  ? monitoringPolicyAssignment!.outputs.monitoringPolicyAssignmentResourceId
  : ''
output sessionHostConfigurationPolicyAssignmentResourceId string = sessionHostConfigurationPolicyAssignment.outputs.resourceId
output guestAttestationPolicyAssignmentResourceId string = integrityMonitoring
  ? guestAttestationPolicyAssignment!.outputs.policyAssignmentResourceId
  : ''
output managedDiskNetworkAccessPolicyAssignmentResourceId string = disableManagedDiskPublicNetworkAccess
  ? sessionHostCreationSettingsPolicyAssignment.outputs.resourceId
  : ''
output monitoringPolicyAssignmentResourceId string = enableMonitoring ? monitoringPolicyAssignment!.outputs.monitoringPolicyAssignmentResourceId : ''
output dataCollectionRulePolicyAssignmentResourceId string = enableMonitoring ? monitoringPolicyAssignment!.outputs.monitoringPolicyAssignmentResourceId : ''
output sessionHostIdentityPolicyAssignmentResourceId string = sessionHostCreationSettingsPolicyAssignment.outputs.resourceId
output policyIdentityResourceId string = policyIdentity.outputs.resourceId
output resourceOwnershipTagPolicyAssignmentResourceId string = !empty(hostPoolResourceId)
  ? resourceOwnershipTagPolicyAssignment!.outputs.resourceId
  : ''
output sessionHostCustomizationPolicyAssignmentResourceIds array = !empty(sessionHostCustomizations)
  ? [privateCustomizationPolicyAssignment!.outputs.resourceId]
  : []
output sessionHostVmApplicationPolicyAssignmentResourceId string = !empty(sessionHostVmApplications)
  ? sessionHostVmApplicationPolicyAssignment!.outputs.policyAssignmentResourceId
  : ''
output sessionHostComputePolicyAssignmentResourceId string = sessionHostCreationSettingsPolicyAssignment.outputs.resourceId
