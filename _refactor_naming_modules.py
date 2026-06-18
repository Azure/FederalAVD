#!/usr/bin/env python3
"""
Refactor hostpools, keyVaults, and imageManagement bicep files to use
shared naming modules from .common/bicepModules/naming/.
"""
import re, os

def word_replace_all(text, var_name, replacement):
    """Replace ALL word-boundary occurrences (including keys), then fix keys back."""
    return re.sub(r'\b' + re.escape(var_name) + r'\b', replacement, text)

def replace_vars(text, var_map):
    """Replace naming vars — longest name first to avoid partial matches.
    Two-pass: first replace all occurrences, then restore accidentally replaced property keys.
    Property keys are lines where the ONLY content before the colon is whitespace + varname.
    """
    # Pass 1: replace all occurrences
    for v in sorted(var_map.keys(), key=len, reverse=True):
        text = word_replace_all(text, v, var_map[v])
    # Pass 2: restore property keys (lines like '  naming.outputs.xxx:' → '  xxx:')
    for v, repl in sorted(var_map.items(), key=lambda x: len(x[0]), reverse=True):
        # Match: start of line, only whitespace, then the replacement, then optional space and colon
        text = re.sub(
            r'(?m)^([ \t]+)' + re.escape(repl) + r'(\s*:)',
            r'\g<1>' + v + r'\g<2>',
            text
        )
    return text

def check_remaining(text, var_names, label):
    """Check for unreplaced refs — skip matches that are already naming.outputs.xxx or property keys."""
    found = []
    for v in var_names:
        # Look for var name NOT preceded by 'naming.outputs.' and NOT a property key
        # Exclude lines where the var is the only thing before a colon (property key pattern)
        matches = list(re.finditer(r'\b' + re.escape(v) + r'\b', text))
        real_matches = []
        for m in matches:
            before = text[max(0, m.start()-15):m.start()]
            if before.endswith('naming.outputs.'):
                continue  # already replaced
            after = text[m.end():m.end()+2]
            line_start = text.rfind('\n', 0, m.start()) + 1
            before_on_line = text[line_start:m.start()]
            if before_on_line.strip() == '' and after.lstrip().startswith(':'):
                continue  # it's a property key
            real_matches.append(v)
            break
        found.extend(real_matches)
    if found:
        print(f'  WARN ({label}): possibly unreplaced refs: {found}')
    else:
        print(f'  OK ({label}): all naming var refs replaced')

# ─────────────────────────────────────────────────────────────────────────────
# 1. HOSTPOOL
# ─────────────────────────────────────────────────────────────────────────────
print('\n=== HOSTPOOL ===')
hp_path = 'deployments/hostpools/hostpool.bicep'
text = open(hp_path, encoding='utf-8-sig').read()

# Naming block: from the Naming Convention comment to just before fslogixShareNamesLookup
BLOCK_START = '// ============================================================================\n// Naming Convention\n'
BLOCK_END   = 'var fslogixShareNamesLookup = {'

si = text.find(BLOCK_START)
ei = text.find(BLOCK_END)
assert si >= 0, 'Could not find naming block start'
assert ei >= 0, 'Could not find naming block end'

# Extract hpIndexString and hpBaseName from inside the block (they stay in parent)
block_text = text[si:ei]
# These two lines appear in the block — capture them exactly
m_idx   = re.search(r"(var hpIndexString = .+)", block_text)
m_base  = re.search(r"(var hpBaseName = .+)", block_text)
assert m_idx and m_base, 'Could not extract hpIndexString / hpBaseName'
hp_index_line = m_idx.group(1)
hp_base_line  = m_base.group(1)

naming_call_hp = f"""{hp_index_line}
{hp_base_line}

// ── Naming module ─────────────────────────────────────────────────────────────
// All resource names for this host pool are resolved by the naming module.
// References below use naming.outputs.<name> instead of local vars.
module naming '../../.common/bicepModules/naming/hostpoolNaming.bicep' = {{
  name: 'Naming-${{deploymentSuffix}}'
  scope: subscription()
  params: {{
    customNamingConvention: customNamingConvention
    virtualMachinesRegion: virtualMachinesRegion
    controlPlaneRegion: effectiveControlPlaneRegion
    identifier: hpBaseName
    globalFeedRegion: globalFeedRegion
    existingFeedWorkspaceResourceId: existingFeedWorkspaceResourceId
  }}
}}

"""

text = text[:si] + naming_call_hp + text[ei:]

hp_vars = {
    'resourceGroupDeployment':                          'naming.outputs.resourceGroupDeployment',
    'depVirtualMachineName':                            'naming.outputs.depVirtualMachineName',
    'depVirtualMachineDiskName':                        'naming.outputs.depVirtualMachineDiskName',
    'depVirtualMachineNicName':                         'naming.outputs.depVirtualMachineNicName',
    'resourceGroupOperations':                          'naming.outputs.resourceGroupOperations',
    'resourceGroupMonitoring':                          'naming.outputs.resourceGroupMonitoring',
    'uniqueStringOperations':                           'naming.outputs.uniqueStringOperations',
    'keyVaultNameSecrets':                              'naming.outputs.keyVaultNameSecrets',
    'keyVaultNameEncryption':                           'naming.outputs.keyVaultNameEncryption',
    'dataCollectionEndpointName':                       'naming.outputs.dataCollectionEndpointName',
    'logAnalyticsWorkspaceName':                        'naming.outputs.logAnalyticsWorkspaceName',
    'globalFeedResourceGroupName':                      'naming.outputs.globalFeedResourceGroupName',
    'globalFeedWorkspaceName':                          'naming.outputs.globalFeedWorkspaceName',
    'resourceGroupControlPlane':                        'naming.outputs.resourceGroupControlPlane',
    'workspaceName':                                    'naming.outputs.workspaceName',
    'desktopApplicationGroupName':                      'naming.outputs.desktopApplicationGroupName',
    'hostPoolName':                                     'naming.outputs.hostPoolName',
    'scalingPlanName':                                  'naming.outputs.scalingPlanName',
    'privateEndpointNameConv':                          'naming.outputs.privateEndpointNameConv',
    'privateEndpointNICNameConv':                       'naming.outputs.privateEndpointNICNameConv',
    'recoveryServicesVaultNameVMs':                     'naming.outputs.recoveryServicesVaultNameVMs',
    'recoveryServicesVaultNameFSLogix':                 'naming.outputs.recoveryServicesVaultNameFSLogix',
    'userAssignedIdentityNameConv':                     'naming.outputs.userAssignedIdentityNameConv',
    'resourceGroupHosts':                               'naming.outputs.resourceGroupHosts',
    'availabilitySetNameConv':                          'naming.outputs.availabilitySetNameConv',
    'virtualMachineNameConv':                           'naming.outputs.virtualMachineNameConv',
    'diskNameConv':                                     'naming.outputs.diskNameConv',
    'networkInterfaceNameConv':                         'naming.outputs.networkInterfaceNameConv',
    'diskAccessName':                                   'naming.outputs.diskAccessName',
    'diskEncryptionSetNameConv':                        'naming.outputs.diskEncryptionSetNameConv',
    'diskEncryptionSetNameConfidentialVMs':             'naming.outputs.diskEncryptionSetNameConfidentialVMs',
    'diskEncryptionSetNameCustomerManaged':             'naming.outputs.diskEncryptionSetNameCustomerManaged',
    'diskEncryptionSetNamePlatformAndCustomerManaged':  'naming.outputs.diskEncryptionSetNamePlatformAndCustomerManaged',
    'resourceGroupStorage':                             'naming.outputs.resourceGroupStorage',
    'netAppAccountName':                                'naming.outputs.netAppAccountName',
    'netAppCapacityPoolName':                           'naming.outputs.netAppCapacityPoolName',
    'uniqueStringStorage':                              'naming.outputs.uniqueStringStorage',
    'fslogixStorageAccountNamePrefix':                  'naming.outputs.fslogixStorageAccountNamePrefix',
    'encryptionKeyNameFSLogix':                         'naming.outputs.encryptionKeyNameFSLogix',
    'encryptionKeyNameVMs':                             'naming.outputs.encryptionKeyNameVMs',
    'encryptionKeyNameConfidentialVMs':                 'naming.outputs.encryptionKeyNameConfidentialVMs',
    'encryptionKeyNameRecoveryServices':                'naming.outputs.encryptionKeyNameRecoveryServices',
    'vmsLocAbbr':                                       'naming.outputs.vmsLocAbbr',
}
text = replace_vars(text, hp_vars)
open(hp_path, 'w', encoding='utf-8').write(text)
print(f'  Saved {hp_path}: {len(text):,} chars')
check_remaining(text, list(hp_vars.keys()), 'hostpool')


# ─────────────────────────────────────────────────────────────────────────────
# 2. KEYVAULTS
# ─────────────────────────────────────────────────────────────────────────────
print('\n=== KEYVAULTS ===')
kv_path = 'deployments/keyVaults/keyVaults.bicep'
text = open(kv_path, encoding='utf-8-sig').read()

# Naming block: from '// ── Naming Convention' to just before '// ── Resource Group'
KV_BLOCK_START = '// ── Naming Convention ──────────────────────────────────────────────────────────\n'
KV_BLOCK_END   = '// ── Resource Group ─────────────────────────────────────────────────────────────\n'

si = text.find(KV_BLOCK_START)
ei = text.find(KV_BLOCK_END)
assert si >= 0, 'Could not find KV naming block start'
assert ei >= 0, 'Could not find KV naming block end'

# Keep deploymentSuffix in parent (used in module names)
naming_call_kv = """// ── Naming module ─────────────────────────────────────────────────────────────
// All resource names for this deployment are resolved by the naming module.
module naming '../../.common/bicepModules/naming/keyVaultsNaming.bicep' = {
  name: 'Naming-${deploymentSuffix}'
  scope: subscription()
  params: {
    customNamingConvention: customNamingConvention
    location: location
  }
}

"""

text = text[:si] + naming_call_kv + text[ei:]

kv_vars = {
    'operationsResourceGroupName': 'naming.outputs.operationsResourceGroupName',
    'privateEndpointNameConv':     'naming.outputs.privateEndpointNameConv',
    'privateEndpointNICNameConv':  'naming.outputs.privateEndpointNICNameConv',
    'uniqueStringOperations':      'naming.outputs.uniqueStringOperations',
    'secretsKeyVaultName':         'naming.outputs.secretsKeyVaultName',
    'encryptionKeyVaultName':      'naming.outputs.encryptionKeyVaultName',
}
text = replace_vars(text, kv_vars)
open(kv_path, 'w', encoding='utf-8').write(text)
print(f'  Saved {kv_path}: {len(text):,} chars')
check_remaining(text, list(kv_vars.keys()), 'keyVaults')


# ─────────────────────────────────────────────────────────────────────────────
# 3. IMAGEMANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
print('\n=== IMAGEMANAGEMENT ===')
im_path = 'deployments/imageManagement/imageManagement.bicep'
text = open(im_path, encoding='utf-8-sig').read()

# Naming block: from '// Naming conventions' to just before 'resource resourceGroup'
IM_BLOCK_START = '// Naming conventions\n'
IM_BLOCK_END   = "resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {"

si = text.find(IM_BLOCK_START)
ei = text.find(IM_BLOCK_END)
assert si >= 0, 'Could not find IM naming block start'
assert ei >= 0, 'Could not find IM naming block end'

# Non-naming constants that were inside the block must be re-inserted in parent.
# cmkKeyNames uses storageEncryptionKeyName which is now naming.outputs.storageEncryptionKeyName.
naming_call_im = """// Naming module — resolves all resource names for image management.
module naming '../../.common/bicepModules/naming/imageManagementNaming.bicep' = {
  name: 'Naming-${timeStamp}'
  scope: subscription()
  params: {
    customNamingConvention: customNamingConvention
    location: location
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    keyManagementGalleryImageVersions: keyManagementGalleryImageVersions
    customImageBuildResourceGroupName: customImageBuildResourceGroupName
  }
}

// Storage / deployment constants (not naming-convention-dependent)
var artifactsBlobContainerName  = 'artifacts'
var sasExpirationPeriod         = '180.00:00:00' // 180 days
var storageKind                 = 'StorageV2'
var storageSkuName              = 'Standard_LRS'
var artifactsStorageAccessTier  = 'Hot'
var logsStorageAccessTier       = 'Hot'
var logsContainerName           = 'image-customization-logs'
var cmkKeyNames = (deployArtifactsStorageAccount || deployBuildLogsStorageAccount) ? [naming.outputs.storageEncryptionKeyName] : []

"""

text = text[:si] + naming_call_im + text[ei:]

im_vars = {
    'resourceGroupName':                         'naming.outputs.resourceGroupName',
    'imageBuildRgName':                          'naming.outputs.imageBuildRgName',
    'galleryName':                               'naming.outputs.galleryName',
    'identityName':                              'naming.outputs.identityName',
    'storageEncryptionIdentityName':             'naming.outputs.storageEncryptionIdentityName',
    'artifactsStorageAccountName':               'naming.outputs.artifactsStorageAccountName',
    'logsStorageName':                           'naming.outputs.logsStorageName',
    'privateEndpointNameConv':                   'naming.outputs.privateEndpointNameConv',
    'privateEndpointName':                       'naming.outputs.privateEndpointName',
    'customNetworkInterfaceName':                'naming.outputs.customNetworkInterfaceName',
    'logsPrivateEndpointName':                   'naming.outputs.logsPrivateEndpointName',
    'logsCustomNetworkInterfaceName':            'naming.outputs.logsCustomNetworkInterfaceName',
    'galleryDiskEncryptionSetName':              'naming.outputs.galleryDiskEncryptionSetName',
    'galleryDiskEncryptionKeyName':              'naming.outputs.galleryDiskEncryptionKeyName',
    'galleryConfidentialVmDiskEncryptionSetName': 'naming.outputs.galleryConfidentialVmDiskEncryptionSetName',
    'galleryConfidentialVmDiskEncryptionKeyName': 'naming.outputs.galleryConfidentialVmDiskEncryptionKeyName',
    'storageEncryptionKeyName':                  'naming.outputs.storageEncryptionKeyName',
}
text = replace_vars(text, im_vars)
open(im_path, 'w', encoding='utf-8').write(text)
print(f'  Saved {im_path}: {len(text):,} chars')
check_remaining(text, list(im_vars.keys()), 'imageManagement')

print('\nDone. Run: az bicep build to verify.')
