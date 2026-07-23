targetScope = 'subscription'

// ============================================================================
// Storage Quota Manager Naming Module
// Computes infrastructure resource names for a Storage Quota Manager deployment.
// No resources are deployed - this module is purely for name resolution.
//
// Location: deployments/add-ons/storageQuotaManager/modules/naming.bicep
// Called by: deployments/add-ons/storageQuotaManager/main.bicep
// ============================================================================

@description('''Naming convention controlling how infrastructure resources are named.
Should match the convention used when deploying the host pool. Pre-populated from the
hpNamingConvention tag on the host pool resource.''')
param namingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

@description('The host pool base name / identifier (e.g. desktop-01). Pre-populated from the hpIdentifier tag on the host pool resource.')
param identifier string

@description('The pre-computed region abbreviation for the function app deployment location.')
param locationAbbreviation string

@description('A 6-character unique string scoped to the storage subscription and resource group.')
param uniqueString string

// ── Naming convention resolution ──────────────────────────────────────────────
var cnv_delimiter  = namingConvention.?delimiter   ?? '-'
var cnv_components = namingConvention.?components  ?? ['resourceType', 'workload', 'purpose', 'location']
var cnv_workload   = !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
var cnv_ff1        = namingConvention.?freeform1   ?? ''
var cnv_env        = namingConvention.?environment ?? ''
var cnv_ff2        = namingConvention.?freeform2   ?? ''
var abbr           = loadJsonContent('../../../../.common/data/resourceAbbreviations.json')
var cnv_rtCodes    = contains(namingConvention, 'resourceTypeCodes')
  ? union(abbr, namingConvention.resourceTypeCodes)
  : abbr
var loc            = !empty(namingConvention.?vmsLocationAbbreviation ?? '') ? namingConvention.vmsLocationAbbreviation : locationAbbreviation

// ── User-defined functions (identical to sessionHostReplacer/modules/naming.bicep) ──────
func resolveComponent(comp string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  comp == 'resourceType' ? rtCode
    : comp == 'purpose'     ? component
    : comp == 'location'    ? loc
    : comp == 'freeform1'   ? ff1
    : comp == 'environment' ? env
    : comp == 'freeform2'   ? ff2
    : comp == 'workload'    ? workload
    : ''

func buildCustomName(components array, delimiter string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  join(
    filter(
      map(components, comp => resolveComponent(comp, rtCode, component, loc, ff1, env, ff2, workload)),
      s => !empty(s)
    ),
    delimiter
  )

func cnv(components array, delimiter string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  buildCustomName(filter(components, s => s != 'none'), delimiter, rtCode, component, loc, ff1, env, ff2, workload)

// ── RT-position detection ─────────────────────────────────────────────────────
var nameConvReversed = !empty(cnv_components) && last(filter(cnv_components, s => s != 'none')) == 'resourceType'

// ── HP-scoped names (unique per host pool via uniqueString) ───────────────────
// Purpose embeds the identifier and unique suffix so each host pool's quota manager
// resources have distinct names within the same naming convention.
var hpPurpose = '${identifier}${cnv_delimiter}sqm${cnv_delimiter}${uniqueString}'

// Storage accounts: no RT code, no delimiters (Azure requires 3-24 lowercase alphanumeric only).
// Hyphens are stripped from the identifier here because the convention delimiter stripping only
// removes the configured delimiter (e.g., '_') — embedded hyphens from the identifier would
// survive and produce an invalid storage account name when the delimiter is not '-'.
var sanitizedStorageId = replace(identifier, '-', '')
var storageRawName = cnv(cnv_components, cnv_delimiter, '', '${sanitizedStorageId}sqm${uniqueString}', loc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)

// ── Private endpoint naming conventions (template strings) ───────────────────
var peNameConv = replace(
  nameConvReversed ? 'RESOURCE-SUBRESOURCE-VNETID-RESOURCETYPE' : 'RESOURCETYPE-RESOURCE-SUBRESOURCE-VNETID',
  'RESOURCETYPE',
  cnv_rtCodes.privateEndpoints
)
var peNicNameConvTemp = nameConvReversed
  ? '${peNameConv}-RESOURCETYPE'
  : 'RESOURCETYPE-${peNameConv}'

// ── Outputs ───────────────────────────────────────────────────────────────────

// HP-scoped (unique per host pool)
output functionAppName string = take(
  cnv(cnv_components, cnv_delimiter, cnv_rtCodes.functionApps, hpPurpose, loc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload),
  60
)
output storageAccountName string = take(
  toLower(replace(storageRawName, cnv_delimiter, '')),
  24
)
output storageEncryptionIdentityName string = cnv(
  cnv_components, cnv_delimiter, cnv_rtCodes.userAssignedIdentities,
  '${identifier}${cnv_delimiter}sqm${uniqueString}${cnv_delimiter}encryption', loc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload
)

// Shared (region-scoped) — no purpose component so the ASP is reusable for any
// AVD function app in the region (e.g. session host replacer, route table updater, future add-ons).
output appServicePlanName string = cnv(
  cnv_components, cnv_delimiter, cnv_rtCodes.appServicePlans,
  '', loc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload
)

// Private endpoint naming conventions
output privateEndpointNameConv    string = peNameConv
output privateEndpointNICNameConv string = replace(peNicNameConvTemp, 'RESOURCETYPE', cnv_rtCodes.networkInterfaces)
