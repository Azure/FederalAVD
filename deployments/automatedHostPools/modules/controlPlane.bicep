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

@description('Optional. Public network access mode for the host pool.')
param hostPoolPublicNetworkAccess string = 'Enabled'

@description('Optional. Public network access mode for a newly created workspace.')
param workspacePublicNetworkAccess string = 'Enabled'

@description('Optional. Resource ID of a Log Analytics workspace used for diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Tags keyed by Azure resource type.')
param tags object = {}

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

module hostPool '../../shared/modules/desktopVirtualization/hostPools/deployAutomated.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: hostPoolName
    location: location
    tags: tags[?'Microsoft.DesktopVirtualization/hostPools'] ?? {}
    loadBalancerType: loadBalancerType
    maxSessionLimit: maxSessionLimit
    validationEnvironment: validationEnvironment
    customRdpProperty: customRdpProperty
    publicNetworkAccess: hostPoolPublicNetworkAccess
    startVMOnConnect: startVMOnConnect
    diagnosticSettings: diagnostics
  }
}

module applicationGroup '../../shared/modules/desktopVirtualization/applicationGroups/deploy.bicep' = {
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

module workspace '../../shared/modules/desktopVirtualization/workspaces/deploy.bicep' = {
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
    publicNetworkAccess: !empty(existingWorkspaceResourceId)
      ? existingWorkspace!.properties.publicNetworkAccess
      : workspacePublicNetworkAccess
    applicationGroupResourceIds: union(existingApplicationGroupReferences, [applicationGroup.outputs.resourceId])
    diagnosticSettings: !empty(existingWorkspaceResourceId) ? null : diagnostics
  }
}

module applicationGroupRoleAssignments '../../shared/modules/desktopVirtualization/applicationGroups/roleAssignment.bicep' = if (!empty(appGroupSecurityGroupIds)) {
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
