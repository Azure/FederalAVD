param artifactUri string
param arguments string
param configurationVersion string
param location string
param runCommandName string
param userAssignedIdentityResourceId string
param virtualMachineName string

module assignArtifactIdentity '../AssignUAI/deploy.bicep' = {
  params: {
    userAssignedIdentityResourceId: userAssignedIdentityResourceId
    vmName: virtualMachineName
    location: location
  }
}

module customization 'PrivateCustomizationRunCommand.bicep' = {
  params: {
    artifactUri: artifactUri
    arguments: arguments
    configurationVersion: configurationVersion
    location: location
    runCommandName: runCommandName
    userAssignedIdentityResourceId: userAssignedIdentityResourceId
    virtualMachineName: virtualMachineName
  }
  dependsOn: [
    assignArtifactIdentity
  ]
}