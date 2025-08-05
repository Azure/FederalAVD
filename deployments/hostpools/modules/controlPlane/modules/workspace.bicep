param applicationGroupResourceId string
param existingWorkspaceProperties object
param friendlyName string
param location string
param logAnalyticsWorkspaceResourceId string
param enableMonitoring bool
param groupIds array
param privateDnsZoneResourceId string
param privateEndpoint bool
param privateEndpointLocation string
param privateEndpointName string
param privateEndpointNICName string
param publicNetworkAccess string
param privateEndpointSubnetResourceId string
param tags object
param timeStamp string
param workspaceName string

var existingWorkspaceReferences = !empty(existingWorkspaceProperties) ? map(existingWorkspaceProperties.applicationGroupReferences, resId => toLower(resId)) : []
var appGroupResId = toLower(applicationGroupResourceId)

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' = {
  name: empty(existingWorkspaceProperties) ? workspaceName : existingWorkspaceProperties.name
  location: empty(existingWorkspaceProperties) ? location : existingWorkspaceProperties.location
  tags: empty(existingWorkspaceProperties) ? tags[?'Microsoft.DesktopVirtualization/Workspaces'] ?? {} : existingWorkspaceProperties.tags
  properties: {
    applicationGroupReferences: empty(existingWorkspaceProperties) ? ( empty(applicationGroupResourceId) ? null : [applicationGroupResourceId] ) : union(existingWorkspaceReferences, [appGroupResId])
    friendlyName: empty(existingWorkspaceProperties) ? friendlyName : existingWorkspaceProperties.friendlyName
    publicNetworkAccess: empty(existingWorkspaceProperties) ? publicNetworkAccess : existingWorkspaceProperties.publicNetworkAccess
  }
}

module workspace_privateEndpoint '../../../../sharedModules/resources/network/private-endpoint/main.bicep' = if (privateEndpoint && !empty(privateEndpointSubnetResourceId)) {
  name: '${workspaceName}_privateEndpoint_${timeStamp}'
  params: {
    customNetworkInterfaceName: privateEndpointNICName
    groupIds: groupIds
    location: !empty(privateEndpointLocation) ? privateEndpointLocation : location
    name: privateEndpointName
    privateDnsZoneGroup: empty(privateDnsZoneResourceId) ? null : {
      privateDNSResourceIds: [
        privateDnsZoneResourceId
      ]
    }
    serviceResourceId: empty(existingWorkspaceProperties) ? workspace.id : existingWorkspaceProperties.resourceId
    subnetResourceId: privateEndpointSubnetResourceId
    tags: union(
      {
        'cm-resource-parent': workspace.id
      },
      tags[?'Microsoft.Network/privateEndpoints'] ?? {}
    )
  }
}

resource workspace_diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (empty(existingWorkspaceProperties) && enableMonitoring) {
  name: 'WVDInsights'
  scope: workspace
  properties: {
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
    ]
    workspaceId: logAnalyticsWorkspaceResourceId
  }
}

output resourceId string = workspace.id
