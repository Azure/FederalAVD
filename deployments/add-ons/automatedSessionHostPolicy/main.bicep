targetScope = 'subscription'

type fslogixConfigurationType = {
  configurationVersion: string
  identitySolution: 'ActiveDirectoryDomainServices' | 'EntraDomainServices' | 'EntraKerberos-CloudOnly' | 'EntraKerberos-Hybrid' | 'EntraId'
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

type privateCustomizationType = {
  @description('Unique Run Command name for the customization.')
  name: string
  @description('Artifact blob path relative to artifactsContainerUri.')
  blobName: string
  @description('Arguments passed to the customization artifact.')
  arguments: string
  @description('Version marker used by the policy compliance check.')
  configurationVersion: string
}

@description('Required. Azure region for the policy assignment managed identity.')
param location string

@description('Required. Resource group containing the automated session host virtual machines.')
param sessionHostResourceGroupName string

@description('Required. Resource group containing the policy assignment managed identity.')
param policyResourceGroupName string

@description('Optional. Create the policy resource group when it does not already exist.')
param createPolicyResourceGroup bool = false

@description('Optional. Name of the user-assigned identity used by Azure Policy remediation.')
param policyIdentityName string = 'id-avd-session-host-policy'

@description('Optional. Name of the user-assigned identity used by Azure Monitor Agent on session hosts.')
param monitoringIdentityName string = 'id-avd-session-host-monitoring'

@description('Required. Resource ID of the existing Disk Encryption Set for session host OS disks.')
@metadata({
  strongType: 'Microsoft.Compute/diskEncryptionSets'
})
param diskEncryptionSetResourceId string

@description('Required. Resource ID of the Data Collection Rule associated with automated session hosts.')
@metadata({
  strongType: 'Microsoft.Insights/dataCollectionRules'
})
param dataCollectionRuleResourceId string

@description('Optional. Resource ID of the Data Collection Endpoint associated with automated session hosts. When supplied, a separate built-in policy assignment creates the DCE association.')
@metadata({
  strongType: 'Microsoft.Insights/dataCollectionEndpoints'
})
param dataCollectionEndpointResourceId string = ''

@description('Optional. Restrict the built-in Azure Monitor Agent initiative to Microsoft-supported Windows images.')
param scopeMonitoringToSupportedImages bool = true

@description('Optional. Additional supported custom image resource IDs evaluated by the Azure Monitor Agent initiative.')
param additionalWindowsImageResourceIds array = []

@description('Required. Identity-based FSLogix configuration applied to automated session hosts.')
param fslogixConfiguration fslogixConfigurationType

@description('Optional. HTTPS URI of the private Azure Blob container holding session host customization artifacts.')
param artifactsContainerUri string = ''

@description('Optional. Resource ID of the user-assigned identity with read access to the private artifact container.')
param artifactsUserAssignedIdentityResourceId string = ''

@description('Optional. Independent, idempotent, versioned private customizations applied to automated session hosts. Execution order is not guaranteed.')
param privateCustomizations privateCustomizationType[] = []

@description('Optional. Tags applied to resources created by this add-on.')
param tags object = {}

var virtualMachineContributorRoleDefinitionId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
var storageAccountKeyOperatorServiceRoleDefinitionId = '81a9662b-bebf-436f-a333-f67b29880f12'
var monitoringPolicyRoleDefinitionIds = [
  'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor
  '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9' // User Access Administrator
  '749f88d5-cbae-40b8-bcfc-e573ddc772fa' // Monitoring Contributor
  '92aaf0da-9dab-42b6-94a3-d43ce8d16293' // Log Analytics Contributor
]
var windowsAmaDcrInitiativeResourceId = tenantResourceId(
  'Microsoft.Authorization/policySetDefinitions',
  '0d1b56c6-6d1f-4a5d-8695-b15efbea6b49'
)
var windowsDcrDceAssociationPolicyResourceId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  'eab1f514-22e3-42e3-9a1f-e1dc9199355c'
)
var fslogixStorageAccountResourceIds = concat(
  fslogixConfiguration.localStorageAccountResourceIds,
  fslogixConfiguration.remoteStorageAccountResourceIds
)
var privateCustomizationConfigurationIsValid = empty(privateCustomizations) || (!empty(artifactsContainerUri) && !empty(artifactsUserAssignedIdentityResourceId))
  ? true
  : bool('artifactsContainerUri and artifactsUserAssignedIdentityResourceId are required when privateCustomizations is not empty.')
var normalizedArtifactsContainerUri = endsWith(artifactsContainerUri, '/')
  ? take(artifactsContainerUri, max(length(artifactsContainerUri) - 1, 0))
  : artifactsContainerUri

resource policyResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = if (createPolicyResourceGroup) {
  name: policyResourceGroupName
  location: location
  tags: tags
}

module policyIdentity '../../shared/modules/managedIdentity/userAssignedIdentities/deploy.bicep' = {
  scope: resourceGroup(policyResourceGroupName)
  params: {
    name: policyIdentityName
    location: location
    tags: tags
  }
  dependsOn: [
    policyResourceGroup
  ]
}

module monitoringIdentity '../../shared/modules/managedIdentity/userAssignedIdentities/deploy.bicep' = {
  scope: resourceGroup(policyResourceGroupName)
  params: {
    name: monitoringIdentityName
    location: location
    tags: tags
  }
  dependsOn: [
    policyResourceGroup
  ]
}

module diskEncryptionSetPolicyDefinition '../../../policy/bicep/virtualMachine-diskEncryptionSet.policyDefinition.bicep' = {
  params: {}
}

module fslogixPolicyDefinition '../../../policy/bicep/configureFSLogix.policyDefinition.bicep' = {
  params: {}
}

module privateCustomizationPolicyDefinition '../../../policy/bicep/privateCustomization.policyDefinition.bicep' = {
  params: {}
}

module policyIdentityVirtualMachineContributor '../../shared/modules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    roleDefinitionId: virtualMachineContributorRoleDefinitionId
    principalId: policyIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Policy to configure automated AVD session host virtual machines.'
  }
}

module monitoringPolicyRoleAssignments '../../shared/modules/authorization/roleAssignments/resourceGroup/deploy.bicep' = [
  for roleDefinitionId in monitoringPolicyRoleDefinitionIds: {
    scope: resourceGroup(sessionHostResourceGroupName)
    params: {
      roleDefinitionId: roleDefinitionId
      principalId: policyIdentity.outputs.principalId
      principalType: 'ServicePrincipal'
      assignmentDescription: 'Allows the built-in Azure Monitor Agent initiative to remediate automated AVD session hosts.'
    }
  }
]

module fslogixStorageKeyRoleAssignments '../../shared/modules/storage/storageAccounts/roleAssignment.bicep' = [
  for (storageAccountResourceId, i) in fslogixStorageAccountResourceIds: if (fslogixConfiguration.identitySolution == 'EntraId') {
    scope: resourceGroup(split(storageAccountResourceId, '/')[2], split(storageAccountResourceId, '/')[4])
    params: {
      storageAccountName: last(split(storageAccountResourceId, '/'))!
      assignments: [
        {
          roleDefinitionId: storageAccountKeyOperatorServiceRoleDefinitionId
          principalId: policyIdentity.outputs.principalId
          principalType: 'ServicePrincipal'
          description: 'Allows Azure Policy to retrieve the FSLogix storage account key for Entra ID session hosts.'
        }
      ]
    }
  }
]

module diskEncryptionSetPolicyAssignment 'modules/policyAssignment.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-des'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: diskEncryptionSetPolicyDefinition.outputs.policyDefinitionResourceId
    displayName: 'Configure automated AVD session host OS disks with a Disk Encryption Set'
    description: 'Assigns the precreated Disk Encryption Set to Windows session host OS disks during VM creation or update.'
    parameters: {
      diskEncryptionSetResourceId: {
        value: diskEncryptionSetResourceId
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

module monitoringPolicyAssignment 'modules/policyAssignment.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-monitor'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: windowsAmaDcrInitiativeResourceId
    displayName: 'Deploy Azure Monitor Agent and associate automated AVD session hosts with a DCR'
    description: 'Uses the Microsoft built-in Windows AMA initiative with a dedicated VM monitoring identity.'
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
        value: dataCollectionRuleResourceId
      }
      bringYourOwnUserAssignedManagedIdentity: {
        value: true
      }
      userAssignedManagedIdentityName: {
        value: monitoringIdentity.outputs.name
      }
      userAssignedManagedIdentityResourceGroup: {
        value: policyResourceGroupName
      }
      builtInIdentityResourceGroupLocation: {
        value: location
      }
    }
    nonComplianceMessage: 'The session host must run Azure Monitor Agent and be associated with the selected Data Collection Rule.'
  }
  dependsOn: [
    monitoringPolicyRoleAssignments
  ]
}

module dataCollectionEndpointPolicyAssignment 'modules/policyAssignment.bicep' = if (!empty(dataCollectionEndpointResourceId)) {
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

module fslogixPolicyAssignment 'modules/policyAssignment.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    name: 'avd-sh-fslogix'
    location: location
    policyIdentityResourceId: policyIdentity.outputs.resourceId
    policyDefinitionResourceId: fslogixPolicyDefinition.outputs.policyDefinitionResourceId
    displayName: 'Configure FSLogix on automated AVD session hosts'
    description: 'Deploys a versioned Run Command that configures identity-based FSLogix storage locations.'
    parameters: {
      effect: {
        value: 'DeployIfNotExists'
      }
      configurationVersion: {
        value: fslogixConfiguration.configurationVersion
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
      runCommandName: {
        value: 'ConfigureFSLogix'
      }
    }
    nonComplianceMessage: 'The session host must have the selected version of the FederalAVD FSLogix configuration.'
  }
  dependsOn: [
    policyIdentityVirtualMachineContributor
    fslogixStorageKeyRoleAssignments
  ]
}

module privateCustomizationPolicyAssignments 'modules/policyAssignment.bicep' = [
  for (customization, i) in privateCustomizations: {
    scope: resourceGroup(sessionHostResourceGroupName)
    params: {
      name: 'avd-sh-cust-${substring(uniqueString(customization.name), 0, 8)}'
      location: location
      policyIdentityResourceId: policyIdentity.outputs.resourceId
      policyDefinitionResourceId: privateCustomizationPolicyDefinition.outputs.policyDefinitionResourceId
      displayName: 'Run private customization ${customization.name} on automated AVD session hosts'
      description: 'Preserves existing VM identities, attaches the artifact identity, and runs the selected private customization.'
      parameters: {
        effect: {
          value: 'DeployIfNotExists'
        }
        artifactUri: {
          value: '${normalizedArtifactsContainerUri}/${privateCustomizationConfigurationIsValid ? customization.blobName : customization.blobName}'
        }
        arguments: {
          value: customization.arguments
        }
        configurationVersion: {
          value: customization.configurationVersion
        }
        runCommandName: {
          value: replace(customization.name, ' ', '-')
        }
        userAssignedIdentityResourceId: {
          value: artifactsUserAssignedIdentityResourceId
        }
      }
      nonComplianceMessage: 'The session host must have version ${customization.configurationVersion} of private customization ${customization.name}.'
    }
    dependsOn: [
      policyIdentityVirtualMachineContributor
    ]
  }
]

output diskEncryptionSetPolicyAssignmentResourceId string = diskEncryptionSetPolicyAssignment.outputs.resourceId
output dataCollectionEndpointPolicyAssignmentResourceId string = !empty(dataCollectionEndpointResourceId)
  ? dataCollectionEndpointPolicyAssignment!.outputs.resourceId
  : ''
output fslogixPolicyAssignmentResourceId string = fslogixPolicyAssignment.outputs.resourceId
output monitoringIdentityResourceId string = monitoringIdentity.outputs.resourceId
output monitoringPolicyAssignmentResourceId string = monitoringPolicyAssignment.outputs.resourceId
output policyIdentityResourceId string = policyIdentity.outputs.resourceId
output privateCustomizationPolicyAssignmentResourceIds array = [
  for (customization, i) in privateCustomizations: privateCustomizationPolicyAssignments[i].outputs.resourceId
]