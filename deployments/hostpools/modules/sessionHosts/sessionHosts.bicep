targetScope = 'subscription'

@description('Required. Deployment mode: "Complete" creates all AVD resources from scratch; "SessionHostsOnly" adds session hosts to an existing host pool.')
param deploymentType string
@description('Optional. Override download URL for the AVD Agent Boot Loader installer. Leave empty to use the default Microsoft-hosted URL for the current cloud.')
param agentBootLoaderDownloadUrl string
@description('Optional. Override download URL for the AVD Agent installer. Leave empty to use the default Microsoft-hosted URL for the current cloud.')
param agentDownloadUrl string
@description('Required. File name of the AVD Agent DSC configuration package blob (e.g. "Configuration_01-20-2023.zip"). Used during session host registration.')
param avdAgentDscPackage string
@description('Required. Array of Entra ID group object IDs assigned to the AVD application group. Members receive the Virtual Machine User Login role on the hosts resource group.')
param appGroupSecurityGroups array
@description('Required. URI of the blob storage container holding scripts and artifacts for session host customizations.')
param artifactsContainerUri string
@description('Required. Resource ID of the user-assigned managed identity with Storage Blob Data Reader access to the artifacts container.')
param artifactsUserAssignedIdentityResourceId string
@description('Required. VM availability strategy: "None", "AvailabilitySets", or "AvailabilityZones".')
param availability string
@description('Required. Name convention string for availability sets, containing RESOURCETYPE, TOKEN, and LOCATION placeholders.')
param availabilitySetNameConv string
@description('Required. Total number of availability sets to create for this host pool deployment.')
param availabilitySetsCount int
@description('Required. Starting index used when naming availability sets.')
param availabilitySetsIndex int
@description('Required. List of availability zones (e.g. ["1","2","3"]) across which session hosts are distributed. Used when availability is "AvailabilityZones".')
param availabilityZones array
@description('Required. Resource ID of the AVD Insights data collection rule for session host diagnostics.')
param avdInsightsDataCollectionRulesResourceId string
@description('Required. Resource ID of the private DNS zone for Azure Blob Storage private endpoints.')
param azureBlobPrivateDnsZoneResourceId string
@description('Required. Object ID of the Confidential VM Orchestrator service principal. Required when deploying confidential VMs with VMGuestState encryption.')
param confidentialVMOrchestratorObjectId string
@description('Required. When true, enables OS disk encryption with VMGuestState for confidential VMs, protecting disk contents from the host.')
param confidentialVMOSDiskEncryption bool
@description('Optional. Resource ID of an Azure Compute Gallery image version to use as the VM OS image. Leave empty to use a marketplace image defined by imagePublisher, imageOffer, and imageSku.')
param customImageResourceId string
@description('Required. Resource ID of the Azure Monitor data collection endpoint for custom log ingestion.')
param dataCollectionEndpointResourceId string
@description('Optional. Resource ID of an Azure Dedicated Host Group to deploy session hosts onto. Mutually exclusive with dedicatedHostResourceId.')
param dedicatedHostGroupResourceId string
@description('Optional. Resource ID of a specific Azure Dedicated Host. When set, all VMs in this deployment are pinned to this host.')
param dedicatedHostResourceId string
@description('Required. When true, deploys a disk access policy restricting managed disk export and import to approved networks.')
param deployDiskAccessPolicy bool
@description('Required. When true, creates a new DiskAccess resource to enforce managed disk network access restrictions.')
param deployDiskAccessResource bool
@description('Required. Password for the domain join service account.')
@secure()
param domainJoinUserPassword string
@description('Required. User principal name of the domain join service account (e.g. "domainjoin@contoso.com").')
@secure()
param domainJoinUserPrincipalName string
@description('Required. Object containing disk encryption set names keyed by key management type. Used to resolve the correct DES resource for this deployment.')
param diskEncryptionSetNames object
@description('Required. Name of the DiskAccess resource used to enforce managed disk network access restrictions.')
param diskAccessName string
@description('Required. OS disk size in GB. Set to 0 to inherit the default size from the source image.')
param diskSizeGB int
@description('Required. Storage SKU for the OS disk (e.g. "Premium_LRS", "StandardSSD_LRS").')
param diskSku string
@description('Required. Active Directory domain name for domain join (e.g. "contoso.com"). Leave empty for Entra ID join.')
param domainName string
@description('Required. When true, enables accelerated networking on session host NICs for lower latency and higher throughput.')
param enableAcceleratedNetworking bool
@description('Required. When true, adds an IPv6 IP configuration to session host network interfaces.')
param enableIPv6 bool
@description('Required. When true, enables encryption at the VM host for all disks and cache (host-based encryption).')
param encryptionAtHost bool
@description('Required. Name of the Customer Managed Key in the Key Vault used for disk encryption set configuration.')
param encryptionKeyName string
@description('Required. When true, installs the AMD GPU driver extension on session host VMs.')
param hasAmdGpu bool
@description('Required. When true, installs the NVIDIA GPU driver extension on session host VMs.')
param hasNvidiaGpu bool
@description('Optional. NVIDIA GPU driver version string. Leave empty to install the latest supported version.')
param nvidiaDriverVersion string
@description('Required. Resource ID of the Key Vault containing Customer Managed Keys for disk encryption set configuration.')
param encryptionKeyVaultResourceId string
@description('Optional. Resource ID of a pre-existing DiskAccess resource. Used instead of creating a new resource when deployDiskAccessResource is false.')
param existingDiskAccessResourceId string
@description('Optional. Resource ID of a pre-existing Disk Encryption Set. When provided, bypasses inline DES creation.')
param existingDiskEncryptionSetResourceId string
@description('Optional. Resource ID of a pre-existing Recovery Services Vault to register session hosts with for backup.')
param existingRecoveryServicesVaultResourceId string
@description('Required. Array of Azure Files share names to mount on session hosts for FSLogix profile containers.')
param fslogixFileShareNames array
@description('Required. When true, configures FSLogix profile container settings on session hosts via DSC.')
param fslogixConfigureSessionHosts bool
@description('Required. FSLogix container type: "CloudCacheProfileContainer", "ProfileContainer", "CloudCacheProfileOfficeContainer", or "ProfileOfficeContainer".')
param fslogixContainerType string
@description('Required. Resource IDs of NetApp volumes in the session host region for FSLogix profile storage or cloud cache primary location.')
param fslogixLocalNetAppVolumeResourceIds array
@description('Required. Resource IDs of Azure Storage accounts in the session host region for FSLogix profile storage or cloud cache primary location.')
param fslogixLocalStorageAccountResourceIds array
@description('Required. Entra ID group object IDs for FSLogix Office container separation (users with Microsoft 365 subscriptions).')
param fslogixOSSGroups array
@description('Required. Resource IDs of NetApp volumes in a remote region for FSLogix cloud cache failover or cross-region replication.')
param fslogixRemoteNetAppVolumeResourceIds array
@description('Required. Resource IDs of Azure Storage accounts in a remote region for FSLogix cloud cache failover or cross-region replication.')
param fslogixRemoteStorageAccountResourceIds array
@description('Required. Maximum size of the FSLogix profile VHD/VHDX in megabytes.')
param fslogixSizeInMBs int
@description('Required. Storage service backing FSLogix containers: "AzureStorageAccount Premium", "AzureStorageAccount Standard", "AzureNetAppFiles Premium", or "AzureNetAppFiles Standard".')
param fslogixStorageService string
@description('Required. When true, enables VM hibernation on session hosts. Not compatible with all VM sizes or availability configurations.')
param hibernationEnabled bool
@description('Required. Resource ID of the AVD host pool that session hosts will be registered with.')
param hostPoolResourceId string
@description('Required. Identity join method for session hosts: "ActiveDirectoryDomainServices", "EntraId", or "EntraIdIntuneEnrollment".')
param identitySolution string
@description('Required. Marketplace image offer (e.g. "windows-11"). Used when customImageResourceId is empty.')
param imageOffer string
@description('Required. Marketplace image publisher (e.g. "MicrosoftWindowsDesktop"). Used when customImageResourceId is empty.')
param imagePublisher string
@description('Required. Marketplace image SKU (e.g. "win11-24h2-avd"). Used when customImageResourceId is empty.')
param imageSku string
@description('Required. When true, deploys the Guest Attestation extension to enable boot integrity monitoring for Trusted Launch VMs.')
param integrityMonitoring bool
@description('Required. When true, enrolls session hosts into Microsoft Intune during provisioning (requires EntraIdIntuneEnrollment identity solution).')
param intuneEnrollment bool
@description('Required. Number of days before Customer Managed Keys expire and must be rotated. Only relevant when keyManagementDisks is not "PlatformManaged".')
param keyExpirationInDays int
@description('Required. Key management type for OS disks: "PlatformManaged", "CustomerManaged", or "CustomerManagedHSM".')
param keyManagementDisks string
@description('Required. Azure region where session host VMs and compute resources are deployed.')
param location string
@description('Required. Name convention string for private endpoint resources, containing RESOURCETYPE, SUBRESOURCE, and RESOURCE placeholders.')
param privateEndpointNameConv string
@description('Required. Name convention string for private endpoint network interface cards.')
param privateEndpointNICNameConv string
@description('Required. Resource ID of the subnet where private endpoint NICs are placed.')
param privateEndpointSubnetResourceId string
@description('Required. When true, deploys Azure Monitor Agent and data collection rules on session hosts for diagnostics and VM Insights.')
param enableMonitoring bool
@description('Required. Name convention string for session host network interfaces, containing RESOURCETYPE and VMNAME placeholders.')
param networkInterfaceNameConv string
@description('Required. Name convention string for session host OS disks.')
param osDiskNameConv string
@description('Required. Distinguished name of the Active Directory OU for session host computer accounts (e.g. "OU=AVD,DC=contoso,DC=com"). Leave empty for Entra ID join.')
param ouPath string
@description('Required. When true, deploys a Recovery Services Vault and configures daily VM backup for session hosts.')
param recoveryServices bool
@description('Required. Name of the resource group where session host VMs and compute resources are deployed.')
param resourceGroupHosts string
@description('Required. When true, enables Secure Boot on session host VMs as part of Trusted Launch or Confidential VM security configuration.')
param secureBootEnabled bool
@description('Required. VM security profile type: "Standard", "TrustedLaunch", or "ConfidentialVM".')
param securityType string
@description('Required. Total number of session host VMs to deploy.')
param sessionHostCount int
@description('Optional. Array of customization objects, each specifying a script and parameters to execute on session hosts after provisioning.')
param sessionHostCustomizations array
@description('Required. Starting VM index number for this deployment batch. Used to generate unique VM names when deploying in multiple batches.')
param sessionHostIndex int
@description('Required. Number of digits in the zero-padded VM index (e.g. 2 → vm-01, 3 → vm-001).')
param vmNameIndexLength int
@description('Required. Azure Storage endpoint suffix for the current cloud (e.g. "core.windows.net" for Azure Commercial).')
param storageSuffix string
@description('Required. Resource ID of the virtual network subnet where session host NICs are connected.')
param subnetResourceId string
@description('Required. Azure resource tags applied to all deployed resources, keyed by resource type.')
param tags object
@description('Required. Short unique suffix appended to deployment names to prevent naming collisions across concurrent deployments.')
param deploymentSuffix string
@description('Required. Windows time zone for session host VMs (e.g. "Eastern Standard Time").')
param timeZone string
@description('Required. Full name convention string for VM names, containing RESOURCETYPE, TOKEN, and LOCATION placeholders.')
param virtualMachineNameConv string
@description('Required. Short prefix for VM names used as the TOKEN segment in the name convention (e.g. "avd", "vdi").')
param virtualMachineNamePrefix string
@description('Required. Azure VM SKU for session hosts (e.g. "Standard_D4s_v5").')
param virtualMachineSize string
@description('Required. Local administrator password for all session host VMs.')
@secure()
param virtualMachineAdminPassword string
@description('Required. Local administrator username for all session host VMs.')
@secure()
param virtualMachineAdminUserName string
@description('Required. When true, enables virtual TPM on session host VMs. Required for Trusted Launch and Confidential VM security types.')
param vTpmEnabled bool
@description('Required. Resource ID of the VM Insights data collection rule for performance counters and dependency map data.')
param vmInsightsDataCollectionRulesResourceId string

var confidentialVMOSDiskEncryptionType = confidentialVMOSDiskEncryption ? 'DiskWithVMGuestState' : 'VMGuestStateOnly'

// Batching logic: Dynamically calculate max VMs per batch based on resources per VM
// Empirically measured: 915 resources / 61 VMs = 15 with monitoring, so base = 11 without monitoring
var baseResourcesPerVM = 11 // NIC, VM, Domain/AAD Extension, DSC Extension, Run Command, updateOSDisk modules(2), diskUpdate, plus 3 unidentified
var monitoringResourcesPerVM = enableMonitoring ? 4 : 0 // Azure Monitor Agent Extension + 3 DCR associations
var gpuResourcesPerVM = (hasAmdGpu || hasNvidiaGpu) ? 1 : 0 // GPU driver extension (AMD or NVIDIA)
var integrityResourcesPerVM = integrityMonitoring ? 1 : 0 // Guest Attestation extension
var customizationsResourcesPerVM = !empty(sessionHostCustomizations) ? (1 + length(sessionHostCustomizations)) : 0 // 1 module deployment + 1 run command per customization
var totalResourcesPerVM = baseResourcesPerVM + monitoringResourcesPerVM + gpuResourcesPerVM + integrityResourcesPerVM + customizationsResourcesPerVM
var calculatedMaxVMs = 800 / totalResourcesPerVM // ARM template limit is 800 resources per template
var maxVMsPerDeployment = calculatedMaxVMs < 20 ? 20 : (calculatedMaxVMs > 45 ? 45 : calculatedMaxVMs) // Safety bounds: minimum 20, maximum 45 VMs per batch
var divisionValue = sessionHostCount / maxVMsPerDeployment
var divisionRemainderValue = sessionHostCount % maxVMsPerDeployment
var sessionHostBatchCount = divisionRemainderValue > 0 ? divisionValue + 1 : divisionValue

// Agent Download URLs
var cloud = toLower(environment().name)
var cloudSuffix = replace(replace(replace(environment().resourceManager, 'https://management.azure.', ''), 'https://management.', ''), '/', '')
var agentBootLoaderUrl = !empty(agentBootLoaderDownloadUrl) 
  ? agentBootLoaderDownloadUrl 
  : (startsWith(cloud, 'us') ? 'https://aka.${cloudSuffix}/avdRDAgentBootLoader' : 'https://go.microsoft.com/fwlink/?linkid=2311028')
var agentUrl = !empty(agentDownloadUrl) 
  ? agentDownloadUrl 
  : (startsWith(cloud, 'us') ? 'https://aka.${cloudSuffix}/avdRDAgent' : 'https://go.microsoft.com/fwlink/?linkid=2310011')

var dscStorageAccount = startsWith(environment().name, 'USN')
  ? 'wvdexportalcontainer'
  : 'wvdportalstorageblob'
var dscUrl = 'https://${dscStorageAccount}.blob.${environment().suffixes.storage}/galleryartifacts/${avdAgentDscPackage}'

var dedicatedHostGroupName = !empty(dedicatedHostResourceId)
  ? split(dedicatedHostResourceId, '/')[8]
  : !empty(dedicatedHostGroupResourceId) ? last(split(dedicatedHostGroupResourceId, '/')) : ''
var dedicatedHostSub = !empty(dedicatedHostResourceId)
  ? split(dedicatedHostResourceId, '/')[2]
  : !empty(dedicatedHostGroupResourceId) ? split(dedicatedHostGroupResourceId, '/')[2] : ''
var dedicatedHostRG = !empty(dedicatedHostResourceId)
  ? split(dedicatedHostResourceId, '/')[4]
  : !empty(dedicatedHostGroupResourceId) ? split(dedicatedHostGroupResourceId, '/')[4] : ''

resource dedicatedHostGroup 'Microsoft.Compute/hostGroups@2024-11-01' existing = if (!empty(dedicatedHostGroupName)) {
  scope: resourceGroup(dedicatedHostSub, dedicatedHostRG)
  name: dedicatedHostGroupName
}

// Call on the hotspool
resource hostPoolGet 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' existing = if(deploymentType == 'SessionHostsOnly') {
  name: last(split(hostPoolResourceId, '/'))
  scope: resourceGroup(split(hostPoolResourceId, '/')[2], split(hostPoolResourceId, '/')[4])
}

// Required for EntraID login
module roleAssignment_VirtualMachineUserLogin '../../../../.common/bicepModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = [
  for i in range(0, length(appGroupSecurityGroups)): if (deploymentType != 'SessionHostsOnly' && !contains(identitySolution, 'DomainServices')) {
    name: 'RA-Hosts-VMLoginUser-${i}-${deploymentSuffix}'
    scope: resourceGroup(resourceGroupHosts)
    params: {
      principalId: appGroupSecurityGroups[i]
      principalType: 'Group'
      roleDefinitionId: 'fb879df8-f326-4884-b1cf-06f3ad86be52' // Virtual Machine User Login
    }
  }
]

module hostPoolUpdate 'modules/hostPoolUpdate.bicep' = if(deploymentType == 'SessionHostsOnly') {
  name: 'HostPoolRegistrationTokenUpdate-${deploymentSuffix}'
  scope: resourceGroup(split(hostPoolResourceId, '/')[2], split(hostPoolResourceId, '/')[4])
  params: {
    hostPoolType: deploymentType == 'SessionHostsOnly' ? hostPoolGet!.properties.hostPoolType : ''
    loadBalancerType: deploymentType == 'SessionHostsOnly' ? hostPoolGet!.properties.loadBalancerType : ''
    location: deploymentType == 'SessionHostsOnly' ? hostPoolGet!.location : location
    name: deploymentType == 'SessionHostsOnly' ? hostPoolGet.name : ''
    preferredAppGroupType: deploymentType == 'SessionHostsOnly' ? hostPoolGet!.properties.preferredAppGroupType : ''
  } 
}

module diskAccessResource '../../../../.common/bicepModules/compute/diskAccesses/deploy.bicep' = if (deploymentType != 'SessionHostsOnly' && deployDiskAccessResource) {
  scope: resourceGroup(resourceGroupHosts)
  name: 'DiskAccess-${deploymentSuffix}'
  params: {
    name: diskAccessName
    location: location
    tags: union({'cm-resource-parent': hostPoolResourceId}, tags[?'Microsoft.Compute/diskAccesses'] ?? {})
  }
}

module diskAccessPrivateEndpoint '../../../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = if (deploymentType != 'SessionHostsOnly' && deployDiskAccessResource && !empty(privateEndpointSubnetResourceId)) {
  scope: resourceGroup(resourceGroupHosts)
  name: 'PE-DiskAccess-${deploymentSuffix}'
  params: {
    name: replace(replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'disks'), 'RESOURCE', diskAccessName), 'VNETID', split(privateEndpointSubnetResourceId, '/')[8])
    customNetworkInterfaceName: replace(replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'disks'), 'RESOURCE', diskAccessName), 'VNETID', split(privateEndpointSubnetResourceId, '/')[8])
    location: location
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceId: diskAccessResource!.outputs.resourceId
    groupId: 'disks'
    privateDNSZoneIds: !empty(azureBlobPrivateDnsZoneResourceId) ? [azureBlobPrivateDnsZoneResourceId] : []
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
  }
}

module diskAccessPolicy 'modules/diskNetworkAccessPolicy.bicep' = if (deploymentType != 'SessionHostsOnly' && deployDiskAccessPolicy) {
  name: 'ManagedDisks-NetworkAccess-Policy-${deploymentSuffix}'
  params: {
    diskAccessId: deployDiskAccessResource ? diskAccessResource!.outputs.resourceId : ''
    location: location
    resourceGroupName: resourceGroupHosts
  }
}

module customerManagedKeys '../../../../.common/bicepModules/custom/customerManagedKeys/customerManagedKeys.bicep' = if (deploymentType != 'SessionHostsOnly' && confidentialVMOSDiskEncryption) {
  name: 'Customer-Managed-Keys-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    keyVaultResourceId: encryptionKeyVaultResourceId
    keyManagementType: contains(keyManagementDisks, 'HSM') ? 'CustomerManagedHSM' : 'CustomerManaged'
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    parentResourceId: hostPoolResourceId
    deploymentSuffix: deploymentSuffix
    diskEncryptionConfigs: [
      {
        keyName: encryptionKeyName
        diskEncryptionSetName: confidentialVMOSDiskEncryption
          ? diskEncryptionSetNames.confidentialVMs
          : (!contains(keyManagementDisks, 'Platform')
              ? diskEncryptionSetNames.customerManaged
              : diskEncryptionSetNames.platformAndCustomerManaged)
        confidentialVMOSDiskEncryption: confidentialVMOSDiskEncryption
        confidentialVMOrchestratorObjectId: confidentialVMOrchestratorObjectId
      }
    ]
  }
}

resource artifactsUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = if (!empty(artifactsUserAssignedIdentityResourceId)) {
  scope: resourceGroup(split(artifactsUserAssignedIdentityResourceId, '/')[2], split(artifactsUserAssignedIdentityResourceId, '/')[4])
  name: last(split(artifactsUserAssignedIdentityResourceId, '/'))
}

module availabilitySets '../../../../.common/bicepModules/compute/availabilitySets/deploy.bicep' = [for i in range(0, availabilitySetsCount): if (availability == 'AvailabilitySets') {
  name: 'AvailabilitySet-${padLeft((i + availabilitySetsIndex) + 1, 2, '0')}-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    name: replace(availabilitySetNameConv, '##', padLeft((i + availabilitySetsIndex) + 1, 2, '0'))
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
    location: location
    skuName: 'Aligned'
    tags: union({'cm-resource-parent': hostPoolResourceId}, tags[?'Microsoft.Compute/availabilitySets'] ?? {})
  }
}]

module netAppVolumeFqdns 'modules/getNetAppVolumeSmbServerFqdns.bicep' = if(fslogixConfigureSessionHosts && (!empty(fslogixLocalNetAppVolumeResourceIds) || !empty(fslogixRemoteNetAppVolumeResourceIds))) {
  name: 'NetAppVolumeFqdns-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    localNetAppVolumeResourceIds: fslogixLocalNetAppVolumeResourceIds
    remoteNetAppVolumeResourceIds: fslogixRemoteNetAppVolumeResourceIds
    shareNames: fslogixFileShareNames
  }
}

@batchSize(5)
module virtualMachines 'modules/virtualMachines.bicep' = [for i in range(1, sessionHostBatchCount): {
  name: 'VirtualMachines-Batch-${i}-of-${sessionHostBatchCount}-(${i == sessionHostBatchCount && divisionRemainderValue > 0 ? divisionRemainderValue : maxVMsPerDeployment}-VMs)-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
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
    customImageResourceId: customImageResourceId
    dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
    dedicatedHostGroupResourceId: dedicatedHostGroupResourceId
    dedicatedHostGroupZones: !empty(dedicatedHostGroupName) ? dedicatedHostGroup!.zones : []
    dedicatedHostResourceId: dedicatedHostResourceId
    diskAccessId: deploymentType != 'SessionHostsOnly' ? deployDiskAccessResource ? diskAccessResource!.outputs.resourceId : '' : existingDiskAccessResourceId
    diskEncryptionSetResourceId: ( deploymentType != 'SessionHostsOnly' && confidentialVMOSDiskEncryption ) ? customerManagedKeys!.outputs.diskResults[0].diskEncryptionSetResourceId : !empty(existingDiskEncryptionSetResourceId) ? existingDiskEncryptionSetResourceId : ''
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
    hostPoolResourceId: deploymentType != 'SessionHostsOnly' ? hostPoolResourceId : hostPoolUpdate!.outputs.resourceId
    hasAmdGpu: hasAmdGpu
    hasNvidiaGpu: hasNvidiaGpu
    nvidiaDriverVersion: nvidiaDriverVersion
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
    sessionHostCustomizations: sessionHostCustomizations
    secureBootEnabled: secureBootEnabled
    securityType: securityType
    sessionHostCount: i == sessionHostBatchCount && divisionRemainderValue > 0 ? divisionRemainderValue : maxVMsPerDeployment
    sessionHostIndex: i == 1 ? sessionHostIndex : ((i - 1) * maxVMsPerDeployment) + sessionHostIndex
    vmNameIndexLength: vmNameIndexLength
    storageSuffix: storageSuffix
    subnetResourceId: subnetResourceId
    tags: tags
    deploymentSuffix: deploymentSuffix
    timeZone: timeZone
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

module protectedItems_Vm '../operations/vmBackupItems.bicep' = [for i in range(1, sessionHostBatchCount): if (recoveryServices && !empty(existingRecoveryServicesVaultResourceId)) {
  name: 'BackupProtectedItems-VirtualMachines-${i-1}-${deploymentSuffix}'
  scope: resourceGroup(split(existingRecoveryServicesVaultResourceId, '/')[4])
  params: {
    hostPoolResourceId: hostPoolResourceId
    policyName: 'AvdPolicyVm'
    recoveryServicesVaultName: last(split(existingRecoveryServicesVaultResourceId, '/'))
    resourceGroupHosts: resourceGroupHosts
    virtualMachineNames: virtualMachines[i-1].outputs.virtualMachineNames
  }
}]

module getFlattenedVmNamesArray 'modules/flattenVirtualMachineNames.bicep' = {
  name: 'Flatten-VirtualMachine-Names-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    virtualMachineNamesPerBatch: [for i in range(1, sessionHostBatchCount):virtualMachines[i-1].outputs.virtualMachineNames]
  }
}

output virtualMachineNames array = getFlattenedVmNamesArray.outputs.virtualMachineNames
