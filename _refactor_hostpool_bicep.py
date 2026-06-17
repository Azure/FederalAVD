#!/usr/bin/env python3
"""
Refactor hostpool.bicep: remove useCustomNaming dual-path, always use cnv() with CAF defaults.
"""

import sys

BICEP = 'deployments/hostpools/hostpool.bicep'

text = open(BICEP, encoding='utf-8').read()
original_len = len(text)

def replace_once(src, old, new, label):
    if old not in src:
        print(f'  ERROR: pattern not found — {label}')
        sys.exit(1)
    count = src.count(old)
    if count > 1:
        print(f'  WARNING: pattern found {count} times — {label}')
    return src.replace(old, new, 1)

# ── 1. Parameter default ──────────────────────────────────────────────────────
text = replace_once(text,
    "param customNamingConvention object = {}",
    """param customNamingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}""",
    "param default"
)

# ── 2. Naming support block (remove useCustomNaming, simplify vars) ───────────
text = replace_once(text,
    """// ── Custom naming convention support ─────────────────────────────────────────
var useCustomNaming = !empty(customNamingConvention) && contains(customNamingConvention, 'components')

var cnv_sep      = useCustomNaming ? customNamingConvention.delimiter : '-'
var cnv_segments = useCustomNaming ? customNamingConvention.components : []
// Location abbreviations: custom override → runtime locs lookup
var cnv_vmsloc = useCustomNaming && !empty(customNamingConvention.?vmsLocationAbbreviation ?? '')
  ? customNamingConvention.vmsLocationAbbreviation : vmsLocAbbr
var cnv_cploc  = useCustomNaming && !empty(customNamingConvention.?cpLocationAbbreviation ?? '')
  ? customNamingConvention.cpLocationAbbreviation : cpLocAbbr
// Merge per-resource-type abbreviation overrides onto the base data file.
// In the non-custom path cnv_rtCodes == abbr — no overhead.
var cnv_rtCodes = useCustomNaming && contains(customNamingConvention, 'resourceTypeCodes')
  ? union(abbr, customNamingConvention.resourceTypeCodes)
  : abbr
// Fixed value segments
var cnv_ff1      = customNamingConvention.?freeform1  ?? ''
var cnv_env      = customNamingConvention.?environment ?? ''
var cnv_ff2      = customNamingConvention.?freeform2  ?? ''
var cnv_workload = customNamingConvention.?workload    ?? ''""",
    """// ── Naming convention ────────────────────────────────────────────────────────
// Default: Cloud Adoption Framework (CAF) — resourceType-workload-purpose-location.
// Override any component via the customNamingConvention parameter.
// Backward compat: passing {} or omitting customNamingConvention uses CAF defaults.

var cnv_sep      = customNamingConvention.?delimiter  ?? '-'
var cnv_segments = customNamingConvention.?components ?? ['resourceType', 'workload', 'purpose', 'location']
// Location abbreviations: custom override → runtime locs lookup
var cnv_vmsloc = !empty(customNamingConvention.?vmsLocationAbbreviation ?? '')
  ? customNamingConvention.vmsLocationAbbreviation : vmsLocAbbr
var cnv_cploc  = !empty(customNamingConvention.?cpLocationAbbreviation ?? '')
  ? customNamingConvention.cpLocationAbbreviation : cpLocAbbr
// Merge per-resource-type abbreviation overrides onto the CAF abbreviations base.
var cnv_rtCodes = contains(customNamingConvention, 'resourceTypeCodes')
  ? union(abbr, customNamingConvention.resourceTypeCodes)
  : abbr
// Fixed value segments
var cnv_ff1      = customNamingConvention.?freeform1   ?? ''
var cnv_env      = customNamingConvention.?environment  ?? ''
var cnv_ff2      = customNamingConvention.?freeform2   ?? ''
var cnv_workload = !empty(customNamingConvention.?workload ?? '') ? customNamingConvention.workload : 'avd'""",
    "cnv support block"
)

# ── 3. nameConvReversed — remove useCustomNaming && guard ────────────────────
text = replace_once(text,
    "var nameConvReversed = useCustomNaming && (!empty(cnv_segments) && last(filter(cnv_segments, s => s != 'none')) == 'resourceType')",
    "var nameConvReversed = !empty(cnv_segments) && last(filter(cnv_segments, s => s != 'none')) == 'resourceType'",
    "nameConvReversed"
)

# ── 4. Remove hpResPrfx + nameConvSuffix + nameConv_* vars ───────────────────
text = replace_once(text,
    """var hpResPrfx = nameConvReversed ? hpBaseName : 'RESOURCETYPE-${hpBaseName}'

var nameConvSuffix = nameConvReversed ? 'LOCATION-RESOURCETYPE' : 'LOCATION'
var nameConv_Shared_ResGroup = nameConvReversed
  ? 'avd-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-TOKEN-${nameConvSuffix}'
var nameConv_Shared_Resources = nameConvReversed
  ? 'avd-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-TOKEN-${nameConvSuffix}'
var nameConv_HP_ResGroups = nameConvReversed
  ? 'avd-${hpBaseName}-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-${hpBaseName}-TOKEN-${nameConvSuffix}'
var nameConv_HP_Resources = '${hpResPrfx}-TOKEN-${nameConvSuffix}'

""",
    "\n",
    "nameConv_ vars block"
)

# ── 5. Individual naming vars — replace useCustomNaming ? cnv(...) : replace(...) ──

# resourceGroupDeployment
text = replace_once(text,
    """// Temporary Deployment Resources for run commands
var resourceGroupDeployment = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, '${hpBaseName}-deployment', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_HP_ResGroups, 'TOKEN', 'deployment'), 'LOCATION', '${vmsLocAbbr}'),
      'RESOURCETYPE',
      '${abbr.resourceGroups}'
    )""",
    """// Temporary Deployment Resources for run commands
var resourceGroupDeployment = cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, '${hpBaseName}-deployment', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)""",
    "resourceGroupDeployment"
)

# depVirtualMachineNameTemp
text = replace_once(text,
    """var depVirtualMachineNameTemp = useCustomNaming
  ? stripSeps(cnv(cnv_segments, cnv_sep, '', hpBaseName, cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload))
  : replace(
      replace(replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', ''), 'LOCATION', vmsLocAbbr), 'TOKEN-', ''),
      '-',
      ''
    )""",
    "var depVirtualMachineNameTemp = stripSeps(cnv(cnv_segments, cnv_sep, '', hpBaseName, cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload))",
    "depVirtualMachineNameTemp"
)

# resourceGroupOperations
text = replace_once(text,
    """var resourceGroupOperations = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, 'operations', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_Shared_ResGroup, 'TOKEN', 'operations'), 'LOCATION', vmsLocAbbr),
      'RESOURCETYPE',
      abbr.resourceGroups
    )""",
    "var resourceGroupOperations = cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, 'operations', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "resourceGroupOperations"
)

# resourceGroupMonitoring
text = replace_once(text,
    """var resourceGroupMonitoring = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, 'monitoring', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_Shared_ResGroup, 'TOKEN', 'monitoring'), 'LOCATION', vmsLocAbbr),
      'RESOURCETYPE',
      abbr.resourceGroups
    )""",
    "var resourceGroupMonitoring = cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, 'monitoring', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "resourceGroupMonitoring"
)

# uniqueStringOperations
text = replace_once(text,
    """var uniqueStringOperations = take(
  (useCustomNaming && !contains(cnv_segments, 'location'))
    ? uniqueString(subscription().subscriptionId, resourceGroupOperations, virtualMachinesRegion)
    : uniqueString(subscription().subscriptionId, resourceGroupOperations),
  6
)""",
    """var uniqueStringOperations = take(
  !contains(cnv_segments, 'location')
    ? uniqueString(subscription().subscriptionId, resourceGroupOperations, virtualMachinesRegion)
    : uniqueString(subscription().subscriptionId, resourceGroupOperations),
  6
)""",
    "uniqueStringOperations"
)

# kvBaseSecrets / kvBaseEncryption / keyVaultNameSecrets (the whole block)
text = replace_once(text,
    """var kvBaseSecrets    = cnv(cnv_segments, cnv_sep, cnv_rtCodes.keyVaults, 'sec', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var kvBaseEncryption = cnv(cnv_segments, cnv_sep, cnv_rtCodes.keyVaults, 'enc', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var keyVaultNameSecrets = take(
  useCustomNaming
    ? (length(kvBaseSecrets) <= 20
        ? '${kvBaseSecrets}-${uniqueStringOperations}'
        : kvBaseSecrets)
    : replace(
        replace(replace(nameConv_Shared_Resources, 'TOKEN', 'sec-${uniqueStringOperations}'), 'LOCATION', vmsLocAbbr),
        'RESOURCETYPE',
        abbr.keyVaults
      ),
  24
)""",
    """var kvBaseSecrets    = cnv(cnv_segments, cnv_sep, cnv_rtCodes.keyVaults, 'sec', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var kvBaseEncryption = cnv(cnv_segments, cnv_sep, cnv_rtCodes.keyVaults, 'enc', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
var keyVaultNameSecrets = take(
  length(kvBaseSecrets) <= 20
    ? '${kvBaseSecrets}-${uniqueStringOperations}'
    : kvBaseSecrets,
  24
)""",
    "keyVaultNameSecrets"
)

# keyVaultNameEncryption
text = replace_once(text,
    """var keyVaultNameEncryption = take(
  useCustomNaming
    ? (length(kvBaseEncryption) <= 20
        ? '${kvBaseEncryption}-${uniqueStringOperations}'
        : kvBaseEncryption)
    : replace(
        replace(replace(nameConv_Shared_Resources, 'TOKEN', 'enc-${uniqueStringOperations}'), 'LOCATION', vmsLocAbbr),
        'RESOURCETYPE',
        abbr.keyVaults
      ),
  24
)""",
    """var keyVaultNameEncryption = take(
  length(kvBaseEncryption) <= 20
    ? '${kvBaseEncryption}-${uniqueStringOperations}'
    : kvBaseEncryption,
  24
)""",
    "keyVaultNameEncryption"
)

# dataCollectionEndpointName
text = replace_once(text,
    """var dataCollectionEndpointName = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.dataCollectionEndpoints, '', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_Shared_Resources, 'RESOURCETYPE', abbr.dataCollectionEndpoints), 'LOCATION', vmsLocAbbr),
      'TOKEN-',
      ''
    )""",
    "var dataCollectionEndpointName = cnv(cnv_segments, cnv_sep, cnv_rtCodes.dataCollectionEndpoints, '', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "dataCollectionEndpointName"
)

# logAnalyticsWorkspaceName
text = replace_once(text,
    """var logAnalyticsWorkspaceName = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.logAnalyticsWorkspaces, '', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_Shared_Resources, 'RESOURCETYPE', abbr.logAnalyticsWorkspaces), 'LOCATION', vmsLocAbbr),
      'TOKEN-',
      ''
    )""",
    "var logAnalyticsWorkspaceName = cnv(cnv_segments, cnv_sep, cnv_rtCodes.logAnalyticsWorkspaces, '', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "logAnalyticsWorkspaceName"
)

# globalFeedResourceGroupName
text = replace_once(text,
    """var globalFeedResourceGroupName = !(empty(globalFeedRegion))
  ? useCustomNaming
      ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, 'global-feed', cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
      : replace(
          replace(
            (nameConvReversed ? 'avd-global-feed-${nameConvSuffix}' : 'RESOURCETYPE-avd-global-feed-${nameConvSuffix}'),
            'LOCATION',
            cpLocAbbr
          ),
          'RESOURCETYPE',
          '${abbr.resourceGroups}'
        )
  : ''""",
    """var globalFeedResourceGroupName = !(empty(globalFeedRegion))
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, 'global-feed', cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : ''""",
    "globalFeedResourceGroupName"
)

# globalFeedWorkspaceName
text = replace_once(text,
    """var globalFeedWorkspaceName = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.workspaces, 'global-feed', cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      (nameConvReversed ? 'avd-global-feed-RESOURCETYPE' : 'RESOURCETYPE-avd-global-feed'),
      'RESOURCETYPE',
      abbr.workspaces
    )""",
    "var globalFeedWorkspaceName = cnv(cnv_segments, cnv_sep, cnv_rtCodes.workspaces, 'global-feed', cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "globalFeedWorkspaceName"
)

# resourceGroupControlPlane
text = replace_once(text,
    """var resourceGroupControlPlane = empty(existingFeedWorkspaceResourceId)
  ? useCustomNaming
      ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, 'control-plane', cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
      : replace(
          replace(replace(nameConv_Shared_ResGroup, 'TOKEN', 'control-plane'), 'LOCATION', '${cpLocAbbr}'),
          'RESOURCETYPE',
          '${abbr.resourceGroups}'
        )
  : split(existingFeedWorkspaceResourceId, '/')[4]""",
    """var resourceGroupControlPlane = empty(existingFeedWorkspaceResourceId)
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, 'control-plane', cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : split(existingFeedWorkspaceResourceId, '/')[4]""",
    "resourceGroupControlPlane"
)

# workspaceName
text = replace_once(text,
    """var workspaceName = empty(existingFeedWorkspaceResourceId)
  ? useCustomNaming
      ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.workspaces, '', cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
      : replace(
          replace(replace(nameConv_Shared_Resources, 'RESOURCETYPE', abbr.workspaces), 'LOCATION', cpLocAbbr),
          'TOKEN-',
          ''
        )
  : last(split(existingFeedWorkspaceResourceId, '/'))""",
    """var workspaceName = empty(existingFeedWorkspaceResourceId)
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.workspaces, '', cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : last(split(existingFeedWorkspaceResourceId, '/'))""",
    "workspaceName"
)

# desktopApplicationGroupName
text = replace_once(text,
    """var desktopApplicationGroupName = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.desktopApplicationGroups, hpBaseName, cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_HP_Resources, 'TOKEN-', ''), 'RESOURCETYPE', abbr.desktopApplicationGroups),
      'LOCATION',
      cpLocAbbr
    )""",
    "var desktopApplicationGroupName = cnv(cnv_segments, cnv_sep, cnv_rtCodes.desktopApplicationGroups, hpBaseName, cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "desktopApplicationGroupName"
)

# hostPoolName
text = replace_once(text,
    """var hostPoolName = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.hostPools, hpBaseName, cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_HP_Resources, 'TOKEN-', ''), 'RESOURCETYPE', abbr.hostPools),
      'LOCATION',
      cpLocAbbr
    )""",
    "var hostPoolName = cnv(cnv_segments, cnv_sep, cnv_rtCodes.hostPools, hpBaseName, cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "hostPoolName"
)

# scalingPlanName
text = replace_once(text,
    """var scalingPlanName = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.scalingPlans, hpBaseName, cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_HP_Resources, 'TOKEN-', ''), 'RESOURCETYPE', abbr.scalingPlans),
      'LOCATION',
      cpLocAbbr
    )""",
    "var scalingPlanName = cnv(cnv_segments, cnv_sep, cnv_rtCodes.scalingPlans, hpBaseName, cnv_cploc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "scalingPlanName"
)

# recoveryServicesVaultNameVMs
text = replace_once(text,
    """var recoveryServicesVaultNameVMs = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.recoveryServicesVaults, hpBaseName, cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', abbr.recoveryServicesVaults), 'LOCATION', vmsLocAbbr),
      'TOKEN-',
      ''
    )""",
    "var recoveryServicesVaultNameVMs = cnv(cnv_segments, cnv_sep, cnv_rtCodes.recoveryServicesVaults, hpBaseName, cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "recoveryServicesVaultNameVMs"
)

# recoveryServicesVaultNameFSLogix
text = replace_once(text,
    """var recoveryServicesVaultNameFSLogix = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.recoveryServicesVaults, 'files', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_Shared_Resources, 'RESOURCETYPE', abbr.recoveryServicesVaults), 'LOCATION', vmsLocAbbr),
      'TOKEN',
      'files'
    )""",
    "var recoveryServicesVaultNameFSLogix = cnv(cnv_segments, cnv_sep, cnv_rtCodes.recoveryServicesVaults, 'files', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "recoveryServicesVaultNameFSLogix"
)

# userAssignedIdentityNameConv
text = replace_once(text,
    """var userAssignedIdentityNameConv = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.userAssignedIdentities, '${hpBaseName}-TOKEN', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(nameConv_HP_Resources, 'RESOURCETYPE', abbr.userAssignedIdentities),
      'LOCATION',
      vmsLocAbbr
    )""",
    "var userAssignedIdentityNameConv = cnv(cnv_segments, cnv_sep, cnv_rtCodes.userAssignedIdentities, '${hpBaseName}-TOKEN', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "userAssignedIdentityNameConv"
)

# resourceGroupHosts
text = replace_once(text,
    """var resourceGroupHosts = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, '${hpBaseName}-hosts', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_HP_ResGroups, 'TOKEN', 'hosts'), 'LOCATION', '${vmsLocAbbr}'),
      'RESOURCETYPE',
      '${abbr.resourceGroups}'
    )""",
    "var resourceGroupHosts = cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, '${hpBaseName}-hosts', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "resourceGroupHosts"
)

# availabilitySetNameConv
text = replace_once(text,
    """var availabilitySetNameConv = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.availabilitySets, '${hpBaseName}-##', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', abbr.availabilitySets), 'LOCATION', vmsLocAbbr),
      'TOKEN',
      '##'
    )""",
    "var availabilitySetNameConv = cnv(cnv_segments, cnv_sep, cnv_rtCodes.availabilitySets, '${hpBaseName}-##', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "availabilitySetNameConv"
)

# diskAccessName
text = replace_once(text,
    """var diskAccessName = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.diskAccesses, hpBaseName, cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', abbr.diskAccesses), 'LOCATION', vmsLocAbbr),
      'TOKEN-',
      ''
    )""",
    "var diskAccessName = cnv(cnv_segments, cnv_sep, cnv_rtCodes.diskAccesses, hpBaseName, cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "diskAccessName"
)

# diskEncryptionSetNameConv (note: comment says TOKEN not TOKEN-)
text = replace_once(text,
    """var diskEncryptionSetNameConv = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.diskEncryptionSets, '${hpBaseName}-TOKEN', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(nameConv_HP_Resources, 'RESOURCETYPE', abbr.diskEncryptionSets),
      'LOCATION',
      vmsLocAbbr
    )""",
    "var diskEncryptionSetNameConv = cnv(cnv_segments, cnv_sep, cnv_rtCodes.diskEncryptionSets, '${hpBaseName}-TOKEN', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "diskEncryptionSetNameConv"
)

# resourceGroupStorage
text = replace_once(text,
    """var resourceGroupStorage = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, '${hpBaseName}-storage', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_HP_ResGroups, 'TOKEN', 'storage'), 'LOCATION', '${vmsLocAbbr}'),
      'RESOURCETYPE',
      '${abbr.resourceGroups}'
    )""",
    "var resourceGroupStorage = cnv(cnv_segments, cnv_sep, cnv_rtCodes.resourceGroups, '${hpBaseName}-storage', cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "resourceGroupStorage"
)

# netAppAccountName
text = replace_once(text,
    """var netAppAccountName = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.netAppAccounts, hpBaseName, cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', abbr.netAppAccounts), 'LOCATION', vmsLocAbbr),
      'TOKEN-',
      ''
    )""",
    "var netAppAccountName = cnv(cnv_segments, cnv_sep, cnv_rtCodes.netAppAccounts, hpBaseName, cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "netAppAccountName"
)

# netAppCapacityPoolName
text = replace_once(text,
    """var netAppCapacityPoolName = useCustomNaming
  ? cnv(cnv_segments, cnv_sep, cnv_rtCodes.netAppCapacityPools, hpBaseName, cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)
  : replace(
      replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', abbr.netAppCapacityPools), 'LOCATION', vmsLocAbbr),
      'TOKEN-',
      ''
    )""",
    "var netAppCapacityPoolName = cnv(cnv_segments, cnv_sep, cnv_rtCodes.netAppCapacityPools, hpBaseName, cnv_vmsloc, cnv_ff1, cnv_env, cnv_ff2, cnv_workload)",
    "netAppCapacityPoolName"
)

# fslogixStorageAccountNamePrefix
text = replace_once(text,
    "var fslogixStorageAccountNamePrefix = useCustomNaming && !empty(customNamingConvention.?fslogixStoragePrefix ?? '')",
    "var fslogixStorageAccountNamePrefix = !empty(customNamingConvention.?fslogixStoragePrefix ?? '')",
    "fslogixStorageAccountNamePrefix"
)

# ── Verify no useCustomNaming references remain ───────────────────────────────
remaining = [i+1 for i, line in enumerate(text.splitlines()) if 'useCustomNaming' in line]
if remaining:
    print(f'  WARNING: useCustomNaming still found at lines: {remaining}')
else:
    print('  OK: no useCustomNaming references remain')

# Verify no nameConv_ references remain
remaining2 = [i+1 for i, line in enumerate(text.splitlines()) if 'nameConv_' in line]
if remaining2:
    print(f'  WARNING: nameConv_ still found at lines: {remaining2}')
else:
    print('  OK: no nameConv_ references remain')

# Save
with open(BICEP, 'w', encoding='utf-8') as f:
    f.write(text)

print(f'Saved {BICEP}: {len(text)} chars (was {original_len}; saved {original_len - len(text)} chars)')
