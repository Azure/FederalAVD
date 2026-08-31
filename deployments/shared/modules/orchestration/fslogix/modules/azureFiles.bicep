param appUpdateUserAssignedIdentityResourceId string

param azureFilePrivateDnsZoneResourceId string
param deploymentUserAssignedIdentityClientId string
param deploymentVirtualMachineName string
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param domainName string
param fslogixEncryptionKeyNameConv string
param encryptionKeyVaultUri string
param encryptionUserAssignedIdentityResourceId string
param fileShares array
param hostPoolResourceId string = ''
param identitySolution string
param kerberosEncryptionType string
param keyManagementStorageAccounts string
param location string
param logAnalyticsWorkspaceId string
param ouPath string
param privateEndpoint bool
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param privateEndpointSubnetResourceId string
param deploymentResourceGroupName string
param resourceGroupStorage string
param shardingOptions string
param shareAdminGroups array
param shareSizeInGB int
param shareUserGroups array
param storageAccountNamePrefix string
param storageCount int
param storageIndex int
param storageSku string
param storageRedundancy string
param tags object
@description('Optional. Array of permitted IP addresses or CIDR blocks for the FSLogix storage account firewall.')
param permittedIPs array = []

@description('Optional. Number of days to retain deleted file shares (1–365).')
@minValue(1)
@maxValue(365)
param softDeleteRetentionDays int = 14

var adminRoleDefinitionId = '69566ab7-960f-475b-8e7c-b3118f30c6bd' // Storage File Data Privileged Contributor

var defaultSharePermission = 'StorageFileDataSmbShareContributor'

var privateEndpointVnetName = !empty(privateEndpointSubnetResourceId) && privateEndpoint
  ? split(privateEndpointSubnetResourceId, '/')[8]
  : ''

var privateEndpointVnetId = length(privateEndpointVnetName) < 37
  ? privateEndpointVnetName
  : uniqueString(privateEndpointVnetName)

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
// defaultAction falls back to 'Allow' only when no network restrictions are configured (dev/open scenario).
var effectivePermittedIPs = filter(permittedIPs, ip => !empty(trim(ip)))
var storageIpRules = [for ip in effectivePermittedIPs: { value: ip, action: 'Allow' }]
var storageNetworkAcls = {
  bypass: 'AzureServices'
  defaultAction: (privateEndpoint || !empty(effectivePermittedIPs)) ? 'Deny' : 'Allow'
  ipRules: storageIpRules
  virtualNetworkRules: []
}

var parentResourceTags = !empty(hostPoolResourceId) ? { 'cm-resource-parent': hostPoolResourceId } : {}

var graphEndpoint = environment().name == 'AzureUSGovernment'
  ? 'https://graph.microsoft.us'
  : startsWith(environment().name, 'us')
      ? 'https://graph.${environment().suffixes.storage}'
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
      publicNetworkAccess: (privateEndpoint && empty(effectivePermittedIPs)) ? 'Disabled' : 'Enabled'
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
      name: replace(
        replace(
          replace(privateEndpointNameConv, 'SUBRESOURCE', 'file'),
          'RESOURCE',
          '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
        ),
        'VNETID',
        privateEndpointVnetId
      )
      customNetworkInterfaceName: replace(
        replace(
          replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'file'),
          'RESOURCE',
          '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
        ),
        'VNETID',
        privateEndpointVnetId
      )
      tags: union(parentResourceTags, tags[?'Microsoft.Network/privateEndpoints'] ?? {})
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
module SetNTFSPermissions '../../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = {
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

output storageAccountResourceIds array = [for i in range(0, storageCount): storageAccounts[i].outputs.resourceId]
