targetScope = 'subscription'

import { personalScalingScheduleType, pooledScalingScheduleType } from '../../../shared/modules/resourceModules/types/scalingTypes.bicep'

param appGroupSecurityGroups string[]
param avdPrivateDnsZoneResourceId string
param avdPrivateLinkPrivateRoutes string
param deploymentUserAssignedIdentityClientId string
param deploymentVirtualMachineName string
param deployScalingPlan bool
param desktopApplicationGroupName string
param desktopFriendlyName string
param enableMonitoring bool
param existingFeedWorkspaceResourceId string
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
param virtualMachinesRegion string
param logAnalyticsWorkspaceResourceId string
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param resourceGroupControlPlane string
param resourceGroupDeployment string
param scalingPlanExclusionTag string
param scalingPlanName string
param scalingPlanPooledSchedules pooledScalingScheduleType[]
param scalingPlanPersonalSchedules personalScalingScheduleType[]
param startVMOnConnect bool
param tags object
param virtualMachinesTimeZone string

// ─── Private endpoint name construction ───────────────────────────────────────
var deployHostPoolPrivateEndpoint = avdPrivateLinkPrivateRoutes != 'None' && !empty(hostPoolPrivateEndpointSubnetResourceId)

func virtualNetworkResourceId(subnetResourceId string) string => join(take(split(subnetResourceId, '/'), 9), '/')

var hostPoolPrivateEndpointVirtualNetworkResourceId = deployHostPoolPrivateEndpoint
  ? virtualNetworkResourceId(hostPoolPrivateEndpointSubnetResourceId)
  : ''

resource hostPoolPrivateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if (deployHostPoolPrivateEndpoint) {
  name: last(split(hostPoolPrivateEndpointVirtualNetworkResourceId, '/'))
  scope: resourceGroup(split(hostPoolPrivateEndpointVirtualNetworkResourceId, '/')[2], split(hostPoolPrivateEndpointVirtualNetworkResourceId, '/')[4])
}

var hostPoolVnetName = last(split(hostPoolPrivateEndpointVirtualNetworkResourceId, '/'))
var hostPoolVnetId = length(hostPoolVnetName) < 37 ? hostPoolVnetName : uniqueString(hostPoolVnetName)

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
resource existingFeedWorkspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' existing = {
  name: last(split(existingFeedWorkspaceResourceId, '/'))
  scope: resourceGroup(split(existingFeedWorkspaceResourceId, '/')[2], split(existingFeedWorkspaceResourceId, '/')[4])
}

var feedExistingRefs = map(existingFeedWorkspace.properties.applicationGroupReferences, resId => toLower(resId))

// ─── Host Pool ─────────────────────────────────────────────────────────────────
module hostPool '../../../shared/modules/resourceModules/desktopVirtualization/hostPools/deploy.bicep' = {
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

module hostPool_pe '../../../shared/modules/resourceModules/network/privateEndpoints/deploy.bicep' = if (deployHostPoolPrivateEndpoint) {
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    name: hostPoolPrivateEndpointName
    location: hostPoolPrivateEndpointVirtualNetwork!.location
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
module applicationGroup '../../../shared/modules/resourceModules/desktopVirtualization/applicationGroups/deploy.bicep' = {
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
module updateDesktopFriendlyName '../../../shared/modules/resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = if (!empty(desktopFriendlyName)) {
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Update-Desktop-Friendly-Name'
    location: virtualMachinesRegion
    script: loadTextContent('../../../shared/scripts/Update-AvdSessionDesktopName.ps1')
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

module appGroupRoleAssignments '../../../shared/modules/resourceModules/desktopVirtualization/applicationGroups/roleAssignment.bicep' = {
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
module feedWorkspace '../../../shared/modules/resourceModules/desktopVirtualization/workspaces/deploy.bicep' = {
  scope: resourceGroup(split(existingFeedWorkspaceResourceId, '/')[2], split(existingFeedWorkspaceResourceId, '/')[4])
  params: {
    name: existingFeedWorkspace.name
    location: existingFeedWorkspace.location
    tags: existingFeedWorkspace.tags
    friendlyName: existingFeedWorkspace.properties.friendlyName
    description: existingFeedWorkspace.properties.description
    publicNetworkAccess: existingFeedWorkspace.properties.publicNetworkAccess == 'Disabled' ? 'Disabled' : 'Enabled'
    applicationGroupResourceIds: union(feedExistingRefs, [toLower(applicationGroup.outputs.resourceId)])
  }
}

// ─── Scaling Plan ──────────────────────────────────────────────────────────────
module scalingPlan '../../../shared/modules/resourceModules/desktopVirtualization/scalingPlans/deploy.bicep' = if (deployScalingPlan) {
  scope: resourceGroup(resourceGroupControlPlane)
  params: {
    name: scalingPlanName
    location: virtualMachinesRegion
    tags: tags[?'Microsoft.DesktopVirtualization/scalingPlans'] ?? {}
    timeZone: virtualMachinesTimeZone
    exclusionTag: scalingPlanExclusionTag
    hostPoolType: effectiveHostPoolType
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPool.outputs.resourceId
        scalingPlanEnabled: true
      }
    ]
    pooledSchedules: scalingPlanPooledSchedules
    personalSchedules: scalingPlanPersonalSchedules
    diagnosticSettings: enableMonitoring
      ? {
          name: 'WVDInsights'
          workspaceId: logAnalyticsWorkspaceResourceId
        }
      : null
  }
}

output hostPoolResourceId string = hostPool.outputs.resourceId
output workspaceResourceId string = feedWorkspace.outputs.resourceId
