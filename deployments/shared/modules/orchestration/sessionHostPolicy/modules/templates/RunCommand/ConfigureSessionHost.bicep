metadata name = 'Session host configuration remediation template'
metadata description = 'Deploys automated session-host initialization as a named Run Command on an existing VM for policy remediation.'

// Time zone and optional FSLogix inputs are forwarded to the embedded initialization script.
// This remediation does not create storage; supplied accounts, shares, and NetApp endpoints must exist.

@description('Required. Whether to forward enabled FSLogix configuration to the embedded initialization script.')
param configureFSLogix bool
@description('Required. FSLogix container selection forwarded to initialization; names containing CloudCache select its CloudCache argument.')
param fslogixContainerType string
@description('Required. Ordered share name strings for initialization, with profile before Office when both are present.')
param fslogixFileShareNames array
@description('Required. Array of existing local Azure Files storage account IDs forwarded to FSLogix initialization.')
param fslogixLocalStorageAccountResourceIds array
@description('Required. Array of local NetApp SMB server FQDN strings aligned with the ordered share names.')
param fslogixLocalNetAppServerFqdns array
@description('Required. Array of group name strings forwarded as the initialization script OSSGroups argument.')
param fslogixOSSGroups array
@description('Required. Array of existing remote Azure Files storage account IDs for FSLogix Cloud Cache initialization.')
param fslogixRemoteStorageAccountResourceIds array
@description('Required. Array of remote NetApp SMB server FQDN strings aligned with the ordered share names.')
param fslogixRemoteNetAppServerFqdns array
@description('Required. Storage backend name forwarded to initialization, AzureFiles or AzureNetAppFiles.')
param fslogixStorageService string
@description('Required. Selected session-host or SMB identity mode used to choose domain, Entra, and storage configuration paths.')
param identitySolution string
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Name of the Run Command child resource created on the existing VM.')
param runCommandName string
@description('Required. Windows time zone identifier forwarded to the initialization script.')
param timeZone string
@description('Required. Profile container size in MB forwarded to the embedded initialization script.')
param profileSizeInMBs int
@description('Required. Name of the existing VM in the deployment resource group.')
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
