@description('Required. Name of the Log Analytics workspace.')
param name string

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Optional. The name of the SKU.')
@allowed([
  'CapacityReservation'
  'Free'
  'LACluster'
  'PerGB2018'
  'PerNode'
  'Premium'
  'Standalone'
  'Standard'
])
param skuName string = 'PerGB2018'

@minValue(100)
@maxValue(5000)
@description('Optional. The capacity reservation level in GB for this workspace, when CapacityReservation sku is selected. Must be in increments of 100 between 100 and 5000.')
param skuCapacityReservationLevel int = 100

@description('Optional. List of storage accounts to be read by the workspace.')
param storageInsightsConfigs array = []

@description('Optional. List of services to be linked.')
param linkedServices array = []

@description('Conditional. List of Storage Accounts to be linked. Required if \'forceCmkForQuery\' is set to \'true\' and \'savedSearches\' is not empty.')
param linkedStorageAccounts array = []

@description('Optional. Kusto Query Language searches to save.')
param savedSearches array = []

@description('Optional. LAW data export instances to be deployed.')
param dataExports array = []

@description('Optional. LAW data sources to configure.')
param dataSources array = []

@description('Optional. LAW custom tables to be deployed.')
param tables array = []

@description('Optional. List of gallerySolutions to be created in the log analytics workspace.')
param gallerySolutions array = []

@description('Optional. Number of days data will be retained for.')
@minValue(0)
@maxValue(730)
param dataRetention int = 365

@description('Optional. The workspace daily quota for ingestion.')
@minValue(-1)
param dailyQuotaGb int = -1

@description('Optional. The network access type for accessing Log Analytics ingestion.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccessForIngestion string = 'Enabled'

@description('Optional. The network access type for accessing Log Analytics query.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccessForQuery string = 'Enabled'

@description('Optional. Enables system assigned managed identity on the resource.')
param systemAssignedIdentity bool = false

@description('Optional. The ID(s) to assign to the resource.')
param userAssignedIdentities object = {}

@description('Optional. Set to \'true\' to use resource or workspace permissions and \'false\' (or leave empty) to require workspace permissions.')
param useResourcePermissions bool = false

@description('Optional. Resource ID of the diagnostic storage account.')
param diagnosticStorageAccountId string = ''

@description('Optional. Resource ID of a log analytics workspace.')
param diagnosticWorkspaceId string = ''

@description('Optional. Resource ID of the diagnostic event hub authorization rule for the Event Hubs namespace in which the event hub should be created or streamed to.')
param diagnosticEventHubAuthorizationRuleId string = ''

@description('Optional. Name of the diagnostic event hub within the namespace to which logs are streamed. Without this, an event hub is created for each log category.')
param diagnosticEventHubName string = ''

@description('Optional. Indicates whether customer managed storage is mandatory for query management.')
param forceCmkForQuery bool = true

@description('Optional. Tags of the resource.')
param tags object = {}

@description('Optional. The name of logs that will be streamed. "allLogs" includes all possible logs for the resource. Set to \'\' to disable log collection.')
@allowed([
  ''
  'allLogs'
  'Audit'
])
param diagnosticLogCategoriesToEnable array = [
  'allLogs'
]

@description('Optional. The name of metrics that will be streamed.')
@allowed([
  'AllMetrics'
])
param diagnosticMetricsToEnable array = [
  'AllMetrics'
]

@description('Optional. The name of the diagnostic setting, if deployed. If left empty, it defaults to "<resourceName>-diagnosticSettings".')
param diagnosticSettingsName string = ''

var diagnosticsLogsSpecified = [for category in filter(diagnosticLogCategoriesToEnable, item => item != 'allLogs' && item != ''): {
  category: category
  enabled: true
}]

var diagnosticsLogs = contains(diagnosticLogCategoriesToEnable, 'allLogs') ? [
  {
    categoryGroup: 'allLogs'
    enabled: true
  }
] : contains(diagnosticLogCategoriesToEnable, '') ? [] : diagnosticsLogsSpecified

var diagnosticsMetrics = [for metric in diagnosticMetricsToEnable: {
  category: metric
  timeGrain: null
  enabled: true
}]

var logAnalyticsSearchVersion = 1

var identityType = systemAssignedIdentity ? 'SystemAssigned' : (!empty(userAssignedIdentities) ? 'UserAssigned' : 'None')

var identity = identityType != 'None' ? {
  type: identityType
  userAssignedIdentities: !empty(userAssignedIdentities) ? userAssignedIdentities : null
} : null

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  location: location
  name: name
  tags: tags
  properties: {
    features: {
      searchVersion: logAnalyticsSearchVersion
      enableLogAccessUsingOnlyResourcePermissions: useResourcePermissions
    }
    sku: {
      name: skuName
      capacityReservationLevel: skuName == 'CapacityReservation' ? skuCapacityReservationLevel : null
    }
    retentionInDays: dataRetention
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    publicNetworkAccessForIngestion: publicNetworkAccessForIngestion
    publicNetworkAccessForQuery: publicNetworkAccessForQuery
    forceCmkForQuery: forceCmkForQuery
  }
  identity: identity
}

resource logAnalyticsWorkspace_diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if ((!empty(diagnosticStorageAccountId)) || (!empty(diagnosticWorkspaceId)) || (!empty(diagnosticEventHubAuthorizationRuleId)) || (!empty(diagnosticEventHubName))) {
  name: !empty(diagnosticSettingsName) ? diagnosticSettingsName : '${name}-diagnosticSettings'
  properties: {
    storageAccountId: !empty(diagnosticStorageAccountId) ? diagnosticStorageAccountId : null
    workspaceId: !empty(diagnosticWorkspaceId) ? diagnosticWorkspaceId : null
    eventHubAuthorizationRuleId: !empty(diagnosticEventHubAuthorizationRuleId) ? diagnosticEventHubAuthorizationRuleId : null
    eventHubName: !empty(diagnosticEventHubName) ? diagnosticEventHubName : null
    metrics: diagnosticsMetrics
    logs: diagnosticsLogs
  }
  scope: logAnalyticsWorkspace
}

module logAnalyticsWorkspace_storageInsightConfigs 'storage-insight-config/main.bicep' = [for (storageInsightsConfig, index) in storageInsightsConfigs: {
  name: 'LAW-StorageInsightsConfig-${index}-${uniqueString(deployment().name, location)}'
  params: {
    logAnalyticsWorkspaceName: logAnalyticsWorkspace.name
    containers: storageInsightsConfig.?containers ?? []
    tables: storageInsightsConfig.?tables ?? []
    storageAccountResourceId: storageInsightsConfig.storageAccountResourceId
  }
}]

module logAnalyticsWorkspace_linkedServices 'linked-service/main.bicep' = [for (linkedService, index) in linkedServices: {
  name: 'LAW-LinkedService-${index}-${uniqueString(deployment().name, location)}'
  params: {
    logAnalyticsWorkspaceName: logAnalyticsWorkspace.name
    name: linkedService.name
    resourceId: linkedService.?resourceId ?? ''
    writeAccessResourceId: linkedService.?writeAccessResourceId ?? ''
  }
}]

module logAnalyticsWorkspace_linkedStorageAccounts 'linked-storage-account/main.bicep' = [for (linkedStorageAccount, index) in linkedStorageAccounts: {
  name: 'LAW-LinkedStorageAccount-${index}-${uniqueString(deployment().name, location)}'
  params: {
    logAnalyticsWorkspaceName: logAnalyticsWorkspace.name
    name: linkedStorageAccount.name
    resourceId: linkedStorageAccount.resourceId
  }
}]

module logAnalyticsWorkspace_savedSearches 'saved-search/main.bicep' = [for (savedSearch, index) in savedSearches: {
  name: 'LAW-SavedSearch-${index}-${uniqueString(deployment().name, location)}'
  params: {
    logAnalyticsWorkspaceName: logAnalyticsWorkspace.name
    name: '${savedSearch.name}${uniqueString(deployment().name)}'
    etag: contains(savedSearch, 'eTag') ? savedSearch.etag : '*'
    displayName: savedSearch.displayName
    category: savedSearch.category
    query: savedSearch.query
    functionAlias: savedSearch.?functionAlias ?? ''
    functionParameters: savedSearch.?functionParameters ?? ''
    version: savedSearch.?version ?? 2
  }
  dependsOn: [
    logAnalyticsWorkspace_linkedStorageAccounts
  ]
}]

module logAnalyticsWorkspace_dataExports 'data-export/main.bicep' = [for (dataExport, index) in dataExports: {
  name: 'LAW-DataExport-${index}-${uniqueString(deployment().name, location)}'
  params: {
    workspaceName: logAnalyticsWorkspace.name
    name: dataExport.name
    destination: dataExport.?destination ?? {}
    enable: dataExport.?enable ?? false
    tableNames: dataExport.?tableNames ?? []
  }
}]

module logAnalyticsWorkspace_dataSources 'data-source/main.bicep' = [for (dataSource, index) in dataSources: {
  name: 'LAW-DataSource-${index}-${uniqueString(deployment().name, location)}'
  params: {
    logAnalyticsWorkspaceName: logAnalyticsWorkspace.name
    name: dataSource.name
    kind: dataSource.kind
    linkedResourceId: dataSource.?linkedResourceId ?? ''
    eventLogName: dataSource.?eventLogName ?? ''
    eventTypes: dataSource.?eventTypes ?? []
    objectName: dataSource.?objectName ?? ''
    instanceName: dataSource.?instanceName ?? ''
    intervalSeconds: dataSource.?intervalSeconds ?? 60
    counterName: dataSource.?counterName ?? ''
    state: dataSource.?state ?? ''
    syslogName: dataSource.?syslogName ?? ''
    syslogSeverities: dataSource.?syslogSeverities ?? []
    performanceCounters: dataSource.?performanceCounters ?? []
  }
}]

module logAnalyticsWorkspace_tables 'table/main.bicep' = [for (table, index) in tables: {
  name: 'LAW-Table-${index}-${uniqueString(deployment().name, location)}'
  params: {
    workspaceName: logAnalyticsWorkspace.name
    name: table.name
    plan: table.?plan ?? 'Analytics'
    schema: table.?schema ?? {}
    retentionInDays: table.?retentionInDays ?? -1
    totalRetentionInDays: table.?totalRetentionInDays ?? -1
    restoredLogs: table.?restoredLogs ?? {}
    searchResults: table.?searchResults ?? {}
  }
}]

module logAnalyticsWorkspace_solutions '../../operations-management/solution/main.bicep' = [for (gallerySolution, index) in gallerySolutions: if (!empty(gallerySolutions)) {
  name: 'LAW-Solution-${index}-${uniqueString(deployment().name, location)}'
  params: {
    name: gallerySolution.name
    location: location
    logAnalyticsWorkspaceName: logAnalyticsWorkspace.name
    product: gallerySolution.?product ?? 'OMSGallery'
    publisher: gallerySolution.?publisher ?? 'Microsoft'
  }
}]

@description('The resource ID of the deployed log analytics workspace.')
output resourceId string = logAnalyticsWorkspace.id

@description('The name of the deployed log analytics workspace.')
output name string = logAnalyticsWorkspace.name

@description('The ID associated with the workspace.')
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.properties.customerId

@description('The location the resource was deployed into.')
output location string = logAnalyticsWorkspace.location

@description('The principal ID of the system assigned identity.')
output systemAssignedIdentityPrincipalId string = systemAssignedIdentity && contains(logAnalyticsWorkspace.identity, 'principalId') ? logAnalyticsWorkspace.identity.principalId : ''
