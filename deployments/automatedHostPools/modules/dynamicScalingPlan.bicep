targetScope = 'subscription'

param resourceGroupName string
param name string
param location string
param tags object = {}
param timeZone string
param exclusionTag string
param hostPoolResourceId string
param scheduleName string
param schedule object

module scalingPlan 'dynamicScalingPlanResource.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: name
    location: location
    tags: tags
    timeZone: timeZone
    exclusionTag: exclusionTag
    hostPoolResourceId: hostPoolResourceId
    scheduleName: scheduleName
    schedule: schedule
  }
}

output resourceId string = scalingPlan.outputs.resourceId
output scheduleResourceId string = scalingPlan.outputs.scheduleResourceId
