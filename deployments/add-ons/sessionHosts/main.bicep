// ============================================================================
// main.bicep — Standalone session hosts deployment entry point
// Handles credentials (Key Vault lookup), naming convention auto-detection,
// and availability set index computation, then delegates VM deployment to
// the shared orchestration module under hostpools/modules/hosts/modules/.
//
// Used as:
//   • A Template Spec loaded by the Session Host Replacer function app
//   • A standalone portal deployment for adding session hosts to an existing host pool
// ============================================================================
// targetScope = resourceGroup (default)

@description('Optional. Override download URL for the AVD Agent Boot Loader installer. Leave empty to use the default Microsoft-hosted URL for the current cloud.')
param agentBootLoaderDownloadUrl string = ''
@description('Optional. Override download URL for the AVD Agent installer. Leave empty to use the default Microsoft-hosted URL for the current cloud.')
param agentDownloadUrl string = ''
@description('Optional. URI of the blob storage container holding scripts and artifacts for session host customizations.')
param artifactsContainerUri string = ''
@description('Optional. Resource ID of the user-assigned managed identity with Storage Blob Data Reader access to the artifacts container.')
param artifactsUserAssignedIdentityResourceId string = ''
@allowed([
  'AvailabilitySets'
  'AvailabilityZones'
  'None'
])
@description('Optional. VM availability strategy.')
param availability string = 'None'
@description('Optional. Naming convention for availability sets with ## placeholder for index. Auto-detected from the host pool name when empty.')
param availabilitySetNameConv string = ''
@description('Optional. Availability zones to spread session hosts across when availability is AvailabilityZones.')
param availabilityZones array = []
@description('Optional. Resource ID of the AVD Insights data collection rule.')
param avdInsightsDataCollectionRulesResourceId string = ''
@description('Optional. When true, enables OS disk encryption with VMGuestState for confidential VMs.')
param confidentialVMOSDiskEncryption bool = false
@description('Required. Resource ID of the Key Vault containing VirtualMachineAdminPassword, VirtualMachineAdminUserName, DomainJoinUserPassword, and DomainJoinUserPrincipalName secrets.')
param credentialsKeyVaultResourceId string
@description('Optional. Resource ID of the Azure Monitor data collection endpoint.')
param dataCollectionEndpointResourceId string = ''
@description('Optional. Per-VM array of dedicated host group resource IDs. One entry per session host, a single-entry array applied to all, or empty for no assignment.')
param dedicatedHostGroupResourceIds array = []
@description('Optional. Per-VM array of dedicated host resource IDs. One entry per session host, a single-entry array applied to all, or empty for no assignment.')
param dedicatedHostResourceIds array = []
@description('Optional. Per-VM preferred availability zones (as zone strings). One entry per session host, or empty for no preference.')
param preferredZones array = []
@description('Optional. Resource ID of the disk access resource to restrict managed disk network access.')
param diskAccessId string = ''
@description('Optional. Resource ID of the disk encryption set for customer-managed key encryption.')
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
@description('Optional. OS disk size in GB. 0 inherits the image default.')
param diskSizeGB int = 0
@allowed([
  'Standard_LRS'
  'StandardSSD_LRS'
  'Premium_LRS'
])
@description('Optional. Storage SKU for the OS disk.')
param diskSku string = 'Premium_LRS'
@description('Optional. Active Directory domain name for domain join. Leave empty for Entra ID join.')
param domainName string = ''
@description('Optional. Enable accelerated networking on session host NICs.')
param enableAcceleratedNetworking bool = true
@description('Optional. Enable IPv6 on session host NICs.')
param enableIPv6 bool = false
@description('Optional. Enable Azure Monitor on session hosts.')
param enableMonitoring bool = false
@description('Optional. Enable encryption at host for all disks and cache.')
param encryptionAtHost bool = true
@description('Optional. Configure FSLogix profile container settings on session hosts.')
param fslogixConfigureSessionHosts bool = false
@allowed([
  'CloudCacheProfileContainer'
  'CloudCacheProfileOfficeContainer'
  'ProfileContainer'
  'ProfileOfficeContainer'
])
@description('Optional. FSLogix container type.')
param fslogixContainerType string = 'ProfileContainer'
@description('Optional. Resource IDs of local Azure NetApp Files volumes for FSLogix.')
param fslogixLocalNetAppVolumeResourceIds array = []
@description('Optional. Resource IDs of local storage accounts for FSLogix.')
param fslogixLocalStorageAccountResourceIds array = []
@description('Optional. Entra ID group object IDs for FSLogix Office container separation.')
param fslogixOSSGroups array = []
@description('Optional. Resource IDs of remote Azure NetApp Files volumes for FSLogix cloud cache failover.')
param fslogixRemoteNetAppVolumeResourceIds array = []
@description('Optional. Resource IDs of remote storage accounts for FSLogix cloud cache failover.')
param fslogixRemoteStorageAccountResourceIds array = []
@description('Optional. Maximum size of FSLogix VHD/VHDX in megabytes.')
param fslogixSizeInMBs int = 30720
@allowed([
  'AzureFiles'
  'AzureNetAppFiles'
])
@description('Optional. Storage service backing FSLogix containers.')
param fslogixStorageService string = 'AzureFiles'
@description('Optional. Enable VM hibernation on session hosts.')
param hibernationEnabled bool = false
@description('Required. Resource ID of the AVD host pool that session hosts will be registered with.')
param hostPoolResourceId string
@allowed([
  'ActiveDirectoryDomainServices'
  'EntraDomainServices'
  'EntraId'
  'EntraKerberos-CloudOnly'
  'EntraKerberos-Hybrid'
])
@description('Required. Identity join method for session hosts.')
param identitySolution string
@description('Optional. Pre-built image reference object. When non-empty, takes precedence over imageOffer/imageSku/customImageResourceId.')
param imageReference object = {}
@description('Optional. Marketplace image offer. Used when imageReference and customImageResourceId are both empty.')
param imageOffer string = ''
@description('Optional. Marketplace image publisher.')
param imagePublisher string = 'MicrosoftWindowsDesktop'
@description('Optional. Marketplace image SKU.')
param imageSku string = ''
@description('Optional. Resource ID of an Azure Compute Gallery image version. Used when imageReference is empty.')
param customImageResourceId string = ''
@description('Optional. Enable Guest Attestation extension for boot integrity monitoring.')
param integrityMonitoring bool = false
@description('Optional. Enroll session hosts in Microsoft Intune.')
param intuneEnrollment bool = false
@description('Optional. Azure region for session host VMs.')
param location string = resourceGroup().location
@description('Optional. Naming convention for NICs with SHNAME placeholder. Auto-detected from host pool name when empty.')
param networkInterfaceNameConv string = ''
@description('Optional. Naming convention for OS disks with SHNAME placeholder. Auto-detected from host pool name when empty.')
param osDiskNameConv string = ''
@description('Optional. OU path in Active Directory for session host computer accounts.')
param ouPath string = ''
@description('Optional. Enable Secure Boot on session host VMs.')
param secureBootEnabled bool = true
@allowed([
  'Standard'
  'TrustedLaunch'
  'ConfidentialVM'
])
@description('Optional. VM security profile type.')
param securityType string = 'TrustedLaunch'
@description('Optional. Custom script extension configurations for post-provisioning session host customization.')
param sessionHostCustomizations array = []
@minValue(1)
@maxValue(4)
@description('Optional. Number of digits in the zero-padded VM index (used for both naming modes).')
param sessionHostNameIndexLength int = 2
@description('Optional. Explicit array of session host computer names (e.g. ["avd01","avd02"]). When non-empty, takes precedence over convention mode. Used by the Session Host Replacer.')
param sessionHostNames array = []
@description('Optional. Short prefix for session host computer names in convention mode (e.g. "avd"). Ignored when sessionHostNames is non-empty.')
param sessionHostNamePrefix string = ''
@minValue(0)
@description('Optional. Number of session hosts to deploy in convention mode. Ignored when sessionHostNames is non-empty.')
param sessionHostCount int = 0
@minValue(0)
@description('Optional. Starting index for VM name generation in convention mode. Ignored when sessionHostNames is non-empty.')
param sessionHostIndex int = 0
@description('Required. Resource ID of the subnet where session host NICs will be placed.')
param subnetResourceId string
@description('Optional. Tags applied to all deployed resources, keyed by resource type.')
param tags object = {}
@description('Optional. Windows time zone for session host VMs.')
param timeZone string = 'Eastern Standard Time'
@description('Optional. Naming convention for VM names with SHNAME placeholder. Auto-detected from host pool name when empty.')
param virtualMachineNameConv string = ''
@description('Required. Azure VM size for session hosts.')
param virtualMachineSize string
@description('Optional. Enable virtual TPM on session host VMs.')
param vTpmEnabled bool = true
@description('Optional. Resource ID of an existing Recovery Services Vault to register session host VMs with for backup. When provided, VMs will be enrolled in the backup policy specified by vmBackupPolicyName. Intended for personal host pools.')
param recoveryServicesVaultResourceId string = ''

@description('Optional. Name of the backup policy within the Recovery Services Vault to apply to session host VMs. Defaults to the standard AVD VM policy name when empty.')
param vmBackupPolicyName string = ''

// ── Shared data ───────────────────────────────────────────────────────────────
var resourceAbbreviations = loadJsonContent('../../../.common/data/resourceAbbreviations.json')
var locationsObject = loadJsonContent('../../../.common/data/locations.json')
var cloud = toLower(environment().name)
var locationsEnvProperty = startsWith(cloud, 'us') ? 'other' : environment().name
var locations = locationsObject[locationsEnvProperty]
#disable-next-line BCP329
var varLocation = startsWith(cloud, 'us') ? substring(location, 5, length(location) - 5) : location
var regionAbbreviation = locations[varLocation].abbreviation

// ── Naming convention auto-detection ─────────────────────────────────────────
// Mirrors the same logic used in the Session Host Replacer function app.
var hostPoolName = last(split(hostPoolResourceId, '/'))
// Naming convention auto-detection: reversed = resource type at the end (e.g., "avd-prod-eus-vdpool" or "avd-prod-eus-hp")
var nameConvReversed = endsWith(hostPoolName, '-${resourceAbbreviations.hostPools}') || endsWith(hostPoolName, '-hp')

var arrHostPoolName = split(hostPoolName, '-')
var hpBaseName = nameConvReversed
  ? join(take(arrHostPoolName, length(arrHostPoolName) - 2), '-')
  : join(take(skip(arrHostPoolName, 1), length(arrHostPoolName) - 2), '-')
var hpResPrfx = nameConvReversed ? hpBaseName : 'RESOURCETYPE-${hpBaseName}'
var nameConv_HP_Resources = '${hpResPrfx}-TOKEN-${nameConvReversed ? 'LOCATION-RESOURCETYPE' : 'LOCATION'}'

var effectiveVirtualMachineNameConv = !empty(virtualMachineNameConv)
  ? virtualMachineNameConv
  : nameConvReversed
      ? 'SHNAME-${resourceAbbreviations.virtualMachines}'
      : '${resourceAbbreviations.virtualMachines}-SHNAME'

var effectiveNetworkInterfaceNameConv = !empty(networkInterfaceNameConv)
  ? networkInterfaceNameConv
  : nameConvReversed
      ? 'SHNAME-${resourceAbbreviations.networkInterfaces}'
      : '${resourceAbbreviations.networkInterfaces}-SHNAME'

var effectiveOsDiskNameConv = !empty(osDiskNameConv)
  ? osDiskNameConv
  : nameConvReversed
      ? 'SHNAME-${resourceAbbreviations.osdisks}'
      : '${resourceAbbreviations.osdisks}-SHNAME'

// ## is placed between TOKEN (purpose/persona) and LOCATION so the AS index
// sits directly after the purpose segment: as-persona-01-01-eus / persona-01-01-eus-as
var generatedAvSetNameConv = replace(
  replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.availabilitySets), 'LOCATION', regionAbbreviation),
  'TOKEN',
  '##'
)

var avSetNameConv = !empty(availabilitySetNameConv) ? availabilitySetNameConv : generatedAvSetNameConv

// ── FSLogix file share names ──────────────────────────────────────────────────
var fslogixFileShareNames = contains(fslogixContainerType, 'Office')
  ? ['profile-containers', 'office-containers']
  : ['profile-containers']

// ── Effective session host names (for availability set index calculation) ─────
var generatedSessionHostNames = [
  for i in range(sessionHostIndex, sessionHostCount): '${sessionHostNamePrefix}${padLeft(i, sessionHostNameIndexLength, '0')}'
]
var effectiveSessionHostNames = !empty(sessionHostNames) ? sessionHostNames : generatedSessionHostNames

// ── Availability set index calculation ───────────────────────────────────────
var vmNumbersForAvSet = [
  for name in effectiveSessionHostNames: int(substring(
    name,
    length(name) - sessionHostNameIndexLength,
    sessionHostNameIndexLength
  ))
]
var minVmNumber = min(vmNumbersForAvSet)
var maxVmNumber = max(vmNumbersForAvSet)
var maxAvSetMembers = 200
var beginAvSetRange = minVmNumber / maxAvSetMembers
var endAvSetRange = maxVmNumber / maxAvSetMembers
var calculatedAvailabilitySetsCount = endAvSetRange - beginAvSetRange + 1
var calculatedAvailabilitySetsIndex = beginAvSetRange

// ── Deployment suffix ─────────────────────────────────────────────────────────
var deploymentSuffix = uniqueString(deployment().name)

var effectiveVmBackupPolicyName = !empty(vmBackupPolicyName) ? vmBackupPolicyName : 'AvdPolicyVm'

// ── Credentials from Key Vault ────────────────────────────────────────────────
resource kvCredentials 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: last(split(credentialsKeyVaultResourceId, '/'))
  scope: resourceGroup(split(credentialsKeyVaultResourceId, '/')[2], split(credentialsKeyVaultResourceId, '/')[4])
}

// ── Session hosts ─────────────────────────────────────────────────────────────
// Delegates to the shared RG-scoped orchestration module under hostpools/modules/hosts/modules/.
module sessionHosts '../../hostpools/modules/hosts/modules/sessionHosts.bicep' = {
  name: 'SessionHosts-${deploymentSuffix}'
  params: {
    agentBootLoaderDownloadUrl: agentBootLoaderDownloadUrl
    agentDownloadUrl: agentDownloadUrl
    artifactsContainerUri: artifactsContainerUri
    artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
    availability: availability
    availabilitySetNameConv: avSetNameConv
    availabilitySetsCount: calculatedAvailabilitySetsCount
    availabilitySetsIndex: calculatedAvailabilitySetsIndex
    availabilityZones: availabilityZones
    avdInsightsDataCollectionRulesResourceId: avdInsightsDataCollectionRulesResourceId
    confidentialVMOSDiskEncryption: confidentialVMOSDiskEncryption
    customImageResourceId: customImageResourceId
    dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
    dedicatedHostGroupResourceIds: dedicatedHostGroupResourceIds
    dedicatedHostResourceIds: dedicatedHostResourceIds
    preferredZones: preferredZones
    diskAccessId: diskAccessId
    diskEncryptionSetResourceId: diskEncryptionSetResourceId
    diskSizeGB: diskSizeGB
    diskSku: diskSku
    domainJoinUserPassword: contains(identitySolution, 'DomainServices')
      ? kvCredentials.getSecret('DomainJoinUserPassword')
      : ''
    domainJoinUserPrincipalName: contains(identitySolution, 'DomainServices')
      ? kvCredentials.getSecret('DomainJoinUserPrincipalName')
      : ''
    domainName: domainName
    enableAcceleratedNetworking: enableAcceleratedNetworking
    enableIPv6: enableIPv6
    enableMonitoring: enableMonitoring
    encryptionAtHost: encryptionAtHost
    fslogixConfigureSessionHosts: fslogixConfigureSessionHosts
    fslogixContainerType: fslogixContainerType
    fslogixFileShareNames: fslogixFileShareNames
    fslogixLocalNetAppVolumeResourceIds: fslogixLocalNetAppVolumeResourceIds
    fslogixLocalStorageAccountResourceIds: fslogixLocalStorageAccountResourceIds
    fslogixOSSGroups: fslogixOSSGroups
    fslogixRemoteNetAppVolumeResourceIds: fslogixRemoteNetAppVolumeResourceIds
    fslogixRemoteStorageAccountResourceIds: fslogixRemoteStorageAccountResourceIds
    fslogixSizeInMBs: fslogixSizeInMBs
    fslogixStorageService: fslogixStorageService
    hibernationEnabled: hibernationEnabled
    hostPoolResourceId: hostPoolResourceId
    identitySolution: identitySolution
    imageReference: imageReference
    imageOffer: imageOffer
    imagePublisher: imagePublisher
    imageSku: imageSku
    integrityMonitoring: integrityMonitoring
    intuneEnrollment: intuneEnrollment
    location: location
    networkInterfaceNameConv: effectiveNetworkInterfaceNameConv
    osDiskNameConv: effectiveOsDiskNameConv
    ouPath: ouPath
    secureBootEnabled: secureBootEnabled
    securityType: securityType
    sessionHostCustomizations: sessionHostCustomizations
    sessionHostNames: effectiveSessionHostNames
    vmNameIndexLength: sessionHostNameIndexLength
    virtualMachineNameConv: effectiveVirtualMachineNameConv
    virtualMachineSize: virtualMachineSize
    virtualMachineAdminPassword: kvCredentials.getSecret('VirtualMachineAdminPassword')
    virtualMachineAdminUserName: kvCredentials.getSecret('VirtualMachineAdminUserName')
    vTpmEnabled: vTpmEnabled
    subnetResourceId: subnetResourceId
    tags: tags
    deploymentSuffix: deploymentSuffix
    timeZone: timeZone
    recoveryServicesVaultResourceId: recoveryServicesVaultResourceId
    vmBackupPolicyName: effectiveVmBackupPolicyName
  }
}

output virtualMachineNames array = sessionHosts.outputs.virtualMachineNames
