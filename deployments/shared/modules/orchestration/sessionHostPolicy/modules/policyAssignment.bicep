metadata name = 'Session host policy assignment'
metadata description = 'Assigns a supplied definition or initiative at the dedicated session-host resource-group scope using an existing user-assigned identity and deterministic ownership metadata.'

targetScope = 'resourceGroup'

@sys.description('Required. Deterministic policy assignment name within the dedicated session-host resource group.')
param name string
@sys.description('Required. Azure region stored on the policy assignment for its managed identity.')
param location string
@sys.description('Required. Resource ID of the existing user-assigned identity used by Azure Policy for remediation.')
param policyIdentityResourceId string
@sys.description('Required. Resource ID of the existing policy definition or initiative to assign.')
param policyDefinitionResourceId string
@sys.description('Required. Human-readable display name for the policy assignment.')
param displayName string
@sys.description('Required. Description recorded on the policy assignment.')
param description string
@sys.description('Optional. Policy parameter envelope keyed by definition parameter name, with each entry shaped as { value: ... }.')
param parameters object = {}
@sys.description('Optional. Assignment-wide noncompliance message; empty omits custom messages.')
param nonComplianceMessage string = ''
@sys.description('Required. Stable ownership label recorded in policy assignment metadata.')
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

@sys.description('Resource ID of the resource-group policy assignment.')
output resourceId string = policyAssignment.id
