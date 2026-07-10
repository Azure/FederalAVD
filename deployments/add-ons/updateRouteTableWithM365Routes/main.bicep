// M365 Route Table Updater Add-On
// Keeps a route table current with Microsoft 365 IP ranges by downloading
// them periodically from the Microsoft 365 endpoint API and writing routes
// whose names start with 'M365-' into the target route table.
// All other routes in the table are left untouched.
//
// Deployment model: Azure Automation Account with a PowerShell 7.2 runbook on a recurring
// schedule. The Automation Account uses a system-assigned managed identity that is granted
// Network Contributor on the route table resource group.
//
// Deploy this template into the same subscription as the route table it manages.

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

@description('Optional. Explicit name for the Automation Account. If not provided, derived from naming convention.')
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

@description('Required. Resource ID of the Azure Route Table to manage. The Automation Account managed identity receives Network Contributor on its resource group.')
param routeTableResourceId string

@description('Optional. Microsoft 365 endpoint instance to download IP ranges from.')
@allowed([
  'worldwide'
  'china'
  'usgovdod'
  'usgovgcchigh'
])
param m365EndpointInstance string = 'worldwide'

@description('Optional. How often the runbook runs, in hours.')
@minValue(1)
@maxValue(24)
param scheduleFrequencyHours int = 8

@description('Optional. URI of the runbook PS1 file. Override for air-gapped or private deployments.')
param runbookContentUri string = 'https://raw.githubusercontent.com/Azure/FederalAVD/main/deployments/add-ons/updateRouteTableWithM365Routes/runbook/run.ps1'

@description('Optional. UTC timestamp used to compute the first schedule start time. Defaults to deployment time.')
param deploymentTime string = utcNow()

@description('Optional. Skip creating the job schedule link. Set to true on redeployments to avoid a conflict - the jobSchedules resource type is create-only and cannot be updated by ARM.')
param skipJobSchedule bool = false

// ========== //
// Variables  //
// ========== //

var routeTableResourceGroupName = split(routeTableResourceId, '/')[4]

var cloud                 = toLower(environment().name)
var locationsObject       = loadJsonContent('../../../.common/data/locations.json')
var locationsEnvProperty  = startsWith(cloud, 'us') ? 'other' : cloud
var locations             = locationsObject[locationsEnvProperty]
var regionAbbr            = locations[location].abbreviation
var resourceAbbreviations = loadJsonContent('../../../.common/data/resourceAbbreviations.json')

var uniqueStringUrt = take(uniqueString(resourceGroup().id, routeTableResourceId), 6)

var automationAccountName = !empty(automationAccountNameOverride)
  ? automationAccountNameOverride
  : '${resourceAbbreviations.automationAccounts}-urt-${uniqueStringUrt}-${regionAbbr}'

var deploymentSuffix = take(uniqueString(resourceGroup().id, deployment().name), 8)

// ========== //
// Resources  //
// ========== //

// Automation Account and all supporting resources
module automation 'modules/automationAccount.bicep' = {
  name: 'UrtAutomation-${deploymentSuffix}'
  params: {
    automationAccountName: automationAccountName
    deploymentTime: deploymentTime
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    m365EndpointInstance: m365EndpointInstance
    resourceManagerUri: environment().resourceManager
    routeTableResourceId: routeTableResourceId
    runbookContentUri: runbookContentUri
    scheduleFrequencyHours: scheduleFrequencyHours
    skipJobSchedule: skipJobSchedule
    tags: tags
  }
}

// Grant the Automation Account managed identity Network Contributor on the route table
// resource group so the runbook can read and update the route table via the ARM API.
module roleAssignment '../../../.common/bicepModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  name: 'RA-RouteTable-NetworkContributor-${deploymentSuffix}'
  scope: resourceGroup(routeTableResourceGroupName)
  params: {
    principalId: automation.outputs.principalId
    roleDefinitionId: '4d97b98b-1d4f-4787-a291-c67834d212e7' // Network Contributor
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
