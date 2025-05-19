targetScope = 'subscription'

param appGroupSecurityGroups array
param avdPrivateDnsZoneResourceId string
param avdPrivateLinkPrivateRoutes string
param deploymentUserAssignedIdentityClientId string
param deploymentVirtualMachineName string
param deployScalingPlan bool
param desktopApplicationGroupName string
param desktopFriendlyName string
param enableMonitoring bool
param existingGlobalWorkspaceResourceId string
param existingFeedWorkspaceResourceId string
param globalFeedPrivateDnsZoneResourceId string
param globalFeedPrivateEndpointSubnetResourceId string
param globalWorkspaceName string
param hostPoolMaxSessionLimit int
param hostPoolName string
param hostPoolPrivateEndpointSubnetResourceId string
param hostPoolPublicNetworkAccess string
param hostPoolRDPProperties string
param hostPoolType string
param hostPoolValidationEnvironment bool
param hostPoolVmTemplate object
param locationControlPlane string
param locationGlobalFeed string
param locationVirtualMachines string
param logAnalyticsWorkspaceResourceId string
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param resourceGroupControlPlane string
param resourceGroupDeployment string
param resourceGroupGlobalFeed string
param scalingPlanExclusionTag string
param scalingPlanName string
param scalingPlanSchedules array
param startVmOnConnect bool
param tags object
param timeStamp string
param virtualMachinesTimeZone string
param workspaceFeedPrivateEndpointSubnetResourceId string
param workspaceFriendlyName string
param workspaceName string
param workspacePublicNetworkAccess string

var feedPrivateEndpointName = (avdPrivateLinkPrivateRoutes != 'None' || avdPrivateLinkPrivateRoutes != 'HostPool') && !empty(workspaceFeedPrivateEndpointSubnetResourceId)
  ? replace(
      replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'feed'), 'RESOURCE', workspaceName),
      'VNETID',
      '${split(workspaceFeedPrivateEndpointSubnetResourceId, '/')[8]}'
    )
  : 'feedPrivateEndpointName'
var feedPrivateEndpointNICName = (avdPrivateLinkPrivateRoutes != 'None' || avdPrivateLinkPrivateRoutes != 'HostPool') && !empty(workspaceFeedPrivateEndpointSubnetResourceId)
  ? replace(
      replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'feed'), 'RESOURCE', workspaceName),
      'VNETID',
      '${split(workspaceFeedPrivateEndpointSubnetResourceId, '/')[8]}'
    )
  : 'feedPrivateEndpointName'
var globalFeedPrivateEndpointName = avdPrivateLinkPrivateRoutes == 'All' && !empty(globalFeedPrivateEndpointSubnetResourceId)
  ? replace(
      replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'global'), 'RESOURCE', workspaceName),
      'VNETID',
      '${split(globalFeedPrivateEndpointSubnetResourceId, '/')[8]}'
    )
  : 'globalFeedPrivateEndpointName'
var globalFeedPrivateEndpointNICName = avdPrivateLinkPrivateRoutes == 'All' && !empty(globalFeedPrivateEndpointSubnetResourceId)
  ? replace(
      replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'global'), 'RESOURCE', workspaceName),
      'VNETID',
      '${split(globalFeedPrivateEndpointSubnetResourceId, '/')[8]}'
    )
  : 'globalFeedPrivateEndpointName'
var hostPoolPrivateEndpointName = avdPrivateLinkPrivateRoutes != 'None' && !empty(hostPoolPrivateEndpointSubnetResourceId)
  ? replace(
      replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'connection'), 'RESOURCE', hostPoolName),
      'VNETID',
      '${split(hostPoolPrivateEndpointSubnetResourceId, '/')[8]}'
    )
  : 'hostPoolPrivateEndpointName'
var hostPoolPrivateEndpointNICName = avdPrivateLinkPrivateRoutes != 'None' && !empty(hostPoolPrivateEndpointSubnetResourceId)
  ? replace(
      replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'connection'), 'RESOURCE', hostPoolName),
      'VNETID',
      '${split(hostPoolPrivateEndpointSubnetResourceId, '/')[8]}'
    )
  : 'hostPoolPrivateEndpointName'

module hostPoolPrivateEndpointVnet '../common/vnetLocation.bicep' = if (avdPrivateLinkPrivateRoutes != 'None' && !empty(hostPoolPrivateEndpointSubnetResourceId)) {
  name: 'HostPoolPrivateEndpointVnet_${timeStamp}'
  params: {
    privateEndpointSubnetResourceId: hostPoolPrivateEndpointSubnetResourceId
  }
}

module workspaceFeedPrivateEndpointVnet '../common/vnetLocation.bicep' = if ((avdPrivateLinkPrivateRoutes == 'All' || avdPrivateLinkPrivateRoutes == 'FeedAndHostPool') && !empty(workspaceFeedPrivateEndpointSubnetResourceId)) {
  name: 'WorkspaceFeedPrivateEndpointVnet_${timeStamp}'
  params: {
    privateEndpointSubnetResourceId: workspaceFeedPrivateEndpointSubnetResourceId
  }
}

module globalFeedPrivateEndpointVnet '../common/vnetLocation.bicep' = if (avdPrivateLinkPrivateRoutes == 'All' && !empty(globalFeedPrivateEndpointSubnetResourceId)) {
  name: 'GlobalFeedPrivateEndpointVnet_${timeStamp}'
  params: {
    privateEndpointSubnetResourceId: globalFeedPrivateEndpointSubnetResourceId
  }
}

module hostPool 'modules/hostPool.bicep' = {
  name: 'HostPool_${timeStamp}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    hostPoolRDPProperties: hostPoolRDPProperties
    hostPoolName: hostPoolName
    hostPoolPrivateDnsZoneResourceId: avdPrivateDnsZoneResourceId
    hostPoolPublicNetworkAccess: hostPoolPublicNetworkAccess
    hostPoolType: hostPoolType
    hostPoolValidationEnvironment: hostPoolValidationEnvironment
    location: locationControlPlane
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    hostPoolMaxSessionLimit: hostPoolMaxSessionLimit
    enableMonitoring: enableMonitoring
    privateEndpoint: avdPrivateLinkPrivateRoutes != 'None' ? true : false
    privateEndpointLocation: avdPrivateLinkPrivateRoutes != 'None' && !empty(hostPoolPrivateEndpointSubnetResourceId)
      ? hostPoolPrivateEndpointVnet.outputs.location
      : ''
    privateEndpointName: hostPoolPrivateEndpointName
    privateEndpointNICName: hostPoolPrivateEndpointNICName
    privateEndpointSubnetResourceId: hostPoolPrivateEndpointSubnetResourceId
    startVmOnConnect: startVmOnConnect
    tags: tags 
    timeStamp: timeStamp
    virtualMachineTemplate: hostPoolVmTemplate
  }
}

module applicationGroup 'modules/applicationGroup.bicep' = {
  name: 'ApplicationGroup_${timeStamp}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    deploymentUserAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    desktopApplicationGroupName: desktopApplicationGroupName
    desktopFriendlyName: desktopFriendlyName
    hostPoolResourceId: hostPool.outputs.resourceId
    location: locationControlPlane
    locationVirtualMachines: locationVirtualMachines
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    deploymentVirtualMachineName: deploymentVirtualMachineName
    resourceGroupDeployment: resourceGroupDeployment
    appGroupSecurityGroups: appGroupSecurityGroups
    tags: tags
    timeStamp: timeStamp
  }
}

resource existingFeedWorkspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' existing = if (!empty(existingFeedWorkspaceResourceId)) {
  name: last(split(existingFeedWorkspaceResourceId, '/'))
  scope: resourceGroup(split(existingFeedWorkspaceResourceId, '/')[2], split(existingFeedWorkspaceResourceId, '/')[4])
}

module feedWorkspace 'modules/workspace.bicep' = {
  name: 'WorkspaceFeed_${timeStamp}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    applicationGroupResourceId: applicationGroup.outputs.ApplicationGroupResourceId
    enableMonitoring: enableMonitoring
    existingWorkspaceProperties: !empty(existingFeedWorkspaceResourceId)
      ? {
          applicationGroupReferences: existingFeedWorkspace.properties.applicationGroupReferences
          friendlyName: existingFeedWorkspace.properties.friendlyName
          location: existingFeedWorkspace.location
          name: existingFeedWorkspace.name
          publicNetworkAccess: existingFeedWorkspace.properties.publicNetworkAccess
          resourceId: existingFeedWorkspaceResourceId
          tags: existingFeedWorkspace.tags
        }
      : {}
    friendlyName: workspaceFriendlyName
    groupIds: ['feed']
    location: locationControlPlane
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    privateDnsZoneResourceId: avdPrivateDnsZoneResourceId
    privateEndpoint: avdPrivateLinkPrivateRoutes != 'None' || avdPrivateLinkPrivateRoutes != 'HostPool' ? true : false
    privateEndpointLocation: !empty(workspaceFeedPrivateEndpointSubnetResourceId)
      ? workspaceFeedPrivateEndpointVnet.outputs.location
      : ''
    privateEndpointName: feedPrivateEndpointName
    privateEndpointNICName: feedPrivateEndpointNICName
    privateEndpointSubnetResourceId: workspaceFeedPrivateEndpointSubnetResourceId
    publicNetworkAccess: workspacePublicNetworkAccess
    tags: tags
    timeStamp: timeStamp
    workspaceName: workspaceName
  }
}

module scalingPlan 'modules/scalingPlan.bicep' = if (deployScalingPlan && contains(hostPoolType, 'Pooled')) {
  name: 'ScalingPlan_${timeStamp}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    diagnosticWorkspaceId: logAnalyticsWorkspaceResourceId
    exclusionTag: scalingPlanExclusionTag
    hostPoolResourceId: hostPool.outputs.resourceId
    hostPoolType: split(hostPoolType, ' ')[0]
    location: locationVirtualMachines
    name: scalingPlanName
    schedules: scalingPlanSchedules
    tags: tags
    timeZone: virtualMachinesTimeZone
  }
}

module globalWorkspace 'modules/workspace.bicep' = if (empty(existingGlobalWorkspaceResourceId) && avdPrivateLinkPrivateRoutes == 'All' && !empty(globalFeedPrivateDnsZoneResourceId) && !empty(globalFeedPrivateEndpointSubnetResourceId)) {
  name: 'Global_Feed_Workspace_${timeStamp}'
  scope: resourceGroup(resourceGroupGlobalFeed)
  params: {
    applicationGroupResourceId: ''
    existingWorkspaceProperties: {}
    enableMonitoring: enableMonitoring
    friendlyName: ''
    groupIds: ['global']
    location: locationGlobalFeed
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    privateDnsZoneResourceId: globalFeedPrivateDnsZoneResourceId
    privateEndpoint: true
    privateEndpointLocation: !empty(globalFeedPrivateEndpointSubnetResourceId)
      ? globalFeedPrivateEndpointVnet.outputs.location
      : ''
    privateEndpointName: globalFeedPrivateEndpointName
    privateEndpointNICName: globalFeedPrivateEndpointNICName
    privateEndpointSubnetResourceId: globalFeedPrivateEndpointSubnetResourceId
    publicNetworkAccess: 'Enabled'
    tags: tags
    timeStamp: timeStamp
    workspaceName: globalWorkspaceName
  }
  dependsOn: [
    feedWorkspace
  ]
}

output hostPoolResourceId string = hostPool.outputs.resourceId
