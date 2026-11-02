metadata name = 'AVD workspace orchestration'
metadata description = 'Creates or updates AVD feed and global workspaces across resource groups with optional private endpoints and diagnostics.'

// Update mode preserves existing workspace properties unless this module explicitly overrides them.
// Diagnostic settings are supplied only when creating a workspace; updates leave existing settings alone.

targetScope = 'subscription'

@allowed([
  'Create'
  'Update'
])
@description('Required. Create deploys a new feed workspace; Update reads the existing workspace identified by workspaceResourceId.')
param workspaceMode string
@description('Required. Whether this module manages the feed workspace and its requested private endpoint.')
param manageWorkspace bool
@description('Required. Name of the feed workspace to create; update mode derives it from workspaceResourceId.')
param workspaceName string
@description('Required. Existing feed workspace resource ID required for Update mode; creation mode uses workspaceName instead.')
param workspaceResourceId string
@description('Required. Target feed workspace resource group name in this subscription for Create mode.')
param workspaceResourceGroupName string
@description('Optional. Whether to create the feed workspace resource group in Create mode; otherwise it must exist.')
param createWorkspaceResourceGroup bool = true
@description('Required. Azure region for new feed workspace resources and the fallback new global workspace location.')
param workspaceLocation string
@description('Required. Friendly name for a new feed workspace; update mode preserves the existing value.')
param workspaceFriendlyName string
@description('Required. Requested feed workspace public access setting; update without a private endpoint preserves the existing value.')
param workspacePublicNetworkAccess 'Disabled' | 'Enabled'
@description('Required. Resource ID of an existing subnet for the feed private endpoint; empty skips endpoint creation.')
param workspaceFeedPrivateEndpointSubnetResourceId string
@description('Required. Resource ID of the existing feed private DNS zone; empty omits its endpoint DNS zone group.')
param avdPrivateDnsZoneResourceId string
@description('Optional. Resource ID of an existing Log Analytics workspace; empty omits optional diagnostic settings.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Required. Whether this module manages the global discovery workspace and its requested private endpoint.')
param manageGlobalWorkspace bool

@allowed([
  'Create'
  'Update'
])
@description('Required. Create deploys a new global workspace; Update reads globalWorkspaceResourceId.')
param globalWorkspaceMode string
@description('Required. Name of the global workspace to create; update mode derives it from globalWorkspaceResourceId.')
param globalWorkspaceName string
@description('Required. Existing global workspace ID required for Update mode; also passed through when the global workspace is not managed.')
param globalWorkspaceResourceId string
@description('Required. Target global workspace resource group name in this subscription for Create mode.')
param globalWorkspaceResourceGroupName string
@description('Optional. Whether to create the global workspace resource group in Create mode; otherwise it must exist.')
param createGlobalWorkspaceResourceGroup bool = true
@description('Required. Resource ID of an existing subnet for the global discovery private endpoint; empty skips endpoint creation.')
param globalFeedPrivateEndpointSubnetResourceId string
@description('Required. Resource ID of the existing global discovery private DNS zone; empty omits its endpoint DNS zone group.')
param globalFeedPrivateDnsZoneResourceId string

@description('Required. Private endpoint name pattern using RESOURCE, SUBRESOURCE, and VNETID substitution tokens.')
param privateEndpointNameConv string
@description('Required. Private endpoint NIC name pattern using RESOURCE, SUBRESOURCE, and VNETID substitution tokens.')
param privateEndpointNICNameConv string
@description('Optional. Tag bags keyed by Azure resource type; each bag is applied to resources of that type.')
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
import { privateEndpointName } from '../naming/naming.bicep'

var workspaceFeedPrivateEndpointName = privateEndpointName(privateEndpointNameConv, effectiveWorkspaceName, 'feed', workspaceFeedVnetName)
var workspaceFeedPrivateEndpointNICName = privateEndpointName(privateEndpointNICNameConv, effectiveWorkspaceName, 'feed', workspaceFeedVnetName)

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
var globalFeedPrivateEndpointName = privateEndpointName(privateEndpointNameConv, effectiveGlobalWorkspaceName, 'global', globalFeedVnetName)
var globalFeedPrivateEndpointNICName = privateEndpointName(privateEndpointNICNameConv, effectiveGlobalWorkspaceName, 'global', globalFeedVnetName)

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

@description('Managed feed workspace resource ID, or an empty string when manageWorkspace is false.')
output workspaceResourceId string = manageWorkspace ? workspace!.outputs.resourceId : ''
@description('Feed private endpoint resource ID, or an empty string when no managed feed endpoint is requested.')
output workspaceFeedPrivateEndpointResourceId string = manageWorkspace && !empty(workspaceFeedPrivateEndpointSubnetResourceId)
  ? workspaceFeedPrivateEndpoint!.outputs.resourceId
  : ''
@description('Managed global workspace resource ID, or the supplied ID when manageGlobalWorkspace is false.')
output globalWorkspaceResourceId string = manageGlobalWorkspace
  ? globalWorkspace!.outputs.resourceId
  : globalWorkspaceResourceId
@description('Global discovery private endpoint resource ID, or an empty string when no managed global endpoint is requested.')
output globalFeedPrivateEndpointResourceId string = manageGlobalWorkspace && !empty(globalFeedPrivateEndpointSubnetResourceId)
  ? globalFeedPrivateEndpoint!.outputs.resourceId
  : ''
@description('Effective feed workspace resource group name, or an empty string when the feed workspace is not managed.')
output controlPlaneResourceGroupName string = manageWorkspace ? effectiveWorkspaceResourceGroupName : ''
@description('Effective feed workspace resource group ID, or an empty string when the feed workspace is not managed.')
output controlPlaneResourceGroupResourceId string = manageWorkspace
  ? '/subscriptions/${effectiveWorkspaceSubscriptionId}/resourceGroups/${effectiveWorkspaceResourceGroupName}'
  : ''
