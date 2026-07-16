// Runs the Azure Local image replication script on the orchestration VM via a Run Command.
// The script exports the captured gallery image version to a temporary managed disk,
// generates a SAS URL, creates a Microsoft.AzureStackHCI/galleryImages resource on the
// target Azure Local instance, and then cleans up the temporary disk.

param orchestrationVmName string
param location string
param deploymentSuffix string
param depPrefix string

@description('Full resource ID of the captured gallery image version to replicate.')
param imageVersionId string

@description('Azure region where the temporary managed disk will be created (must match the image version primary region).')
param diskLocation string

@description('Resource ID of the Azure Local custom location.')
param azureLocalCustomLocationResourceId string

@description('Resource ID of the target resource group on Azure Local in which to create the VM image.')
param azureLocalResourceGroupId string

@description('Name for the Azure Local VM image.')
param azureLocalImageName string

@description('Hyper-V generation of the source image (V1 or V2).')
param hyperVGeneration string

@description('Client ID of the user-assigned managed identity used by the orchestration VM. Pass an empty string when the orchestration VM uses its system-assigned identity.')
param userAssignedIdentityClientId string

module azureLocalReplicationRunCommand '../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  name: '${depPrefix}AzureLocal-Replication-${deploymentSuffix}'
  params: {
    location: location
    name: 'AzureLocalImageReplication'
    virtualMachineName: orchestrationVmName
    script: loadTextContent('../../../.common/scripts/Invoke-AzureLocalImageReplication.ps1')
    treatFailureAsDeploymentFailure: true
    // Allow up to 4 hours: large images (130+ GB) can take 2+ hours to download to the
    // Azure Local cluster depending on the available network bandwidth.
    timeoutInSeconds: 14400
    parameters: [
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'UserAssignedIdentityClientId', value: userAssignedIdentityClientId }
      { name: 'ImageVersionId', value: imageVersionId }
      { name: 'DiskLocation', value: diskLocation }
      { name: 'AzureLocalCustomLocationResourceId', value: azureLocalCustomLocationResourceId }
      { name: 'AzureLocalResourceGroupId', value: azureLocalResourceGroupId }
      { name: 'AzureLocalImageName', value: azureLocalImageName }
      { name: 'HyperVGeneration', value: hyperVGeneration }
    ]
  }
}
