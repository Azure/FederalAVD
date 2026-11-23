targetScope = 'subscription'

import { publicNetworkAccessMode } from '../../shared/modules/orchestration/networking/functions.bicep'
import { entraGroupType } from '../../shared/modules/resourceModules/types/identityTypes.bicep'
import { fslogixNames, sharedServicesNames, resourceNameForType, namingConventionConfig } from '../../shared/modules/orchestration/naming/naming.bicep'

@description('Required. Azure region for FSLogix storage resources and deployment VM Run Commands.')
param location string

@description('Optional. Identifier used by the shared FederalAVD naming convention.')
param identifier string = 'fslogix'

@description('Optional. Naming convention used to derive resource names when explicit overrides are not supplied.')
param namingConvention namingConventionConfig = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

@description('Optional. Resource group where FSLogix storage resources are deployed. Required for an existing resource group; overrides the generated name for a new resource group.')
param storageResourceGroupName string = ''

@description('Optional. Create the FSLogix storage resource group before deploying storage resources.')
param createStorageResourceGroup bool = false

@description('Optional. Name override for the temporary resource group created for the deployment VM and identity. The resource group is deleted after storage configuration completes.')
param deploymentResourceGroupName string = ''

@description('Optional. Name override for the temporary deployment VM used for domain, application, and NTFS configuration.')
param deploymentVirtualMachineName string = ''

@description('Optional. Name override for the temporary deployment VM operating system disk.')
param deploymentVirtualMachineDiskName string = ''

@description('Optional. Name override for the temporary deployment VM network interface.')
param deploymentVirtualMachineNicName string = ''

@description('Optional. Size of the temporary deployment VM.')
param deploymentVirtualMachineSize string = 'Standard_B2s'

@description('Optional. Domain join the add-on-created deployment VM using the configured domain and credentials. Requires AD DS or Entra Domain Services. Azure NetApp Files retains its automatic domain join.')
param domainJoinDeploymentVirtualMachine bool = false

@description('Conditional. Subnet resource ID required when this add-on creates a temporary deployment VM. Not used for Entra ID storage-account-key authentication or an externally managed deployment VM.')
param deploymentVirtualMachineSubnetResourceId string = ''

@description('Optional. Name override for the temporary user-assigned identity used by storage configuration and cleanup scripts.')
param deploymentUserAssignedIdentityName string = ''

@description('Optional. Create and clean up the deployment VM within this add-on. Disable when a parent deployment supplies an existing VM and identity.')
param manageDeploymentVirtualMachine bool = true

@description('Optional. Client ID of an externally managed deployment identity. Required when manageDeploymentVirtualMachine is false.')
param existingDeploymentUserAssignedIdentityClientId string = ''

@description('Required. Identity and storage authentication model.')
@allowed([
  'ActiveDirectoryDomainServices'
  'EntraDomainServices'
  'EntraKerberos-Hybrid'
  'EntraKerberos-CloudOnly'
  'EntraId'
])
param identitySolution string

@description('Optional. Resource ID of the Key Vault containing DomainJoinUserPrincipalName and DomainJoinUserPassword secrets. Required when the selected identity or storage service uses domain credentials.')
param credentialsKeyVaultResourceId string = ''

@description('Optional. Domain account UPN. Required for AD DS and Azure NetApp Files, and for Entra Kerberos Hybrid only when AD group names must be resolved for NTFS permissions or sharding.')
@secure()
param domainJoinUserPrincipalName string = ''

@description('Optional. Domain join account password.')
@secure()
param domainJoinUserPassword string = ''

@description('Optional. AD DS domain name used by domain-backed identity solutions.')
param domainName string = ''

@description('Optional. OU path for storage computer objects.')
param organizationalUnitPath string = ''

@description('Optional. OU path for a domain-joined deployment VM. When empty, uses organizationalUnitPath.')
param deploymentVirtualMachineOrganizationalUnitPath string = ''

@description('Optional. Existing user-assigned identity resource ID with permissions to update and consent to storage account enterprise applications for Entra Kerberos.')
param appUpdateUserAssignedIdentityResourceId string = ''

@description('Required. FSLogix storage service and SKU.')
@allowed([
  'AzureFiles Premium'
  'AzureFiles Standard'
  'AzureNetAppFiles Premium'
  'AzureNetAppFiles Standard'
])
param fslogixStorageService string = 'AzureFiles Standard'

@description('Optional. Storage redundancy for Azure Files.')
@allowed([
  'LocallyRedundant'
  'ZoneRedundant'
])
param fslogixStorageRedundancy string = 'LocallyRedundant'

@allowed(['LocallyRedundant', 'ZoneRedundant'])
@description('Optional. Preferred Profile Azure Files redundancy. Overrides fslogixStorageRedundancy when supplied.')
param fslogixProfileStorageRedundancy string?

@allowed(['Standard', 'Premium'])
@description('Optional. Profile Azure Files tier. Null derives the tier from fslogixStorageService; does not change Azure NetApp Files.')
param fslogixProfileStorageTier string?

@allowed(['Legacy', 'ProvisionedV2'])
@description('Optional. Profile Azure Files billing model. Existing accounts are not converted.')
param fslogixProfileStorageBillingModel string = 'Legacy'

@allowed(['Inherit', 'Legacy', 'ProvisionedV2'])
@description('Optional. Office Azure Files billing model. Inherit uses the Profile billing model.')
param fslogixOfficeStorageBillingModel string = 'Inherit'

@minValue(0)
@description('Optional. Profile provisioned v2 IOPS. Zero calculates recommended sizing from the Profile quota.')
param fslogixProfileProvisionedIops int = 0

@minValue(0)
@description('Optional. Profile provisioned v2 throughput in MiB/s. Zero calculates recommended sizing from the Profile quota.')
param fslogixProfileProvisionedThroughputMiBps int = 0

@minValue(0)
@description('Optional. Office provisioned v2 IOPS. Zero calculates recommended sizing from the Office quota.')
param fslogixOfficeProvisionedIops int = 0

@minValue(0)
@description('Optional. Office provisioned v2 throughput in MiB/s. Zero calculates recommended sizing from the Office quota.')
param fslogixOfficeProvisionedThroughputMiBps int = 0

@allowed(['Inherit', 'Standard', 'Premium'])
@description('Optional. Office Azure Files tier; Inherit uses Profile tier. Ignored for Azure NetApp Files.')
param fslogixOfficeStorageTier string = 'Inherit'

@allowed(['Inherit', 'LocallyRedundant', 'ZoneRedundant'])
@description('Optional. Office Azure Files redundancy; Inherit uses Profile redundancy.')
param fslogixOfficeStorageRedundancy string = 'Inherit'

@minValue(0)
@maxValue(262144)
@description('Optional. Office Azure Files share quota in GB; 0 inherits shareSizeInGB. Ignored for Azure NetApp Files.')
param fslogixOfficeShareSizeInGB int = 0

@description('Optional. FSLogix container layout.')
@allowed([
  'CloudCacheProfileContainer'
  'CloudCacheProfileOfficeContainer'
  'ProfileContainer'
  'ProfileOfficeContainer'
])
param fslogixContainerType string = 'ProfileContainer'

@description('Optional. Profile container size configured on session hosts, in MB.')
@minValue(1)
param profileSizeInMBs int = 30000

@description('Optional. File share or Azure NetApp Files volume size, in GB.')
@minValue(1)
param shareSizeInGB int = 100

@minValue(1)
@description('Optional. Preferred Profile share or volume quota in GiB. Overrides shareSizeInGB when supplied.')
param fslogixProfileShareSizeInGB int?

@description('Optional. Azure Files storage sharding and permission model.')
@allowed([
  'None'
  'ShardOSS'
  'ShardPerms'
])
param fslogixShardOptions string = 'None'

@description('Optional. Groups granted administrative access to FSLogix storage.')
param fslogixAdminGroups entraGroupType[] = []

@description('Optional. Groups granted user access to FSLogix storage and used for sharding.')
param fslogixUserGroups entraGroupType[] = []

@description('Optional. Lowercase alphanumeric Azure Files storage account name prefix override. The module appends a two-digit index.')
@maxLength(13)
param storageAccountNamePrefix string = ''

@maxLength(13)
@description('Optional. Preferred Profile Azure Files account prefix. Overrides storageAccountNamePrefix, including an empty value to use generated naming.')
param fslogixProfileStorageAccountNamePrefix string?

@description('Optional. Separate Office Azure Files prefix override, 3-13 lowercase alphanumeric characters. Blank uses the generated fsloc prefix with the paired two-digit index.')
@maxLength(13)
param officeStorageAccountNamePrefix string = ''

@description('Optional. Starting index appended to Azure Files storage account names.')
@minValue(0)
@maxValue(99)
param storageIndex int = 1

@description('Optional. Resource ID recorded as the Cost Management parent tag on deployed resources.')
param parentResourceId string = ''

@description('Optional. Deploy private endpoints for Azure Files storage accounts.')
param privateEndpoint bool = true

@description('Optional. Resource ID of the subnet used by Azure Files private endpoints.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. Resource ID of the Azure Files private DNS zone.')
param azureFilePrivateDnsZoneResourceId string = ''

@description('Required when privateEndpoint is true. Naming convention for private endpoints. Supports RESOURCE, SUBRESOURCE, and VNETID tokens.')
param privateEndpointNameConvention string = ''

@description('Required when privateEndpoint is true. Naming convention for private endpoint NICs. Supports RESOURCE, SUBRESOURCE, and VNETID tokens.')
param privateEndpointNicNameConvention string = ''

@description('Optional. IP addresses or CIDR blocks permitted through the Azure Files firewall.')
param permittedIPs string[] = []

@description('Optional. Azure Files public-access mode. Auto preserves legacy private-endpoint/IP inference; does not alter existing resources, NetApp Files or backup vault access.')
param paasPublicNetworkAccess publicNetworkAccessMode = 'Auto'

@description('Optional. Resource ID of an existing Log Analytics workspace for storage diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Storage encryption key management mode.')
@allowed([
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
param keyManagementStorage string = 'PlatformManaged'

@description('Optional. Resource ID of the existing Key Vault where Azure Files customer-managed keys are created.')
param existingEncryptionKeyVaultResourceId string = ''

@description('Optional. Number of days before Azure Files customer-managed keys expire and rotate.')
@minValue(7)
param keyExpirationInDays int = 180

@description('Optional. Name override for the user-assigned identity created for Azure Files customer-managed encryption.')
param encryptionUserAssignedIdentityName string = ''

@description('Optional. Number of days to retain deleted Azure file shares.')
@minValue(1)
@maxValue(365)
param softDeleteRetentionDays int = 14

@description('Optional. Resource ID of an existing Recovery Services vault used for Azure Files backup.')
param recoveryServicesVaultResourceId string = ''

@description('Optional. Name of the Azure Files backup policy in the Recovery Services vault.')
param fileSharePolicyName string = 'filesharepolicy'

@description('Optional. Create a snapshot backup vault and policy when no existing vault ID is supplied. Azure Files only.')
param deployFSLogixBackupVault bool = false

@description('Optional. Shared uses the regional operations resource group; Dedicated uses the storage resource group.')
@allowed([
  'Shared'
  'Dedicated'
])
param backupVaultScope string = 'Shared'

@description('Optional. Name override for a newly deployed backup vault.')
param backupVaultName string = ''

@description('Optional. Operations resource group name override for a new Shared backup vault. Dedicated always uses the storage resource group.')
param backupResourceGroupName string = ''

@description('Optional. Daily snapshot retention for a newly deployed backup policy.')
@minValue(1)
@maxValue(200)
param fslogixBackupRetentionDays int = 30

@description('Optional. Windows time zone for the new backup policy daily schedule at 23:00.')
param fslogixBackupTimeZone string = 'UTC'

@description('Optional. Indicates that the Azure NetApp account already has the required Active Directory connection.')
param existingSharedActiveDirectoryConnection bool = false

@description('Optional. Controls whether the Azure NetApp Files account and capacity pool are created or reused. Volumes are always created.')
@allowed([
  'CreateAll'
  'ExistingAccountNewPool'
  'ExistingAccountAndPool'
])
param netAppDeploymentMode string = 'CreateAll'

@description('Optional. Azure NetApp Files account name.')
param netAppAccountName string = ''

@description('Optional. Azure NetApp Files capacity pool name.')
param netAppCapacityPoolName string = ''

@description('Optional. Resource ID of the subnet delegated to Microsoft.NetApp/volumes.')
param netAppVolumesSubnetResourceId string = ''

@description('Optional. Short location token used in the Azure NetApp Files SMB server name.')
param smbServerLocation string = ''

@description('Optional. Existing remote Azure Files storage account resource IDs included in the session-host configuration output.')
param remoteStorageAccountResourceIds string[] = []

@description('Conditional. Remote Office Azure Files account IDs paired with remoteStorageAccountResourceIds in the same shard order. Required with remote Profile accounts and Office containers; cannot overlap Profile accounts.')
param remoteOfficeStorageAccountResourceIds string[] = []

@description('Optional. Existing remote Azure NetApp Files volume resource IDs included in the session-host configuration output.')
param remoteNetAppVolumeResourceIds string[] = []

@description('Optional. Tags keyed by Azure resource type, matching the host pool deployment tag contract.')
param tags object = {}

var fslogixShareNamesLookup = {
  CloudCacheProfileContainer: [
    'profile-containers'
  ]
  CloudCacheProfileOfficeContainer: [
    'profile-containers'
    'office-containers'
  ]
  ProfileContainer: [
    'profile-containers'
  ]
  ProfileOfficeContainer: [
    'profile-containers'
    'office-containers'
  ]
}

var storageSolution = split(fslogixStorageService, ' ')[0]
var azureFilesTuningIsValid = storageSolution != 'AzureNetAppFiles' || (fslogixProfileStorageTier == null && (fslogixProfileStorageRedundancy == null || fslogixProfileStorageRedundancy == 'LocallyRedundant') && empty(fslogixProfileStorageAccountNamePrefix) && fslogixProfileStorageBillingModel == 'Legacy' && fslogixOfficeStorageBillingModel == 'Inherit' && fslogixProfileProvisionedIops == 0 && fslogixProfileProvisionedThroughputMiBps == 0 && fslogixOfficeProvisionedIops == 0 && fslogixOfficeProvisionedThroughputMiBps == 0 && fslogixOfficeStorageTier == 'Inherit' && fslogixOfficeStorageRedundancy == 'Inherit' && fslogixOfficeShareSizeInGB == 0)
  ? true
  : fail('Azure Files tier, billing, redundancy and performance tuning cannot be used with Azure NetApp Files.')
var storageSku = azureFilesTuningIsValid && storageSolution == 'AzureFiles'
  ? fslogixProfileStorageTier ?? split(fslogixStorageService, ' ')[1]
  : split(fslogixStorageService, ' ')[1]
var effectiveProfileStorageRedundancy = fslogixProfileStorageRedundancy ?? fslogixStorageRedundancy
var effectiveProfileShareSizeInGB = fslogixProfileShareSizeInGB ?? shareSizeInGB
var effectiveOfficeStorageBillingModel = fslogixOfficeStorageBillingModel == 'Inherit' ? fslogixProfileStorageBillingModel : fslogixOfficeStorageBillingModel == 'ProvisionedV2' ? 'ProvisionedV2' : 'Legacy'
var officeEnabled = contains(fslogixContainerType, 'OfficeContainer')
var effectiveOfficeStorageSku = fslogixOfficeStorageTier == 'Inherit' ? storageSku : fslogixOfficeStorageTier
var effectiveOfficeStorageRedundancy = fslogixOfficeStorageRedundancy == 'Inherit' ? effectiveProfileStorageRedundancy : fslogixOfficeStorageRedundancy
var effectiveOfficeShareSizeInGB = fslogixOfficeShareSizeInGB == 0 ? effectiveProfileShareSizeInGB : fslogixOfficeShareSizeInGB
var createFSLogixBackupVault = storageSolution == 'AzureFiles' && deployFSLogixBackupVault && empty(recoveryServicesVaultResourceId)
var effectiveBackupResourceGroupName = backupVaultScope == 'Dedicated'
  ? effectiveStorageResourceGroupName
  : !empty(backupResourceGroupName) ? backupResourceGroupName : backupNaming.operationsResourceGroupName
var effectiveBackupVaultName = !empty(backupVaultName)
  ? backupVaultName
  : backupVaultScope == 'Shared'
      ? backupNaming.fslogixBackupVaultName
      : resourceNameForType(namingConvention, 'Microsoft.RecoveryServices/vaults', '${identifier}-backup', {
          subscriptionId: subscription().subscriptionId
          resourceGroupName: effectiveStorageResourceGroupName
          cloud: environment().name
          location: location
        })
var backupConfigurationIsValid = storageSolution == 'AzureFiles' || (!deployFSLogixBackupVault && empty(recoveryServicesVaultResourceId))
  ? true
  : fail('Recovery Services snapshot backup is supported only for Azure Files.')
var backupResourceGroupNamesAreDistinct = !deployDeploymentVirtualMachine || ((!createFSLogixBackupVault || toLower(effectiveBackupResourceGroupName) != toLower(effectiveDeploymentResourceGroupName)) && (empty(recoveryServicesVaultResourceId) || toLower(split(recoveryServicesVaultResourceId, '/')[4]) != toLower(effectiveDeploymentResourceGroupName)))
  ? true
  : fail('The backup vault must not reside in the temporary deployment resource group, which cleanup deletes.')
var effectiveRecoveryServicesVaultResourceId = createFSLogixBackupVault
  ? fslogixBackupVault!.outputs.recoveryServicesVaultResourceId
  : recoveryServicesVaultResourceId
var effectiveStorageResourceGroupName = !empty(storageResourceGroupName) ? storageResourceGroupName : naming.resourceGroupStorage
var effectiveDeploymentResourceGroupName = !empty(deploymentResourceGroupName) ? deploymentResourceGroupName : naming.resourceGroupDeployment
var effectiveDeploymentVirtualMachineName = !empty(deploymentVirtualMachineName) ? deploymentVirtualMachineName : naming.depVirtualMachineName
var effectiveDeploymentVirtualMachineDiskName = !empty(deploymentVirtualMachineDiskName) ? deploymentVirtualMachineDiskName : naming.depVirtualMachineDiskName
var effectiveDeploymentVirtualMachineNicName = !empty(deploymentVirtualMachineNicName) ? deploymentVirtualMachineNicName : naming.depVirtualMachineNicName
var effectiveDeploymentUserAssignedIdentityName = !empty(deploymentUserAssignedIdentityName)
  ? deploymentUserAssignedIdentityName
  : replace(naming.userAssignedIdentityNameConv, 'TOKEN', 'deployment')
var selectedProfileStorageAccountNamePrefix = fslogixProfileStorageAccountNamePrefix ?? storageAccountNamePrefix
var effectiveStorageAccountNamePrefix = !empty(selectedProfileStorageAccountNamePrefix) ? selectedProfileStorageAccountNamePrefix : naming.fslogixStorageAccountNamePrefix
var effectiveOfficeStorageAccountNamePrefix = !empty(officeStorageAccountNamePrefix) ? officeStorageAccountNamePrefix : naming.fslogixOfficeStorageAccountNamePrefix
var officeStorageAccountPrefixIsValid = storageSolution != 'AzureFiles' || !officeEnabled || (length(effectiveOfficeStorageAccountNamePrefix) >= 3 && length(effectiveOfficeStorageAccountNamePrefix) <= 13 && empty(filter(range(0, length(effectiveOfficeStorageAccountNamePrefix)), i => !contains('abcdefghijklmnopqrstuvwxyz0123456789', substring(effectiveOfficeStorageAccountNamePrefix, i, 1)))))
  ? true
  : fail('Office storage account prefixes must contain 3-13 lowercase alphanumeric characters.')
var officeStorageAccountPrefixesAreDistinct = storageSolution != 'AzureFiles' || !officeEnabled || toLower(effectiveStorageAccountNamePrefix) != toLower(effectiveOfficeStorageAccountNamePrefix)
  ? true
  : fail('Profile and Office Azure Files storage account prefixes must differ. Existing data is not moved, renamed, or deleted.')
var effectivePrivateEndpointNameConvention = !empty(privateEndpointNameConvention) ? privateEndpointNameConvention : naming.privateEndpointNameConv
var effectivePrivateEndpointNicNameConvention = !empty(privateEndpointNicNameConvention) ? privateEndpointNicNameConvention : naming.privateEndpointNICNameConv
var effectiveEncryptionUserAssignedIdentityName = !empty(encryptionUserAssignedIdentityName)
  ? encryptionUserAssignedIdentityName
  : replace(naming.userAssignedIdentityNameConv, 'TOKEN', 'storage${naming.delimiter}cmk')
var effectiveNetAppAccountName = !empty(netAppAccountName) ? netAppAccountName : naming.netAppAccountName
var effectiveNetAppCapacityPoolName = !empty(netAppCapacityPoolName) ? netAppCapacityPoolName : naming.netAppCapacityPoolName
var effectiveSmbServerLocation = !empty(smbServerLocation) ? smbServerLocation : naming.vmsLocAbbr
var fileShareNames = fslogixShareNamesLookup[fslogixContainerType]
var storageCount = identitySolution == 'EntraId' || fslogixShardOptions == 'None' ? 1 : length(fslogixUserGroups)
var remoteStorageAccountConfigurationIsValid = empty(remoteStorageAccountResourceIds) || length(remoteStorageAccountResourceIds) == storageCount
  ? true
  : fail('remoteStorageAccountResourceIds must contain one storage account per local FSLogix storage account.')
var remoteProfileAccountIds = map(concat(
  map(range(0, storageCount), i => resourceId(subscription().subscriptionId, effectiveStorageResourceGroupName, 'Microsoft.Storage/storageAccounts', '${effectiveStorageAccountNamePrefix}${padLeft(i + storageIndex, 2, '0')}')),
  remoteStorageAccountResourceIds
), id => toLower(id))
var remoteOfficeAccountIds = map(concat(
  officeEnabled ? map(range(0, storageCount), i => resourceId(subscription().subscriptionId, effectiveStorageResourceGroupName, 'Microsoft.Storage/storageAccounts', '${effectiveOfficeStorageAccountNamePrefix}${padLeft(i + storageIndex, 2, '0')}')) : [],
  remoteOfficeStorageAccountResourceIds
), id => toLower(id))
var remoteOfficeStorageAccountConfigurationIsValid = storageSolution != 'AzureFiles' || !officeEnabled || (length(remoteOfficeStorageAccountResourceIds) == length(remoteStorageAccountResourceIds) && empty(intersection(remoteProfileAccountIds, remoteOfficeAccountIds)) && length(remoteProfileAccountIds) == length(union(remoteProfileAccountIds, remoteProfileAccountIds)) && length(remoteOfficeAccountIds) == length(union(remoteOfficeAccountIds, remoteOfficeAccountIds)))
  ? true
  : fail('Remote Office accounts must be separate from Profile accounts and paired one-for-one in the same shard order. No Profile-account fallback is permitted.')
var remoteNetAppConfigurationIsValid = empty(remoteNetAppVolumeResourceIds) || length(remoteNetAppVolumeResourceIds) == length(fileShareNames)
  ? true
  : fail('remoteNetAppVolumeResourceIds must contain one volume per FSLogix share, in profile-then-Office order.')
var shardingConfigurationIsValid = fslogixShardOptions == 'None' || !empty(fslogixUserGroups)
  ? true
  : fail('fslogixUserGroups must contain at least one group when sharding is enabled.')
var storageIdentityConfigurationIsValid = storageSolution != 'AzureNetAppFiles' || contains(identitySolution, 'DomainServices')
  ? true
  : fail('Azure NetApp Files requires ActiveDirectoryDomainServices or EntraDomainServices.')
var netAppResourceGroupConfigurationIsValid = storageSolution != 'AzureNetAppFiles' || netAppDeploymentMode == 'CreateAll' || !createStorageResourceGroup
  ? true
  : fail('An existing storage resource group is required when reusing an Azure NetApp Files account or capacity pool.')
var deploymentVirtualMachineRequired = identitySolution != 'EntraId'
var deployDeploymentVirtualMachine = manageDeploymentVirtualMachine && deploymentVirtualMachineRequired
var deploymentVmDomainJoinIsValid = !domainJoinDeploymentVirtualMachine || (deployDeploymentVirtualMachine && contains(identitySolution, 'DomainServices') && !empty(domainName) && (!empty(credentialsKeyVaultResourceId) || (!empty(domainJoinUserPrincipalName) && !empty(domainJoinUserPassword))))
  ? true
  : fail('domainJoinDeploymentVirtualMachine requires an add-on-managed deployment VM, ActiveDirectoryDomainServices or EntraDomainServices, domainName, and domain-join credentials or credentialsKeyVaultResourceId. Join an externally managed VM through its owning deployment.')
var resourceGroupNamesAreDistinct = !deployDeploymentVirtualMachine || toLower(effectiveStorageResourceGroupName) != toLower(effectiveDeploymentResourceGroupName)
  ? true
  : fail('The temporary deployment resource group must differ from the storage resource group because cleanup deletes the entire temporary group.')
var deployStorageCmk = storageSolution == 'AzureFiles' && contains(keyManagementStorage, 'CustomerManaged')
var storageCmkConfigurationIsValid = !deployStorageCmk || !empty(existingEncryptionKeyVaultResourceId)
  ? true
  : fail('existingEncryptionKeyVaultResourceId is required when Azure Files uses customer-managed keys.')
var domainCredentialsRequired = contains(identitySolution, 'DomainServices') || storageSolution == 'AzureNetAppFiles' || (identitySolution == 'EntraKerberos-Hybrid' && !empty(fslogixUserGroups))
var externalDeploymentConfigurationIsValid = !deploymentVirtualMachineRequired || manageDeploymentVirtualMachine || (!empty(deploymentVirtualMachineName) && !empty(existingDeploymentUserAssignedIdentityClientId))
  ? true
  : fail('deploymentVirtualMachineName and existingDeploymentUserAssignedIdentityClientId are required when manageDeploymentVirtualMachine is false.')

var naming = fslogixNames(namingConvention, identifier, {
  subscriptionId: subscription().subscriptionId
  cloud: environment().name
  location: location
})
var backupNaming = sharedServicesNames(namingConvention, {
  subscriptionId: subscription().subscriptionId
  cloud: environment().name
  location: location
}, {})

resource credentialsKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(credentialsKeyVaultResourceId)) {
  name: last(split(credentialsKeyVaultResourceId, '/'))
  scope: resourceGroup(split(credentialsKeyVaultResourceId, '/')[2], split(credentialsKeyVaultResourceId, '/')[4])
}

resource encryptionKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (deployStorageCmk && !empty(existingEncryptionKeyVaultResourceId)) {
  name: last(split(existingEncryptionKeyVaultResourceId, '/'))
  scope: resourceGroup(split(existingEncryptionKeyVaultResourceId, '/')[2], split(existingEncryptionKeyVaultResourceId, '/')[4])
}

module storageResourceGroup '../../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (createStorageResourceGroup) {
  params: {
    name: effectiveStorageResourceGroupName
    location: location
    tags: union(
      tags[?'Microsoft.Resources/resourceGroups'] ?? {},
      empty(parentResourceId) ? {} : { 'cm-resource-parent': parentResourceId }
    )
  }
}

module deploymentResourceGroup '../../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (deployDeploymentVirtualMachine) {
  params: {
    name: resourceGroupNamesAreDistinct ? effectiveDeploymentResourceGroupName : effectiveDeploymentResourceGroupName
    location: location
    tags: union(
      tags[?'Microsoft.Resources/resourceGroups'] ?? {},
      empty(parentResourceId) ? {} : { 'cm-resource-parent': parentResourceId }
    )
  }
}

module deploymentHelper '../../shared/modules/orchestration/deploymentHelper/deploy.bicep' = if (deployDeploymentVirtualMachine) {
  params: {
    confidentialVMOSDiskEncryption: false
    desktopFriendlyName: ''
    encryptionAtHost: true
    fslogix: true
    fslogixAppUpdateUserAssignedIdentityResourceId: appUpdateUserAssignedIdentityResourceId
    hostPoolName: ''
    keyManagementDisks: 'PlatformManaged'
    keyManagementStorageAccounts: 'PlatformManaged'
    location: location
    deploymentVmSize: deploymentVirtualMachineSize
    domainJoinUserPassword: domainCredentialsRequired
      ? !empty(domainJoinUserPassword)
        ? domainJoinUserPassword
        : !empty(credentialsKeyVaultResourceId) ? credentialsKeyVault!.getSecret('DomainJoinUserPassword') : ''
      : ''
    domainJoinUserPrincipalName: domainCredentialsRequired
      ? !empty(domainJoinUserPrincipalName)
        ? domainJoinUserPrincipalName
        : !empty(credentialsKeyVaultResourceId) ? credentialsKeyVault!.getSecret('DomainJoinUserPrincipalName') : ''
      : ''
    domainName: domainName
    domainJoinDeploymentVirtualMachine: domainJoinDeploymentVirtualMachine || storageSolution == 'AzureNetAppFiles'
    identitySolution: identitySolution
    ouPath: !empty(deploymentVirtualMachineOrganizationalUnitPath)
      ? deploymentVirtualMachineOrganizationalUnitPath
      : organizationalUnitPath
    parentResourceId: parentResourceId
    resourceGroupControlPlane: effectiveStorageResourceGroupName
    resourceGroupDeployment: effectiveDeploymentResourceGroupName
    resourceGroupHosts: effectiveStorageResourceGroupName
    resourceGroupSecurity: effectiveStorageResourceGroupName
    resourceGroupStorage: effectiveStorageResourceGroupName
    tags: tags
    userAssignedIdentityName: effectiveDeploymentUserAssignedIdentityName
    virtualMachineName: effectiveDeploymentVirtualMachineName
    virtualMachineNICName: effectiveDeploymentVirtualMachineNicName
    virtualMachineDiskName: effectiveDeploymentVirtualMachineDiskName
    virtualMachineSubnetResourceId: !deployDeploymentVirtualMachine || !empty(deploymentVirtualMachineSubnetResourceId)
      ? deploymentVirtualMachineSubnetResourceId
      : fail('deploymentVirtualMachineSubnetResourceId is required when the add-on creates a temporary deployment VM.')
    manageHostResourcePermissions: false
  }
  dependsOn: [
    deploymentResourceGroup
    storageResourceGroup
  ]
}

module storageCmk '../../shared/modules/orchestration/customerManagedKeys/storageCmk.bicep' = if (deployStorageCmk && storageCmkConfigurationIsValid) {
  params: {
    resourceGroupName: effectiveStorageResourceGroupName
    keyVaultResourceId: existingEncryptionKeyVaultResourceId
    keyManagementType: contains(keyManagementStorage, 'HSM') ? 'CustomerManagedHSM' : 'CustomerManaged'
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    parentResourceId: parentResourceId
    storageKeyNames: concat(
      map(range(0, storageCount), i => replace(naming.encryptionKeyNameFSLogix, '##', padLeft(i + storageIndex, 2, '0'))),
      officeEnabled ? map(range(0, storageCount), i => replace(naming.encryptionKeyNameFSLogixOffice, '##', padLeft(i + storageIndex, 2, '0'))) : []
    )
    identityName: effectiveEncryptionUserAssignedIdentityName
  }
  dependsOn: [storageResourceGroup]
}

module backupResourceGroup '../../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (createFSLogixBackupVault && backupVaultScope == 'Shared') {
  params: {
    name: backupResourceGroupNamesAreDistinct ? effectiveBackupResourceGroupName : effectiveBackupResourceGroupName
    location: location
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

// Snapshot data remains in Azure Files; this metadata vault does not require a backup private endpoint.
// Existing vaults and policies are never modified by this add-on.
module fslogixBackupVault '../../shared/modules/resourceModules/recoveryServices/fslogixBackupVault.bicep' = if (createFSLogixBackupVault) {
  params: {
    createVault: true
    manageBackupPolicy: true
    vaultName: effectiveBackupVaultName
    resourceGroupOperations: effectiveBackupResourceGroupName
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    privateEndpoint: false
    privateEndpointNameConv: effectivePrivateEndpointNameConvention
    privateEndpointNICNameConv: effectivePrivateEndpointNicNameConvention
    tags: union(tags, {
      'Microsoft.RecoveryServices/vaults': union(
        tags[?'Microsoft.RecoveryServices/vaults'] ?? {},
        backupVaultScope == 'Dedicated' && !empty(parentResourceId) ? { 'cm-resource-parent': parentResourceId } : {}
      )
    })
    timeZone: fslogixBackupTimeZone
    fileSharePolicyName: fileSharePolicyName
    backupRetentionDays: fslogixBackupRetentionDays
  }
  dependsOn: [backupResourceGroup, storageResourceGroup]
}

module fslogix '../../shared/modules/orchestration/fslogix/fslogix.bicep' = {
  params: {
    activeDirectoryConnection: storageIdentityConfigurationIsValid && netAppResourceGroupConfigurationIsValid && deploymentVmDomainJoinIsValid
      ? netAppDeploymentMode == 'CreateAll' || existingSharedActiveDirectoryConnection
      : existingSharedActiveDirectoryConnection
    createNetAppAccount: netAppDeploymentMode == 'CreateAll'
    createNetAppCapacityPool: netAppDeploymentMode != 'ExistingAccountAndPool'
    appUpdateUserAssignedIdentityResourceId: appUpdateUserAssignedIdentityResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    deploymentUserAssignedIdentityClientId: !deploymentVirtualMachineRequired
      ? ''
      : externalDeploymentConfigurationIsValid
          ? (deployDeploymentVirtualMachine
              ? deploymentHelper!.outputs.deploymentUserAssignedIdentityClientId
              : existingDeploymentUserAssignedIdentityClientId)
          : existingDeploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: !deploymentVirtualMachineRequired
      ? ''
      : externalDeploymentConfigurationIsValid
          ? (deployDeploymentVirtualMachine ? deploymentHelper!.outputs.virtualMachineName : deploymentVirtualMachineName)
          : deploymentVirtualMachineName
    #disable-next-line BCP422
    domainJoinUserPassword: domainCredentialsRequired
      ? !empty(domainJoinUserPassword)
        ? domainJoinUserPassword
        : !empty(credentialsKeyVaultResourceId) ? credentialsKeyVault!.getSecret('DomainJoinUserPassword') : ''
      : ''
    #disable-next-line BCP422
    domainJoinUserPrincipalName: domainCredentialsRequired
      ? !empty(domainJoinUserPrincipalName)
        ? domainJoinUserPrincipalName
        : !empty(credentialsKeyVaultResourceId) ? credentialsKeyVault!.getSecret('DomainJoinUserPrincipalName') : ''
      : ''
    domainName: domainName
    #disable-next-line BCP318
    encryptionKeyVaultUri: deployStorageCmk ? encryptionKeyVault!.properties.vaultUri : ''
    encryptionUserAssignedIdentityResourceId: deployStorageCmk ? storageCmk!.outputs.storageEncryptionIdentityResourceId : ''
    fileSharePolicyName: backupConfigurationIsValid && backupResourceGroupNamesAreDistinct ? fileSharePolicyName : fileSharePolicyName
    fslogixAdminGroups: fslogixAdminGroups
    fslogixEncryptionKeyNameConv: naming.encryptionKeyNameFSLogix
    officeEncryptionKeyNameConv: naming.encryptionKeyNameFSLogixOffice
    fslogixFileShares: fileShareNames
    fslogixShardOptions: shardingConfigurationIsValid ? fslogixShardOptions : fslogixShardOptions
    fslogixSoftDeleteRetentionDays: softDeleteRetentionDays
    fslogixStorageRedundancy: effectiveProfileStorageRedundancy
    fslogixUserGroups: fslogixUserGroups
    hostPoolResourceId: parentResourceId
    identitySolution: identitySolution
    keyManagementStorageAccounts: keyManagementStorage
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    netAppAccountName: effectiveNetAppAccountName
    netAppCapacityPoolName: effectiveNetAppCapacityPoolName
    netAppVolumesSubnetResourceId: netAppVolumesSubnetResourceId
    ouPath: organizationalUnitPath
    permittedIPs: permittedIPs
    paasPublicNetworkAccess: paasPublicNetworkAccess
    privateEndpoint: privateEndpoint
    privateEndpointNameConv: effectivePrivateEndpointNameConvention
    privateEndpointNICNameConv: effectivePrivateEndpointNicNameConvention
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    recoveryServicesVaultResourceId: effectiveRecoveryServicesVaultResourceId
    resourceGroupDeployment: effectiveDeploymentResourceGroupName
    resourceGroupStorage: effectiveStorageResourceGroupName
    shareSizeInGB: effectiveProfileShareSizeInGB
    profileStorageBillingModel: fslogixProfileStorageBillingModel
    officeStorageBillingModel: effectiveOfficeStorageBillingModel
    profileProvisionedIops: fslogixProfileProvisionedIops
    profileProvisionedThroughputMiBps: fslogixProfileProvisionedThroughputMiBps
    officeProvisionedIops: fslogixOfficeProvisionedIops
    officeProvisionedThroughputMiBps: fslogixOfficeProvisionedThroughputMiBps
    smbServerLocation: effectiveSmbServerLocation
    storageAccountNamePrefix: effectiveStorageAccountNamePrefix
    officeStorageAccountNamePrefix: officeStorageAccountPrefixIsValid && officeStorageAccountPrefixesAreDistinct ? effectiveOfficeStorageAccountNamePrefix : effectiveOfficeStorageAccountNamePrefix
    officeStorageSku: effectiveOfficeStorageSku
    officeStorageRedundancy: effectiveOfficeStorageRedundancy
    officeShareSizeInGB: effectiveOfficeShareSizeInGB
    storageCount: remoteStorageAccountConfigurationIsValid && remoteOfficeStorageAccountConfigurationIsValid ? storageCount : storageCount
    storageIndex: storageIndex
    storageSku: storageSku
    storageSolution: storageSolution
    tags: tags
  }
  dependsOn: [storageResourceGroup]
}

module remoteNetAppVolumeFqdns '../../shared/modules/orchestration/fslogix/modules/getNetAppVolumeSmbServerFqdns.bicep' = if (!empty(remoteNetAppVolumeResourceIds)) {
  params: {
    localNetAppVolumeResourceIds: []
    remoteNetAppVolumeResourceIds: remoteNetAppConfigurationIsValid ? remoteNetAppVolumeResourceIds : []
    shareNames: fileShareNames
  }
}

module cleanupDeploymentHelper '../../shared/modules/orchestration/deploymentHelper/cleanup.bicep' = if (deployDeploymentVirtualMachine) {
  params: {
    location: location
    resourceGroupDeployment: effectiveDeploymentResourceGroupName
    resourceGroupHosts: effectiveStorageResourceGroupName
    userAssignedIdentityClientId: deploymentHelper!.outputs.deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deploymentHelper!.outputs.virtualMachineName
    roleAssignmentIds: deploymentHelper!.outputs.deploymentUserAssignedIdentityRoleAssignmentIds
    virtualMachineNames: []
    removeHostRunCommands: false
  }
  dependsOn: [fslogix]
}

output fslogixConfiguration object = {
  identitySolution: identitySolution
  storageService: storageSolution
  containerType: fslogixContainerType
  fileShareNames: fileShareNames
  localStorageAccountResourceIds: fslogix.outputs.storageAccountResourceIds
  remoteStorageAccountResourceIds: remoteStorageAccountConfigurationIsValid ? remoteStorageAccountResourceIds : []
  localOfficeStorageAccountResourceIds: fslogix.outputs.officeStorageAccountResourceIds
  remoteOfficeStorageAccountResourceIds: remoteOfficeStorageAccountConfigurationIsValid ? remoteOfficeStorageAccountResourceIds : []
  localNetAppServerFqdns: fslogix.outputs.netAppServerFqdns
  remoteNetAppServerFqdns: empty(remoteNetAppVolumeResourceIds) ? [] : remoteNetAppVolumeFqdns!.outputs.remoteNetAppVolumeSmbServerFqdns
  objectSpecificSettingsGroups: fslogixShardOptions == 'ShardOSS' ? map(fslogixUserGroups, group => group.name) : []
  profileSizeInMBs: profileSizeInMBs
}
output netAppServerFqdns array = fslogix.outputs.netAppServerFqdns
output netAppVolumeResourceIds array = fslogix.outputs.netAppVolumeResourceIds
output storageAccountResourceIds array = fslogix.outputs.storageAccountResourceIds
output officeStorageAccountResourceIds array = fslogix.outputs.officeStorageAccountResourceIds

@description('Selected snapshot backup vault ID; empty when backup is disabled.')
output fslogixBackupVaultResourceId string = effectiveRecoveryServicesVaultResourceId

@description('Selected snapshot backup policy name; empty when backup is disabled.')
output fslogixBackupPolicyName string = empty(effectiveRecoveryServicesVaultResourceId) ? '' : fileSharePolicyName

@description('Selected snapshot backup policy resource ID; empty when backup is disabled.')
output fslogixBackupPolicyResourceId string = empty(effectiveRecoveryServicesVaultResourceId)
  ? ''
  : '${effectiveRecoveryServicesVaultResourceId}/backupPolicies/${fileSharePolicyName}'
