@description('URI of the storage container holding custom artifacts for session host configuration.')
param artifactsContainerUri string

@description('Resource ID of the user-assigned managed identity with access to the artifacts container.')
param artifactsUserAssignedIdentityResourceId string

@description('Availability option for session hosts. Valid values: AvailabilitySets, AvailabilityZones, None.')
param availability string

@description('Naming prefix for availability sets when availability is set to AvailabilitySets.')
param availabilitySetNamePrefix string

@description('Array of availability zones to distribute session hosts across when availability is set to AvailabilityZones.')
param availabilityZones array

@description('Name of the DSC package used to register session hosts with the AVD host pool.')
param avdAgentsDSCPackage string

@description('Resource ID of the data collection rule for AVD Insights monitoring.')
param avdInsightsDataCollectionRulesResourceId string

@description('Enable confidential VM OS disk encryption with VM guest state. Only applicable for confidential VMs.')
param confidentialVMOSDiskEncryption bool

@description('Resource ID of the Key Vault containing credentials for domain join and VM admin accounts.')
param credentialsKeyVaultResourceId string

@description('Resource ID of the data collection endpoint for Azure Monitor agent.')
param dataCollectionEndpointResourceId string

@description('Resource ID of the dedicated host group for session host placement.')
param dedicatedHostGroupResourceId string

@description('Array of availability zones for the dedicated host group.')
param dedicatedHostGroupZones array

@description('Resource ID of a specific dedicated host for session host placement.')
param dedicatedHostResourceId string

@description('Resource ID of the disk encryption set for encrypting managed disks with customer-managed keys.')
param diskEncryptionSetResourceId string

@description('Size of the OS disk in GB.')
param diskSizeGB int

@description('SKU for the managed OS disk. Examples: Premium_LRS, StandardSSD_LRS, Standard_LRS.')
param diskSku string

@description('Fully qualified domain name (FQDN) for Active Directory domain join.')
param domainName string

@description('Enable accelerated networking on network interfaces for improved network performance.')
param enableAcceleratedNetworking bool

@description('Enable encryption at host for additional data encryption on the VM host.')
param encryptionAtHost bool

@description('Array of FSLogix file share names. First element is profile-containers, second (if present) is office-containers.')
param fslogixFileShareNames array

@description('Configure FSLogix on session hosts during deployment.')
param fslogixConfigureSessionHosts bool

@description('Type of FSLogix container. Valid values: ProfileContainer, OfficeContainer, ProfileOfficeContainer.')
param fslogixContainerType string

@description('Array of resource IDs for local Azure NetApp Files volumes used for FSLogix containers.')
param fslogixLocalNetAppVolumeResourceIds array

@description('Array of resource IDs for local storage accounts used for FSLogix containers.')
param fslogixLocalStorageAccountResourceIds array

@description('Array of Active Directory security groups for FSLogix Office 365 container redirection.')
param fslogixOSSGroups array

@description('Array of resource IDs for remote Azure NetApp Files volumes used for FSLogix containers in DR scenarios.')
param fslogixRemoteNetAppVolumeResourceIds array

@description('Array of resource IDs for remote storage accounts used for FSLogix containers in DR scenarios.')
param fslogixRemoteStorageAccountResourceIds array

@description('Size limit in MB for FSLogix containers. 0 = no limit.')
param fslogixSizeInMBs int

@description('Storage service type for FSLogix. Valid values: AzureFiles, AzureNetAppFiles.')
param fslogixStorageService string

@description('Resource ID of the AVD host pool that session hosts will be registered to.')
param hostPoolResourceId string

@description('Identity solution for session hosts. Valid values: ActiveDirectoryDomainServices, EntraID, EntraIDIntuneEnrollment.')
param identitySolution string

@description('Image reference object containing either marketplace image details or compute gallery image version resource ID.')
param imageReference object

@description('Enable Microsoft Defender for Cloud integrity monitoring on session hosts.')
param integrityMonitoring bool

@description('Enroll session hosts in Microsoft Intune. Only applicable with EntraIDIntuneEnrollment identity solution.')
param intuneEnrollment bool

@description('Azure region where session hosts will be deployed.')
param location string

@description('Enable Azure Monitor VM insights on session hosts.')
param enableMonitoring bool

@description('Naming convention pattern for network interfaces.')
param networkInterfaceNameConv string

@description('Naming convention pattern for OS managed disks.')
param osDiskNameConv string

@description('Organizational Unit (OU) path in Active Directory for computer objects. Leave empty for default Computers container.')
param ouPath string

@description('Enable secure boot for generation 2 VMs.')
param secureBootEnabled bool

@description('Resource ID of the data collection rule for security monitoring with Microsoft Defender for Cloud.')
param securityDataCollectionRulesResourceId string

@description('Security type for VMs. Valid values: Standard, TrustedLaunch, ConfidentialVM.')
param securityType string

@description('Array of custom script extension configurations for additional session host customization.')
param sessionHostCustomizations array

@description('Number of digits used in the session host name index. Determines how many characters from the end represent the VM number.')
param sessionHostNameIndexLength int

@description('Array of session host names to deploy. Names should follow the pattern <prefix><index> where index length matches sessionHostNameIndexLength.')
param sessionHostNames array

@description('Resource ID of the subnet where session host network interfaces will be placed.')
param subnetResourceId string

@description('Tags to apply to deployed resources. Organized by resource type.')
param tags object

@description('DO NOT MODIFY THIS VALUE! The timeStamp is needed to differentiate deployments for certain Azure resources and must be set using a parameter.')
param timeStamp string = utcNow('yyyyMMddHHmmss')

@description('Time zone for session hosts. Use Windows time zone format (e.g., Eastern Standard Time, Pacific Standard Time).')
param timeZone string

@description('Naming convention pattern for virtual machines.')
param virtualMachineNameConv string

@description('Azure VM size for session hosts. Examples: Standard_D4s_v5, Standard_D8s_v5.')
param virtualMachineSize string

@description('Enable virtual Trusted Platform Module (vTPM) for generation 2 VMs.')
param vTpmEnabled bool

@description('Resource ID of the data collection rule for VM Insights performance and dependency monitoring.')
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
var vmNumbersForAvSet = [
  for name in sessionHostNames: int(substring(name, length(name)-sessionHostNameIndexLength, sessionHostNameIndexLength))
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
    name: '${take(deployment().name, 10)}-VMs-Batch-${i-1}-${deploymentSuffix}'
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
      deploymentSuffix: deploymentSuffix
      diskEncryptionSetResourceId: diskEncryptionSetResourceId
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
      sessionHostNameIndexLength: sessionHostNameIndexLength
      sessionHostNames: i == sessionHostBatchCount && divisionRemainderValue > 0
        ? take(skip(sessionHostNames, (i - 1) * maxVMsPerDeployment), divisionRemainderValue)
        : take(skip(sessionHostNames, (i - 1) * maxVMsPerDeployment), maxVMsPerDeployment)
      sessionHostRegistrationDSCUrl: sessionHostRegistrationDSCUrl
      subnetResourceId: subnetResourceId
      tags: tags
      timeZone: timeZone
      virtualMachineAdminPassword: kvCredentials.getSecret('VirtualMachineAdminPassword')
      virtualMachineAdminUserName: kvCredentials.getSecret('VirtualMachineAdminUserName')
      virtualMachineNameConv: virtualMachineNameConv
      virtualMachineSize: virtualMachineSize
      vmInsightsDataCollectionRulesResourceId: vmInsightsDataCollectionRulesResourceId
      vTpmEnabled: vTpmEnabled
    }
    dependsOn: [
      availabilitySets
    ]
  }
]
