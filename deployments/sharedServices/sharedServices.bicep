targetScope = 'subscription'

// Deploys the AVD Key Vault prerequisites into the operations resource group: a Secrets Key Vault for
// credentials (domain join, VM admin) and an Encryption Key Vault for Customer Managed Key (CMK) encryption.
// Deploy this before any AVD solution that uses CMK or references a pre-provisioned credentials Key Vault.

// ── Location & Naming ──────────────────────────────────────────────────────────

@description('Required. The Azure region for all foundation resources.')
param location string = deployment().location

@description('Optional. Existing resource group used for operations, monitoring, and a newly created AVD workspace. The caller must create it before this deployment. Global-feed resources remain separately scoped.')
param consolidatedResourceGroupName string = ''

// ── Secrets Key Vault ──────────────────────────────────────────────────────────

@description('Optional. Deploy the Secrets Key Vault (Standard SKU) for storing AVD credentials (VM admin password, domain join credentials).')
param deploySecretsKeyVault bool = true

@description('Optional. Existing Shared Services secrets Key Vault resource ID. When supplied, no secrets Key Vault is created and this ID is returned to consumers.')
#disable-next-line secure-secrets-in-params
param existingSecretsKeyVaultResourceId string = ''

@description('Optional. Enable soft delete on the Secrets Key Vault.')
param secretsKeyVaultEnableSoftDelete bool = true

@description('Optional. Enable purge protection on the Secrets Key Vault. Recommended for production environments.')
param secretsKeyVaultEnablePurgeProtection bool = true

@description('Optional. The retention period in days for soft-deleted objects in the Secrets Key Vault. Use 7 in test environments to minimise the wait before a deleted vault name can be reused; keep 90 in production.')
@minValue(7)
@maxValue(90)
param secretsKeyVaultRetentionInDays int = 90

// ── Credential Secrets (Optional — Security Team Owned) ───────────────────────
// Providing these values stores them in the Secrets Key Vault at foundation deployment time.
// Solution deployers (host pool, add-ons) only need the KV resource ID as a reference —
// they do not require read/write access to the secrets themselves.
// NOTE: If using ARM getSecret() references in downstream deployments, the deploying identity
// requires the 'Key Vault Secrets User' role on the Secrets Key Vault.

@secure()
@description('Optional. Virtual machine local administrator password. Stored as VirtualMachineAdminPassword in the Secrets Key Vault.')
param virtualMachineAdminPassword string = ''

@secure()
@description('Optional. Virtual machine local administrator username. Stored as VirtualMachineAdminUserName in the Secrets Key Vault.')
param virtualMachineAdminUserName string = ''

@secure()
@description('Optional. Domain join user password. Stored as DomainJoinUserPassword in the Secrets Key Vault.')
param domainJoinUserPassword string = ''

@secure()
@description('Optional. Domain join user principal name (UPN). Stored as DomainJoinUserPrincipalName in the Secrets Key Vault.')
param domainJoinUserPrincipalName string = ''

// ── Encryption Key Vault ───────────────────────────────────────────────────────
// Required for all AVD solutions using Customer-Managed Keys:
//   - Host Pool (disk encryption sets, FSLogix storage)
//   - Image Management (artifacts storage)
//   - Image Build (logs storage)
//   - Session Host Replacer / Storage Quota Manager (function app storage)
//
// REQUIRED RBAC for deploying identities on this Key Vault:
//   - 'Key Vault Crypto Officer' role — required to create encryption keys via the CMK module.
//     This role is needed at deployment time only; it can be removed after initial key creation
//     if key rotation is handled separately.

@description('Optional. Deploy the Encryption Key Vault (Premium SKU) for Customer-Managed Keys. Required when using CMK in any AVD solution.')
param deployEncryptionKeyVault bool = true

@description('Optional. Existing Shared Services encryption Key Vault resource ID. When supplied, no encryption Key Vault is created and this ID is returned to consumers.')
param existingEncryptionKeyVaultResourceId string = ''

@description('Optional. Soft delete retention days for the Encryption Key Vault. Use 7 in test environments to minimise the wait before a deleted vault name can be reused; keep 90 in production.')
@minValue(7)
@maxValue(90)
param encryptionKeyVaultRetentionInDays int = 90

// ── Private Endpoints ──────────────────────────────────────────────────────────

@description('Optional. Deploy private endpoints for the Key Vaults. When true, public network access is disabled on both Key Vaults.')
param privateEndpoint bool = false

@description('Conditional. The resource ID of the subnet for Key Vault private endpoints. Required when privateEndpoint is true.')
param privateEndpointSubnetResourceId string = ''

@description('Conditional. The resource ID of the Azure Key Vault Private DNS Zone. Required when privateEndpoint is true.')
param azureKeyVaultPrivateDnsZoneResourceId string = ''

// ── Permitted IPs ─────────────────────────────────────────────────────────────

@description('Optional. Array of permitted IP addresses or CIDR blocks allowed through the firewall of all Key Vaults deployed by this module. Use when managing from a trusted workstation outside the Azure network boundary.')
param permittedIPs array = []

// ── Monitoring ─────────────────────────────────────────────────────────────────

@description('Optional. Deploy a Log Analytics Workspace, AVD Insights Data Collection Rule, and Data Collection Endpoint into a dedicated monitoring resource group. Their resource IDs are returned as "logAnalyticsWorkspaceResourceId", "avdInsightsDataCollectionRuleResourceId", and "dataCollectionEndpointResourceId" - pass those to "existingLogAnalyticsWorkspaceResourceId", "existingAVDInsightsDataCollectionRuleResourceId", and "existingDataCollectionEndpointResourceId" on the host pool deployment (and "logAnalyticsWorkspaceResourceId" to the Image Management deployment) so every AVD solution shares one workspace and one DCE/DCR instead of the first host pool deployment creating its own.')
param deployMonitoring bool = false

@description('Optional. The subscription ID where the Log Analytics Workspace and related monitoring resources will be deployed. If not provided, the operations subscription is used.')
param logAnalyticsWorkspaceSubscriptionId string = ''

@description('Optional. The pricing tier for the deployed Log Analytics Workspace.')
param logAnalyticsWorkspaceSku string = 'PerGB2018'

@description('Optional. The data retention period in days for the deployed Log Analytics Workspace.')
@minValue(30)
@maxValue(730)
param logAnalyticsWorkspaceRetentionInDays int = 30

@description('Optional. The resource ID of an existing Log Analytics Workspace for Key Vault diagnostic logs. Ignored when "deployMonitoring" is true - the newly deployed workspace is used instead.')
param existingLogAnalyticsWorkspaceResourceId string = ''

@description('Optional. Existing AVD Insights Data Collection Rule resource ID returned to consuming host-pool deployments when monitoring is adopted.')
param existingAVDInsightsDataCollectionRuleResourceId string = ''

@description('Optional. Existing Data Collection Endpoint resource ID returned to consuming host-pool deployments when monitoring is adopted.')
param existingDataCollectionEndpointResourceId string = ''

@description('Optional. The resource ID of an existing Azure Monitor Private Link Scope (AMPLS) to associate with the deployed Log Analytics Workspace and Data Collection Endpoint. The AMPLS, private endpoint, access modes, and DNS configuration must be managed by the networking platform. Ignored when "deployMonitoring" is false.')
param azureMonitorPrivateLinkScopeResourceId string = ''

// ── Shared AVD Workspace ──────────────────────────────────────────────────────

@description('Optional. Create or update and manage a shared AVD workspace in the AVD control-plane resource group.')
param manageAvdWorkspace bool = false

@allowed([
  'Create'
  'Update'
])
@description('Optional. Create a shared AVD workspace, or update an existing workspace while preserving all application group references.')
param avdWorkspaceMode string = 'Create'

@description('Conditional. Existing AVD workspace resource ID. Required when avdWorkspaceMode is Update.')
param existingAvdWorkspaceResourceId string = ''

@description('Optional. Friendly name for a newly created shared AVD workspace.')
param avdWorkspaceFriendlyName string = ''

@description('Optional. Complete resource-group name override for a newly created AVD workspace. Use this to give a PoC workspace a host-pool-specific lifecycle boundary.')
param avdControlPlaneResourceGroupNameOverride string = ''

@description('Optional. Complete name override for a newly created AVD workspace.')
param avdWorkspaceNameOverride string = ''

@description('Optional. Public network access mode managed on the shared AVD workspace.')
param avdWorkspacePublicNetworkAccess 'Disabled' | 'Enabled' = 'Enabled'

@description('Optional. Subnet resource ID for the deterministically named workspace feed private endpoint. Empty disables feed endpoint management.')
param workspaceFeedPrivateEndpointSubnetResourceId string = ''

@description('Optional. AVD feed Private DNS zone resource ID for the workspace feed private endpoint.')
param avdPrivateDnsZoneResourceId string = ''

@description('Optional. Create or update and manage the global-feed workspace and its deterministically named private endpoint.')
param manageGlobalAvdWorkspace bool = false

@allowed([
  'Create'
  'Update'
])
@description('Optional. Create a global-feed workspace, or update an existing global-feed workspace while preserving all application group references.')
param globalAvdWorkspaceMode string = 'Create'

@description('Conditional. Existing global-feed workspace resource ID. Required when globalAvdWorkspaceMode is Update.')
param existingGlobalAvdWorkspaceResourceId string = ''

@description('Optional. Complete resource-group name override for a newly created global-feed workspace.')
param globalFeedResourceGroupNameOverride string = ''

@description('Optional. Complete name override for a newly created global-feed workspace.')
param globalFeedWorkspaceNameOverride string = ''

@description('Conditional. Subnet resource ID for the deterministically named global-feed private endpoint. Required when manageGlobalAvdWorkspace is true.')
param globalFeedPrivateEndpointSubnetResourceId string = ''

@description('Optional. AVD global-feed Private DNS zone resource ID.')
param globalFeedPrivateDnsZoneResourceId string = ''

// FSLogix Backup

@description('Optional. Deploy a shared Recovery Services vault and Azure Files snapshot backup policy for FSLogix storage. The vault is shared by pooled host pools and standalone FSLogix storage deployments in this subscription and region.')
param deployFSLogixBackupVault bool = false

@description('Optional. Existing shared FSLogix Recovery Services vault resource ID. When supplied, no backup vault or policy is created.')
param existingFSLogixBackupVaultResourceId string = ''

@description('Optional. Existing Azure Files backup policy name in existingFSLogixBackupVaultResourceId.')
param existingFSLogixBackupPolicyName string = 'filesharepolicy'

@description('Optional. Name of the shared Azure Files snapshot backup policy.')
param fslogixBackupPolicyName string = 'filesharepolicy'

@description('Optional. Number of daily Azure Files snapshots retained by the shared backup policy.')
@minValue(1)
@maxValue(200)
param fslogixBackupRetentionDays int = 30

@description('Optional. Time zone used by the shared Azure Files snapshot backup policy.')
param fslogixBackupTimeZone string = 'UTC'

@description('Conditional. Resource ID of the Azure Backup private DNS zone used by the FSLogix backup vault private endpoint.')
param azureBackupPrivateDnsZoneResourceId string = ''

@description('Conditional. Resource ID of the Azure Blob private DNS zone used by the FSLogix backup vault private endpoint.')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Conditional. Resource ID of the Azure Queue private DNS zone used by the FSLogix backup vault private endpoint.')
param azureQueuePrivateDnsZoneResourceId string = ''

// ── Tags ───────────────────────────────────────────────────────────────────────

@description('Optional. Tags to apply to deployed resources, keyed by resource type (e.g., "Microsoft.KeyVault/vaults", "Microsoft.Resources/resourceGroups").')
param tags object = {}

// ── Non-Specified Values ───────────────────────────────────────────────────────

@description('''Optional. Naming convention controlling how all resources in this deployment are named.
The default value produces names aligned with the Cloud Adoption Framework (CAF) naming convention: resourceType-workload-purpose-location.
Note: 'purpose' is a FederalAVD addition with no direct CAF equivalent — it provides per-resource uniqueness within a deployment.
Component requirements:
  purpose      — REQUIRED. Two Key Vaults are deployed (secrets and encryption). Without 'purpose' they
                 produce identical names and the deployment fails.
  resourceType — Strongly recommended. Without it resource names carry no type identifier.
  location     — Optional. When omitted the location abbreviation is still added to unique-string seeds
                 so cross-region deployments produce distinct Key Vault names, but the location segment
                 will not appear in resource names.
  workload, freeform1, environment, freeform2 — Optional static tokens.
Key properties:
  components          — ordered array of name components, e.g. ["resourceType","workload","purpose","location"]
  delimiter           — character inserted between components, e.g. "-"
  workload            — solution identifier inserted into names, e.g. "avd"
  freeform1, environment, freeform2 — optional static/context tokens
  locationAbbreviation — override for the region abbreviation
  resourceTypeCodes   — object with per-resource-type abbreviation overrides
    { resourceGroups, keyVaults, logAnalyticsWorkspaces, dataCollectionEndpoints, workspaces, privateEndpoints, networkInterfaces }
This object is produced automatically when deploying via the Azure Portal UI.
When deploying via ARM/Bicep CLI, omit to accept the defaults or override individual properties.''')
param namingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

@description('Optional. Complete name override for the Secrets Key Vault. When empty, the name is generated from namingConvention.')
@maxLength(24)
#disable-next-line secure-secrets-in-params
param secretsKeyVaultNameOverride string = ''

@description('Optional. Complete name override for the Encryption Key Vault. When empty, the name is generated from namingConvention.')
@maxLength(24)
param encryptionKeyVaultNameOverride string = ''

// ── Naming Convention ──────────────────────────────────────────────────────────

var cloud = toLower(environment().name)
// Account for air-gapped cloud location prefixes (us-gov, us-sec, etc.)
#disable-next-line BCP329
var varLocation = startsWith(cloud, 'us') ? substring(location, 5, length(location) - 5) : location
var locations = startsWith(cloud, 'us')
  ? (loadJsonContent('../shared/data/locations.json')).other
  : (loadJsonContent('../shared/data/locations.json'))[environment().name]
var resourceAbbreviations = loadJsonContent('../shared/data/resourceAbbreviations.json')

var identifier = 'operations'
var effectiveLogAnalyticsWorkspaceSubscription = empty(logAnalyticsWorkspaceSubscriptionId)
  ? subscription().subscriptionId
  : logAnalyticsWorkspaceSubscriptionId
var createSecretsKeyVault = deploySecretsKeyVault && empty(existingSecretsKeyVaultResourceId)
var createEncryptionKeyVault = deployEncryptionKeyVault && empty(existingEncryptionKeyVaultResourceId)
var createFSLogixBackupVault = deployFSLogixBackupVault && empty(existingFSLogixBackupVaultResourceId)
var deployOperationsResourceGroup = createSecretsKeyVault || createEncryptionKeyVault || createFSLogixBackupVault

#disable-next-line BCP329
var locationAbbreviation = locations[varLocation].abbreviation

// ── Naming convention ────────────────────────────────────────────────────────
// Default: Cloud Adoption Framework (CAF) — resourceType-workload-purpose-location.
// Override any component via the namingConvention parameter.

var cnv_delimiter      = namingConvention.?delimiter  ?? '-'
var cnv_loc      = !empty(namingConvention.?locationAbbreviation ?? '')
  ? namingConvention.locationAbbreviation
  : locationAbbreviation
var cnv_rtCodes  = namingConvention.?resourceTypeCodes ?? {
  resourceGroups: resourceAbbreviations.resourceGroups
  keyVaults: resourceAbbreviations.keyVaults
  recoveryServicesVaults: resourceAbbreviations.recoveryServicesVaults
  logAnalyticsWorkspaces: resourceAbbreviations.logAnalyticsWorkspaces
  dataCollectionEndpoints: resourceAbbreviations.dataCollectionEndpoints
  workspaces: resourceAbbreviations.workspaces
  privateEndpoints: resourceAbbreviations.privateEndpoints
  networkInterfaces: resourceAbbreviations.networkInterfaces
}
var cnv_components = namingConvention.?components ?? ['resourceType', 'workload', 'purpose', 'location']
// RT is last only when resourceType is explicitly the last non-'none' component.
var cnv_rtFirst  = !empty(cnv_components) ? (last(filter(cnv_components, s => s != 'none')) != 'resourceType') : true

func resolveComponent(comp string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  comp == 'resourceType' ? rtCode
    : comp == 'purpose' ? component
    : comp == 'location'  ? loc
    : comp == 'freeform1'     ? ff1
    : comp == 'environment'   ? env
    : comp == 'freeform2' ? ff2
    : comp == 'workload'  ? workload
    : ''

func buildCustomName(components array, delimiter string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  join(
    filter(
      map(components, comp => resolveComponent(comp, rtCode, component, loc, ff1, env, ff2, workload)),
      s => !empty(s)
    ),
    delimiter
  )

// Key Vault names allow hyphens but not underscores or dots — replace them.
func kvSanitize(s string) string =>
  replace(replace(s, '_', '-'), '.', '-')

var customRgName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.resourceGroups,
  identifier,
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)
// ─────────────────────────────────────────────────────────────────────────────

// Resource group and resource naming now always use buildCustomName via cnv_components.

// Private endpoint naming conventions — follows the same resource-type-first/last convention as all other resources
var privateEndpointNameConv = cnv_rtFirst
  ? '${cnv_rtCodes.privateEndpoints}-RESOURCE-SUBRESOURCE-VNETID'
  : 'RESOURCE-SUBRESOURCE-VNETID-${cnv_rtCodes.privateEndpoints}'
var privateEndpointNICNameConv = cnv_rtFirst
  ? '${cnv_rtCodes.?networkInterfaces ?? resourceAbbreviations.networkInterfaces}-${cnv_rtCodes.privateEndpoints}-RESOURCE-SUBRESOURCE-VNETID'
  : 'RESOURCE-SUBRESOURCE-VNETID-${cnv_rtCodes.privateEndpoints}-${cnv_rtCodes.?networkInterfaces ?? resourceAbbreviations.networkInterfaces}'

var operationsResourceGroupName = !empty(consolidatedResourceGroupName) ? consolidatedResourceGroupName : customRgName

// Monitoring resource group and Log Analytics Workspace name - only used when deployMonitoring is true.
var generatedMonitoringResourceGroupName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.resourceGroups,
  'monitoring',
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)
var monitoringResourceGroupName = !empty(consolidatedResourceGroupName)
  ? consolidatedResourceGroupName
  : generatedMonitoringResourceGroupName

// No purpose component - matches the single-workspace naming the host pool deployment's inline
// monitoring module produces, so both paths agree on the same Log Analytics Workspace name.
var logAnalyticsWorkspaceName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.?logAnalyticsWorkspaces ?? resourceAbbreviations.logAnalyticsWorkspaces,
  '',
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)

// No purpose component - matches the host pool deployment's inline monitoring module naming.
var dataCollectionEndpointName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.?dataCollectionEndpoints ?? resourceAbbreviations.dataCollectionEndpoints,
  '',
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)

var generatedControlPlaneResourceGroupName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.resourceGroups,
  'control${cnv_delimiter}plane',
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)

var generatedAvdWorkspaceName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.?workspaces ?? resourceAbbreviations.workspaces,
  '',
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)

var generatedGlobalFeedResourceGroupName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.resourceGroups,
  'global${cnv_delimiter}feed',
  '',
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)

var generatedGlobalFeedWorkspaceName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.?workspaces ?? resourceAbbreviations.workspaces,
  'global${cnv_delimiter}feed',
  '',
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)

var controlPlaneResourceGroupName = !empty(consolidatedResourceGroupName)
  ? consolidatedResourceGroupName
  : !empty(avdControlPlaneResourceGroupNameOverride)
      ? avdControlPlaneResourceGroupNameOverride
      : generatedControlPlaneResourceGroupName
var avdWorkspaceName = !empty(avdWorkspaceNameOverride) ? avdWorkspaceNameOverride : generatedAvdWorkspaceName
var globalFeedResourceGroupName = !empty(globalFeedResourceGroupNameOverride)
  ? globalFeedResourceGroupNameOverride
  : generatedGlobalFeedResourceGroupName
var globalFeedWorkspaceName = !empty(globalFeedWorkspaceNameOverride)
  ? globalFeedWorkspaceNameOverride
  : generatedGlobalFeedWorkspaceName

// Stable 6-char unique string seeded on subscription + resource group name.
// Add location to the seed when the convention has no location component,
// so deployments to different regions don't produce identical Key Vault names.
// CAF fallback already embeds the location abbreviation in the name itself.
var uniqueStringOperations = take(
  !contains(cnv_components, 'location')
    ? uniqueString(subscription().subscriptionId, operationsResourceGroupName, location)
    : uniqueString(subscription().subscriptionId, operationsResourceGroupName),
  6
)
var effectiveSecretsKeyVaultNameOverride = !empty(secretsKeyVaultNameOverride)
  ? secretsKeyVaultNameOverride
  : namingConvention.?secretsKeyVaultNameOverride ?? ''
var effectiveEncryptionKeyVaultNameOverride = !empty(encryptionKeyVaultNameOverride)
  ? encryptionKeyVaultNameOverride
  : namingConvention.?encryptionKeyVaultNameOverride ?? ''

// Unique string is embedded in the purpose slot so the final name matches the original CAF pattern:
// kv-avd-sec-{unique}-use  (RT-first)  /  avd-sec-{unique}-use-kv  (RT-last)
// kvSanitize strips underscores/dots — the result always uses hyphens regardless of delimiter.
var secretsKeyVaultName = !empty(effectiveSecretsKeyVaultNameOverride)
  ? effectiveSecretsKeyVaultNameOverride
  : take(kvSanitize(buildCustomName(filter(cnv_components, s => s != 'none'), cnv_delimiter, cnv_rtCodes.keyVaults, 'sec-${uniqueStringOperations}', cnv_loc, namingConvention.?freeform1 ?? '', namingConvention.?environment ?? '', namingConvention.?freeform2 ?? '', !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd')), 24)

var encryptionKeyVaultName = !empty(effectiveEncryptionKeyVaultNameOverride)
  ? effectiveEncryptionKeyVaultNameOverride
  : take(kvSanitize(buildCustomName(filter(cnv_components, s => s != 'none'), cnv_delimiter, cnv_rtCodes.keyVaults, 'enc-${uniqueStringOperations}', cnv_loc, namingConvention.?freeform1 ?? '', namingConvention.?environment ?? '', namingConvention.?freeform2 ?? '', !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd')), 24)

var fslogixBackupVaultName = buildCustomName(
  filter(cnv_components, component => component != 'none'),
  cnv_delimiter,
  cnv_rtCodes.?recoveryServicesVaults ?? resourceAbbreviations.recoveryServicesVaults,
  'files',
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)

// ── Resource Group ─────────────────────────────────────────────────────────────

module operationsResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (deployOperationsResourceGroup && empty(consolidatedResourceGroupName)) {
  scope: subscription()
  params: {
    location: location
    name: operationsResourceGroupName
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

// ── Log Analytics Workspace ─────────────────────────────────────────────────────

module monitoringResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (deployMonitoring && empty(consolidatedResourceGroupName)) {
  scope: subscription(effectiveLogAnalyticsWorkspaceSubscription)
  params: {
    location: location
    name: monitoringResourceGroupName
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

var effectiveAzureMonitorPrivateLinkScopeResourceId = deployMonitoring ? azureMonitorPrivateLinkScopeResourceId : ''

// DCE + DCR are generic per region/workspace (not tied to any host pool) - creating them once here
// lets every host pool that reuses this workspace share the same DCE/DCR via "existingAVDInsightsDataCollectionRuleResourceId"
// and "existingDataCollectionEndpointResourceId", instead of the first host pool deployment creating them.
module monitoring '../shared/modules/orchestration/monitoring/monitoring.bicep' = if (deployMonitoring) {
  scope: subscription(effectiveLogAnalyticsWorkspaceSubscription)
  params: {
    azureMonitorPrivateLinkScopeResourceId: effectiveAzureMonitorPrivateLinkScopeResourceId
    dataCollectionEndpointName: dataCollectionEndpointName
    location: location
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    logAnalyticsWorkspaceRetention: logAnalyticsWorkspaceRetentionInDays
    logAnalyticsWorkspaceSku: logAnalyticsWorkspaceSku
    resourceGroupMonitoring: monitoringResourceGroupName
    tags: tags
  }
  dependsOn: [monitoringResourceGroup]
}

var avdWorkspaceConfigurationIsValid = !manageAvdWorkspace || avdWorkspaceMode == 'Create' && empty(existingAvdWorkspaceResourceId) || avdWorkspaceMode == 'Update' && !empty(existingAvdWorkspaceResourceId)
  ? true
  : fail('AVD workspace management requires an empty existingAvdWorkspaceResourceId for Create, or a workspace resource ID for Update.')
var globalAvdWorkspaceConfigurationIsValid = !manageGlobalAvdWorkspace || !empty(globalFeedPrivateEndpointSubnetResourceId) && (globalAvdWorkspaceMode == 'Create' && empty(existingGlobalAvdWorkspaceResourceId) || globalAvdWorkspaceMode == 'Update' && !empty(existingGlobalAvdWorkspaceResourceId))
  ? true
  : fail('Global-feed workspace management requires an endpoint subnet and an empty existingGlobalAvdWorkspaceResourceId for Create, or a workspace resource ID for Update.')

module avdWorkspace '../shared/modules/orchestration/avdWorkspace/avdWorkspace.bicep' = if ((manageAvdWorkspace || manageGlobalAvdWorkspace) && avdWorkspaceConfigurationIsValid && globalAvdWorkspaceConfigurationIsValid) {
  scope: subscription()
  params: {
    workspaceMode: avdWorkspaceMode
    manageWorkspace: manageAvdWorkspace
    workspaceName: avdWorkspaceName
    workspaceResourceId: existingAvdWorkspaceResourceId
    workspaceResourceGroupName: controlPlaneResourceGroupName
    createWorkspaceResourceGroup: empty(consolidatedResourceGroupName)
    workspaceLocation: location
    workspaceFriendlyName: avdWorkspaceFriendlyName
    workspacePublicNetworkAccess: avdWorkspacePublicNetworkAccess
    workspaceFeedPrivateEndpointSubnetResourceId: workspaceFeedPrivateEndpointSubnetResourceId
    avdPrivateDnsZoneResourceId: avdPrivateDnsZoneResourceId
    logAnalyticsWorkspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId
    manageGlobalWorkspace: manageGlobalAvdWorkspace
    globalWorkspaceMode: globalAvdWorkspaceMode
    globalWorkspaceName: globalFeedWorkspaceName
    globalWorkspaceResourceId: existingGlobalAvdWorkspaceResourceId
    globalWorkspaceResourceGroupName: globalFeedResourceGroupName
    globalFeedPrivateEndpointSubnetResourceId: globalFeedPrivateEndpointSubnetResourceId
    globalFeedPrivateDnsZoneResourceId: globalFeedPrivateDnsZoneResourceId
    privateEndpointNameConv: privateEndpointNameConv
    privateEndpointNICNameConv: privateEndpointNICNameConv
    tags: tags
  }
}

// Resolves to the newly deployed workspace when requested, otherwise falls back to whatever
// existing workspace resource ID (if any) was passed in for Key Vault diagnostic settings.
var effectiveLogAnalyticsWorkspaceResourceId = deployMonitoring
  ? monitoring!.outputs.logAnalyticsWorkspaceResourceId
  : existingLogAnalyticsWorkspaceResourceId
var effectiveAvdInsightsDataCollectionRuleResourceId = deployMonitoring
  ? monitoring!.outputs.avdInsightsDataCollectionRuleResourceId
  : existingAVDInsightsDataCollectionRuleResourceId
var effectiveDataCollectionEndpointResourceId = deployMonitoring
  ? monitoring!.outputs.dataCollectionEndpointResourceId
  : existingDataCollectionEndpointResourceId

// ── Key Vaults ─────────────────────────────────────────────────────────────────

module keyVaults '../shared/modules/orchestration/keyVaults/keyVaults.bicep' = {
  scope: subscription()
  params: {
    resourceGroupName: operationsResourceGroupName
    deploySecretsKeyVault: createSecretsKeyVault
    secretsKeyVaultName: secretsKeyVaultName
    secretsKeyVaultEnableSoftDelete: secretsKeyVaultEnableSoftDelete
    secretsKeyVaultEnablePurgeProtection: secretsKeyVaultEnablePurgeProtection
    secretsKeyVaultRetentionInDays: secretsKeyVaultRetentionInDays
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    virtualMachineAdminPassword: virtualMachineAdminPassword
    virtualMachineAdminUserName: virtualMachineAdminUserName
    deployEncryptionKeyVault: createEncryptionKeyVault
    encryptionKeyVaultName: encryptionKeyVaultName
    encryptionKeyVaultRetentionInDays: encryptionKeyVaultRetentionInDays
    privateEndpoint: privateEndpoint
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    azureKeyVaultPrivateDnsZoneResourceId: azureKeyVaultPrivateDnsZoneResourceId
    privateEndpointNameConv: privateEndpointNameConv
    privateEndpointNICNameConv: privateEndpointNICNameConv
    permittedIPs: permittedIPs
    logAnalyticsWorkspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId
    tags: tags
  }
  dependsOn: [operationsResourceGroup]
}

// Shared FSLogix Backup Vault

module fslogixBackupVault '../shared/modules/resourceModules/recoveryServices/fslogixBackupVault.bicep' = if (createFSLogixBackupVault) {
  params: {
    createVault: true
    manageBackupPolicy: true
    vaultName: fslogixBackupVaultName
    resourceGroupOperations: operationsResourceGroupName
    location: location
    logAnalyticsWorkspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId
    privateEndpoint: privateEndpoint
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    azureBackupPrivateDnsZoneResourceId: azureBackupPrivateDnsZoneResourceId
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    privateEndpointNameConv: privateEndpointNameConv
    privateEndpointNICNameConv: privateEndpointNICNameConv
    tags: tags
    timeZone: fslogixBackupTimeZone
    fileSharePolicyName: fslogixBackupPolicyName
    backupRetentionDays: fslogixBackupRetentionDays
  }
  dependsOn: [operationsResourceGroup]
}

var effectiveFSLogixBackupVaultResourceId = createFSLogixBackupVault
  ? fslogixBackupVault!.outputs.recoveryServicesVaultResourceId
  : existingFSLogixBackupVaultResourceId
var effectiveFSLogixBackupPolicyName = createFSLogixBackupVault
  ? fslogixBackupVault!.outputs.fileShareBackupPolicyName
  : (!empty(existingFSLogixBackupVaultResourceId) ? existingFSLogixBackupPolicyName : '')
var effectiveFSLogixBackupPolicyResourceId = !empty(effectiveFSLogixBackupVaultResourceId)
  ? '${effectiveFSLogixBackupVaultResourceId}/backupPolicies/${effectiveFSLogixBackupPolicyName}'
  : ''

// ── Outputs ────────────────────────────────────────────────────────────────────

@description('The name of the security resource group.')
output resourceGroupName string = deployOperationsResourceGroup ? operationsResourceGroupName : ''

@description('The name of the Secrets Key Vault. Empty if not deployed.')
output secretsKeyVaultName string = createSecretsKeyVault
  ? secretsKeyVaultName
  : (!empty(existingSecretsKeyVaultResourceId) ? last(split(existingSecretsKeyVaultResourceId, '/')) : '')

@description('The resource ID of the Secrets Key Vault. Pass as "existingCredentialsKeyVaultResourceId" to the standard host pool, or "credentialsKeyVaultResourceId" to the automated host pool, Session Host Replacer, and Session Hosts add-on deployments.')
output secretsKeyVaultResourceId string = createSecretsKeyVault
  ? keyVaults.outputs.secretsKeyVaultResourceId
  : existingSecretsKeyVaultResourceId

@description('The name of the Encryption Key Vault. Empty if not deployed.')
output encryptionKeyVaultName string = createEncryptionKeyVault
  ? encryptionKeyVaultName
  : (!empty(existingEncryptionKeyVaultResourceId) ? last(split(existingEncryptionKeyVaultResourceId, '/')) : '')

@description('The resource ID of the Encryption Key Vault. Pass as "encryptionKeyVaultResourceId" to any AVD solution using Customer-Managed Keys.')
output encryptionKeyVaultResourceId string = createEncryptionKeyVault
  ? keyVaults.outputs.encryptionKeyVaultResourceId
  : existingEncryptionKeyVaultResourceId

@description('The URI of the Encryption Key Vault.')
output encryptionKeyVaultUri string = createEncryptionKeyVault ? keyVaults.outputs.encryptionKeyVaultUri : ''

@description('The name of the monitoring resource group. Empty if the Log Analytics Workspace is not deployed.')
output monitoringResourceGroupName string = deployMonitoring ? monitoringResourceGroupName : ''

@description('The name of the Log Analytics Workspace. Empty if not deployed.')
output logAnalyticsWorkspaceName string = deployMonitoring ? logAnalyticsWorkspaceName : ''

@description('The resource ID of the Log Analytics Workspace. Empty if not deployed. Pass as "existingLogAnalyticsWorkspaceResourceId" to the host pool deployment and "logAnalyticsWorkspaceResourceId" to the Image Management deployment.')
output logAnalyticsWorkspaceResourceId string = effectiveLogAnalyticsWorkspaceResourceId

@description('The resource ID of the AVD Insights Data Collection Rule. Empty if the Log Analytics Workspace is not deployed. Pass as "existingAVDInsightsDataCollectionRuleResourceId" to the host pool deployment.')
output avdInsightsDataCollectionRuleResourceId string = effectiveAvdInsightsDataCollectionRuleResourceId

@description('The resource ID of the Data Collection Endpoint. Empty if the Log Analytics Workspace is not deployed. Pass as "existingDataCollectionEndpointResourceId" to the host pool deployment.')
output dataCollectionEndpointResourceId string = effectiveDataCollectionEndpointResourceId

@description('The resource ID of the existing Azure Monitor Private Link Scope associated with the monitoring resources. Empty when monitoring or AMPLS integration is disabled.')
output azureMonitorPrivateLinkScopeResourceId string = effectiveAzureMonitorPrivateLinkScopeResourceId

@description('The resource ID of the created or adopted shared AVD workspace. Empty when workspace management is disabled.')
output avdWorkspaceResourceId string = manageAvdWorkspace ? avdWorkspace!.outputs.workspaceResourceId : ''

@description('The resource ID of the deterministically named shared workspace feed private endpoint. Empty when feed endpoint management is disabled.')
output workspaceFeedPrivateEndpointResourceId string = manageAvdWorkspace ? avdWorkspace!.outputs.workspaceFeedPrivateEndpointResourceId : ''

@description('The resource ID of the created or adopted global-feed workspace. Empty when global-feed management is disabled.')
output globalFeedWorkspaceResourceId string = manageGlobalAvdWorkspace ? avdWorkspace!.outputs.globalWorkspaceResourceId : ''

@description('The resource ID of the deterministically named global-feed private endpoint. Empty when global-feed management is disabled.')
output globalFeedPrivateEndpointResourceId string = manageGlobalAvdWorkspace ? avdWorkspace!.outputs.globalFeedPrivateEndpointResourceId : ''

@description('The AVD control-plane resource group name. For an adopted workspace, this is the workspace existing resource group. Empty when workspace management is disabled.')
output avdControlPlaneResourceGroupName string = manageAvdWorkspace ? avdWorkspace!.outputs.controlPlaneResourceGroupName : ''

@description('The resource ID of the AVD control-plane resource group. For an adopted workspace, this is the workspace existing resource group. Empty when workspace management is disabled.')
output avdControlPlaneResourceGroupResourceId string = manageAvdWorkspace ? avdWorkspace!.outputs.controlPlaneResourceGroupResourceId : ''

@description('The resource ID of the shared FSLogix Recovery Services vault. Pass as "existingFilesBackupVaultResourceId" to standard or automated pooled host pool deployments, or "recoveryServicesVaultResourceId" to the FSLogix Storage add-on.')
output fslogixBackupVaultResourceId string = effectiveFSLogixBackupVaultResourceId

@description('The name of the shared Azure Files snapshot backup policy. Pass as "existingFilesBackupPolicyName" to standard or automated pooled host pool deployments, or "fileSharePolicyName" to the FSLogix Storage add-on.')
output fslogixBackupPolicyName string = effectiveFSLogixBackupPolicyName

@description('The resource ID of the shared Azure Files snapshot backup policy.')
output fslogixBackupPolicyResourceId string = effectiveFSLogixBackupPolicyResourceId
