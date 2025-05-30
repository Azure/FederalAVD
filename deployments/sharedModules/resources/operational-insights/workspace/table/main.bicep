@description('Required. The name of the table.')
param name string

@description('Conditional. The name of the parent workspaces. Required if the template is used in a standalone deployment.')
param workspaceName string

@description('Optional. Instruct the system how to handle and charge the logs ingested to this table.')
@allowed([
  'Basic'
  'Analytics'
])
param plan string = 'Analytics'

@description('Optional. Restore parameters.')
param restoredLogs object = {}

@description('Optional. The table retention in days, between 4 and 730. Setting this property to -1 will default to the workspace retention.')
@minValue(-1)
@maxValue(730)
param retentionInDays int = -1

@description('Optional. Table\'s schema.')
param schema object = {}

@description('Optional. Parameters of the search job that initiated this table.')
param searchResults object = {}

@description('Optional. The table total retention in days, between 4 and 2555. Setting this property to -1 will default to table retention.')
@minValue(-1)
@maxValue(2555)
param totalRetentionInDays int = -1

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: workspaceName
}

resource table 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: name
  properties: {
    plan: plan
    restoredLogs: restoredLogs
    #disable-next-line BCP329
    retentionInDays: retentionInDays == -1 ? null : retentionInDays
    schema: schema
    searchResults: searchResults
    #disable-next-line BCP329
    totalRetentionInDays: totalRetentionInDays == -1 ? null : totalRetentionInDays
  }
}

@description('The name of the table.')
output name string = table.name

@description('The resource ID of the table.')
output resourceId string = table.id

@description('The name of the resource group the table was created in.')
output resourceGroupName string = resourceGroup().name
