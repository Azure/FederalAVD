targetScope = 'subscription'

param appGroupSecurityGroups array
param avdPrivateDnsZoneResourceId string
param avdPrivateLinkPrivateRoutes string
param deploymentSuffix string
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
param controlPlaneRegion string
param globalFeedRegion string
param virtualMachinesRegion string
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
param storageResourceGroup string
param tags object
param virtualMachinesTimeZone string
param workspaceFeedPrivateEndpointSubnetResourceId string
param workspaceFriendlyName string
param workspaceName string
param workspacePublicNetworkAccess string

var globalFeedVnetName = !empty(globalFeedPrivateEndpointSubnetResourceId)
  ? split(globalFeedPrivateEndpointSubnetResourceId, '/')[8]
  : ''
var globalFeedVnetId = length(globalFeedVnetName) < 37 ? globalFeedVnetName : uniqueString(globalFeedVnetName)
var workspaceFeedVnetName = !empty(workspaceFeedPrivateEndpointSubnetResourceId)
  ? split(workspaceFeedPrivateEndpointSubnetResourceId, '/')[8]
  : ''
var workspaceFeedVnetId = length(workspaceFeedVnetName) < 37
  ? workspaceFeedVnetName
  : uniqueString(workspaceFeedVnetName)
var hostPoolVnetName = !empty(hostPoolPrivateEndpointSubnetResourceId)
  ? split(hostPoolPrivateEndpointSubnetResourceId, '/')[8]
  : ''
var hostPoolVnetId = length(hostPoolVnetName) < 37 ? hostPoolVnetName : uniqueString(hostPoolVnetName)

var feedPrivateEndpointName = replace(
  replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'feed'), 'RESOURCE', workspaceName),
  'VNETID',
  workspaceFeedVnetId
)
var feedPrivateEndpointNICName = replace(
  replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'feed'), 'RESOURCE', workspaceName),
  'VNETID',
  workspaceFeedVnetId
)
var globalFeedPrivateEndpointName = replace(
  replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'global'), 'RESOURCE', workspaceName),
  'VNETID',
  globalFeedVnetId
)

var globalFeedPrivateEndpointNICName = replace(
  replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'global'), 'RESOURCE', workspaceName),
  'VNETID',
  globalFeedVnetId
)

var hostPoolPrivateEndpointName = replace(
  replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'connection'), 'RESOURCE', hostPoolName),
  'VNETID',
  hostPoolVnetId
)
var hostPoolPrivateEndpointNICName = replace(
  replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'connection'), 'RESOURCE', hostPoolName),
  'VNETID',
  hostPoolVnetId
)

module hostPoolPrivateEndpointVnet '../common/vnetLocation.bicep' = if (avdPrivateLinkPrivateRoutes != 'None' && !empty(hostPoolPrivateEndpointSubnetResourceId)) {
  name: 'HostPoolPrivateEndpointVnet-${deploymentSuffix}'
  params: {
    privateEndpointSubnetResourceId: hostPoolPrivateEndpointSubnetResourceId
  }
}

module workspaceFeedPrivateEndpointVnet '../common/vnetLocation.bicep' = if ((avdPrivateLinkPrivateRoutes == 'All' || avdPrivateLinkPrivateRoutes == 'FeedAndHostPool') && !empty(workspaceFeedPrivateEndpointSubnetResourceId)) {
  name: 'WorkspaceFeedPrivateEndpointVnet-${deploymentSuffix}'
  params: {
    privateEndpointSubnetResourceId: workspaceFeedPrivateEndpointSubnetResourceId
  }
}

module globalFeedPrivateEndpointVnet '../common/vnetLocation.bicep' = if (avdPrivateLinkPrivateRoutes == 'All' && !empty(globalFeedPrivateEndpointSubnetResourceId)) {
  name: 'GlobalFeedPrivateEndpointVnet-${deploymentSuffix}'
  params: {
    privateEndpointSubnetResourceId: globalFeedPrivateEndpointSubnetResourceId
  }
}

module hostPool 'modules/hostPool.bicep' = {
  name: 'HostPool-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    hostPoolRDPProperties: hostPoolRDPProperties
    hostPoolName: hostPoolName
    hostPoolPrivateDnsZoneResourceId: avdPrivateDnsZoneResourceId
    hostPoolPublicNetworkAccess: hostPoolPublicNetworkAccess
    hostPoolType: hostPoolType
    hostPoolValidationEnvironment: hostPoolValidationEnvironment
    location: controlPlaneRegion
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    hostPoolMaxSessionLimit: hostPoolMaxSessionLimit
    enableMonitoring: enableMonitoring
    privateEndpoint: avdPrivateLinkPrivateRoutes != 'None' ? true : false
    privateEndpointName: hostPoolPrivateEndpointName
    privateEndpointNICName: hostPoolPrivateEndpointNICName
    privateEndpointSubnetResourceId: hostPoolPrivateEndpointSubnetResourceId
    startVmOnConnect: startVmOnConnect
    storageResourceGroup: storageResourceGroup
    tags: tags
    deploymentSuffix: deploymentSuffix
    virtualMachineTemplate: hostPoolVmTemplate
  }
}

module applicationGroup 'modules/applicationGroup.bicep' = {
  name: 'ApplicationGroup-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    deploymentSuffix: deploymentSuffix
    deploymentUserAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    desktopApplicationGroupName: desktopApplicationGroupName
    desktopFriendlyName: desktopFriendlyName
    hostPoolResourceId: hostPool.outputs.resourceId
    location: controlPlaneRegion
    virtualMachinesRegion: virtualMachinesRegion
    deploymentVirtualMachineName: deploymentVirtualMachineName
    resourceGroupDeployment: resourceGroupDeployment
    appGroupSecurityGroups: appGroupSecurityGroups
    tags: tags
  }
}

resource existingFeedWorkspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' existing = if (!empty(existingFeedWorkspaceResourceId)) {
  name: last(split(existingFeedWorkspaceResourceId, '/'))
  scope: resourceGroup(split(existingFeedWorkspaceResourceId, '/')[2], split(existingFeedWorkspaceResourceId, '/')[4])
}

module feedWorkspace 'modules/workspace.bicep' = {
  name: 'WorkspaceFeed-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    applicationGroupResourceId: applicationGroup.outputs.ApplicationGroupResourceId
    enableMonitoring: enableMonitoring
    existingWorkspaceProperties: !empty(existingFeedWorkspaceResourceId)
      ? {
          applicationGroupReferences: existingFeedWorkspace!.properties.applicationGroupReferences
          friendlyName: existingFeedWorkspace!.properties.friendlyName
          location: existingFeedWorkspace!.location
          name: existingFeedWorkspace.name
          publicNetworkAccess: existingFeedWorkspace!.properties.publicNetworkAccess
          resourceId: existingFeedWorkspaceResourceId
          tags: existingFeedWorkspace!.tags
        }
      : {}
    friendlyName: workspaceFriendlyName
    groupIds: ['feed']
    location: controlPlaneRegion
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    privateDnsZoneResourceId: avdPrivateDnsZoneResourceId
    privateEndpoint: avdPrivateLinkPrivateRoutes != 'None' || avdPrivateLinkPrivateRoutes != 'HostPool' ? true : false
    privateEndpointName: feedPrivateEndpointName
    privateEndpointNICName: feedPrivateEndpointNICName
    privateEndpointSubnetResourceId: workspaceFeedPrivateEndpointSubnetResourceId
    publicNetworkAccess: workspacePublicNetworkAccess
    tags: tags
    deploymentSuffix: deploymentSuffix
    workspaceName: workspaceName
  }
}

module scalingPlan 'modules/scalingPlan.bicep' = if (deployScalingPlan) {
  name: 'ScalingPlan-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    diagnosticWorkspaceId: logAnalyticsWorkspaceResourceId
    exclusionTag: scalingPlanExclusionTag
    hostPoolResourceId: hostPool.outputs.resourceId
    hostPoolType: split(hostPoolType, ' ')[0]
    location: virtualMachinesRegion
    name: scalingPlanName
    schedules: scalingPlanSchedules
    tags: tags
    timeZone: virtualMachinesTimeZone
  }
}

module globalWorkspace 'modules/workspace.bicep' = if (empty(existingGlobalWorkspaceResourceId) && avdPrivateLinkPrivateRoutes == 'All' && !empty(globalFeedPrivateDnsZoneResourceId) && !empty(globalFeedPrivateEndpointSubnetResourceId)) {
  name: 'Global-Feed-Workspace-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupGlobalFeed)
  params: {
    applicationGroupResourceId: ''
    existingWorkspaceProperties: {}
    enableMonitoring: enableMonitoring
    friendlyName: ''
    groupIds: ['global']
    location: globalFeedRegion
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    privateDnsZoneResourceId: globalFeedPrivateDnsZoneResourceId
    privateEndpoint: true
    privateEndpointName: globalFeedPrivateEndpointName
    privateEndpointNICName: globalFeedPrivateEndpointNICName
    privateEndpointSubnetResourceId: globalFeedPrivateEndpointSubnetResourceId
    publicNetworkAccess: 'Enabled'
    tags: tags
    deploymentSuffix: deploymentSuffix
    workspaceName: globalWorkspaceName
  }
  dependsOn: [
    feedWorkspace
  ]
}

output hostPoolResourceId string = hostPool.outputs.resourceId
output workspaceResourceId string = empty(existingFeedWorkspaceResourceId) ? feedWorkspace.outputs.resourceId : existingFeedWorkspaceResourceId
