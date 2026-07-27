// FSLogix Storage Quota Manager Add-On
// Automated quota management for FSLogix Azure Files Premium file shares
//
// Deployment model: Azure Automation Account with a PowerShell 7.2 runbook on a recurring
// schedule. The Automation Account uses a system-assigned managed identity that is granted
// Storage Account Contributor on the storage resource group.
//
// Deploy this template into the same resource group where you want the Automation Account.

// ========== //
// Parameters //
// ========== //

// ================================================================================================
// Common Parameters
// ================================================================================================

@description('Required. The location for all resources.')
param location string = resourceGroup().location

@description('Optional. Tags for all resources.')
param tags object = {}

// ================================================================================================
// Brownfield Naming Override Parameters
// ================================================================================================

@description('Optional. Explicit name for the Automation Account. If not provided, derived from the storage resource group name. Must be 6-128 characters, alphanumeric and hyphens.')
@maxLength(128)
param automationAccountNameOverride string = ''

// ================================================================================================
// Automation Infrastructure Parameters
// ================================================================================================

@description('Optional. Log Analytics Workspace resource ID for diagnostic settings.')
param logAnalyticsWorkspaceResourceId string = ''

// ================================================================================================
// Execution Parameters
// ================================================================================================

@description('Required. The resource ID of the resource group containing the FSLogix storage accounts. The Automation Account managed identity receives Storage Account Contributor on this resource group.')
param storageResourceGroupId string

@description('Optional. How often the runbook runs, in minutes. Minimum 15.')
@minValue(15)
param scheduleFrequencyMinutes int = 15

@description('''Optional. URI of the runbook PS1 file to download and publish at deployment time.
Defaults to the public FederalAVD GitHub repository.

For air-gapped or internet-restricted environments, set this to empty (\'\') to skip
automatic publishing. The runbook will be created in an unpublished (New) state and must
be published manually via the Portal or PowerShell before the first scheduled run.
See the add-on README for step-by-step instructions.''')
param runbookContentUri string = 'https://raw.githubusercontent.com/Azure/FederalAVD/main/deployments/add-ons/storageQuotaManager/runbook/run.ps1'

@description('Optional. UTC timestamp used to compute the first schedule start time. Defaults to deployment time.')
param deploymentTime string = utcNow()

@description('''Optional. Set to true on first deployment, false on all redeployments.

Azure Automation caches the runbook/schedule association by account name. This cache persists
even after deleting the automation account and recreating it with the same name. ARM cannot
create a job schedule resource that already exists (Conflict error). Setting this to false on
redeployment skips creation entirely - the existing link stays active and the runbook keeps
running on its schedule.''')
param createJobSchedule bool = true

// ========== //
// Variables  //
// ========== //

var storageSubscriptionId    = split(storageResourceGroupId, '/')[2]
var storageResourceGroupName = split(storageResourceGroupId, '/')[4]

var cloud                 = toLower(environment().name)
var locationsObject       = loadJsonContent('../../../.common/data/locations.json')
var locationsEnvProperty  = startsWith(cloud, 'us') ? 'other' : cloud
var locations             = locationsObject[locationsEnvProperty]
var regionAbbr            = locations[location].abbreviation
var resourceAbbreviations = loadJsonContent('../../../.common/data/resourceAbbreviations.json')

var uniqueStringSqm = take(uniqueString(storageSubscriptionId, storageResourceGroupName), 6)

var automationAccountName = !empty(automationAccountNameOverride)
  ? automationAccountNameOverride
  : '${resourceAbbreviations.automationAccounts}-sqm-${uniqueStringSqm}-${regionAbbr}'

var deploymentSuffix = take(uniqueString(resourceGroup().id, deployment().name), 8)

// ========== //
// Resources  //
// ========== //

// Automation Account and all supporting resources
module automation 'modules/automationAccount.bicep' = {
  name: 'SqmAutomation-${deploymentSuffix}'
  params: {
    automationAccountName: automationAccountName
    createJobSchedule: createJobSchedule
    deploymentTime: deploymentTime
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    resourceManagerUri: environment().resourceManager
    runbookContentUri: runbookContentUri
    scheduleFrequencyMinutes: scheduleFrequencyMinutes
    storageResourceGroupName: storageResourceGroupName
    storageSubscriptionId: storageSubscriptionId
    tags: tags
  }
}

// Grant the Automation Account managed identity Storage Account Contributor on the storage
// resource group so the runbook can read share stats and update quotas via the ARM API.
module roleAssignment '../../../.common/bicepModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  name: 'RA-StorageAccounts-StorageContributor-${deploymentSuffix}'
  scope: resourceGroup(storageSubscriptionId, storageResourceGroupName)
  params: {
    principalId: automation.outputs.principalId
    roleDefinitionId: '17d1049b-9a84-46fb-8f53-869881c3d3ab' // Storage Account Contributor
    principalType: 'ServicePrincipal'
  }
}

// ======= //
// Outputs //
// ======= //

@description('Name of the deployed Automation Account.')
output automationAccountName string = automation.outputs.automationAccountName

@description('Principal ID of the Automation Account managed identity.')
output automationAccountPrincipalId string = automation.outputs.principalId
