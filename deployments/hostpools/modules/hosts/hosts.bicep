targetScope = 'subscription'

param resourceGroupHosts string
param agentBootLoaderDownloadUrl string = ''
param agentDownloadUrl string = ''
param artifactsContainerUri string
param artifactsUserAssignedIdentityResourceId string
param availability string
param availabilitySetNameConv string
param availabilitySetsCount int
param availabilitySetsIndex int
param availabilityZones array
param avdInsightsDataCollectionRulesResourceId string
param confidentialVMOSDiskEncryption bool
param customImageResourceId string = ''
param dataCollectionEndpointResourceId string
param dedicatedHostGroupResourceId string = ''
param dedicatedHostResourceId string = ''
param diskAccessId string = ''
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param diskSizeGB int
param diskSku string
param domainName string
param enableAcceleratedNetworking bool
param enableIPv6 bool
param encryptionAtHost bool
param diskEncryptionSetResourceId string = ''
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
param location string
param enableMonitoring bool
param virtualMachineNicNameConv string
param virtualMachineDiskNameConv string
param ouPath string
param secureBootEnabled bool
param securityType string
param sessionHostCount int
param sessionHostCustomizations array
param sessionHostIndex int
param vmNameIndexLength int
param subnetResourceId string
param tags object
param deploymentSuffix string
param timeZone string
param virtualMachineNameConv string
param virtualMachineNamePrefix string
param virtualMachineSize string
@secure()
param virtualMachineAdminPassword string
@secure()
param virtualMachineAdminUserName string
param vTpmEnabled bool
// ─── VM Backup (Recovery Services Vault) ─────────────────────────────────────
@description('Optional. Whether to deploy or use a Recovery Services Vault for VM backup.')
param deployRecoveryServices bool = false
@description('Optional. Whether to create a new vault. False when providing existingVmBackupVaultResourceId.')
param createVault bool = true
@description('Optional. Resource ID of an existing VM backup Recovery Services Vault.')
param existingVmBackupVaultResourceId string = ''
@description('Optional. Name for the Recovery Services Vault (used only when createVault is true).')
param vaultName string = ''
@description('Optional. Storage replication type for a new vault.')
param vaultStorageRedundancy string = 'LocallyRedundant'
@description('Optional. Number of daily VM recovery points to retain (1–365).')
@minValue(1)
@maxValue(365)
param backupRetentionDays int = 30
@description('Optional. CMK mode for the vault.')
@allowed(['PlatformManaged', 'CustomerManaged', 'CustomerManagedHSM'])
param keyManagementType string = 'PlatformManaged'
@description('Optional. Resource ID of the CMK encryption Key Vault.')
param encryptionKeyVaultResourceId string = ''
@description('Optional. URI of the CMK encryption Key Vault.')
param encryptionKeyVaultUri string = ''
@description('Optional. Name of the CMK encryption key.')
param encryptionKeyName string = ''
@description('Optional. Key expiration period in days for the vault CMK encryption key. Also controls auto-rotation.')
@minValue(7)
param keyExpirationInDays int = 180
@description('Optional. Whether to deploy a private endpoint for the vault.')
param deployPrivateEndpoints bool = false
@description('Optional. Resource ID of the subnet for the vault private endpoint.')
param vaultPrivateEndpointSubnetResourceId string = ''
@description('Optional. Resource ID of the Azure Backup private DNS zone.')
param azureBackupPrivateDnsZoneResourceId string = ''
@description('Optional. Resource ID of the Azure Blob private DNS zone (needed for backup PE).')
param azureBlobPrivateDnsZoneResourceId string = ''
@description('Optional. Resource ID of the Azure Queue private DNS zone (needed for backup PE).')
param azureQueuePrivateDnsZoneResourceId string = ''
@description('Optional. Name convention for private endpoints.')
param privateEndpointNameConv string = ''
@description('Optional. Name convention for private endpoint NICs.')
param privateEndpointNICNameConv string = ''
@description('Optional. Resource ID of the Log Analytics workspace for vault diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

var generatedSessionHostNames = [for i in range(0, sessionHostCount): '${virtualMachineNamePrefix}${padLeft(i + sessionHostIndex, vmNameIndexLength, '0')}']

var vmBackupPolicyName = 'AvdPolicyVm'

module recoveryServicesModule 'modules/recoveryServices.bicep' = if (deployRecoveryServices) {
  name: 'RecoveryServices-${deploymentSuffix}'
  params: {
    createVault: createVault
    existingRecoveryServicesVaultResourceId: existingVmBackupVaultResourceId
    vaultName: vaultName
    resourceGroupHosts: resourceGroupHosts
    location: location
    storageRedundancy: vaultStorageRedundancy
    deploymentSuffix: deploymentSuffix
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    privateEndpoint: deployPrivateEndpoints
    privateEndpointSubnetResourceId: vaultPrivateEndpointSubnetResourceId
    azureBackupPrivateDnsZoneResourceId: azureBackupPrivateDnsZoneResourceId
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    privateEndpointNameConv: privateEndpointNameConv
    privateEndpointNICNameConv: privateEndpointNICNameConv
    tags: tags
    timeZone: timeZone
    vmPolicyName: vmBackupPolicyName
    backupRetentionDays: backupRetentionDays
    keyManagementType: keyManagementType
    encryptionKeyVaultResourceId: encryptionKeyVaultResourceId
    encryptionKeyVaultUri: encryptionKeyVaultUri
    encryptionKeyName: encryptionKeyName
    keyExpirationInDays: keyExpirationInDays
  }
}

var effectiveRecoveryServicesVaultResourceId = deployRecoveryServices
  ? (empty(existingVmBackupVaultResourceId)
      ? recoveryServicesModule!.outputs.recoveryServicesVaultResourceId
      : existingVmBackupVaultResourceId)
  : ''

module sessionHosts 'modules/sessionHosts.bicep' = {
  name: 'Session-Hosts-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    agentBootLoaderDownloadUrl: agentBootLoaderDownloadUrl
    agentDownloadUrl: agentDownloadUrl
    artifactsContainerUri: artifactsContainerUri
    artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
    availability: availability
    availabilitySetNameConv: availabilitySetNameConv
    availabilitySetsCount: availabilitySetsCount
    availabilitySetsIndex: availabilitySetsIndex
    availabilityZones: availabilityZones
    avdInsightsDataCollectionRulesResourceId: avdInsightsDataCollectionRulesResourceId
    confidentialVMOSDiskEncryption: confidentialVMOSDiskEncryption
    customImageResourceId: customImageResourceId
    dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
    dedicatedHostGroupResourceId: dedicatedHostGroupResourceId
    dedicatedHostResourceId: dedicatedHostResourceId
    diskAccessId: diskAccessId
    diskSizeGB: diskSizeGB
    diskSku: diskSku
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    domainName: domainName
    enableAcceleratedNetworking: enableAcceleratedNetworking
    enableIPv6: enableIPv6
    enableMonitoring: enableMonitoring
    encryptionAtHost: encryptionAtHost
    diskEncryptionSetResourceId: diskEncryptionSetResourceId
    fslogixConfigureSessionHosts: fslogixConfigureSessionHosts
    fslogixContainerType: fslogixContainerType
    fslogixFileShareNames: fslogixFileShareNames
    fslogixLocalStorageAccountResourceIds: fslogixLocalStorageAccountResourceIds
    fslogixLocalNetAppVolumeResourceIds: fslogixLocalNetAppVolumeResourceIds
    fslogixOSSGroups: fslogixOSSGroups
    fslogixRemoteNetAppVolumeResourceIds: fslogixRemoteNetAppVolumeResourceIds
    fslogixRemoteStorageAccountResourceIds: fslogixRemoteStorageAccountResourceIds
    fslogixSizeInMBs: fslogixSizeInMBs
    fslogixStorageService: fslogixStorageService
    hibernationEnabled: hibernationEnabled
    hostPoolResourceId: hostPoolResourceId
    identitySolution: identitySolution
    imageOffer: imageOffer
    imagePublisher: imagePublisher
    imageSku: imageSku
    integrityMonitoring: integrityMonitoring
    intuneEnrollment: intuneEnrollment
    location: location
    virtualMachineNicNameConv: virtualMachineNicNameConv
    virtualMachineDiskNameConv: virtualMachineDiskNameConv
    ouPath: ouPath
    secureBootEnabled: secureBootEnabled
    securityType: securityType
    sessionHostCustomizations: sessionHostCustomizations
    sessionHostNames: generatedSessionHostNames
    vmNameIndexLength: vmNameIndexLength
    subnetResourceId: subnetResourceId
    tags: tags
    deploymentSuffix: deploymentSuffix
    timeZone: timeZone
    virtualMachineAdminPassword: virtualMachineAdminPassword
    virtualMachineAdminUserName: virtualMachineAdminUserName
    virtualMachineNameConv: virtualMachineNameConv
    virtualMachineSize: virtualMachineSize
    vTpmEnabled: vTpmEnabled
    recoveryServicesVaultResourceId: effectiveRecoveryServicesVaultResourceId
    vmBackupPolicyName: vmBackupPolicyName
  }
}

output virtualMachineNames array = sessionHosts.outputs.virtualMachineNames
