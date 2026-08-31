import { dynamicScalingScheduleType } from '../../types/scalingTypes.bicep'

param name string
param location string = resourceGroup().location
param tags object = {}
param timeZone string
param exclusionTag string
param hostPoolResourceId string
param scalingPlanEnabled bool = true
param schedules dynamicScalingScheduleType[]

resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2025-11-01-preview' = {
  name: name
  location: location
  tags: tags
  properties: {
    timeZone: timeZone
    exclusionTag: exclusionTag
    hostPoolType: 'Pooled'
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPoolResourceId
        scalingPlanEnabled: scalingPlanEnabled
      }
    ]
  }
}

module pooledSchedules 'pooledSchedules/deploy.bicep' = if (!empty(schedules)) {
  name: 'PooledSchedules-${uniqueString(name, resourceGroup().id)}'
  params: {
    scalingPlanName: scalingPlan.name
    schedules: schedules
  }
}

output resourceId string = scalingPlan.id
output name string = scalingPlan.name
output scheduleResourceIds string[] = !empty(schedules) ? pooledSchedules!.outputs.scheduleResourceIds : []
