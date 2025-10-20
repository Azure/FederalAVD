param availability string
param azureBackupPrivateDnsZoneResourceId string
param azureBlobPrivateDnsZoneResourceId string
param azureFilePrivateDnsZoneResourceId string
param azureFunctionAppPrivateDnsZoneResourceId string
param azureQueuePrivateDnsZoneResourceId string
param azureTablePrivateDnsZoneResourceId string
param deploymentUserAssignedIdentityClientId string
param deploymentVirtualMachineName string
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param domainName string
param domainGuid string
param fslogixEncryptionKeyNameConv string
param encryptionKeyVaultUri string
param encryptionUserAssignedIdentityResourceId string
param fileShares array
param functionAppDelegatedSubnetResourceId string
param hostPoolResourceId string
param identitySolution string
param increaseQuota bool
param increaseQuotaEncryptionKeyName string
param increaseQuotaApplicationInsightsName string
param increaseQuotaFunctionAppName string
param increaseQuotaStorageAccountName string
param kerberosEncryptionType string
param keyManagementStorageAccounts string
param location string
param logAnalyticsWorkspaceId string
param ouPath string
param privateEndpoint bool
param privateEndpointLocation string
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param privateEndpointSubnetResourceId string
param privateLinkScopeResourceId string
param recoveryServices bool
param recoveryServicesVaultName string
param deploymentResourceGroupName string
param resourceGroupStorage string
param serverFarmId string
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

var adminRoleDefinitionId = 'a7264617-510b-434b-a828-9731dc254ea7' // Storage File Data SMB Share Elevated Contributor
var userRoleDefinitionId = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb' // Storage File Data SMB Share Contributor

var privateEndpointVnetName = !empty(privateEndpointSubnetResourceId) && privateEndpoint
  ? split(privateEndpointSubnetResourceId, '/')[8]
  : ''

var privateEndpointVnetId = length(privateEndpointVnetName) < 37
  ? privateEndpointVnetName
  : uniqueString(privateEndpointVnetName)

var smbMultiChannel = {
  multichannel: {
    enabled: true
  }
}
var smbSettings = {
  versions: 'SMB3.0;SMB3.1.1;'
  authenticationMethods: 'NTLMv2;Kerberos;'
  kerberosTicketEncryption: kerberosEncryptionType == 'RC4' ? 'RC4-HMAC;' : 'AES-256;'
  channelEncryption: 'AES-128-CCM;AES-128-GCM;AES-256-GCM;'
}
var storageRedundancy = availability == 'availabilityZones' ? '_ZRS' : '_LRS'

var backupPrivateDNSZoneResourceIds = [
  azureBackupPrivateDnsZoneResourceId
  azureBlobPrivateDnsZoneResourceId
  azureQueuePrivateDnsZoneResourceId
]

var nonEmptyBackupPrivateDNSZoneResourceIds = filter(backupPrivateDNSZoneResourceIds, zone => !empty(zone))

resource storageAccounts 'Microsoft.Storage/storageAccounts@2022-09-01' = [
  for i in range(0, storageCount): {
    name: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
    kind: storageSku == 'Standard' ? 'StorageV2' : 'FileStorage'
    location: location
    identity: keyManagementStorageAccounts != 'MicrosoftManaged'
      ? {
          type: 'UserAssigned'
          userAssignedIdentities: {
            '${encryptionUserAssignedIdentityResourceId}': {}
          }
        }
      : null
    properties: {
      accessTier: 'Hot'
      allowBlobPublicAccess: false
      allowCrossTenantReplication: false
      allowedCopyScope: privateEndpoint ? 'PrivateLink' : 'AAD'
      allowSharedKeyAccess: identitySolution == 'EntraId' ? true : false
      azureFilesIdentityBasedAuthentication: identitySolution != 'EntraId' && identitySolution != 'EntraKerberos'
        ? {
            defaultSharePermission: contains(identitySolution, 'DomainServices')
              ? 'StorageFileDataSmbShareContributor'
              : 'None'
            directoryServiceOptions: identitySolution == 'EntraDomainServices' ? 'AADDS' : 'None'
          }
        : null
      defaultToOAuthAuthentication: false
      dnsEndpointType: 'Standard'
      encryption: {
        identity: keyManagementStorageAccounts != 'MicrosoftManaged'
          ? {
              userAssignedIdentity: encryptionUserAssignedIdentityResourceId
            }
          : null
        services: storageSku == 'Standard'
          ? {
              blob: {
                keyType: 'Account'
                enabled: true
              }
              file: {
                keyType: 'Account'
                enabled: true
              }
            }
          : {
              file: {
                keyType: 'Account'
                enabled: true
              }
            }
        keySource: keyManagementStorageAccounts != 'MicrosoftManaged' ? 'Microsoft.KeyVault' : 'Microsoft.Storage'
        keyvaultproperties: keyManagementStorageAccounts != 'MicrosoftManaged'
          ? {
              keyname: replace(fslogixEncryptionKeyNameConv, '##', padLeft(i + storageIndex, 2, '0'))
              keyvaulturi: encryptionKeyVaultUri
            }
          : null
        requireInfrastructureEncryption: true
      }
      largeFileSharesState: storageSku == 'Standard' ? 'Enabled' : null
      minimumTlsVersion: 'TLS1_2'
      networkAcls: {
        bypass: 'AzureServices'
        defaultAction: privateEndpoint ? 'Deny' : 'Allow'
      }
      publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
      sasPolicy: {
        expirationAction: 'Log'
        sasExpirationPeriod: '180.00:00:00'
      }
      supportsHttpsTrafficOnly: true
    }
    sku: {
      name: '${storageSku}${storageRedundancy}'
    }
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Storage/storageAccounts'] ?? {})
  }
]

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2022-09-01' = [
  for i in range(0, storageCount): {
    parent: storageAccounts[i]
    name: 'default'
    properties: {
      protocolSettings: {
        smb: storageSku == 'Standard' ? smbSettings : union(smbSettings, smbMultiChannel)
      }
      shareDeleteRetentionPolicy: {
        enabled: false
      }
    }
  }
]

// Assigns the SMB Contributor role to the Storage Account for the user groups so they can write their profile directories.
module roleAssignmentsUsers '../../common/roleAssignment-storageAccount.bicep' = [
  for i in range(0, storageCount): if (!contains(identitySolution, 'DomainServices')) {
    name: '${storageAccounts[i].name}-UserRoleAssignments-${deploymentSuffix}'
    params: {
      principalIds: shardingOptions == 'None'
        ? map(shareUserGroups, group => group.id)
        : [map(shareUserGroups, group => group.id)[i]]
      principalType: 'Group'
      storageAccountResourceId: storageAccounts[i].id
      roleDefinitionId: userRoleDefinitionId
    }
  }
]

// Assigns the SMB Elevated Contributor role to the Storage Account for admins so they can adjust NTFS permissions if needed.
module roleAssignmentsAdmins '../../common/roleAssignment-storageAccount.bicep' = [
  for i in range(0, storageCount): if (!empty(shareAdminGroups)) {
    name: '${storageAccounts[i].name}-AdminRoleAssignments-${deploymentSuffix}'
    params: {
      principalIds: map(shareAdminGroups, group => group.id)
      principalType: 'Group'
      storageAccountResourceId: storageAccounts[i].id
      roleDefinitionId: adminRoleDefinitionId
    }
  }
]

module shares 'shares.bicep' = [
  for i in range(0, storageCount): {
    name: '${storageAccounts[i].name}-fileShares-${deploymentSuffix}'
    params: {
      fileShares: fileShares
      shareSizeInGB: shareSizeInGB
      StorageAccountName: storageAccounts[i].name
      storageSku: storageSku
    }    
  }
]

module entraKerberos 'azureFilesEntraKerberos.bicep' = [
  for i in range(0, storageCount): if (identitySolution == 'EntraKerberos') {
    name: '${storageAccounts[i].name}-entra-kerberos-${deploymentSuffix}'
    params: {
      domainGuid: domainGuid
      domainName: domainName
      storageAccountName: storageAccounts[i].name
      kind: storageSku == 'Standard' ? 'StorageV2' : 'FileStorage'
      sku: {
        name: '${storageSku}${storageRedundancy}'
      }
      location: location
    }
    dependsOn: [
      shares[i]
    ]
  }
]

module privateEndpoints '../../../../sharedModules/resources/network/private-endpoint/main.bicep' = [
  for i in range(0, storageCount): if (privateEndpoint) {
    name: '${storageAccounts[i].name}-privateEndpoint-${deploymentSuffix}'
    params: {
      customNetworkInterfaceName: replace(
        replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'file'), 'RESOURCE', '${storageAccounts[i].name}'),
        'VNETID',
        privateEndpointVnetId
      )
      groupIds: [
        'file'
      ]
      location: !empty(privateEndpointLocation) ? privateEndpointLocation : location
      name: replace(
        replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'file'), 'RESOURCE', '${storageAccounts[i].name}'),
        'VNETID',
        privateEndpointVnetId
      )
      privateDnsZoneGroup: empty(azureFilePrivateDnsZoneResourceId)
        ? null
        : {
            privateDNSResourceIds: [
              azureFilePrivateDnsZoneResourceId
            ]
          }
      serviceResourceId: storageAccounts[i].id
      subnetResourceId: privateEndpointSubnetResourceId
      tags: union(
        {
          'cm-resource-parent': hostPoolResourceId
        },
        tags[?'Microsoft.Network/privateEndpoints'] ?? {}
      )
    }
  }
]

resource storageAccounts_diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [
  for i in range(0, storageCount): if (!empty(logAnalyticsWorkspaceId)) {
    name: '${storageAccounts[i].name}-diagnosticSettings'
    properties: {
      metrics: [
        {
          category: 'Transaction'
          enabled: true
        }
      ]
      workspaceId: logAnalyticsWorkspaceId
    }
    scope: storageAccounts[i]
  }
]

resource storageAccounts_file_diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [
  for i in range(0, storageCount): if (!empty(logAnalyticsWorkspaceId)) {
    name: '${storageAccounts[i].name}-file-diagnosticSettings'
    scope: fileServices[i]
    properties: {
      workspaceId: logAnalyticsWorkspaceId
      logs: [
        {
          category: 'StorageDelete'
          enabled: true
        }
      ]
      metrics: [
        {
          category: 'Transaction'
          enabled: true
        }
      ]
    }
  }
]

module configureADDSAuth 'domainJoin.bicep' = if (identitySolution == 'ActiveDirectoryDomainServices') {
  name: 'Join-Domain-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    domainJoinUserPassword: domainJoinUserPassword
    hostPoolName: last(split(hostPoolResourceId, '/'))
    kerberosEncryptionType: kerberosEncryptionType
    location: location
    ouPath: ouPath
    resourceGroupStorage: resourceGroupStorage
    storageAccountNamePrefix: storageAccountNamePrefix
    storageCount: storageCount
    storageIndex: storageIndex
    userAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    virtualMachineName: deploymentVirtualMachineName
  }
  dependsOn: [
    privateEndpoints
    shares
  ]
}

module SetNTFSPermissions 'setNTFSPermissionsAzureFiles.bicep' = {
  name: 'Set-NTFS-Permissions-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    adminGroups: contains(identitySolution, 'DomainServices') ? map(shareAdminGroups, group => group.name) : []
    location: location
    shardingOptions: shardingOptions
    shares: fileShares
    storageAccountNamePrefix: storageAccountNamePrefix
    storageCount: storageCount
    storageIndex: storageIndex
    userAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    userGroups: contains(identitySolution, 'DomainServices') ? map(shareUserGroups, group => group.name) : []
    virtualMachineName: deploymentVirtualMachineName
  }
  dependsOn: [
    privateEndpoints
    shares
    configureADDSAuth
  ]
}

module recoveryServicesVault '../../../../sharedModules/resources/recovery-services/vault/main.bicep' = if (recoveryServices) {
  name: 'RecoveryServices-AzureFiles-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupStorage)
  params: {
    location: location
    name: recoveryServicesVaultName
    backupPolicies: [
      {
        name: 'filesharepolicy'
        type: 'Microsoft.RecoveryServices/vaults/backupPolicies'
        properties: {
          backupManagementType: 'AzureStorage'
          workloadType: 'AzureFileShare'
          schedulePolicy: {
            schedulePolicyType: 'SimpleSchedulePolicy'
            scheduleRunFrequency: 'Daily'
            scheduleRunTimes: [
              '23:00'
            ]
          }
          retentionPolicy: {
            retentionPolicyType: 'LongTermRetentionPolicy'
            dailySchedule: {
              retentionTimes: [
                '23:00'
              ]
              retentionDuration: {
                count: 30
                durationType: 'Days'
              }
            }
          }
          timeZone: timeZone
          workLoadType: 'AzureFileShare'
        }
      }
    ]
    diagnosticWorkspaceId: logAnalyticsWorkspaceId
    privateEndpoints: privateEndpoint && !empty(privateEndpointSubnetResourceId)
      ? [
          {
            customNetworkInterfaceName: replace(
              replace(
                replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'azurebackup'),
                'RESOURCE',
                recoveryServicesVaultName
              ),
              'VNETID',
              '${split(privateEndpointSubnetResourceId, '/')[8]}'
            )
            name: replace(
              replace(
                replace(privateEndpointNameConv, 'SUBRESOURCE', 'azurebackup'),
                'RESOURCE',
                recoveryServicesVaultName
              ),
              'VNETID',
              '${split(privateEndpointSubnetResourceId, '/')[8]}'
            )
            privateDnsZoneGroup: empty(nonEmptyBackupPrivateDNSZoneResourceIds)
              ? null
              : {
                  privateDNSResourceIds: nonEmptyBackupPrivateDNSZoneResourceIds
                }
            service: 'AzureBackup'
            subnetResourceId: privateEndpointSubnetResourceId
            tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Network/privateEndpoints'] ?? {})
          }
        ]
      : null
    protectionContainers: [
      for i in range(0, storageCount): {
        name: 'storagecontainer;Storage;${resourceGroupStorage};${storageAccounts[i].name}'
        friendlyName: storageAccounts[i].name
        sourceResourceId: storageAccounts[i].id
        backupManagementType: 'AzureStorage'
        containerType: 'StorageContainer'
        location: location
        protectedItems: [
          {
            name: 'AzureFileShare;${fileShares[0]}'
            policyId: '${resourceGroup().id}/providers/Microsoft.RecoveryServices/vaults/${recoveryServicesVaultName}/backupPolicies/filesharepolicy'
            protectedItemType: 'AzureFileShareProtectedItem'
            sourceResourceId: storageAccounts[i].id
          }
        ]
      }
    ]
    publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.RecoveryServices/vaults'] ?? {})
  }
}

module increaseQuotaFunctionApp '../../common/functionApp/functionApp.bicep' = if (storageSku == 'Premium' && increaseQuota) {
  name: 'IncreaseQuotaFunctionApp-${deploymentSuffix}'
  params: {
    location: location
    applicationInsightsName: increaseQuotaApplicationInsightsName
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    azureFunctionAppPrivateDnsZoneResourceId: azureFunctionAppPrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    azureTablePrivateDnsZoneResourceId: azureTablePrivateDnsZoneResourceId
    enableApplicationInsights: !empty(logAnalyticsWorkspaceId)
    functionAppDelegatedSubnetResourceId: functionAppDelegatedSubnetResourceId
    functionAppAppSettings: [
      {
        name: 'FileShareNames'
        value: string(fileShares)
      }
      {
        name: 'ResourceGroupName'
        value: resourceGroupStorage
      }
    ]
    encryptionUserAssignedIdentityResourceId: encryptionUserAssignedIdentityResourceId
    functionAppName: increaseQuotaFunctionAppName
    hostPoolResourceId: hostPoolResourceId
    keyManagementStorageAccounts: keyManagementStorageAccounts
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceId
    privateEndpoint: privateEndpoint
    privateEndpointNameConv: privateEndpointNameConv
    privateEndpointNICNameConv: privateEndpointNICNameConv
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    privateLinkScopeResourceId: privateLinkScopeResourceId
    resourceGroupRoleAssignments: [
      {
        roleDefinitionId: '17d1049b-9a84-46fb-8f53-869881c3d3ab' // Storage Account Contributor
        scope: resourceGroupStorage
      }
    ]
    serverFarmId: serverFarmId
    storageAccountName: increaseQuotaStorageAccountName
    tags: tags
    deploymentSuffix: deploymentSuffix
    encryptionKeyName: increaseQuotaEncryptionKeyName
    encryptionKeyVaultUri: encryptionKeyVaultUri
  }
}

module increaseQuotaFunction '../../common/functionApp/function.bicep' = if (storageSku == 'Premium' && increaseQuota && storageCount > 0) {
  name: 'IncreaseQuotaFunction-${deploymentSuffix}'
  params: {
    files: {
      'requirements.psd1': loadTextContent('../../../../../.common/scripts/auto-increase-file-share/requirements.psd1')
      'run.ps1': loadTextContent('../../../../../.common/scripts/auto-increase-file-share/run.ps1')
      '../profile.ps1': loadTextContent('../../../../../.common/scripts/auto-increase-file-share/profile.ps1')
    }
    functionAppName: increaseQuotaFunctionApp!.outputs.functionAppName
    functionName: 'auto-increase-file-share-quota'
    schedule: '0 */15 * * * *'
  }
}

output storageAccountResourceIds array = [for i in range(0, storageCount): storageAccounts[i].id]
