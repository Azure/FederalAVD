targetScope = 'subscription'

param resourceGroupName string
param name string
param location string
param tags object = {}
param timeZone string
param exclusionTag string
param hostPoolResourceId string
param schedules array

module scalingPlan '../../shared/modules/desktopVirtualization/scalingPlans/deployAutomated.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: name
    location: location
    tags: tags
    timeZone: timeZone
    exclusionTag: exclusionTag
    hostPoolResourceId: hostPoolResourceId
    schedules: schedules
  }
}

output resourceId string = scalingPlan.outputs.resourceId
output scheduleResourceIds array = scalingPlan.outputs.scheduleResourceIds
