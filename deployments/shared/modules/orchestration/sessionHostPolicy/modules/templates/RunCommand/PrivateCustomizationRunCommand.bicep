metadata name = 'Private customization remediation command'
metadata description = 'Deploys one named customization Run Command on an existing VM, resolving the attached artifact identity client ID for private artifact access.'

@description('Required. URI of the customization artifact read using the VM artifact identity.')
param artifactUri string
@description('Optional. Argument string forwarded to the customization script; empty omits the Arguments parameter.')
param arguments string = ''
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Name of the Run Command child resource created on the existing VM.')
param runCommandName string
@description('Optional. Comma-separated exit codes forwarded as successful results; empty leaves the customization script default.')
param successExitCodes string = ''
@description('Required. Resource ID of the existing artifact identity attached to the VM and authorized to read the private artifacts.')
param userAssignedIdentityResourceId string
@description('Required. Name of the existing VM in the deployment resource group.')
param virtualMachineName string

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-03-01' existing = {
  name: virtualMachineName
}

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: last(split(userAssignedIdentityResourceId, '/'))!
  scope: resourceGroup(
    split(userAssignedIdentityResourceId, '/')[2],
    split(userAssignedIdentityResourceId, '/')[4]
  )
}

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: virtualMachine
  name: runCommandName
  location: location
  properties: {
    parameters: union(
      [
        {
          name: 'APIVersion'
          value: '2018-02-01'
        }
        {
          name: 'BlobStorageSuffix'
          value: 'blob.${environment().suffixes.storage}'
        }
        {
          name: 'Name'
          value: runCommandName
        }
        {
          name: 'Uri'
          value: artifactUri
        }
        {
          name: 'UserAssignedIdentityClientId'
          value: userAssignedIdentity.properties.clientId
        }
      ],
      empty(arguments)
        ? []
        : [
            {
              name: 'Arguments'
              value: arguments
            }
          ],
      empty(successExitCodes)
        ? []
        : [
            {
              name: 'SuccessExitCodes'
              value: successExitCodes
            }
          ]
    )
    source: {
      script: loadTextContent('../../../../../../scripts/Invoke-Customization.ps1')
    }
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
}
