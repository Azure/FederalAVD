targetScope = 'subscription'

param resourceGroupName string
param virtualMachineName string
param location string
var waitTimeoutInSeconds = 300

module policyPropagationWait '../../shared/modules/resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    virtualMachineName: virtualMachineName
    name: 'Policy-Propagation-Wait'
    location: location
    script: loadTextContent('../scripts/Wait-PolicyPropagation.ps1')
    parameters: [
      {
        name: 'WaitSeconds'
        value: string(waitTimeoutInSeconds)
      }
    ]
    timeoutInSeconds: waitTimeoutInSeconds + 30
    treatFailureAsDeploymentFailure: true
  }
}

output resourceId string = policyPropagationWait.outputs.resourceId
