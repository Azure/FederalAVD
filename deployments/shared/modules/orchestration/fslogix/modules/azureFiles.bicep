metadata name = 'FSLogix Azure Files orchestration'
metadata description = 'Creates indexed storage accounts, SMB shares, optional private endpoints, administrator RBAC, and identity-dependent configuration through an existing deployment helper VM.'

import { publicNetworkAccessMode, resolveNetworkAccess } from '../../networking/functions.bicep'

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
param fslogixEncryptionKeyNameConv string
@description('Required. URI of the existing encryption Key Vault, including the trailing slash; used for customer-managed storage keys.')
param encryptionKeyVaultUri string
@description('Required. Resource ID of the existing identity authorized to use the storage encryption keys; unused for PlatformManaged encryption.')
param encryptionUserAssignedIdentityResourceId string
@description('Required. Array of share name strings to create or register on every supplied storage account.')
param fileShares array
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
param storageAccountNamePrefix string
@description('Required. Number of indexed Azure Files storage accounts to create.')
param storageCount int
@description('Required. Starting numeric index for storage account and encryption-key names.')
param storageIndex int
@description('Required. Storage tier: Standard or Premium for Azure Files, or the NetApp service level for NetApp volumes.')
param storageSku string
@description('Required. Azure Files redundancy selection; ZoneRedundant selects ZRS and other values select LRS.')
param storageRedundancy string
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

import { privateEndpointName } from '../../naming/naming.bicep'

resource privateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if (privateEndpoint && !empty(privateEndpointSubnetResourceId)) {
  name: privateEndpointVnetName
  scope: resourceGroup(
    split(privateEndpointSubnetResourceId, '/')[2],
    split(privateEndpointSubnetResourceId, '/')[4]
  )
}

var smbSettingsValues = {
  versions: 'SMB3.0;SMB3.1.1;'
  authenticationMethods: 'NTLMv2;Kerberos;'
  kerberosTicketEncryption: kerberosEncryptionType == 'RC4' ? 'RC4-HMAC;' : 'AES-256;'
  channelEncryption: 'AES-128-CCM;AES-128-GCM;AES-256-GCM;'
  multichannel: storageSku != 'Standard' ? { enabled: true } : null
}
var storageRedundancySuffix = storageRedundancy == 'ZoneRedundant' ? '_ZRS' : '_LRS'

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
  for i in range(0, storageCount): {
    params: {
      name: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
      location: location
      kind: storageSku == 'Standard' ? 'StorageV2' : 'FileStorage'
      skuName: '${storageSku}${storageRedundancySuffix}'
      tags: union(parentResourceTags, tags[?'Microsoft.Storage/storageAccounts'] ?? {})
      allowedCopyScope: privateEndpoint ? 'PrivateLink' : 'AAD'
      allowSharedKeyAccess: identitySolution == 'EntraId' ? true : false
      largeFileSharesState: storageSku == 'Standard' ? 'Enabled' : ''
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
        ? '${encryptionKeyVaultUri}keys/${replace(fslogixEncryptionKeyNameConv, '##', padLeft(i + storageIndex, 2, '0'))}'
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
  for i in range(0, storageCount): {
    params: {
      storageAccountName: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
      smbSettings: smbSettingsValues
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
  for i in range(0, storageCount): {
    params: {
      fileShares: fileShares
      shareSizeInGB: shareSizeInGB
      StorageAccountName: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
      storageSku: storageSku
    }
    dependsOn: [storageAccounts, fileServices]
  }
]

// ─── Private Endpoints ─────────────────────────────────────────────────────────
module privateEndpoints '../../../resourceModules/network/privateEndpoints/deploy.bicep' = [
  for i in range(0, storageCount): if (privateEndpoint) {
    params: {
      name: privateEndpointName(privateEndpointNameConv, '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}', 'file', privateEndpointVnetName)
      customNetworkInterfaceName: privateEndpointName(privateEndpointNICNameConv, '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}', 'file', privateEndpointVnetName)
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
module configureADDSAuth '../../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = if (identitySolution == 'ActiveDirectoryDomainServices') {
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Domain-Join'
    location: location
    script: loadTextContent('../../../../scripts/Configure-StorageAccountforADDS.ps1')
    parameters: [
      { name: 'DomainName', value: domainName }
      { name: 'HostPoolName', value: !empty(hostPoolResourceId) ? last(split(hostPoolResourceId, '/'))! : storageAccountNamePrefix }
      { name: 'KerberosEncryptionType', value: kerberosEncryptionType }
      { name: 'OuPath', value: ouPath }
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'StorageAccountPrefix', value: storageAccountNamePrefix }
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

// ─── EntraKerberos Hybrid (with domain info) ───────────────────────────────────
// Configure Entra Kerberos Hybrid with Domain Info if domainName, domainJoinUserPrincipalName and domainJoinUserPassword are provided.
// The workgroup deployment helper VM uses these credentials for explicit ADWS operations; it is not domain joined.
module configureEntraKerberosWithDomainInfo '../../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = if (identitySolution == 'EntraKerberos-Hybrid' && !empty(domainName) && !empty(domainJoinUserPassword) && !empty(domainJoinUserPrincipalName)) {
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Configure-StorageAccountsforEntraHybrid'
    location: location
    script: loadTextContent('../../../../scripts/Configure-StorageAccountforEntraHybrid.ps1')
    parameters: [
      { name: 'DefaultSharePermission', value: defaultSharePermission }
      { name: 'DomainName', value: domainName }
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'StorageAccountPrefix', value: storageAccountNamePrefix }
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

// PHASE 1: Update application manifest with privatelink FQDNs and tags
// This must happen BEFORE NTFS permissions are set so authentication works through private endpoints
module updateStorageApplicationsManifest '../../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = if (((identitySolution == 'EntraKerberos-Hybrid' && privateEndpoint) || (identitySolution == 'EntraKerberos-CloudOnly')) && !empty(appUpdateUserAssignedIdentityResourceId)) {
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Update-Storage-Account-Application-Manifest'
    location: location
    script: loadTextContent('../../../../scripts/Update-StorageAccountApplicationManifest.ps1')
    parameters: [
      { name: 'AppDisplayNamePrefix', value: '[Storage Account] ${storageAccountNamePrefix}' }
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

// ─── Set NTFS Permissions ──────────────────────────────────────────────────────
module SetNTFSPermissions '../../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = if (identitySolution != 'EntraId') {
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Set-NTFS-Permissions'
    location: location
    script: loadTextContent('../../../../scripts/Set-NtfsPermissionsAzureFiles.ps1')
    parameters: [
      { name: 'DomainName', value: domainName }
      { name: 'Shares', value: string(fileShares) }
      { name: 'ShardAzureFilesStorage', value: shardingOptions == 'None' ? 'false' : 'true' }
      { name: 'StorageAccountPrefix', value: storageAccountNamePrefix }
      { name: 'StorageCount', value: string(storageCount) }
      { name: 'StorageIndex', value: string(storageIndex) }
      { name: 'StorageSuffix', value: environment().suffixes.storage }
      { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
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

// PHASE 2: Grant admin consent to storage account applications
// This must happen AFTER NTFS permissions are set
module grantStorageApplicationsConsent '../../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = if (((identitySolution == 'EntraKerberos-Hybrid' && privateEndpoint) || (identitySolution == 'EntraKerberos-CloudOnly')) && !empty(appUpdateUserAssignedIdentityResourceId)) {
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Grant-Storage-Account-Application-Consent'
    location: location
    script: loadTextContent('../../../../scripts/Grant-StorageAccountApplicationConsent.ps1')
    parameters: [
      { name: 'AppDisplayNamePrefix', value: '[Storage Account] ${storageAccountNamePrefix}' }
      { name: 'ClientId', value: appUpdateUai!.properties.clientId }
      { name: 'GraphEndpoint', value: graphEndpoint }
    ]
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    SetNTFSPermissions
  ]
}

@description('Created storage account resource IDs in ascending index order starting at storageIndex.')
output storageAccountResourceIds array = [for i in range(0, storageCount): storageAccounts[i].outputs.resourceId]
