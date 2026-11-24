metadata name = 'FSLogix Azure Files orchestration'
metadata description = 'Creates indexed storage accounts, SMB shares, optional private endpoints, administrator RBAC, and identity-dependent configuration through an existing deployment helper VM.'

import { publicNetworkAccessMode, resolveNetworkAccess } from '../../networking/functions.bicep'
import { resolveFilesConfiguration, fslogixShareNames } from 'configuration.bicep'

@description('Required. Resource ID of the storage application update identity attached to the helper VM; empty skips application manifest and consent commands.')
param appUpdateUserAssignedIdentityResourceId string

@description('Required. Resource ID of an existing Azure Files private DNS zone; empty omits the private endpoint DNS zone group.')
param azureFilePrivateDnsZoneResourceId string
@description('Required. Client ID of the identity attached to the helper VM and authorized for storage configuration.')
param deploymentUserAssignedIdentityClientId string
@description('Required. Name of the existing deployment helper VM used to execute storage or cleanup Run Commands.')
param deploymentVirtualMachineName string
@secure()
@description('Required. Domain account password used when domain operations are selected; otherwise pass an empty string.')
param domainJoinUserPassword string
@secure()
@description('Required. Domain account UPN used when domain operations are selected; otherwise pass an empty string.')
param domainJoinUserPrincipalName string
@description('Required. DNS domain name for selected domain operations; otherwise pass an empty string.')
param domainName string
@description('Required. Key name pattern containing ## for the two-digit storage account index; used with customer-managed encryption.')
param fslogixProfileEncryptionKeyNameConv string
@description('Required. URI of the existing encryption Key Vault, including the trailing slash; used for customer-managed storage keys.')
param encryptionKeyVaultUri string
@description('Required. Resource ID of the existing identity authorized to use the storage encryption keys; unused for PlatformManaged encryption.')
param encryptionUserAssignedIdentityResourceId string
@description('Required. FSLogix container selection; determines separate Profile and optional Office accounts.')
param containerType string
@description('Optional. Resource ID of the associated AVD host pool, used for resource ownership tags.')
param hostPoolResourceId string = ''
@description('Required. Selected session-host or SMB identity mode used to choose domain, Entra, and storage configuration paths.')
param identitySolution string
@description('Required. Kerberos ticket encryption selection; RC4 selects RC4-HMAC and other values select AES-256 for Azure Files SMB settings.')
param kerberosEncryptionType string
@description('Required. Storage encryption mode; PlatformManaged omits customer-managed key configuration.')
param keyManagementStorageAccounts string
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Resource ID of an existing Log Analytics workspace; empty omits storage and file-service diagnostics.')
param logAnalyticsWorkspaceId string
@description('Required. Distinguished name of the target organizational unit for selected domain operations; empty uses the domain default.')
param ouPath string
@description('Required. Whether to create private endpoints. Public access is controlled separately by paasPublicNetworkAccess.')
param privateEndpoint bool
@description('Required. Private endpoint name pattern using RESOURCE, SUBRESOURCE, and VNETID substitution tokens.')
param privateEndpointNameConv string
@description('Required. Private endpoint NIC name pattern using RESOURCE, SUBRESOURCE, and VNETID substitution tokens.')
param privateEndpointNICNameConv string
@description('Required. Resource ID of the existing subnet for private endpoints; required when endpoint creation is selected.')
param privateEndpointSubnetResourceId string
@description('Required. Name of the existing helper VM resource group for storage configuration Run Commands.')
param deploymentResourceGroupName string
@description('Required. Name of the existing storage resource group in this subscription.')
param resourceGroupStorage string
@description('Required. Sharding selection forwarded to the permissions command; None disables Azure Files sharding.')
param shardingOptions string
@description('Required. Array of administrator group objects with id and name for Azure Files RBAC or NetApp/domain permissions.')
param shareAdminGroups array
@description('Required. Quota per file share or NetApp volume in GiB.')
param shareSizeInGB int
@description('Required. Array of user group objects with id and name; the selected identity mode determines which field is forwarded.')
param shareUserGroups array
@description('Required. Prefix for storage account names, followed by a two-digit index starting at storageIndex.')
param profileStorageAccountNamePrefix string
@description('Required. Distinct Office account prefix; Office accounts use the same shard indices as Profile accounts.')
@minLength(3)
@maxLength(13)
param officeStorageAccountNamePrefix string
@description('Required. Office encryption-key name pattern containing ##; unused with platform-managed encryption.')
param officeEncryptionKeyNameConv string
@description('Required. Number of indexed Azure Files storage accounts to create.')
param storageCount int
@description('Required. Starting numeric index for storage account and encryption-key names.')
param storageIndex int
@description('Required. Storage tier: Standard or Premium for Azure Files, or the NetApp service level for NetApp volumes.')
param storageSku string
@description('Optional. Office Azure Files tier; defaults to the Profile tier.')
param officeStorageSku string = storageSku
@description('Optional. Office share quota in GiB; defaults to the Profile quota.')
param officeShareSizeInGB int = shareSizeInGB
@description('Required. Azure Files redundancy selection; ZoneRedundant selects ZRS and other values select LRS.')
param storageRedundancy string
@description('Optional. Office Azure Files redundancy; defaults to the Profile redundancy.')
param officeStorageRedundancy string = storageRedundancy
@allowed(['Legacy', 'ProvisionedV2'])
@description('Optional. Profile billing model; Legacy preserves existing deployments.')
param profileStorageBillingModel string = 'Legacy'
@allowed(['Legacy', 'ProvisionedV2'])
@description('Optional. Office billing model; defaults to the Profile model.')
param officeStorageBillingModel string = profileStorageBillingModel
@description('Optional. Profile v2 IOPS; zero selects the capacity-based recommendation.')
param profileProvisionedIops int = 0
@description('Optional. Profile v2 throughput in MiB/s; zero selects the capacity-based recommendation.')
param profileProvisionedThroughputMiBps int = 0
@description('Optional. Office v2 IOPS; zero selects the recommendation for Office capacity.')
param officeProvisionedIops int = 0
@description('Optional. Office v2 throughput in MiB/s; zero selects the recommendation for Office capacity.')
param officeProvisionedThroughputMiBps int = 0
@description('Required. Tag bags keyed by Azure resource type; each bag is applied to resources of that type.')
param tags object
@description('Optional. Array of permitted IP addresses or CIDR blocks for the FSLogix storage account firewall.')
param permittedIPs array = []

@description('Optional. Storage public-access mode. Auto preserves legacy behavior; IP rules and AzureServices bypass remain configured in all modes.')
param paasPublicNetworkAccess publicNetworkAccessMode = 'Auto'

@description('Optional. Number of days to retain deleted file shares (1–365).')
@minValue(1)
@maxValue(365)
param softDeleteRetentionDays int = 14

var adminRoleDefinitionId = '69566ab7-960f-475b-8e7c-b3118f30c6bd' // Storage File Data Privileged Contributor

var defaultSharePermission = 'StorageFileDataSmbShareContributor'

var privateEndpointVnetName = !empty(privateEndpointSubnetResourceId) && privateEndpoint
  ? split(privateEndpointSubnetResourceId, '/')[8]
  : ''

import { privateEndpointName } from '../../naming/internal.bicep'

resource privateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if (privateEndpoint && !empty(privateEndpointSubnetResourceId)) {
  name: privateEndpointVnetName
  scope: resourceGroup(split(privateEndpointSubnetResourceId, '/')[2], split(privateEndpointSubnetResourceId, '/')[4])
}

var smbSettingsValues = {
  versions: 'SMB3.0;SMB3.1.1;'
  authenticationMethods: 'NTLMv2;Kerberos;'
  kerberosTicketEncryption: kerberosEncryptionType == 'RC4' ? 'RC4-HMAC;' : 'AES-256;'
  channelEncryption: 'AES-128-CCM;AES-128-GCM;AES-256-GCM;'
}

// One template contains both roles so scripts are not duplicated in generated ARM.
// Each role owns one share and its own capacity/performance settings. storageCount is per role:
// two shards with Office enabled create two Profile accounts and two separate Office accounts.
var fileShares = fslogixShareNames(containerType)
var storageRoles = concat(
  [
    {
      prefix: profileStorageAccountNamePrefix
      keyPattern: fslogixProfileEncryptionKeyNameConv
      sku: storageSku
      configuration: resolveFilesConfiguration(storageSku, storageRedundancy, profileStorageBillingModel, shareSizeInGB, profileProvisionedIops, profileProvisionedThroughputMiBps)
      shares: take(fileShares, 1)
      shareSizeInGB: shareSizeInGB
      commandPrefix: ''
    }
  ],
  length(fileShares) > 1
    ? [
        {
          prefix: toLower(officeStorageAccountNamePrefix) != toLower(profileStorageAccountNamePrefix)
            ? officeStorageAccountNamePrefix
            : fail('Profile and Office Azure Files storage account prefixes must differ.')
          keyPattern: keyManagementStorageAccounts == 'PlatformManaged' || toLower(officeEncryptionKeyNameConv) != toLower(fslogixProfileEncryptionKeyNameConv)
            ? officeEncryptionKeyNameConv
            : fail('Profile and Office customer-managed encryption keys must use different name patterns.')
          sku: officeStorageSku
          configuration: resolveFilesConfiguration(officeStorageSku, officeStorageRedundancy, officeStorageBillingModel, officeShareSizeInGB, officeProvisionedIops, officeProvisionedThroughputMiBps)
          shares: take(skip(fileShares, 1), 1)
          shareSizeInGB: officeShareSizeInGB
          commandPrefix: 'Office-'
        }
      ]
    : []
)

// Flatten in role-major order: all Profile shards, then all Office shards.
// Both roles reuse the same index + storageIndex suffix, pairing accounts without sharing them.
// The flattened ARM loop index is not the account suffix; outputs below rely on this ordering.
var accountConfigurations = flatten(map(
  storageRoles,
  role =>
    map(
      range(0, storageCount),
      index =>
        union(role, {
          name: '${role.prefix}${padLeft(index + storageIndex, 2, '0')}'
          keyName: replace(role.keyPattern, '##', padLeft(index + storageIndex, 2, '0'))
        })
    )
))

// Network ACLs for FSLogix storage accounts.
// AzureServices bypass is required for Azure Files backup and monitoring.
var effectivePermittedIPs = filter(permittedIPs, ip => !empty(trim(ip)))
var networkAccess = resolveNetworkAccess(paasPublicNetworkAccess, privateEndpoint, !empty(effectivePermittedIPs))
var storageIpRules = [for ip in effectivePermittedIPs: { value: ip, action: 'Allow' }]
var storageNetworkAcls = {
  bypass: 'AzureServices'
  defaultAction: networkAccess.defaultAction
  ipRules: storageIpRules
  virtualNetworkRules: []
}

var parentResourceTags = !empty(hostPoolResourceId) ? { 'cm-resource-parent': hostPoolResourceId } : {}

var graphEndpoint = environment().name == 'AzureUSGovernment'
  ? 'https://graph.microsoft.us'
  : startsWith(environment().name, 'us')
      ? 'https://graph${replace(environment().suffixes.storage, 'core', '')}'
      : 'https://graph.microsoft.com'

resource appUpdateUai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (!empty(appUpdateUserAssignedIdentityResourceId)) {
  name: last(split(appUpdateUserAssignedIdentityResourceId, '/'))!
  scope: resourceGroup(
    split(appUpdateUserAssignedIdentityResourceId, '/')[2],
    split(appUpdateUserAssignedIdentityResourceId, '/')[4]
  )
}

// ─── Storage Accounts ──────────────────────────────────────────────────────────
module storageAccounts '../../../resourceModules/storage/storageAccounts/deploy.bicep' = [
  for (account, i) in accountConfigurations: {
    params: {
      name: account.name
      location: location
      kind: account.configuration.kind
      skuName: account.configuration.skuName
      tags: union(parentResourceTags, tags[?'Microsoft.Storage/storageAccounts'] ?? {})
      allowedCopyScope: privateEndpoint ? 'PrivateLink' : 'AAD'
      allowSharedKeyAccess: identitySolution == 'EntraId' ? true : false
      largeFileSharesState: account.configuration.largeFileSharesState
      sasExpirationPeriod: '180.00:00:00'
      networkAcls: storageNetworkAcls
      publicNetworkAccess: networkAccess.publicNetworkAccess
      azureFilesIdentityBasedAuthentication: identitySolution != 'EntraId'
        ? {
            defaultSharePermission: defaultSharePermission
            directoryServiceOptions: contains(identitySolution, 'EntraKerberos')
              ? 'AADKERB'
              : identitySolution == 'EntraDomainServices' ? 'AADDS' : 'None'
          }
        : {}
      cmkKeyUri: keyManagementStorageAccounts != 'PlatformManaged'
        ? '${encryptionKeyVaultUri}keys/${account.keyName}'
        : ''
      cmkUserAssignedIdentityResourceId: keyManagementStorageAccounts != 'PlatformManaged'
        ? encryptionUserAssignedIdentityResourceId
        : ''
      diagnosticSettings: !empty(logAnalyticsWorkspaceId) ? { workspaceId: logAnalyticsWorkspaceId } : null
    }
  }
]

// ─── File Services ─────────────────────────────────────────────────────────────
module fileServices '../../../resourceModules/storage/storageAccounts/fileServices/deploy.bicep' = [
  for (account, i) in accountConfigurations: {
    params: {
      storageAccountName: account.name
      smbSettings: union(smbSettingsValues, { multichannel: account.sku != 'Standard' ? { enabled: true } : null })
      shareDeleteRetentionPolicyEnabled: true
      shareDeleteRetentionPolicyDays: softDeleteRetentionDays
      diagnosticSettings: !empty(logAnalyticsWorkspaceId)
        ? {
            workspaceId: logAnalyticsWorkspaceId
            logCategories: [{ category: 'StorageDelete', enabled: true }]
          }
        : null
    }
    dependsOn: [storageAccounts]
  }
]

// ─── File Shares ───────────────────────────────────────────────────────────────
module shares 'shares.bicep' = [
  for (account, i) in accountConfigurations: {
    params: {
      fileShares: account.shares
      shareSizeInGB: account.shareSizeInGB
      StorageAccountName: account.name
      storageSku: account.sku
      accessTier: account.configuration.accessTier
      provisionedIops: account.configuration.provisionedIops
      provisionedThroughputMiBps: account.configuration.provisionedThroughputMiBps
    }
    dependsOn: [storageAccounts, fileServices]
  }
]

// ─── Private Endpoints ─────────────────────────────────────────────────────────
module privateEndpoints '../../../resourceModules/network/privateEndpoints/deploy.bicep' = [
  for (account, i) in accountConfigurations: if (privateEndpoint) {
    params: {
      name: privateEndpointName(privateEndpointNameConv, account.name, 'file', privateEndpointVnetName)
      customNetworkInterfaceName: privateEndpointName(
        privateEndpointNICNameConv,
        account.name,
        'file',
        privateEndpointVnetName
      )
      tags: union(parentResourceTags, tags[?'Microsoft.Network/privateEndpoints'] ?? {})
      location: privateEndpointVirtualNetwork!.location
      subnetResourceId: privateEndpointSubnetResourceId
      privateLinkServiceId: storageAccounts[i].outputs.resourceId
      groupId: 'file'
      privateDNSZoneIds: !empty(azureFilePrivateDnsZoneResourceId) ? [azureFilePrivateDnsZoneResourceId] : []
    }
    // File service config and share creation both mutate the storage account; private endpoint
    // creation also acquires an exclusive lock on it. Serialise by waiting for all storage
    // configuration to complete before creating the endpoints.
    dependsOn: [fileServices, shares]
  }
]

// ─── Admin Role Assignments ────────────────────────────────────────────────────
module roleAssignmentsAdmins '../../../resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = [
  for (group, i) in shareAdminGroups: {
    params: {
      principalId: group.id
      roleDefinitionId: adminRoleDefinitionId
      principalType: 'Group'
    }
  }
]

// ─── ADDS Domain Join ──────────────────────────────────────────────────────────
// Configuration commands batch by role, not by account. The scripts process that role's prefix
// and shard range; Office- distinguishes the command names rather than identifying a shard.
module configureADDSAuth '../../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = [
  for role in storageRoles: if (identitySolution == 'ActiveDirectoryDomainServices') {
    scope: resourceGroup(deploymentResourceGroupName)
    params: {
      virtualMachineName: deploymentVirtualMachineName
      name: '${role.commandPrefix}Domain-Join'
      location: location
      script: loadTextContent('../../../../scripts/Configure-StorageAccountforADDS.ps1')
      parameters: [
        { name: 'DomainName', value: domainName }
        {
          name: 'HostPoolName'
          value: !empty(hostPoolResourceId) ? last(split(hostPoolResourceId, '/'))! : role.prefix
        }
        { name: 'KerberosEncryptionType', value: kerberosEncryptionType }
        { name: 'OuPath', value: ouPath }
        { name: 'ResourceManagerUri', value: environment().resourceManager }
        { name: 'StorageAccountPrefix', value: role.prefix }
        { name: 'StorageAccountResourceGroupName', value: resourceGroupStorage }
        { name: 'StorageCount', value: string(storageCount) }
        { name: 'StorageIndex', value: string(storageIndex) }
        { name: 'StorageSuffix', value: environment().suffixes.storage }
        { name: 'SubscriptionId', value: subscription().subscriptionId }
        { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
      ]
      protectedParameters: [
        { name: 'DomainJoinUserPrincipalName', value: domainJoinUserPrincipalName }
        { name: 'DomainJoinUserPwd', value: domainJoinUserPassword }
      ]
      treatFailureAsDeploymentFailure: true
    }
    dependsOn: [privateEndpoints, shares]
  }
]

// ─── EntraKerberos Hybrid (with domain info) ───────────────────────────────────
// Configure Entra Kerberos Hybrid with Domain Info if domainName, domainJoinUserPrincipalName and domainJoinUserPassword are provided.
// The workgroup deployment helper VM uses these credentials for explicit ADWS operations; it is not domain joined.
module configureEntraKerberosWithDomainInfo '../../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = [
  for role in storageRoles: if (identitySolution == 'EntraKerberos-Hybrid' && !empty(domainName) && !empty(domainJoinUserPassword) && !empty(domainJoinUserPrincipalName)) {
    scope: resourceGroup(deploymentResourceGroupName)
    params: {
      virtualMachineName: deploymentVirtualMachineName
      name: '${role.commandPrefix}Configure-StorageAccountsforEntraHybrid'
      location: location
      script: loadTextContent('../../../../scripts/Configure-StorageAccountforEntraHybrid.ps1')
      parameters: [
        { name: 'DefaultSharePermission', value: defaultSharePermission }
        { name: 'DomainName', value: domainName }
        { name: 'ResourceManagerUri', value: environment().resourceManager }
        { name: 'StorageAccountPrefix', value: role.prefix }
        { name: 'StorageAccountResourceGroupName', value: resourceGroupStorage }
        { name: 'StorageCount', value: string(storageCount) }
        { name: 'StorageIndex', value: string(storageIndex) }
        { name: 'StorageSuffix', value: environment().suffixes.storage }
        { name: 'SubscriptionId', value: subscription().subscriptionId }
        { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
      ]
      protectedParameters: [
        { name: 'DomainJoinUserPrincipalName', value: domainJoinUserPrincipalName }
        { name: 'DomainJoinUserPwd', value: domainJoinUserPassword }
      ]
      treatFailureAsDeploymentFailure: true
    }
    dependsOn: [privateEndpoints, shares]
  }
]

// PHASE 1: Update application manifest with privatelink FQDNs and tags
// This must happen BEFORE NTFS permissions are set so authentication works through private endpoints
module updateStorageApplicationsManifest '../../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = [
  for role in storageRoles: if (((identitySolution == 'EntraKerberos-Hybrid' && privateEndpoint) || (identitySolution == 'EntraKerberos-CloudOnly')) && !empty(appUpdateUserAssignedIdentityResourceId)) {
    scope: resourceGroup(deploymentResourceGroupName)
    params: {
      virtualMachineName: deploymentVirtualMachineName
      name: '${role.commandPrefix}Update-Storage-Account-Application-Manifest'
      location: location
      script: loadTextContent('../../../../scripts/Update-StorageAccountApplicationManifest.ps1')
      parameters: [
        { name: 'AppDisplayNamePrefix', value: '[Storage Account] ${role.prefix}' }
        { name: 'ClientId', value: appUpdateUai!.properties.clientId }
        { name: 'GraphEndpoint', value: graphEndpoint }
        { name: 'PrivateEndpoint', value: string(privateEndpoint) }
        { name: 'EnableCloudGroupSids', value: string(identitySolution == 'EntraKerberos-CloudOnly') }
      ]
      treatFailureAsDeploymentFailure: true
    }
    dependsOn: [
      privateEndpoints
      shares
      configureEntraKerberosWithDomainInfo
    ]
  }
]

// ─── Set NTFS Permissions ──────────────────────────────────────────────────────
module SetNTFSPermissions '../../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = [
  for role in storageRoles: if (identitySolution != 'EntraId') {
    scope: resourceGroup(deploymentResourceGroupName)
    params: {
      virtualMachineName: deploymentVirtualMachineName
      name: '${role.commandPrefix}Set-NTFS-Permissions'
      location: location
      script: loadTextContent('../../../../scripts/Set-NtfsPermissionsAzureFiles.ps1')
      parameters: [
        { name: 'DomainName', value: domainName }
        { name: 'ShareName', value: first(role.shares) }
        { name: 'ShardAzureFilesStorage', value: shardingOptions == 'None' ? 'false' : 'true' }
        { name: 'StorageAccountPrefix', value: role.prefix }
        { name: 'StorageCount', value: string(storageCount) }
        { name: 'StorageIndex', value: string(storageIndex) }
        { name: 'StorageSuffix', value: environment().suffixes.storage }
        { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
        // Cloud-only permissions need Entra object IDs; credential-backed domain paths use names.
        // Preserve group order: the permission script pairs group position with shard position.
        {
          name: 'UserGroups'
          value: string(identitySolution == 'EntraKerberos-CloudOnly'
            ? map(shareUserGroups, group => group.id)
            : !empty(domainJoinUserPassword) && !empty(domainJoinUserPrincipalName)
                ? map(shareUserGroups, group => group.name)
                : [])
        }
      ]
      protectedParameters: [
        { name: 'DomainJoinUserPrincipalName', value: domainJoinUserPrincipalName }
        { name: 'DomainJoinUserPwd', value: domainJoinUserPassword }
      ]
      treatFailureAsDeploymentFailure: true
    }
    dependsOn: [
      privateEndpoints
      shares
      configureEntraKerberosWithDomainInfo
      configureADDSAuth
      updateStorageApplicationsManifest
    ]
  }
]

// PHASE 2: Grant admin consent to storage account applications
// This must happen AFTER NTFS permissions are set
module grantStorageApplicationsConsent '../../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = [
  for role in storageRoles: if (((identitySolution == 'EntraKerberos-Hybrid' && privateEndpoint) || (identitySolution == 'EntraKerberos-CloudOnly')) && !empty(appUpdateUserAssignedIdentityResourceId)) {
    scope: resourceGroup(deploymentResourceGroupName)
    params: {
      virtualMachineName: deploymentVirtualMachineName
      name: '${role.commandPrefix}Grant-Storage-Account-Application-Consent'
      location: location
      script: loadTextContent('../../../../scripts/Grant-StorageAccountApplicationConsent.ps1')
      parameters: [
        { name: 'AppDisplayNamePrefix', value: '[Storage Account] ${role.prefix}' }
        { name: 'ClientId', value: appUpdateUai!.properties.clientId }
        { name: 'GraphEndpoint', value: graphEndpoint }
      ]
      treatFailureAsDeploymentFailure: true
    }
    dependsOn: [
      SetNTFSPermissions
    ]
  }
]

// Profile accounts occupy the first storageCount entries; Office accounts start at that offset.
// Return separate arrays with identical shard ordering for downstream routing and Profile-only backup.
@description('Created storage account resource IDs in ascending index order starting at storageIndex.')
output profileStorageAccountResourceIds array = [for i in range(0, storageCount): storageAccounts[i].outputs.resourceId]
@description('Created Office account IDs paired by shard index with Profile accounts; empty when Office containers are disabled.')
output officeStorageAccountResourceIds array = [
  for i in range(0, length(fileShares) > 1 ? storageCount : 0): storageAccounts[i + storageCount].outputs.resourceId
]
