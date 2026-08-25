targetScope = 'subscription'

@description('Required. Resource group containing the AVD control-plane resources.')
param resourceGroupName string

@description('Required. Azure region for the AVD control plane.')
param location string

@description('Required. Automated host-pool name.')
param hostPoolName string

@description('Required. Desktop application-group name.')
param applicationGroupName string

@description('Required. Workspace name.')
param workspaceName string

@description('Optional. Resource ID of an existing workspace to update with the new application group.')
param existingWorkspaceResourceId string = ''

@description('Optional. Workspace friendly name.')
param workspaceFriendlyName string = ''

@description('Optional. Desktop application-group friendly name.')
param desktopFriendlyName string = ''

@description('Optional. Name of the deployment VM used to update the SessionDesktop friendly name.')
param deploymentVirtualMachineName string = ''

@description('Optional. Client ID of the deployment identity used to update the SessionDesktop friendly name.')
param deploymentUserAssignedIdentityClientId string = ''

@description('Optional. Resource group containing the deployment VM.')
param deploymentResourceGroupName string = ''

@description('Optional. Azure region containing the deployment VM.')
param deploymentLocation string = location

@description('Optional. Suffix used to keep Run Command deployment names unique.')
param deploymentSuffix string = utcNow('yyyyMMddHHmmss')

@description('Optional. Entra group object IDs assigned Desktop Virtualization User access.')
param appGroupSecurityGroupIds string[] = []

@description('Optional. Maximum concurrent sessions per session host.')
param maxSessionLimit int = 4

@description('Optional. Pooled host load-balancing algorithm.')
@allowed([
  'BreadthFirst'
  'DepthFirst'
])
param loadBalancerType string = 'DepthFirst'

@description('Optional. Custom RDP properties applied to the host pool.')
param customRdpProperty string = ''

@description('Optional. Deploy the host pool in the validation environment.')
param validationEnvironment bool = false

@description('Optional. Allow session hosts to start when a user connects.')
param startVMOnConnect bool = true

@description('Optional. Deploy a dynamic create/delete scaling plan for the automated host pool.')
param deployDynamicScalingPlan bool = false

@description('Required when dynamic scaling is enabled. Scaling-plan name.')
param scalingPlanName string = ''

@description('Optional. Scaling-plan time zone.')
param scalingPlanTimeZone string = 'Eastern Standard Time'

@description('Optional. Tag that excludes session hosts from scaling operations.')
param scalingPlanExclusionTag string = 'ScalingPlanExclusion'

@description('Required when dynamic scaling is enabled. Create/delete scaling schedules.')
param dynamicScalingSchedules array = []

@allowed([
  'None'
  'HostPool'
  'FeedAndHostPool'
  'All'
])
@description('Optional. AVD traffic routed through Private Link.')
param avdPrivateLinkPrivateRoutes string = 'None'

@description('Optional. Subnet resource ID for the host-pool connection private endpoint.')
param hostPoolPrivateEndpointSubnetResourceId string = ''

@description('Optional. AVD Private DNS zone resource ID for connection and feed endpoints.')
param avdPrivateDnsZoneResourceId string = ''

@description('Optional. Public network access mode for the host pool.')
param hostPoolPublicNetworkAccess 'Disabled' | 'Enabled' | 'EnabledForClientsOnly' = 'Enabled'

@description('Optional. Subnet resource ID for the workspace feed private endpoint.')
param workspaceFeedPrivateEndpointSubnetResourceId string = ''

@description('Optional. Public network access mode for a newly created workspace.')
param workspacePublicNetworkAccess 'Disabled' | 'Enabled' = 'Enabled'

@description('Optional. Existing global-feed workspace resource ID.')
param existingGlobalWorkspaceResourceId string = ''

@description('Optional. Subnet resource ID for a newly created global-feed private endpoint.')
param globalFeedPrivateEndpointSubnetResourceId string = ''

@description('Optional. Private DNS zone resource ID for the global-feed endpoint.')
param globalFeedPrivateDnsZoneResourceId string = ''

@description('Optional. Name for a newly created global-feed workspace.')
param globalWorkspaceName string = ''

@description('Optional. Resource group for a newly created global-feed workspace and endpoint.')
param resourceGroupGlobalFeed string = ''

@description('Required. Naming pattern for private endpoints.')
param privateEndpointNameConv string

@description('Required. Naming pattern for private-endpoint network interfaces.')
param privateEndpointNICNameConv string

@description('Optional. Resource ID of a Log Analytics workspace used for diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Tags keyed by Azure resource type.')
param tags object = {}

@description('Optional. Operational metadata tags applied to the automated host pool.')
param hostPoolCustomTags object = {}

resource existingWorkspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' existing = if (!empty(existingWorkspaceResourceId)) {
  name: last(split(existingWorkspaceResourceId, '/'))
  scope: resourceGroup(split(existingWorkspaceResourceId, '/')[2], split(existingWorkspaceResourceId, '/')[4])
}

var effectiveWorkspaceName = !empty(existingWorkspaceResourceId) ? existingWorkspace!.name : workspaceName
var existingApplicationGroupReferences = !empty(existingWorkspaceResourceId)
  ? existingWorkspace!.properties.applicationGroupReferences
  : []
var diagnostics = !empty(logAnalyticsWorkspaceResourceId)
  ? {
      name: 'WVDInsights'
      workspaceId: logAnalyticsWorkspaceResourceId
    }
  : null
var deployHostPoolPrivateEndpoint = avdPrivateLinkPrivateRoutes != 'None' && !empty(hostPoolPrivateEndpointSubnetResourceId)
var deployWorkspaceFeedPrivateEndpoint = contains(['FeedAndHostPool', 'All'], avdPrivateLinkPrivateRoutes) && !empty(workspaceFeedPrivateEndpointSubnetResourceId)
var deployGlobalWorkspace = avdPrivateLinkPrivateRoutes == 'All' && empty(existingGlobalWorkspaceResourceId) && !empty(globalFeedPrivateEndpointSubnetResourceId)
var effectiveWorkspacePublicNetworkAccess 'Disabled' | 'Enabled' = deployWorkspaceFeedPrivateEndpoint
  ? workspacePublicNetworkAccess
  : (!empty(existingWorkspaceResourceId) && existingWorkspace!.properties.publicNetworkAccess == 'Disabled' ? 'Disabled' : 'Enabled')

resource hostPoolPrivateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if (deployHostPoolPrivateEndpoint) {
  name: split(hostPoolPrivateEndpointSubnetResourceId, '/')[8]
  scope: resourceGroup(split(hostPoolPrivateEndpointSubnetResourceId, '/')[2], split(hostPoolPrivateEndpointSubnetResourceId, '/')[4])
}

resource workspaceFeedPrivateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if (deployWorkspaceFeedPrivateEndpoint) {
  name: split(workspaceFeedPrivateEndpointSubnetResourceId, '/')[8]
  scope: resourceGroup(split(workspaceFeedPrivateEndpointSubnetResourceId, '/')[2], split(workspaceFeedPrivateEndpointSubnetResourceId, '/')[4])
}

resource globalFeedPrivateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if (deployGlobalWorkspace) {
  name: split(globalFeedPrivateEndpointSubnetResourceId, '/')[8]
  scope: resourceGroup(split(globalFeedPrivateEndpointSubnetResourceId, '/')[2], split(globalFeedPrivateEndpointSubnetResourceId, '/')[4])
}

func privateEndpointName(pattern string, resourceName string, subresource string, vnetName string) string => replace(
  replace(replace(pattern, 'SUBRESOURCE', subresource), 'RESOURCE', resourceName),
  'VNETID',
  length(vnetName) < 37 ? vnetName : uniqueString(vnetName)
)

module hostPool '../../shared/modules/resourceModules/desktopVirtualization/hostPools/deployAutomated.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: hostPoolName
    location: location
    tags: union(tags[?'Microsoft.DesktopVirtualization/hostPools'] ?? {}, hostPoolCustomTags)
    loadBalancerType: loadBalancerType
    maxSessionLimit: maxSessionLimit
    validationEnvironment: validationEnvironment
    customRdpProperty: customRdpProperty
    publicNetworkAccess: hostPoolPublicNetworkAccess
    startVMOnConnect: startVMOnConnect
    diagnosticSettings: diagnostics
  }
}

module hostPoolPrivateEndpoint '../../shared/modules/resourceModules/network/privateEndpoints/deploy.bicep' = if (deployHostPoolPrivateEndpoint) {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: privateEndpointName(privateEndpointNameConv, hostPoolName, 'connection', hostPoolPrivateEndpointVirtualNetwork!.name)
    location: hostPoolPrivateEndpointVirtualNetwork!.location
    tags: union(
      tags[?'Microsoft.Network/privateEndpoints'] ?? {},
      { 'cm-resource-parent': hostPool.outputs.resourceId }
    )
    subnetResourceId: hostPoolPrivateEndpointSubnetResourceId
    privateLinkServiceId: hostPool.outputs.resourceId
    groupId: 'connection'
    customNetworkInterfaceName: privateEndpointName(privateEndpointNICNameConv, hostPoolName, 'connection', hostPoolPrivateEndpointVirtualNetwork!.name)
    privateDNSZoneIds: !empty(avdPrivateDnsZoneResourceId) ? [avdPrivateDnsZoneResourceId] : []
  }
}

module dynamicScalingPlan '../../shared/modules/resourceModules/desktopVirtualization/scalingPlans/deployAutomated.bicep' = if (deployDynamicScalingPlan) {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: scalingPlanName
    location: location
    tags: tags[?'Microsoft.DesktopVirtualization/scalingPlans'] ?? {}
    timeZone: scalingPlanTimeZone
    exclusionTag: scalingPlanExclusionTag
    hostPoolResourceId: hostPool.outputs.resourceId
    schedules: dynamicScalingSchedules
  }
}

module applicationGroup '../../shared/modules/resourceModules/desktopVirtualization/applicationGroups/deploy.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: applicationGroupName
    location: location
    tags: union(
      tags[?'Microsoft.DesktopVirtualization/applicationGroups'] ?? {},
      { 'cm-resource-parent': hostPool.outputs.resourceId }
    )
    hostPoolResourceId: hostPool.outputs.resourceId
    applicationGroupType: 'Desktop'
    friendlyName: desktopFriendlyName
    diagnosticSettings: diagnostics
  }
}

module updateDesktopFriendlyName '../../shared/modules/resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = if (!empty(desktopFriendlyName)) {
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'updateDesktopFriendlyName-${deploymentSuffix}'
    location: deploymentLocation
    script: loadTextContent('../../shared/scripts/Update-AvdSessionDesktopName.ps1')
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

module workspace '../../shared/modules/resourceModules/desktopVirtualization/workspaces/deploy.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: effectiveWorkspaceName
    location: !empty(existingWorkspaceResourceId) ? existingWorkspace!.location : location
    tags: !empty(existingWorkspaceResourceId)
      ? existingWorkspace!.tags ?? {}
      : tags[?'Microsoft.DesktopVirtualization/Workspaces'] ?? {}
    friendlyName: !empty(existingWorkspaceResourceId)
      ? existingWorkspace!.properties.friendlyName
      : workspaceFriendlyName
    publicNetworkAccess: effectiveWorkspacePublicNetworkAccess
    applicationGroupResourceIds: union(existingApplicationGroupReferences, [applicationGroup.outputs.resourceId])
    diagnosticSettings: !empty(existingWorkspaceResourceId) ? null : diagnostics
  }
}

module workspaceFeedPrivateEndpoint '../../shared/modules/resourceModules/network/privateEndpoints/deploy.bicep' = if (deployWorkspaceFeedPrivateEndpoint) {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: privateEndpointName(privateEndpointNameConv, effectiveWorkspaceName, 'feed', workspaceFeedPrivateEndpointVirtualNetwork!.name)
    location: workspaceFeedPrivateEndpointVirtualNetwork!.location
    tags: union(
      tags[?'Microsoft.Network/privateEndpoints'] ?? {},
      { 'cm-resource-parent': workspace.outputs.resourceId }
    )
    subnetResourceId: workspaceFeedPrivateEndpointSubnetResourceId
    privateLinkServiceId: workspace.outputs.resourceId
    groupId: 'feed'
    customNetworkInterfaceName: privateEndpointName(privateEndpointNICNameConv, effectiveWorkspaceName, 'feed', workspaceFeedPrivateEndpointVirtualNetwork!.name)
    privateDNSZoneIds: !empty(avdPrivateDnsZoneResourceId) ? [avdPrivateDnsZoneResourceId] : []
  }
}

module globalWorkspace '../../shared/modules/resourceModules/desktopVirtualization/workspaces/deploy.bicep' = if (deployGlobalWorkspace) {
  scope: resourceGroup(resourceGroupGlobalFeed)
  params: {
    name: globalWorkspaceName
    location: globalFeedPrivateEndpointVirtualNetwork!.location
    tags: tags[?'Microsoft.DesktopVirtualization/Workspaces'] ?? {}
    publicNetworkAccess: 'Enabled'
    applicationGroupResourceIds: []
    diagnosticSettings: diagnostics
  }
  dependsOn: [workspace]
}

module globalFeedPrivateEndpoint '../../shared/modules/resourceModules/network/privateEndpoints/deploy.bicep' = if (deployGlobalWorkspace) {
  scope: resourceGroup(resourceGroupGlobalFeed)
  params: {
    name: privateEndpointName(privateEndpointNameConv, globalWorkspaceName, 'global', globalFeedPrivateEndpointVirtualNetwork!.name)
    location: globalFeedPrivateEndpointVirtualNetwork!.location
    tags: union(
      tags[?'Microsoft.Network/privateEndpoints'] ?? {},
      { 'cm-resource-parent': globalWorkspace!.outputs.resourceId }
    )
    subnetResourceId: globalFeedPrivateEndpointSubnetResourceId
    privateLinkServiceId: globalWorkspace!.outputs.resourceId
    groupId: 'global'
    customNetworkInterfaceName: privateEndpointName(privateEndpointNICNameConv, globalWorkspaceName, 'global', globalFeedPrivateEndpointVirtualNetwork!.name)
    privateDNSZoneIds: !empty(globalFeedPrivateDnsZoneResourceId) ? [globalFeedPrivateDnsZoneResourceId] : []
  }
}

module applicationGroupRoleAssignments '../../shared/modules/resourceModules/desktopVirtualization/applicationGroups/roleAssignment.bicep' = if (!empty(appGroupSecurityGroupIds)) {
  scope: resourceGroup(resourceGroupName)
  params: {
    applicationGroupName: applicationGroupName
    assignments: [
      for principalId in appGroupSecurityGroupIds: {
        principalId: principalId
        principalType: 'Group'
        roleDefinitionId: '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'
        description: 'Allows the group to use the automated AVD desktop application group.'
      }
    ]
  }
  dependsOn: [applicationGroup]
}

output hostPoolResourceId string = hostPool.outputs.resourceId
output hostPoolPrincipalId string = hostPool.outputs.principalId
output applicationGroupResourceId string = applicationGroup.outputs.resourceId
output workspaceResourceId string = workspace.outputs.resourceId
output scalingPlanResourceId string = deployDynamicScalingPlan ? dynamicScalingPlan!.outputs.resourceId : ''
output hostPoolPrivateEndpointResourceId string = deployHostPoolPrivateEndpoint ? hostPoolPrivateEndpoint!.outputs.resourceId : ''
output workspaceFeedPrivateEndpointResourceId string = deployWorkspaceFeedPrivateEndpoint ? workspaceFeedPrivateEndpoint!.outputs.resourceId : ''
output globalFeedWorkspaceResourceId string = !empty(existingGlobalWorkspaceResourceId)
  ? existingGlobalWorkspaceResourceId
  : (deployGlobalWorkspace ? globalWorkspace!.outputs.resourceId : '')
output globalFeedPrivateEndpointResourceId string = deployGlobalWorkspace ? globalFeedPrivateEndpoint!.outputs.resourceId : ''
