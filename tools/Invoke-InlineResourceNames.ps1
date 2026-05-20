
<#
.SYNOPSIS
  Inlines deployments/hostpools/modules/resourceNames.bicep into hostpool.bicep,
  replacing the module declaration and all resourceNames.outputs.* references.
#>

$file    = 'c:\repos\FederalAVD\deployments\hostpools\hostpool.bicep'
$content = [System.IO.File]::ReadAllText($file).Replace("`r`n", "`n")

# ── 1. Replace module block ────────────────────────────────────────────────────

$oldModule = @'
// Resource Names
module resourceNames 'modules/resourceNames.bicep' = {
  name: 'Resource-Names-${deploymentSuffix}'
  params: {
    existingFeedWorkspaceResourceId: existingFeedWorkspaceResourceId
    existingHostPoolResourceId: existingHostPoolResourceId
    fslogixStorageCustomPrefix: fslogixStorageCustomPrefix
    identifier: identifier
    index: index
    controlPlaneRegion: effectiveControlPlaneRegion
    globalFeedRegion: globalFeedRegion!
    virtualMachinesRegion: virtualMachinesRegion
    nameConvResTypeAtEnd: nameConvResTypeAtEnd
    virtualMachineNamePrefix: virtualMachineNamePrefix
  }
}
'@

$newVars = @'
// ============================================================================
// Naming Convention
// Compile-time placeholders — resolved here by Bicep string substitution:
//   RESOURCETYPE  → resource type abbreviation (e.g., 'hp', 'vm', 'rg')
//   LOCATION      → region abbreviation (e.g., 'eus', 'va')
//   TOKEN         → per-resource differentiator (e.g., 'hosts', 'sec-abc123')
// ============================================================================
var cloud = toLower(environment().name)
var locationsObject = loadJsonContent('../../.common/data/locations.json')
var locationsEnvProperty = startsWith(cloud, 'us') ? 'other' : environment().name
var locations = locationsObject[locationsEnvProperty]

#disable-next-line BCP329
var varLocationVirtualMachines = startsWith(cloud, 'us') ? substring(virtualMachinesRegion, 5, length(virtualMachinesRegion) - 5) : virtualMachinesRegion
var virtualMachinesRegionAbbreviation = locations[varLocationVirtualMachines].abbreviation
#disable-next-line BCP329
var varLocationControlPlane = startsWith(cloud, 'us') ? substring(effectiveControlPlaneRegion, 5, length(effectiveControlPlaneRegion) - 5) : effectiveControlPlaneRegion
var controlPlaneRegionAbbreviation = locations[varLocationControlPlane].abbreviation

var resourceAbbreviations = loadJsonContent('../../.common/data/resourceAbbreviations.json')

var existingHostPoolName = empty(existingHostPoolResourceId) ? '' : last(split(existingHostPoolResourceId, '/'))
// nameConvReversed = true means resource type at end (e.g., "avd-01-eus-hp")
// nameConvReversed = false means resource type at beginning (e.g., "hp-avd-01-eus")
var nameConvReversed = !empty(existingHostPoolName)
  ? startsWith(existingHostPoolName, resourceAbbreviations.hostPools)
      ? false // Resource type is at the beginning
      : endsWith(existingHostPoolName, resourceAbbreviations.hostPools)
          ? true // Resource type is at the end
          : nameConvResTypeAtEnd // Fallback to parameter if unclear
  : nameConvResTypeAtEnd

var arrHostPoolName = split(existingHostPoolName, '-')
var hpIndexString = index >= 0 ? format('{0:00}', index) : ''
// Extract hpBaseName from existing host pool name by removing resource type and location
// Not reversed: hp-{hpBaseName}-{location} → remove first segment (hp) and last segment (location)
// Reversed: {hpBaseName}-{location}-hp → remove last two segments (location-hp)
// For new deployments, construct hpBaseName from identifier and index
var hpBaseName = !empty(existingHostPoolName)
  ? nameConvReversed
      ? join(take(arrHostPoolName, length(arrHostPoolName) - 2), '-') // Remove last 2 segments (location-hp)
      : join(take(skip(arrHostPoolName, 1), length(arrHostPoolName) - 2), '-') // Remove first (hp) and last (location)
  : empty(hpIndexString) ? toLower(identifier) : '${toLower(identifier)}-${hpIndexString}'
var hpResPrfx = nameConvReversed ? hpBaseName : 'RESOURCETYPE-${hpBaseName}'

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

// Deployment Resources
var resourceGroupDeployment = replace(
  replace(replace(nameConv_HP_ResGroups, 'TOKEN', 'deployment'), 'LOCATION', '${virtualMachinesRegionAbbreviation}'),
  'RESOURCETYPE',
  '${resourceAbbreviations.resourceGroups}'
)
var depVirtualMachineNameTemp = replace(
  replace(
    replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', ''), 'LOCATION', virtualMachinesRegionAbbreviation),
    'TOKEN-',
    ''
  ),
  '-',
  ''
)
var depVirtualMachineName = take('${depVirtualMachineNameTemp}${uniqueString(depVirtualMachineNameTemp)}', 15)
var depVirtualMachineDiskName = '${depVirtualMachineName}-${resourceAbbreviations.osdisks}'
var depVirtualMachineNicName = '${depVirtualMachineName}-${resourceAbbreviations.networkInterfaces}'

// Operations / Monitoring Resource Groups (shared infrastructure)
// The standalone keyVaults.bicep deployment also targets the operations RG (identifier defaults
// to 'operations'), so both the inline fallback and the standalone path produce KVs in the same
// RG with identical names — preventing duplicates.
var resourceGroupOperations = replace(
  replace(replace(nameConv_Shared_ResGroup, 'TOKEN', 'operations'), 'LOCATION', virtualMachinesRegionAbbreviation),
  'RESOURCETYPE',
  resourceAbbreviations.resourceGroups
)
var resourceGroupMonitoring = replace(
  replace(replace(nameConv_Shared_ResGroup, 'TOKEN', 'monitoring'), 'LOCATION', virtualMachinesRegionAbbreviation),
  'RESOURCETYPE',
  resourceAbbreviations.resourceGroups
)
var uniqueStringOperations = take(uniqueString(subscription().subscriptionId, resourceGroupOperations), 6)
// Key Vault names are seeded on resourceGroupOperations so the standalone keyVaults.bicep
// deployment produces identical names to the inline fallback, preventing duplicates.
var keyVaultNameSecrets = take(
  replace(
    replace(
      replace(nameConv_Shared_Resources, 'TOKEN', 'sec-${uniqueStringOperations}'),
      'LOCATION',
      virtualMachinesRegionAbbreviation
    ),
    'RESOURCETYPE',
    resourceAbbreviations.keyVaults
  ),
  24
)
var keyVaultNameEncryption = take(
  replace(
    replace(
      replace(nameConv_Shared_Resources, 'TOKEN', 'enc-${uniqueStringOperations}'),
      'LOCATION',
      virtualMachinesRegionAbbreviation
    ),
    'RESOURCETYPE',
    resourceAbbreviations.keyVaults
  ),
  24
)

var dataCollectionEndpointName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.dataCollectionEndpoints),
    'LOCATION',
    virtualMachinesRegionAbbreviation
  ),
  'TOKEN-',
  ''
)
var logAnalyticsWorkspaceName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.logAnalyticsWorkspaces),
    'LOCATION',
    virtualMachinesRegionAbbreviation
  ),
  'TOKEN-',
  ''
)

// Global Feed Resources
var globalFeedResourceGroupName = !(empty(globalFeedRegion))
  ? replace(
      replace(
        (nameConvReversed ? 'avd-global-feed-${nameConvSuffix}' : 'RESOURCETYPE-avd-global-feed-${nameConvSuffix}'),
        'LOCATION',
        controlPlaneRegionAbbreviation
      ),
      'RESOURCETYPE',
      '${resourceAbbreviations.resourceGroups}'
    )
  : ''
var globalFeedWorkspaceName = replace(
  (nameConvReversed ? 'avd-global-feed-RESOURCETYPE' : 'RESOURCETYPE-avd-global-feed'),
  'RESOURCETYPE',
  resourceAbbreviations.workspaces
)

// Control Plane Shared Resources
var resourceGroupControlPlane = empty(existingHostPoolResourceId)
  ? empty(existingFeedWorkspaceResourceId)
      ? replace(
          replace(
            replace(nameConv_Shared_ResGroup, 'TOKEN', 'control-plane'),
            'LOCATION',
            '${controlPlaneRegionAbbreviation}'
          ),
          'RESOURCETYPE',
          '${resourceAbbreviations.resourceGroups}'
        )
      : split(existingFeedWorkspaceResourceId, '/')[4]
  : split(existingHostPoolResourceId, '/')[4]
var workspaceName = empty(existingFeedWorkspaceResourceId)
  ? replace(
      replace(
        replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.workspaces),
        'LOCATION',
        controlPlaneRegionAbbreviation
      ),
      'TOKEN-',
      ''
    )
  : last(split(existingFeedWorkspaceResourceId, '/'))

// Control Plane HostPool Resources
var desktopApplicationGroupName = replace(
  replace(replace(nameConv_HP_Resources, 'TOKEN-', ''), 'RESOURCETYPE', resourceAbbreviations.desktopApplicationGroups),
  'LOCATION',
  controlPlaneRegionAbbreviation
)
var hostPoolName = replace(
  replace(replace(nameConv_HP_Resources, 'TOKEN-', ''), 'RESOURCETYPE', resourceAbbreviations.hostPools),
  'LOCATION',
  controlPlaneRegionAbbreviation
)
var scalingPlanName = replace(
  replace(replace(nameConv_HP_Resources, 'TOKEN-', ''), 'RESOURCETYPE', resourceAbbreviations.scalingPlans),
  'LOCATION',
  controlPlaneRegionAbbreviation
)

// Common HostPool Resource Naming
var privateEndpointNameConv = replace(
  nameConvReversed ? 'RESOURCE-SUBRESOURCE-VNETID-RESOURCETYPE' : 'RESOURCETYPE-RESOURCE-SUBRESOURCE-VNETID',
  'RESOURCETYPE',
  resourceAbbreviations.privateEndpoints
)
var privateEndpointNICNameConvTemp = nameConvReversed
  ? '${privateEndpointNameConv}-RESOURCETYPE'
  : 'RESOURCETYPE-${privateEndpointNameConv}'
var privateEndpointNICNameConv = replace(
  privateEndpointNICNameConvTemp,
  'RESOURCETYPE',
  resourceAbbreviations.networkInterfaces
)
var recoveryServicesVaultNameVMs = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.recoveryServicesVaults),
    'LOCATION',
    virtualMachinesRegionAbbreviation
  ),
  'TOKEN',
  'vms'
)
var recoveryServicesVaultNameFSLogix = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.recoveryServicesVaults),
    'LOCATION',
    virtualMachinesRegionAbbreviation
  ),
  'TOKEN',
  'fslogix'
)
var userAssignedIdentityNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.userAssignedIdentities),
  'LOCATION',
  virtualMachinesRegionAbbreviation
)

// Compute Resources
var resourceGroupHosts = replace(
  replace(replace(nameConv_HP_ResGroups, 'TOKEN', 'hosts'), 'LOCATION', '${virtualMachinesRegionAbbreviation}'),
  'RESOURCETYPE',
  '${resourceAbbreviations.resourceGroups}'
)
var availabilitySetNameConv = nameConvReversed ? replace(replace(replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', '##-RESOURCETYPE'), 'RESOURCETYPE', resourceAbbreviations.availabilitySets), 'LOCATION', virtualMachinesRegionAbbreviation), 'TOKEN-', '') : '${replace(replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.availabilitySets), 'LOCATION', virtualMachinesRegionAbbreviation), 'TOKEN-', '')}-##'
var virtualMachineNameConv = nameConvReversed
  ? '${virtualMachineNamePrefix}###-${resourceAbbreviations.virtualMachines}'
  : '${resourceAbbreviations.virtualMachines}-${virtualMachineNamePrefix}###'
var diskNameConv = nameConvReversed
  ? '${virtualMachineNamePrefix}###-${resourceAbbreviations.osdisks}'
  : '${resourceAbbreviations.osdisks}-${virtualMachineNamePrefix}###'
var networkInterfaceNameConv = nameConvReversed
  ? '${virtualMachineNamePrefix}###-${resourceAbbreviations.networkInterfaces}'
  : '${resourceAbbreviations.networkInterfaces}-${virtualMachineNamePrefix}###'
var diskAccessName = replace(
  replace(
    replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.diskAccesses),
    'LOCATION',
    virtualMachinesRegionAbbreviation
  ),
  'TOKEN-',
  ''
)
var diskEncryptionSetNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.diskEncryptionSets),
  'LOCATION',
  virtualMachinesRegionAbbreviation
)
var diskEncryptionSetNameConfidentialVMs = replace(diskEncryptionSetNameConv, 'TOKEN-', 'confvm-customer-keys-')
var diskEncryptionSetNameCustomerManaged = replace(diskEncryptionSetNameConv, 'TOKEN-', 'customer-keys-')
var diskEncryptionSetNamePlatformAndCustomerManaged = replace(diskEncryptionSetNameConv, 'TOKEN-', 'platform-and-customer-keys-')

// Storage Resources
var resourceGroupStorage = replace(
  replace(replace(nameConv_HP_ResGroups, 'TOKEN', 'storage'), 'LOCATION', '${virtualMachinesRegionAbbreviation}'),
  'RESOURCETYPE',
  '${resourceAbbreviations.resourceGroups}'
)
var netAppAccountName = replace(
  replace(
    replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.netAppAccounts),
    'LOCATION',
    virtualMachinesRegionAbbreviation
  ),
  'TOKEN-',
  ''
)
var netAppCapacityPoolName = replace(
  replace(
    replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.netAppCapacityPools),
    'LOCATION',
    virtualMachinesRegionAbbreviation
  ),
  'TOKEN-',
  ''
)

// FSLogix Storage Account Naming Convention (max 15 characters for domain join)
var uniqueStringStorage = take(uniqueString(subscription().subscriptionId, resourceGroupStorage), 6)
var fslogixStorageAccountNamePrefix = empty(fslogixStorageCustomPrefix)
  ? 'fslogix${uniqueStringStorage}'
  : toLower(fslogixStorageCustomPrefix)
var encryptionKeyNameFSLogix = '${hpBaseName}-encryption-key-${fslogixStorageAccountNamePrefix}##'
var encryptionKeyNameVMs = '${hpBaseName}-encryption-key-vms'
var encryptionKeyNameConfidentialVMs = '${hpBaseName}-encryption-key-confidential-vms'
var fslogixfileShareNames = {
  CloudCacheProfileContainer: [
    'profile-containers'
  ]
  CloudCacheProfileOfficeContainer: [
    'profile-containers'
    'office-containers'
  ]
  ProfileContainer: [
    'profile-containers'
  ]
  ProfileOfficeContainer: [
    'profile-containers'
    'office-containers'
  ]
}
'@

# Normalize line endings
$oldModule = $oldModule.Replace("`r`n", "`n")
$newVars   = $newVars.Replace("`r`n", "`n")

$before = $content.Length
$content = $content.Replace($oldModule, $newVars)
if ($content.Length -eq $before) {
  Write-Error "Module block replacement FAILED — oldModule string not found. Check line endings or whitespace."
  exit 1
}
Write-Host "Module block replaced."

# ── 2. Replace all resourceNames.outputs.* references ─────────────────────────

$replacements = [ordered]@{
  # Object property accesses — most specific first (longer paths before shorter)
  'resourceNames.outputs.diskEncryptionSetNames.confidentialVMs'        = 'diskEncryptionSetNameConfidentialVMs'
  'resourceNames.outputs.diskEncryptionSetNames.customerManaged'        = 'diskEncryptionSetNameCustomerManaged'
  'resourceNames.outputs.diskEncryptionSetNames.platformAndCustomerManaged' = 'diskEncryptionSetNamePlatformAndCustomerManaged'
  'resourceNames.outputs.keyVaultNames.encryptionKeys'                  = 'keyVaultNameEncryption'
  'resourceNames.outputs.keyVaultNames.secrets'                         = 'keyVaultNameSecrets'
  'resourceNames.outputs.encryptionKeyNames.fslogix'                    = 'encryptionKeyNameFSLogix'
  'resourceNames.outputs.encryptionKeyNames.virtualMachines'            = 'encryptionKeyNameVMs'
  'resourceNames.outputs.encryptionKeyNames.confidentialVMs'            = 'encryptionKeyNameConfidentialVMs'
  'resourceNames.outputs.recoveryServicesVaultNames.vms'                = 'recoveryServicesVaultNameVMs'
  'resourceNames.outputs.recoveryServicesVaultNames.fslogix'            = 'recoveryServicesVaultNameFSLogix'
  'resourceNames.outputs.storageAccountNames.fslogix'                   = 'fslogixStorageAccountNamePrefix'
  'resourceNames.outputs.fslogixFileShareNames'                         = 'fslogixfileShareNames'
  # Simple direct replacements
  'resourceNames.outputs.availabilitySetNameConv'                       = 'availabilitySetNameConv'
  'resourceNames.outputs.dataCollectionEndpointName'                    = 'dataCollectionEndpointName'
  'resourceNames.outputs.depVirtualMachineName'                         = 'depVirtualMachineName'
  'resourceNames.outputs.depVirtualMachineNicName'                      = 'depVirtualMachineNicName'
  'resourceNames.outputs.depVirtualMachineDiskName'                     = 'depVirtualMachineDiskName'
  'resourceNames.outputs.desktopApplicationGroupName'                   = 'desktopApplicationGroupName'
  'resourceNames.outputs.diskAccessName'                                = 'diskAccessName'
  'resourceNames.outputs.globalFeedWorkspaceName'                       = 'globalFeedWorkspaceName'
  'resourceNames.outputs.hostPoolName'                                  = 'hostPoolName'
  'resourceNames.outputs.logAnalyticsWorkspaceName'                     = 'logAnalyticsWorkspaceName'
  'resourceNames.outputs.netAppAccountName'                             = 'netAppAccountName'
  'resourceNames.outputs.netAppCapacityPoolName'                        = 'netAppCapacityPoolName'
  'resourceNames.outputs.privateEndpointNameConv'                       = 'privateEndpointNameConv'
  'resourceNames.outputs.privateEndpointNICNameConv'                    = 'privateEndpointNICNameConv'
  'resourceNames.outputs.resourceGroupControlPlane'                     = 'resourceGroupControlPlane'
  'resourceNames.outputs.resourceGroupDeployment'                       = 'resourceGroupDeployment'
  'resourceNames.outputs.resourceGroupGlobalFeed'                       = 'globalFeedResourceGroupName'
  'resourceNames.outputs.resourceGroupHosts'                            = 'resourceGroupHosts'
  'resourceNames.outputs.resourceGroupMonitoring'                       = 'resourceGroupMonitoring'
  'resourceNames.outputs.resourceGroupOperations'                       = 'resourceGroupOperations'
  'resourceNames.outputs.resourceGroupStorage'                          = 'resourceGroupStorage'
  'resourceNames.outputs.scalingPlanName'                               = 'scalingPlanName'
  'resourceNames.outputs.smbServerLocation'                             = 'virtualMachinesRegionAbbreviation'
  'resourceNames.outputs.userAssignedIdentityNameConv'                  = 'userAssignedIdentityNameConv'
  'resourceNames.outputs.virtualMachineNameConv'                        = 'virtualMachineNameConv'
  'resourceNames.outputs.virtualMachineDiskNameConv'                    = 'diskNameConv'
  'resourceNames.outputs.virtualMachineNicNameConv'                     = 'networkInterfaceNameConv'
  'resourceNames.outputs.workspaceName'                                 = 'workspaceName'
}

foreach ($entry in $replacements.GetEnumerator()) {
  $count = ([regex]::Matches($content, [regex]::Escape($entry.Key))).Count
  if ($count -gt 0) {
    $content = $content.Replace($entry.Key, $entry.Value)
    Write-Host "  Replaced $count occurrence(s): $($entry.Key) → $($entry.Value)"
  } else {
    Write-Warning "  NOT FOUND: $($entry.Key)"
  }
}

# ── 3. Verify nothing remains ──────────────────────────────────────────────────

$remaining = [regex]::Matches($content, 'resourceNames\.outputs\.[a-zA-Z.]+')
if ($remaining.Count -gt 0) {
  $unique = ($remaining | Select-Object -ExpandProperty Value | Sort-Object -Unique) -join ', '
  Write-Warning "Still has $($remaining.Count) unreplaced reference(s): $unique"
} else {
  Write-Host "`nAll resourceNames.outputs references replaced successfully."
}

# ── 4. Write back ──────────────────────────────────────────────────────────────

[System.IO.File]::WriteAllText($file, $content, [System.Text.UTF8Encoding]::new($false))
Write-Host "Written: $file"
Write-Host "Lines: $($content.Split("`n").Count)"
