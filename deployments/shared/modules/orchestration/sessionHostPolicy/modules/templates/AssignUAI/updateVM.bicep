param vmName string
param location string
param identityType string
param userAssignedIdentities object

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  identity: {
    type: identityType
    userAssignedIdentities: userAssignedIdentities
  }
}
