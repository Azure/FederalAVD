metadata name = 'VM identity lookup'
metadata description = 'Reads identity type and the user-assigned identity map from an existing VM in the deployment resource group for identity-preserving remediation.'

@description('Required. Name of the existing VM in the deployment resource group.')
param vmname string

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' existing = {
  name: vmname
}

@description('Existing VM identity type, or None when the VM has no identity.')
output identityType string = vm.?identity.?type ?? 'None'
@description('Existing user-assigned identity map keyed by identity resource ID, or an empty object when none are attached.')
output userAssignedIdentities object = vm.?identity.?userAssignedIdentities ?? {}
