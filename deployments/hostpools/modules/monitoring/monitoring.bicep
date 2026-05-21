targetScope = 'subscription'

param azureMonitorPrivateLinkScopeResourceId string
param dataCollectionEndpointName string
param deploymentSuffix string
param location string
param logAnalyticsWorkspaceName string
param logAnalyticsWorkspaceRetention int = 30
param logAnalyticsWorkspaceSku string = 'PerGB2018'
param resourceGroupMonitoring string
param tags object

// ─── Log Analytics Workspace ───────────────────────────────────────────────────
module logAnalyticsWorkspace '../../../../.common/bicepModules/operationalInsights/workspaces/deploy.bicep' = {
  name: 'LogAnalytics-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupMonitoring)
  params: {
    name: logAnalyticsWorkspaceName
    location: location
    tags: tags[?'Microsoft.OperationalInsights/workspaces'] ?? {}
    sku: logAnalyticsWorkspaceSku
    retentionInDays: logAnalyticsWorkspaceRetention
  }
}

// ─── Data Collection Endpoint ──────────────────────────────────────────────────
module dataCollectionEndpoint '../../../../.common/bicepModules/insights/dataCollectionEndpoints/deploy.bicep' = {
  name: 'DataCollectionEndpoint-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupMonitoring)
  params: {
    name: dataCollectionEndpointName
    location: location
    tags: tags[?'Microsoft.Insights/dataCollectionEndpoints'] ?? {}
    publicNetworkAccess: empty(azureMonitorPrivateLinkScopeResourceId) ? 'Enabled' : 'Disabled'
  }
}

// ─── AVD Insights Data Collection Rule ────────────────────────────────────────
module avdInsightsDataCollectionRule 'modules/avdInsightsDataCollectionRule.bicep' = {
  name: 'AVDInsights-DataCollectionRule-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupMonitoring)
  params: {
    location: location
    tags: tags[?'Microsoft.Insights/dataCollectionRules'] ?? {}
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
    dataCollectionEndpointId: dataCollectionEndpoint.outputs.resourceId
  }
}

// ─── Azure Monitor Private Link Scope ─────────────────────────────────────────
module updatePrivateLinkScope '../../../../.common/bicepModules/custom/get-PrivateLinkScope.bicep' = if (!empty(azureMonitorPrivateLinkScopeResourceId)) {
  name: 'PrivateLinkScope-${deploymentSuffix}'
  params: {
    deploymentSuffix: deploymentSuffix
    privateLinkScopeResourceId: azureMonitorPrivateLinkScopeResourceId
    scopedResourceIds: [
      logAnalyticsWorkspace.outputs.resourceId
      dataCollectionEndpoint.outputs.resourceId
    ]
  }
}

output avdInsightsDataCollectionRulesResourceId string = avdInsightsDataCollectionRule.outputs.resourceId
output dataCollectionEndpointResourceId string = dataCollectionEndpoint.outputs.resourceId
output logAnalyticsWorkspaceResourceId string = logAnalyticsWorkspace.outputs.resourceId
