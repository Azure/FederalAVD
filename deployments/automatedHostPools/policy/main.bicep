targetScope = 'subscription'

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

type sessionHostCustomizationType = {
  @description('Unique Run Command name for the customization.')
  name: string
  @description('Artifact blob path relative to artifactsContainerUri, or a full HTTPS URI.')
  blobNameOrUri: string
  @description('Optional. Arguments passed to the customization artifact.')
  arguments: string?
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

@description('Optional. Create the disk encryption key and Disk Encryption Set in this deployment.')
param deployDiskEncryptionSet bool = false

@description('Optional. Resource ID of an existing Disk Encryption Set for session host OS disks. Do not set when deployDiskEncryptionSet is true.')
@metadata({
  strongType: 'Microsoft.Compute/diskEncryptionSets'
})
param diskEncryptionSetResourceId string = ''

@description('Conditional. Resource ID of the existing Key Vault where the disk encryption key is created. Required when deployDiskEncryptionSet is true.')
@metadata({
  strongType: 'Microsoft.KeyVault/vaults'
})
param encryptionKeyVaultResourceId string = ''

@allowed([
  'CustomerManaged'
  'CustomerManagedHSM'
  'PlatformManagedAndCustomerManaged'
  'PlatformManagedAndCustomerManagedHSM'
])
@description('Optional. Customer-managed encryption mode used when creating the Disk Encryption Set.')
param keyManagementDisks string = 'CustomerManagedHSM'

@description('Optional. Name of the Key Vault key created for session host disk encryption.')
param diskEncryptionKeyName string = 'key-avd-session-host-disk'

@description('Optional. Name of the Disk Encryption Set created in the session-host resource group.')
param diskEncryptionSetName string = 'des-avd-session-host'

@minValue(7)
@description('Optional. Disk encryption key expiration period in days. The key rotates seven days before expiration.')
param keyExpirationInDays int = 180

@description('Optional. Deploy Azure Monitor Agent and associate automated session hosts with the selected Data Collection Rule.')
param enableMonitoring bool = true

@description('Conditional. Resource ID of the Data Collection Rule associated with automated session hosts. Required when enableMonitoring is true.')
@metadata({
  strongType: 'Microsoft.Insights/dataCollectionRules'
})
param dataCollectionRuleResourceId string = ''

@description('Optional. Resource ID of the Data Collection Endpoint associated with automated session hosts. When supplied, a separate built-in policy assignment creates the DCE association.')
@metadata({
  strongType: 'Microsoft.Insights/dataCollectionEndpoints'
})
param dataCollectionEndpointResourceId string = ''

@description('Optional. Restrict the built-in Azure Monitor Agent policies to Microsoft-supported Windows images.')
param scopeMonitoringToSupportedImages bool = true

@description('Optional. Additional supported custom image resource IDs evaluated by the Azure Monitor Agent policies.')
param additionalWindowsImageResourceIds array = []

@description('Optional. Deploy Guest Attestation to Trusted Launch and Confidential VM session hosts for integrity monitoring.')
param integrityMonitoring bool = true

@description('Optional. Encrypt temporary disks, ephemeral OS disks, and disk caches at the physical host.')
param encryptionAtHost bool = true

@minValue(0)
@description('Optional. OS disk size in GB. Set to zero to preserve the image default.')
param diskSizeGB int = 0

@description('Optional. Enable accelerated networking on session host network interfaces. The selected VM size must support accelerated networking.')
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
param sessionHostCustomizations sessionHostCustomizationType[] = []

@description('Optional. Tags applied to resources created by this policy stage.')
param tags object = {}

var virtualMachineContributorRoleDefinitionId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
var tagContributorRoleDefinitionId = '4a9ae827-6dc8-4573-8ac7-8239d42aa03f'
var managedIdentityOperatorRoleDefinitionId = 'f1a07417-d97a-45cb-824c-7a7467783830'
var monitoringPolicyRoleDefinitionIds = [
  '749f88d5-cbae-40b8-bcfc-e573ddc772fa' // Monitoring Contributor
  '92aaf0da-9dab-42b6-94a3-d43ce8d16293' // Log Analytics Contributor
]
var windowsAmaSystemAssignedIdentityInitiativeResourceId = tenantResourceId(
  'Microsoft.Authorization/policySetDefinitions',
  '9575b8b7-78ab-4281-b53b-d3c1ace2260b'
)
var windowsDcrDceAssociationPolicyResourceId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  '244efd75-0d92-453c-b9a3-7d73ca36ed52'
)
var inheritResourceGroupTagPolicyResourceId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  'cd3aa116-8754-49c9-a813-ad46512ece54'
)
var monitoringConfigurationIsValid = !enableMonitoring || !empty(dataCollectionRuleResourceId)
  ? true
  : bool('dataCollectionRuleResourceId is required when enableMonitoring is true.')
var relativeSessionHostCustomizations = filter(sessionHostCustomizations, customization => !startsWith(customization.blobNameOrUri, 'https://'))
var sessionHostCustomizationConfigurationIsValid = empty(sessionHostCustomizations) || (!empty(artifactsUserAssignedIdentityResourceId) && (empty(relativeSessionHostCustomizations) || !empty(artifactsContainerUri)))
  ? true
  : bool('artifactsUserAssignedIdentityResourceId is required for sessionHostCustomizations, and artifactsContainerUri is required when any blobNameOrUri is relative.')
var normalizedArtifactsContainerUri = endsWith(artifactsContainerUri, '/')
  ? take(artifactsContainerUri, max(length(artifactsContainerUri) - 1, 0))
  : artifactsContainerUri
var finalSessionHostCustomizationName = !empty(sessionHostCustomizations)
  ? replace(last(sessionHostCustomizations)!.name, ' ', '-')
  : 'PrivateCustomization-Final'
var diskEncryptionSetConfigurationIsValid = !deployDiskEncryptionSet || (empty(diskEncryptionSetResourceId) && !empty(encryptionKeyVaultResourceId))
  ? true
  : bool('When deployDiskEncryptionSet is true, encryptionKeyVaultResourceId is required and diskEncryptionSetResourceId must be empty.')
var effectiveDiskEncryptionSetResourceId = deployDiskEncryptionSet
  ? diskCmk!.outputs.diskEncryptionSetResourceId
  : diskEncryptionSetResourceId
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

module diskCmk '../../shared/modules/orchestration/customerManagedKeys/diskCmk.bicep' = if (deployDiskEncryptionSet) {
  params: {
    resourceGroupName: sessionHostResourceGroupName
    keyVaultResourceId: diskEncryptionSetConfigurationIsValid ? encryptionKeyVaultResourceId : encryptionKeyVaultResourceId
    keyManagementType: keyManagementDisks
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    parentResourceId: hostPoolResourceId
    deploymentSuffix: substring(uniqueString(sessionHostResourceGroupName, diskEncryptionSetName), 0, 8)
    keyName: diskEncryptionKeyName
    diskEncryptionSetName: diskEncryptionSetName
  }
}

module diskEncryptionSetPolicyDefinition 'modules/policy/bicep/virtualMachine-diskEncryptionSet.policyDefinition.bicep' = if (deployDiskEncryptionSet || !empty(diskEncryptionSetResourceId)) {
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

module managedDiskNetworkAccessPolicyDefinition 'modules/policy/bicep/managedDiskNetworkAccess.policyDefinition.bicep' = if (disableManagedDiskPublicNetworkAccess) {
  params: {}
}

module sessionHostComputePolicyDefinition 'modules/policy/bicep/sessionHostCompute.policyDefinition.bicep' = {
  params: {}
}

module sessionHostSystemAssignedIdentityPolicyDefinition 'modules/policy/bicep/sessionHostSystemAssignedIdentity.policyDefinition.bicep' = {
  params: {}
}

module acceleratedNetworkingPolicyDefinition 'modules/policy/bicep/networkInterfaceAcceleratedNetworking.policyDefinition.bicep' = {
  params: {}
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

module policyIdentityNetworkContributor '../../shared/modules/resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
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
      assignmentDescription: 'Allows the built-in Azure Monitor Agent policies to remediate automated AVD session hosts.'
    }
  }
]

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

module diskEncryptionSetPolicyAssignment 'modules/policyAssignment.bicep' = if (deployDiskEncryptionSet || !empty(diskEncryptionSetResourceId)) {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-des'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: diskEncryptionSetPolicyDefinition!.outputs.policyDefinitionResourceId
    displayName: 'Configure automated AVD session host OS disks with a Disk Encryption Set'
    description: 'Assigns the created or selected Disk Encryption Set to Windows session host OS disks during VM creation or update.'
    parameters: {
      diskEncryptionSetResourceId: {
        value: effectiveDiskEncryptionSetResourceId
      }
      effect: {
        value: 'Modify'
      }
    }
    nonComplianceMessage: 'The session host OS disk must use the Disk Encryption Set selected for this host pool.'
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
  ]
}

module sessionHostComputePolicyAssignment 'modules/policyAssignment.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-compute'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: sessionHostComputePolicyDefinition.outputs.policyDefinitionResourceId
    displayName: 'Configure automated AVD session host compute security settings'
    description: 'Enforces encryption at host and the selected OS disk size during VM creation or update.'
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
    }
    nonComplianceMessage: 'Session host virtual machines must use the selected encryption-at-host and OS disk settings.'
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
  ]
}

module acceleratedNetworkingPolicyAssignment 'modules/policyAssignment.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-accel-net'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: acceleratedNetworkingPolicyDefinition.outputs.policyDefinitionResourceId
    displayName: 'Configure accelerated networking on automated AVD session hosts'
    description: 'Enforces the selected accelerated-networking setting on network interfaces in the dedicated session host resource group.'
    parameters: {
      effect: {
        value: 'Modify'
      }
      enableAcceleratedNetworking: {
        value: enableAcceleratedNetworking
      }
    }
    nonComplianceMessage: 'Session host network interfaces must use the selected accelerated-networking setting.'
  }
  dependsOn: [
    policyIdentityNetworkContributor
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

module sessionHostIdentityPolicyAssignment 'modules/policyAssignment.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-monitor-id'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: sessionHostSystemAssignedIdentityPolicyDefinition.outputs.policyDefinitionResourceId
    displayName: 'Configure system-assigned identity on automated AVD session hosts'
    description: 'Enables system-assigned managed identity on every automated AVD session host while preserving existing user-assigned identities.'
    parameters: {
      effect: {
        value: 'Modify'
      }
    }
    nonComplianceMessage: 'The session host must have a system-assigned managed identity.'
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
  ]
}

module monitoringPolicyAssignment 'modules/policyAssignment.bicep' = if (enableMonitoring) {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-monitor'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: windowsAmaSystemAssignedIdentityInitiativeResourceId
    displayName: 'Deploy Azure Monitor Agent and DCR association to automated AVD session hosts'
    description: 'Uses the Microsoft built-in initiative to deploy Azure Monitor Agent with system-assigned identity authentication and associate the selected Data Collection Rule.'
    parameters: {
      effect: {
        value: 'DeployIfNotExists'
      }
      scopeToSupportedImages: {
        value: scopeMonitoringToSupportedImages
      }
      listOfWindowsImageIdToInclude: {
        value: additionalWindowsImageResourceIds
      }
      DcrResourceId: {
        value: monitoringConfigurationIsValid ? dataCollectionRuleResourceId : dataCollectionRuleResourceId
      }
    }
    nonComplianceMessage: 'The session host must run Azure Monitor Agent using system-assigned identity and be associated with the selected Data Collection Rule.'
  }
  dependsOn: [
    sessionHostIdentityPolicyAssignment
    monitoringPolicyRoleAssignments
  ]
}

module dataCollectionEndpointPolicyAssignment 'modules/policyAssignment.bicep' = if (enableMonitoring && !empty(dataCollectionEndpointResourceId)) {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-dce'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: windowsDcrDceAssociationPolicyResourceId
    displayName: 'Associate automated AVD session hosts with a Data Collection Endpoint'
    description: 'Uses the Microsoft built-in DCR or DCE association policy in Data Collection Endpoint mode.'
    parameters: {
      effect: {
        value: 'DeployIfNotExists'
      }
      scopeToSupportedImages: {
        value: scopeMonitoringToSupportedImages
      }
      listOfWindowsImageIdToInclude: {
        value: additionalWindowsImageResourceIds
      }
      dcrResourceId: {
        value: dataCollectionEndpointResourceId
      }
      resourceType: {
        value: 'Microsoft.Insights/dataCollectionEndpoints'
      }
    }
    nonComplianceMessage: 'The session host must be associated with the selected Data Collection Endpoint.'
  }
  dependsOn: [
    monitoringPolicyRoleAssignments
  ]
}

module managedDiskNetworkAccessPolicyAssignment 'modules/policyAssignment.bicep' = if (disableManagedDiskPublicNetworkAccess) {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-disk-net'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: managedDiskNetworkAccessPolicyDefinition!.outputs.policyDefinitionResourceId
    displayName: 'Disable public network access on automated AVD session host managed disks'
    description: 'Disables public network access and denies all network export access on managed disks.'
    parameters: {
      effect: {
        value: 'Modify'
      }
    }
    nonComplianceMessage: 'Session host managed disks must disable public network access and deny all network export access.'
  }
  dependsOn: [
    policyIdentityDiskPoolOperator
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

output diskEncryptionSetPolicyAssignmentResourceId string = deployDiskEncryptionSet || !empty(diskEncryptionSetResourceId)
  ? diskEncryptionSetPolicyAssignment!.outputs.resourceId
  : ''
output diskEncryptionSetResourceId string = deployDiskEncryptionSet || !empty(diskEncryptionSetResourceId)
  ? effectiveDiskEncryptionSetResourceId
  : ''
output acceleratedNetworkingPolicyAssignmentResourceId string = acceleratedNetworkingPolicyAssignment.outputs.resourceId
output dataCollectionEndpointPolicyAssignmentResourceId string = enableMonitoring && !empty(dataCollectionEndpointResourceId)
  ? dataCollectionEndpointPolicyAssignment!.outputs.resourceId
  : ''
output sessionHostConfigurationPolicyAssignmentResourceId string = sessionHostConfigurationPolicyAssignment.outputs.resourceId
output guestAttestationPolicyAssignmentResourceId string = integrityMonitoring
  ? guestAttestationPolicyAssignment!.outputs.resourceId
  : ''
output managedDiskNetworkAccessPolicyAssignmentResourceId string = disableManagedDiskPublicNetworkAccess
  ? managedDiskNetworkAccessPolicyAssignment!.outputs.resourceId
  : ''
output monitoringPolicyAssignmentResourceId string = enableMonitoring ? monitoringPolicyAssignment!.outputs.resourceId : ''
output dataCollectionRulePolicyAssignmentResourceId string = enableMonitoring ? monitoringPolicyAssignment!.outputs.resourceId : ''
output sessionHostIdentityPolicyAssignmentResourceId string = sessionHostIdentityPolicyAssignment.outputs.resourceId
output policyIdentityResourceId string = policyIdentity.outputs.resourceId
output resourceOwnershipTagPolicyAssignmentResourceId string = !empty(hostPoolResourceId)
  ? resourceOwnershipTagPolicyAssignment!.outputs.resourceId
  : ''
output sessionHostCustomizationPolicyAssignmentResourceIds array = !empty(sessionHostCustomizations)
  ? [privateCustomizationPolicyAssignment!.outputs.resourceId]
  : []
output sessionHostComputePolicyAssignmentResourceId string = sessionHostComputePolicyAssignment.outputs.resourceId
