// AVD Alerts Add-On
//
// Subscription-scoped deployment. Deploys:
//
//   - Automation Account (Basic SKU) with system-assigned identity in the specified resource group.
//     Two runbooks: AvdHostPoolLogData and AvdStorageLogData (storage runbook only when
//     StorageAccountResourceIds is provided). Runbooks run every 15 minutes and write
//     pipe/comma-delimited output to the Automation Account job stream, which Log Analytics
//     collects via diagnostic settings.
//
//   - Per-host-pool alert rules (Log Analytics scheduled query rules) for each entry in HostPoolInfo:
//       capacity %, personal VM unhealthy, no resources available, VM health check failure,
//       user connection failures, disconnected sessions > 24h / 72h,
//       local disk free space <= 10% / 5%,
//       FSLogix profile full (EventID 33/34), network issue (43), VHD attach failure (52/40),
//       service disabled (60), compaction failed (62/63), VHD in use by another VM (51).
//
//   - Per-host-pool VM metric alert rules (multi-resource, scoped to each VM resource group):
//       CPU > 85%/95%, Available Memory < 2GB/1GB, OS Disk Bandwidth > 85%/95%.
//
//   - Per-storage-account metric alert rules (optional):
//       SuccessServerLatency > 50ms/100ms, SuccessE2ELatency > 50ms/100ms,
//       Availability < 99%, file share throttling.
//       Log-based storage space alerts <= 15%/5% (one set, driven by the storage runbook).
//
//   - Per-ANF-volume metric alert rules (optional):
//       VolumeConsumedSizePercentage >= 85%/95%.
//
//   - Service Health activity log alerts (subscription-scoped):
//       Incident, Maintenance, Health Advisory, Security.
//
// Role assignments granted to the Automation Account managed identity:
//   - Desktop Virtualization Reader on the subscription (to enumerate host pools and sessions)
//   - Log Analytics Contributor on the Log Analytics workspace resource group
//   - Storage Account Contributor on each storage account resource group (when applicable)
//
// Air-gapped environments: set runbookContentUriHostPool and runbookContentUriStorage to empty
//   strings to skip automatic runbook publishing. The Automation Account is created with the
//   runbooks in an unpublished state. Publish manually via the Portal before the first run.

targetScope = 'subscription'

// ========== //
// Parameters //
// ========== //

// ================================================================================================
// Identity / Common
// ================================================================================================

@description('Required. Azure region for the Automation Account and alert rule resources.')
param location string

@description('Optional. Tags applied to all resources.')
param tags object = {}

@description('Optional. Prefix for all alert rule names (e.g. "AVD").')
param alertNamePrefix string = 'AVD'

@description('Optional. Whether alert rules should auto-resolve when the condition clears.')
param autoResolveAlert bool = true

// ================================================================================================
// Resource Group
// ================================================================================================

@description('Required. Name of the resource group where the Automation Account and alert resources will be deployed.')
param resourceGroupName string

@description('Optional. Set to true to create the resource group. Set to false if it already exists.')
param createResourceGroup bool = false

// ================================================================================================
// Monitoring
// ================================================================================================

@description('Required. Resource ID of the Log Analytics Workspace where AVD diagnostic data is collected.')
param logAnalyticsWorkspaceResourceId string

@description('Required. Resource ID of the existing Action Group to receive alert notifications.')
param actionGroupResourceId string

// ================================================================================================
// Host Pools
// ================================================================================================

@description('''Required. Array of host pool objects, one per host pool to monitor.
Each object must have the following properties:
  hostPoolResourceId:  string  - Full resource ID of the AVD host pool.
  vmResourceGroupId:   string  - Resource ID of the resource group containing the session host VMs.
  hostPoolType:        string  - 'Pooled' or 'Personal'. Controls which alerts are deployed.

Example:
[
  { "hostPoolResourceId": "/subscriptions/.../resourceGroups/rg-avd-01/providers/Microsoft.DesktopVirtualization/hostPools/hp-avd-pooled-01", "vmResourceGroupId": "/subscriptions/.../resourceGroups/rg-avd-vms-01", "hostPoolType": "Pooled" }
  { "hostPoolResourceId": "/subscriptions/.../resourceGroups/rg-avd-02/providers/Microsoft.DesktopVirtualization/hostPools/hp-avd-personal-01", "vmResourceGroupId": "/subscriptions/.../resourceGroups/rg-avd-vms-02", "hostPoolType": "Personal" }
]
''')
param hostPoolInfo array

// ================================================================================================
// Storage (optional)
// ================================================================================================

@description('Optional. Resource IDs of Azure Files storage accounts used for FSLogix profile storage. When provided, metric and log-based storage alerts are deployed.')
param storageAccountResourceIds array = []

// ================================================================================================
// Azure NetApp Files (optional)
// ================================================================================================

@description('Optional. Resource IDs of Azure NetApp Files volumes used for FSLogix profile storage. When provided, ANF volume capacity alerts are deployed.')
param anfVolumeResourceIds array = []

// ================================================================================================
// Automation Account / Runbooks
// ================================================================================================

@description('Optional. Explicit name override for the Automation Account. When empty, the auto-generated name is used: aa-avd-alerts-{regionAbbr}.')
param automationAccountNameOverride string = ''


@description('''Optional. URI of the AvdStorageLogData runbook PS1 file.
Defaults to the public FederalAVD GitHub repository.

For air-gapped or internet-restricted environments, set this to empty (\'\') to skip automatic
publishing. The runbook will be created in an unpublished (New) state and must be published
manually via the Portal before the first scheduled run.''')
param runbookContentUriStorage string = 'https://raw.githubusercontent.com/Azure/FederalAVD/main/deployments/add-ons/avdAlerts/scripts/Get-StorAcctInfo.ps1'

@description('Optional. UTC timestamp used to compute the first schedule start time. Defaults to deployment time.')
param deploymentTime string = utcNow()

@description('''Optional. Set to true on first deployment to let ARM create the job schedule links.
Set to false on all redeployments. Azure Automation caches job schedule associations by account name
and raises a Conflict error if ARM tries to create a link that already exists.''')
param createJobSchedules bool = true

// ================================================================================================
// Alert Category Enable/Disable
// ================================================================================================

@description('Optional. When false, host pool capacity alert rules (50%, 85%, 95%) are not deployed.')
param enableCapacityAlerts bool = true

@description('Optional. When false, host availability and VM health alert rules are not deployed.')
param enableAvailabilityAlerts bool = true

@description('Optional. When false, user connection failure and disconnected session alert rules are not deployed.')
param enableConnectionAlerts bool = true

@description('Optional. When false, session host local disk free-space alert rules are not deployed.')
param enableLocalDiskAlerts bool = true

@description('Optional. When false, FSLogix profile alert rules are not deployed.')
param enableFslogixAlerts bool = true

@description('Optional. When false, session host VM CPU alert rules are not deployed.')
param enableCpuAlerts bool = true

@description('Optional. When false, session host VM available memory alert rules are not deployed.')
param enableMemoryAlerts bool = true

@description('Optional. Minutes of Perf data stream age required before memory alerts fire. A VM whose oldest Perf record in the 1-hour lookback window is newer than this value is treated as still starting up and excluded. Set to 0 to disable.')
@minValue(0)
@maxValue(60)
param memoryAlertStartupExclusionMinutes int = 20

@description('Optional. When false, session host VM OS disk bandwidth alert rules are not deployed.')
param enableOsDiskAlerts bool = true

@description('Optional. When false, Azure Files storage latency alert rules are not deployed.')
param enableStorageLatencyAlerts bool = true

@description('Optional. When false, Azure Files storage availability alert rules are not deployed.')
param enableStorageAvailabilityAlerts bool = true

@description('Optional. When false, Azure Files file share throttling alert rules are not deployed.')
param enableStorageThrottlingAlerts bool = true

@description('Optional. When false, ANF volume capacity alert rules are not deployed.')
param enableAnfCapacityAlerts bool = true

@description('Optional. When false, Azure Service Health activity log alert rules are not deployed.')
param enableServiceHealthAlerts bool = true

// ========== //
// Variables  //
// ========== //

var cloud                 = toLower(az.environment().name)
var locationsObject       = loadJsonContent('../../../.common/data/locations.json')
var locationsEnvProperty  = startsWith(cloud, 'us') ? 'other' : cloud
var locations             = locationsObject[locationsEnvProperty]
var regionAbbr            = locations[location].abbreviation
var resourceAbbreviations = loadJsonContent('../../../.common/data/resourceAbbreviations.json')

var automationAccountName = !empty(automationAccountNameOverride)
  ? automationAccountNameOverride
  : '${resourceAbbreviations.automationAccounts}-avd-alerts-${regionAbbr}'

var hasStorageAccounts = !empty(storageAccountResourceIds)

// Build a JSON array string of storage account resource IDs for the automation variable
var storageAccountResourceIdsJson = string(storageAccountResourceIds)

// Extract unique storage resource group pairs: subscriptionId,resourceGroupName
var storageRgPairs = [for id in storageAccountResourceIds: '${split(id, '/')[2]},${split(id, '/')[4]}']

var deploymentSuffix = take(uniqueString(subscription().subscriptionId, resourceGroupName, deployment().name), 8)

var lawSubscriptionId = split(logAnalyticsWorkspaceResourceId, '/')[2]
var lawResourceGroup  = split(logAnalyticsWorkspaceResourceId, '/')[4]

// Deduplicate hostPoolInfo by hostPoolResourceId (keep first occurrence of each)
var hostPoolInfoDeduped = reduce(
  hostPoolInfo,
  [],
  (acc, item) => contains(map(acc, (e) => e.hostPoolResourceId), item.hostPoolResourceId) ? acc : concat(acc, [item])
)

// Deduplicate by vmResourceGroupId for VM metric alerts - multiple host pools may share
// a single VM resource group and must produce only one set of metric alert rules.
var vmRgInfoDeduped = reduce(
  hostPoolInfoDeduped,
  [],
  (acc, item) => contains(map(acc, (e) => e.vmResourceGroupId), item.vmResourceGroupId) ? acc : concat(acc, [item])
)

// ========== //
// Resources  //
// ========== //

// ------------------------------------------------------------------------------------------------
// Resource Group
// ------------------------------------------------------------------------------------------------

resource newResourceGroup 'Microsoft.Resources/resourceGroups@2022-09-01' = if (createResourceGroup) {
  name: resourceGroupName
  location: location
  tags: tags
}

resource existingResourceGroup 'Microsoft.Resources/resourceGroups@2022-09-01' existing = if (!createResourceGroup) {
  name: resourceGroupName
}

// ------------------------------------------------------------------------------------------------
// Automation Account
// ------------------------------------------------------------------------------------------------

module automationAccountDeploy 'modules/automationAccount.bicep' = if (hasStorageAccounts) {
  name: 'AvdAlerts-AutomationAccount-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    automationAccountName: automationAccountName
    location: location
    tags: tags
    resourceManagerUri: az.environment().resourceManager
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    runbookStorageUri: runbookContentUriStorage
    hasStorageAccounts: hasStorageAccounts
    storageAccountResourceIdsJson: storageAccountResourceIdsJson
    deploymentTime: deploymentTime
    createJobSchedules: createJobSchedules
  }
  dependsOn: createResourceGroup ? [newResourceGroup] : [existingResourceGroup]
}

// ------------------------------------------------------------------------------------------------
// Role Assignments for Automation Account Managed Identity
// ------------------------------------------------------------------------------------------------

// Log Analytics Contributor - on the LAW resource group
module roleAssignLogAnalytics 'modules/roleAssignment.bicep' = if (hasStorageAccounts) {
  name: 'AvdAlerts-RoleAssign-LAW-${deploymentSuffix}'
  scope: resourceGroup(lawSubscriptionId, lawResourceGroup)
  params: {
    #disable-next-line BCP318
    principalId: automationAccountDeploy.outputs.principalId!
    roleDefinitionId: '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
    resourceGroupName: lawResourceGroup
    nameSuffix: automationAccountName
  }
}

// Storage Account Contributor - on each unique storage resource group
module roleAssignStorage 'modules/roleAssignment.bicep' = [for (rgPair, i) in storageRgPairs: {
  name: 'AvdAlerts-RoleAssign-Stor${i}-${deploymentSuffix}'
  scope: resourceGroup(split(rgPair, ',')[0], split(rgPair, ',')[1])
  params: {
    #disable-next-line BCP318
    principalId: automationAccountDeploy.outputs.principalId!
    roleDefinitionId: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
    resourceGroupName: split(rgPair, ',')[1]
    nameSuffix: '${automationAccountName}-stor${i}'
  }
}]

// ------------------------------------------------------------------------------------------------
// Per-Host-Pool Alert Rules
// ------------------------------------------------------------------------------------------------

module hostPoolLogAlerts 'modules/hostPoolAlerts.bicep' = [for hp in hostPoolInfoDeduped: {
  name: 'AvdAlerts-HP-${last(split(hp.hostPoolResourceId, '/'))}-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    hostPoolName: last(split(hp.hostPoolResourceId, '/'))
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    actionGroupResourceId: actionGroupResourceId
    alertNamePrefix: alertNamePrefix
    autoResolveAlert: autoResolveAlert
    location: location
    enableCapacityAlerts: enableCapacityAlerts
    enableAvailabilityAlerts: enableAvailabilityAlerts
    enableConnectionAlerts: enableConnectionAlerts
    enableFslogixAlerts: enableFslogixAlerts
    hostPoolType: hp.?hostPoolType ?? 'Pooled'
    hostPoolResourceId: hp.hostPoolResourceId
  }
  dependsOn: createResourceGroup ? [newResourceGroup] : [existingResourceGroup]
}]

// Per-VM-resource-group metric alerts - centralized in the monitoring resource group.
// Deduplicated by vmResourceGroupId - one set of rules per unique VM RG.
module vmAlerts 'modules/vmAlerts.bicep' = [for hp in vmRgInfoDeduped: {
  name: 'AvdAlerts-VM-${last(split(hp.vmResourceGroupId, '/'))}-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    hostPoolName: last(split(hp.hostPoolResourceId, '/'))
    vmResourceGroupId: hp.vmResourceGroupId
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    actionGroupResourceId: actionGroupResourceId
    alertNamePrefix: alertNamePrefix
    autoResolveAlert: autoResolveAlert
    location: location
    enableCpuAlerts: enableCpuAlerts
    enableOsDiskAlerts: enableOsDiskAlerts
    enableLocalDiskAlerts: enableLocalDiskAlerts
    enableMemoryAlerts: enableMemoryAlerts
    memoryAlertStartupExclusionMinutes: memoryAlertStartupExclusionMinutes
    hostPoolResourceId: hp.hostPoolResourceId
  }
  dependsOn: createResourceGroup ? [newResourceGroup] : [existingResourceGroup]
}]

// ------------------------------------------------------------------------------------------------
// Storage Alert Rules
// ------------------------------------------------------------------------------------------------

module storageAlerts 'modules/storageAlerts.bicep' = [for (storId, i) in storageAccountResourceIds: {
  name: 'AvdAlerts-Stor${i}-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    storageAccountResourceId: storId
    actionGroupResourceId: actionGroupResourceId
    alertNamePrefix: alertNamePrefix
    autoResolveAlert: autoResolveAlert
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    // Only create the log-based space alert rules once (on the first storage account)
    createStorageLogAlerts: i == 0
    enableStorageLatencyAlerts: enableStorageLatencyAlerts
    enableStorageAvailabilityAlerts: enableStorageAvailabilityAlerts
    enableStorageThrottlingAlerts: enableStorageThrottlingAlerts
  }
  dependsOn: createResourceGroup ? [newResourceGroup] : [existingResourceGroup]
}]

// ------------------------------------------------------------------------------------------------
// ANF Volume Alert Rules
// ------------------------------------------------------------------------------------------------

module anfAlerts 'modules/anfAlerts.bicep' = [for (anfId, i) in anfVolumeResourceIds: {
  name: 'AvdAlerts-ANF${i}-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    anfVolumeResourceId: anfId
    actionGroupResourceId: actionGroupResourceId
    alertNamePrefix: alertNamePrefix
    autoResolveAlert: autoResolveAlert
    enableAnfCapacityAlerts: enableAnfCapacityAlerts
  }
  dependsOn: createResourceGroup ? [newResourceGroup] : [existingResourceGroup]
}]

// ------------------------------------------------------------------------------------------------
// Service Health Alert Rules
// ------------------------------------------------------------------------------------------------

module serviceHealthAlerts 'modules/serviceHealthAlerts.bicep' = {
  name: 'AvdAlerts-SvcHealth-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    actionGroupResourceId: actionGroupResourceId
    alertNamePrefix: alertNamePrefix
    enableServiceHealthAlerts: enableServiceHealthAlerts
  }
  dependsOn: createResourceGroup ? [newResourceGroup] : [existingResourceGroup]
}
