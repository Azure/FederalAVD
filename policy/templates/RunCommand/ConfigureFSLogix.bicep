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
param configurationVersion string
param profileSizeInMBs int
param virtualMachineName string

// Storage Accounts
var fslogixLocalStorageAccountNames = [for id in fslogixLocalStorageAccountResourceIds: last(split(id, '/'))]
var fslogixRemoteStorageAccountNames = [for id in fslogixRemoteStorageAccountResourceIds: last(split(id, '/'))]
//  only get keys if EntraId
var fslogixLocalSAKey1 = identitySolution == 'EntraId' && !empty(fslogixLocalStorageAccountResourceIds) ? [ localStorageAccounts[0].listkeys().keys[0].value ] : []
var fslogixLocalSAKey2 = identitySolution == 'EntraId' && length(fslogixLocalStorageAccountResourceIds) > 1 ? [ localStorageAccounts[1].listkeys().keys[0].value ] : []
var fslogixLocalStorageAccountKeys = union(fslogixLocalSAKey1, fslogixLocalSAKey2)
var fslogixRemoteAKey1 = identitySolution == 'EntraId' && !empty(fslogixRemoteStorageAccountResourceIds) ? [ remoteStorageAccounts[0].listkeys().keys[0].value ] : []
var fslogixRemoteSAKey2 = identitySolution == 'EntraId' && length(fslogixRemoteStorageAccountResourceIds) > 1 ? [ remoteStorageAccounts[1].listkeys().keys[0].value ] : []
var fslogixRemoteStorageAccountKeys = union(fslogixRemoteAKey1, fslogixRemoteSAKey2)

// call on new storage accounts only if we need the Storage Key(s)
resource localStorageAccounts 'Microsoft.Storage/storageAccounts@2023-01-01' existing = [for resId in fslogixLocalStorageAccountResourceIds: if(identitySolution == 'EntraId' && !empty(fslogixLocalStorageAccountResourceIds)) {
  name: last(split(resId, '/'))
  scope: resourceGroup(split(resId, '/')[2], split(resId, '/')[4])
}]

// call on remote storage accounts only if we need the Storage Key(s)
resource remoteStorageAccounts 'Microsoft.Storage/storageAccounts@2023-01-01' existing = [for resId in fslogixRemoteStorageAccountResourceIds: if(identitySolution == 'EntraId' && !empty(fslogixRemoteStorageAccountResourceIds)) {
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
        name: 'ConfigurationVersion'
        value: configurationVersion
      }
      {
        name: 'ConfigureFSLogix'
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
        name: 'RunCommandName'
        value: runCommandName
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
        name: 'StorageAccountDNSSuffix'
        value: environment().suffixes.storage
      }
      {
        name: 'StorageService'
        value: fslogixStorageService
      }      
    ]
    protectedParameters: [
      {
        name: 'LocalStorageAccountKeys'
        value: string(fslogixLocalStorageAccountKeys)
      }
      {
        name: 'RemoteStorageAccountKeys'
        value: string(fslogixRemoteStorageAccountKeys)
      }
    ]
    source: {
      script: loadTextContent('../../../deployments/shared/scripts/Set-FSLogixSessionHostConfiguration.ps1')
    }
    timeoutInSeconds: 180
    treatFailureAsDeploymentFailure: true    
  }
}
