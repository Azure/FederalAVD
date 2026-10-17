targetScope = 'subscription'

@allowed([
  'Create'
  'Update'
])
param workspaceMode string
param manageWorkspace bool
param workspaceName string
param workspaceResourceId string
param workspaceResourceGroupName string
param createWorkspaceResourceGroup bool = true
param workspaceLocation string
param workspaceFriendlyName string
param workspacePublicNetworkAccess 'Disabled' | 'Enabled'
param workspaceFeedPrivateEndpointSubnetResourceId string
param avdPrivateDnsZoneResourceId string
param logAnalyticsWorkspaceResourceId string = ''

param manageGlobalWorkspace bool

@allowed([
  'Create'
  'Update'
])
param globalWorkspaceMode string
param globalWorkspaceName string
param globalWorkspaceResourceId string
param globalWorkspaceResourceGroupName string
param createGlobalWorkspaceResourceGroup bool = true
param globalFeedPrivateEndpointSubnetResourceId string
param globalFeedPrivateDnsZoneResourceId string

param privateEndpointNameConv string
param privateEndpointNICNameConv string
param tags object = {}

var updateWorkspace = manageWorkspace && workspaceMode == 'Update'
var updateGlobalWorkspace = manageGlobalWorkspace && globalWorkspaceMode == 'Update'

resource existingWorkspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' existing = if (updateWorkspace) {
  name: last(split(workspaceResourceId, '/'))
  scope: resourceGroup(split(workspaceResourceId, '/')[2], split(workspaceResourceId, '/')[4])
}

resource existingGlobalWorkspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' existing = if (updateGlobalWorkspace) {
  name: last(split(globalWorkspaceResourceId, '/'))
  scope: resourceGroup(split(globalWorkspaceResourceId, '/')[2], split(globalWorkspaceResourceId, '/')[4])
}

func virtualNetworkResourceIdFromSubnet(subnetResourceId string) string =>
  !empty(subnetResourceId) ? join(take(split(subnetResourceId, '/'), 9), '/') : ''

var workspaceFeedVirtualNetworkResourceId = virtualNetworkResourceIdFromSubnet(workspaceFeedPrivateEndpointSubnetResourceId)
var globalFeedVirtualNetworkResourceId = virtualNetworkResourceIdFromSubnet(globalFeedPrivateEndpointSubnetResourceId)

resource workspaceFeedVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if (!empty(workspaceFeedVirtualNetworkResourceId)) {
  name: last(split(workspaceFeedVirtualNetworkResourceId, '/'))
  scope: resourceGroup(split(workspaceFeedVirtualNetworkResourceId, '/')[2], split(workspaceFeedVirtualNetworkResourceId, '/')[4])
}

resource globalFeedVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if (!empty(globalFeedVirtualNetworkResourceId)) {
  name: last(split(globalFeedVirtualNetworkResourceId, '/'))
  scope: resourceGroup(split(globalFeedVirtualNetworkResourceId, '/')[2], split(globalFeedVirtualNetworkResourceId, '/')[4])
}

var effectiveWorkspaceName = updateWorkspace ? existingWorkspace!.name : workspaceName
var effectiveWorkspaceSubscriptionId = updateWorkspace ? split(workspaceResourceId, '/')[2] : subscription().subscriptionId
var effectiveWorkspaceResourceGroupName = updateWorkspace ? split(workspaceResourceId, '/')[4] : workspaceResourceGroupName
var effectiveWorkspaceLocation = updateWorkspace ? existingWorkspace!.location : workspaceLocation
var effectiveWorkspaceTags = updateWorkspace ? existingWorkspace!.tags ?? {} : tags[?'Microsoft.DesktopVirtualization/Workspaces'] ?? {}
var effectiveWorkspaceFriendlyName = updateWorkspace ? existingWorkspace!.properties.friendlyName ?? '' : workspaceFriendlyName
var effectiveWorkspaceDescription = updateWorkspace ? existingWorkspace!.properties.description ?? '' : ''
var effectiveWorkspaceApplicationGroupReferences = updateWorkspace
  ? existingWorkspace!.properties.applicationGroupReferences ?? []
  : []
var workspaceDiagnosticSettings = !updateWorkspace && !empty(logAnalyticsWorkspaceResourceId)
  ? {
      name: 'WVDInsights'
      workspaceId: logAnalyticsWorkspaceResourceId
    }
  : null
var effectiveWorkspacePublicNetworkAccess 'Disabled' | 'Enabled' = updateWorkspace && empty(
  workspaceFeedPrivateEndpointSubnetResourceId
)
  ? (existingWorkspace!.properties.publicNetworkAccess == 'Disabled' ? 'Disabled' : 'Enabled')
  : workspacePublicNetworkAccess

module workspaceResourceGroup '../../resourceModules/resources/resourceGroups/deploy.bicep' = if (manageWorkspace && !updateWorkspace && createWorkspaceResourceGroup) {
  scope: subscription()
  params: {
    location: workspaceLocation
    name: workspaceResourceGroupName
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module workspace '../../resourceModules/desktopVirtualization/workspaces/deploy.bicep' = if (manageWorkspace) {
  scope: resourceGroup(effectiveWorkspaceSubscriptionId, effectiveWorkspaceResourceGroupName)
  params: {
    name: effectiveWorkspaceName
    location: effectiveWorkspaceLocation
    tags: effectiveWorkspaceTags
    friendlyName: effectiveWorkspaceFriendlyName
    description: effectiveWorkspaceDescription
    publicNetworkAccess: effectiveWorkspacePublicNetworkAccess
    applicationGroupResourceIds: effectiveWorkspaceApplicationGroupReferences
    diagnosticSettings: workspaceDiagnosticSettings
  }
  dependsOn: [workspaceResourceGroup]
}

var workspaceFeedVnetName = !empty(workspaceFeedVirtualNetworkResourceId)
  ? last(split(workspaceFeedVirtualNetworkResourceId, '/'))
  : ''
var workspaceFeedVnetId = length(workspaceFeedVnetName) < 37
  ? workspaceFeedVnetName
  : uniqueString(workspaceFeedVnetName)
var workspaceFeedPrivateEndpointName = replace(
  replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'feed'), 'RESOURCE', effectiveWorkspaceName),
  'VNETID',
  workspaceFeedVnetId
)
var workspaceFeedPrivateEndpointNICName = replace(
  replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'feed'), 'RESOURCE', effectiveWorkspaceName),
  'VNETID',
  workspaceFeedVnetId
)

module workspaceFeedPrivateEndpoint '../../resourceModules/network/privateEndpoints/deploy.bicep' = if (manageWorkspace && !empty(workspaceFeedPrivateEndpointSubnetResourceId)) {
  scope: resourceGroup(effectiveWorkspaceSubscriptionId, effectiveWorkspaceResourceGroupName)
  params: {
    name: workspaceFeedPrivateEndpointName
    location: workspaceFeedVirtualNetwork!.location
    tags: union(
      { 'cm-resource-parent': workspace!.outputs.resourceId },
      tags[?'Microsoft.Network/privateEndpoints'] ?? {}
    )
    subnetResourceId: workspaceFeedPrivateEndpointSubnetResourceId
    privateLinkServiceId: workspace!.outputs.resourceId
    groupId: 'feed'
    customNetworkInterfaceName: workspaceFeedPrivateEndpointNICName
    privateDNSZoneIds: !empty(avdPrivateDnsZoneResourceId) ? [avdPrivateDnsZoneResourceId] : []
  }
}

var effectiveGlobalWorkspaceName = updateGlobalWorkspace ? existingGlobalWorkspace!.name : globalWorkspaceName
var effectiveGlobalWorkspaceSubscriptionId = updateGlobalWorkspace
  ? split(globalWorkspaceResourceId, '/')[2]
  : subscription().subscriptionId
var effectiveGlobalWorkspaceResourceGroupName = updateGlobalWorkspace
  ? split(globalWorkspaceResourceId, '/')[4]
  : globalWorkspaceResourceGroupName
var effectiveGlobalWorkspaceLocation = updateGlobalWorkspace
  ? existingGlobalWorkspace!.location
  : !empty(globalFeedVirtualNetworkResourceId) ? globalFeedVirtualNetwork!.location : workspaceLocation
var effectiveGlobalWorkspaceTags = updateGlobalWorkspace
  ? existingGlobalWorkspace!.tags ?? {}
  : tags[?'Microsoft.DesktopVirtualization/Workspaces'] ?? {}
var effectiveGlobalWorkspaceFriendlyName = updateGlobalWorkspace
  ? existingGlobalWorkspace!.properties.friendlyName ?? ''
  : ''
var effectiveGlobalWorkspaceDescription = updateGlobalWorkspace
  ? existingGlobalWorkspace!.properties.description ?? ''
  : ''
var effectiveGlobalWorkspaceApplicationGroupReferences = updateGlobalWorkspace
  ? existingGlobalWorkspace!.properties.applicationGroupReferences ?? []
  : []
var globalWorkspaceDiagnosticSettings = !updateGlobalWorkspace && !empty(logAnalyticsWorkspaceResourceId)
  ? {
      name: 'WVDInsights'
      workspaceId: logAnalyticsWorkspaceResourceId
    }
  : null

module globalWorkspaceResourceGroup '../../resourceModules/resources/resourceGroups/deploy.bicep' = if (manageGlobalWorkspace && !updateGlobalWorkspace && createGlobalWorkspaceResourceGroup) {
  scope: subscription()
  params: {
    location: effectiveGlobalWorkspaceLocation
    name: globalWorkspaceResourceGroupName
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module globalWorkspace '../../resourceModules/desktopVirtualization/workspaces/deploy.bicep' = if (manageGlobalWorkspace) {
  scope: resourceGroup(effectiveGlobalWorkspaceSubscriptionId, effectiveGlobalWorkspaceResourceGroupName)
  params: {
    name: effectiveGlobalWorkspaceName
    location: effectiveGlobalWorkspaceLocation
    tags: effectiveGlobalWorkspaceTags
    friendlyName: effectiveGlobalWorkspaceFriendlyName
    description: effectiveGlobalWorkspaceDescription
    publicNetworkAccess: 'Enabled'
    applicationGroupResourceIds: effectiveGlobalWorkspaceApplicationGroupReferences
    diagnosticSettings: globalWorkspaceDiagnosticSettings
  }
  dependsOn: [globalWorkspaceResourceGroup]
}

var globalFeedVnetName = !empty(globalFeedVirtualNetworkResourceId)
  ? last(split(globalFeedVirtualNetworkResourceId, '/'))
  : ''
var globalFeedVnetId = length(globalFeedVnetName) < 37
  ? globalFeedVnetName
  : uniqueString(globalFeedVnetName)
var globalFeedPrivateEndpointName = replace(
  replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'global'), 'RESOURCE', effectiveGlobalWorkspaceName),
  'VNETID',
  globalFeedVnetId
)
var globalFeedPrivateEndpointNICName = replace(
  replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'global'), 'RESOURCE', effectiveGlobalWorkspaceName),
  'VNETID',
  globalFeedVnetId
)

module globalFeedPrivateEndpoint '../../resourceModules/network/privateEndpoints/deploy.bicep' = if (manageGlobalWorkspace && !empty(globalFeedPrivateEndpointSubnetResourceId)) {
  scope: resourceGroup(effectiveGlobalWorkspaceSubscriptionId, effectiveGlobalWorkspaceResourceGroupName)
  params: {
    name: globalFeedPrivateEndpointName
    location: globalFeedVirtualNetwork!.location
    tags: union(
      { 'cm-resource-parent': globalWorkspace!.outputs.resourceId },
      tags[?'Microsoft.Network/privateEndpoints'] ?? {}
    )
    subnetResourceId: globalFeedPrivateEndpointSubnetResourceId
    privateLinkServiceId: globalWorkspace!.outputs.resourceId
    groupId: 'global'
    customNetworkInterfaceName: globalFeedPrivateEndpointNICName
    privateDNSZoneIds: !empty(globalFeedPrivateDnsZoneResourceId) ? [globalFeedPrivateDnsZoneResourceId] : []
  }
}

output workspaceResourceId string = manageWorkspace ? workspace!.outputs.resourceId : ''
output workspaceFeedPrivateEndpointResourceId string = manageWorkspace && !empty(workspaceFeedPrivateEndpointSubnetResourceId)
  ? workspaceFeedPrivateEndpoint!.outputs.resourceId
  : ''
output globalWorkspaceResourceId string = manageGlobalWorkspace
  ? globalWorkspace!.outputs.resourceId
  : globalWorkspaceResourceId
output globalFeedPrivateEndpointResourceId string = manageGlobalWorkspace && !empty(globalFeedPrivateEndpointSubnetResourceId)
  ? globalFeedPrivateEndpoint!.outputs.resourceId
  : ''
output controlPlaneResourceGroupName string = manageWorkspace ? effectiveWorkspaceResourceGroupName : ''
output controlPlaneResourceGroupResourceId string = manageWorkspace
  ? '/subscriptions/${effectiveWorkspaceSubscriptionId}/resourceGroups/${effectiveWorkspaceResourceGroupName}'
  : ''
