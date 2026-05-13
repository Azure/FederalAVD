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
param hostPoolCustomTags object
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
param startVMOnConnect bool
param tags object
param virtualMachinesTimeZone string
param workspaceFeedPrivateEndpointSubnetResourceId string
param workspaceFriendlyName string
param workspaceName string
param workspacePublicNetworkAccess string

// ─── Private endpoint name construction ───────────────────────────────────────
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

// ─── Host pool type coercion ───────────────────────────────────────────────────
// hostPoolType arrives as e.g. "Pooled BreadthFirst" or "Personal Automatic"
var effectiveHostPoolType = contains(hostPoolType, 'Personal') ? 'Personal' : 'Pooled'
var effectiveLoadBalancerType = contains(hostPoolType, 'Pooled') ? split(hostPoolType, ' ')[1] : 'Persistent'
var effectivePersonalAssignmentType = contains(hostPoolType, 'Automatic')
  ? 'Automatic'
  : (contains(hostPoolType, 'Direct') ? 'Direct' : '')

// ─── Existing feed workspace lookup ───────────────────────────────────────────
resource existingFeedWorkspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' existing = if (!empty(existingFeedWorkspaceResourceId)) {
  name: last(split(existingFeedWorkspaceResourceId, '/'))
  scope: resourceGroup(split(existingFeedWorkspaceResourceId, '/')[2], split(existingFeedWorkspaceResourceId, '/')[4])
}

var feedWorkspaceExistingProps = !empty(existingFeedWorkspaceResourceId)
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

// Merge new app group into any existing workspace app group references
var feedExistingRefs = !empty(feedWorkspaceExistingProps)
  ? map(feedWorkspaceExistingProps.applicationGroupReferences, resId => toLower(resId))
  : []

// ─── Host Pool ─────────────────────────────────────────────────────────────────
module hostPool '../../../../.common/bicepModules/desktopVirtualization/hostPools/deploy.bicep' = {
  name: 'HostPool-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    name: hostPoolName
    location: controlPlaneRegion
    tags: union(tags[?'Microsoft.DesktopVirtualization/hostPools'] ?? {}, hostPoolCustomTags)
    hostPoolType: effectiveHostPoolType
    loadBalancerType: effectiveLoadBalancerType
    maxSessionLimit: hostPoolMaxSessionLimit
    validationEnvironment: hostPoolValidationEnvironment
    customRdpProperty: hostPoolRDPProperties
    publicNetworkAccess: hostPoolPublicNetworkAccess
    startVMOnConnect: startVMOnConnect
    vmTemplate: string(hostPoolVmTemplate)
    personalDesktopAssignmentType: effectivePersonalAssignmentType
    diagnosticSettings: enableMonitoring
      ? {
          name: 'WVDInsights'
          workspaceId: logAnalyticsWorkspaceResourceId
        }
      : null
  }
}

module hostPool_pe '../../../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = if (avdPrivateLinkPrivateRoutes != 'None' && !empty(hostPoolPrivateEndpointSubnetResourceId)) {
  name: 'HostPool-PE-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    name: hostPoolPrivateEndpointName
    location: controlPlaneRegion
    tags: union(
      { 'cm-resource-parent': hostPool.outputs.resourceId },
      tags[?'Microsoft.Network/privateEndpoints'] ?? {}
    )
    subnetResourceId: hostPoolPrivateEndpointSubnetResourceId
    privateLinkServiceId: hostPool.outputs.resourceId
    groupId: 'connection'
    customNetworkInterfaceName: hostPoolPrivateEndpointNICName
    privateDNSZoneIds: !empty(avdPrivateDnsZoneResourceId) ? [avdPrivateDnsZoneResourceId] : []
  }
}

// ─── Application Group ─────────────────────────────────────────────────────────
module applicationGroup '../../../../.common/bicepModules/desktopVirtualization/applicationGroups/deploy.bicep' = {
  name: 'ApplicationGroup-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    name: desktopApplicationGroupName
    location: controlPlaneRegion
    tags: union(
      { 'cm-resource-parent': hostPool.outputs.resourceId },
      tags[?'Microsoft.DesktopVirtualization/applicationGroups'] ?? {}
    )
    hostPoolResourceId: hostPool.outputs.resourceId
    applicationGroupType: 'Desktop'
    diagnosticSettings: enableMonitoring
      ? {
          name: 'WVDInsights'
          workspaceId: logAnalyticsWorkspaceResourceId
        }
      : null
  }
}

// Adds a friendly name to the SessionDesktop application in the app group
module updateDesktopFriendlyName '../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = if (!empty(desktopFriendlyName)) {
  name: 'DesktopFriendlyName-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'updateDesktopFriendlyName-${deploymentSuffix}'
    location: virtualMachinesRegion
    script: loadTextContent('../../../../.common/scripts/Update-AvdSessionDesktopName.ps1')
    parameters: [
      { name: 'ApplicationGroupResourceId', value: applicationGroup.outputs.resourceId }
      { name: 'FriendlyName', value: desktopFriendlyName }
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
    ]
    timeoutInSeconds: 120
    treatFailureAsDeploymentFailure: true
  }
}

// Role assignments must live in a RG-scoped module (Bicep constraint at subscription scope)
var desktopVirtualizationUserRoleId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'

module appGroupRoleAssignments '../../../../.common/bicepModules/desktopVirtualization/applicationGroups/roleAssignment.bicep' = {
  name: 'AppGroup-RoleAssignments-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    applicationGroupName: desktopApplicationGroupName
    assignments: [
      for principalId in appGroupSecurityGroups: {
        principalId: principalId
        roleDefinitionId: desktopVirtualizationUserRoleId
        principalType: 'Group'
      }
    ]
  }
  dependsOn: [applicationGroup]
}

// ─── Feed Workspace ────────────────────────────────────────────────────────────
module feedWorkspace '../../../../.common/bicepModules/desktopVirtualization/workspaces/deploy.bicep' = {
  name: 'WorkspaceFeed-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    name: empty(feedWorkspaceExistingProps) ? workspaceName : feedWorkspaceExistingProps.name
    location: empty(feedWorkspaceExistingProps) ? controlPlaneRegion : feedWorkspaceExistingProps.location
    tags: empty(feedWorkspaceExistingProps)
      ? tags[?'Microsoft.DesktopVirtualization/Workspaces'] ?? {}
      : feedWorkspaceExistingProps.tags
    friendlyName: empty(feedWorkspaceExistingProps) ? workspaceFriendlyName : feedWorkspaceExistingProps.friendlyName
    publicNetworkAccess: empty(feedWorkspaceExistingProps)
      ? workspacePublicNetworkAccess
      : feedWorkspaceExistingProps.publicNetworkAccess
    applicationGroupResourceIds: empty(feedWorkspaceExistingProps)
      ? [applicationGroup.outputs.resourceId]
      : union(feedExistingRefs, [toLower(applicationGroup.outputs.resourceId)])
    diagnosticSettings: (empty(feedWorkspaceExistingProps) && enableMonitoring)
      ? {
          name: 'WVDInsights'
          workspaceId: logAnalyticsWorkspaceResourceId
        }
      : null
  }
}

// The original condition avdPrivateLinkPrivateRoutes != 'None' || avdPrivateLinkPrivateRoutes != 'HostPool'
// is always true; the effective gate is whether a subnet was provided.
module feedWorkspace_pe '../../../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = if (!empty(workspaceFeedPrivateEndpointSubnetResourceId)) {
  name: 'WorkspaceFeed-PE-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    name: feedPrivateEndpointName
    location: controlPlaneRegion
    tags: union(
      { 'cm-resource-parent': feedWorkspace.outputs.resourceId },
      tags[?'Microsoft.Network/privateEndpoints'] ?? {}
    )
    subnetResourceId: workspaceFeedPrivateEndpointSubnetResourceId
    privateLinkServiceId: feedWorkspace.outputs.resourceId
    groupId: 'feed'
    customNetworkInterfaceName: feedPrivateEndpointNICName
    privateDNSZoneIds: !empty(avdPrivateDnsZoneResourceId) ? [avdPrivateDnsZoneResourceId] : []
  }
}

// ─── Scaling Plan ──────────────────────────────────────────────────────────────
module scalingPlan '../../../../.common/bicepModules/desktopVirtualization/scalingPlans/deploy.bicep' = if (deployScalingPlan && contains(
  hostPoolType,
  'Pooled'
)) {
  name: 'ScalingPlan-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    name: scalingPlanName
    location: virtualMachinesRegion
    tags: tags[?'Microsoft.DesktopVirtualization/scalingPlans'] ?? {}
    timeZone: virtualMachinesTimeZone
    exclusionTag: scalingPlanExclusionTag
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPool.outputs.resourceId
        scalingPlanEnabled: true
      }
    ]
    schedules: scalingPlanSchedules
    diagnosticSettings: enableMonitoring
      ? {
          name: 'WVDInsights'
          workspaceId: logAnalyticsWorkspaceResourceId
        }
      : null
  }
}

// ─── Global Feed Workspace ─────────────────────────────────────────────────────
var deployGlobalWorkspace = empty(existingGlobalWorkspaceResourceId) && avdPrivateLinkPrivateRoutes == 'All' && !empty(globalFeedPrivateDnsZoneResourceId) && !empty(globalFeedPrivateEndpointSubnetResourceId)

module globalWorkspace '../../../../.common/bicepModules/desktopVirtualization/workspaces/deploy.bicep' = if (deployGlobalWorkspace) {
  name: 'GlobalFeed-Workspace-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupGlobalFeed)
  params: {
    name: globalWorkspaceName
    location: globalFeedRegion
    tags: tags[?'Microsoft.DesktopVirtualization/Workspaces'] ?? {}
    publicNetworkAccess: 'Enabled'
    applicationGroupResourceIds: []
    diagnosticSettings: enableMonitoring
      ? {
          name: 'WVDInsights'
          workspaceId: logAnalyticsWorkspaceResourceId
        }
      : null
  }
  dependsOn: [feedWorkspace]
}

module globalWorkspace_pe '../../../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = if (deployGlobalWorkspace) {
  name: 'GlobalFeed-PE-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupGlobalFeed)
  params: {
    name: globalFeedPrivateEndpointName
    location: globalFeedRegion
    tags: union(
      { 'cm-resource-parent': globalWorkspace!.outputs.resourceId },
      tags[?'Microsoft.Network/privateEndpoints'] ?? {}
    )
    subnetResourceId: globalFeedPrivateEndpointSubnetResourceId
    privateLinkServiceId: globalWorkspace!.outputs.resourceId
    groupId: 'global'
    customNetworkInterfaceName: globalFeedPrivateEndpointNICName
    privateDNSZoneIds: [globalFeedPrivateDnsZoneResourceId]
  }
  dependsOn: [feedWorkspace]
}

output hostPoolResourceId string = hostPool.outputs.resourceId
output workspaceResourceId string = empty(existingFeedWorkspaceResourceId)
  ? feedWorkspace.outputs.resourceId
  : existingFeedWorkspaceResourceId
