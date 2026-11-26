metadata name = 'Session host configuration remediation template'
metadata description = 'Deploys automated session-host initialization as a named Run Command on an existing VM for policy remediation.'

import { validateObjectSpecificSettings } from '../../../../fslogix/fslogix.bicep'

// Time zone and optional FSLogix inputs are forwarded to the embedded initialization script.
// This remediation does not create storage; supplied accounts, shares, and NetApp endpoints must exist.

@description('Required. Whether to forward enabled FSLogix configuration to the embedded initialization script.')
param configureFSLogix bool
@description('Required. FSLogix container selection used to derive share names and Cloud Cache behavior.')
param fslogixContainerType string
@description('Required. Array of existing local Azure Files storage account IDs forwarded to FSLogix initialization.')
param fslogixLocalProfileStorageAccountResourceIds array
@description('Optional. Existing local Office Azure Files account IDs paired with local Profile accounts in shard order.')
param fslogixLocalOfficeStorageAccountResourceIds array = []
@description('Required. Array of local NetApp SMB server FQDN strings aligned with the ordered share names.')
param fslogixLocalNetAppServerFqdns array
@description('Required. Array of group name strings forwarded as the initialization script OSSGroups argument.')
param fslogixOSSGroups array
@description('Required. Array of existing remote Azure Files storage account IDs for FSLogix Cloud Cache initialization.')
param fslogixRemoteProfileStorageAccountResourceIds array
@description('Optional. Existing remote Office Azure Files account IDs paired with remote Profile accounts in shard order.')
param fslogixRemoteOfficeStorageAccountResourceIds array = []
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

var fslogixLocalProfileStorageAccountNames = [for id in fslogixLocalProfileStorageAccountResourceIds: last(split(id, '/'))]
var fslogixRemoteProfileStorageAccountNames = [for id in fslogixRemoteProfileStorageAccountResourceIds: last(split(id, '/'))]
var fslogixLocalOfficeStorageAccountNames = [for id in fslogixLocalOfficeStorageAccountResourceIds: last(split(id, '/'))]
var fslogixRemoteOfficeStorageAccountNames = [for id in fslogixRemoteOfficeStorageAccountResourceIds: last(split(id, '/'))]
var useStorageKeys = configureFSLogix && identitySolution == 'EntraId' && fslogixStorageService == 'AzureFiles'
var objectSpecificSettingsAreValid = validateObjectSpecificSettings(identitySolution, configureFSLogix && !empty(fslogixOSSGroups))

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
        value: objectSpecificSettingsAreValid && configureFSLogix ? 'true' : 'false'
      }
      {
        name: 'ContainerType'
        value: fslogixContainerType
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
        name: 'LocalProfileStorageAccountNames'
        value: string(fslogixLocalProfileStorageAccountNames)
      }
      {
        name: 'LocalOfficeStorageAccountNames'
        value: string(fslogixLocalOfficeStorageAccountNames)
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
        name: 'RemoteProfileStorageAccountNames'
        value: string(fslogixRemoteProfileStorageAccountNames)
      }
      {
        name: 'RemoteOfficeStorageAccountNames'
        value: string(fslogixRemoteOfficeStorageAccountNames)
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
    protectedParameters: [
      {
        name: 'LocalProfileStorageAccountKeys'
        value: useStorageKeys && length(fslogixLocalProfileStorageAccountResourceIds) == 1 ? string([listKeys(fslogixLocalProfileStorageAccountResourceIds[0], '2023-05-01').keys[0].value]) : '[]'
      }
      {
        name: 'RemoteProfileStorageAccountKeys'
        value: useStorageKeys && length(fslogixRemoteProfileStorageAccountResourceIds) == 1 ? string([listKeys(fslogixRemoteProfileStorageAccountResourceIds[0], '2023-05-01').keys[0].value]) : '[]'
      }
      {
        name: 'LocalOfficeStorageAccountKeys'
        value: useStorageKeys && length(fslogixLocalOfficeStorageAccountResourceIds) == 1 ? string([listKeys(fslogixLocalOfficeStorageAccountResourceIds[0], '2023-05-01').keys[0].value]) : '[]'
      }
      {
        name: 'RemoteOfficeStorageAccountKeys'
        value: useStorageKeys && length(fslogixRemoteOfficeStorageAccountResourceIds) == 1 ? string([listKeys(fslogixRemoteOfficeStorageAccountResourceIds[0], '2023-05-01').keys[0].value]) : '[]'
      }
    ]
    source: {
      script: loadTextContent('../../../../../../../automatedHostPools/scripts/Initialize-SessionHost.ps1')
    }
    timeoutInSeconds: 900
    treatFailureAsDeploymentFailure: true
  }
}
