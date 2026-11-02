metadata name = 'Session host policy remediation task'
metadata description = 'Creates a resource-group remediation task that reevaluates compliance for a supplied policy assignment or a selected initiative member.'

targetScope = 'resourceGroup'

@description('Required. Deterministic remediation task name within the assignment resource group.')
param name string
@description('Required. Resource ID of the existing resource-group policy assignment to remediate.')
param policyAssignmentId string
@description('Optional. Initiative member reference ID to remediate; leave empty for an individual policy definition.')
param policyDefinitionReferenceId string = ''

resource remediation 'Microsoft.PolicyInsights/remediations@2021-10-01' = {
  name: name
  properties: {
    policyAssignmentId: policyAssignmentId
    policyDefinitionReferenceId: empty(policyDefinitionReferenceId) ? null : policyDefinitionReferenceId
    resourceDiscoveryMode: 'ReEvaluateCompliance'
  }
}

@description('Resource ID of the resource-group remediation task.')
output resourceId string = remediation.id
