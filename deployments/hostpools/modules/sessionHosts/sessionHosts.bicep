targetScope = 'subscription'

param deploymentType string
param appGroupSecurityGroups array
param artifactsContainerUri string
param artifactsUserAssignedIdentityResourceId string
param availability string
param availabilitySetNameConv string
param availabilitySetsCount int
param availabilitySetsIndex int
param availabilityZones array
param avdInsightsDataCollectionRulesResourceId string
param azureBackupPrivateDnsZoneResourceId string
param azureBlobPrivateDnsZoneResourceId string
param azureQueuePrivateDnsZoneResourceId string
param confidentialVMOrchestratorObjectId string
param confidentialVMOSDiskEncryption bool
param customImageResourceId string
param dataCollectionEndpointResourceId string
param dedicatedHostGroupResourceId string
param dedicatedHostResourceId string
param deployDiskAccessPolicy bool
param deployDiskAccessResource bool
param deploymentUserAssignedIdentityClientId string
param deploymentVirtualMachineName string
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param diskEncryptionSetNames object
param diskAccessName string
param diskSizeGB int
param diskSku string
param divisionRemainderValue int
param domainName string
param enableAcceleratedNetworking bool
param enableIPv6 bool
param encryptionAtHost bool
param encryptionKeyName string
param encryptionKeyVaultResourceId string
param encryptionKeyVaultUri string
param existingDiskAccessResourceId string
param existingDiskEncryptionSetResourceId string
param existingRecoveryServicesVaultResourceId string
param fslogixFileShareNames array
param fslogixConfigureSessionHosts bool
param fslogixContainerType string
param fslogixLocalNetAppVolumeResourceIds array
param fslogixLocalStorageAccountResourceIds array
param fslogixOSSGroups array
param fslogixRemoteNetAppVolumeResourceIds array
param fslogixRemoteStorageAccountResourceIds array
param fslogixSizeInMBs int
param fslogixStorageService string
param hibernationEnabled bool
param hostPoolResourceId string
param identitySolution string
param imageOffer string
param imagePublisher string
param imageSku string
param integrityMonitoring bool
param intuneEnrollment bool
param keyExpirationInDays int
param keyManagementDisks string
param location string
param logAnalyticsWorkspaceResourceId string
param maxVMsPerDeployment int
param privateEndpoint bool
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param privateEndpointSubnetResourceId string
param enableMonitoring bool
param networkInterfaceNameConv string
param osDiskNameConv string
param ouPath string
param pooledHostPool bool
param recoveryServices bool
param recoveryServicesVaultName string
param resourceGroupDeployment string
param resourceGroupHosts string
param secureBootEnabled bool
param securityDataCollectionRulesResourceId string
param securityType string
param sessionHostBatchCount int
param sessionHostCustomizations array
param sessionHostRegistrationDSCUrl string
param sessionHostIndex int
param vmNameIndexLength int
param storageSuffix string
param subnetResourceId string
param tags object
param deploymentSuffix string
param timeZone string
param useAgentDownloadEndpoint bool
param virtualMachineNameConv string
param virtualMachineNamePrefix string
param virtualMachineSize string
@secure()
param virtualMachineAdminPassword string
@secure()
param virtualMachineAdminUserName string
param vTpmEnabled bool
param vmInsightsDataCollectionRulesResourceId string

var backupPolicyName = 'AvdPolicyVm'
var confidentialVMOSDiskEncryptionType = confidentialVMOSDiskEncryption ? 'DiskWithVMGuestState' : 'VMGuestStateOnly'

var backupPrivateDNSZoneResourceIds = [
  azureBackupPrivateDnsZoneResourceId
  azureBlobPrivateDnsZoneResourceId
  azureQueuePrivateDnsZoneResourceId
]

var dedicatedHostGroupName = !empty(dedicatedHostResourceId)
  ? split(dedicatedHostResourceId, '/')[8]
  : !empty(dedicatedHostGroupResourceId) ? last(split(dedicatedHostGroupResourceId, '/')) : ''
var dedicatedHostSub = !empty(dedicatedHostResourceId)
  ? split(dedicatedHostResourceId, '/')[2]
  : !empty(dedicatedHostGroupResourceId) ? split(dedicatedHostGroupResourceId, '/')[2] : ''
var dedicatedHostRG = !empty(dedicatedHostResourceId)
  ? split(dedicatedHostResourceId, '/')[4]
  : !empty(dedicatedHostGroupResourceId) ? split(dedicatedHostGroupResourceId, '/')[4] : ''

resource dedicatedHostGroup 'Microsoft.Compute/hostGroups@2024-11-01' existing = if (!empty(dedicatedHostGroupName)) {
  scope: resourceGroup(dedicatedHostSub, dedicatedHostRG)
  name: dedicatedHostGroupName
}

var nonEmptyBackupPrivateDNSZoneResourceIds = filter(backupPrivateDNSZoneResourceIds, zone => !empty(zone))

// Call on the hotspool
resource hostPoolGet 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' existing = if(deploymentType == 'SessionHostsOnly') {
  name: last(split(hostPoolResourceId, '/'))
  scope: resourceGroup(split(hostPoolResourceId, '/')[2], split(hostPoolResourceId, '/')[4])
}

// Required for EntraID login
module roleAssignment_VirtualMachineUserLogin '../../../sharedModules/resources/authorization/role-assignment/resource-group/main.bicep' = [
  for i in range(0, length(appGroupSecurityGroups)): if (deploymentType != 'SessionHostsOnly' && !contains(identitySolution, 'DomainServices')) {
    name: 'RA-Hosts-VMLoginUser-${i}-${deploymentSuffix}'
    scope: resourceGroup(resourceGroupHosts)
    params: {
      principalId: appGroupSecurityGroups[i]
      principalType: 'Group'
      roleDefinitionId: 'fb879df8-f326-4884-b1cf-06f3ad86be52' // Virtual Machine User Login
    }
  }
]

module hostPoolUpdate 'modules/hostPoolUpdate.bicep' = if(deploymentType == 'SessionHostsOnly') {
  name: 'HostPoolRegistrationTokenUpdate-${deploymentSuffix}'
  scope: resourceGroup(split(hostPoolResourceId, '/')[2], split(hostPoolResourceId, '/')[4])
  params: {
    hostPoolType: deploymentType == 'SessionHostsOnly' ? hostPoolGet!.properties.hostPoolType : ''
    loadBalancerType: deploymentType == 'SessionHostsOnly' ? hostPoolGet!.properties.loadBalancerType : ''
    location: deploymentType == 'SessionHostsOnly' ? hostPoolGet!.location : location
    name: deploymentType == 'SessionHostsOnly' ? hostPoolGet.name : ''
    preferredAppGroupType: deploymentType == 'SessionHostsOnly' ? hostPoolGet!.properties.preferredAppGroupType : ''
  } 
}

module diskAccessResource '../../../sharedModules/resources/compute/disk-access/main.bicep' = if (deploymentType != 'SessionHostsOnly' && deployDiskAccessResource) {
  scope: resourceGroup(resourceGroupHosts)
  name: 'DiskAccess-${deploymentSuffix}'
  params: {
    name: diskAccessName
    location: location
    privateEndpoints:[
      {
        customNetworkInterfaceName: replace(
          replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'disks'), 'RESOURCE', diskAccessName),
          'VNETID',
          '${split(privateEndpointSubnetResourceId, '/')[8]}'
        )
        name: replace(
          replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'disks'), 'RESOURCE', diskAccessName),
          'VNETID',
          '${split(privateEndpointSubnetResourceId, '/')[8]}'
        )
        privateDnsZoneGroup: empty(azureBlobPrivateDnsZoneResourceId) ? null : {
          privateDNSResourceIds: [
            azureBlobPrivateDnsZoneResourceId
          ]
        }
        service: 'disks'
        subnetResourceId: privateEndpointSubnetResourceId
        tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
      }
    ]
    tags: union({'cm-resource-parent': hostPoolResourceId}, tags[?'Microsoft.Compute/diskAccesses'] ?? {})
  }
}

module diskAccessPolicy 'modules/diskNetworkAccessPolicy.bicep' = if (deploymentType != 'SessionHostsOnly' && deployDiskAccessPolicy) {
  name: 'ManagedDisks-NetworkAccess-Policy-${deploymentSuffix}'
  params: {
    diskAccessId: deployDiskAccessResource ? diskAccessResource!.outputs.resourceId : ''
    location: location
    resourceGroupName: resourceGroupHosts
  }
}

module customerManagedKeys 'modules/customerManagedKeys.bicep' =  if (deploymentType != 'SessionHostsOnly' && keyManagementDisks != 'PlatformManaged') {
  name: 'Customer-Managed-Keys-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {    
    confidentialVMOrchestratorObjectId: confidentialVMOrchestratorObjectId
    confidentialVMOSDiskEncryption: confidentialVMOSDiskEncryption
    deploymentUserAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deploymentVirtualMachineName
    diskEncryptionSetNames: diskEncryptionSetNames
    hostPoolResourceId: hostPoolResourceId
    keyExpirationInDays: keyExpirationInDays
    keyManagementDisks: keyManagementDisks
    keyName: encryptionKeyName
    keyVaultResourceId: encryptionKeyVaultResourceId
    keyVaultUri: encryptionKeyVaultUri
    location: location
    deploymentResourceGroupName: resourceGroupDeployment
    tags: tags
    deploymentSuffix: deploymentSuffix
  }
}

resource artifactsUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = if (!empty(artifactsUserAssignedIdentityResourceId)) {
  scope: resourceGroup(split(artifactsUserAssignedIdentityResourceId, '/')[2], split(artifactsUserAssignedIdentityResourceId, '/')[4])
  name: last(split(artifactsUserAssignedIdentityResourceId, '/'))
}

module availabilitySets '../../../sharedModules/resources/compute/availability-set/main.bicep' = [for i in range(0, availabilitySetsCount): if (pooledHostPool && availability == 'AvailabilitySets') {
  name: '${replace(availabilitySetNameConv, '##', padLeft((i + availabilitySetsIndex) + 1, 2, '0'))}-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    name: replace(availabilitySetNameConv, '##', padLeft((i + availabilitySetsIndex) + 1, 2, '0'))
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
    proximityPlacementGroupResourceId: ''
    location: location
    skuName: 'Aligned'
    tags: union({'cm-resource-parent': hostPoolResourceId}, tags[?'Microsoft.Compute/availabilitySets'] ?? {})
  }
}]

module netAppVolumeFqdns 'modules/getNetAppVolumeSmbServerFqdns.bicep' = if(fslogixConfigureSessionHosts && (!empty(fslogixLocalNetAppVolumeResourceIds) || !empty(fslogixRemoteNetAppVolumeResourceIds))) {
  name: 'NetAppVolumeFqdns-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    localNetAppVolumeResourceIds: fslogixLocalNetAppVolumeResourceIds
    remoteNetAppVolumeResourceIds: fslogixRemoteNetAppVolumeResourceIds
    shareNames: fslogixFileShareNames
  }
}

@batchSize(5)
module virtualMachines 'modules/virtualMachines.bicep' = [for i in range(1, sessionHostBatchCount): {
  name: 'VirtualMachines-Batch-${i-1}-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    artifactsContainerUri: artifactsContainerUri
    artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
    artifactsUserAssignedIdentityClientId: empty(artifactsUserAssignedIdentityResourceId) ? '' : artifactsUAI!.properties.clientId
    availability: availability
    availabilityZones: availabilityZones
    availabilitySetNameConv: availabilitySetNameConv
    avdInsightsDataCollectionRulesResourceId: avdInsightsDataCollectionRulesResourceId
    confidentialVMOSDiskEncryptionType: confidentialVMOSDiskEncryptionType

    customImageResourceId: customImageResourceId
    dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
    dedicatedHostGroupResourceId: dedicatedHostGroupResourceId
    dedicatedHostGroupZones: !empty(dedicatedHostGroupName) ? dedicatedHostGroup!.zones : []
    dedicatedHostResourceId: dedicatedHostResourceId
    diskAccessId: deploymentType != 'SessionHostsOnly' ? deployDiskAccessResource ? diskAccessResource!.outputs.resourceId : '' : existingDiskAccessResourceId
    diskEncryptionSetResourceId: ( deploymentType != 'SessionHostsOnly' && keyManagementDisks != 'PlatformManaged' ) ? customerManagedKeys!.outputs.diskEncryptionSetResourceId : !empty(existingDiskEncryptionSetResourceId) ? existingDiskEncryptionSetResourceId : ''
    diskSizeGB: diskSizeGB
    diskSku: diskSku
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    domainName: domainName
    enableAcceleratedNetworking: enableAcceleratedNetworking
    enableIPv6: enableIPv6
    enableMonitoring: enableMonitoring
    encryptionAtHost: encryptionAtHost
    fslogixConfigureSessionHosts: fslogixConfigureSessionHosts
    fslogixContainerType: fslogixContainerType
    fslogixFileShareNames: fslogixFileShareNames
    fslogixOSSGroups: fslogixOSSGroups
    fslogixLocalNetAppServerFqdns: fslogixConfigureSessionHosts && !empty(fslogixLocalNetAppVolumeResourceIds) ? netAppVolumeFqdns!.outputs.localNetAppVolumeSmbServerFqdns : []
    fslogixLocalStorageAccountResourceIds: fslogixLocalStorageAccountResourceIds
    fslogixRemoteNetAppServerFqdns: fslogixConfigureSessionHosts && !empty(fslogixRemoteNetAppVolumeResourceIds) ? netAppVolumeFqdns!.outputs.remoteNetAppVolumeSmbServerFqdns : []
    fslogixRemoteStorageAccountResourceIds: fslogixRemoteStorageAccountResourceIds
    fslogixSizeInMBs: fslogixSizeInMBs    
    fslogixStorageService: fslogixStorageService
    hibernationEnabled: hibernationEnabled
    hostPoolResourceId: deploymentType != 'SessionHostsOnly' ? hostPoolResourceId : hostPoolUpdate!.outputs.resourceId
    identitySolution: identitySolution
    imageOffer: imageOffer
    imagePublisher: imagePublisher
    imageSku: imageSku
    integrityMonitoring: integrityMonitoring
    intuneEnrollment: intuneEnrollment
    location: location
    networkInterfaceNameConv: networkInterfaceNameConv
    osDiskNameConv: osDiskNameConv
    ouPath: ouPath
    sessionHostCustomizations: sessionHostCustomizations
    securityDataCollectionRulesResourceId: securityDataCollectionRulesResourceId
    secureBootEnabled: secureBootEnabled
    securityType: securityType
    sessionHostCount: i == sessionHostBatchCount && divisionRemainderValue > 0 ? divisionRemainderValue : maxVMsPerDeployment
    sessionHostIndex: i == 1 ? sessionHostIndex : ((i - 1) * maxVMsPerDeployment) + sessionHostIndex
    vmNameIndexLength: vmNameIndexLength
    sessionHostRegistrationDSCUrl: sessionHostRegistrationDSCUrl
    storageSuffix: storageSuffix
    subnetResourceId: subnetResourceId
    tags: tags
    deploymentSuffix: deploymentSuffix
    timeZone: timeZone
    useAgentDownloadEndpoint: useAgentDownloadEndpoint
    virtualMachineAdminPassword: virtualMachineAdminPassword
    virtualMachineAdminUserName: virtualMachineAdminUserName
    virtualMachineNameConv: virtualMachineNameConv
    virtualMachineNamePrefix: virtualMachineNamePrefix
    virtualMachineSize: virtualMachineSize
    vmInsightsDataCollectionRulesResourceId: vmInsightsDataCollectionRulesResourceId 
    vTpmEnabled: vTpmEnabled
  }
  dependsOn: [
    availabilitySets
  ]
}]

module recoveryServicesVault '../../../sharedModules/resources/recovery-services/vault/main.bicep' = if (deploymentType != 'SessionHostsOnly' && recoveryServices) {
  name: 'RecoveryServicesVault-VirtualMachines-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    location: location
    name: recoveryServicesVaultName
    backupPolicies: [
      {
        name: backupPolicyName
        properties: {
          backupManagementType: 'AzureIaasVM'
          instantRpRetentionRangeInDays: 2
          policyType: 'V2'
          retentionPolicy: {
            retentionPolicyType: 'LongTermRetentionPolicy'
            dailySchedule: {
              retentionDuration: {
                count: 30
                durationType: 'Days'
              }
              retentionTimes: [
                '23:00'
              ]
            }
          }
          schedulePolicy: {
            schedulePolicyType: 'SimpleSchedulePolicyV2'
            scheduleRunFrequency: 'Daily'
            dailySchedule: {
              scheduleRunTimes: [
                '23:00'
              ]
            }
          }     
          timeZone: timeZone
        }
      }
    ]
    privateEndpoints: privateEndpoint && !empty(privateEndpointSubnetResourceId) && !empty(azureBackupPrivateDnsZoneResourceId) && !empty(azureBlobPrivateDnsZoneResourceId) && !empty(azureQueuePrivateDnsZoneResourceId)
      ? [
          {
            customNetworkInterfaceName: replace(
              replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'AzureBackup'), 'RESOURCE', recoveryServicesVaultName),
              'VNETID',
              '${split(privateEndpointSubnetResourceId, '/')[8]}'
            )            
            name: replace(
              replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'AzureBackup'), 'RESOURCE', recoveryServicesVaultName),
              'VNETID',
              '${split(privateEndpointSubnetResourceId, '/')[8]}'
            )
            privateDnsZoneGroup: empty(nonEmptyBackupPrivateDNSZoneResourceIds) ? null :{
              privateDNSResourceIds: nonEmptyBackupPrivateDNSZoneResourceIds
            }
            service: 'AzureBackup'
            subnetResourceId: privateEndpointSubnetResourceId
            tags: union({'cm-resource-parent': hostPoolResourceId}, tags[?'Microsoft.Network/privateEndpoints'] ?? {})
          }
        ]
      : null
    diagnosticWorkspaceId: logAnalyticsWorkspaceResourceId
    tags: union({'cm-resource-parent': hostPoolResourceId}, tags[?'Microsoft.recoveryServices/vaults'] ?? {})
  }
}

/* Disabled temporarily until we can figure out why protected Items fail via ARM/Bicep.
module protectedItems_Vm 'modules/protectedItems.bicep' = [for i in range(1, sessionHostBatchCount): if (recoveryServices && (deploymentType != 'SessionHostsOnly' || !empty(existingRecoveryServicesVaultResourceId))) {
  name: 'BackupProtectedItems-VirtualMachines-${i-1}-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    policyName: backupPolicyName
    recoveryServicesVaultName: deploymentType == 'Complete' ? recoveryServicesVault!.outputs.name : last(split(existingRecoveryServicesVaultResourceId, '/'))
    sessionHostCount: i == sessionHostBatchCount && divisionRemainderValue > 0 ? divisionRemainderValue : maxVMsPerDeployment
    sessionHostIndex: i == 1 ? sessionHostIndex : ((i - 1) * maxVMsPerDeployment) + sessionHostIndex
    virtualMachineNamePrefix: virtualMachineNamePrefix
  }
  dependsOn: [
    virtualMachines[i-1]
  ]
}]
*/
module getFlattenedVmNamesArray 'modules/flattenVirtualMachineNames.bicep' = {
  name: 'FlattenVirtualMachineNames-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    virtualMachineNamesPerBatch: [for i in range(1, sessionHostBatchCount):virtualMachines[i-1].outputs.virtualMachineNames]
  }
}

output virtualMachineNames array = getFlattenedVmNamesArray.outputs.virtualMachineNames
