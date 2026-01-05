param hostingPlanType string
param location string
param logAnalyticsWorkspaceId string
param functionAppKind string
param name string
param planPricing string
param tags object
param zoneRedundant bool

var sku = {
  name: split(planPricing, '_')[1]
  tier: split(planPricing, '_')[0]
  capacity: zoneRedundant ? 3 : 1
}

resource hostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: name
  location: location
  sku: sku
  tags: tags[?'Microsoft.Web/serverfarms'] ?? {}
  properties: {
    maximumElasticWorkerCount: contains(hostingPlanType, 'Consumption') ? null : hostingPlanType == 'FunctionsPremium' ? 20 : 1
    reserved: contains(functionAppKind, 'linux') ? true : false
    zoneRedundant: zoneRedundant
  }
}

resource hostingPlan_diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if(!empty(logAnalyticsWorkspaceId)) {
  name: '${name}-diagnosticSettings'
  properties: {
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
    workspaceId: logAnalyticsWorkspaceId
  }
  scope: hostingPlan
}

output hostingPlanId string = hostingPlan.id
