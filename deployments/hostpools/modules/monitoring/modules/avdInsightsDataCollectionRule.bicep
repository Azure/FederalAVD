// Opinionated AVD Insights DCR.
// Deploys the Microsoft-prescribed data collection rule for Azure Virtual Desktop Insights.
// Collects the AVD-specific performance counters, Windows event logs, and FSLogix events
// required to populate the AVD Insights workbook in Azure Monitor.

param location string = resourceGroup().location
param tags object = {}
param logAnalyticsWorkspaceResourceId string
param dataCollectionEndpointId string = ''

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: 'microsoft-avdi-${toLower(location)}'
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    dataCollectionEndpointId: !empty(dataCollectionEndpointId) ? dataCollectionEndpointId : null
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounterDataSource10'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 10
          counterSpecifiers: [
            '\\LogicalDisk(C:)\\Avg. Disk Queue Length'
            '\\LogicalDisk(C:)\\Current Disk Queue Length'
            '\\Memory\\Available Mbytes'
            '\\Memory\\Page Faults/sec'
            '\\Memory\\Pages/sec'
            '\\Memory\\% Committed Bytes In Use'
            '\\PhysicalDisk(*)\\Avg. Disk Queue Length'
            '\\PhysicalDisk(*)\\Avg. Disk sec/Read'
            '\\PhysicalDisk(*)\\Avg. Disk sec/Transfer'
            '\\PhysicalDisk(*)\\Avg. Disk sec/Write'
            '\\Processor Information(_Total)\\% Processor Time'
            '\\User Input Delay per Process(*)\\Max Input Delay'
            '\\User Input Delay per Session(*)\\Max Input Delay'
            '\\RemoteFX Network(*)\\Current TCP RTT'
            '\\RemoteFX Network(*)\\Current UDP Bandwidth'
          ]
        }
        {
          name: 'perfCounterDataSource30'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 30
          counterSpecifiers: [
            '\\Terminal Services(*)\\Active Sessions'
            '\\Terminal Services(*)\\Inactive Sessions'
            '\\Terminal Services(*)\\Total Sessions'
          ]
        }
      ]
      windowsEventLogs: [
        {
          name: 'eventLogsDataSource'
          streams: ['Microsoft-Event']
          xPathQueries: [
            'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
            'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
            'System!*'
            'Microsoft-FSLogix-Apps/Operational!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
            'Application!*[System[(Level=2 or Level=3)]]'
            'Microsoft-FSLogix-Apps/Admin!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
          ]
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
        streams: ['Microsoft-Perf', 'Microsoft-Event']
        destinations: ['la-workspace']
      }
    ]
  }
}

output resourceId string = dataCollectionRule.id
output name string = dataCollectionRule.name
