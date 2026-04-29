// Opinionated VM Insights DCR.
// Deploys the Microsoft-prescribed data collection rule for VM Insights.
// Collects performance counters and map data required to populate the VM Insights workbook.

param location string = resourceGroup().location
param tags object = {}
param logAnalyticsWorkspaceResourceId string

@description('Optional. Resource ID of the data collection endpoint. Required when the workspace uses private link.')
param dataCollectionEndpointId string = ''

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: 'microsoft-vminsights-${toLower(location)}'
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    dataCollectionEndpointId: !empty(dataCollectionEndpointId) ? dataCollectionEndpointId : null
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounterDataSource60'
          streams: ['Microsoft-InsightsMetrics']
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\VmInsights\\DetailedMetrics'
          ]
        }
      ]
      extensions: [
        {
          name: 'DependencyAgent'
          streams: ['Microsoft-ServiceMap']
          extensionName: 'DependencyAgent'
          extensionSettings: {}
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'la-workspace'
          workspaceResourceId: logAnalyticsWorkspaceResourceId
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-InsightsMetrics', 'Microsoft-ServiceMap']
        destinations: ['la-workspace']
      }
    ]
  }
}

output resourceId string = dataCollectionRule.id
output name string = dataCollectionRule.name
