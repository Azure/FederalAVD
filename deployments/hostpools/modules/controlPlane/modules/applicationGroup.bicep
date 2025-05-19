param deploymentUserAssignedIdentityClientId string
param desktopApplicationGroupName string
param desktopFriendlyName string
param hostPoolResourceId string
param location string
param locationVirtualMachines string
param logAnalyticsWorkspaceResourceId string
param deploymentVirtualMachineName string
param resourceGroupDeployment string
param appGroupSecurityGroups array
param tags object
param timeStamp string

var applicationGroupLogs = [
  {
    categoryGroup: 'allLogs'
    enabled: true
  }
]

var desktopVirtualizationUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')

resource applicationGroup 'Microsoft.DesktopVirtualization/applicationGroups@2021-03-09-preview' = {
  name: desktopApplicationGroupName
  location: location
  tags: union({
    'cm-resource-parent': hostPoolResourceId
  }, tags[?'Microsoft.DesktopVirtualization/applicationGroups'] ?? {})
  properties: {
    hostPoolArmPath: hostPoolResourceId
    applicationGroupType: 'Desktop'
  }
}

resource applicationGroup_DiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if(!empty(logAnalyticsWorkspaceResourceId)) {
  name: 'diag-${desktopApplicationGroupName}'
  scope: applicationGroup
  properties: {
    logs: applicationGroupLogs
    workspaceId: logAnalyticsWorkspaceResourceId
  }
}

// Adds a friendly name to the SessionDesktop application for the desktop application group
module updateDesktopFriendlyName 'updateDesktopFriendlyName.bicep' = if (!empty(desktopFriendlyName)) {
  name: 'DesktopFriendlyName_${timeStamp}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    applicationGroupResourceId: applicationGroup.id
    desktopFriendlyName: desktopFriendlyName
    userAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    location: locationVirtualMachines
    timeStamp: timeStamp
    virtualMachineName: deploymentVirtualMachineName
  }
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for i in range(0, length(appGroupSecurityGroups)): {
  scope: applicationGroup
  name: guid(applicationGroup.id, appGroupSecurityGroups[i], desktopVirtualizationUserRoleId)
  properties: {
    roleDefinitionId: desktopVirtualizationUserRoleId
    principalId: appGroupSecurityGroups[i]
  }
}]

output Name string = applicationGroup.name
output ApplicationGroupResourceId string = applicationGroup.id
