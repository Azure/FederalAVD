targetScope = 'subscription'

param existingFeedWorkspaceResourceId string
param fslogixStorageCustomPrefix string
param identifier string
param index string
param locationControlPlane string
param locationGlobalFeed string
param locationVirtualMachines string
param nameConvResTypeAtEnd bool
param virtualMachineNamePrefix string

var locations = (loadJsonContent('../../../.common/data/locations.json'))[environment().name]
var resourceAbbreviations = loadJsonContent('../../../.common/data/resourceAbbreviations.json')

var hpBaseName = empty(index) ? identifier : '${identifier}-${index}'
var hpResPrfx = nameConvResTypeAtEnd ? hpBaseName : 'RESOURCETYPE-${hpBaseName}'
var nameConvSuffix = nameConvResTypeAtEnd ? 'LOCATION-RESOURCETYPE' : 'LOCATION'

// Management, Monitoring, and Control Plane Resource Naming Conventions
var nameConv_Shared_ResGroup = nameConvResTypeAtEnd
  ? 'avd-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-TOKEN-${nameConvSuffix}'
var nameConv_Shared_Resources = nameConvResTypeAtEnd
  ? 'avd-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-TOKEN-${nameConvSuffix}'

// HostPool Specific Resource Naming Conventions
var nameConv_HP_ResGroups = nameConvResTypeAtEnd
  ? 'avd-${hpBaseName}-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-${hpBaseName}-TOKEN-${nameConvSuffix}'
var nameConv_HP_Resources = '${hpResPrfx}-TOKEN-${nameConvSuffix}'

// Deployment Resources (temporary resource group for deployment purposes)
var resourceGroupDeployment = replace(
  replace(
    replace(nameConv_HP_ResGroups, 'TOKEN', 'deployment'),
    'LOCATION',
    '${locations[locationVirtualMachines].abbreviation}'
  ),
  'RESOURCETYPE',
  '${resourceAbbreviations.resourceGroups}'
)
var depVirtualMachineNameTemp = replace(
  replace(
    replace(
      replace(nameConv_HP_Resources, 'RESOURCETYPE', ''),
      'LOCATION',
      locations[locationVirtualMachines].abbreviation
    ),
    'TOKEN-',
    ''
  ),
  '-',
  ''
)
var depVirtualMachineName = take('${depVirtualMachineNameTemp}${uniqueString(depVirtualMachineNameTemp)}', 15)
var depVirtualMachineDiskName = nameConvResTypeAtEnd
  ? '${depVirtualMachineName}-${resourceAbbreviations.disks}'
  : '${resourceAbbreviations.disks}-${depVirtualMachineName}'
var depVirtualMachineNicName = nameConvResTypeAtEnd
  ? '${depVirtualMachineName}-${resourceAbbreviations.networkInterfaces}'
  : '${resourceAbbreviations.networkInterfaces}-${depVirtualMachineName}'

// Management and Monitoring Resource Names
var resourceGroupManagement = replace(
  replace(
    replace(nameConv_Shared_ResGroup, 'TOKEN', 'management'),
    'LOCATION',
    locations[locationVirtualMachines].abbreviation
  ),
  'RESOURCETYPE',
  resourceAbbreviations.resourceGroups
)
var uniqueStringManagement = uniqueString(subscription().subscriptionId, resourceGroupManagement) 
var appServicePlanName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.appServicePlans),
    'LOCATION',
    locations[locationVirtualMachines].abbreviation
  ),
  'TOKEN-',
  ''
)

// key vaults must be named with a length of 3 - 24 characters and must be globally unique.
var keyVaultNameSecrets = nameConvResTypeAtEnd ? 'sec-${take(uniqueStringManagement, 12)}-${locations[locationVirtualMachines].abbreviation}-${resourceAbbreviations.keyVaults}' : '${resourceAbbreviations.keyVaults}-sec-${take(uniqueStringManagement,12)}-${locations[locationVirtualMachines].abbreviation}'

var dataCollectionEndpointName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.dataCollectionEndpoints),
    'LOCATION',
    locations[locationVirtualMachines].abbreviation
  ),
  'TOKEN-',
  ''
)

var logAnalyticsWorkspaceName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.logAnalyticsWorkspaces),
    'LOCATION',
    locations[locationVirtualMachines].abbreviation
  ),
  'TOKEN-',
  ''
)

// Global Feed Resources
var globalFeedResourceGroupName = !(empty(locationGlobalFeed))
  ? replace(
      replace(
        (nameConvResTypeAtEnd ? 'avd-global-feed-${nameConvSuffix}' : 'RESOURCETYPE-avd-global-feed-${nameConvSuffix}'),
        'LOCATION',
        '${locations[locationGlobalFeed].abbreviation}'
      ),
      'RESOURCETYPE',
      '${resourceAbbreviations.resourceGroups}'
    )
  : ''
var globalFeedWorkspaceName = replace(
  (nameConvResTypeAtEnd ? 'avd-global-feed-RESOURCETYPE' : 'RESOURCETYPE-avd-global-feed'),
  'RESOURCETYPE',
  resourceAbbreviations.workspaces
)

// Control Plane Shared Resources
var resourceGroupControlPlane = empty(existingFeedWorkspaceResourceId)
  ? replace(
      replace(
        replace(nameConv_Shared_ResGroup, 'TOKEN', 'control-plane'),
        'LOCATION',
        '${locations[locationControlPlane].abbreviation}'
      ),
      'RESOURCETYPE',
      '${resourceAbbreviations.resourceGroups}'
    )
  : split(existingFeedWorkspaceResourceId, '/')[4]

var workspaceName = empty(existingFeedWorkspaceResourceId)
  ? replace(
      replace(
        replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.workspaces),
        'LOCATION',
        locations[locationControlPlane].abbreviation
      ),
      'TOKEN-',
      ''
    )
  : last(split(existingFeedWorkspaceResourceId, '/'))

// Control Plane HostPool Resources
var desktopApplicationGroupName = replace(
  replace(replace(nameConv_HP_Resources, 'TOKEN-', ''), 'RESOURCETYPE', resourceAbbreviations.desktopApplicationGroups),
  'LOCATION',
  locations[locationControlPlane].abbreviation
)
var hostPoolName = replace(
  replace(replace(nameConv_HP_Resources, 'TOKEN-', ''), 'RESOURCETYPE', resourceAbbreviations.hostPools),
  'LOCATION',
  locations[locationControlPlane].abbreviation
)
var scalingPlanName = replace(
  replace(replace(nameConv_HP_Resources, 'TOKEN-', ''), 'RESOURCETYPE', resourceAbbreviations.scalingPlans),
  'LOCATION',
  locations[locationControlPlane].abbreviation
)

// Common HostPool Specific Resource Naming Conventions
var uniqueStringHosts = uniqueString(subscription().subscriptionId, resourceGroupHosts)
var appInsightsNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.applicationInsights),
  'LOCATION',
  locations[locationVirtualMachines].abbreviation
)
var functionAppNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.functionApps),
  'LOCATION',
  locations[locationVirtualMachines].abbreviation
)

var privateEndpointNameConv = replace(
  nameConvResTypeAtEnd ? 'RESOURCE-SUBRESOURCE-VNETID-RESOURCETYPE' : 'RESOURCETYPE-RESOURCE-SUBRESOURCE-VNETID',
  'RESOURCETYPE',
  resourceAbbreviations.privateEndpoints
)
var privateEndpointNICNameConvTemp = nameConvResTypeAtEnd
  ? '${privateEndpointNameConv}-RESOURCETYPE'
  : 'RESOURCETYPE-${privateEndpointNameConv}'
var privateEndpointNICNameConv = replace(
  privateEndpointNICNameConvTemp,
  'RESOURCETYPE',
  resourceAbbreviations.networkInterfaces
)
var recoveryServicesVaultsNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.recoveryServicesVaults),
  'LOCATION',
  locations[locationVirtualMachines].abbreviation
)
var userAssignedIdentityNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.userAssignedIdentities),
  'LOCATION',
  locations[locationVirtualMachines].abbreviation
)

// Compute Resources
var resourceGroupHosts = replace(
  replace(
    replace(nameConv_HP_ResGroups, 'TOKEN', 'hosts'),
    'LOCATION',
    '${locations[locationVirtualMachines].abbreviation}'
  ),
  'RESOURCETYPE',
  '${resourceAbbreviations.resourceGroups}'
)
var vmNamePrefixWithoutDash = toLower(last(virtualMachineNamePrefix) == '-'
  ? take(virtualMachineNamePrefix, length(virtualMachineNamePrefix) - 1)
  : virtualMachineNamePrefix)
var availabilitySetNamePrefix = nameConvResTypeAtEnd
  ? '${vmNamePrefixWithoutDash}-${resourceAbbreviations.availabilitySets}-'
  : '${resourceAbbreviations.availabilitySets}-${vmNamePrefixWithoutDash}-'

var diskNamePrefix = nameConvResTypeAtEnd
  ? '${vmNamePrefixWithoutDash}-${resourceAbbreviations.disks}-'
  : '${resourceAbbreviations.disks}-${vmNamePrefixWithoutDash}-'
var networkInterfaceNamePrefix = nameConvResTypeAtEnd
  ? '${vmNamePrefixWithoutDash}-${resourceAbbreviations.networkInterfaces}-'
  : '${resourceAbbreviations.networkInterfaces}-${vmNamePrefixWithoutDash}-'
var diskAccessName = replace(
  replace(
    replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.diskAccesses),
    'LOCATION',
    locations[locationVirtualMachines].abbreviation
  ),
  'TOKEN-',
  ''
)
// Disk Encryption Set Names - Max length 80 Characters
var diskEncryptionSetNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.diskEncryptionSets),
  'LOCATION',
  locations[locationVirtualMachines].abbreviation
)
// Key Vault Names must be unique across the entire Azure Cloud
var keyVaultNameVMs = nameConvResTypeAtEnd ? 'vme-${take(uniqueStringHosts, 12)}-${locations[locationVirtualMachines].abbreviation}-${resourceAbbreviations.keyVaults}' : '${resourceAbbreviations.keyVaults}-vme-${take(uniqueStringHosts, 12)}-${locations[locationVirtualMachines].abbreviation}'
//var keyVaultNameSHR = nameConvResTypeAtEnd ? 'shr-${take(uniqueStringHosts, 12)}-${locations[locationVirtualMachines].abbreviation}-${resourceAbbreviations.keyVaults}' : '${resourceAbbreviations.keyVaults}-shr-${take(uniqueStringHosts, 12)}-${locations[locationVirtualMachines].abbreviation}'

// Storage Resources
var resourceGroupStorage = replace(
  replace(
    replace(nameConv_HP_ResGroups, 'TOKEN', 'storage'),
    'LOCATION',
    '${locations[locationVirtualMachines].abbreviation}'
  ),
  'RESOURCETYPE',
  '${resourceAbbreviations.resourceGroups}'
)
var netAppAccountName = replace(
  replace(
    replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.netAppAccounts),
    'LOCATION',
    locations[locationVirtualMachines].abbreviation
  ),
  'TOKEN-',
  ''
)
var netAppCapacityPoolName = replace(
  replace(
    replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.netAppCapacityPools),
    'LOCATION',
    locations[locationVirtualMachines].abbreviation
  ),
  'TOKEN-',
  ''
)

// App Attach and FSLogix Storage Account Naming Convention (max 15 characters for domain join)
var appAttachStorageAccountName = take('appattach${uniqueStringManagement}', 15)
var keyVaultNameAppAttach = nameConvResTypeAtEnd ? '${appAttachStorageAccountName}-${locations[locationVirtualMachines].abbreviation}-${resourceAbbreviations.keyVaults}' : '${resourceAbbreviations.keyVaults}-${appAttachStorageAccountName}-${locations[locationVirtualMachines].abbreviation}'
var uniqueStringStorage = uniqueString(subscription().subscriptionId, resourceGroupStorage)
var fslogixStorageAccountNamePrefix = empty(fslogixStorageCustomPrefix) ? take('fslogix${uniqueStringStorage}', 13) : toLower(fslogixStorageCustomPrefix)

var increaseQuotaFAStorageAccountName = take('saquota${uniqueStringStorage}', 13)
var sessionHostReplacerFAStorageAccountName = 'shreplacer${uniqueStringHosts}'
var keyVaultNameProfileStorage = nameConvResTypeAtEnd ? '${take('fslogix${uniqueStringStorage}', 13)}-${locations[locationVirtualMachines].abbreviation}-${resourceAbbreviations.keyVaults}' : '${resourceAbbreviations.keyVaults}-${take('fslogix${uniqueStringStorage}', 13)}-${locations[locationVirtualMachines].abbreviation}'

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

output appInsightsNames object = {
  IncreaseStorageQuota: replace(appInsightsNameConv, 'TOKEN-', 'saquota-')
  SessionHostReplacement: replace(appInsightsNameConv, 'TOKEN-', 'shreplacer-')
}
output appServicePlanName string = appServicePlanName
output availabilitySetNamePrefix string = availabilitySetNamePrefix
output dataCollectionEndpointName string = dataCollectionEndpointName
output depVirtualMachineName string = depVirtualMachineName
output depVirtualMachineNicName string = depVirtualMachineNicName
output depVirtualMachineDiskName string = depVirtualMachineDiskName
output desktopApplicationGroupName string = desktopApplicationGroupName
output diskAccessName string = diskAccessName
output diskEncryptionSetNames object = {
  ConfidentialVMs: replace(diskEncryptionSetNameConv, 'TOKEN-', 'confvm-customer-keys-')
  CustomerManaged: replace(diskEncryptionSetNameConv, 'TOKEN-', 'customer-keys-')
  PlatformAndCustomerManaged: replace(diskEncryptionSetNameConv, 'TOKEN-', 'platform-and-customer-keys-')
}
output diskNamePrefix string = diskNamePrefix
output fslogixFileShareNames object = fslogixfileShareNames
output functionAppNames object = {
  IncreaseStorageQuota: replace(functionAppNameConv, 'TOKEN-', 'saquota-')
  SessionHostReplacement: replace(functionAppNameConv, 'TOKEN-', 'shreplacer-')
}
output globalFeedWorkspaceName string = globalFeedWorkspaceName
output hostPoolName string = hostPoolName
output keyVaultNames object = {
  AppAttachEncryptionKeys: keyVaultNameAppAttach
  FSLogixEncryptionKeys: keyVaultNameProfileStorage
  VMEncryptionKeys: keyVaultNameVMs
  VMSecrets: keyVaultNameSecrets
}
output locations object = locations
output logAnalyticsWorkspaceName string = logAnalyticsWorkspaceName
output netAppAccountName string = netAppAccountName
output netAppCapacityPoolName string = netAppCapacityPoolName
output networkInterfaceNamePrefix string = networkInterfaceNamePrefix
output privateEndpointNameConv string = privateEndpointNameConv
output privateEndpointNICNameConv string = privateEndpointNICNameConv
output recoveryServicesVaultNames object = {
  FSLogixStorage: replace(recoveryServicesVaultsNameConv, 'TOKEN-', 'fslogix-storage-')
  VirtualMachines: replace(recoveryServicesVaultsNameConv, 'TOKEN-', 'virtual-machines-')
}
output resourceGroupControlPlane string = resourceGroupControlPlane
output resourceGroupGlobalFeed string = globalFeedResourceGroupName
output resourceGroupHosts string = resourceGroupHosts
output resourceGroupDeployment string = resourceGroupDeployment
output resourceGroupManagement string = resourceGroupManagement
output resourceGroupStorage string = resourceGroupStorage
output scalingPlanName string = scalingPlanName
output storageAccountNames object = {
  AppAttach: appAttachStorageAccountName
  FSLogix: fslogixStorageAccountNamePrefix
  IncreaseStorageQuota: increaseQuotaFAStorageAccountName
  SessionHostReplacement: sessionHostReplacerFAStorageAccountName
}
output userAssignedIdentityNameConv string = userAssignedIdentityNameConv
output virtualMachineNamePrefix string = virtualMachineNamePrefix
output workspaceName string = workspaceName
