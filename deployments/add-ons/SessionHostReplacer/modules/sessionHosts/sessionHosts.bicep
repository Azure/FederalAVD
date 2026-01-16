@description('URI of the storage container holding custom artifacts for session host configuration.')
param artifactsContainerUri string = ''

@description('Resource ID of the user-assigned managed identity with access to the artifacts container.')
param artifactsUserAssignedIdentityResourceId string = ''

@allowed([
  'AvailabilitySets'
  'AvailabilityZones'
  'None'
])
@description('Availability option for session hosts. Valid values: AvailabilitySets, AvailabilityZones, None.')
param availability string = 'None'

@description('Naming convention for availability sets when availability is set to AvailabilitySets. Use ## as placeholder for the index.')
param availabilitySetNameConv string = ''

@description('Array of availability zones to distribute session hosts across when availability is set to AvailabilityZones.')
param availabilityZones array = []

@description('Name of the DSC package used to register session hosts with the AVD host pool.')
param avdAgentsDSCPackage string

@description('Resource ID of the data collection rule for AVD Insights monitoring.')
param avdInsightsDataCollectionRulesResourceId string = ''

@description('Enable confidential VM OS disk encryption with VM guest state. Only applicable for confidential VMs.')
param confidentialVMOSDiskEncryption bool = false

@description('Resource ID of the Key Vault containing credentials for domain join and VM admin accounts.')
param credentialsKeyVaultResourceId string

@description('Resource ID of the data collection endpoint for Azure Monitor agent.')
param dataCollectionEndpointResourceId string = ''

@description('Array of resource IDs for dedicated host groups. One per session host, or single value applied to all, or empty string for VMs without assignment.')
param dedicatedHostGroupResourceIds array = []

@description('Array of resource IDs for specific dedicated hosts. One per session host, or single value applied to all, or empty string for VMs without assignment.')
param dedicatedHostResourceIds array = []

@description('Array of preferred zones for each session host. One per session host (as array like ["1"]), or empty for VMs without specific zone preference.')
param preferredZones array = []

@description('Resource ID of the disk encryption set for encrypting managed disks with customer-managed keys.')
param diskEncryptionSetResourceId string = ''

@allowed([
  0
  32
  64
  128
  256
  512
  1024
  2048
])
@description('Size of the OS disk in GB.')
param diskSizeGB int = 0

@allowed([
  'Standard_LRS'
  'StandardSSD_LRS'
  'Premium_LRS'
])
@description('SKU for the managed OS disk. Examples: Premium_LRS, StandardSSD_LRS, Standard_LRS.')
param diskSku string = 'Premium_LRS'

@description('Fully qualified domain name (FQDN) for Active Directory domain join.')
param domainName string = ''

@description('Enable accelerated networking on network interfaces for improved network performance.')
param enableAcceleratedNetworking bool = true

@description('Enable IPv6 on network interfaces.')
param enableIPv6 bool = false

@description('Enable encryption at host for additional data encryption on the VM host.')
param encryptionAtHost bool = true

@description('Configure FSLogix on session hosts during deployment.')
param fslogixConfigureSessionHosts bool = false

@allowed([
  'CloudCacheProfileContainer'
  'CloudCacheProfileOfficeContainer'
  'ProfileContainer'
  'ProfileOfficeContainer'
])
@description('Type of FSLogix container. Valid values: CloudCacheProfileContainer, CloudCacheProfileOfficeContainer, ProfileContainer, ProfileOfficeContainer.')
param fslogixContainerType string = 'ProfileContainer'

@description('Array of resource IDs for local Azure NetApp Files volumes used for FSLogix containers.')
param fslogixLocalNetAppVolumeResourceIds array = []

@description('Array of resource IDs for local storage accounts used for FSLogix containers.')
param fslogixLocalStorageAccountResourceIds array = []

@description('Array of Active Directory security groups for FSLogix Office 365 container redirection.')
param fslogixOSSGroups array = []

@description('Array of resource IDs for remote Azure NetApp Files volumes used for FSLogix containers in DR scenarios.')
param fslogixRemoteNetAppVolumeResourceIds array = []

@description('Array of resource IDs for remote storage accounts used for FSLogix containers in DR scenarios.')
param fslogixRemoteStorageAccountResourceIds array = []

@description('Size limit in MB for FSLogix containers. 0 = no limit.')
param fslogixSizeInMBs int = 30720

@allowed([
  'AzureFiles'
  'AzureNetAppFiles'
])
@description('Storage service type for FSLogix.')
param fslogixStorageService string = 'AzureFiles'

@description('Resource ID of the AVD host pool that session hosts will be registered to.')
param hostPoolResourceId string

@allowed([
  'ActiveDirectoryDomainServices'
  'EntraDomainServices'
  'EntraId'
  'EntraKerberos-CloudOnly'
  'EntraKerberos-Hybrid'
])
@description('Identity solution for session hosts. Valid values: ActiveDirectoryDomainServices, EntraDomainServices, EntraId, EntraKerberos-CloudOnly, EntraKerberos-Hybrid.')
param identitySolution string

@description('Image reference object containing either marketplace image details or compute gallery image version resource ID.')
param imageReference object

@description('Enable Microsoft Defender for Cloud integrity monitoring on session hosts.')
param integrityMonitoring bool = false

@description('Enroll session hosts in Microsoft Intune. Only applicable with EntraIDIntuneEnrollment identity solution.')
param intuneEnrollment bool = false

@description('Azure region where session hosts will be deployed.')
param location string = resourceGroup().location

@description('Enable Azure Monitor VM insights on session hosts.')
param enableMonitoring bool = false

@description('Naming convention pattern for network interfaces.')
param networkInterfaceNameConv string = ''

@description('Naming convention pattern for OS managed disks.')
param osDiskNameConv string = ''

@description('Organizational Unit (OU) path in Active Directory for computer objects. Leave empty for default Computers container.')
param ouPath string = ''

@description('Enable secure boot for generation 2 VMs.')
param secureBootEnabled bool = true

@allowed([
  'Standard'
  'TrustedLaunch'
  'ConfidentialVM'
])
@description('Security type for VMs. Valid values: Standard, TrustedLaunch, ConfidentialVM.')
param securityType string = 'TrustedLaunch'

@description('Array of custom script extension configurations for additional session host customization.')
param sessionHostCustomizations array = []

@minValue(1)
@maxValue(4)
@description('Number of digits used in the session host name index. Determines how many characters from the end represent the VM number.')
param sessionHostNameIndexLength int = 2

@description('Array of session host names to deploy. Names should follow the pattern <prefix><index> where index length matches sessionHostNameIndexLength.')
param sessionHostNames array

@description('Resource ID of the subnet where session host network interfaces will be placed.')
param subnetResourceId string

@description('Tags to apply to deployed resources. Organized by resource type.')
param tags object = {}

@description('Time zone for session hosts. Use Windows time zone format (e.g., Eastern Standard Time, Pacific Standard Time).')
param timeZone string = 'Eastern Standard Time'

@description('Naming convention pattern for virtual machines.')
param virtualMachineNameConv string = ''

@description('Azure VM size for session hosts. Examples: Standard_D4s_v5, Standard_D8s_v5.')
param virtualMachineSize string

@description('Enable virtual Trusted Platform Module (vTPM) for generation 2 VMs.')
param vTpmEnabled bool = true

@description('Resource ID of the data collection rule for VM Insights performance and dependency monitoring.')
param vmInsightsDataCollectionRulesResourceId string = ''

// Variables

var avSetNameConv = empty(availabilitySetNameConv) ? 'as-${substring(sessionHostNames[0], 0, length(sessionHostNames[0])-sessionHostNameIndexLength)}-##' : availabilitySetNameConv

var deploymentSuffix = uniqueString(deployment().name)

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

var fslogixFileShareNames = contains(fslogixContainerType, 'Office') ? ['profile-containers', 'office-containers'] : ['profile-containers']

// Existing Key Vault for secrets
resource kvCredentials 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: last(split(credentialsKeyVaultResourceId, '/'))
  scope: resourceGroup(split(credentialsKeyVaultResourceId, '/')[2], split(credentialsKeyVaultResourceId, '/')[4])
}

resource artifactsUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = if (!empty(artifactsUserAssignedIdentityResourceId)) {
  scope: resourceGroup(split(artifactsUserAssignedIdentityResourceId, '/')[2], split(artifactsUserAssignedIdentityResourceId, '/')[4])
  name: last(split(artifactsUserAssignedIdentityResourceId, '/'))
}

module netAppVolumeFqdns 'modules/getNetAppVolumeSmbServerFqdns.bicep' = if(fslogixConfigureSessionHosts && (!empty(fslogixLocalNetAppVolumeResourceIds) || !empty(fslogixRemoteNetAppVolumeResourceIds))) {
  name: 'shr-netAppVolumeFqdns-${deploymentSuffix}'
  params: {
    localNetAppVolumeResourceIds: fslogixLocalNetAppVolumeResourceIds
    remoteNetAppVolumeResourceIds: fslogixRemoteNetAppVolumeResourceIds
    shareNames: fslogixFileShareNames
  }
}

module availabilitySets '../../../../sharedModules/resources/compute/availability-set/main.bicep' = [
  for i in range(0, calculatedAvailabilitySetsCount): if (availability == 'AvailabilitySets') {
    name: 'shr-${replace(avSetNameConv, '##', padLeft((i + calculatedAvailabilitySetsIndex) + 1, 2, '0'))}-${deploymentSuffix}'
    params: {
      name: replace(avSetNameConv, '##', padLeft((i + calculatedAvailabilitySetsIndex) + 1, 2, '0'))
      platformFaultDomainCount: 2
      platformUpdateDomainCount: 5
      proximityPlacementGroupResourceId: ''
      location: location
      skuName: 'Aligned'
      tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Compute/availabilitySets'] ?? {})
    }
  }
]

@batchSize(5)
module virtualMachines 'modules/virtualMachines.bicep' = [
  for i in range(1, sessionHostBatchCount): {
    name: 'shr-vm-batch-${i}-${deploymentSuffix}'
    params: {
      artifactsContainerUri: artifactsContainerUri
      artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
      artifactsUserAssignedIdentityClientId: empty(artifactsUserAssignedIdentityResourceId)
        ? ''
        : artifactsUAI!.properties.clientId
      availability: availability
      availabilityZones: availabilityZones
      availabilitySetNameConv: avSetNameConv
      avdInsightsDataCollectionRulesResourceId: avdInsightsDataCollectionRulesResourceId
      confidentialVMOSDiskEncryptionType: confidentialVMOSDiskEncryptionType
      dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
      dedicatedHostGroupResourceIds: dedicatedHostGroupResourceIds
      dedicatedHostResourceIds: dedicatedHostResourceIds
      preferredZones: preferredZones
      deploymentSuffix: deploymentSuffix
      diskEncryptionSetResourceId: diskEncryptionSetResourceId
      diskSizeGB: diskSizeGB
      diskSku: diskSku
      domainJoinUserPassword: !empty(domainName) ? kvCredentials.getSecret('DomainJoinUserPassword') : ''
      domainJoinUserPrincipalName: !empty(domainName) ? kvCredentials.getSecret('DomainJoinUserPrincipalName') : ''
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
