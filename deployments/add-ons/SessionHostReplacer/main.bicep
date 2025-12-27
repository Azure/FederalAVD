metadata name = 'AVD Session Host Replacer Add-On'
metadata description = 'Deploys automated session host lifecycle management for Azure Virtual Desktop'
metadata owner = 'FederalAVD'

// ========== //
// Parameters //
// ========== //

// ================================================================================================
// Common Parameters
// These parameters apply to the overall deployment and are shared across multiple resources.
// ================================================================================================

@description('Optional. The location for all resources. Defaults to deployment location.')
param location string = resourceGroup().location

@description('Optional. Tags for all resources.')
param tags object = {}

// ================================================================================================
// Function App Infrastructure Parameters
// These parameters configure the Azure Function App infrastructure including networking, 
// security, encryption, and monitoring capabilities.
// ================================================================================================

@description('Required. The resource ID of the User-Assigned Managed Identity with Microsoft Graph API permissions (Device.ReadWrite.All, DeviceManagementManagedDevices.ReadWrite.All).')
param sessionHostReplacerUserAssignedIdentityResourceId string

@description('Optional. The resource ID of an existing App Service Plan for the function app. If not provided, a new plan will be deployed.')
param appServicePlanResourceId string = ''

@description('Optional. Whether to deploy the App Service Plan with zone redundancy. Only applies if appServicePlanResourceId is not provided. Default is false.')
param zoneRedundant bool = false

@description('Optional. Enable private endpoints for function app and storage. Default is false.')
param privateEndpoint bool = false

@description('Optional. The subnet resource ID for private endpoints. Required if privateEndpoint is true.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. The subnet resource ID for the function app VNet integration. Required if privateEndpoint is true.')
param functionAppDelegatedSubnetResourceId string = ''

@description('Optional. Private DNS Zone resource IDs. Required if privateEndpoint is true.')
param azureBlobPrivateDnsZoneResourceId string = ''
param azureFilePrivateDnsZoneResourceId string = ''
param azureFunctionAppPrivateDnsZoneResourceId string = ''
param azureQueuePrivateDnsZoneResourceId string = ''
param azureTablePrivateDnsZoneResourceId string = ''

@description('Optional. The resource ID of the Key Vault for encryption. Required if keyManagementStorageAccounts is set to Customer.')
param encryptionKeyVaultResourceId string = ''

@description('Optional. Key management solution for storage accounts. Options: Platform, Customer.')
@allowed([
  'MicrosoftManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
param keyManagementStorageAccounts string = 'MicrosoftManaged'

@description('Optional. Log Analytics Workspace resource ID for Application Insights.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Private Link Scope resource ID for Application Insights.')
param privateLinkScopeResourceId string = ''

// ================================================================================================
// Function App Runtime/Execution Parameters
// These parameters control the behavior and execution logic of the session host replacer function,
// including lifecycle policies, tagging strategies, device cleanup, and execution schedule.
// ================================================================================================

@description('Required. The resource ID of the Key Vault containing session host credential secrets (VirtualMachineAdminPassword, VirtualMachineAdminUserName, DomainJoinUserPassword, DomainJoinUserPrincipalName).')
param credentialsKeyVaultResourceId string

@description('Optional. The resource ID of the Template Spec version for session host deployments. If not provided, a new template spec will be created.')
param sessionHostTemplateSpecVersionResourceId string = ''

@description('Optional. The name of the Template Spec to create. Defaults to hostpool-based naming.')
param templateSpecName string = ''

@description('Optional. The version of the Template Spec. Default is 1.0.0.')
param templateSpecVersion string = '1.0.0'

@description('Optional. Timer schedule for the function app (cron expression). Default is every hour.')
param timerSchedule string = '0 0 * * * *'

@description('Optional. The target age in days for session hosts before replacement. Default is 45 days.')
@minValue(1)
@maxValue(365)
param targetVMAgeDays int = 45

@description('Optional. The grace period in hours after draining before deleting session hosts. Default is 24 hours.')
@minValue(1)
@maxValue(168)
param drainGracePeriodHours int = 24

@description('Optional. Whether to fix session host tags during execution. Default is true.')
param fixSessionHostTags bool = true

@description('Optional. Whether to include pre-existing session hosts in automation. Default is true.')
param includePreExistingSessionHosts bool = true

@description('Optional. Tag name to identify session hosts included in automation. Default is IncludeInAutoReplace.')
param tagIncludeInAutomation string = 'IncludeInAutoReplace'

@description('Optional. Tag name for deploy timestamp. Default is AutoReplaceDeployTimestamp.')
param tagDeployTimestamp string = 'AutoReplaceDeployTimestamp'

@description('Optional. Tag name for pending drain timestamp. Default is AutoReplacePendingDrainTimestamp.')
param tagPendingDrainTimestamp string = 'AutoReplacePendingDrainTimestamp'

@description('Optional. Tag name for scaling plan exclusion. Default is ScalingPlanExclusion.')
param tagScalingPlanExclusionTag string = 'ScalingPlanExclusion'

@description('Optional. Whether to remove Entra ID device records when deleting session hosts. Default is true.')
param removeEntraDevice bool = true

@description('Optional. Whether to remove Intune device records when deleting session hosts. Default is true.')
param removeIntuneDevice bool = true

@description('Optional. Enable progressive scale-up with percentage-based batching for deployments. When enabled, the function will start with a small percentage of needed hosts and gradually increase. Default is false.')
param enableProgressiveScaleUp bool = false

@description('Optional. Initial deployment size as percentage of total needed hosts. Used when progressive scale-up is enabled. Default is 10%.')
@minValue(1)
@maxValue(100)
param initialDeploymentPercentage int = 10

@description('Optional. Percentage increment added after each successful deployment run. Used when progressive scale-up is enabled. Default is 20%.')
@minValue(5)
@maxValue(50)
param scaleUpIncrementPercentage int = 20

@description('Optional. Maximum number of hosts to deploy per run (ceiling constraint). Prevents deploying more than this number even if percentage calculation is higher. Default is 10.')
@minValue(1)
@maxValue(50)
param maxDeploymentBatchSize int = 10

@description('Optional. Number of consecutive successful deployment runs required before increasing the deployment percentage. Default is 1.')
@minValue(1)
@maxValue(5)
param successfulRunsBeforeScaleUp int = 1

// ================================================================================================
// Session Host Configuration Parameters
// These parameters define the configuration for session hosts that will be deployed as replacements.
// They are passed to the Template Spec deployment when creating new session hosts.
// ================================================================================================
@description('Required. The resource ID of the resource group where virtual machines are deployed.')
param virtualMachinesResourceGroupId string

@description('Required. The resource ID of the AVD Host Pool where session hosts will be registered.')
param hostPoolResourceId string

@description('Required. The VM name prefix used for session hosts.')
param virtualMachineNamePrefix string

@description('Optional. VM name index length for padding.')
param vmNameIndexLength int = 3

@description('Optional. Publisher of the marketplace image. Default is MicrosoftWindowsDesktop.')
param imagePublisher string = 'MicrosoftWindowsDesktop'

@description('Optional. Offer of the marketplace image. Default is windows-11.')
param imageOffer string = 'windows-11'

@description('Optional. SKU of the marketplace image. Default is win11-25h2-avd.')
param imageSku string = 'win11-25h2-avd'

@description('Optional. The resource ID of a custom image to use for session hosts. If provided, imagePublisher, imageOffer, and imageSku are ignored.')
param customImageResourceId string = ''

@description('Optional. The VM size for session hosts.')
param virtualMachineSize string = 'Standard_D4ads_v5'

@description('Required. The subnet resource ID for session host NICs.')
param virtualMachineSubnetResourceId string

@description('Optional. The identity solution for session hosts.')
@allowed([
  'ActiveDirectoryDomainServices'
  'EntraDomainServices'
  'EntraKerberos-Hybrid'
  'EntraKerberos-CloudOnly'
  'EntraId'
])
param identitySolution string = 'ActiveDirectoryDomainServices'

@description('Optional. The domain name for domain join.')
param domainName string = ''

@description('Optional. The OU path for domain join.')
param ouPath string = ''

@description('Optional. Enable Intune enrollment for Entra joined VMs.')
param intuneEnrollment bool = false

@description('Optional. The time zone for session hosts.')
param timeZone string = 'Eastern Standard Time'

@description('Optional. Availability configuration.')
@allowed([
  'AvailabilityZones'
  'AvailabilitySets'
  'None'
])
param availability string = 'AvailabilityZones'

@description('Optional. Availability zones for session hosts.')
param availabilityZones array = []

@description('Optional. Security type for session hosts.')
@allowed([
  'Standard'
  'TrustedLaunch'
  'ConfidentialVM'
])
param securityType string = 'TrustedLaunch'

@description('Optional. Enable secure boot.')
param secureBootEnabled bool = true

@description('Optional. Enable vTPM.')
param vTpmEnabled bool = true

@description('Optional. Enable integrity monitoring.')
param integrityMonitoring bool = true

@description('Optional. Enable encryption at host.')
param encryptionAtHost bool = true

@description('Optional. Enable confidential VM OS disk encryption.')
param confidentialVMOSDiskEncryption bool = false

@description('Optional. OS disk size in GB. 0 uses image default.')
param diskSizeGB int = 0

@description('Optional. OS disk SKU.')
@allowed([
  'Premium_LRS'
  'StandardSSD_LRS'
  'Standard_LRS'
])
param diskSku string = 'Premium_LRS'

@description('Optional. Enable accelerated networking.')
param enableAcceleratedNetworking bool = true

@description('Optional. Enable monitoring with Azure Monitor Agent.')
param enableMonitoring bool = false

@description('Optional. Dedicated host resource ID.')
param dedicatedHostResourceId string = ''

@description('Optional. Dedicated host group resource ID.')
param dedicatedHostGroupResourceId string = ''

@description('Optional. Dedicated host group zones.')
param dedicatedHostGroupZones array = []

@description('Optional. Existing disk encryption set resource ID.')
param existingDiskEncryptionSetResourceId string = ''

@description('Optional. Existing disk access resource ID.')
param existingDiskAccessResourceId string = ''

@description('Optional. AVD Insights data collection rules resource ID.')
param avdInsightsDataCollectionRulesResourceId string = ''

@description('Optional. VM Insights data collection rules resource ID.')
param vmInsightsDataCollectionRulesResourceId string = ''

@description('Optional. Security data collection rules resource ID.')
param securityDataCollectionRulesResourceId string = ''

@description('Optional. Data collection endpoint resource ID.')
param dataCollectionEndpointResourceId string = ''

@description('Optional. FSLogix configuration - enable session host configuration.')
param fslogixConfigureSessionHosts bool = false

@description('Optional. FSLogix container type.')
@allowed([
  'ProfileContainer'
  'OfficeContainer'
  'ProfileContainer OfficeContainer'
  'ProfileContainer CloudCache'
  'OfficeContainer CloudCache'
  'ProfileContainer OfficeContainer CloudCache'
])
param fslogixContainerType string = 'ProfileContainer'

@description('Optional. FSLogix file share names.')
param fslogixFileShareNames array = ['profile-containers']

@description('Optional. FSLogix container size in MBs.')
param fslogixSizeInMBs int = 30000

@description('Optional. FSLogix storage service.')
@allowed([
  'AzureFiles'
  'AzureNetAppFiles'
])
param fslogixStorageService string = 'AzureFiles'

@description('Optional. FSLogix local storage account resource IDs.')
param fslogixLocalStorageAccountResourceIds array = []

@description('Optional. FSLogix remote storage account resource IDs.')
param fslogixRemoteStorageAccountResourceIds array = []

@description('Optional. FSLogix local NetApp volume resource IDs.')
param fslogixLocalNetAppVolumeResourceIds array = []

@description('Optional. FSLogix remote NetApp volume resource IDs.')
param fslogixRemoteNetAppVolumeResourceIds array = []

@description('Optional. FSLogix OSS groups for sharding.')
param fslogixOSSGroups array = []

@description('Optional. AVD Agents DSC package name or URL.')
param avdAgentsDSCPackage string = 'Configuration_1.0.03211.1002.zip'

@description('Optional. Artifacts container URI for custom scripts.')
param artifactsContainerUri string = ''

@description('Optional. Artifacts user assigned identity resource ID.')
param artifactsUserAssignedIdentityResourceId string = ''

@description('Optional. Session host customizations array.')
param sessionHostCustomizations array = []

// ========== //
// Variables  //
// ========== //

var deploymentSuffix = uniqueString(resourceGroup().id, deployment().name)
var hostPoolName = split(hostPoolResourceId, '/')[8]
var hostPoolResourceGroupName = split(hostPoolResourceId, '/')[4]
var hostPoolSubscriptionId = split(hostPoolResourceId, '/')[2]
var virtualMachineResourceGroupLocation = reference(virtualMachinesResourceGroupId, '2021-04-01', 'Full').location
var virtualMachinesResourceGroupName = last(split(virtualMachinesResourceGroupId, '/'))
var virtualMachinesSubscriptionId = split(virtualMachinesResourceGroupId, '/')[2]

// Template Spec resource group - either from provided resource ID or current resource group
var templateSpecResourceGroupId = !empty(sessionHostTemplateSpecVersionResourceId)
  ? '/subscriptions/${split(sessionHostTemplateSpecVersionResourceId, '/')[2]}/resourceGroups/${split(sessionHostTemplateSpecVersionResourceId, '/')[4]}'
  : resourceGroup().id

// Naming Convention Logic (derived from resourceNames.bicep)
var cloud = toLower(environment().name)
var locationsObject = loadJsonContent('../../../.common/data/locations.json')
var locationsEnvProperty = startsWith(cloud, 'us') ? 'other' : cloud
var locations = locationsObject[locationsEnvProperty]
// the graph endpoint varies for USGov and other US clouds. The DoD cloud uses a different endpoint. It will be handled within the function app code.
var graphEndpoint = environment().name == 'AzureUSGovernment' ? 'https://graph.microsoft.us' : startsWith(environment().name, 'us') ? 'https://graph.${environment().suffixes.storage}' : 'https://graph.microsoft.com'


var functionAppRegionAbbreviation = locations[location].abbreviation
var resourceAbbreviations = loadJsonContent('../../../.common/data/resourceAbbreviations.json')

// Dynamically determine naming convention from existing host pool name
var nameConvReversed = startsWith(hostPoolName, resourceAbbreviations.hostPools)
  ? false // Resource type is at the beginning (e.g., "hp-avd-01")
  : endsWith(hostPoolName, resourceAbbreviations.hostPools)
      ? true // Resource type is at the end (e.g., "avd-01-hp")
      : false // Default fallback

var arrHostPoolName = split(hostPoolName, '-')
var lengthArrHostPoolName = length(arrHostPoolName)

var hpIdentifier = nameConvReversed
  ? lengthArrHostPoolName < 5 ? arrHostPoolName[0] : '${arrHostPoolName[0]}-${arrHostPoolName[1]}'
  : lengthArrHostPoolName < 5 ? arrHostPoolName[1] : '${arrHostPoolName[1]}-${arrHostPoolName[2]}'

var hpIndex = lengthArrHostPoolName == 3
  ? ''
  : nameConvReversed
      ? lengthArrHostPoolName < 5 ? arrHostPoolName[1] : arrHostPoolName[2]
      : lengthArrHostPoolName < 5 ? arrHostPoolName[2] : arrHostPoolName[3]

var hpBaseName = empty(hpIndex) ? hpIdentifier : '${hpIdentifier}-${hpIndex}'
var hpResPrfx = nameConvReversed ? hpBaseName : 'RESOURCETYPE-${hpBaseName}'

var nameConvSuffix = nameConvReversed ? 'LOCATION-RESOURCETYPE' : 'LOCATION'
var nameConv_HP_Resources = '${hpResPrfx}-TOKEN-${nameConvSuffix}'

// Generate unique identifiers for resource naming
var uniqueStringHosts = take(uniqueString(virtualMachinesSubscriptionId, virtualMachinesResourceGroupName), 6)

// App Service Plan naming convention
var nameConv_Shared_Resources = nameConvReversed
  ? 'avd-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-TOKEN-${nameConvSuffix}'
var appServicePlanName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.appServicePlans),
    'LOCATION',
    functionAppRegionAbbreviation
  ),
  'TOKEN-',
  ''
)

// Resource naming conventions for session host replacer
var appInsightsNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.applicationInsights),
  'LOCATION',
  functionAppRegionAbbreviation
)
var functionAppNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.functionApps),
  'LOCATION',
  functionAppRegionAbbreviation
)

// Private endpoint naming conventions
var privateEndpointNameConv = replace(
  nameConvReversed
    ? 'RESOURCE-SUBRESOURCE-VNETID-RESOURCETYPE'
    : 'RESOURCETYPE-RESOURCE-SUBRESOURCE-VNETID',
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

// Session host replacer resource names
var sessionHostReplacerFAStorageAccountName = 'shreplacer${uniqueStringHosts}'
var functionAppName = replace(functionAppNameConv, 'TOKEN-', 'shreplacer-${uniqueStringHosts}-')
var storageAccountName = sessionHostReplacerFAStorageAccountName
var appInsightsName = replace(appInsightsNameConv, 'TOKEN-', 'shreplacer-${uniqueStringHosts}-')
var encryptionKeyName = '${hpBaseName}-encryption-key-${sessionHostReplacerFAStorageAccountName}'
var templateSpecNameFinal = !empty(templateSpecName) ? templateSpecName : replace(replace(replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.templateSpecs), 'TOKEN', 'sessionhost'), 'LOCATION', functionAppRegionAbbreviation)

// Virtual Machine naming conventions
var vmNamePrefixWithoutDash = toLower(last(virtualMachineNamePrefix) == '-'
  ? take(virtualMachineNamePrefix, length(virtualMachineNamePrefix) - 1)
  : virtualMachineNamePrefix)
var availabilitySetNamePrefix = nameConvReversed
  ? '${vmNamePrefixWithoutDash}-${resourceAbbreviations.availabilitySets}-'
  : '${resourceAbbreviations.availabilitySets}-${vmNamePrefixWithoutDash}-'
var virtualMachineNameConv = nameConvReversed
  ? 'VMNAMEPREFIX###-${resourceAbbreviations.virtualMachines}'
  : '${resourceAbbreviations.virtualMachines}-VMNAMEPREFIX###'
var diskNameConv = nameConvReversed
  ? 'VMNAMEPREFIX###-${resourceAbbreviations.osdisks}'
  : '${resourceAbbreviations.osdisks}-VMNAMEPREFIX###'
var networkInterfaceNameConv = nameConvReversed
  ? 'VMNAMEPREFIX###-${resourceAbbreviations.networkInterfaces}'
  : '${resourceAbbreviations.networkInterfaces}-VMNAMEPREFIX###'

// Session Host Parameters - Passed to Template Spec Deployment
// These parameters are passed to the function app which will use them when deploying new session hosts
var sessionHostParameters = {
  artifactsContainerUri: artifactsContainerUri
  artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
  availability: availability
  availabilitySetNamePrefix: availabilitySetNamePrefix
  availabilityZones: availabilityZones
  avdAgentsDSCPackage: avdAgentsDSCPackage
  avdInsightsDataCollectionRulesResourceId: avdInsightsDataCollectionRulesResourceId
  confidentialVMOSDiskEncryption: confidentialVMOSDiskEncryption
  credentialsKeyVaultResourceId: credentialsKeyVaultResourceId
  dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
  dedicatedHostGroupResourceId: dedicatedHostGroupResourceId
  dedicatedHostGroupZones: dedicatedHostGroupZones
  dedicatedHostResourceId: dedicatedHostResourceId
  diskSizeGB: diskSizeGB
  diskSku: diskSku
  domainName: domainName
  enableAcceleratedNetworking: enableAcceleratedNetworking
  encryptionAtHost: encryptionAtHost
  existingDiskAccessResourceId: existingDiskAccessResourceId
  existingDiskEncryptionSetResourceId: existingDiskEncryptionSetResourceId
  fslogixConfigureSessionHosts: fslogixConfigureSessionHosts
  fslogixContainerType: fslogixContainerType
  fslogixFileShareNames: fslogixFileShareNames
  fslogixLocalNetAppVolumeResourceIds: fslogixLocalNetAppVolumeResourceIds
  fslogixLocalStorageAccountResourceIds: fslogixLocalStorageAccountResourceIds
  fslogixOSSGroups: fslogixOSSGroups
  fslogixRemoteNetAppVolumeResourceIds: fslogixRemoteNetAppVolumeResourceIds
  fslogixRemoteStorageAccountResourceIds: fslogixRemoteStorageAccountResourceIds
  fslogixSizeInMBs: fslogixSizeInMBs
  fslogixStorageService: fslogixStorageService
  hostPoolResourceId: hostPoolResourceId
  identitySolution: identitySolution
  imageReference: empty(customImageResourceId) ? {
    publisher: imagePublisher
    offer: imageOffer
    sku: imageSku
  } : {
    id: customImageResourceId
  }
  integrityMonitoring: integrityMonitoring
  intuneEnrollment: intuneEnrollment
  location: virtualMachineResourceGroupLocation
  enableMonitoring: enableMonitoring
  networkInterfaceNameConv: networkInterfaceNameConv
  osDiskNameConv: diskNameConv
  ouPath: ouPath
  secureBootEnabled: secureBootEnabled
  securityDataCollectionRulesResourceId: securityDataCollectionRulesResourceId
  securityType: securityType
  sessionHostCustomizations: sessionHostCustomizations
  vmNameIndexLength: vmNameIndexLength
  subnetResourceId: virtualMachineSubnetResourceId
  tags: tags
  timeZone: timeZone
  virtualMachineNameConv: virtualMachineNameConv
  virtualMachineNamePrefix: virtualMachineNamePrefix
  virtualMachineSize: virtualMachineSize
  vmInsightsDataCollectionRulesResourceId: vmInsightsDataCollectionRulesResourceId
  vTpmEnabled: vTpmEnabled
}

// Conditional Template Spec for Session Host Deployment
module templateSpec 'modules/sessionHostTemplateSpec.bicep' = if (empty(sessionHostTemplateSpecVersionResourceId)) {
  name: 'SessionHostTemplateSpec-${deploymentSuffix}'
  params: {
    location: location
    templateSpecName: templateSpecNameFinal
    templateSpecVersion: templateSpecVersion
    tags: union(
      { 'cm-resource-parent': hostPoolResourceId },
      tags[?'Microsoft.Resources/templateSpecs'] ?? {}
    )
  }
}

// Conditional App Service Plan deployment
module hostingPlan '../../sharedModules/custom/functionApp/functionAppHostingPlan.bicep' = if (empty(appServicePlanResourceId)) {
  name: 'FunctionAppHostingPlan-${deploymentSuffix}'
  params: {
    functionAppKind: 'functionApp'
    hostingPlanType: 'FunctionsPremium'
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceResourceId
    location: location
    name: appServicePlanName
    planPricing: 'PremiumV3_P1v3'
    tags: tags
    zoneRedundant: zoneRedundant
  }
}

module functionApp '../../sharedModules/custom/functionApp/functionApp.bicep' = {
  name: 'SessionHostReplacerFunctionApp-${deploymentSuffix}'
  params: {
    location: location
    applicationInsightsName: appInsightsName
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    azureFunctionAppPrivateDnsZoneResourceId: azureFunctionAppPrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    azureTablePrivateDnsZoneResourceId: azureTablePrivateDnsZoneResourceId
    deploymentSuffix: deploymentSuffix
    enableApplicationInsights: !empty(logAnalyticsWorkspaceResourceId)    
    encryptionKeyName: encryptionKeyName
    encryptionKeyVaultResourceId: encryptionKeyVaultResourceId
    functionAppAppSettings: [      
      {
        name: 'GraphEndpoint'
        value: graphEndpoint
      }
      {
        name: 'HostPoolSubscriptionId'
        value: hostPoolSubscriptionId
      }
      {
        name: 'HostPoolResourceGroupName'
        value: hostPoolResourceGroupName
      }
      {
        name: 'HostPoolName'
        value: hostPoolName
      }
      {
        name: 'VirtualMachinesSubscriptionId'
        value: virtualMachinesSubscriptionId
      }
      {
        name: 'VirtualMachinesResourceGroupName'
        value: virtualMachinesResourceGroupName
      }
      {
        name: 'TargetVMAgeDays'
        value: string(targetVMAgeDays)
      }
      {
        name: 'DrainGracePeriodHours'
        value: string(drainGracePeriodHours)
      }
      {
        name: 'FixSessionHostTags'
        value: string(fixSessionHostTags)
      }
      {
        name: 'IncludePreExistingSessionHosts'
        value: string(includePreExistingSessionHosts)
      }
      {
        name: 'Tag_IncludeInAutomation'
        value: tagIncludeInAutomation
      }
      {
        name: 'Tag_DeployTimestamp'
        value: tagDeployTimestamp
      }
      {
        name: 'Tag_PendingDrainTimestamp'
        value: tagPendingDrainTimestamp
      }
      {
        name: 'Tag_ScalingPlanExclusionTag'
        value: tagScalingPlanExclusionTag
      }
      {
        name: 'SessionHostTemplate'
        value: !empty(sessionHostTemplateSpecVersionResourceId) ? sessionHostTemplateSpecVersionResourceId : templateSpec!.outputs.templateSpecVersionResourceId
      }
      {
        name: 'SessionHostParameters'
        value: string(sessionHostParameters)
      }
      {
        name: 'WEBSITE_TIME_ZONE'
        value: timeZone
      }
      {
        name: 'RemoveEntraDevice'
        value: string(removeEntraDevice)
      }
      {
        name: 'RemoveIntuneDevice'
        value: string(removeIntuneDevice)
      }
      {
        name: 'EnableProgressiveScaleUp'
        value: string(enableProgressiveScaleUp)
      }
      {
        name: 'InitialDeploymentPercentage'
        value: string(initialDeploymentPercentage)
      }
      {
        name: 'ScaleUpIncrementPercentage'
        value: string(scaleUpIncrementPercentage)
      }
      {
        name: 'MaxDeploymentBatchSize'
        value: string(maxDeploymentBatchSize)
      }
      {
        name: 'SubscriptionId'
        value: subscription().subscriptionId
      }
      {
        name: 'SuccessfulRunsBeforeScaleUp'
        value: string(successfulRunsBeforeScaleUp)
      }
    ]
    functionAppDelegatedSubnetResourceId: functionAppDelegatedSubnetResourceId
    functionAppName: functionAppName
    functionAppUserAssignedIdentityResourceId: sessionHostReplacerUserAssignedIdentityResourceId
    hostPoolResourceId: hostPoolResourceId
    keyManagementStorageAccounts: keyManagementStorageAccounts
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    privateEndpoint: privateEndpoint
    privateEndpointNameConv: privateEndpointNameConv
    privateEndpointNICNameConv: privateEndpointNICNameConv
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    privateLinkScopeResourceId: privateLinkScopeResourceId
    roleAssignments: [
      {
        roleDefinitionId: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c' // Virtual Machine Contributor
        scope: '/subscriptions/${virtualMachinesSubscriptionId}'
      }
      {
        roleDefinitionId: 'e307426c-f9b6-4e81-87de-d99efb3c32bc' // Desktop Virtualization Host Pool Contributor
        scope: '/subscriptions/${hostPoolSubscriptionId}/resourceGroups/${hostPoolResourceGroupName}'
      }
      {
        roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader to be able to read the Template Spec
        scope: templateSpecResourceGroupId
      }
    ]
    serverFarmId: !empty(appServicePlanResourceId) ? appServicePlanResourceId : hostingPlan!.outputs.hostingPlanId
    storageAccountName: storageAccountName
    tags: tags
  }
}

module functionCode '../../sharedModules/custom/functionApp/function.bicep' = {
  name: 'SessionHostReplacerFunction-${deploymentSuffix}'
  params: {
    files: {
      'requirements.psd1': loadTextContent('functions/requirements.psd1')
      'run.ps1': loadTextContent('functions/run.ps1')
      '../profile.ps1': loadTextContent('functions/profile.ps1')
    }
    functionAppName: functionApp.outputs.functionAppName
    functionName: 'session-host-replacer'
    schedule: timerSchedule
  }
}

// ========== //
// Outputs    //
// ========== //

@description('The name of the deployed function app.')
output functionAppName string = functionApp.outputs.functionAppName
