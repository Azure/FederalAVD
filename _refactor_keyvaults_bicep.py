#!/usr/bin/env python3
"""
Refactor keyVaults.bicep: remove useCustomNaming dual-path, always use CAF defaults.
"""
import sys

BICEP = 'deployments/keyVaults/keyVaults.bicep'
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
var useCustomNaming = !empty(customNamingConvention) && contains(customNamingConvention, 'components')

var cnv_sep = useCustomNaming ? customNamingConvention.delimiter : '-'
var cnv_loc = useCustomNaming
  ? (!empty(customNamingConvention.?locationAbbreviation ?? '')
      ? customNamingConvention.locationAbbreviation
      : locationAbbreviation)
  : locationAbbreviation
var cnv_rtCodes = useCustomNaming && contains(customNamingConvention, 'resourceTypeCodes')
  ? customNamingConvention.resourceTypeCodes
  : {
      resourceGroups: resourceAbbreviations.resourceGroups
      keyVaults: resourceAbbreviations.keyVaults
      privateEndpoints: resourceAbbreviations.privateEndpoints
      networkInterfaces: resourceAbbreviations.networkInterfaces
    }
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
  : locationAbbreviation
var cnv_rtCodes  = contains(customNamingConvention, 'resourceTypeCodes')
  ? customNamingConvention.resourceTypeCodes
  : {
      resourceGroups: resourceAbbreviations.resourceGroups
      keyVaults: resourceAbbreviations.keyVaults
      privateEndpoints: resourceAbbreviations.privateEndpoints
      networkInterfaces: resourceAbbreviations.networkInterfaces
    }
var cnv_segments = customNamingConvention.?components ?? ['resourceType', 'workload', 'purpose', 'location']
// RT is last only when resourceType is explicitly the last non-'none' component.
var cnv_rtFirst  = !empty(cnv_segments) ? (last(filter(cnv_segments, s => s != 'none')) != 'resourceType') : true""",
    "naming support block"
)

# ── 3. customRgName — remove useCustomNaming ? ─────────────────────────────
text = replace_once(text,
    """var customRgName = useCustomNaming
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
    """var customRgName = buildCustomName(
  filter(cnv_segments, s => s != 'none'),
  cnv_sep,
  cnv_rtCodes.resourceGroups,
  identifier,
  cnv_loc,
  customNamingConvention.?freeform1 ?? '',
  customNamingConvention.?environment ?? '',
  customNamingConvention.?freeform2 ?? '',
  !empty(customNamingConvention.?workload ?? '') ? customNamingConvention.workload : 'avd'
)""",
    "customRgName"
)

# ── 4. Remove nameConv_ vars — only if operationsResourceGroupName replaces them ─
text = replace_once(text,
    """// Resource group naming: rg-avd-operations-eus
var nameConv_Operations_ResGroup = 'RESOURCETYPE-avd-${identifier}-LOCATION'

// Shared resource naming with TOKEN placeholder for sub-type differentiation (sec, enc)
var nameConv_Operations_Resources = 'RESOURCETYPE-avd-TOKEN-LOCATION'""",
    "// Resource group and resource naming now always use buildCustomName via cnv_segments.",
    "nameConv_ vars"
)

# ── 5. operationsResourceGroupName ───────────────────────────────────────────
text = replace_once(text,
    """var operationsResourceGroupName = useCustomNaming
  ? customRgName
  : replace(
      replace(nameConv_Operations_ResGroup, 'LOCATION', locationAbbreviation),
      'RESOURCETYPE',
      resourceAbbreviations.resourceGroups
    )""",
    "var operationsResourceGroupName = customRgName",
    "operationsResourceGroupName"
)

# ── 6. uniqueStringOperations ─────────────────────────────────────────────────
text = replace_once(text,
    """var uniqueStringOperations = take(
  (useCustomNaming && !contains(cnv_segments, 'location'))
    ? uniqueString(subscription().subscriptionId, operationsResourceGroupName, location)
    : uniqueString(subscription().subscriptionId, operationsResourceGroupName),
  6
)""",
    """var uniqueStringOperations = take(
  !contains(cnv_segments, 'location')
    ? uniqueString(subscription().subscriptionId, operationsResourceGroupName, location)
    : uniqueString(subscription().subscriptionId, operationsResourceGroupName),
  6
)""",
    "uniqueStringOperations"
)

# ── 7. secretsKeyVaultName ────────────────────────────────────────────────────
text = replace_once(text,
    """var secretsKeyVaultName = useCustomNaming
  ? take(
      length(kvBaseSecrets) <= 20
        ? '${kvBaseSecrets}-${uniqueStringOperations}'
        : kvBaseSecrets,
      24
    )
  : take(
      replace(
        replace(
          replace(nameConv_Operations_Resources, 'TOKEN', 'sec-${uniqueStringOperations}'),
          'LOCATION',
          locationAbbreviation
        ),
        'RESOURCETYPE',
        resourceAbbreviations.keyVaults
      ),
      24
    )""",
    """var secretsKeyVaultName = take(
  length(kvBaseSecrets) <= 20
    ? '${kvBaseSecrets}-${uniqueStringOperations}'
    : kvBaseSecrets,
  24
)""",
    "secretsKeyVaultName"
)

# ── 8. encryptionKeyVaultName ─────────────────────────────────────────────────
text = replace_once(text,
    """var encryptionKeyVaultName = useCustomNaming
  ? take(
      length(kvBaseEncryption) <= 20
        ? '${kvBaseEncryption}-${uniqueStringOperations}'
        : kvBaseEncryption,
      24
    )
  : take(
      replace(
        replace(
          replace(nameConv_Operations_Resources, 'TOKEN', 'enc-${uniqueStringOperations}'),
          'LOCATION',
          locationAbbreviation
        ),
        'RESOURCETYPE',
        resourceAbbreviations.keyVaults
      ),
      24
    )""",
    """var encryptionKeyVaultName = take(
  length(kvBaseEncryption) <= 20
    ? '${kvBaseEncryption}-${uniqueStringOperations}'
    : kvBaseEncryption,
  24
)""",
    "encryptionKeyVaultName"
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
