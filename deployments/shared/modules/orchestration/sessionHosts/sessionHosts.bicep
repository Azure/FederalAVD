metadata name = 'Session host deployment orchestration'
metadata description = 'Batches session-host deployment in the current resource group, composing availability sets, optional NetApp endpoint lookups, VM initialization, and ordered VM-name outputs.'

import { artifactCustomizationType } from '../../resourceModules/types/customizationTypes.bicep'

@description('Optional. AVD Agent Boot Loader installer URL; empty lets orchestration select the cloud-specific default.')
param agentBootLoaderDownloadUrl string = ''
@description('Optional. AVD Agent installer URL; empty lets orchestration select the cloud-specific default.')
param agentDownloadUrl string = ''
@description('Required. Base URI of the existing artifact container used to resolve relative customization blob names.')
param artifactsContainerUri string
@description('Required. Resource ID of the existing artifact-read identity to attach to session hosts; empty omits that identity.')
param artifactsUserAssignedIdentityResourceId string
@description('Required. Placement mode used to select availability sets or availability zones.')
param availability string
@description('Required. Availability set name pattern containing ## for the two-digit set number.')
param availabilitySetNameConv string
@description('Required. Number of availability sets to create when availability is AvailabilitySets.')
param availabilitySetsCount int
@description('Required. Zero-based starting availability set index before adding one for the name suffix.')
param availabilitySetsIndex int
@description('Required. Ordered availability zone strings used for rotation based on each VM numeric suffix.')
param availabilityZones string[]
@description('Required. Resource ID of the existing AVD Insights data collection rule; empty skips its association when monitoring is enabled.')
param avdInsightsDataCollectionRulesResourceId string
@description('Required. Whether confidential VM OS disk encryption is selected.')
param confidentialVMOSDiskEncryption bool
@description('Optional. Custom or Gallery image resource ID used when imageReference is empty; empty falls back to marketplace image inputs.')
param customImageResourceId string = ''
@description('Optional. License type applied to VMs deployed from a custom/gallery image. Ignored for marketplace images.')
param customImageLicenseType string = 'Windows_Client'
@description('Required. Resource ID of an existing data collection endpoint; empty skips its association.')
param dataCollectionEndpointResourceId string
@description('Optional. Single existing dedicated host group ID used when dedicatedHostGroupResourceIds is empty.')
param dedicatedHostGroupResourceId string = ''
@description('Optional. Existing dedicated host group IDs; one applies to all VMs, otherwise entries align with the VM names. Used only when no dedicated hosts are supplied.')
param dedicatedHostGroupResourceIds string[] = []
@description('Optional. Single existing dedicated host ID used when dedicatedHostResourceIds is empty.')
param dedicatedHostResourceId string = ''
@description('Optional. Existing dedicated host IDs; one applies to all VMs, otherwise entries align with the VM names. Takes precedence over host groups.')
param dedicatedHostResourceIds string[] = []
@description('Optional. Resource ID of an existing disk access resource; empty selects DenyAll instead of AllowPrivate network access.')
param diskAccessId string = ''
@description('Required. OS disk size in GB; zero preserves the image disk size.')
param diskSizeGB int
@description('Required. Managed OS disk storage account type.')
param diskSku string
@secure()
@description('Required. Domain account password used when domain operations are selected; otherwise pass an empty string.')
param domainJoinUserPassword string
@secure()
@description('Required. Domain account UPN used when domain operations are selected; otherwise pass an empty string.')
param domainJoinUserPrincipalName string
@description('Required. DNS domain name for selected domain operations; otherwise pass an empty string.')
param domainName string
@description('Required. Whether to enable accelerated networking on each session-host NIC.')
param enableAcceleratedNetworking bool
@description('Required. Whether to add an IPv6 configuration alongside IPv4 on each session-host NIC.')
param enableIPv6 bool
@description('Required. Whether to deploy Azure Monitor Agent and any supplied data collection associations.')
param enableMonitoring bool
@description('Required. Whether to enable encryption at host on the deployed VMs.')
param encryptionAtHost bool
@description('Optional. Resource ID of an existing disk encryption set; empty uses platform-managed disk encryption.')
param diskEncryptionSetResourceId string = ''
@description('Required. Whether to forward enabled FSLogix configuration and required storage inputs to session-host initialization.')
param fslogixConfigureSessionHosts bool
@description('Required. FSLogix container selection forwarded to initialization; names containing CloudCache select its CloudCache argument.')
param fslogixContainerType string
@description('Required. Ordered share name strings for initialization, with profile before Office when both are present.')
param fslogixFileShareNames string[]
@description('Required. Array of existing local NetApp volume IDs, empty or one per share in profile-then-Office order.')
param fslogixLocalNetAppVolumeResourceIds string[]
@description('Required. Array of existing local Azure Files storage account IDs forwarded to FSLogix initialization.')
param fslogixLocalStorageAccountResourceIds string[]
@description('Required. Array of group name strings forwarded as the initialization script OSSGroups argument.')
param fslogixOSSGroups string[]
@description('Required. Array of existing remote NetApp volume IDs, empty or one per share in profile-then-Office order.')
param fslogixRemoteNetAppVolumeResourceIds string[]
@description('Required. Array of existing remote Azure Files storage account IDs for FSLogix Cloud Cache initialization.')
param fslogixRemoteStorageAccountResourceIds string[]
@description('Required. Profile container size in MB forwarded to session-host initialization.')
param fslogixSizeInMBs int
@description('Required. Storage backend name forwarded to initialization, AzureFiles or AzureNetAppFiles.')
param fslogixStorageService string
@description('Required. Whether to enable the VM hibernation additional capability.')
param hibernationEnabled bool
@description('Required. Resource ID of the existing AVD host pool with an active registration token for VM initialization; also used for ownership tags.')
param hostPoolResourceId string
@description('Required. Selected session-host or SMB identity mode used to choose domain, Entra, and storage configuration paths.')
param identitySolution string
@description('Required. Marketplace image offer used when neither imageReference nor customImageResourceId is supplied.')
param imageOffer string
@description('Required. Marketplace image publisher used when neither imageReference nor customImageResourceId is supplied.')
param imagePublisher string
@description('Optional. Explicit Compute image reference object; when empty, customImageResourceId or the marketplace publisher, offer, and SKU are used.')
param imageReference object = {}
@description('Required. Marketplace image SKU used when neither imageReference nor customImageResourceId is supplied.')
param imageSku string
@description('Required. Whether to deploy the Guest Attestation extension on each session host.')
param integrityMonitoring bool
@description('Required. Whether to pass the Intune MDM identifier to applicable Entra sign-in and initialization configuration.')
param intuneEnrollment bool
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. NIC name pattern containing SHNAME; empty uses the session-host name unchanged.')
param virtualMachineNicNameConv string
@description('Required. OS disk name pattern containing SHNAME; empty uses the shared naming policy disk pattern.')
param virtualMachineDiskNameConv string
@description('Required. Distinguished name of the target organizational unit for selected domain operations; empty uses the domain default.')
param ouPath string
@description('Optional. Per-VM preferred zone strings forwarded to each VM batch; nonempty entries override zone rotation.')
param preferredZones string[] = []
@description('Optional. Resource ID of an existing Recovery Services vault; empty disables backup registration.')
param recoveryServicesVaultResourceId string = ''
@description('Required. Whether to enable secure boot for a non-Standard VM security type.')
param secureBootEnabled bool
@description('Required. VM security type; Standard omits the security type and UEFI settings from the request.')
param securityType string
@description('Required. Ordered artifact customization objects with name and blobNameOrUri, plus optional arguments and successExitCodes; empty skips customization commands.')
param sessionHostCustomizations artifactCustomizationType[]
@description('Required. Ordered session-host computer name strings, each ending in the numeric suffix used for placement.')
param sessionHostNames string[]
@description('Required. Resource ID of the existing session-host subnet used by each NIC.')
param subnetResourceId string
@description('Required. Tag bags keyed by Azure resource type; each bag is applied to resources of that type.')
param tags object
@description('Required. Windows time zone identifier forwarded to the initialization script.')
param timeZone string
@secure()
@description('Required. Local administrator password for the deployed VM.')
param virtualMachineAdminPassword string
@secure()
@description('Required. Local administrator account name for the deployed VM.')
param virtualMachineAdminUserName string
@description('Required. VM resource name pattern containing SHNAME; empty uses the session-host name unchanged.')
param virtualMachineNameConv string
@description('Required. Azure VM size for each session host.')
param virtualMachineSize string
@description('Optional. Name of the existing VM backup policy in the selected Recovery Services vault.')
param vmBackupPolicyName string = 'AvdPolicyVm'
@description('Optional. Number of trailing characters parsed as the numeric suffix of each sessionHostNames entry.')
param vmNameIndexLength int = 2
@description('Required. Whether to enable virtual TPM for a non-Standard VM security type.')
param vTpmEnabled bool

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

// === GPU detection ===
var hasAmdGpu = contains(virtualMachineSize, 'Standard_NV') && (endsWith(virtualMachineSize, 'as_v4') || endsWith(virtualMachineSize, '_V710_v5'))
var hasNvidiaGpu = contains(virtualMachineSize, 'Standard_NV') && endsWith(virtualMachineSize, '_A10_v5')

// === Batching logic ===
// Dynamically calculate max VMs per batch based on resources per VM
var baseResourcesPerVM = 11
var monitoringResourcesPerVM = enableMonitoring ? 3 : 0
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
  : (startsWith(cloud, 'us') ? 'https://aka.${cloudSuffix}/RdAgentBootLoader_latest' : 'https://go.microsoft.com/fwlink/?linkid=2311028')
var agentUrl = !empty(agentDownloadUrl)
  ? agentDownloadUrl
  : (startsWith(cloud, 'us') ? 'https://aka.${cloudSuffix}/RdAgent_latest' : 'https://go.microsoft.com/fwlink/?linkid=2310011')
resource artifactsUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = if (!empty(artifactsUserAssignedIdentityResourceId)) {
  scope: resourceGroup(split(artifactsUserAssignedIdentityResourceId, '/')[2], split(artifactsUserAssignedIdentityResourceId, '/')[4])
  name: last(split(artifactsUserAssignedIdentityResourceId, '/'))
}

module availabilitySets '../../resourceModules/compute/availabilitySets/deploy.bicep' = [for i in range(0, availabilitySetsCount): if (availability == 'AvailabilitySets') {
  params: {
    name: replace(availabilitySetNameConv, '##', padLeft((i + availabilitySetsIndex) + 1, 2, '0'))
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
    location: location
    skuName: 'Aligned'
    tags: union({'cm-resource-parent': hostPoolResourceId}, tags[?'Microsoft.Compute/availabilitySets'] ?? {})
  }
}]

module netAppVolumeFqdns '../fslogix/modules/getNetAppVolumeSmbServerFqdns.bicep' = if (fslogixConfigureSessionHosts && (!empty(fslogixLocalNetAppVolumeResourceIds) || !empty(fslogixRemoteNetAppVolumeResourceIds))) {
  scope: subscription()
  params: {
    localNetAppVolumeResourceIds: fslogixLocalNetAppVolumeResourceIds
    remoteNetAppVolumeResourceIds: fslogixRemoteNetAppVolumeResourceIds
    shareNames: fslogixFileShareNames
  }
}

@batchSize(5)
module virtualMachines 'virtualMachines.bicep' = [for i in range(1, sessionHostBatchCount): {
  params: {
    agentBootLoaderDownloadUrl: agentBootLoaderUrl
    agentDownloadUrl: agentUrl
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
    diskEncryptionSetResourceId: diskEncryptionSetResourceId
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
    hasAmdGpu: hasAmdGpu
    hasNvidiaGpu: hasNvidiaGpu
    hostPoolResourceId: hostPoolResourceId
    identitySolution: identitySolution
    imageReference: effectiveImageReference
    customImageLicenseType: customImageLicenseType
    integrityMonitoring: integrityMonitoring
    intuneEnrollment: intuneEnrollment
    location: location
    virtualMachineNicNameConv: virtualMachineNicNameConv
    virtualMachineDiskNameConv: virtualMachineDiskNameConv
    ouPath: ouPath
    sessionHostCustomizations: sessionHostCustomizations
    sessionHostNames: [for j in range(0, i == sessionHostBatchCount && divisionRemainderValue > 0 ? divisionRemainderValue : maxVMsPerDeployment): sessionHostNames[(i - 1) * maxVMsPerDeployment + j]]
    vmNumbers: [for j in range(0, i == sessionHostBatchCount && divisionRemainderValue > 0 ? divisionRemainderValue : maxVMsPerDeployment): allVmNumbers[(i - 1) * maxVMsPerDeployment + j]]
    secureBootEnabled: secureBootEnabled
    securityType: securityType
    subnetResourceId: subnetResourceId
    tags: tags
    timeZone: timeZone
    virtualMachineAdminPassword: virtualMachineAdminPassword
    virtualMachineAdminUserName: virtualMachineAdminUserName
    virtualMachineNameConv: virtualMachineNameConv
    virtualMachineSize: virtualMachineSize
    vTpmEnabled: vTpmEnabled
    recoveryServicesVaultResourceId: recoveryServicesVaultResourceId
    vmBackupPolicyName: vmBackupPolicyName
  }
  dependsOn: [
    availabilitySets
  ]
}]

module getFlattenedVmNamesArray 'flattenVirtualMachineNames.bicep' = {
  params: {
    virtualMachineNamesPerBatch: [for i in range(1, sessionHostBatchCount): virtualMachines[i - 1].outputs.virtualMachineNames]
  }
}

@description('Flat VM resource name array preserving batch order and the order of sessionHostNames within each batch.')
output virtualMachineNames array = getFlattenedVmNamesArray.outputs.virtualMachineNames
