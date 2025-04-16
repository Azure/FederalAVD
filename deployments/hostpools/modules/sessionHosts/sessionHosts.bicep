targetScope = 'subscription'

param deploymentType string
param artifactsContainerUri string
param artifactsUserAssignedIdentityResourceId string
param availability string
param availabilitySetNamePrefix string
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
param dedicatedHostGroupZones array
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
param drainMode bool
param enableAcceleratedNetworking bool
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
param fslogixStorageService string
param hibernationEnabled bool
param hostPoolResourceId string
param identitySolution string
param imageOffer string
param imagePublisher string
param imageSku string
param integrityMonitoring bool
param keyExpirationInDays int
param keyManagementDisks string
param location string
param logAnalyticsWorkspaceResourceId string
param maxResourcesPerTemplateDeployment int
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
param storageSuffix string
param subnetResourceId string
param tags object
param timeStamp string
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

// create new arrays that always contain the profile-containers volume as the first element.
var localNetAppProfileContainerVolumeResourceIds = !empty(fslogixLocalNetAppVolumeResourceIds) ? filter(fslogixLocalNetAppVolumeResourceIds, id => contains(id, fslogixFileShareNames[0])) : []
var localNetAppOfficeContainerVolumeResourceIds = !empty(fslogixLocalNetAppVolumeResourceIds) && length(fslogixFileShareNames) > 1 ? filter(fslogixLocalNetAppVolumeResourceIds, id => contains(id, fslogixFileShareNames[1])) : []
var sortedLocalNetAppResourceIds = union(localNetAppProfileContainerVolumeResourceIds, localNetAppOfficeContainerVolumeResourceIds)
var remoteNetAppProfileContainerVolumeResourceIds = !empty(fslogixRemoteNetAppVolumeResourceIds) ? filter(fslogixRemoteNetAppVolumeResourceIds, id => contains(id, fslogixFileShareNames[0])) : []
var remoteNetAppOfficeContainerVolumeResourceIds = !empty(fslogixRemoteNetAppVolumeResourceIds) && length(fslogixFileShareNames) > 1 ? filter(fslogixRemoteNetAppVolumeResourceIds, id => !contains(id, fslogixFileShareNames[0])) : []
var sortedRemoteNetAppResourceIds = union(remoteNetAppProfileContainerVolumeResourceIds, remoteNetAppOfficeContainerVolumeResourceIds)

var backupPrivateDNSZoneResourceIds = [
  azureBackupPrivateDnsZoneResourceId
  azureBlobPrivateDnsZoneResourceId
  azureQueuePrivateDnsZoneResourceId
]

var nonEmptyBackupPrivateDNSZoneResourceIds = filter(backupPrivateDNSZoneResourceIds, zone => !empty(zone))

// Call on the hotspool
resource hostPoolGet 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' existing = if(deploymentType != 'Complete') {
  name: last(split(hostPoolResourceId, '/'))
  scope: resourceGroup(split(hostPoolResourceId, '/')[4])
}

module hostPoolUpdate 'modules/hostPoolUpdate.bicep' = if(deploymentType != 'Complete') {
  name: 'HostPoolRegistrationTokenUpdate_${timeStamp}'
  scope: resourceGroup(split(hostPoolResourceId, '/')[4])
  params: {
    hostPoolType: deploymentType != 'Complete' ? hostPoolGet.properties.hostPoolType : ''
    loadBalancerType: deploymentType != 'Complete' ? hostPoolGet.properties.loadBalancerType : ''
    location: deploymentType != 'Complete' ? hostPoolGet.location : location
    name: deploymentType != 'Complete' ? hostPoolGet.name : ''
    preferredAppGroupType: deploymentType != 'Complete' ? hostPoolGet.properties.preferredAppGroupType : ''
  } 
}

module diskAccessResource '../../../sharedModules/resources/compute/disk-access/main.bicep' = if (deployDiskAccessResource && deploymentType == 'Complete') {
  scope: resourceGroup(resourceGroupHosts)
  name: 'DiskAccess_${timeStamp}'
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

module diskAccessPolicy 'modules/diskNetworkAccessPolicy.bicep' = if (deployDiskAccessPolicy) {
  name: 'ManagedDisks_NetworkAccess_Policy_${timeStamp}'
  params: {
    diskAccessId: deployDiskAccessResource ? diskAccessResource.outputs.resourceId : ''
    location: location
    resourceGroupName: resourceGroupHosts
  }
}

module customerManagedKeys 'modules/customerManagedKeys.bicep' =  if (deploymentType == 'Complete' && keyManagementDisks != 'PlatformManaged') {
  name: 'Customer_Managed_Keys_${timeStamp}'
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
    resourceGroupDeployment: resourceGroupDeployment
    tags: tags
    timeStamp: timeStamp
  }
}

module artifactsUserAssignedIdentity 'modules/getUserAssignedIdentity.bicep' = if(!empty(artifactsUserAssignedIdentityResourceId)) {
  name: 'ArtifactsUserAssignedIdentity_${timeStamp}'
  params: {
    userAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
  }
}

module availabilitySets '../../../sharedModules/resources/compute/availability-set/main.bicep' = [for i in range(0, availabilitySetsCount): if (pooledHostPool && availability == 'AvailabilitySets') {
  name: '${availabilitySetNamePrefix}${padLeft((i + availabilitySetsIndex), 2, '0')}_${timeStamp}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    name: '${availabilitySetNamePrefix}${padLeft((i + availabilitySetsIndex), 2, '0')}'
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
    proximityPlacementGroupResourceId: ''
    location: location
    skuName: 'Aligned'
    tags: union({'cm-resource-parent': hostPoolResourceId}, tags[?'Microsoft.Compute/availabilitySets'] ?? {})
  }
}]

module localNetAppVolumes 'modules/getNetAppVolumeSmbServerFqdn.bicep' = [for i in range(0, length(sortedLocalNetAppResourceIds)): if(!empty(sortedLocalNetAppResourceIds)) {
  name: 'LocalNetAppVolumes-${i}-${timeStamp}'
  params: {
    netAppVolumeResourceId: sortedLocalNetAppResourceIds[i]
  }
}]

module remoteNetAppVolumes 'modules/getNetAppVolumeSmbServerFqdn.bicep' = [for i in range(0, length(sortedRemoteNetAppResourceIds)) : if(!empty(sortedRemoteNetAppResourceIds)) {
  name: 'RemoteNetAppVolumes-${i}-${timeStamp}'
  params: {
    netAppVolumeResourceId: sortedRemoteNetAppResourceIds[i]
  }
}]

@batchSize(5)
module virtualMachines 'modules/virtualMachines.bicep' = [for i in range(1, sessionHostBatchCount): {
  name: 'VirtualMachines_Batch_${i-1}_${timeStamp}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    artifactsContainerUri: artifactsContainerUri
    artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
    artifactsUserAssignedIdentityClientId: empty(artifactsUserAssignedIdentityResourceId) ? '' : artifactsUserAssignedIdentity.outputs.clientId
    availability: availability
    availabilityZones: availabilityZones
    availabilitySetNamePrefix: availabilitySetNamePrefix
    avdInsightsDataCollectionRulesResourceId: avdInsightsDataCollectionRulesResourceId
    batchCount: i
    confidentialVMOSDiskEncryptionType: confidentialVMOSDiskEncryptionType
    customImageResourceId: customImageResourceId
    dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
    dedicatedHostGroupResourceId: dedicatedHostGroupResourceId
    dedicatedHostGroupZones: dedicatedHostGroupZones
    dedicatedHostResourceId: dedicatedHostResourceId
    deploymentUserAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deploymentVirtualMachineName
    diskAccessId: deploymentType == 'Complete' ? deployDiskAccessResource ? diskAccessResource.outputs.resourceId : '' : existingDiskAccessResourceId
    diskEncryptionSetResourceId: ( deploymentType == 'Complete' && keyManagementDisks != 'PlatformManaged' ) ? customerManagedKeys.outputs.diskEncryptionSetResourceId : !empty(existingDiskEncryptionSetResourceId) ? existingDiskEncryptionSetResourceId : ''
    diskSizeGB: diskSizeGB
    diskSku: diskSku
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    domainName: domainName
    drainMode: drainMode
    enableAcceleratedNetworking: enableAcceleratedNetworking
    enableMonitoring: enableMonitoring
    encryptionAtHost: encryptionAtHost
    fslogixConfigureSessionHosts: fslogixConfigureSessionHosts
    fslogixContainerType: fslogixContainerType
    fslogixFileShareNames: fslogixFileShareNames
    fslogixOSSGroups: fslogixOSSGroups
    fslogixLocalNetAppServerFqdns: [for i in range(0, length(sortedLocalNetAppResourceIds)) : localNetAppVolumes[i].outputs.smbServerFqdn]
    fslogixLocalStorageAccountResourceIds: fslogixLocalStorageAccountResourceIds
    fslogixRemoteNetAppServerFqdns: [for i in range(0, length(sortedRemoteNetAppResourceIds)) : remoteNetAppVolumes[i].outputs.smbServerFqdn]
    fslogixRemoteStorageAccountResourceIds: fslogixRemoteStorageAccountResourceIds    
    fslogixStorageService: fslogixStorageService
    hibernationEnabled: hibernationEnabled
    hostPoolResourceId: deploymentType == 'Complete' ? hostPoolResourceId : hostPoolUpdate.outputs.resourceId
    identitySolution: identitySolution
    imageOffer: imageOffer
    imagePublisher: imagePublisher
    imageSku: imageSku
    integrityMonitoring: integrityMonitoring
    location: location
    networkInterfaceNameConv: networkInterfaceNameConv
    osDiskNameConv: osDiskNameConv
    ouPath: ouPath
    resourceGroupDeployment: resourceGroupDeployment
    sessionHostCustomizations: sessionHostCustomizations
    securityDataCollectionRulesResourceId: securityDataCollectionRulesResourceId
    secureBootEnabled: secureBootEnabled
    securityType: securityType
    sessionHostCount: i == sessionHostBatchCount && divisionRemainderValue > 0 ? divisionRemainderValue : maxResourcesPerTemplateDeployment
    sessionHostIndex: i == 1 ? sessionHostIndex : ((i - 1) * maxResourcesPerTemplateDeployment) + sessionHostIndex
    sessionHostRegistrationDSCUrl: sessionHostRegistrationDSCUrl
    storageSuffix: storageSuffix
    subnetResourceId: subnetResourceId
    tags: tags
    timeStamp: timeStamp
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

module recoveryServicesVault '../../../sharedModules/resources/recovery-services/vault/main.bicep' = if (deploymentType == 'Complete' && recoveryServices) {
  name: 'RecoveryServicesVault_VirtualMachines_${timeStamp}'
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

module protectedItems_Vm 'modules/protectedItems.bicep' = [for i in range(1, sessionHostBatchCount): if (recoveryServices && (deploymentType == 'Complete' || !empty(existingRecoveryServicesVaultResourceId))) {
  name: 'BackupProtectedItems_VirtualMachines_${i-1}_${timeStamp}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    location: location
    PolicyId: deploymentType == 'Complete' ? '${recoveryServicesVault.outputs.resourceId}/backupPolicies/${backupPolicyName}' : '${existingRecoveryServicesVaultResourceId}/backupPolicies/${backupPolicyName}'
    recoveryServicesVaultName: deploymentType == 'Complete' ? recoveryServicesVault.outputs.name : last(split(existingRecoveryServicesVaultResourceId, '/'))
    sessionHostCount: i == sessionHostBatchCount && divisionRemainderValue > 0 ? divisionRemainderValue : maxResourcesPerTemplateDeployment
    sessionHostIndex: i == 1 ? sessionHostIndex : ((i - 1) * maxResourcesPerTemplateDeployment) + sessionHostIndex
    tags: union({'cm-resource-parent': hostPoolResourceId}, tags[?'Microsoft.recoveryServices/vaults'] ?? {})
    virtualMachineNamePrefix: virtualMachineNamePrefix
    VirtualMachineResourceGroupName: resourceGroupHosts
  }
  dependsOn: [
    virtualMachines[i-1]
  ]
}]

module getFlattenedVmNamesArray 'modules/flattenVirtualMachineNames.bicep' = {
  name: 'FlattenVirtualMachineNames_${timeStamp}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    virtualMachineNamesPerBatch: [for i in range(1, sessionHostBatchCount):virtualMachines[i-1].outputs.virtualMachineNames]
  }
}

output virtualMachineNames array = getFlattenedVmNamesArray.outputs.virtualMachineNames
