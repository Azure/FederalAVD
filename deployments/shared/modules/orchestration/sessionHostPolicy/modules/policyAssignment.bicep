targetScope = 'resourceGroup'

param name string
param location string
param policyIdentityResourceId string
param policyDefinitionResourceId string
param displayName string
param description string
param parameters object = {}
param nonComplianceMessage string = ''
param ownerId string

resource policyAssignment 'Microsoft.Authorization/policyAssignments@2024-05-01' = {
  name: name
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${policyIdentityResourceId}': {}
    }
  }
  properties: {
    displayName: displayName
    description: description
    enforcementMode: 'Default'
    metadata: {
      category: 'Azure Virtual Desktop'
      managedBy: 'FederalAVD'
      ownerId: ownerId
    }
    policyDefinitionId: policyDefinitionResourceId
    parameters: parameters
    nonComplianceMessages: empty(nonComplianceMessage) ? [] : [{ message: nonComplianceMessage }]
  }
}

output resourceId string = policyAssignment.id
