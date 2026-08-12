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

@description('''Optional. Controls whether ARM creates the job schedule link between the runbook and
schedule. Leave true for normal deployments - ARM handles idempotent redeployment correctly when
the automation account already exists.

Set to false ONLY if you receive: Code: Conflict / A jobSchedule with same id already exists.
This error occurs specifically when the automation account was previously DELETED from ARM and is
being recreated with the same name. Azure Automation caches the runbook/schedule association by
account name; that cache persists through ARM deletion and is restored the moment an account with
the same name exists again, causing ARM\'s create call to conflict with the cached association.

When set to false, the existing job schedule link is preserved and the runbook continues to run
on schedule. To clear the conflict manually from Azure Cloud Shell (required before setting back
to true), see the snippet in the comment above the jobSchedule resource below.''')
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
    disableLocalAuth: true
  }
}

// Automation Variable: Route Table Resource ID
resource varRouteTableResourceId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'RouteTableResourceId'
  properties: {
    value: '"${routeTableResourceId}"'
    isEncrypted: true
    description: 'Resource ID of the Azure Route Table to manage.'
  }
}

// Automation Variable: M365 Endpoint Instance
resource varM365Instance 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'M365EndpointInstance'
  properties: {
    value: '"${m365EndpointInstance}"'
    isEncrypted: true
    description: 'Microsoft 365 endpoint instance (worldwide, usgovdod, usgovgcchigh, china).'
  }
}

// Automation Variable: Resource Manager URI
resource varResourceManagerUri 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'ResourceManagerUri'
  properties: {
    value: '"${resourceManagerUri}"'
    isEncrypted: true
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
// Controlled by the createJobSchedule parameter. See parameter description for when to set false.
// On normal incremental redeployments (account exists), ARM handles this idempotently.
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
