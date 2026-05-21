targetScope = 'subscription'

@description('Required. Name of the resource group where session host VMs are deployed.')
param resourceGroupHosts string

@description('Optional. Override download URL for the AVD Agent Boot Loader installer.')
param agentBootLoaderDownloadUrl string = ''
@description('Optional. Override download URL for the AVD Agent installer.')
param agentDownloadUrl string = ''
@description('Required. File name of the AVD Agent DSC configuration package blob.')
param avdAgentDscPackage string
@description('Required. URI of the blob storage container holding artifacts for session host customizations.')
param artifactsContainerUri string
@description('Required. Resource ID of the user-assigned managed identity with Storage Blob Data Reader access.')
param artifactsUserAssignedIdentityResourceId string
@description('Required. VM availability strategy.')
param availability string
@description('Required. Name convention string for availability sets.')
param availabilitySetNameConv string
@description('Required. Total number of availability sets to create.')
param availabilitySetsCount int
@description('Required. Starting index for availability set naming.')
param availabilitySetsIndex int
@description('Required. List of availability zones.')
param availabilityZones array
@description('Required. Resource ID of the AVD Insights data collection rule.')
param avdInsightsDataCollectionRulesResourceId string
@description('Required. When true, enables OS disk encryption with VMGuestState for confidential VMs.')
param confidentialVMOSDiskEncryption bool
@description('Optional. Resource ID of a Compute Gallery image version.')
param customImageResourceId string = ''
@description('Required. Resource ID of the Azure Monitor data collection endpoint.')
param dataCollectionEndpointResourceId string
@description('Optional. Resource ID of a dedicated host group.')
param dedicatedHostGroupResourceId string = ''
@description('Optional. Resource ID of a specific dedicated host.')
param dedicatedHostResourceId string = ''
@description('Optional. Resource ID of the DiskAccess resource.')
param diskAccessId string = ''
@description('Required. Password for the domain join service account.')
@secure()
param domainJoinUserPassword string
@description('Required. UPN of the domain join service account.')
@secure()
param domainJoinUserPrincipalName string
@description('Required. OS disk size in GB.')
param diskSizeGB int
@description('Required. Storage SKU for the OS disk.')
param diskSku string
@description('Required. Active Directory domain name for domain join.')
param domainName string
@description('Required. When true, enables accelerated networking.')
param enableAcceleratedNetworking bool
@description('Required. When true, adds IPv6 IP configuration to NICs.')
param enableIPv6 bool
@description('Required. When true, enables encryption at host.')
param encryptionAtHost bool
@description('Required. When true, installs AMD GPU driver extension.')
param hasAmdGpu bool
@description('Required. When true, installs NVIDIA GPU driver extension.')
param hasNvidiaGpu bool
@description('Optional. Resource ID of a pre-existing Disk Encryption Set.')
param existingDiskEncryptionSetResourceId string = ''
@description('Required. Array of Azure Files share names for FSLogix.')
param fslogixFileShareNames array
@description('Required. When true, configures FSLogix settings on session hosts.')
param fslogixConfigureSessionHosts bool
@description('Required. FSLogix container type.')
param fslogixContainerType string
@description('Required. Resource IDs of local NetApp volumes for FSLogix.')
param fslogixLocalNetAppVolumeResourceIds array
@description('Required. Resource IDs of local storage accounts for FSLogix.')
param fslogixLocalStorageAccountResourceIds array
@description('Required. Entra ID group object IDs for FSLogix OSS.')
param fslogixOSSGroups array
@description('Required. Resource IDs of remote NetApp volumes for FSLogix cloud cache failover.')
param fslogixRemoteNetAppVolumeResourceIds array
@description('Required. Resource IDs of remote storage accounts for FSLogix cloud cache failover.')
param fslogixRemoteStorageAccountResourceIds array
@description('Required. Maximum size of FSLogix profile VHD/VHDX in MB.')
param fslogixSizeInMBs int
@description('Required. Storage service backing FSLogix containers.')
param fslogixStorageService string
@description('Required. When true, enables VM hibernation.')
param hibernationEnabled bool
@description('Required. Resource ID of the AVD host pool.')
param hostPoolResourceId string
@description('Required. Identity join method.')
param identitySolution string
@description('Required. Marketplace image offer.')
param imageOffer string
@description('Required. Marketplace image publisher.')
param imagePublisher string
@description('Required. Marketplace image SKU.')
param imageSku string
@description('Required. When true, deploys the Guest Attestation extension.')
param integrityMonitoring bool
@description('Required. When true, enrolls session hosts into Intune.')
param intuneEnrollment bool
@description('Required. Azure region for session host VMs.')
param location string
@description('Required. When true, deploys Azure Monitor Agent and DCRs.')
param enableMonitoring bool
@description('Required. Name convention string for NICs, containing SHNAME placeholder.')
param networkInterfaceNameConv string
@description('Required. Name convention string for OS disks, containing SHNAME placeholder.')
param osDiskNameConv string
@description('Required. Distinguished name of the AD OU.')
param ouPath string
@description('Required. When true, enables Secure Boot.')
param secureBootEnabled bool
@description('Required. VM security profile type.')
param securityType string
@description('Required. Total number of session host VMs to deploy.')
param sessionHostCount int
@description('Optional. Array of customization objects.')
param sessionHostCustomizations array
@description('Required. Starting VM index number.')
param sessionHostIndex int
@description('Required. Number of digits in the zero-padded VM index.')
param vmNameIndexLength int
@description('Required. Resource ID of the virtual network subnet.')
param subnetResourceId string
@description('Required. Azure resource tags keyed by resource type.')
param tags object
@description('Required. Short unique suffix for deployment names.')
param deploymentSuffix string
@description('Required. Windows time zone for session host VMs.')
param timeZone string
@description('Required. Full name convention for VM names, containing SHNAME placeholder.')
param virtualMachineNameConv string
@description('Required. Short prefix for VM names.')
param virtualMachineNamePrefix string
@description('Required. Azure VM SKU for session hosts.')
param virtualMachineSize string
@description('Required. Local administrator password.')
@secure()
param virtualMachineAdminPassword string
@description('Required. Local administrator username.')
@secure()
param virtualMachineAdminUserName string
@description('Required. When true, enables virtual TPM.')
param vTpmEnabled bool
@description('Required. Resource ID of the VM Insights data collection rule.')
param vmInsightsDataCollectionRulesResourceId string
@description('Optional. Resource ID of the Recovery Services Vault for VM backup. Populated only for Personal host pools when backup is enabled.')
param recoveryServicesVaultResourceId string = ''
@description('Optional. Backup policy name for session host VMs.')
param vmBackupPolicyName string = 'AvdPolicyVm'

var generatedSessionHostNames = [for i in range(0, sessionHostCount): '${virtualMachineNamePrefix}${padLeft(i + sessionHostIndex, vmNameIndexLength, '0')}']

module sessionHosts 'modules/sessionHosts.bicep' = {
  name: 'Session-Hosts-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    agentBootLoaderDownloadUrl: agentBootLoaderDownloadUrl
    agentDownloadUrl: agentDownloadUrl
    avdAgentDscPackage: avdAgentDscPackage
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
    hasAmdGpu: hasAmdGpu
    hasNvidiaGpu: hasNvidiaGpu
    existingDiskEncryptionSetResourceId: existingDiskEncryptionSetResourceId
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
    networkInterfaceNameConv: networkInterfaceNameConv
    osDiskNameConv: osDiskNameConv
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
    vmInsightsDataCollectionRulesResourceId: vmInsightsDataCollectionRulesResourceId
    vTpmEnabled: vTpmEnabled
  }
}

// ─── VM Backup Registration ──────────────────────────────────────────────────
// Runs after sessionHosts so VM names are available. Scoped to the vault's
// resource group so ARM child resources (protectedItems) compile correctly.
module vmBackupRegistration '../operations/vmBackupItems.bicep' = if (!empty(recoveryServicesVaultResourceId)) {
  name: 'VmBackupRegistration-${deploymentSuffix}'
  scope: resourceGroup(split(recoveryServicesVaultResourceId, '/')[2], split(recoveryServicesVaultResourceId, '/')[4])
  params: {
    hostPoolResourceId: hostPoolResourceId
    policyName: vmBackupPolicyName
    recoveryServicesVaultName: last(split(recoveryServicesVaultResourceId, '/'))!
    resourceGroupHosts: resourceGroupHosts
    virtualMachineNames: sessionHosts.outputs.virtualMachineNames
  }
}

output virtualMachineNames array = sessionHosts.outputs.virtualMachineNames
