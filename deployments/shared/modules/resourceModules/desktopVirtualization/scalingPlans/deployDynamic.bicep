metadata name = 'Dynamic AVD scaling plan'
metadata description = 'Deploys a pooled scaling plan linked to one existing host pool and optional create-delete-power-management schedules. Automated host configuration and autoscale permissions are caller prerequisites.'

import { dynamicScalingScheduleType } from '../../types/scalingTypes.bicep'

@description('Required. Name of the dynamic AVD scaling plan to deploy.')
param name string
@description('Optional. Azure region for the dynamic AVD scaling plan; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the dynamic AVD scaling plan.')
param tags object = {}
@description('Required. Windows time zone ID used to interpret the scaling schedule times.')
param timeZone string
@description('Required. Tag name used to exclude session hosts from autoscale operations.')
param exclusionTag string
@description('Required. Resource ID of the existing pooled host pool linked to this scaling plan.')
param hostPoolResourceId string
@description('Optional. Enable this scaling plan for the referenced host pool.')
param scalingPlanEnabled bool = true
@description('Required. Dynamic pooled schedules defining phase times, capacity thresholds and minimum/maximum host counts; an empty array deploys no schedules.')
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

@description('Resource ID of the dynamic AVD scaling plan.')
output resourceId string = scalingPlan.id
@description('Azure resource name of the dynamic AVD scaling plan.')
output name string = scalingPlan.name
@description('Array of deployed pooled schedule resource IDs in input order; empty when no schedules are supplied.')
output scheduleResourceIds string[] = !empty(schedules) ? pooledSchedules!.outputs.scheduleResourceIds : []
