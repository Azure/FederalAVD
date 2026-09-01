targetScope = 'resourceGroup'

param name string
param policyAssignmentId string
param policyDefinitionReferenceId string = ''

resource remediation 'Microsoft.PolicyInsights/remediations@2021-10-01' = {
  name: name
  properties: {
    policyAssignmentId: policyAssignmentId
    policyDefinitionReferenceId: empty(policyDefinitionReferenceId) ? null : policyDefinitionReferenceId
    resourceDiscoveryMode: 'ReEvaluateCompliance'
  }
}

output resourceId string = remediation.id
