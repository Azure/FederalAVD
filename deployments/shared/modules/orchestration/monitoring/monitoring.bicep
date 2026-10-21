metadata name = 'AVD monitoring orchestration'
metadata description = 'Creates a Log Analytics workspace, data collection endpoint, and AVD Insights data collection rule in an existing monitoring resource group, optionally adding them to an existing Azure Monitor Private Link Scope.'

targetScope = 'subscription'

@description('Required. Resource ID of an existing Azure Monitor Private Link Scope; empty skips scope membership and leaves endpoint public access enabled.')
param azureMonitorPrivateLinkScopeResourceId string
@description('Required. Name of the data collection endpoint in the deployment resource group.')
param dataCollectionEndpointName string
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Name of the Log Analytics workspace to create in the monitoring resource group.')
param logAnalyticsWorkspaceName string
@description('Optional. Log Analytics workspace retention interval in days.')
param logAnalyticsWorkspaceRetention int = 30
@description('Optional. Pricing SKU of the Log Analytics workspace to create.')
param logAnalyticsWorkspaceSku string = 'PerGB2018'
@description('Required. Name of the existing resource group for the workspace, endpoint, and AVD Insights rule.')
param resourceGroupMonitoring string
@description('Required. Tag bags keyed by Azure resource type; each bag is applied to resources of that type.')
param tags object

// ─── Log Analytics Workspace ───────────────────────────────────────────────────
module logAnalyticsWorkspace '../../resourceModules/operationalInsights/workspaces/deploy.bicep' = {
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
module dataCollectionEndpoint '../../resourceModules/insights/dataCollectionEndpoints/deploy.bicep' = {
  scope: resourceGroup(resourceGroupMonitoring)
  params: {
    name: dataCollectionEndpointName
    location: location
    tags: tags[?'Microsoft.Insights/dataCollectionEndpoints'] ?? {}
    publicNetworkAccess: empty(azureMonitorPrivateLinkScopeResourceId) ? 'Enabled' : 'Disabled'
  }
}

// ─── AVD Insights Data Collection Rule ────────────────────────────────────────
module avdInsightsDataCollectionRule '../../resourceModules/monitoring/avdInsightsDataCollectionRule.bicep' = {
  scope: resourceGroup(resourceGroupMonitoring)
  params: {
    location: location
    tags: tags[?'Microsoft.Insights/dataCollectionRules'] ?? {}
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
    dataCollectionEndpointId: dataCollectionEndpoint.outputs.resourceId
  }
}

// ─── Azure Monitor Private Link Scope ─────────────────────────────────────────
module updatePrivateLinkScope '../../resourceModules/privateLinkScope/get-PrivateLinkScope.bicep' = if (!empty(azureMonitorPrivateLinkScopeResourceId)) {
  params: {
    privateLinkScopeResourceId: azureMonitorPrivateLinkScopeResourceId
    scopedResourceIds: [
      logAnalyticsWorkspace.outputs.resourceId
      dataCollectionEndpoint.outputs.resourceId
    ]
  }
}

@description('Resource ID of the created AVD Insights data collection rule.')
output avdInsightsDataCollectionRuleResourceId string = avdInsightsDataCollectionRule.outputs.resourceId
@description('Compatibility alias returning the same AVD Insights data collection rule resource ID as the singular output.')
output avdInsightsDataCollectionRulesResourceId string = avdInsightsDataCollectionRule.outputs.resourceId
@description('Resource ID of the created data collection endpoint.')
output dataCollectionEndpointResourceId string = dataCollectionEndpoint.outputs.resourceId
@description('Resource ID of the created Log Analytics workspace.')
output logAnalyticsWorkspaceResourceId string = logAnalyticsWorkspace.outputs.resourceId
