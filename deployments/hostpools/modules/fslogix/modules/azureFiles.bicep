param availability string
param azureBackupPrivateDnsZoneResourceId string
param azureBlobPrivateDnsZoneResourceId string
param azureFilePrivateDnsZoneResourceId string
param azureFunctionAppPrivateDnsZoneResourceId string
param azureFunctionAppScmPrivateDnsZoneResourceId string
param azureQueuePrivateDnsZoneResourceId string
param azureTablePrivateDnsZoneResourceId string
param deploymentUserAssignedIdentityClientId string
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param encryptionKeyVaultName string
param encryptionKeyVaultUri string
param encryptionUserAssignedIdentityResourceId string
param fileShares array
param functionAppDelegatedSubnetResourceId string
param hostPoolResourceId string
param identitySolution string
param increaseQuota bool
param increaseQuotaApplicationInsightsName string
param increaseQuotaFunctionAppName string
param increaseQuotaStorageAccountName string
param kerberosEncryptionType string
param keyManagementStorageAccounts string
param location string
param logAnalyticsWorkspaceId string
param deploymentVirtualMachineName string
param ouPath string
param privateEndpoint bool
param privateEndpointLocation string
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param privateEndpointSubnetResourceId string
param privateLinkScopeResourceId string
param recoveryServices bool
param recoveryServicesVaultName string
param resourceGroupDeployment string
param resourceGroupStorage string
param serverFarmId string
param shardingOptions string
param shareAdminGroups array
param shareSizeInGB int
param shareUserGroups array
param storageAccountNamePrefix string
param storageEncryptionKeySuffix string
param storageCount int
param storageIndex int
param storageSku string
param storageSolution string
param tags object
param timeStamp string
param timeZone string

var adminRoleDefinitionId = 'a7264617-510b-434b-a828-9731dc254ea7' // Storage File Data SMB Share Elevated Contributor

var privateEndpointVnetName = !empty(privateEndpointSubnetResourceId) && privateEndpoint
  ? split(privateEndpointSubnetResourceId, '/')[8]
  : ''

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
      allowSharedKeyAccess: true
      azureFilesIdentityBasedAuthentication: contains(identitySolution, 'DomainServices') ? {
        defaultSharePermission: 'StorageFileDataSmbShareContributor'
        directoryServiceOptions: identitySolution == 'EntraDomainServices' ? 'AADDS' : 'None'
      } : null
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
              keyname: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}${storageEncryptionKeySuffix}'
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
    tags: union({ 'cm-resource-parent' : hostPoolResourceId }, tags[?'Microsoft.Storage/storageAccounts'] ?? {})
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

// Assigns the SMB Elevated Contributor role to the Storage Account for admins so they can adjust NTFS permissions if needed.
module roleAssignmentsAdmins '../../common/roleAssignment-storageAccount.bicep' = [
  for i in range(0, storageCount): if (contains(identitySolution, 'DomainServices') && !empty(shareAdminGroups)) {
    name: '${storageAccounts[i].name}_AdminRoleAssignments_${timeStamp}'
    params: {
      principalIds: map(shareAdminGroups, group => group.objectId)
      principalType: 'Group'
      storageAccountResourceId: storageAccounts[i].id
      roleDefinitionId: adminRoleDefinitionId
    }
  }
]

module shares 'shares.bicep' = [
  for i in range(0, storageCount): {
    name: '${storageAccounts[i].name}_fileShares_${timeStamp}'
    params: {
      fileShares: fileShares
      shareSizeInGB: shareSizeInGB
      StorageAccountName: storageAccounts[i].name
      storageSku: storageSku
    }
    dependsOn: [
      roleAssignmentsAdmins
    ]
  }
]

module privateEndpoints '../../../../sharedModules/resources/network/private-endpoint/main.bicep' = [
  for i in range(0, storageCount): if (privateEndpoint) {
    name: '${storageAccounts[i].name}_privateEndpoint_${timeStamp}'
    params: {
      customNetworkInterfaceName: replace(
        replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'file'), 'RESOURCE', '${storageAccounts[i].name}'),
        'VNETID',
        privateEndpointVnetName
      )
      groupIds: [
        'file'
      ]
      location: !empty(privateEndpointLocation) ? privateEndpointLocation : location
      name: replace(
        replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'file'), 'RESOURCE', '${storageAccounts[i].name}'),
        'VNETID',
        privateEndpointVnetName
      )
      privateDnsZoneGroup: empty(azureFilePrivateDnsZoneResourceId) ? null : {
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

module SetNTFSPermissions 'domainJoinSetNTFSPermissions.bicep' = if (contains(identitySolution, 'DomainServices')) {
  name: 'Set-NTFSPermissions_${timeStamp}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    adminGroupNames: map(shareAdminGroups, group => group.displayName)
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    domainJoinUserPassword: domainJoinUserPassword
    kerberosEncryptionType: kerberosEncryptionType
    location: location
    ouPath: ouPath
    resourceGroupStorage: resourceGroupStorage
    shardingOptions: shardingOptions
    shares: fileShares
    storageAccountNamePrefix: storageAccountNamePrefix
    storageCount: storageCount
    storageIndex: storageIndex
    storageSolution: storageSolution
    timeStamp: timeStamp
    userAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    userGroupNames: map(shareUserGroups, group => group.displayName)
    virtualMachineName: deploymentVirtualMachineName
  }
  dependsOn: [
    privateEndpoints
    shares
  ]
}

module recoveryServicesVault '../../../../sharedModules/resources/recovery-services/vault/main.bicep' = if (recoveryServices) {
  name: 'RecoveryServices_AzureFiles_${timeStamp}'
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
                replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'AzureBackup'),
                'RESOURCE',
                recoveryServicesVaultName
              ),
              'VNETID',
              '${split(privateEndpointSubnetResourceId, '/')[8]}'
            )
            name: replace(
              replace(
                replace(privateEndpointNameConv, 'SUBRESOURCE', 'AzureBackup'),
                'RESOURCE',
                recoveryServicesVaultName
              ),
              'VNETID',
              '${split(privateEndpointSubnetResourceId, '/')[8]}'
            )
            privateDnsZoneGroup: empty(nonEmptyBackupPrivateDNSZoneResourceIds) ? null : {
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
  name: 'IncreaseQuotaFunctionApp_${timeStamp}'
  params: {
    location: location
    applicationInsightsName: increaseQuotaApplicationInsightsName
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    azureFunctionAppPrivateDnsZoneResourceId: azureFunctionAppPrivateDnsZoneResourceId
    azureFunctionAppScmPrivateDnsZoneResourceId: azureFunctionAppScmPrivateDnsZoneResourceId
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
    keyVaultName: encryptionKeyVaultName
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
    timeStamp: timeStamp
  }
}

module increaseQuotaFunction '../../common/functionApp/function.bicep' = if (storageSku == 'Premium' && increaseQuota && storageCount > 0) {
  name: 'IncreaseQuotaFunction_${timeStamp}'
  params: {
    files: {
      'requirements.psd1': loadTextContent('../../../../../.common/scripts//auto-increase-file-share/requirements.psd1')
      'run.ps1': loadTextContent('../../../../../.common/scripts//auto-increase-file-share/run.ps1')
      '../profile.ps1': loadTextContent('../../../../../.common/scripts//auto-increase-file-share/profile.ps1')
    }
    functionAppName: increaseQuotaFunctionApp.outputs.functionAppName
    functionName: 'auto-increase-file-share-quota'
    schedule: '0 */15 * * * *'
  }
}

output storageAccountResourceIds array = [for i in range(0, storageCount): storageAccounts[i].id]
