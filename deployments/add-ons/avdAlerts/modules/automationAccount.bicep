// AVD Alerts Add-On - Automation Account Module
// Deploys the Automation Account used to collect Azure Files storage space metrics and
// publish them to Log Analytics for storage-capacity alert rules.
//
// Host pool capacity alerts use WVDAgentHealthStatus (native AVD diagnostic data) directly
// and do NOT require the Automation Account.
//
// Resources:
//   - Automation Account (Basic SKU, system-assigned identity)
//   - Automation Variables (ResourceManagerUri, StorageAccountResourceIDs)
//   - Runbook: AvdStorageLogData  (deployed only when hasStorageAccounts is true)
//   - Schedule: every 15 minutes  (when hasStorageAccounts is true)
//   - Job Schedule linking runbook to schedule (controlled by createJobSchedules)
//   - Diagnostic Settings -> Log Analytics workspace

// ========== //
// Parameters //
// ========== //

@description('Required. Name of the Automation Account.')
param automationAccountName string

@description('Required. Azure region for all resources.')
param location string

@description('Optional. Tags for all resources.')
param tags object = {}

@description('Required. Azure Resource Manager URI for this cloud (e.g. https://management.azure.com/).')
param resourceManagerUri string

@description('Required. Resource ID of the Log Analytics Workspace for diagnostic settings and runbook output.')
param logAnalyticsWorkspaceResourceId string

@description('Optional. URI of the AvdStorageLogData runbook PS1 file. Leave empty for air-gapped environments to create the runbook in an unpublished state.')
param runbookStorageUri string = ''

@description('Optional. Set to true when StorageAccountResourceIds is not empty.')
param hasStorageAccounts bool = false

@description('Optional. JSON array string of storage account resource IDs for the storage runbook.')
param storageAccountResourceIdsJson string = '[]'

@description('Required. UTC timestamp used to compute the first schedule start time.')
param deploymentTime string

@description('''Optional. Set to true on first deployment to let ARM create the job schedule links.
Set to false on redeployments. Azure Automation caches job schedule associations by account
name and raises a Conflict error if ARM tries to create a link that already exists.''')
param createJobSchedules bool = true

// ========== //
// Variables  //
// ========== //

var runbookNameStorage  = 'AvdStorageLogData'

// Schedule start time a few minutes after deployment time
var scheduleStorageStart = dateTimeAdd(deploymentTime, 'PT10M')

// ========== //
// Resources  //
// ========== //

// Automation Account
resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: false
    disableLocalAuth: true
  }
}

// Variable: Resource Manager URI
resource varResourceManagerUri 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'ResourceManagerUri'
  properties: {
    value: '"${resourceManagerUri}"'
    isEncrypted: false
    description: 'Azure Resource Manager endpoint URI for this cloud.'
  }
}

// Variable: Storage Account Resource IDs (JSON array)
resource varStorageAccountResourceIDs 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (hasStorageAccounts) {
  parent: automationAccount
  name: 'StorageAccountResourceIDs'
  properties: {
    value: '"${replace(storageAccountResourceIdsJson, '"', '\\"')}"'
    isEncrypted: false
    description: 'JSON array of storage account resource IDs for the storage space collector.'
  }
}

// Runbook: AvdStorageLogData
// Collects Azure Files share usage data and writes to job stream -> Log Analytics.
resource runbookStorage 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = if (hasStorageAccounts) {
  parent: automationAccount
  name: runbookNameStorage
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    logVerbose: false
    logProgress: false
    description: 'Collects Azure Files share usage statistics for Log Analytics alert queries.'
    publishContentLink: !empty(runbookStorageUri) ? {
      uri: runbookStorageUri
    } : null
  }
}

// Schedule: AvdStorageLogData (every 15 minutes)
resource scheduleStorage 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = if (hasStorageAccounts) {
  parent: automationAccount
  name: 'AvdAlerts-Storage-15min'
  properties: {
    description: 'Runs the AVD storage data collector every 15 minutes.'
    startTime: scheduleStorageStart
    frequency: 'Minute'
    interval: 15
    timeZone: 'UTC'
  }
}

// Job Schedule: AvdStorageLogData <-> schedule
resource jobScheduleStorage 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = if (hasStorageAccounts && createJobSchedules) {
  parent: automationAccount
  #disable-next-line use-stable-resource-identifiers
  name: guid(automationAccount.id, runbookStorage.id, scheduleStorage.id)
  properties: {
    runbook: {
      name: runbookNameStorage
    }
    schedule: {
      name: 'AvdAlerts-Storage-15min'
    }
  }
}

// Diagnostic Settings - send job logs and streams to Log Analytics
resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${automationAccountName}'
  scope: automationAccount
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logs: [
      {
        category: 'JobLogs'
        enabled: true
      }
      {
        category: 'JobStreams'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: false
      }
    ]
  }
}

// ======= //
// Outputs //
// ======= //

@description('Principal ID of the Automation Account system-assigned managed identity.')
output principalId string = automationAccount.identity.principalId

@description('Resource ID of the Automation Account.')
output resourceId string = automationAccount.id
