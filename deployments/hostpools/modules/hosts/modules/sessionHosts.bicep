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
param dedicatedHostGroupResourceIds array = []
param dedicatedHostResourceId string = ''
param dedicatedHostResourceIds array = []
param deploymentSuffix string
param diskAccessId string = ''
param diskSizeGB int
param diskSku string
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param domainName string
param enableAcceleratedNetworking bool
param enableIPv6 bool
param enableMonitoring bool
param encryptionAtHost bool
param diskEncryptionSetResourceId string = ''
param fslogixConfigureSessionHosts bool
param fslogixContainerType string
param fslogixFileShareNames array
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
param imageReference object = {}
param imageSku string
param integrityMonitoring bool
param intuneEnrollment bool
param location string
param networkInterfaceNameConv string
param osDiskNameConv string
param ouPath string
param preferredZones array = []
param recoveryServicesVaultResourceId string = ''
param secureBootEnabled bool
param securityType string
param sessionHostCustomizations array
param sessionHostNames array
param subnetResourceId string
param tags object
param timeZone string
@secure()
param virtualMachineAdminPassword string
@secure()
param virtualMachineAdminUserName string
param virtualMachineNameConv string
param virtualMachineSize string
param vmBackupPolicyName string = 'AvdPolicyVm'
param vmNameIndexLength int = 2
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
  : (startsWith(cloud, 'us') ? 'https://aka.${cloudSuffix}/avdRDAgentBootLoader' : 'https://go.microsoft.com/fwlink/?linkid=2311028')
var agentUrl = !empty(agentDownloadUrl)
  ? agentDownloadUrl
  : (startsWith(cloud, 'us') ? 'https://aka.${cloudSuffix}/avdRDAgent' : 'https://go.microsoft.com/fwlink/?linkid=2310011')
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
    vTpmEnabled: vTpmEnabled
    recoveryServicesVaultResourceId: recoveryServicesVaultResourceId
    vmBackupPolicyName: vmBackupPolicyName
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
