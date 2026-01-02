@description('Required. The name of the workbook.')
param workbookName string

@description('Required. The location for the workbook.')
param location string

@description('Required. The resource ID of the Application Insights instance for this region.')
param applicationInsightsResourceId string

@description('Optional. Tags for the workbook.')
param tags object = {}

var workbookDisplayName = 'AVD Session Host Replacer - Enterprise Dashboard'
// Use Application Insights resource ID as source to display in App Insights workbooks blade
var workbookSourceId = applicationInsightsResourceId

// Load the workbook template and inject the Application Insights resource ID
var workbookTemplateBase = loadJsonContent('workbookTemplate.json')
var workbookTemplateWithFallback = union(workbookTemplateBase, {
  fallbackResourceIds: [
    applicationInsightsResourceId
  ]
})

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookName
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    serializedData: string(workbookTemplateWithFallback)
    version: '1.0'
    sourceId: workbookSourceId
    category: 'workbook'
  }
}

output workbookId string = workbook.id
output workbookName string = workbook.name
