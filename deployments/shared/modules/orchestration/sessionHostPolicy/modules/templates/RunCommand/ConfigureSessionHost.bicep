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

var fslogixLocalStorageAccountNames = [for id in fslogixLocalStorageAccountResourceIds: last(split(id, '/'))]
var fslogixRemoteStorageAccountNames = [for id in fslogixRemoteStorageAccountResourceIds: last(split(id, '/'))]

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
    source: {
      script: loadTextContent('../../../../../../../automatedHostPools/scripts/Initialize-SessionHost.ps1')
    }
    timeoutInSeconds: 900
    treatFailureAsDeploymentFailure: true
  }
}
