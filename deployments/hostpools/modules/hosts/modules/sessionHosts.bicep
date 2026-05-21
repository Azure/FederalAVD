@description('Optional. Override download URL for the AVD Agent Boot Loader installer. Leave empty to use the default Microsoft-hosted URL for the current cloud.')
param agentBootLoaderDownloadUrl string = ''
@description('Optional. Override download URL for the AVD Agent installer. Leave empty to use the default Microsoft-hosted URL for the current cloud.')
param agentDownloadUrl string = ''
@description('Required. File name of the AVD Agent DSC configuration package blob (e.g. "Configuration_01-20-2023.zip"). Used during session host registration.')
param avdAgentDscPackage string
@description('Required. URI of the blob storage container holding scripts and artifacts for session host customizations.')
param artifactsContainerUri string
@description('Required. Resource ID of the user-assigned managed identity with Storage Blob Data Reader access to the artifacts container.')
param artifactsUserAssignedIdentityResourceId string
@description('Required. VM availability strategy: "None", "AvailabilitySets", or "AvailabilityZones".')
param availability string
@description('Required. Name convention string for availability sets, containing ## placeholder for set number.')
param availabilitySetNameConv string
@description('Required. Total number of availability sets to create for this host pool deployment.')
param availabilitySetsCount int
@description('Required. Starting index used when naming availability sets.')
param availabilitySetsIndex int
@description('Required. List of availability zones across which session hosts are distributed. Used when availability is "AvailabilityZones".')
param availabilityZones array
@description('Required. Resource ID of the AVD Insights data collection rule for session host diagnostics.')
param avdInsightsDataCollectionRulesResourceId string
@description('Required. When true, enables OS disk encryption with VMGuestState for confidential VMs.')
param confidentialVMOSDiskEncryption bool
@description('Optional. Resource ID of an Azure Compute Gallery image version. Leave empty to use marketplace image.')
param customImageResourceId string = ''
@description('Required. Resource ID of the Azure Monitor data collection endpoint.')
param dataCollectionEndpointResourceId string
@description('Optional. Resource ID of a dedicated host group for all session hosts in this deployment.')
param dedicatedHostGroupResourceId string = ''
@description('Optional. Resource ID of a specific dedicated host for all session hosts in this deployment.')
param dedicatedHostResourceId string = ''
@description('Optional. Per-VM array of dedicated host group resource IDs. Takes precedence over dedicatedHostGroupResourceId when non-empty.')
param dedicatedHostGroupResourceIds array = []
@description('Optional. Per-VM array of dedicated host resource IDs. Takes precedence over dedicatedHostResourceId when non-empty.')
param dedicatedHostResourceIds array = []
@description('Optional. Per-VM preferred availability zones. One entry per session host (as a zone string). Empty array means no zone preference.')
param preferredZones array = []
@description('Optional. Resource ID of the DiskAccess resource used to restrict managed disk network access.')
param diskAccessId string = ''
@description('Required. Password for the domain join service account.')
@secure()
param domainJoinUserPassword string
@description('Required. User principal name of the domain join service account.')
@secure()
param domainJoinUserPrincipalName string
@description('Required. OS disk size in GB. Set to 0 to inherit the default size from the source image.')
param diskSizeGB int
@description('Required. Storage SKU for the OS disk.')
param diskSku string
@description('Required. Active Directory domain name for domain join. Leave empty for Entra ID join.')
param domainName string
@description('Required. When true, enables accelerated networking on session host NICs.')
param enableAcceleratedNetworking bool
@description('Required. When true, adds an IPv6 IP configuration to session host NICs.')
param enableIPv6 bool
@description('Required. When true, enables encryption at the VM host for all disks and cache.')
param encryptionAtHost bool
@description('Required. When true, installs the AMD GPU driver extension.')
param hasAmdGpu bool
@description('Required. When true, installs the NVIDIA GPU driver extension.')
param hasNvidiaGpu bool
@description('Optional. Resource ID of a pre-existing Disk Encryption Set.')
param existingDiskEncryptionSetResourceId string = ''
@description('Required. Array of Azure Files share names to mount for FSLogix profile containers.')
param fslogixFileShareNames array
@description('Required. When true, configures FSLogix profile container settings on session hosts.')
param fslogixConfigureSessionHosts bool
@description('Required. FSLogix container type.')
param fslogixContainerType string
@description('Required. Resource IDs of NetApp volumes in the session host region for FSLogix.')
param fslogixLocalNetAppVolumeResourceIds array
@description('Required. Resource IDs of Azure Storage accounts in the session host region for FSLogix.')
param fslogixLocalStorageAccountResourceIds array
@description('Required. Entra ID group object IDs for FSLogix Office container separation.')
param fslogixOSSGroups array
@description('Required. Resource IDs of NetApp volumes in a remote region for FSLogix cloud cache failover.')
param fslogixRemoteNetAppVolumeResourceIds array
@description('Required. Resource IDs of Azure Storage accounts in a remote region for FSLogix cloud cache failover.')
param fslogixRemoteStorageAccountResourceIds array
@description('Required. Maximum size of the FSLogix profile VHD/VHDX in megabytes.')
param fslogixSizeInMBs int
@description('Required. Storage service backing FSLogix containers.')
param fslogixStorageService string
@description('Required. When true, enables VM hibernation on session hosts.')
param hibernationEnabled bool
@description('Required. Resource ID of the AVD host pool that session hosts will be registered with.')
param hostPoolResourceId string
@description('Required. Identity join method: "ActiveDirectoryDomainServices", "EntraId", or "EntraIdIntuneEnrollment".')
param identitySolution string
@description('Optional. Pre-built image reference object. When provided, takes precedence over imagePublisher/imageOffer/imageSku/customImageResourceId.')
param imageReference object = {}
@description('Required. Marketplace image offer. Used when imageReference and customImageResourceId are empty.')
param imageOffer string
@description('Required. Marketplace image publisher. Used when imageReference and customImageResourceId are empty.')
param imagePublisher string
@description('Required. Marketplace image SKU. Used when imageReference and customImageResourceId are empty.')
param imageSku string
@description('Required. When true, deploys the Guest Attestation extension for boot integrity monitoring.')
param integrityMonitoring bool
@description('Required. When true, enrolls session hosts into Microsoft Intune during provisioning.')
param intuneEnrollment bool
@description('Required. Azure region where session host VMs are deployed.')
param location string
@description('Required. When true, deploys Azure Monitor Agent and data collection rules on session hosts.')
param enableMonitoring bool
@description('Required. Name convention string for session host NICs, containing SHNAME placeholder.')
param networkInterfaceNameConv string
@description('Required. Name convention string for session host OS disks, containing SHNAME placeholder.')
param osDiskNameConv string
@description('Required. Distinguished name of the AD OU for session host computer accounts.')
param ouPath string
@description('Required. When true, enables Secure Boot on session host VMs.')
param secureBootEnabled bool
@description('Required. VM security profile type: "Standard", "TrustedLaunch", or "ConfidentialVM".')
param securityType string
@description('Required. Resolved list of session host computer names to deploy.')
param sessionHostNames array
@description('Optional. Array of customization objects to execute on session hosts after provisioning.')
param sessionHostCustomizations array
@description('Required. Number of digits in the zero-padded VM index. Used to extract the numeric suffix for availability zone and set assignment.')
param vmNameIndexLength int = 2
@description('Required. Resource ID of the virtual network subnet where session host NICs are connected.')
param subnetResourceId string
@description('Required. Azure resource tags applied to all deployed resources, keyed by resource type.')
param tags object
@description('Required. Short unique suffix appended to deployment names to prevent naming collisions.')
param deploymentSuffix string
@description('Required. Windows time zone for session host VMs.')
param timeZone string
@description('Required. Full name convention string for VM names, containing SHNAME placeholder.')
param virtualMachineNameConv string
@description('Required. Azure VM SKU for session hosts.')
param virtualMachineSize string
@description('Required. Local administrator password for all session host VMs.')
@secure()
param virtualMachineAdminPassword string
@description('Required. Local administrator username for all session host VMs.')
@secure()
param virtualMachineAdminUserName string
@description('Required. When true, enables virtual TPM on session host VMs.')
param vTpmEnabled bool
@description('Required. Resource ID of the VM Insights data collection rule.')
param vmInsightsDataCollectionRulesResourceId string

// === Computed image reference ===
var confidentialVMOSDiskEncryptionType = confidentialVMOSDiskEncryption ? 'DiskWithVMGuestState' : 'VMGuestStateOnly'
var effectiveImageReference = !empty(imageReference)
  ? imageReference
  : !empty(customImageResourceId)
      ? { id: customImageResourceId }
      : { publisher: imagePublisher, offer: imageOffer, sku: imageSku, version: 'latest' }

// === Session host names ===
var totalVmCount = length(sessionHostNames)
// Numeric suffix extracted from each name — used for availability zone rotation and set assignment.
var allVmNumbers = [for name in sessionHostNames: int(substring(name, length(name) - vmNameIndexLength, vmNameIndexLength))]

// === Dedicated host arrays ===
// Array params (wrapper/SHR path) take precedence over single-string params (hostpool path).
var effectiveDedicatedHostGroupResourceIds = !empty(dedicatedHostGroupResourceIds)
  ? dedicatedHostGroupResourceIds
  : !empty(dedicatedHostGroupResourceId) ? [dedicatedHostGroupResourceId] : []
var effectiveDedicatedHostResourceIds = !empty(dedicatedHostResourceIds)
  ? dedicatedHostResourceIds
  : !empty(dedicatedHostResourceId) ? [dedicatedHostResourceId] : []

// === Batching logic ===
// Dynamically calculate max VMs per batch based on resources per VM
var baseResourcesPerVM = 11
var monitoringResourcesPerVM = enableMonitoring ? 4 : 0
var gpuResourcesPerVM = (hasAmdGpu || hasNvidiaGpu) ? 1 : 0
var integrityResourcesPerVM = integrityMonitoring ? 1 : 0
var customizationsResourcesPerVM = !empty(sessionHostCustomizations) ? (1 + length(sessionHostCustomizations)) : 0
var totalResourcesPerVM = baseResourcesPerVM + monitoringResourcesPerVM + gpuResourcesPerVM + integrityResourcesPerVM + customizationsResourcesPerVM
var calculatedMaxVMs = 800 / totalResourcesPerVM
var maxVMsPerDeployment = calculatedMaxVMs < 20 ? 20 : (calculatedMaxVMs > 45 ? 45 : calculatedMaxVMs)
var divisionValue = totalVmCount / maxVMsPerDeployment
var divisionRemainderValue = totalVmCount % maxVMsPerDeployment
var sessionHostBatchCount = divisionRemainderValue > 0 ? divisionValue + 1 : divisionValue

// === Agent Download URLs ===
var cloud = toLower(environment().name)
var cloudSuffix = replace(replace(replace(environment().resourceManager, 'https://management.azure.', ''), 'https://management.', ''), '/', '')
var agentBootLoaderUrl = !empty(agentBootLoaderDownloadUrl)
  ? agentBootLoaderDownloadUrl
  : (startsWith(cloud, 'us') ? 'https://aka.${cloudSuffix}/avdRDAgentBootLoader' : 'https://go.microsoft.com/fwlink/?linkid=2311028')
var agentUrl = !empty(agentDownloadUrl)
  ? agentDownloadUrl
  : (startsWith(cloud, 'us') ? 'https://aka.${cloudSuffix}/avdRDAgent' : 'https://go.microsoft.com/fwlink/?linkid=2310011')
var dscStorageAccount = startsWith(environment().name, 'USN') ? 'wvdexportalcontainer' : 'wvdportalstorageblob'
var dscUrl = 'https://${dscStorageAccount}.blob.${environment().suffixes.storage}/galleryartifacts/${avdAgentDscPackage}'

resource artifactsUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = if (!empty(artifactsUserAssignedIdentityResourceId)) {
  scope: resourceGroup(split(artifactsUserAssignedIdentityResourceId, '/')[2], split(artifactsUserAssignedIdentityResourceId, '/')[4])
  name: last(split(artifactsUserAssignedIdentityResourceId, '/'))
}

module availabilitySets '../../../../../.common/bicepModules/compute/availabilitySets/deploy.bicep' = [for i in range(0, availabilitySetsCount): if (availability == 'AvailabilitySets') {
  name: 'AvailabilitySet-${padLeft((i + availabilitySetsIndex) + 1, 2, '0')}-${deploymentSuffix}'
  params: {
    name: replace(availabilitySetNameConv, '##', padLeft((i + availabilitySetsIndex) + 1, 2, '0'))
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
    location: location
    skuName: 'Aligned'
    tags: union({'cm-resource-parent': hostPoolResourceId}, tags[?'Microsoft.Compute/availabilitySets'] ?? {})
  }
}]

module netAppVolumeFqdns 'getNetAppVolumeSmbServerFqdns.bicep' = if (fslogixConfigureSessionHosts && (!empty(fslogixLocalNetAppVolumeResourceIds) || !empty(fslogixRemoteNetAppVolumeResourceIds))) {
  name: 'NetAppVolumeFqdns-${deploymentSuffix}'
  params: {
    localNetAppVolumeResourceIds: fslogixLocalNetAppVolumeResourceIds
    remoteNetAppVolumeResourceIds: fslogixRemoteNetAppVolumeResourceIds
    shareNames: fslogixFileShareNames
  }
}

@batchSize(5)
module virtualMachines 'virtualMachines.bicep' = [for i in range(1, sessionHostBatchCount): {
  name: 'VirtualMachines-Batch-${i}-of-${sessionHostBatchCount}-(${i == sessionHostBatchCount && divisionRemainderValue > 0 ? divisionRemainderValue : maxVMsPerDeployment}-VMs)-${deploymentSuffix}'
  params: {
    agentBootLoaderDownloadUrl: agentBootLoaderUrl
    agentDownloadUrl: agentUrl
    agentFallBackDownloadUrl: dscUrl
    artifactsContainerUri: artifactsContainerUri
    artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
    artifactsUserAssignedIdentityClientId: empty(artifactsUserAssignedIdentityResourceId) ? '' : artifactsUAI!.properties.clientId
    availability: availability
    availabilityZones: availabilityZones
    availabilitySetNameConv: availabilitySetNameConv
    avdInsightsDataCollectionRulesResourceId: avdInsightsDataCollectionRulesResourceId
    confidentialVMOSDiskEncryptionType: confidentialVMOSDiskEncryptionType
    dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
    dedicatedHostGroupResourceIds: effectiveDedicatedHostGroupResourceIds
    dedicatedHostResourceIds: effectiveDedicatedHostResourceIds
    preferredZones: preferredZones
    diskAccessId: diskAccessId
    diskEncryptionSetResourceId: existingDiskEncryptionSetResourceId
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
    hostPoolResourceId: hostPoolResourceId
    hasAmdGpu: hasAmdGpu
    hasNvidiaGpu: hasNvidiaGpu
    identitySolution: identitySolution
    imageReference: effectiveImageReference
    integrityMonitoring: integrityMonitoring
    intuneEnrollment: intuneEnrollment
    location: location
    networkInterfaceNameConv: networkInterfaceNameConv
    osDiskNameConv: osDiskNameConv
    ouPath: ouPath
    sessionHostCustomizations: sessionHostCustomizations
    sessionHostNames: [for j in range(0, i == sessionHostBatchCount && divisionRemainderValue > 0 ? divisionRemainderValue : maxVMsPerDeployment): sessionHostNames[(i - 1) * maxVMsPerDeployment + j]]
    vmNumbers: [for j in range(0, i == sessionHostBatchCount && divisionRemainderValue > 0 ? divisionRemainderValue : maxVMsPerDeployment): allVmNumbers[(i - 1) * maxVMsPerDeployment + j]]
    secureBootEnabled: secureBootEnabled
    securityType: securityType
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
  dependsOn: [
    availabilitySets
  ]
}]

module getFlattenedVmNamesArray 'flattenVirtualMachineNames.bicep' = {
  name: 'Flatten-VirtualMachine-Names-${deploymentSuffix}'
  params: {
    virtualMachineNamesPerBatch: [for i in range(1, sessionHostBatchCount): virtualMachines[i - 1].outputs.virtualMachineNames]
  }
}

output virtualMachineNames array = getFlattenedVmNamesArray.outputs.virtualMachineNames
