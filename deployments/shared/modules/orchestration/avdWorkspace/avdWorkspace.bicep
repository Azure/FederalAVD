targetScope = 'subscription'

@allowed([
  'Adopt'
  'Create'
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
  'Adopt'
  'Create'
])
param globalWorkspaceMode string
param globalWorkspaceName string
param globalWorkspaceResourceId string
param globalWorkspaceResourceGroupName string
param createGlobalWorkspaceResourceGroup bool = true
param globalWorkspacePublicNetworkAccess 'Disabled' | 'Enabled'
param globalFeedPrivateEndpointSubnetResourceId string
param globalFeedPrivateDnsZoneResourceId string

param privateEndpointNameConv string
param privateEndpointNICNameConv string
param tags object = {}

var adoptWorkspace = manageWorkspace && workspaceMode == 'Adopt'
var adoptGlobalWorkspace = manageGlobalWorkspace && globalWorkspaceMode == 'Adopt'

resource existingWorkspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' existing = if (adoptWorkspace) {
  name: last(split(workspaceResourceId, '/'))
  scope: resourceGroup(split(workspaceResourceId, '/')[2], split(workspaceResourceId, '/')[4])
}

resource existingGlobalWorkspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' existing = if (adoptGlobalWorkspace) {
  name: last(split(globalWorkspaceResourceId, '/'))
  scope: resourceGroup(split(globalWorkspaceResourceId, '/')[2], split(globalWorkspaceResourceId, '/')[4])
}

func virtualNetworkResourceIdFromSubnet(subnetResourceId string) string =>
  !empty(subnetResourceId) ? join(take(split(subnetResourceId, '/'), 9), '/') : ''

var workspaceFeedVirtualNetworkResourceId = virtualNetworkResourceIdFromSubnet(workspaceFeedPrivateEndpointSubnetResourceId)
var globalFeedVirtualNetworkResourceId = virtualNetworkResourceIdFromSubnet(globalFeedPrivateEndpointSubnetResourceId)
var privateEndpointVirtualNetworkResourceIds = union(
  !empty(workspaceFeedVirtualNetworkResourceId) ? [workspaceFeedVirtualNetworkResourceId] : [],
  !empty(globalFeedVirtualNetworkResourceId) ? [globalFeedVirtualNetworkResourceId] : []
)

resource privateEndpointVirtualNetworks 'Microsoft.Network/virtualNetworks@2024-05-01' existing = [
  for virtualNetworkResourceId in privateEndpointVirtualNetworkResourceIds: {
    name: last(split(virtualNetworkResourceId, '/'))
    scope: resourceGroup(split(virtualNetworkResourceId, '/')[2], split(virtualNetworkResourceId, '/')[4])
  }
]

var effectiveWorkspaceName = adoptWorkspace ? existingWorkspace!.name : workspaceName
var effectiveWorkspaceSubscriptionId = adoptWorkspace ? split(workspaceResourceId, '/')[2] : subscription().subscriptionId
var effectiveWorkspaceResourceGroupName = adoptWorkspace ? split(workspaceResourceId, '/')[4] : workspaceResourceGroupName
var effectiveWorkspaceLocation = adoptWorkspace ? existingWorkspace!.location : workspaceLocation
var effectiveWorkspaceTags = adoptWorkspace ? existingWorkspace!.tags ?? {} : tags[?'Microsoft.DesktopVirtualization/Workspaces'] ?? {}
var effectiveWorkspaceFriendlyName = adoptWorkspace ? existingWorkspace!.properties.friendlyName ?? '' : workspaceFriendlyName
var effectiveWorkspaceDescription = adoptWorkspace ? existingWorkspace!.properties.description ?? '' : ''
var effectiveWorkspaceApplicationGroupReferences = adoptWorkspace
  ? existingWorkspace!.properties.applicationGroupReferences ?? []
  : []
var workspaceDiagnosticSettings = !adoptWorkspace && !empty(logAnalyticsWorkspaceResourceId)
  ? {
      name: 'WVDInsights'
      workspaceId: logAnalyticsWorkspaceResourceId
    }
  : null
var effectiveWorkspacePublicNetworkAccess 'Disabled' | 'Enabled' = adoptWorkspace && empty(
  workspaceFeedPrivateEndpointSubnetResourceId
)
  ? (existingWorkspace!.properties.publicNetworkAccess == 'Disabled' ? 'Disabled' : 'Enabled')
  : workspacePublicNetworkAccess

module workspaceResourceGroup '../../resourceModules/resources/resourceGroups/deploy.bicep' = if (manageWorkspace && !adoptWorkspace && createWorkspaceResourceGroup) {
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
    location: privateEndpointVirtualNetworks[indexOf(privateEndpointVirtualNetworkResourceIds, workspaceFeedVirtualNetworkResourceId)].location
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

var effectiveGlobalWorkspaceName = adoptGlobalWorkspace ? existingGlobalWorkspace!.name : globalWorkspaceName
var effectiveGlobalWorkspaceSubscriptionId = adoptGlobalWorkspace
  ? split(globalWorkspaceResourceId, '/')[2]
  : subscription().subscriptionId
var effectiveGlobalWorkspaceResourceGroupName = adoptGlobalWorkspace
  ? split(globalWorkspaceResourceId, '/')[4]
  : globalWorkspaceResourceGroupName
var effectiveGlobalWorkspaceLocation = adoptGlobalWorkspace
  ? existingGlobalWorkspace!.location
  : privateEndpointVirtualNetworks[indexOf(privateEndpointVirtualNetworkResourceIds, globalFeedVirtualNetworkResourceId)].location
var effectiveGlobalWorkspaceTags = adoptGlobalWorkspace
  ? existingGlobalWorkspace!.tags ?? {}
  : tags[?'Microsoft.DesktopVirtualization/Workspaces'] ?? {}
var effectiveGlobalWorkspaceFriendlyName = adoptGlobalWorkspace
  ? existingGlobalWorkspace!.properties.friendlyName ?? ''
  : ''
var effectiveGlobalWorkspaceDescription = adoptGlobalWorkspace
  ? existingGlobalWorkspace!.properties.description ?? ''
  : ''
var effectiveGlobalWorkspaceApplicationGroupReferences = adoptGlobalWorkspace
  ? existingGlobalWorkspace!.properties.applicationGroupReferences ?? []
  : []
var globalWorkspaceDiagnosticSettings = !adoptGlobalWorkspace && !empty(logAnalyticsWorkspaceResourceId)
  ? {
      name: 'WVDInsights'
      workspaceId: logAnalyticsWorkspaceResourceId
    }
  : null

module globalWorkspaceResourceGroup '../../resourceModules/resources/resourceGroups/deploy.bicep' = if (manageGlobalWorkspace && !adoptGlobalWorkspace && createGlobalWorkspaceResourceGroup) {
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
    publicNetworkAccess: globalWorkspacePublicNetworkAccess
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
    location: privateEndpointVirtualNetworks[indexOf(privateEndpointVirtualNetworkResourceIds, globalFeedVirtualNetworkResourceId)].location
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
