targetScope = 'resourceGroup'

import { vmApplicationAssignmentType } from '../vmApplicationTypes.bicep'

param location string
param policyIdentityResourceId string
param policyDefinitionResourceId string
param vmApplications vmApplicationAssignmentType[]
param createRemediation bool = false
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

output policyAssignmentResourceId string = policyAssignment.id
output remediationResourceId string = createRemediation ? remediation!.id : ''
