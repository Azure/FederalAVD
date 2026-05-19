targetScope = 'subscription'

@description('Required. Resource ID of an existing host pool. When provided, naming conventions are derived from the existing host pool name rather than constructed from scratch.')
param existingHostPoolResourceId string
@description('Optional. Resource ID of an existing global feed workspace to register this host pool with. Leave empty to skip global feed registration.')
param existingFeedWorkspaceResourceId string = ''
@description('Optional. Custom prefix for FSLogix storage account names. Overrides the default naming convention when set.')
param fslogixStorageCustomPrefix string = ''
@description('Optional. Short label for this host pool (e.g. "finance", "dev"). Used as the base segment in all generated resource names. Ignored when existingHostPoolResourceId is provided.')
param identifier string = ''
@description('Required. Numeric index for this host pool (e.g. 1 produces a -01 suffix). Used to differentiate multiple host pools sharing the same identifier.')
param index int
@description('Required. Azure region for AVD control plane resources: host pool, workspace, and application groups.')
param controlPlaneRegion string
@description('Optional. Azure region for the global feed workspace. Required only when creating a new global feed workspace resource.')
param globalFeedRegion string = ''
@description('Required. Azure region where session host VMs and associated compute and storage resources are deployed.')
param virtualMachinesRegion string
@description('Optional. When true, the resource type abbreviation is placed at the end of names (e.g. avd-01-eus-vm). When false, at the beginning (e.g. vm-avd-01-eus). Ignored when existingHostPoolResourceId is provided — convention is detected automatically from the existing name.')
param nameConvResTypeAtEnd bool = false
@description('Optional. Override prefix for virtual machine names. When empty, derived from the naming convention and identifier.')
param virtualMachineNamePrefix string = ''

var cloud = toLower(environment().name)
var locationsObject = loadJsonContent('../../../.common/data/locations.json')
var locationsEnvProperty = startsWith(cloud, 'us') ? 'other' : environment().name
var locations = locationsObject[locationsEnvProperty]

#disable-next-line BCP329
var varLocationVirtualMachines = startsWith(cloud, 'us') ? substring(virtualMachinesRegion, 5, length(virtualMachinesRegion) - 5) : virtualMachinesRegion
var virtualMachinesRegionAbbreviation = locations[varLocationVirtualMachines].abbreviation
#disable-next-line BCP329
var varLocationControlPlane = startsWith(cloud, 'us') ? substring(controlPlaneRegion, 5, length(controlPlaneRegion) - 5) : controlPlaneRegion
var controlPlaneRegionAbbreviation = locations[varLocationControlPlane].abbreviation

var resourceAbbreviations = loadJsonContent('../../../.common/data/resourceAbbreviations.json')

var existingHostPoolName = empty(existingHostPoolResourceId) ? '' : last(split(existingHostPoolResourceId, '/'))

// Dynamically determine naming convention from existing host pool name
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

// Management, Monitoring, and Control Plane Resource Naming Conventions
var nameConv_Shared_ResGroup = nameConvReversed
  ? 'avd-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-TOKEN-${nameConvSuffix}'
var nameConv_Shared_Resources = nameConvReversed
  ? 'avd-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-TOKEN-${nameConvSuffix}'

// HostPool Specific Resource Naming Conventions
var nameConv_HP_ResGroups = nameConvReversed
  ? 'avd-${hpBaseName}-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-${hpBaseName}-TOKEN-${nameConvSuffix}'
var nameConv_HP_Resources = '${hpResPrfx}-TOKEN-${nameConvSuffix}'

// Deployment Resources (temporary resource group for deployment purposes)
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

// Operations RG: Key Vaults, App Service Plan, Template Specs, App Attach storage — shared infrastructure
// The standalone keyVaults.bicep deployment also targets this RG (identifier defaults to 'operations')
// so both the inline fallback and the standalone path produce KVs in the same RG with identical names.
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

// Key Vault names are seeded on resourceGroupOperations so both the inline fallback
// and the standalone keyVaults.bicep deployment produce identical names, preventing duplicates.
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

// Common HostPool Specific Resource Naming Conventions
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
// Disk Encryption Set Names - Max length 80 Characters
var diskEncryptionSetNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.diskEncryptionSets),
  'LOCATION',
  virtualMachinesRegionAbbreviation
)

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

output availabilitySetNameConv string = availabilitySetNameConv
output dataCollectionEndpointName string = dataCollectionEndpointName
output depVirtualMachineName string = depVirtualMachineName
output depVirtualMachineNicName string = depVirtualMachineNicName
output depVirtualMachineDiskName string = depVirtualMachineDiskName
output desktopApplicationGroupName string = desktopApplicationGroupName
output diskAccessName string = diskAccessName
output diskEncryptionSetNames object = {
  confidentialVMs: replace(diskEncryptionSetNameConv, 'TOKEN-', 'confvm-customer-keys-')
  customerManaged: replace(diskEncryptionSetNameConv, 'TOKEN-', 'customer-keys-')
  platformAndCustomerManaged: replace(diskEncryptionSetNameConv, 'TOKEN-', 'platform-and-customer-keys-')
}
output fslogixFileShareNames object = fslogixfileShareNames
output globalFeedWorkspaceName string = globalFeedWorkspaceName
output hostPoolName string = hostPoolName
output keyVaultNames object = {
  encryptionKeys: keyVaultNameEncryption
  secrets: keyVaultNameSecrets
}
output encryptionKeyNames object = {
  fslogix: '${hpBaseName}-encryption-key-${fslogixStorageAccountNamePrefix}##'
  virtualMachines: '${hpBaseName}-encryption-key-vms'
  confidentialVMs: '${hpBaseName}-encryption-key-confidential-vms'
}
output smbServerLocation string = virtualMachinesRegionAbbreviation
output logAnalyticsWorkspaceName string = logAnalyticsWorkspaceName
output netAppAccountName string = netAppAccountName
output netAppCapacityPoolName string = netAppCapacityPoolName
output privateEndpointNameConv string = privateEndpointNameConv
output privateEndpointNICNameConv string = privateEndpointNICNameConv
output recoveryServicesVaultNames object = {
  vms: recoveryServicesVaultNameVMs
  fslogix: recoveryServicesVaultNameFSLogix
}
output resourceGroupControlPlane string = resourceGroupControlPlane
output resourceGroupGlobalFeed string = globalFeedResourceGroupName
output resourceGroupHosts string = resourceGroupHosts
output resourceGroupDeployment string = resourceGroupDeployment
output resourceGroupOperations string = resourceGroupOperations
output resourceGroupMonitoring string = resourceGroupMonitoring
output resourceGroupStorage string = resourceGroupStorage
output scalingPlanName string = scalingPlanName
output storageAccountNames object = {
  fslogix: fslogixStorageAccountNamePrefix
}
output userAssignedIdentityNameConv string = userAssignedIdentityNameConv
output virtualMachineNameConv string = virtualMachineNameConv
output virtualMachineDiskNameConv string = diskNameConv
output virtualMachineNicNameConv string = networkInterfaceNameConv
output workspaceName string = workspaceName
