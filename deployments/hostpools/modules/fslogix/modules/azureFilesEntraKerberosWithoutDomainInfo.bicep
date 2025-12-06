param defaultSharePermission string
param storageAccountNamePrefix string
param storageCount int
param storageIndex int
param kind string
param skuName string
param location string

resource configureEntraKerberosWithoutDomainInfoold 'Microsoft.Storage/storageAccounts@2022-09-01' = [
  for i in range(0, storageCount): {
    name: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
    kind: kind
    location: location
    properties: {
      azureFilesIdentityBasedAuthentication: {
        defaultSharePermission: defaultSharePermission
        directoryServiceOptions: 'AADKERB'
      }
    }
    sku: {
      name: skuName
    }
  }
]
