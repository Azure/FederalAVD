param configureFSLogix bool
param fslogixContainerType string
param fslogixFileShareNames array
param fslogixLocalStorageAccountResourceIds array
param fslogixLocalNetAppServerFqdns array
param fslogixOSSGroups array
param fslogixRemoteStorageAccountResourceIds array
param fslogixRemoteNetAppServerFqdns array
param fslogixStorageService string
param identitySolution string
param location string
param runCommandName string
param timeZone string
param profileSizeInMBs int
param virtualMachineName string

// Storage Accounts
var fslogixLocalStorageAccountNames = [for id in fslogixLocalStorageAccountResourceIds: last(split(id, '/'))]
var fslogixRemoteStorageAccountNames = [for id in fslogixRemoteStorageAccountResourceIds: last(split(id, '/'))]
var useStorageAccountKeys = configureFSLogix && identitySolution == 'EntraId'
var fslogixLocalSAKey1 = useStorageAccountKeys && !empty(fslogixLocalStorageAccountResourceIds) ? [ localStorageAccounts[0].listkeys().keys[0].value ] : []
var fslogixLocalSAKey2 = useStorageAccountKeys && length(fslogixLocalStorageAccountResourceIds) > 1 ? [ localStorageAccounts[1].listkeys().keys[0].value ] : []
var fslogixLocalStorageAccountKeys = union(fslogixLocalSAKey1, fslogixLocalSAKey2)
var fslogixRemoteSAKey1 = useStorageAccountKeys && !empty(fslogixRemoteStorageAccountResourceIds) ? [ remoteStorageAccounts[0].listkeys().keys[0].value ] : []
var fslogixRemoteSAKey2 = useStorageAccountKeys && length(fslogixRemoteStorageAccountResourceIds) > 1 ? [ remoteStorageAccounts[1].listkeys().keys[0].value ] : []
var fslogixRemoteStorageAccountKeys = union(fslogixRemoteSAKey1, fslogixRemoteSAKey2)

resource localStorageAccounts 'Microsoft.Storage/storageAccounts@2023-01-01' existing = [for resId in fslogixLocalStorageAccountResourceIds: if(useStorageAccountKeys) {
  name: last(split(resId, '/'))
  scope: resourceGroup(split(resId, '/')[2], split(resId, '/')[4])
}]

resource remoteStorageAccounts 'Microsoft.Storage/storageAccounts@2023-01-01' existing = [for resId in fslogixRemoteStorageAccountResourceIds: if(useStorageAccountKeys) {
  name: last(split(resId, '/'))
  scope: resourceGroup(split(resId, '/')[2], split(resId, '/')[4])
}]

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-03-01' existing = {
  name: virtualMachineName
}

resource runCommand_ConfigureFSLogix 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: virtualMachine
  name: runCommandName
  location: location
  properties: {
    parameters: [
      {
        name: 'ConfigureFSLogix'
        value: configureFSLogix ? 'true' : 'false'
      }
      {
        name: 'ConfigurationOnly'
        value: 'true'
      }
      {
        name: 'CloudCache'
        value: contains(fslogixContainerType, 'CloudCache') ? 'true' : 'false'
      }
      {
        name: 'IdentitySolution'
        value: identitySolution
      }
      {
        name: 'LocalNetAppServers'
        value: string(fslogixLocalNetAppServerFqdns)
      }
      {
        name: 'LocalStorageAccountNames'
        value: string(fslogixLocalStorageAccountNames)
      }
      {
        name: 'OSSGroups'
        value: string(fslogixOSSGroups)
      }
      {
        name: 'RemoteNetAppServers'
        value: string(fslogixRemoteNetAppServerFqdns)
      }
      {
        name: 'RemoteStorageAccountNames'
        value: string(fslogixRemoteStorageAccountNames)
      }
      {
        name: 'Shares'
        value: string(fslogixFileShareNames)
      }
      {
        name: 'SizeInMBs'
        value: string(profileSizeInMBs)
      }
      {
        name: 'StorageSuffix'
        value: environment().suffixes.storage
      }
      {
        name: 'StorageService'
        value: fslogixStorageService
      }
      {
        name: 'TimeZone'
        value: timeZone
      }
    ]
    protectedParameters: useStorageAccountKeys
      ? [
          {
            name: 'LocalStorageAccountKeys'
            value: string(fslogixLocalStorageAccountKeys)
          }
          {
            name: 'RemoteStorageAccountKeys'
            value: string(fslogixRemoteStorageAccountKeys)
          }
        ]
      : []
    source: {
      script: loadTextContent('../../../../../../shared/scripts/Initialize-SessionHost.ps1')
    }
    timeoutInSeconds: 900
    treatFailureAsDeploymentFailure: true    
  }
}
