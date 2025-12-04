param storageAccountName string
param kind string
param identitySolution string
param sku object
param location string
param domainGuid string
param domainName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  properties: {
    azureFilesIdentityBasedAuthentication: {   
      activeDirectoryProperties: !empty(domainGuid) && !empty(domainName) ? {
        domainGuid: domainGuid
        domainName: domainName
      } : null
      defaultSharePermission: identitySolution == 'EntraKerberos-Hybrid' ? 'None' : 'StorageFileDataSmbShareElevatedContributor'   
      directoryServiceOptions: 'AADKERB'
    }
  }
  kind: kind
  location: location
  sku: sku
}
