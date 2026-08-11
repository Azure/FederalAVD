// Resource-group-scoped module: Azure Automation Account and all associated resources
// for the FSLogix Storage Quota Manager add-on.

// ========== //
// Parameters //
// ========== //

@description('Required. Name of the Automation Account.')
param automationAccountName string

@description('Required. Azure region for all resources.')
param location string

@description('Optional. Tags to apply to all resources.')
param tags object = {}

@description('Required. Name of the resource group containing the FSLogix storage accounts.')
param storageResourceGroupName string

@description('Required. Subscription ID containing the FSLogix storage resource group.')
param storageSubscriptionId string

@description('Required. Azure Resource Manager URI for this cloud (e.g. https://management.azure.com/).')
param resourceManagerUri string

@description('Optional. How often the runbook runs, in minutes. Minimum 15.')
@minValue(15)
param scheduleFrequencyMinutes int = 15

@description('Required. UTC timestamp used to set the initial schedule start time (10 minutes from deployment).')
param deploymentTime string

@description('Optional. Log Analytics Workspace resource ID for diagnostic settings.')
param logAnalyticsWorkspaceResourceId string = ''

@description('''Optional. URI of the runbook PS1 file to publish at deployment time.

Leave empty for air-gapped or internet-restricted environments. When empty the runbook
resource is created in New (unpublished) state. The schedule and job schedule link are
still created so the account is fully configured; the runbook just needs to be published
manually before the first scheduled run. See README.md for portal and PowerShell steps.''')
param runbookContentUri string = ''

@description('''Optional. Controls whether ARM creates the job schedule link between the runbook and
schedule. Leave true for normal deployments - ARM handles idempotent redeployment correctly when
the automation account already exists.

Set to false ONLY if you receive: Code: Conflict / A jobSchedule with same id already exists.
This error occurs specifically when the automation account was previously DELETED from ARM and is
being recreated with the same name. Azure Automation caches the runbook/schedule association by
account name; that cache persists through ARM deletion and is restored the moment an account with
the same name exists again, causing ARM's create call to conflict with the cached association.

When set to false, the existing job schedule link is preserved and the runbook continues to run
on schedule. To clear the conflict manually from Azure Cloud Shell (required before setting back
to true), see the snippet in the comment above the jobSchedule resource below.''')
param createJobSchedule bool = true

// ========== //
// Variables  //
// ========== //

var runbookName = 'Set-StorageQuota'

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

// Automation Variable: Storage Resource Group Name
resource varResourceGroupName 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'ResourceGroupName'
  properties: {
    value: '"${storageResourceGroupName}"'
    isEncrypted: true
    description: 'Name of the resource group containing the FSLogix storage accounts.'
  }
}

// Automation Variable: Subscription ID
resource varSubscriptionId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'SubscriptionId'
  properties: {
    value: '"${storageSubscriptionId}"'
    isEncrypted: true
    description: 'Subscription ID containing the FSLogix storage resource group.'
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
// When runbookContentUri is provided the runbook is immediately published (Published state).
// When empty the runbook is created in New state - publish manually after deployment via
// the Portal (Automation Account -> Runbooks -> Import a runbook) or PowerShell.
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: runbookName
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    logVerbose: false
    logProgress: false
    description: 'Automatically increases FSLogix file share quotas before they fill up.'
    publishContentLink: !empty(runbookContentUri) ? {
      uri: runbookContentUri
    } : null
  }
}

// Schedule
resource schedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: 'StorageQuotaManager-Schedule'
  properties: {
    description: 'Runs the storage quota manager on a recurring interval.'
    startTime: scheduleStartTime
    frequency: 'Minute'
    interval: scheduleFrequencyMinutes
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
