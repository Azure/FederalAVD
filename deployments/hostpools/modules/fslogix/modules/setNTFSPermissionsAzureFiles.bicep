param adminGroups array
param location string
param shardingOptions string
param shares array
param storageAccountNamePrefix string
param storageCount int = 0
param storageIndex int = 0
param userGroups array
param userAssignedIdentityClientId string
param virtualMachineName string

resource virtualMachine 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: virtualMachineName
}

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'Set-NTFS-Permissions'
  location: location
  parent: virtualMachine
  properties: {
    asyncExecution: false
    parameters: [
      {
        name: 'AdminGroups'
        value: string(adminGroups)
      }
      {
        name: 'Shares'
        value: string(shares)
      }
      {
        name: 'ShardAzureFilesStorage'
        value: shardingOptions == 'None' ? 'false' : 'true'
      }
      {
        name: 'StorageAccountPrefix'
        value: storageAccountNamePrefix
      }
      {
        name: 'StorageCount'
        value: string(storageCount)
      }
      {
        name: 'StorageIndex'
        value: string(storageIndex)
      }
      {
        name: 'StorageSuffix'
        value: environment().suffixes.storage
      }
      {
        name: 'UserAssignedIdentityClientId'
        value: userAssignedIdentityClientId
      }
      {
        name: 'UserGroups'
        value: string(userGroups)
      }
    ]
    source: {
      script: loadTextContent('../../../../../.common/scripts/Set-NtfsPermissionsAzureFiles.ps1')
    }
    timeoutInSeconds: 300
    treatFailureAsDeploymentFailure: true
  }
}
