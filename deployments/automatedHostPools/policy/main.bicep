targetScope = 'subscription'

import { artifactCustomizationType } from '../../shared/modules/resourceModules/types/customizationTypes.bicep'
import { vmApplicationAssignmentType } from 'modules/policy/bicep/vmApplicationTypes.bicep'

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
var readerRoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var monitoringContributorRoleDefinitionId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
var monitoringPolicyRoleDefinitionIds = [
  monitoringContributorRoleDefinitionId
]
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
var resourceGroupTags = union(tags[?'Microsoft.Resources/resourceGroups'] ?? {}, parentResourceTags)
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

module diskEncryptionSetPolicyDefinition 'modules/policy/bicep/virtualMachine-diskEncryptionSet.policyDefinition.bicep' = {
  params: {}
}

module sessionHostConfigurationPolicyDefinition 'modules/policy/bicep/configureSessionHost.policyDefinition.bicep' = {
  params: {}
}

module privateCustomizationPolicyDefinition 'modules/policy/bicep/privateCustomization.policyDefinition.bicep' = if (!empty(sessionHostCustomizations)) {
  params: {}
}

module guestAttestationPolicyDefinition 'modules/policy/bicep/guestAttestation.policyDefinition.bicep' = if (integrityMonitoring) {
  params: {}
}

module managedDiskNetworkAccessPolicyDefinition 'modules/policy/bicep/managedDiskNetworkAccess.policyDefinition.bicep' = {
  params: {}
}

module sessionHostComputePolicyDefinition 'modules/policy/bicep/sessionHostCompute.policyDefinition.bicep' = {
  params: {}
}

module sessionHostSystemAssignedIdentityPolicyDefinition 'modules/policy/bicep/sessionHostSystemAssignedIdentity.policyDefinition.bicep' = {
  params: {}
}

module sessionHostVmApplicationPolicyDefinition 'modules/policy/bicep/sessionHostVmApplication.policyDefinition.bicep' = if (!empty(sessionHostVmApplications)) {
  params: {}
}

module azureMonitorAgentPolicyDefinition 'modules/policy/bicep/azureMonitorAgent.policyDefinition.bicep' = if (enableMonitoring) {
  params: {}
}

module monitoringAssociationPolicyDefinition 'modules/policy/bicep/monitoringAssociation.policyDefinition.bicep' = if (enableMonitoring) {
  params: {}
}

module sessionHostMonitoringPolicySetDefinition 'modules/policy/bicep/sessionHostMonitoring.policySetDefinition.bicep' = if (enableMonitoring) {
  params: {
    azureMonitorAgentPolicyDefinitionResourceId: azureMonitorAgentPolicyDefinition!.outputs.policyDefinitionResourceId
    monitoringAssociationPolicyDefinitionResourceId: monitoringAssociationPolicyDefinition!.outputs.policyDefinitionResourceId
  }
}

module acceleratedNetworkingPolicyDefinition 'modules/policy/bicep/networkInterfaceAcceleratedNetworking.policyDefinition.bicep' = {
  params: {}
}

module sessionHostCreationSettingsPolicySetDefinition 'modules/policy/bicep/sessionHostCreationSettings.policySetDefinition.bicep' = {
  params: {
    diskEncryptionSetPolicyDefinitionResourceId: diskEncryptionSetPolicyDefinition.outputs.policyDefinitionResourceId
    sessionHostComputePolicyDefinitionResourceId: sessionHostComputePolicyDefinition.outputs.policyDefinitionResourceId
    sessionHostSystemAssignedIdentityPolicyDefinitionResourceId: sessionHostSystemAssignedIdentityPolicyDefinition.outputs.policyDefinitionResourceId
    acceleratedNetworkingPolicyDefinitionResourceId: acceleratedNetworkingPolicyDefinition.outputs.policyDefinitionResourceId
    managedDiskNetworkAccessPolicyDefinitionResourceId: managedDiskNetworkAccessPolicyDefinition.outputs.policyDefinitionResourceId
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

module monitoringPolicyRoleAssignments '../../shared/modules/resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = [
  for roleDefinitionId in monitoringPolicyRoleDefinitionIds: if (enableMonitoring) {
    scope: resourceGroup(sessionHostResourceGroupName)
    params: {
      roleDefinitionId: roleDefinitionId
      principalId: policyIdentity.outputs.principalId
      principalType: 'ServicePrincipal'
      assignmentDescription: 'Allows Azure Policy to deploy monitoring resources on automated AVD session hosts.'
    }
  }
]

module policyIdentityDataCollectionRuleReader 'modules/dataCollectionRuleReader.bicep' = if (enableMonitoring) {
  scope: resourceGroup(
    split(dataCollectionRuleResourceId, '/')[2],
    split(dataCollectionRuleResourceId, '/')[4]
  )
  params: {
    dataCollectionRuleName: last(split(dataCollectionRuleResourceId, '/'))!
    principalId: policyIdentity.outputs.principalId
    readerRoleDefinitionId: readerRoleDefinitionId
  }
}

module policyIdentityDataCollectionEndpointContributor 'modules/dataCollectionEndpointContributor.bicep' = if (enableMonitoring && !empty(dataCollectionEndpointResourceId)) {
  scope: resourceGroup(
    split(dataCollectionEndpointResourceId, '/')[2],
    split(dataCollectionEndpointResourceId, '/')[4]
  )
  params: {
    dataCollectionEndpointName: last(split(dataCollectionEndpointResourceId, '/'))!
    principalId: policyIdentity.outputs.principalId
    monitoringContributorRoleDefinitionId: monitoringContributorRoleDefinitionId
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

module sessionHostCreationSettingsPolicyAssignment 'modules/policyAssignment.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-creation-settings'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: sessionHostCreationSettingsPolicySetDefinition.outputs.policySetDefinitionResourceId
    displayName: 'Configure AVD session host creation settings'
    description: 'Configures compute security, optional Disk Encryption Set, system-assigned identity, accelerated networking, and optional managed-disk network access during resource creation or update.'
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
    }
    nonComplianceMessage: 'Session host resources must use the selected creation-time compute, identity, networking, encryption, and managed-disk settings.'
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
    policyIdentityNetworkContributor
    policyIdentityDiskPoolOperator
  ]
}

module resourceOwnershipTagPolicyAssignment 'modules/policyAssignment.bicep' = if (!empty(hostPoolResourceId)) {
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
  }
  dependsOn: [
    policyIdentityTagContributor
    sessionHostResourceGroupTags
  ]
}

module monitoringPolicyAssignment 'modules/policyAssignment.bicep' = if (enableMonitoring) {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-monitor'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: sessionHostMonitoringPolicySetDefinition!.outputs.policySetDefinitionResourceId
    displayName: 'Deploy Azure Monitor Agent and DCR association to automated AVD session hosts'
    description: 'Deploys Azure Monitor Agent with system-assigned identity authentication and associates the selected Data Collection Rule and optional Data Collection Endpoint.'
    parameters: {
      effect: {
        value: 'DeployIfNotExists'
      }
      dataCollectionRuleResourceId: {
        value: monitoringConfigurationIsValid ? dataCollectionRuleResourceId : dataCollectionRuleResourceId
      }
      dataCollectionEndpointResourceId: {
        value: dataCollectionEndpointResourceId
      }
      dataCollectionEndpointEffect: {
        value: empty(dataCollectionEndpointResourceId) ? 'Disabled' : 'DeployIfNotExists'
      }
    }
    nonComplianceMessage: 'The session host must run Azure Monitor Agent using system-assigned identity and have the selected monitoring associations.'
  }
  dependsOn: [
    sessionHostCreationSettingsPolicyAssignment
    monitoringPolicyRoleAssignments
    policyIdentityDataCollectionRuleReader
    policyIdentityDataCollectionEndpointContributor
  ]
}

module guestAttestationPolicyAssignment 'modules/policyAssignment.bicep' = if (integrityMonitoring) {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-attest'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: guestAttestationPolicyDefinition!.outputs.policyDefinitionResourceId
    displayName: 'Deploy Guest Attestation on automated AVD session hosts'
    description: 'Deploys Guest Attestation to Trusted Launch and Confidential VM session hosts for boot integrity monitoring.'
    parameters: {
      effect: {
        value: 'DeployIfNotExists'
      }
    }
    nonComplianceMessage: 'Trusted Launch and Confidential VM session hosts must run the Guest Attestation extension.'
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
  ]
}

module sessionHostVmApplicationPolicyAssignment 'modules/policyAssignment.bicep' = if (!empty(sessionHostVmApplications)) {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-vm-applications'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: sessionHostVmApplicationPolicyDefinition!.outputs.policyDefinitionResourceId
    displayName: 'Configure VM Applications on automated AVD session hosts'
    description: 'Configures the selected ordered Azure Compute Gallery application versions as the authoritative VM Application list on every automated session host.'
    parameters: {
      effect: {
        value: 'Modify'
      }
      galleryApplications: {
        value: vmApplicationConfigurationIsValid ? sessionHostVmApplications : []
      }
    }
    nonComplianceMessage: 'The session host must use the selected ordered Azure Compute Gallery application versions.'
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
  ]
}

module sessionHostConfigurationPolicyAssignment 'modules/policyAssignment.bicep' = {
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
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
  ]
}

module privateCustomizationPolicyAssignment 'modules/policyAssignment.bicep' = if (!empty(sessionHostCustomizations)) {
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
  ? monitoringPolicyAssignment!.outputs.resourceId
  : ''
output sessionHostConfigurationPolicyAssignmentResourceId string = sessionHostConfigurationPolicyAssignment.outputs.resourceId
output guestAttestationPolicyAssignmentResourceId string = integrityMonitoring
  ? guestAttestationPolicyAssignment!.outputs.resourceId
  : ''
output managedDiskNetworkAccessPolicyAssignmentResourceId string = disableManagedDiskPublicNetworkAccess
  ? sessionHostCreationSettingsPolicyAssignment.outputs.resourceId
  : ''
output monitoringPolicyAssignmentResourceId string = enableMonitoring ? monitoringPolicyAssignment!.outputs.resourceId : ''
output dataCollectionRulePolicyAssignmentResourceId string = enableMonitoring ? monitoringPolicyAssignment!.outputs.resourceId : ''
output sessionHostIdentityPolicyAssignmentResourceId string = sessionHostCreationSettingsPolicyAssignment.outputs.resourceId
output policyIdentityResourceId string = policyIdentity.outputs.resourceId
output resourceOwnershipTagPolicyAssignmentResourceId string = !empty(hostPoolResourceId)
  ? resourceOwnershipTagPolicyAssignment!.outputs.resourceId
  : ''
output sessionHostCustomizationPolicyAssignmentResourceIds array = !empty(sessionHostCustomizations)
  ? [privateCustomizationPolicyAssignment!.outputs.resourceId]
  : []
output sessionHostVmApplicationPolicyAssignmentResourceId string = !empty(sessionHostVmApplications)
  ? sessionHostVmApplicationPolicyAssignment!.outputs.resourceId
  : ''
output sessionHostComputePolicyAssignmentResourceId string = sessionHostCreationSettingsPolicyAssignment.outputs.resourceId
