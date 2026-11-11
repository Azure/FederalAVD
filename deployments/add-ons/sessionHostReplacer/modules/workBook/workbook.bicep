@description('Required. The name of the workbook.')
param workbookName string

@description('Required. The location for the workbook.')
param location string

@description('Required. The resource ID of the Log Analytics workspace that provides the shared monitoring boundary.')
param logAnalyticsWorkspaceResourceId string

@description('Optional. Tags for the workbook.')
param tags object = {}

var workbookDisplayName = 'AVD Session Host Replacer - Enterprise Dashboard'

// Query only the primary workspace, even when policy exports the same component's telemetry elsewhere.
// Schema adapters in the workbook preserve the existing dashboard parsers and native correlation.
var workbookTemplateBase = loadJsonContent('workbookTemplate.json')
var workbookTemplateWithFallback = union(workbookTemplateBase, {
  fallbackResourceIds: [
    logAnalyticsWorkspaceResourceId
  ]
})

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookName
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    serializedData: replace(string(workbookTemplateWithFallback), '__SHR_WORKSPACE_RESOURCE_ID__', logAnalyticsWorkspaceResourceId)
    version: '1.0'
    sourceId: logAnalyticsWorkspaceResourceId
    category: 'workbook'
  }
}

output workbookId string = workbook.id
output workbookName string = workbook.name
