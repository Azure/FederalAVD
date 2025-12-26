param artifactsContainerUri string
param artifactsUserAssignedIdentityResourceId string
param availability string
param availabilitySetNamePrefix string
param availabilityZones array
param avdAgentsDSCPackage string
param avdInsightsDataCollectionRulesResourceId string
param confidentialVMOSDiskEncryption bool
param credentialsKeyVaultResourceId string
param dataCollectionEndpointResourceId string
param dedicatedHostGroupResourceId string
param dedicatedHostGroupZones array
param dedicatedHostResourceId string
param diskSizeGB int
param diskSku string
param domainName string
param enableAcceleratedNetworking bool
param encryptionAtHost bool
param existingDiskAccessResourceId string
param existingDiskEncryptionSetResourceId string
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
param hostPoolResourceId string
param identitySolution string
param imageReference object
param integrityMonitoring bool
param intuneEnrollment bool
param location string
param enableMonitoring bool
param networkInterfaceNameConv string
param osDiskNameConv string
param ouPath string
param secureBootEnabled bool
param securityDataCollectionRulesResourceId string
param securityType string
param sessionHostCustomizations array
param sessionHostNames array
param vmNameIndexLength int
param subnetResourceId string
param tags object
@description('DO NOT MODIFY THIS VALUE! The timeStamp is needed to differentiate deployments for certain Azure resources and must be set using a parameter.')
param timeStamp string = utcNow('yyyyMMddHHmmss')
param timeZone string
param virtualMachineNameConv string
param virtualMachineNamePrefix string
param virtualMachineSize string
param vTpmEnabled bool
param vmInsightsDataCollectionRulesResourceId string

// Variables

var deploymentSuffix = startsWith(deployment().name, 'Microsoft.Template-') ? substring(deployment().name, 19, 14) : timeStamp

var sessionHostRegistrationDSCStorageAccount = startsWith(environment().name, 'USN')
  ? 'wvdexportalcontainer'
  : 'wvdportalstorageblob'
var sessionHostRegistrationDSCUrl = startsWith(avdAgentsDSCPackage, 'https://')
  ? avdAgentsDSCPackage
  : 'https://${sessionHostRegistrationDSCStorageAccount}.blob.${environment().suffixes.storage}/galleryartifacts/${avdAgentsDSCPackage}'

var confidentialVMOSDiskEncryptionType = confidentialVMOSDiskEncryption ? 'DiskWithVMGuestState' : 'VMGuestStateOnly'

// Batching logic: Deploy max 40 VMs per batch
var maxVMsPerDeployment = 40
var totalVMCount = length(sessionHostNames)
var divisionValue = totalVMCount / maxVMsPerDeployment
var divisionRemainderValue = totalVMCount % maxVMsPerDeployment
var sessionHostBatchCount = divisionRemainderValue > 0 ? divisionValue + 1 : divisionValue

// Availability Set logic: Max 200 VMs per availability set
// Extract VM numbers from names to determine which availability sets are needed
var indexPositionForAvSet = indexOf(virtualMachineNameConv, '###')
var vmNumbersForAvSet = [
  for name in sessionHostNames: int(substring(name, indexPositionForAvSet, vmNameIndexLength))
]
var minVmNumber = min(vmNumbersForAvSet)
var maxVmNumber = max(vmNumbersForAvSet)
var maxAvSetMembers = 200
var beginAvSetRange = minVmNumber / maxAvSetMembers
var endAvSetRange = maxVmNumber / maxAvSetMembers
var calculatedAvailabilitySetsCount = endAvSetRange - beginAvSetRange + 1
var calculatedAvailabilitySetsIndex = beginAvSetRange

// create new arrays that always contain the profile-containers volume as the first element.
var localNetAppProfileContainerVolumeResourceIds = !empty(fslogixLocalNetAppVolumeResourceIds)
  ? filter(fslogixLocalNetAppVolumeResourceIds, id => contains(id, fslogixFileShareNames[0]))
  : []
var localNetAppOfficeContainerVolumeResourceIds = !empty(fslogixLocalNetAppVolumeResourceIds) && length(fslogixFileShareNames) > 1
  ? filter(fslogixLocalNetAppVolumeResourceIds, id => contains(id, fslogixFileShareNames[1]))
  : []
var sortedLocalNetAppResourceIds = union(
  localNetAppProfileContainerVolumeResourceIds,
  localNetAppOfficeContainerVolumeResourceIds
)
var remoteNetAppProfileContainerVolumeResourceIds = !empty(fslogixRemoteNetAppVolumeResourceIds)
  ? filter(fslogixRemoteNetAppVolumeResourceIds, id => contains(id, fslogixFileShareNames[0]))
  : []
var remoteNetAppOfficeContainerVolumeResourceIds = !empty(fslogixRemoteNetAppVolumeResourceIds) && length(fslogixFileShareNames) > 1
  ? filter(fslogixRemoteNetAppVolumeResourceIds, id => !contains(id, fslogixFileShareNames[0]))
  : []
var sortedRemoteNetAppResourceIds = union(
  remoteNetAppProfileContainerVolumeResourceIds,
  remoteNetAppOfficeContainerVolumeResourceIds
)

// Existing Key Vault for secrets
resource kvCredentials 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: last(split(credentialsKeyVaultResourceId, '/'))
  scope: resourceGroup(split(credentialsKeyVaultResourceId, '/')[2], split(credentialsKeyVaultResourceId, '/')[4])
}

module artifactsUserAssignedIdentity 'modules/getUserAssignedIdentity.bicep' = if (!empty(artifactsUserAssignedIdentityResourceId)) {
  scope: subscription()
  name: 'ArtifactsUserAssignedIdentity-${deploymentSuffix}'
  params: {
    userAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
  }
}

module availabilitySets '../../../../sharedModules/resources/compute/availability-set/main.bicep' = [
  for i in range(0, calculatedAvailabilitySetsCount): if (availability == 'AvailabilitySets') {
    name: '${availabilitySetNamePrefix}${padLeft((i + calculatedAvailabilitySetsIndex), 2, '0')}-${deploymentSuffix}'
    params: {
      name: '${availabilitySetNamePrefix}${padLeft((i + calculatedAvailabilitySetsIndex), 2, '0')}'
      platformFaultDomainCount: 2
      platformUpdateDomainCount: 5
      proximityPlacementGroupResourceId: ''
      location: location
      skuName: 'Aligned'
      tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Compute/availabilitySets'] ?? {})
    }
  }
]

module localNetAppVolumes 'modules/getNetAppVolumeSmbServerFqdn.bicep' = [
  for i in range(0, length(sortedLocalNetAppResourceIds)): if (!empty(sortedLocalNetAppResourceIds)) {
    scope: subscription()
    name: 'LocalNetAppVolumes-${i}-${deploymentSuffix}'
    params: {
      netAppVolumeResourceId: sortedLocalNetAppResourceIds[i]
    }
  }
]

module remoteNetAppVolumes 'modules/getNetAppVolumeSmbServerFqdn.bicep' = [
  for i in range(0, length(sortedRemoteNetAppResourceIds)): if (!empty(sortedRemoteNetAppResourceIds)) {
    scope: subscription()
    name: 'RemoteNetAppVolumes-${i}-${deploymentSuffix}'
    params: {
      netAppVolumeResourceId: sortedRemoteNetAppResourceIds[i]
    }
  }
]

@batchSize(5)
module virtualMachines 'modules/virtualMachines.bicep' = [
  for i in range(1, sessionHostBatchCount): {
    name: 'VirtualMachines-Batch-${i-1}-${deploymentSuffix}'
    params: {
      artifactsContainerUri: artifactsContainerUri
      artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
      artifactsUserAssignedIdentityClientId: empty(artifactsUserAssignedIdentityResourceId)
        ? ''
        : artifactsUserAssignedIdentity!.outputs.clientId
      availability: availability
      availabilityZones: availabilityZones
      availabilitySetNamePrefix: availabilitySetNamePrefix
      avdInsightsDataCollectionRulesResourceId: avdInsightsDataCollectionRulesResourceId
      confidentialVMOSDiskEncryptionType: confidentialVMOSDiskEncryptionType
      dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
      dedicatedHostGroupResourceId: dedicatedHostGroupResourceId
      dedicatedHostGroupZones: dedicatedHostGroupZones
      dedicatedHostResourceId: dedicatedHostResourceId
      diskAccessId: existingDiskAccessResourceId
      diskEncryptionSetResourceId: existingDiskEncryptionSetResourceId
      diskSizeGB: diskSizeGB
      diskSku: diskSku
      domainJoinUserPassword: kvCredentials.getSecret('DomainJoinUserPassword')
      domainJoinUserPrincipalName: kvCredentials.getSecret('DomainJoinUserPrincipalName')
      domainName: domainName
      enableAcceleratedNetworking: enableAcceleratedNetworking
      enableMonitoring: enableMonitoring
      encryptionAtHost: encryptionAtHost
      fslogixConfigureSessionHosts: fslogixConfigureSessionHosts
      fslogixContainerType: fslogixContainerType
      fslogixFileShareNames: fslogixFileShareNames
      fslogixOSSGroups: fslogixOSSGroups
      fslogixLocalNetAppServerFqdns: [
        for j in range(0, length(sortedLocalNetAppResourceIds)): localNetAppVolumes[j]!.outputs.smbServerFqdn
      ]
      fslogixLocalStorageAccountResourceIds: fslogixLocalStorageAccountResourceIds
      fslogixRemoteNetAppServerFqdns: [
        for j in range(0, length(sortedRemoteNetAppResourceIds)): remoteNetAppVolumes[j]!.outputs.smbServerFqdn
      ]
      fslogixRemoteStorageAccountResourceIds: fslogixRemoteStorageAccountResourceIds
      fslogixSizeInMBs: fslogixSizeInMBs
      fslogixStorageService: fslogixStorageService
      hostPoolResourceId: hostPoolResourceId
      identitySolution: identitySolution
      imageReference: imageReference
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
      sessionHostNames: i == sessionHostBatchCount && divisionRemainderValue > 0
        ? take(skip(sessionHostNames, (i - 1) * maxVMsPerDeployment), divisionRemainderValue)
        : take(skip(sessionHostNames, (i - 1) * maxVMsPerDeployment), maxVMsPerDeployment)
      vmNameIndexLength: vmNameIndexLength
      sessionHostRegistrationDSCUrl: sessionHostRegistrationDSCUrl
      subnetResourceId: subnetResourceId
      tags: tags
      deploymentSuffix: deploymentSuffix
      timeZone: timeZone
      virtualMachineAdminPassword: kvCredentials.getSecret('VirtualMachineAdminPassword')
      virtualMachineAdminUserName: kvCredentials.getSecret('VirtualMachineAdminUserName')
      virtualMachineNameConv: virtualMachineNameConv
      virtualMachineNamePrefix: virtualMachineNamePrefix
      virtualMachineSize: virtualMachineSize
      vmInsightsDataCollectionRulesResourceId: vmInsightsDataCollectionRulesResourceId
      vTpmEnabled: vTpmEnabled
    }
    dependsOn: [
      availabilitySets
    ]
  }
]
