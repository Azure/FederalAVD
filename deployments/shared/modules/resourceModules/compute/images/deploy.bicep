metadata name = 'Managed image'
metadata description = 'Captures a managed image from an existing virtual machine supplied by the caller; source VM preparation is managed outside this module.'

@description('Required. Name of the managed image to deploy.')
param name string
@description('Optional. Azure region for the managed image; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the managed image.')
param tags object = {}

@description('Resource ID of the source virtual machine to capture.')
param sourceVirtualMachineResourceId string

@description('Hyper-V generation of the virtual machine. V1 or V2.')
@allowed(['V1', 'V2'])
param hyperVGeneration string = 'V2'

resource image 'Microsoft.Compute/images@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    hyperVGeneration: hyperVGeneration
    sourceVirtualMachine: {
      id: sourceVirtualMachineResourceId
    }
  }
}

@description('Resource ID of the managed image.')
output resourceId string = image.id
@description('Azure resource name of the managed image.')
output name string = image.name
