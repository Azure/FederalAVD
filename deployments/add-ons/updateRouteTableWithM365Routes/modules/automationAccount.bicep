// Resource-group-scoped module: Azure Automation Account and all associated resources
// for the M365 Route Table Updater add-on.

// ========== //
// Parameters //
// ========== //

@description('Required. Name of the Automation Account.')
param automationAccountName string

@description('Required. Azure region for all resources.')
param location string

@description('Optional. Tags to apply to all resources.')
param tags object = {}

@description('Required. Resource ID of the route table to manage.')
param routeTableResourceId string

@description('Required. M365 endpoint instance (worldwide, usgovdod, usgovgcchigh, china).')
param m365EndpointInstance string

@description('Required. Azure Resource Manager URI for this cloud (e.g. https://management.azure.com/).')
param resourceManagerUri string

@description('Optional. How often the runbook runs, in hours.')
param scheduleFrequencyHours int = 8

@description('Required. UTC timestamp used to set the initial schedule start time (10 minutes from deployment).')
param deploymentTime string

@description('Optional. Log Analytics Workspace resource ID for diagnostic settings.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Required. URI of the runbook PS1 file to publish.')
param runbookContentUri string

@description('''Optional. Set to true on first deployment to let ARM create the job schedule link between
the runbook and schedule. Set to false on every redeployment.

WHY: Azure Automation caches the runbook/schedule association keyed on the automation account
NAME. This cache persists even after deleting the job schedule resource, the child resources,
or the automation account itself - and is restored the moment an account with that name exists
again. ARM cannot create a resource that already exists, so including this resource on
redeployment always produces: Code: Conflict / A jobSchedule with same id already exists.

The existing link is not affected when this is false - the runbook continues to run on schedule.''')
param createJobSchedule bool = true

// ========== //
// Variables  //
// ========== //

var runbookName = 'Update-M365RouteTable'

var scheduleStartTime = dateTimeAdd(deploymentTime, 'PT10M')

// ========== //
// Resources  //
// ========== //

// Automation Account with system-assigned managed identity
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
    disableLocalAuth: false
  }
}

// Automation Variable: Route Table Resource ID
resource varRouteTableResourceId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'RouteTableResourceId'
  properties: {
    value: '"${routeTableResourceId}"'
    isEncrypted: false
    description: 'Resource ID of the Azure Route Table to manage.'
  }
}

// Automation Variable: M365 Endpoint Instance
resource varM365Instance 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'M365EndpointInstance'
  properties: {
    value: '"${m365EndpointInstance}"'
    isEncrypted: false
    description: 'Microsoft 365 endpoint instance (worldwide, usgovdod, usgovgcchigh, china).'
  }
}

// Automation Variable: Resource Manager URI
resource varResourceManagerUri 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'ResourceManagerUri'
  properties: {
    value: '"${resourceManagerUri}"'
    isEncrypted: false
    description: 'Azure Resource Manager endpoint URI for this cloud.'
  }
}

// Runbook
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: runbookName
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    logVerbose: false
    logProgress: false
    description: 'Keeps an Azure Route Table current with Microsoft 365 IP ranges.'
    publishContentLink: {
      uri: runbookContentUri
    }
  }
}

// Schedule
resource schedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: 'M365RouteUpdater-Schedule'
  properties: {
    description: 'Runs the M365 route table updater on a recurring interval.'
    startTime: scheduleStartTime
    frequency: 'Hour'
    interval: scheduleFrequencyHours
    timeZone: 'UTC'
  }
}

// Job Schedule - links runbook to schedule.
// Controlled by the createJobSchedule parameter. Set true on first deployment, false on all
// subsequent redeployments. See parameter description for full explanation.
//
// To manually inspect or delete the link from Azure Cloud Shell when needed
// (publicNetworkAccess: false blocks all local tools):
//   $base = "/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Automation/automationAccounts/<name>"
//   $jsId = ((Invoke-AzRestMethod -Method GET -Path ($base + "/jobSchedules?api-version=2023-11-01")).Content | ConvertFrom-Json).value[0].properties.jobScheduleId
//   Invoke-AzRestMethod -Method DELETE -Path ($base + "/jobSchedules/" + $jsId + "?api-version=2023-11-01")
resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = if (createJobSchedule) {
  parent: automationAccount
  #disable-next-line use-stable-resource-identifiers
  name: guid(automationAccount.id, runbook.id, schedule.id)
  properties: {
    runbook: {
      name: runbook.name
    }
    schedule: {
      name: schedule.name
    }
  }
}

// Diagnostic Settings (optional)
resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceResourceId)) {
  scope: automationAccount
  name: 'diag-${automationAccountName}'
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
        enabled: true
      }
    ]
  }
}

// ======= //
// Outputs //
// ======= //

@description('Name of the deployed Automation Account.')
output automationAccountName string = automationAccount.name

@description('Principal ID of the Automation Account system-assigned managed identity.')
output principalId string = automationAccount.identity.principalId
