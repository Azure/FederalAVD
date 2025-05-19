targetScope = 'subscription'

param existingHostPoolResourceId string
param existingFeedWorkspaceResourceId string
param fslogixStorageCustomPrefix string
param identifier string
param index string
param locationControlPlane string
param locationGlobalFeed string
param locationVirtualMachines string
param nameConvResTypeAtEnd bool
param virtualMachineNamePrefix string

var locations = startsWith(environment().name, 'US') ? null : (loadJsonContent('../../../.common/data/locations.json'))[environment().name]
#disable-next-line BCP329
var locationVirtualMachinesAbbreviation = startsWith(environment().name, 'US') ? substring(locationVirtualMachines, 5, length(locationVirtualMachines) - 5): locations[locationVirtualMachines].abbreviation
#disable-next-line BCP329
var locationControlPlaneAbbreviation = startsWith(environment().name, 'US') ? substring(locationControlPlane, 5, length(locationVirtualMachines) - 5): locations[locationControlPlane].abbreviation

var resourceAbbreviations = loadJsonContent('../../../.common/data/resourceAbbreviations.json')

var existingHostPoolName = empty(existingHostPoolResourceId) ? '' : split(existingHostPoolResourceId, '/')[8]

var nameConvReversed = !empty(existingHostPoolName) ? !startsWith(existingHostPoolName, resourceAbbreviations.hostPools) : nameConvResTypeAtEnd

var arrHostPoolName = split(existingHostPoolName, '-')
var lengthArrHostPoolName = length(arrHostPoolName)

var hpIdentifier = !empty(existingHostPoolName) ? nameConvReversed ? lengthArrHostPoolName < 5 ? arrHostPoolName[0] : '${arrHostPoolName[0]}-${arrHostPoolName[1]}' : lengthArrHostPoolName < 5 ? arrHostPoolName[1] : '${arrHostPoolName[1]}-${arrHostPoolName[2]}' : identifier
var hpIndex = !empty(existingHostPoolName) ? lengthArrHostPoolName == 3 ? '' : nameConvReversed ? lengthArrHostPoolName < 5 ? arrHostPoolName[1] : arrHostPoolName[2] : lengthArrHostPoolName < 5 ? arrHostPoolName[2] : arrHostPoolName[3] : index  

var hpBaseName = empty(hpIndex) ? hpIdentifier : '${hpIdentifier}-${hpIndex}'
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
  replace(
    replace(nameConv_HP_ResGroups, 'TOKEN', 'deployment'),
    'LOCATION',
    '${locationVirtualMachinesAbbreviation}'
  ),
  'RESOURCETYPE',
  '${resourceAbbreviations.resourceGroups}'
)
var depVirtualMachineNameTemp = replace(
  replace(
    replace(
      replace(nameConv_HP_Resources, 'RESOURCETYPE', ''),
      'LOCATION',
      locationVirtualMachinesAbbreviation
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
    locationVirtualMachinesAbbreviation
  ),
  'RESOURCETYPE',
  resourceAbbreviations.resourceGroups
)
var uniqueStringManagement = uniqueString(subscription().subscriptionId, resourceGroupManagement)
var appServicePlanName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.appServicePlans),
    'LOCATION',
    locationVirtualMachinesAbbreviation
  ),
  'TOKEN-',
  ''
)

// key vaults must be named with a length of 3 - 24 characters and must be globally unique.
var keyVaultNameSecrets = replace(
  replace(
    replace(nameConv_Shared_Resources, 'TOKEN', 'sec-${take(uniqueStringManagement, 8)}'),
    'LOCATION',
    locationVirtualMachinesAbbreviation
  ),
  'RESOURCETYPE',
  resourceAbbreviations.keyVaults
)
var keyVaultNameEncryption = replace(
  replace(
    replace(nameConv_Shared_Resources, 'TOKEN', 'enc-${take(uniqueStringManagement, 8)}'),
    'LOCATION',
    locationVirtualMachinesAbbreviation
  ),
  'RESOURCETYPE',
  resourceAbbreviations.keyVaults
)

var dataCollectionEndpointName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.dataCollectionEndpoints),
    'LOCATION',
    locationVirtualMachinesAbbreviation
  ),
  'TOKEN-',
  ''
)

var logAnalyticsWorkspaceName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.logAnalyticsWorkspaces),
    'LOCATION',
    locationVirtualMachinesAbbreviation
  ),
  'TOKEN-',
  ''
)

// Global Feed Resources
var globalFeedResourceGroupName = !(empty(locationGlobalFeed))
  ? replace(
      replace(
        (nameConvReversed ? 'avd-global-feed-${nameConvSuffix}' : 'RESOURCETYPE-avd-global-feed-${nameConvSuffix}'),
        'LOCATION',
        locationControlPlaneAbbreviation
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
          '${locationControlPlaneAbbreviation}'
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
        locationControlPlaneAbbreviation
      ),
      'TOKEN-',
      ''
    )
  : last(split(existingFeedWorkspaceResourceId, '/'))

// Control Plane HostPool Resources
var desktopApplicationGroupName = replace(
  replace(replace(nameConv_HP_Resources, 'TOKEN-', ''), 'RESOURCETYPE', resourceAbbreviations.desktopApplicationGroups),
  'LOCATION',
  locationControlPlaneAbbreviation
)
var hostPoolName = replace(
  replace(replace(nameConv_HP_Resources, 'TOKEN-', ''), 'RESOURCETYPE', resourceAbbreviations.hostPools),
  'LOCATION',
  locationControlPlaneAbbreviation
)
var scalingPlanName = replace(
  replace(replace(nameConv_HP_Resources, 'TOKEN-', ''), 'RESOURCETYPE', resourceAbbreviations.scalingPlans),
  'LOCATION',
  locationControlPlaneAbbreviation
)

// Common HostPool Specific Resource Naming Conventions
var uniqueStringHosts = uniqueString(subscription().subscriptionId, resourceGroupHosts)
var appInsightsNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.applicationInsights),
  'LOCATION',
  locationVirtualMachinesAbbreviation
)
var functionAppNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.functionApps),
  'LOCATION',
  locationVirtualMachinesAbbreviation
)

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
var recoveryServicesVaultsNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.recoveryServicesVaults),
  'LOCATION',
  locationVirtualMachinesAbbreviation
)
var userAssignedIdentityNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.userAssignedIdentities),
  'LOCATION',
  locationVirtualMachinesAbbreviation
)

// Compute Resources
var resourceGroupHosts = replace(
  replace(
    replace(nameConv_HP_ResGroups, 'TOKEN', 'hosts'),
    'LOCATION',
    '${locationVirtualMachinesAbbreviation}'
  ),
  'RESOURCETYPE',
  '${resourceAbbreviations.resourceGroups}'
)
var vmNamePrefixWithoutDash = toLower(last(virtualMachineNamePrefix) == '-'
  ? take(virtualMachineNamePrefix, length(virtualMachineNamePrefix) - 1)
  : virtualMachineNamePrefix)
var availabilitySetNamePrefix = nameConvReversed
  ? '${vmNamePrefixWithoutDash}-${resourceAbbreviations.availabilitySets}-'
  : '${resourceAbbreviations.availabilitySets}-${vmNamePrefixWithoutDash}-'
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
    locationVirtualMachinesAbbreviation
  ),
  'TOKEN-',
  ''
)
// Disk Encryption Set Names - Max length 80 Characters
var diskEncryptionSetNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.diskEncryptionSets),
  'LOCATION',
  locationVirtualMachinesAbbreviation
)

// Storage Resources
var resourceGroupStorage = replace(
  replace(
    replace(nameConv_HP_ResGroups, 'TOKEN', 'storage'),
    'LOCATION',
    '${locationVirtualMachinesAbbreviation}'
  ),
  'RESOURCETYPE',
  '${resourceAbbreviations.resourceGroups}'
)
var netAppAccountName = replace(
  replace(
    replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.netAppAccounts),
    'LOCATION',
    locationVirtualMachinesAbbreviation
  ),
  'TOKEN-',
  ''
)
var netAppCapacityPoolName = replace(
  replace(
    replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.netAppCapacityPools),
    'LOCATION',
    locationVirtualMachinesAbbreviation
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
  fslogix: '${hpBaseName}-encryption-key-${fslogixStorageAccountNamePrefix}##'
  increaseStorageQuota: '${hpBaseName}-encryption-key-${increaseQuotaFAStorageAccountName}'
  sessionHostReplacement: '${hpBaseName}-encryption-key-${sessionHostReplacerFAStorageAccountName}'
  virtualMachines: '${hpBaseName}-encryption-key-vms'
  confidentialVMs: '${hpBaseName}-encryption-key-confidential-vms'
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
