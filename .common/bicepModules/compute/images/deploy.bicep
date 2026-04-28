param name string
param location string = resourceGroup().location
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

output resourceId string = image.id
output name string = image.name
