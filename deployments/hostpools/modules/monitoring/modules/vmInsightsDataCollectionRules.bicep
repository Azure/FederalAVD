param dataCollectionEndpointId string
param location string
param logAWorkspaceResourceId string
param tags object

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: 'MSVMI-${location}'
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: !empty(dataCollectionEndpointId) ? dataCollectionEndpointId : null
    description: 'Data collection rule for VM Insights.'
    dataSources: {
      performanceCounters: [
        {
          name: 'VMInsightsPerfCounters'
          streams: [
            'Microsoft-InsightsMetrics'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\VmInsights\\DetailedMetrics'
          ]
        }
      ]      
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAWorkspaceResourceId
          name: 'VMInsightsPerf-Logs-Dest'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-InsightsMetrics'
        ]
        destinations: [
          'VMInsightsPerf-Logs-Dest'
        ]
      }      
    ]
  }
}

output dataCollectionRulesId string = dcr.id
