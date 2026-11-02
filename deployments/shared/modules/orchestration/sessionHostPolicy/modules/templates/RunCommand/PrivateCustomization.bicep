metadata name = 'Private customization remediation orchestration'
metadata description = 'Attaches an artifact identity to an existing VM and serializes the supplied customization Run Commands in input order for policy remediation.'

type resolvedPolicyCustomizationType = {
  name: string
  artifactUri: string
  arguments: string?
  successExitCodes: string?
}

@description('Required. Ordered objects with name and artifactUri, plus optional arguments and comma-separated successExitCodes; names become VM Run Command names.')
param customizations resolvedPolicyCustomizationType[]
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Resource ID of the existing artifact identity attached to the VM and authorized to read the private artifacts.')
param userAssignedIdentityResourceId string
@description('Required. Name of the existing VM in the deployment resource group.')
param virtualMachineName string

module assignArtifactIdentity '../AssignUAI/deploy.bicep' = {
  params: {
    userAssignedIdentityResourceId: userAssignedIdentityResourceId
    vmName: virtualMachineName
    location: location
  }
}

@batchSize(1)
module customization 'PrivateCustomizationRunCommand.bicep' = [
  for (customization, index) in customizations: {
    name: 'customization-${index}-${take(virtualMachineName, 20)}-${uniqueString('customization', deployment().name)}'
    params: {
      artifactUri: customization.artifactUri
      arguments: customization.?arguments ?? ''
      successExitCodes: customization.?successExitCodes ?? ''
      location: location
      runCommandName: customization.name
      userAssignedIdentityResourceId: userAssignedIdentityResourceId
      virtualMachineName: virtualMachineName
    }
    dependsOn: [
      assignArtifactIdentity
    ]
  }
]
