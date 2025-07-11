targetScope = 'subscription'

@description('The location of the virtual machines where the run commands will be executed.')
param location string = deployment().location

@description('Required. The name of the resource group in which to deploy the resources.')
param resourceGroupName string

@description('Required. The names of the virtual machines on which to run the scripts.')
param vmNames array

@description('Optional. An array of objects that define the scripts to run. Each object must contain a "name" and "blobNameOrUri" property.')
param scripts array = []

@description('Optional. The name of the storage account where the logs will be stored.')
param logsStorageAccountName string = ''

@description('Optional. The name of the container in the storage account where the logs will be stored.')
param logsContainerName string = ''

@description('Optional. The resource ID of the user-assigned identity to use for logging.')
param logsUserAssignedIdentityResourceId string = ''

@description('Optional. The name of the storage account where the scripts are stored.')
param scriptsStorageAccountName string = ''

@description('Optional. The name of the container in the storage account where the scripts are stored.')
param scriptsContainerName string = ''

@description('Optional. The resource ID of the user-assigned identity to use for running the scripts.')
param scriptsUserAssignedIdentityResourceId string = ''

@description('Optional. The name of the run command to execute.')
param runCommandName string = ''

@description('Optional. The content of the script to run.')
param scriptContent string = ''

@description('Optional. The URI of the script to run.')
param scriptUri string = ''

@description('Optional. The timeout in seconds for the script execution. Default is 5400 (90 minutes).')
param timeoutInSeconds int = 5400

@description('Optional. The parameters to pass to the script.')
param parameters array = []

@description('Optional. The name and value of the protected parameter to pass to the script.')
@secure()
param protectedParameter object = {}

@description('Do Not Update. Used to name deployments and logs.')
param timeStamp string = utcNow('yyyyMMddHHmm')

var logsContainerUri = empty(logsContainerName) || empty(logsStorageAccountName)
  ? ''
  : 'https://${logsStorageAccountName}.blob.${environment().suffixes.storage}/${logsContainerName}'

var scriptsContainerUri = empty(scriptsContainerName) || empty(scriptsStorageAccountName)
  ? ''
  : 'https://${scriptsStorageAccountName}.blob.${environment().suffixes.storage}/${scriptsContainerName}'

var multipleScripts = [
  for script in scripts: {
    name: replace(script.name, ' ', '-')
    uri: contains(script.blobNameOrUri, '://') ? script.blobNameOrUri : '${scriptsContainerUri}/${script.blobNameOrUri}'
    arguments: script.?arguments ?? ''
  }
]

resource logsUserAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = if (!empty(logsUserAssignedIdentityResourceId)) {
  name: last(split(logsUserAssignedIdentityResourceId, '/'))
  scope: resourceGroup(
    split(logsUserAssignedIdentityResourceId, '/')[2],
    split(logsUserAssignedIdentityResourceId, '/')[4]
  )
}

resource scriptsUserAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = if (!empty(scriptsUserAssignedIdentityResourceId)) {
  name: last(split(scriptsUserAssignedIdentityResourceId, '/'))
  scope: resourceGroup(
    split(scriptsUserAssignedIdentityResourceId, '/')[2],
    split(scriptsUserAssignedIdentityResourceId, '/')[4]
  )
}

resource existingVms 'Microsoft.Compute/virtualMachines@2023-03-01' existing = [
  for (vmName, i) in vmNames: {
    name: vmName
    scope: resourceGroup(resourceGroupName)
  }
]

module updateVms 'virtualMachineUpdate.bicep' = [
   for (vmName, i) in vmNames: if(!empty(logsUserAssignedIdentityResourceId) || !empty(scriptsUserAssignedIdentityResourceId)) {
    name: 'VirtualMachineUpdate-${vmName}-${timeStamp}'
    scope: resourceGroup(resourceGroupName)
    params: {
      location: location
      name: vmNames[i]
      identity: existingVms[i].?identity
      logsUserAssignedIdentityResourceId: logsUserAssignedIdentityResourceId
      scriptsUserAssignedIdentityResourceId: scriptsUserAssignedIdentityResourceId
      hardwareProfile: existingVms[i].properties.hardwareProfile
      storageProfile: existingVms[i].properties.storageProfile
      osProfile: existingVms[i].properties.osProfile
      networkProfile: existingVms[i].properties.networkProfile
    }
  }
]

module runCommands 'runCommands.bicep' = [
  for (vmName, i) in vmNames: if (!empty(scripts)) {
    name: 'RunCommands-${vmName}-${timeStamp}'
    scope: resourceGroup(resourceGroupName)
    params: {
      scripts: multipleScripts
      location: location
      logsContainerUri: logsContainerUri
      logsUserAssignedIdentityClientId: empty(logsUserAssignedIdentityResourceId)
        ? ''
        : logsUserAssignedIdentity.properties.clientId
      scriptsUserAssignedIdentityClientId: empty(scriptsUserAssignedIdentityResourceId)
        ? ''
        : scriptsUserAssignedIdentity.properties.clientId
      timeStamp: timeStamp
      virtualMachineName: vmNames[i]
    }
    dependsOn: [
      updateVms[i]
    ]
  }
]

module runCommand 'runCommand.bicep' = [
  for (vmName, i) in vmNames: if (empty(scripts)) {
    name: 'RunCommand-${vmName}-${timeStamp}'
    scope: resourceGroup(resourceGroupName)
    params: {
      location: location
      vmName: vmNames[0]
      runCommandName: runCommandName
      logsContainerUri: logsContainerUri
      logsUserAssignedIdentityClientId: empty(logsUserAssignedIdentityResourceId)
        ? ''
        : logsUserAssignedIdentity.properties.clientId
      scriptsUserAssignedIdentityClientId: empty(scriptsUserAssignedIdentityResourceId)
        ? ''
        : scriptsUserAssignedIdentity.properties.clientId
      parameters: parameters
      protectedParameter: protectedParameter
      scriptContent: scriptContent
      scriptUri: scriptUri
      timeoutInSeconds: timeoutInSeconds
      timeStamp: timeStamp
    }
    dependsOn: [
      updateVms[i]
    ]
  }
]
