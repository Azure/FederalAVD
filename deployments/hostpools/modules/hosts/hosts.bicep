targetScope = 'subscription'

param resourceGroupHosts string
param agentBootLoaderDownloadUrl string = ''
param agentDownloadUrl string = ''
param avdAgentDscPackage string
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
param existingDiskEncryptionSetResourceId string = ''
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
param networkInterfaceNameConv string
param osDiskNameConv string
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
param recoveryServicesVaultResourceId string = ''
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
    vTpmEnabled: vTpmEnabled
    recoveryServicesVaultResourceId: recoveryServicesVaultResourceId
    vmBackupPolicyName: vmBackupPolicyName
  }
}

output virtualMachineNames array = sessionHosts.outputs.virtualMachineNames
