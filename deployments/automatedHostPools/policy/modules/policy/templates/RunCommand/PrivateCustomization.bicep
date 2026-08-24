param customizations array
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
  for customization in customizations: {
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
