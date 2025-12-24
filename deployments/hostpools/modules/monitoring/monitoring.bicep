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

// Log Analytics Workspace for AVD Insights and VM Insights

module logAnalyticsWorkspace 'modules/logAnalyticsWorkspace.bicep' = {
  name: 'LogAnalytics-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupMonitoring)
  params: {
    location: location
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    logAnalyticsWorkspaceRetention: logAnalyticsWorkspaceRetention
    logAnalyticsWorkspaceSku: logAnalyticsWorkspaceSku
    tags: tags[?'Microsoft.OperationalInsights/workspaces'] ?? {}
  }
}

// Data Collection Rule for AVD Insights required for the Azure Monitor Agent
module avdInsightsDataCollectionRules 'modules/avdInsightsDataCollectionRules.bicep' = {
  name: 'AVDInsights-DataCollectionRule-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupMonitoring)
  params: {
    dataCollectionEndpointId: dataCollectionEndpoint!.outputs.resourceId
    logAWorkspaceResourceId: logAnalyticsWorkspace!.outputs.resourceId
    location: location
    tags: tags[?'Microsoft.Insights/dataCollectionRules'] ?? {}
  }
}

// Data Collection Rule for VM Insights required for the Azure Monitor Agent
module vmInsightsDataCollectionRules 'modules/vmInsightsDataCollectionRules.bicep' = {
  name: 'VMInsights-DataCollectionRule-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupMonitoring)
  params: {
    dataCollectionEndpointId: dataCollectionEndpoint!.outputs.resourceId
    location: location
    logAWorkspaceResourceId: logAnalyticsWorkspace!.outputs.resourceId
    tags: tags[?'Microsoft.Insights/dataCollectionRules'] ?? {}
  }
}

module dataCollectionEndpoint 'modules/dataCollectionEndpoint.bicep' = {
  name: 'DataCollectionEndpoint-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupMonitoring)
  params: {
    location: location    
    name: dataCollectionEndpointName
    publicNetworkAccess: empty(azureMonitorPrivateLinkScopeResourceId) ? 'Enabled' : 'Disabled'
    tags: tags[?'Microsoft.Insights/dataCollectionEndpoints'] ?? {}
  }
}

module updatePrivateLinkScope '../../../sharedModules/custom/privateLinkScopes/get-PrivateLinkScope.bicep' = if (!empty(azureMonitorPrivateLinkScopeResourceId)) {
  name: 'PrivateLlinkScope-${deploymentSuffix}'
  params: {
    deploymentSuffix: deploymentSuffix
    privateLinkScopeResourceId: azureMonitorPrivateLinkScopeResourceId
    scopedResourceIds: [
      logAnalyticsWorkspace!.outputs.resourceId
      dataCollectionEndpoint!.outputs.resourceId
    ]
  }
}

output avdInsightsDataCollectionRulesResourceId string = avdInsightsDataCollectionRules!.outputs.dataCollectionRulesId
output dataCollectionEndpointResourceId string = dataCollectionEndpoint!.outputs.resourceId
output logAnalyticsWorkspaceResourceId string = logAnalyticsWorkspace!.outputs.resourceId
output vmInsightsDataCollectionRulesResourceId string = vmInsightsDataCollectionRules!.outputs.dataCollectionRulesId
