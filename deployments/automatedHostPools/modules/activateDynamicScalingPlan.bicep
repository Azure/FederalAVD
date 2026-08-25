targetScope = 'subscription'

@description('Required. Resource group containing the AVD control-plane resources.')
param resourceGroupName string

@description('Required. Existing scaling-plan name to activate.')
param scalingPlanName string

@description('Required. Azure region for the scaling plan.')
param location string

@description('Optional. Tags keyed by Azure resource type.')
param tags object = {}

@description('Optional. Scaling-plan time zone.')
param scalingPlanTimeZone string = 'Eastern Standard Time'

@description('Optional. Tag that excludes session hosts from scaling operations.')
param scalingPlanExclusionTag string = 'ScalingPlanExclusion'

@description('Required. Host pool resource ID associated with this scaling plan.')
param hostPoolResourceId string

module activateScalingPlan '../../shared/modules/resourceModules/desktopVirtualization/scalingPlans/deployAutomated.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: scalingPlanName
    location: location
    tags: tags
    timeZone: scalingPlanTimeZone
    exclusionTag: scalingPlanExclusionTag
    hostPoolResourceId: hostPoolResourceId
    scalingPlanEnabled: true
    schedules: []
  }
}

output resourceId string = activateScalingPlan.outputs.resourceId
