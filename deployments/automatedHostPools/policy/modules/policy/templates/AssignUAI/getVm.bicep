param vmname string

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' existing = {
  name: vmname
}

output identityType string = vm.?identity.?type ?? 'None'
output userAssignedIdentities object = vm.?identity.?userAssignedIdentities ?? {}
