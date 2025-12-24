param appInsightsName string
param azureBlobPrivateDnsZoneResourceId string
param azureFilePrivateDnsZoneResourceId string
param azureFunctionAppPrivateDnsZoneResourceId string
param azureQueuePrivateDnsZoneResourceId string
param azureTablePrivateDnsZoneResourceId string
param deploymentSuffix string
param encryptionKeyName string
param encryptionKeyVaultUri string
param encryptionUserAssignedIdentityResourceId string
param fslogixFileShareNames array
param functionAppDelegatedSubnetResourceId string
param functionAppName string
param hostPoolResourceId string
param keyManagementStorageAccounts string
param location string
param logAnalyticsWorkspaceResourceId string
param privateEndpoint bool
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param privateEndpointSubnetResourceId string
param privateLinkScopeResourceId string
param resourceGroupStorage string
param serverFarmId string
param storageAccountName string
param tags object

module increaseQuotaFunctionApp '../../../sharedModules/custom/functionApp/functionApp.bicep' = {
  name: 'IncreaseQuotaFunctionApp-${deploymentSuffix}'
  params: {
    location: location
    applicationInsightsName: appInsightsName
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    azureFunctionAppPrivateDnsZoneResourceId: azureFunctionAppPrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    azureTablePrivateDnsZoneResourceId: azureTablePrivateDnsZoneResourceId
    enableApplicationInsights: !empty(logAnalyticsWorkspaceResourceId)
    functionAppDelegatedSubnetResourceId: functionAppDelegatedSubnetResourceId
    functionAppAppSettings: [
      {
        name: 'FileShareNames'
        value: string(fslogixFileShareNames)
      }
      {
        name: 'ResourceGroupName'
        value: resourceGroupStorage
      }
    ]
    encryptionUserAssignedIdentityResourceId: encryptionUserAssignedIdentityResourceId
    functionAppName: functionAppName
    hostPoolResourceId: hostPoolResourceId
    keyManagementStorageAccounts: keyManagementStorageAccounts
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
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
    storageAccountName: storageAccountName
    tags: tags
    deploymentSuffix: deploymentSuffix
    encryptionKeyName: encryptionKeyName
    encryptionKeyVaultUri: encryptionKeyVaultUri
  }
}

module increaseQuotaFunction '../../../sharedModules/custom/functionApp/function.bicep' = {
  name: 'IncreaseQuotaFunction-${deploymentSuffix}'
  params: {
    files: {
      'requirements.psd1': loadTextContent('../../../../.common/scripts/auto-increase-file-share/requirements.psd1')
      'run.ps1': loadTextContent('../../../../.common/scripts/auto-increase-file-share/run.ps1')
      '../profile.ps1': loadTextContent('../../../../.common/scripts/auto-increase-file-share/profile.ps1')
    }
    functionAppName: increaseQuotaFunctionApp!.outputs.functionAppName
    functionName: 'auto-increase-file-share-quota'
    schedule: '0 */60 * * * *' // Run every 60 minutes
  }
}

output functionAppName string = increaseQuotaFunctionApp.outputs.functionAppName
