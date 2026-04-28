param appUpdateUserAssignedIdentityResourceId string
param availability string
param azureBackupPrivateDnsZoneResourceId string
param azureBlobPrivateDnsZoneResourceId string
param azureFilePrivateDnsZoneResourceId string
param azureQueuePrivateDnsZoneResourceId string
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
param hostPoolResourceId string
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
param recoveryServices bool
param recoveryServicesVaultName string
param recoveryServicesVaultStorageRedundancy string
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
param tags object
param deploymentSuffix string
param timeZone string

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
var storageRedundancy = availability == 'availabilityZones' ? '_ZRS' : '_LRS'

var backupPrivateDNSZoneResourceIds = [
  azureBackupPrivateDnsZoneResourceId
  azureBlobPrivateDnsZoneResourceId
  azureQueuePrivateDnsZoneResourceId
]

var nonEmptyBackupPrivateDNSZoneResourceIds = filter(backupPrivateDNSZoneResourceIds, zone => !empty(zone))

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
module storageAccounts '../../../../../.common/bicepModules/storage/storageAccounts/deploy.bicep' = [
  for i in range(0, storageCount): {
    name: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}-${deploymentSuffix}'
    params: {
      name: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
      location: location
      kind: storageSku == 'Standard' ? 'StorageV2' : 'FileStorage'
      skuName: '${storageSku}${storageRedundancy}'
      tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Storage/storageAccounts'] ?? {})
      allowedCopyScope: privateEndpoint ? 'PrivateLink' : 'AAD'
      allowSharedKeyAccess: identitySolution == 'EntraId' ? true : false
      largeFileSharesState: storageSku == 'Standard' ? 'Enabled' : ''
      sasExpirationPeriod: '180.00:00:00'
      publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
      networkAcls: {
        bypass: 'AzureServices'
        defaultAction: privateEndpoint ? 'Deny' : 'Allow'
      }
      azureFilesIdentityBasedAuthentication: identitySolution != 'EntraId'
        ? {
            defaultSharePermission: defaultSharePermission
            directoryServiceOptions: contains(identitySolution, 'EntraKerberos')
              ? 'AADKERB'
              : identitySolution == 'EntraDomainServices' ? 'AADDS' : 'None'
          }
        : {}
      encryptionKeyVaultUri: keyManagementStorageAccounts != 'MicrosoftManaged' ? encryptionKeyVaultUri : ''
      encryptionKeyName: keyManagementStorageAccounts != 'MicrosoftManaged'
        ? replace(fslogixEncryptionKeyNameConv, '##', padLeft(i + storageIndex, 2, '0'))
        : ''
      encryptionUserAssignedIdentityResourceId: keyManagementStorageAccounts != 'MicrosoftManaged'
        ? encryptionUserAssignedIdentityResourceId
        : ''
      diagnosticSettings: !empty(logAnalyticsWorkspaceId) ? { workspaceId: logAnalyticsWorkspaceId } : null
    }
  }
]

// ─── File Services ─────────────────────────────────────────────────────────────
module fileServices '../../../../../.common/bicepModules/storage/storageAccounts/fileServices/deploy.bicep' = [
  for i in range(0, storageCount): {
    name: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}-fileService-${deploymentSuffix}'
    params: {
      storageAccountName: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
      smbSettings: smbSettingsValues
      shareDeleteRetentionPolicyEnabled: false
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
    name: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}-fileShares-${deploymentSuffix}'
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
module storageAccountPes '../../../../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = [
  for i in range(0, storageCount): if (privateEndpoint) {
    name: 'StorageAccount-PE-${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}-${deploymentSuffix}'
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
      tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Network/privateEndpoints'] ?? {})
      subnetResourceId: privateEndpointSubnetResourceId
      privateLinkServiceId: storageAccounts[i].outputs.resourceId
      groupId: 'file'
      privateDNSZoneIds: !empty(azureFilePrivateDnsZoneResourceId) ? [azureFilePrivateDnsZoneResourceId] : []
    }
  }
]

// ─── Admin Role Assignments ────────────────────────────────────────────────────
module roleAssignmentsAdmins '../../../../../.common/bicepModules/authorization/roleAssignments/deploy.resourceGroup.bicep' = [
  for (group, i) in shareAdminGroups: {
    name: 'RoleAssignment-Admin-${i}-${deploymentSuffix}'
    params: {
      assignments: [
        {
          principalId: group.id
          roleDefinitionId: adminRoleDefinitionId
          principalType: 'Group'
        }
      ]
    }
  }
]

// ─── ADDS Domain Join ──────────────────────────────────────────────────────────
module configureADDSAuth '../../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = if (identitySolution == 'ActiveDirectoryDomainServices') {
  name: 'Join-Domain-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Domain-Join'
    location: location
    script: loadTextContent('../../../../../.common/scripts/Configure-StorageAccountforADDS.ps1')
    parameters: [
      { name: 'HostPoolName', value: last(split(hostPoolResourceId, '/'))! }
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
  dependsOn: [storageAccountPes, shares]
}

// ─── EntraKerberos Hybrid (with domain info) ───────────────────────────────────
// Configure Entra Kerberos Hybrid with Domain Info if domainName, domainJoinUserPrincipalName and domainJoinUserPassword are provided.
// If they were, the deployment helper VM is domain joined. If not, then the deployment helper VM is not domain joined and can't run this configuration.
module configureEntraKerberosWithDomainInfo '../../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = if (identitySolution == 'EntraKerberos-Hybrid' && !empty(domainName) && !empty(domainJoinUserPassword) && !empty(domainJoinUserPrincipalName)) {
  name: 'Configure-Entra-Kerberos-DomainInfo-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Configure-StorageAccountsforEntraHybrid'
    location: location
    script: loadTextContent('../../../../../.common/scripts/Configure-StorageAccountforEntraHybrid.ps1')
    parameters: [
      { name: 'DefaultSharePermission', value: defaultSharePermission }
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
  dependsOn: [storageAccountPes, shares]
}

// PHASE 1: Update application manifest with privatelink FQDNs and tags
// This must happen BEFORE NTFS permissions are set so authentication works through private endpoints
module updateStorageApplicationsManifest '../../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = if (((identitySolution == 'EntraKerberos-Hybrid' && privateEndpoint) || (identitySolution == 'EntraKerberos-CloudOnly')) && !empty(appUpdateUserAssignedIdentityResourceId)) {
  name: 'Update-Storage-App-Manifest-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Update-Storage-Account-Application-Manifest'
    location: location
    script: loadTextContent('../../../../../.common/scripts/Update-StorageAccountApplicationManifest.ps1')
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
    storageAccountPes
    shares
    configureEntraKerberosWithDomainInfo
  ]
}

// ─── Set NTFS Permissions ──────────────────────────────────────────────────────
module SetNTFSPermissions '../../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  name: 'Set-NTFS-Permissions-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Set-NTFS-Permissions'
    location: location
    script: loadTextContent('../../../../../.common/scripts/Set-NtfsPermissionsAzureFiles.ps1')
    parameters: [
      { name: 'Shares', value: string(fileShares) }
      { name: 'ShardAzureFilesStorage', value: shardingOptions == 'None' ? 'false' : 'true' }
      { name: 'StorageAccountPrefix', value: storageAccountNamePrefix }
      { name: 'StorageCount', value: string(storageCount) }
      { name: 'StorageIndex', value: string(storageIndex) }
      { name: 'StorageSuffix', value: environment().suffixes.storage }
      { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
      {
        name: 'UserGroups'
        value: string(identitySolution == 'EntraKerberos-CloudOnly' && !empty(appUpdateUserAssignedIdentityResourceId)
          ? map(shareUserGroups, group => group.id)
          : !empty(domainJoinUserPassword) && !empty(domainJoinUserPrincipalName)
              ? map(shareUserGroups, group => group.name)
              : [])
      }
    ]
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    storageAccountPes
    shares
    configureEntraKerberosWithDomainInfo
    configureADDSAuth
    updateStorageApplicationsManifest
  ]
}

// PHASE 2: Grant admin consent to storage account applications
// This must happen AFTER NTFS permissions are set
module grantStorageApplicationsConsent '../../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = if (((identitySolution == 'EntraKerberos-Hybrid' && privateEndpoint) || (identitySolution == 'EntraKerberos-CloudOnly')) && !empty(appUpdateUserAssignedIdentityResourceId)) {
  name: 'Grant-Storage-App-Consent-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Grant-Storage-Account-Application-Consent'
    location: location
    script: loadTextContent('../../../../../.common/scripts/Grant-StorageAccountApplicationConsent.ps1')
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

// ─── Recovery Services Vault ───────────────────────────────────────────────────
module recoveryServicesVaultModule '../../../../../.common/bicepModules/recoveryServices/vaults/deploy.bicep' = if (recoveryServices) {
  name: 'RecoveryServices-AzureFiles-${deploymentSuffix}'
  params: {
    name: recoveryServicesVaultName
    location: location
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.RecoveryServices/vaults'] ?? {})
    publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    storageType: recoveryServicesVaultStorageRedundancy
    diagnosticSettings: !empty(logAnalyticsWorkspaceId) ? { workspaceId: logAnalyticsWorkspaceId } : null
  }
}

resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = if (recoveryServices) {
  name: '${recoveryServicesVaultName}/filesharepolicy'
  properties: {
    backupManagementType: 'AzureStorage'
    workLoadType: 'AzureFileShare'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: ['23:00']
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: ['23:00']
        retentionDuration: {
          count: 30
          durationType: 'Days'
        }
      }
    }
    timeZone: timeZone
  }
  dependsOn: [recoveryServicesVaultModule]
}

resource protectionContainers 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers@2024-04-01' = [
  for i in range(0, storageCount): if (recoveryServices) {
    name: '${recoveryServicesVaultName}/Azure/storagecontainer;Storage;${resourceGroupStorage};${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
    properties: {
      friendlyName: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
      sourceResourceId: storageAccounts[i].outputs.resourceId
      backupManagementType: 'AzureStorage'
      containerType: 'StorageContainer'
    }
    dependsOn: [backupPolicy]
  }
]

resource protectedItems 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-04-01' = [
  for i in range(0, storageCount): if (recoveryServices) {
    name: '${recoveryServicesVaultName}/Azure/storagecontainer;Storage;${resourceGroupStorage};${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}/AzureFileShare;${fileShares[0]}'
    location: location
    properties: {
      protectedItemType: 'AzureFileShareProtectedItem'
      policyId: '${resourceGroup().id}/providers/Microsoft.RecoveryServices/vaults/${recoveryServicesVaultName}/backupPolicies/filesharepolicy'
      sourceResourceId: storageAccounts[i].outputs.resourceId
    }
    dependsOn: [protectionContainers]
  }
]

module backupVault_pe '../../../../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = if (recoveryServices && privateEndpoint && !empty(privateEndpointSubnetResourceId)) {
  name: 'RecoveryServices-PE-${deploymentSuffix}'
  params: {
    name: replace(
      replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'azurebackup'), 'RESOURCE', recoveryServicesVaultName),
      'VNETID',
      split(privateEndpointSubnetResourceId, '/')[8]
    )
    customNetworkInterfaceName: replace(
      replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'azurebackup'), 'RESOURCE', recoveryServicesVaultName),
      'VNETID',
      split(privateEndpointSubnetResourceId, '/')[8]
    )
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Network/privateEndpoints'] ?? {})
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceId: recoveryServicesVaultModule!.outputs.resourceId
    groupId: 'AzureBackup'
    privateDNSZoneIds: !empty(nonEmptyBackupPrivateDNSZoneResourceIds) ? nonEmptyBackupPrivateDNSZoneResourceIds : []
  }
}

output storageAccountResourceIds array = [for i in range(0, storageCount): storageAccounts[i].outputs.resourceId]
