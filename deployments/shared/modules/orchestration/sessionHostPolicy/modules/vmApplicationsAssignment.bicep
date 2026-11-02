metadata name = 'VM Applications policy assignment'
metadata description = 'Assigns the supplied VM Application Modify definition at the dedicated session-host resource group with ownership metadata and an optional deterministic remediation task.'

targetScope = 'resourceGroup'

import { vmApplicationAssignmentType } from '../vmApplicationTypes.bicep'

@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Resource ID of the existing user-assigned identity used by Azure Policy for remediation.')
param policyIdentityResourceId string
@description('Required. Resource ID of the existing policy definition or initiative to assign.')
param policyDefinitionResourceId string
@description('Required. Authoritative ordered array of objects with packageReferenceId, order, and treatFailureAsDeploymentFailure for Gallery application versions.')
param vmApplications vmApplicationAssignmentType[]
@description('Optional. Whether to create deterministic remediation tasks for existing noncompliant resources.')
param createRemediation bool = false
@description('Required. Stable ownership label recorded in policy assignment metadata.')
param ownerId string

resource policyAssignment 'Microsoft.Authorization/policyAssignments@2024-05-01' = {
  name: 'avd-sh-vm-applications'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${policyIdentityResourceId}': {}
    }
  }
  properties: {
    displayName: 'Configure VM Applications on AVD session hosts'
    description: 'Configures the selected ordered Azure Compute Gallery application versions as the authoritative VM Application list on every VM in the dedicated target resource group.'
    enforcementMode: 'Default'
    metadata: {
      category: 'Azure Virtual Desktop'
      component: 'VM Applications'
      managedBy: 'FederalAVD'
      ownerId: ownerId
    }
    policyDefinitionId: policyDefinitionResourceId
    parameters: {
      effect: {
        value: 'Modify'
      }
      galleryApplications: {
        value: vmApplications
      }
    }
    nonComplianceMessages: [
      {
        message: 'The session host must use the selected ordered Azure Compute Gallery application versions.'
      }
    ]
  }
}

resource remediation 'Microsoft.PolicyInsights/remediations@2021-10-01' = if (createRemediation) {
  name: 'avd-sh-vm-applications'
  properties: {
    policyAssignmentId: policyAssignment.id
    resourceDiscoveryMode: 'ReEvaluateCompliance'
  }
}

@description('Resource ID of the session-host policy assignment.')
output policyAssignmentResourceId string = policyAssignment.id
@description('Resource ID of the remediation task, or an empty string when remediation is not requested.')
output remediationResourceId string = createRemediation ? remediation!.id : ''
