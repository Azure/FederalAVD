targetScope = 'subscription'

// Deploys the AVD Key Vault prerequisites into the operations resource group: a Secrets Key Vault for
// credentials (domain join, VM admin) and an Encryption Key Vault for Customer Managed Key (CMK) encryption.
// Deploy this before any AVD solution that uses CMK or references a pre-provisioned credentials Key Vault.

// ── Location & Naming ──────────────────────────────────────────────────────────

@description('Required. The Azure region for all foundation resources.')
param location string = deployment().location

// ── Secrets Key Vault ──────────────────────────────────────────────────────────

@description('Optional. Deploy the Secrets Key Vault (Standard SKU) for storing AVD credentials (VM admin password, domain join credentials).')
param deploySecretsKeyVault bool = true

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

@description('Optional. The subscription ID where the Log Analytics Workspace (and its monitoring resource group) will be deployed. If not provided, the deployment subscription is used. Use this when a centralized monitoring/security team owns a separate subscription from the one hosting the Key Vaults.')
param logAnalyticsWorkspaceSubscriptionId string = ''

@description('Optional. The pricing tier for the deployed Log Analytics Workspace.')
param logAnalyticsWorkspaceSku string = 'PerGB2018'

@description('Optional. The data retention period in days for the deployed Log Analytics Workspace.')
@minValue(30)
@maxValue(730)
param logAnalyticsWorkspaceRetentionInDays int = 30

@description('Optional. The resource ID of an existing Log Analytics Workspace for Key Vault diagnostic logs. Ignored when "deployMonitoring" is true - the newly deployed workspace is used instead.')
param existingLogAnalyticsWorkspaceResourceId string = ''

@description('Optional. The resource ID of the Azure Monitor Private Link Scope (AMPLS) to associate the deployed Log Analytics Workspace and Data Collection Endpoint with. Ignored when "deployMonitoring" is false. There should only be one AMPLS per network that shares the same DNS.')
param azureMonitorPrivateLinkScopeResourceId string = ''

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
    { resourceGroups, keyVaults, logAnalyticsWorkspaces, dataCollectionEndpoints, privateEndpoints, networkInterfaces }
This object is produced automatically when deploying via the Azure Portal UI.
When deploying via ARM/Bicep CLI, omit to accept the defaults or override individual properties.''')
param namingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

@description('DO NOT MODIFY THIS VALUE! The timestamp is needed to differentiate deployments for certain Azure resources and must be set using a parameter.')
param timeStamp string = utcNow('yyyyMMddHHmmss')

// ── Naming Convention ──────────────────────────────────────────────────────────

var cloud = toLower(environment().name)
// Account for air-gapped cloud location prefixes (us-gov, us-sec, etc.)
#disable-next-line BCP329
var varLocation = startsWith(cloud, 'us') ? substring(location, 5, length(location) - 5) : location
var locations = startsWith(cloud, 'us')
  ? (loadJsonContent('../../.common/data/locations.json')).other
  : (loadJsonContent('../../.common/data/locations.json'))[environment().name]
var resourceAbbreviations = loadJsonContent('../../.common/data/resourceAbbreviations.json')

var deploymentSuffix = timeStamp
var identifier = 'operations'

var effectiveLogAnalyticsWorkspaceSubscription = empty(logAnalyticsWorkspaceSubscriptionId)
  ? subscription().subscriptionId
  : logAnalyticsWorkspaceSubscriptionId

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
  logAnalyticsWorkspaces: resourceAbbreviations.logAnalyticsWorkspaces
  dataCollectionEndpoints: resourceAbbreviations.dataCollectionEndpoints
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

var operationsResourceGroupName = customRgName

// Monitoring resource group and Log Analytics Workspace name - only used when deployMonitoring is true.
var monitoringResourceGroupName = buildCustomName(
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

// Unique string is embedded in the purpose slot so the final name matches the original CAF pattern:
// kv-avd-sec-{unique}-use  (RT-first)  /  avd-sec-{unique}-use-kv  (RT-last)
// kvSanitize strips underscores/dots — the result always uses hyphens regardless of delimiter.
var secretsKeyVaultName    = take(kvSanitize(buildCustomName(filter(cnv_components, s => s != 'none'), cnv_delimiter, cnv_rtCodes.keyVaults, 'sec-${uniqueStringOperations}', cnv_loc, namingConvention.?freeform1 ?? '', namingConvention.?environment ?? '', namingConvention.?freeform2 ?? '', !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd')), 24)

var encryptionKeyVaultName = take(kvSanitize(buildCustomName(filter(cnv_components, s => s != 'none'), cnv_delimiter, cnv_rtCodes.keyVaults, 'enc-${uniqueStringOperations}', cnv_loc, namingConvention.?freeform1 ?? '', namingConvention.?environment ?? '', namingConvention.?freeform2 ?? '', !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd')), 24)

// ── Resource Group ─────────────────────────────────────────────────────────────

module operationsResourceGroup '../shared/modules/resources/resourceGroups/deploy.bicep' = {
  name: 'Operations-ResourceGroup-${deploymentSuffix}'
  scope: subscription()
  params: {
    location: location
    name: operationsResourceGroupName
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

// ── Log Analytics Workspace ─────────────────────────────────────────────────────

module monitoringResourceGroup '../shared/modules/resources/resourceGroups/deploy.bicep' = if (deployMonitoring) {
  name: 'Monitoring-ResourceGroup-${deploymentSuffix}'
  scope: subscription(effectiveLogAnalyticsWorkspaceSubscription)
  params: {
    location: location
    name: monitoringResourceGroupName
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module logAnalyticsWorkspace '../shared/modules/operationalInsights/workspaces/deploy.bicep' = if (deployMonitoring) {
  name: 'Monitoring-LogAnalytics-${deploymentSuffix}'
  scope: resourceGroup(effectiveLogAnalyticsWorkspaceSubscription, monitoringResourceGroupName)
  params: {
    name: logAnalyticsWorkspaceName
    location: location
    tags: tags[?'Microsoft.OperationalInsights/workspaces'] ?? {}
    sku: logAnalyticsWorkspaceSku
    retentionInDays: logAnalyticsWorkspaceRetentionInDays
  }
  dependsOn: [monitoringResourceGroup]
}

// DCE + DCR are generic per region/workspace (not tied to any host pool) - creating them once here
// lets every host pool that reuses this workspace share the same DCE/DCR via "existingAVDInsightsDataCollectionRuleResourceId"
// and "existingDataCollectionEndpointResourceId", instead of the first host pool deployment creating them.
module dataCollectionEndpoint '../shared/modules/insights/dataCollectionEndpoints/deploy.bicep' = if (deployMonitoring) {
  name: 'Monitoring-DataCollectionEndpoint-${deploymentSuffix}'
  scope: resourceGroup(effectiveLogAnalyticsWorkspaceSubscription, monitoringResourceGroupName)
  params: {
    name: dataCollectionEndpointName
    location: location
    tags: tags[?'Microsoft.Insights/dataCollectionEndpoints'] ?? {}
    publicNetworkAccess: empty(azureMonitorPrivateLinkScopeResourceId) ? 'Enabled' : 'Disabled'
  }
  dependsOn: [monitoringResourceGroup]
}

module avdInsightsDataCollectionRule '../shared/modules/monitoring/avdInsightsDataCollectionRule.bicep' = if (deployMonitoring) {
  name: 'Monitoring-AVDInsightsDCR-${deploymentSuffix}'
  scope: resourceGroup(effectiveLogAnalyticsWorkspaceSubscription, monitoringResourceGroupName)
  params: {
    location: location
    tags: tags[?'Microsoft.Insights/dataCollectionRules'] ?? {}
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspace!.outputs.resourceId
    dataCollectionEndpointId: dataCollectionEndpoint!.outputs.resourceId
  }
}

module updatePrivateLinkScope '../shared/modules/privateLinkScope/get-PrivateLinkScope.bicep' = if (deployMonitoring && !empty(azureMonitorPrivateLinkScopeResourceId)) {
  name: 'Monitoring-PrivateLinkScope-${deploymentSuffix}'
  params: {
    deploymentSuffix: deploymentSuffix
    privateLinkScopeResourceId: azureMonitorPrivateLinkScopeResourceId
    scopedResourceIds: [
      logAnalyticsWorkspace!.outputs.resourceId
      dataCollectionEndpoint!.outputs.resourceId
    ]
  }
}

// Resolves to the newly deployed workspace when requested, otherwise falls back to whatever
// existing workspace resource ID (if any) was passed in for Key Vault diagnostic settings.
var effectiveLogAnalyticsWorkspaceResourceId = deployMonitoring
  ? logAnalyticsWorkspace!.outputs.resourceId
  : existingLogAnalyticsWorkspaceResourceId

// ── Key Vaults ─────────────────────────────────────────────────────────────────

module keyVaults '../shared/modules/keyVaults/keyVaults.bicep' = {
  name: 'Operations-KeyVaults-${deploymentSuffix}'
  scope: subscription()
  params: {
    resourceGroupName: operationsResourceGroupName
    deploySecretsKeyVault: deploySecretsKeyVault
    secretsKeyVaultName: secretsKeyVaultName
    secretsKeyVaultEnableSoftDelete: secretsKeyVaultEnableSoftDelete
    secretsKeyVaultEnablePurgeProtection: secretsKeyVaultEnablePurgeProtection
    secretsKeyVaultRetentionInDays: secretsKeyVaultRetentionInDays
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    virtualMachineAdminPassword: virtualMachineAdminPassword
    virtualMachineAdminUserName: virtualMachineAdminUserName
    deployEncryptionKeyVault: deployEncryptionKeyVault
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
    deploymentSuffix: deploymentSuffix
  }
  dependsOn: [operationsResourceGroup]
}

// ── Outputs ────────────────────────────────────────────────────────────────────

@description('The name of the security resource group.')
output resourceGroupName string = operationsResourceGroupName

@description('The name of the Secrets Key Vault. Empty if not deployed.')
output secretsKeyVaultName string = deploySecretsKeyVault ? secretsKeyVaultName : ''

@description('The resource ID of the Secrets Key Vault. Pass as "credentialsKeyVaultResourceId" to the host pool and Session Host Replacer deployments.')
output secretsKeyVaultResourceId string = deploySecretsKeyVault ? keyVaults.outputs.secretsKeyVaultResourceId : ''

@description('The name of the Encryption Key Vault. Empty if not deployed.')
output encryptionKeyVaultName string = deployEncryptionKeyVault ? encryptionKeyVaultName : ''

@description('The resource ID of the Encryption Key Vault. Pass as "encryptionKeyVaultResourceId" to any AVD solution using Customer-Managed Keys.')
output encryptionKeyVaultResourceId string = deployEncryptionKeyVault ? keyVaults.outputs.encryptionKeyVaultResourceId : ''

@description('The URI of the Encryption Key Vault.')
output encryptionKeyVaultUri string = deployEncryptionKeyVault ? keyVaults.outputs.encryptionKeyVaultUri : ''

@description('The name of the monitoring resource group. Empty if the Log Analytics Workspace is not deployed.')
output monitoringResourceGroupName string = deployMonitoring ? monitoringResourceGroupName : ''

@description('The name of the Log Analytics Workspace. Empty if not deployed.')
output logAnalyticsWorkspaceName string = deployMonitoring ? logAnalyticsWorkspaceName : ''

@description('The resource ID of the Log Analytics Workspace. Empty if not deployed. Pass as "existingLogAnalyticsWorkspaceResourceId" to the host pool deployment and "logAnalyticsWorkspaceResourceId" to the Image Management deployment.')
output logAnalyticsWorkspaceResourceId string = deployMonitoring ? logAnalyticsWorkspace!.outputs.resourceId : ''

@description('The resource ID of the AVD Insights Data Collection Rule. Empty if the Log Analytics Workspace is not deployed. Pass as "existingAVDInsightsDataCollectionRuleResourceId" to the host pool deployment.')
output avdInsightsDataCollectionRuleResourceId string = deployMonitoring ? avdInsightsDataCollectionRule!.outputs.resourceId : ''

@description('The resource ID of the Data Collection Endpoint. Empty if the Log Analytics Workspace is not deployed. Pass as "existingDataCollectionEndpointResourceId" to the host pool deployment.')
output dataCollectionEndpointResourceId string = deployMonitoring ? dataCollectionEndpoint!.outputs.resourceId : ''
