targetScope = 'subscription'

param avdServicePrincipalObjectId string
param deployDynamicScalingPlan bool
param startVMOnConnect bool

var powerOnContributorRoleId = '489581de-a3bd-480d-9518-53dea7416b33'
var powerOnOffContributorRoleId = '40c5ff49-9181-41f8-ae61-143b0e78555e'
var virtualMachineContributorRoleId = 'a959dbd1-f747-45e3-8ba6-dd80f235f97c'

resource powerOnContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!deployDynamicScalingPlan && startVMOnConnect) {
  name: guid(avdServicePrincipalObjectId, powerOnContributorRoleId, subscription().id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', powerOnContributorRoleId)
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

resource powerOnOffContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployDynamicScalingPlan) {
  name: guid(avdServicePrincipalObjectId, powerOnOffContributorRoleId, subscription().id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', powerOnOffContributorRoleId)
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

resource virtualMachineContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployDynamicScalingPlan) {
  name: guid(avdServicePrincipalObjectId, virtualMachineContributorRoleId, subscription().id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineContributorRoleId)
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}