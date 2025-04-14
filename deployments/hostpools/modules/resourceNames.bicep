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
var depVirtualMachineDiskName = '${depVirtualMachineName}-${resourceAbbreviations.osdisks}'
var depVirtualMachineNicName = '${depVirtualMachineName}-${resourceAbbreviations.networkInterfaces}'

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
var keyVaultNameSecrets = replace(
  replace(
    replace(nameConv_Shared_Resources, 'TOKEN', 'sec-${take(uniqueStringManagement, 8)}'),
    'LOCATION',
    locations[locationVirtualMachines].abbreviation
  ),
  'RESOURCETYPE',
  resourceAbbreviations.keyVaults
)
var keyVaultNameEncryption = replace(
  replace(
    replace(nameConv_Shared_Resources, 'TOKEN', 'enc-${take(uniqueStringManagement, 8)}'),
    'LOCATION',
    locations[locationVirtualMachines].abbreviation
  ),
  'RESOURCETYPE',
  resourceAbbreviations.keyVaults
)

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
var virtualMachineNameConv = nameConvResTypeAtEnd
  ? '${virtualMachineNamePrefix}###-${resourceAbbreviations.virtualMachines}'
  : '${resourceAbbreviations.virtualMachines}-${virtualMachineNamePrefix}###'
var diskNameConv = nameConvResTypeAtEnd
  ? '${virtualMachineNamePrefix}###-${resourceAbbreviations.osdisks}'
  : '${resourceAbbreviations.osdisks}-${virtualMachineNamePrefix}###'
var networkInterfaceNameConv = nameConvResTypeAtEnd
  ? '${virtualMachineNamePrefix}###-${resourceAbbreviations.networkInterfaces}'
  : '${resourceAbbreviations.networkInterfaces}-${virtualMachineNamePrefix}###'
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
var uniqueStringStorage = uniqueString(subscription().subscriptionId, resourceGroupStorage)
var fslogixStorageAccountNamePrefix = empty(fslogixStorageCustomPrefix)
  ? take('fslogix${uniqueStringStorage}', 13)
  : toLower(fslogixStorageCustomPrefix)
var increaseQuotaFAStorageAccountName = take('saquota${uniqueStringStorage}', 13)
var sessionHostReplacerFAStorageAccountName = 'shreplacer${uniqueStringHosts}'

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
  increaseStorageQuota: replace(appInsightsNameConv, 'TOKEN-', 'saquota-')
  sessionHostReplacement: replace(appInsightsNameConv, 'TOKEN-', 'shreplacer-')
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
  confidentialVMs: replace(diskEncryptionSetNameConv, 'TOKEN-', 'confvm-customer-keys-')
  customerManaged: replace(diskEncryptionSetNameConv, 'TOKEN-', 'customer-keys-')
  platformAndCustomerManaged: replace(diskEncryptionSetNameConv, 'TOKEN-', 'platform-and-customer-keys-')
}
output fslogixFileShareNames object = fslogixfileShareNames
output functionAppNames object = {
  increaseStorageQuota: replace(functionAppNameConv, 'TOKEN-', 'saquota-')
  sessionHostReplacement: replace(functionAppNameConv, 'TOKEN-', 'shreplacer-')
}
output globalFeedWorkspaceName string = globalFeedWorkspaceName
output hostPoolName string = hostPoolName
output keyVaultNames object = {
  encryptionKeys: keyVaultNameEncryption
  secrets: keyVaultNameSecrets
}
output encryptionKeyNames object = {
  appAttach: 'encryption-key-appattach-${appAttachStorageAccountName}'
  fslogix: '${hpBaseName}-encryption-key-fslogix-${fslogixStorageAccountNamePrefix}##'
  increaseStorageQuota: '${hpBaseName}-encryption-key-increase-storage-quota-${increaseQuotaFAStorageAccountName}'
  sessionHostReplacement: '${hpBaseName}-encryption-key-session-host-replacement-${sessionHostReplacerFAStorageAccountName}'
  virtualMachines: '${hpBaseName}-encryption-key-virtual-machines'
}
output locations object = locations
output logAnalyticsWorkspaceName string = logAnalyticsWorkspaceName
output netAppAccountName string = netAppAccountName
output netAppCapacityPoolName string = netAppCapacityPoolName
output privateEndpointNameConv string = privateEndpointNameConv
output privateEndpointNICNameConv string = privateEndpointNICNameConv
output recoveryServicesVaultNames object = {
  fslogixStorage: replace(recoveryServicesVaultsNameConv, 'TOKEN-', 'fslogix-storage-')
  virtualMachines: replace(recoveryServicesVaultsNameConv, 'TOKEN-', 'virtual-machines-')
}
output resourceGroupControlPlane string = resourceGroupControlPlane
output resourceGroupGlobalFeed string = globalFeedResourceGroupName
output resourceGroupHosts string = resourceGroupHosts
output resourceGroupDeployment string = resourceGroupDeployment
output resourceGroupManagement string = resourceGroupManagement
output resourceGroupStorage string = resourceGroupStorage
output scalingPlanName string = scalingPlanName
output storageAccountNames object = {
  appAttach: appAttachStorageAccountName
  fslogix: fslogixStorageAccountNamePrefix
  increaseStorageQuota: increaseQuotaFAStorageAccountName
  sessionHostReplacement: sessionHostReplacerFAStorageAccountName
}
output userAssignedIdentityNameConv string = userAssignedIdentityNameConv
output virtualMachineNameConv string = virtualMachineNameConv
output virtualMachineDiskNameConv string = diskNameConv
output virtualMachineNicNameConv string = networkInterfaceNameConv
output workspaceName string = workspaceName
