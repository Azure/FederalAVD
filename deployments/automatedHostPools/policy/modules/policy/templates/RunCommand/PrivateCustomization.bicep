type resolvedPolicyCustomizationType = {
  name: string
  artifactUri: string
  arguments: string?
}

param customizations resolvedPolicyCustomizationType[]
param location string
param userAssignedIdentityResourceId string
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
