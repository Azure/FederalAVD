#!/usr/bin/env python3
"""
Refactor imageManagement.bicep: remove useCustomNaming dual-path, always use CAF defaults.
"""
import sys

BICEP = 'deployments/imageManagement/imageManagement.bicep'
text = open(BICEP, encoding='utf-8').read()
original_len = len(text)

def replace_once(src, old, new, label):
    if old not in src:
        print(f'  ERROR: pattern not found — {label}')
        sys.exit(1)
    if src.count(old) > 1:
        print(f'  WARNING: pattern found {src.count(old)} times — {label}')
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

# ── 2. Replace naming support block ──────────────────────────────────────────
text = replace_once(text,
    """// ── Custom naming convention support ─────────────────────────────────────────
// When customNamingConvention is populated from the portal UI, build all resource names
// from the ordered components array. When empty, fall through to the existing CAF logic.
var useCustomNaming = !empty(customNamingConvention) && contains(customNamingConvention, 'components')

// Resolve per-convention values (safe to evaluate even when useCustomNaming = false)
var cnv_sep = useCustomNaming ? customNamingConvention.delimiter : '-'
var cnv_loc = useCustomNaming
  ? (!empty(customNamingConvention.locationAbbreviation)
      ? customNamingConvention.locationAbbreviation
      : locations[varLocation].abbreviation)
  : locations[varLocation].abbreviation
var cnv_rtCodes = useCustomNaming && contains(customNamingConvention, 'resourceTypeCodes')
  ? customNamingConvention.resourceTypeCodes
  : {
      resourceGroups: resourceAbbreviations.resourceGroups
      computeGalleries: resourceAbbreviations.computeGalleries
      userAssignedIdentities: resourceAbbreviations.userAssignedIdentities
      storageAccounts: resourceAbbreviations.storageAccounts
      privateEndpoints: resourceAbbreviations.privateEndpoints
      diskEncryptionSets: resourceAbbreviations.diskEncryptionSets
    }

// Resolve each segment value. 'resourceType' and 'purpose' use per-call placeholders; the
// others are fixed strings that can be resolved once here.
// Build one segment-value per slot (slot value = 'none' means stop).
var cnv_segments = useCustomNaming ? customNamingConvention.components : []
// When custom naming is active, derive resource-type-first ordering from whether segment 1 is 'resourceType'.
// In the CAF path, resource type always appears first (standard CAF convention).
// RT is considered last only when it is explicitly the last non-'none' component.
// Used to ensure PE and NIC names follow the same prefix/suffix convention as all other resources.
var cnv_rtFirst = useCustomNaming ? (last(filter(cnv_segments, s => s != 'none')) != 'resourceType') : true""",
    """// ── Naming convention ────────────────────────────────────────────────────────
// Default: Cloud Adoption Framework (CAF) — resourceType-workload-purpose-location.
// Override any component via the customNamingConvention parameter.

var cnv_sep      = customNamingConvention.?delimiter  ?? '-'
var cnv_loc      = !empty(customNamingConvention.?locationAbbreviation ?? '')
  ? customNamingConvention.locationAbbreviation
  : locations[varLocation].abbreviation
var cnv_rtCodes  = contains(customNamingConvention, 'resourceTypeCodes')
  ? customNamingConvention.resourceTypeCodes
  : {
      resourceGroups: resourceAbbreviations.resourceGroups
      computeGalleries: resourceAbbreviations.computeGalleries
      userAssignedIdentities: resourceAbbreviations.userAssignedIdentities
      storageAccounts: resourceAbbreviations.storageAccounts
      privateEndpoints: resourceAbbreviations.privateEndpoints
      diskEncryptionSets: resourceAbbreviations.diskEncryptionSets
    }
var cnv_segments = customNamingConvention.?components ?? ['resourceType', 'workload', 'purpose', 'location']
// RT is last only when resourceType is explicitly the last non-'none' component.
var cnv_rtFirst  = !empty(cnv_segments) ? (last(filter(cnv_segments, s => s != 'none')) != 'resourceType') : true""",
    "naming support block"
)

# helper for the repeated freeform/env/ff2/workload args
WL = "!empty(customNamingConvention.?workload ?? '') ? customNamingConvention.workload : 'avd'"

# ── 3. customResourceGroupName ───────────────────────────────────────────────
text = replace_once(text,
    """// Per-resource custom names (only used when useCustomNaming = true)
var customResourceGroupName = useCustomNaming
  ? buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.resourceGroups,
      identifier,
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    )
  : ''""",
    f"""// Per-resource names always built from cnv_segments
var customResourceGroupName = buildCustomName(
  filter(cnv_segments, s => s != 'none'),
  cnv_sep,
  cnv_rtCodes.resourceGroups,
  identifier,
  cnv_loc,
  customNamingConvention.?freeform1 ?? '',
  customNamingConvention.?environment ?? '',
  customNamingConvention.?freeform2 ?? '',
  {WL}
)""",
    "customResourceGroupName"
)

# ── 4. customGalleryName ──────────────────────────────────────────────────────
text = replace_once(text,
    """var customGalleryName = useCustomNaming
  ? replace(
      buildCustomName(
        filter(cnv_segments, s => s != 'none'),
        cnv_sep,
        cnv_rtCodes.computeGalleries,
        identifier,
        cnv_loc,
        customNamingConvention.?freeform1 ?? '',
        customNamingConvention.?environment ?? '',
        customNamingConvention.?freeform2 ?? '',
        customNamingConvention.?workload ?? ''
      ),
      '-',
      '_'
    )
  : ''""",
    f"""var customGalleryName = replace(
  buildCustomName(
    filter(cnv_segments, s => s != 'none'),
    cnv_sep,
    cnv_rtCodes.computeGalleries,
    identifier,
    cnv_loc,
    customNamingConvention.?freeform1 ?? '',
    customNamingConvention.?environment ?? '',
    customNamingConvention.?freeform2 ?? '',
    {WL}
  ),
  '-',
  '_'
)""",
    "customGalleryName"
)

# ── 5. customIdentityName ─────────────────────────────────────────────────────
text = replace_once(text,
    """var customIdentityName = useCustomNaming
  ? buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.userAssignedIdentities,
      identifier,
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    )
  : ''""",
    f"""var customIdentityName = buildCustomName(
  filter(cnv_segments, s => s != 'none'),
  cnv_sep,
  cnv_rtCodes.userAssignedIdentities,
  identifier,
  cnv_loc,
  customNamingConvention.?freeform1 ?? '',
  customNamingConvention.?environment ?? '',
  customNamingConvention.?freeform2 ?? '',
  {WL}
)""",
    "customIdentityName"
)

# ── 6. customEncryptionIdentityName ──────────────────────────────────────────
text = replace_once(text,
    """var customEncryptionIdentityName = useCustomNaming
  ? buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.userAssignedIdentities,
      '${identifier}-encryption',
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    )
  : ''""",
    f"""var customEncryptionIdentityName = buildCustomName(
  filter(cnv_segments, s => s != 'none'),
  cnv_sep,
  cnv_rtCodes.userAssignedIdentities,
  '${'{identifier}'}-encryption',
  cnv_loc,
  customNamingConvention.?freeform1 ?? '',
  customNamingConvention.?environment ?? '',
  customNamingConvention.?freeform2 ?? '',
  {WL}
)""",
    "customEncryptionIdentityName"
)

# ── 7. customSaArtifactsBase ──────────────────────────────────────────────────
text = replace_once(text,
    """var customSaArtifactsBase = useCustomNaming
  ? stripSeparators(buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.storageAccounts,
      'assets',
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    ))
  : ''""",
    f"""var customSaArtifactsBase = stripSeparators(buildCustomName(
  filter(cnv_segments, s => s != 'none'),
  cnv_sep,
  cnv_rtCodes.storageAccounts,
  'assets',
  cnv_loc,
  customNamingConvention.?freeform1 ?? '',
  customNamingConvention.?environment ?? '',
  customNamingConvention.?freeform2 ?? '',
  {WL}
))""",
    "customSaArtifactsBase"
)

# ── 8. customSaLogsBase ───────────────────────────────────────────────────────
text = replace_once(text,
    """var customSaLogsBase = useCustomNaming
  ? stripSeparators(buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.storageAccounts,
      'logs',
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    ))
  : ''""",
    f"""var customSaLogsBase = stripSeparators(buildCustomName(
  filter(cnv_segments, s => s != 'none'),
  cnv_sep,
  cnv_rtCodes.storageAccounts,
  'logs',
  cnv_loc,
  customNamingConvention.?freeform1 ?? '',
  customNamingConvention.?environment ?? '',
  customNamingConvention.?freeform2 ?? '',
  {WL}
))""",
    "customSaLogsBase"
)

# ── 9. Remove nameConv_ vars + update resourceGroupName / galleryName / identityName ──
text = replace_once(text,
    """// ─────────────────────────────────────────────────────────────────────────────
var nameConv_Suffix_withoutResType = 'LOCATION'
var nameConvSuffix = nameConv_Suffix_withoutResType
// 'image-management' is intentionally hardcoded — this solution always deploys a single
// shared environment and has no identifier or index parameter like host pool deployments.
var identifier = 'image-management'
var nameConv_ImageManagement_ResGroup = 'RESOURCETYPE-avd-${identifier}-${nameConvSuffix}'
var nameConv_ImageManagement_Resources = 'RESOURCETYPE-avd-${identifier}-${nameConvSuffix}'
var resourceGroupName = useCustomNaming
  ? customResourceGroupName
  : replace(
      replace(nameConv_ImageManagement_ResGroup, 'LOCATION', locations[varLocation].abbreviation),
      'RESOURCETYPE',
      resourceAbbreviations.resourceGroups
    )""",
    """// ─────────────────────────────────────────────────────────────────────────────
// 'image-management' is intentionally hardcoded — this solution always deploys a single
// shared environment and has no identifier or index parameter like host pool deployments.
var identifier = 'image-management'
var resourceGroupName = customResourceGroupName""",
    "nameConv_ vars + resourceGroupName"
)

# ── 10. galleryName ───────────────────────────────────────────────────────────
text = replace_once(text,
    """var galleryName = useCustomNaming
  ? customGalleryName
  : replace(
      replace(
        replace(nameConv_ImageManagement_Resources, 'RESOURCETYPE', resourceAbbreviations.computeGalleries),
        'LOCATION',
        locations[varLocation].abbreviation
      ),
      '-',
      '_'
    )""",
    "var galleryName = customGalleryName",
    "galleryName"
)

# ── 11. identityName ──────────────────────────────────────────────────────────
text = replace_once(text,
    """var identityName = useCustomNaming
  ? customIdentityName
  : replace(
      replace(nameConv_ImageManagement_Resources, 'RESOURCETYPE', resourceAbbreviations.userAssignedIdentities),
      'LOCATION',
      locations[varLocation].abbreviation
    )""",
    "var identityName = customIdentityName",
    "identityName"
)

# ── 12. saUniqueSuffix ────────────────────────────────────────────────────────
text = replace_once(text,
    """var saUniqueSuffix = (useCustomNaming && !contains(cnv_segments, 'location'))
  ? uniqueString(subscription().subscriptionId, resourceGroupName, location)
  : uniqueString(subscription().subscriptionId, resourceGroupName)""",
    """var saUniqueSuffix = !contains(cnv_segments, 'location')
  ? uniqueString(subscription().subscriptionId, resourceGroupName, location)
  : uniqueString(subscription().subscriptionId, resourceGroupName)""",
    "saUniqueSuffix"
)

# ── 13. artifactsStorageAccountName ──────────────────────────────────────────
text = replace_once(text,
    """var artifactsStorageAccountName = take(
  useCustomNaming
    ? '${customSaArtifactsBase}${saUniqueSuffix}'
    : '${resourceAbbreviations.storageAccounts}imageassets${locations[varLocation].abbreviation}${saUniqueSuffix}',
  24
)""",
    """var artifactsStorageAccountName = take('${customSaArtifactsBase}${saUniqueSuffix}', 24)""",
    "artifactsStorageAccountName"
)

# ── 14. storageEncryptionIdentityName ─────────────────────────────────────────
text = replace_once(text,
    """var storageEncryptionIdentityName = useCustomNaming
  ? customEncryptionIdentityName
  : replace(
      replace(
        replace(nameConv_ImageManagement_Resources, identifier, '${identifier}-encryption'),
        'RESOURCETYPE',
        resourceAbbreviations.userAssignedIdentities
      ),
      'LOCATION',
      locations[varLocation].abbreviation
    )""",
    "var storageEncryptionIdentityName = customEncryptionIdentityName",
    "storageEncryptionIdentityName"
)

# ── 15. galleryDiskEncryptionSetName ─────────────────────────────────────────
text = replace_once(text,
    """var galleryDiskEncryptionSetName = useCustomNaming
  ? buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.diskEncryptionSets,
      contains(keyManagementGalleryImageVersions, 'Platform') ? 'platform-and-customer-keys' : 'customer-keys',
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    )
  : '${resourceAbbreviations.diskEncryptionSets}-image-management-${contains(keyManagementGalleryImageVersions, 'Platform') ? 'platform-and-customer-keys' : 'customer-keys'}-${locations[varLocation].abbreviation}'""",
    f"""var galleryDiskEncryptionSetName = buildCustomName(
  filter(cnv_segments, s => s != 'none'),
  cnv_sep,
  cnv_rtCodes.diskEncryptionSets,
  contains(keyManagementGalleryImageVersions, 'Platform') ? 'platform-and-customer-keys' : 'customer-keys',
  cnv_loc,
  customNamingConvention.?freeform1 ?? '',
  customNamingConvention.?environment ?? '',
  customNamingConvention.?freeform2 ?? '',
  {WL}
)""",
    "galleryDiskEncryptionSetName"
)

# ── 16. galleryConfidentialVmDiskEncryptionSetName ────────────────────────────
text = replace_once(text,
    """var galleryConfidentialVmDiskEncryptionSetName = useCustomNaming
  ? buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.diskEncryptionSets,
      'confidential-vm',
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    )
  : '${resourceAbbreviations.diskEncryptionSets}-image-management-confidential-vm-${locations[varLocation].abbreviation}'""",
    f"""var galleryConfidentialVmDiskEncryptionSetName = buildCustomName(
  filter(cnv_segments, s => s != 'none'),
  cnv_sep,
  cnv_rtCodes.diskEncryptionSets,
  'confidential-vm',
  cnv_loc,
  customNamingConvention.?freeform1 ?? '',
  customNamingConvention.?environment ?? '',
  customNamingConvention.?freeform2 ?? '',
  {WL}
)""",
    "galleryConfidentialVmDiskEncryptionSetName"
)

# ── 17. logsStorageName ───────────────────────────────────────────────────────
text = replace_once(text,
    """var logsStorageName = take(
  useCustomNaming
    ? '${customSaLogsBase}${saUniqueSuffix}'
    : '${resourceAbbreviations.storageAccounts}imagelogs${locations[varLocation].abbreviation}${saUniqueSuffix}',
  24
)""",
    """var logsStorageName = take('${customSaLogsBase}${saUniqueSuffix}', 24)""",
    "logsStorageName"
)

# ── Verify ────────────────────────────────────────────────────────────────────
remaining = [i+1 for i, ln in enumerate(text.splitlines()) if 'useCustomNaming' in ln]
if remaining:
    print(f'  WARNING: useCustomNaming still at lines: {remaining}')
else:
    print('  OK: no useCustomNaming references remain')

remaining2 = [i+1 for i, ln in enumerate(text.splitlines()) if 'nameConv_' in ln]
if remaining2:
    print(f'  WARNING: nameConv_ still at lines: {remaining2}')
else:
    print('  OK: no nameConv_ references remain')

with open(BICEP, 'w', encoding='utf-8') as f:
    f.write(text)
print(f'Saved {BICEP}: {len(text)} chars (was {original_len}; saved {original_len - len(text)} chars)')
