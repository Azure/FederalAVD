targetScope = 'subscription'

param resourceGroupName string
param virtualMachineName string
param location string
param deploymentSuffix string

module policyPropagationWait '../../shared/modules/resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  name: 'Policy-Propagation-Wait-Command-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    virtualMachineName: virtualMachineName
    name: 'Policy-Propagation-Wait-${deploymentSuffix}'
    location: location
    script: loadTextContent('../scripts/Wait-PolicyPropagation.ps1')
    timeoutInSeconds: 600
    treatFailureAsDeploymentFailure: true
  }
}

output resourceId string = policyPropagationWait.outputs.resourceId
