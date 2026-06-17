// ============================================================================
// Hostpool Naming Module
// Computes all resource names for a host pool deployment.
// No resources are deployed — this module is purely for name resolution.
//
// Location: deployments/hostpools/modules/naming.bicep
// Called by: deployments/hostpools/hostpool.bicep
// ============================================================================

@description('Naming convention overrides. Defaults produce CAF-compliant names.')
param customNamingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

@description('Azure region for VM / session host resources.')
param virtualMachinesRegion string

@description('Azure region for control plane resources (host pool, workspace, app groups).')
param controlPlaneRegion string = virtualMachinesRegion

@description('Base name for this host pool (identifier + zero-padded index, already computed by caller).')
param identifier string

@description('Global feed region. Pass empty string when there is no global feed workspace.')
param globalFeedRegion string = ''

@description('Existing feed workspace resource ID. Pass empty string when creating a new workspace.')
param existingFeedWorkspaceResourceId string = ''

targetScope = 'subscription'

// ── Location resolution ───────────────────────────────────────────────────────
var cloud      = toLower(environment().name)
var allLocs    = loadJsonContent('../../../.common/data/locations.json')
var locsEnvProp = startsWith(cloud, 'us') ? 'other' : environment().name
var locs       = allLocs[locsEnvProp]
var abbr       = loadJsonContent('../../../.common/data/resourceAbbreviations.json')

// Air-gapped clouds prefix location strings with the cloud slug (e.g. 'usgov', 'ussec').
var locationVms = startsWith(cloud, 'us')
  ? substring(virtualMachinesRegion, 5, max(length(virtualMachinesRegion) - 5, 0))
  : virtualMachinesRegion
var vmsLocAbbr  = locs[locationVms].abbreviation

var locationCP  = startsWith(cloud, 'us')
  ? substring(controlPlaneRegion, 5, max(length(controlPlaneRegion) - 5, 0))
  : controlPlaneRegion
var cpLocAbbr   = locs[locationCP].abbreviation

// ── Naming convention components ──────────────────────────────────────────────
var cnv_sep      = customNamingConvention.?delimiter    ?? '-'
var cnv_segments = customNamingConvention.?components   ?? ['resourceType', 'workload', 'purpose', 'location']
var cnv_vmsloc   = !empty(customNamingConvention.?vmsLocationAbbreviation ?? '')
  ? customNamingConvention.vmsLocationAbbreviation : vmsLocAbbr
var cnv_cploc    = !empty(customNamingConvention.?cpLocationAbbreviation  ?? '')
  ? customNamingConvention.cpLocationAbbreviation  : cpLocAbbr
var cnv_rtCodes  = contains(customNamingConvention, 'resourceTypeCodes')
  ? union(abbr, customNamingConvention.resourceTypeCodes)
  : abbr
var cnv_ff1      = customNamingConvention.?freeform1    ?? ''
var cnv_env      = customNamingConvention.?environment  ?? ''
var cnv_ff2      = customNamingConvention.?freeform2    ?? ''
var cnv_workload = !empty(customNamingConvention.?workload ?? '') ? customNamingConvention.workload : 'avd'

// ── User-defined functions ────────────────────────────────────────────────────
func resolveSegment(seg string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  seg == 'resourceType' ? rtCode
    : seg == 'purpose'     ? component
    : seg == 'location'    ? loc
    : seg == 'freeform1'   ? ff1
    : seg == 'environment' ? env
    : seg == 'freeform2'   ? ff2
    : seg == 'workload'    ? workload
    : ''

func buildCustomName(segments array, sep string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  join(
    filter(
      map(segments, seg => resolveSegment(seg, rtCode, component, loc, ff1, env, ff2, workload)),
      s => !empty(s)
    ),
    sep
  )

func stripSeps(s string) string =>
  replace(replace(replace(s, '-', ''), '_', ''), '.', '')

func cnv(segments array, sep string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  buildCustomName(filter(segments, s => s != 'none'), sep, rtCode, component, loc, ff1, env, ff2, workload)

// ── Derived flags ─────────────────────────────────────────────────────────────
// RT is considered last only when resourceType is explicitly the final non-'none' segment.
var nameConvReversed = !empty(cnv_segments) && last(filter(cnv_segments, s => s != 'none')) == 'resourceType'
var cnv_rtFirst      = !nameConvReversed

// ── Temporary Deployment Resources ───────────────────────────────────────────
var resourceGroupDeployment    = cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, '${identifier}-deployment', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var depVirtualMachineNameTemp  = stripSeps(cnv(cnv_segments, cnv_sep, '', identifier, cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload))
var depVirtualMachineName      = take('${depVirtualMachineNameTemp}${uniqueString(depVirtualMachineNameTemp)}', 15)
var depVirtualMachineDiskName  = '${depVirtualMachineName}-${cnv_rtCodes.osdisks}'
var depVirtualMachineNicName   = '${depVirtualMachineName}-${cnv_rtCodes.networkInterfaces}'

// ── Operations / Monitoring Resource Groups ───────────────────────────────────
var resourceGroupOperations = cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, 'operations', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var resourceGroupMonitoring = cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, 'monitoring', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)

// Seed matches keyVaults.bicep exactly.
var uniqueStringOperations = take(
  !contains(cnv_segments, 'location')
    ? uniqueString(subscription().subscriptionId, resourceGroupOperations, virtualMachinesRegion)
    : uniqueString(subscription().subscriptionId, resourceGroupOperations),
  6
)

var kvBaseSecrets    = cnv(cnv_segments, cnv_sep, cnv_rtCodes.keyVaults, 'sec', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var kvBaseEncryption = cnv(cnv_segments, cnv_sep, cnv_rtCodes.keyVaults, 'enc', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)

var keyVaultNameSecrets = take(
  length(kvBaseSecrets) <= 20
    ? '${kvBaseSecrets}-${uniqueStringOperations}'
    : kvBaseSecrets,
  24
)
var keyVaultNameEncryption = take(
  length(kvBaseEncryption) <= 20
    ? '${kvBaseEncryption}-${uniqueStringOperations}'
    : kvBaseEncryption,
  24
)

// ── Monitoring ────────────────────────────────────────────────────────────────
var dataCollectionEndpointName = cnv(cnv_segments, cnv_sep, cnv_rtCodes.dataCollectionEndpoints, '', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var logAnalyticsWorkspaceName  = cnv(cnv_segments, cnv_sep, cnv_rtCodes.logAnalyticsWorkspaces,  '', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)

// ── Global Feed Resources ─────────────────────────────────────────────────────
var globalFeedResourceGroupName = !empty(globalFeedRegion)
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, 'global-feed', cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : ''
var globalFeedWorkspaceName = cnv(cnv_segments, cnv_sep, cnv_rtCodes.workspaces, 'global-feed', cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)

// ── Control Plane Shared Resources ───────────────────────────────────────────
var resourceGroupControlPlane = empty(existingFeedWorkspaceResourceId)
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, 'control-plane', cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : split(existingFeedWorkspaceResourceId, '/')[4]
var workspaceName = empty(existingFeedWorkspaceResourceId)
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.workspaces, '', cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : last(split(existingFeedWorkspaceResourceId, '/'))

// ── Control Plane HostPool Resources ──────────────────────────────────────────
var desktopApplicationGroupName = cnv(cnv_segments, cnv_sep, cnv_rtCodes.desktopApplicationGroups, identifier, cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var hostPoolName                = cnv(cnv_segments, cnv_sep, cnv_rtCodes.hostPools,                 identifier, cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var scalingPlanName             = cnv(cnv_segments, cnv_sep, cnv_rtCodes.scalingPlans,              identifier, cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)

// ── Common HostPool Naming Conventions ───────────────────────────────────────
var privateEndpointNameConv = replace(
  cnv_rtFirst ? 'RESOURCETYPE-RESOURCE-SUBRESOURCE-VNETID' : 'RESOURCE-SUBRESOURCE-VNETID-RESOURCETYPE',
  'RESOURCETYPE',
  cnv_rtCodes.privateEndpoints
)
var privateEndpointNICNameConvTemp = cnv_rtFirst
  ? 'RESOURCETYPE-${privateEndpointNameConv}'
  : '${privateEndpointNameConv}-RESOURCETYPE'
var privateEndpointNICNameConv = replace(privateEndpointNICNameConvTemp, 'RESOURCETYPE', cnv_rtCodes.networkInterfaces)

var recoveryServicesVaultNameVMs     = cnv(cnv_segments, cnv_sep, cnv_rtCodes.recoveryServicesVaults,  identifier, cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var recoveryServicesVaultNameFSLogix = cnv(cnv_segments, cnv_sep, cnv_rtCodes.recoveryServicesVaults,  'files',    cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var userAssignedIdentityNameConv     = cnv(cnv_segments, cnv_sep, cnv_rtCodes.userAssignedIdentities, '${identifier}-TOKEN', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)

// ── Compute Resources ─────────────────────────────────────────────────────────
var resourceGroupHosts    = cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups,   '${identifier}-hosts', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var availabilitySetNameConv = cnv(cnv_segments, cnv_sep, cnv_rtCodes.availabilitySets, '${identifier}-##',   cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var virtualMachineNameConv  = cnv_rtFirst ? '${cnv_rtCodes.virtualMachines}-SHNAME'  : 'SHNAME-${cnv_rtCodes.virtualMachines}'
var diskNameConv            = cnv_rtFirst ? '${cnv_rtCodes.osdisks}-SHNAME'          : 'SHNAME-${cnv_rtCodes.osdisks}'
var networkInterfaceNameConv = cnv_rtFirst ? '${cnv_rtCodes.networkInterfaces}-SHNAME' : 'SHNAME-${cnv_rtCodes.networkInterfaces}'

var diskAccessName    = cnv(cnv_segments, cnv_sep, cnv_rtCodes.diskAccesses,      identifier,            cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var diskEncryptionSetNameConv = cnv(cnv_segments, cnv_sep, cnv_rtCodes.diskEncryptionSets, '${identifier}-TOKEN', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var diskEncryptionSetNameConfidentialVMs             = replace(diskEncryptionSetNameConv, 'TOKEN', 'confvm-customer-keys')
var diskEncryptionSetNameCustomerManaged             = replace(diskEncryptionSetNameConv, 'TOKEN', 'customer-keys')
var diskEncryptionSetNamePlatformAndCustomerManaged  = replace(diskEncryptionSetNameConv, 'TOKEN', 'platform-and-customer-keys')

// ── Storage Resources ─────────────────────────────────────────────────────────
var resourceGroupStorage     = cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups,      '${identifier}-storage', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var netAppAccountName        = cnv(cnv_segments, cnv_sep, cnv_rtCodes.netAppAccounts,        identifier,             cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var netAppCapacityPoolName   = cnv(cnv_segments, cnv_sep, cnv_rtCodes.netAppCapacityPools,   identifier,             cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)

// FSLogix storage account naming (max 15 chars for domain-join compatibility)
var uniqueStringStorage = take(uniqueString(subscription().subscriptionId, resourceGroupStorage), 6)
var fslogixStorageAccountNamePrefix = !empty(customNamingConvention.?fslogixStoragePrefix ?? '')
  ? take(toLower(replace(customNamingConvention.fslogixStoragePrefix, '-', '')), 13)
  : 'fslogix${uniqueStringStorage}'

// ── Encryption Key Names ──────────────────────────────────────────────────────
var encryptionKeyNameFSLogix           = '${identifier}-encryption-key-${fslogixStorageAccountNamePrefix}##'
var encryptionKeyNameVMs               = '${identifier}-encryption-key-vms'
var encryptionKeyNameConfidentialVMs   = '${identifier}-encryption-key-confidential-vms'
var encryptionKeyNameRecoveryServices  = '${identifier}-encryption-key-rsv'

// ── Outputs ───────────────────────────────────────────────────────────────────
output resourceGroupDeployment   string = resourceGroupDeployment
output depVirtualMachineName     string = depVirtualMachineName
output depVirtualMachineDiskName string = depVirtualMachineDiskName
output depVirtualMachineNicName  string = depVirtualMachineNicName

output resourceGroupOperations   string = resourceGroupOperations
output resourceGroupMonitoring   string = resourceGroupMonitoring
output uniqueStringOperations    string = uniqueStringOperations
output keyVaultNameSecrets       string = keyVaultNameSecrets
output keyVaultNameEncryption    string = keyVaultNameEncryption

output dataCollectionEndpointName string = dataCollectionEndpointName
output logAnalyticsWorkspaceName   string = logAnalyticsWorkspaceName

output globalFeedResourceGroupName string = globalFeedResourceGroupName
output globalFeedWorkspaceName      string = globalFeedWorkspaceName

output resourceGroupControlPlane    string = resourceGroupControlPlane
output workspaceName                string = workspaceName
output desktopApplicationGroupName  string = desktopApplicationGroupName
output hostPoolName                 string = hostPoolName
output scalingPlanName              string = scalingPlanName

output privateEndpointNameConv    string = privateEndpointNameConv
output privateEndpointNICNameConv string = privateEndpointNICNameConv

output recoveryServicesVaultNameVMs     string = recoveryServicesVaultNameVMs
output recoveryServicesVaultNameFSLogix string = recoveryServicesVaultNameFSLogix
output userAssignedIdentityNameConv     string = userAssignedIdentityNameConv

output resourceGroupHosts        string = resourceGroupHosts
output availabilitySetNameConv   string = availabilitySetNameConv
output virtualMachineNameConv    string = virtualMachineNameConv
output diskNameConv              string = diskNameConv
output networkInterfaceNameConv  string = networkInterfaceNameConv

output diskAccessName                               string = diskAccessName
output diskEncryptionSetNameConv                    string = diskEncryptionSetNameConv
output diskEncryptionSetNameConfidentialVMs         string = diskEncryptionSetNameConfidentialVMs
output diskEncryptionSetNameCustomerManaged         string = diskEncryptionSetNameCustomerManaged
output diskEncryptionSetNamePlatformAndCustomerManaged string = diskEncryptionSetNamePlatformAndCustomerManaged

output resourceGroupStorage          string = resourceGroupStorage
output netAppAccountName             string = netAppAccountName
output netAppCapacityPoolName        string = netAppCapacityPoolName
output uniqueStringStorage           string = uniqueStringStorage
output fslogixStorageAccountNamePrefix string = fslogixStorageAccountNamePrefix

output encryptionKeyNameFSLogix          string = encryptionKeyNameFSLogix
output encryptionKeyNameVMs              string = encryptionKeyNameVMs
output encryptionKeyNameConfidentialVMs  string = encryptionKeyNameConfidentialVMs
output encryptionKeyNameRecoveryServices string = encryptionKeyNameRecoveryServices

@description('Location abbreviation for the VM/session host region (used by callers for non-naming-convention purposes).')
output vmsLocAbbr string = vmsLocAbbr
