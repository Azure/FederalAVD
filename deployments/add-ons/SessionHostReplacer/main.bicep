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

@description('Optional. The SKU for the App Service Plan. Only applies if appServicePlanResourceId is not provided. Default is P0v3 for cost optimization.')
@allowed([
  'PremiumV3_P0v3'
  'PremiumV3_P1v3'
  'PremiumV3_P2v3'
  'PremiumV3_P3v3'
])
param appServicePlanSku string = 'PremiumV3_P0v3'

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
param azureFunctionAppPrivateDnsZoneResourceId string = ''
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
param sessionHostTemplateSpecResourceId string = ''

@description('Optional. The name of the Template Spec to create. Defaults to hostpool-based naming.')
param templateSpecName string = ''

@description('Optional. The version of the Template Spec. Default is 1.0.0.')
param templateSpecVersion string = '1.0.0'

@description('Optional. Timer schedule for the function app (NCrontab format: {second} {minute} {hour} {day} {month} {day-of-week}). Default runs every 30 minutes starting at minute 0 (runs at :00 and :30). To stagger across deployments, vary the minute (e.g., "0 15,45 * * * *" runs at :15 and :45 past each hour). For half-hourly execution during specific hours, use "0 0,30 8-17 * * 1-5" for 8 AM to 5 PM weekdays. The UI form automatically generates the correct format when you select hours and start minute.')
param timerSchedule string = '0 0,30 * * * *'

@description('Optional. Whether to deploy the Azure Monitor Workbook dashboard. Set to true for the first deployment or when updating the workbook. Set to false for subsequent deployments in the same subscription to avoid conflicts. Default is true.')
param deployWorkbook bool = true

@description('Optional. The Azure region for the centralized workbook deployment. Defaults to the function app location. The workbook location does not affect its ability to query cross-region Application Insights instances.')
param workbookLocation string = location

@description('Optional. Replacement mode strategy. SideBySide: Adds new hosts before deleting old ones (higher capacity during updates, zero downtime). DeleteFirst: Deletes idle hosts before adding replacements (lower cost, temporary capacity reduction). Default is SideBySide.')
@allowed([
  'SideBySide'
  'DeleteFirst'
])
param replacementMode string = 'SideBySide'

@description('Optional. The grace period in hours after draining before deleting session hosts WITH active sessions. Default is 24 hours.')
@minValue(1)
@maxValue(168)
param drainGracePeriodHours int = 24

@description('Optional. Minimum drain time in minutes for session hosts with ZERO sessions before deletion. With hourly scheduling: 0=current run, 1-60=next run (~1hr), 61-120=second run (~2hrs). Values >0 provide safety buffer for API lag, race conditions, and admin intervention. Default is 15 minutes.')
@minValue(0)
@maxValue(120)
param minimumDrainMinutes int = 15

@description('Optional. Safety floor: minimum percentage of target capacity to maintain during DeleteFirst mode. Deletions are capped to prevent dropping below this threshold. Higher values = more conservative (e.g., 80% keeps more hosts running), lower values = more aggressive (e.g., 50% allows faster replacement). Only applies when replacementMode is DeleteFirst. Default is 80%.')
@minValue(50)
@maxValue(100)
param minimumCapacityPercentage int = 80

@description('Optional. Maximum number of hosts to delete and deploy per cycle in DeleteFirst mode. Controls the pace of replacements - function deletes this many idle hosts, then deploys the same number of replacements. Lower values = slower, safer updates. Only applies when replacementMode is DeleteFirst. Default is 5.')
@minValue(1)
@maxValue(50)
param maxDeletionsPerCycle int = 5

@description('Optional. Minimum host index for hostname numbering in SideBySide mode. Useful for starting numbering at a specific value (e.g., 10 instead of 1). Only applies when replacementMode is SideBySide. Default is 1.')
@minValue(1)
@maxValue(999)
param minimumHostIndex int = 1

@description('Optional. Enable shutdown retention for replaced session hosts in SideBySide mode. When enabled, old session hosts are shutdown (deallocated) instead of deleted, allowing for rollback. They are automatically deleted after the retention period expires. Only applies when replacementMode is SideBySide. Default is false.')
param enableShutdownRetention bool = false

@description('Optional. Number of days to retain shutdown session hosts before automatic deletion in SideBySide mode. Provides rollback window in case issues are discovered with new hosts. Only applies when replacementMode is SideBySide and enableShutdownRetention is true. Default is 3 days.')
@minValue(1)
@maxValue(7)
param shutdownRetentionDays int = 3

@description('Required. The target number of session hosts to maintain in the host pool. Set to 0 for auto-detect mode: the function will automatically maintain whatever count exists when a replacement cycle begins, allowing you to manually scale between image updates.')
@minValue(0)
@maxValue(1000)
param targetSessionHostCount int = 0

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

@description('Optional. Tag name for shutdown timestamp in SideBySide mode with shutdown retention. Default is AutoReplaceShutdownTimestamp.')
param tagShutdownTimestamp string = 'AutoReplaceShutdownTimestamp'

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
param initialDeploymentPercentage int = 20

@description('Optional. Percentage increment added after each successful deployment run. Used when progressive scale-up is enabled. Default is 20%.')
@minValue(5)
@maxValue(50)
param scaleUpIncrementPercentage int = 40

@description('Optional. Maximum number of hosts to deploy per run in SideBySide mode. Controls the pace of new deployments - function adds this many new hosts in parallel before deleting old ones. Lower values = slower rollout, higher values = faster but more resource-intensive. Only applies when replacementMode is SideBySide. Default is 100.')
@minValue(1)
@maxValue(1000)
param maxDeploymentBatchSize int = 100

@description('Optional. Number of consecutive successful deployment runs required before increasing the deployment percentage. Default is 1.')
@minValue(1)
@maxValue(5)
param successfulRunsBeforeScaleUp int = 1

@description('Optional. Delay in days before replacing session hosts after a new image version is detected. Only used when replacementMode is ImageVersion. Default is 0 days.')
@minValue(0)
@maxValue(30)
param replaceSessionHostOnNewImageVersionDelayDays int = 0

@description('Optional. Allow replacement of session hosts even if their current image version is newer than the latest available version. When false (default), session hosts with newer versions will not be replaced to prevent unintended rollbacks. Only used when replacementMode is ImageVersion.')
param allowImageVersionRollback bool = false

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
param sessionHostNamePrefix string

@description('Optional. VM name index length for padding.')
param sessionHostNameIndexLength int = 2

@description('Optional. Publisher of the marketplace image. Default is MicrosoftWindowsDesktop.')
param imagePublisher string = 'MicrosoftWindowsDesktop'

@description('Optional. Offer of the marketplace image. Default is windows-11.')
param imageOffer string = 'windows-11'

@description('Optional. SKU of the marketplace image. Default is win11-25h2-avd.')
param imageSku string = 'win11-25h2-avd'

@description('Optional. The resource ID of a custom image to use for session hosts. If provided, imagePublisher, imageOffer, and imageSku are ignored.')
param customImageResourceId string = ''

@description('Optional. The VM size for session hosts.')
param virtualMachineSize string = 'Standard_D4ads_v6'

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
param availability string = 'None'

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

@description('Optional. Existing disk encryption set resource ID.')
param diskEncryptionSetResourceId string = ''

@description('Optional. AVD Insights data collection rules resource ID.')
param avdInsightsDataCollectionRulesResourceId string = ''

@description('Optional. VM Insights data collection rules resource ID.')
param vmInsightsDataCollectionRulesResourceId string = ''

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
param fslogixSizeInMBs int = 30720

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
param avdAgentsDSCPackage string = 'Configuration_1.0.03266.1110.zip'

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
var hostPoolName = last(split(hostPoolResourceId, '/'))
var hostPoolResourceGroupName = split(hostPoolResourceId, '/')[4]
var hostPoolSubscriptionId = split(hostPoolResourceId, '/')[2]
var virtualMachineResourceGroupLocation = reference(virtualMachinesResourceGroupId, '2021-04-01', 'Full').location
var virtualMachinesResourceGroupName = last(split(virtualMachinesResourceGroupId, '/'))
var virtualMachinesSubscriptionId = split(virtualMachinesResourceGroupId, '/')[2]

// Naming Convention Logic (derived from resourceNames.bicep)
var cloud = toLower(environment().name)
var locationsObject = loadJsonContent('../../../.common/data/locations.json')
var locationsEnvProperty = startsWith(cloud, 'us') ? 'other' : cloud
var locations = locationsObject[locationsEnvProperty]
// the graph endpoint varies for USGov and other US clouds. The DoD cloud uses a different endpoint. It will be handled within the function app code.
var graphEndpoint = cloud == 'azureusgovernment'
  ? 'https://graph.microsoft.us'
  : startsWith(cloud, 'us')
      ? 'https://graph.${environment().suffixes.storage}'
      : 'https://graph.microsoft.com'

var functionAppRegionAbbreviation = locations[location].abbreviation
#disable-next-line BCP329
var varLocationVirtualMachines = startsWith(cloud, 'us')
  ? substring(virtualMachineResourceGroupLocation, 5, length(virtualMachineResourceGroupLocation) - 5)
  : virtualMachineResourceGroupLocation
var virtualMachinesRegionAbbreviation = locations[varLocationVirtualMachines].abbreviation
var resourceAbbreviations = loadJsonContent('../../../.common/data/resourceAbbreviations.json')

// Dynamically determine naming convention from existing host pool name
var nameConvReversed = startsWith(hostPoolName, '${resourceAbbreviations.hostPools}-')
  ? false // Resource type is at the beginning (e.g., "hp-avd-01-eus")
  : endsWith(hostPoolName, '-${resourceAbbreviations.hostPools}')
      ? true // Resource type is at the end (e.g., "avd-01-eus-hp")
      : false // Default fallback

// Extract hpBaseName by removing resource type and location from the host pool name
// Not reversed: hp-{hpBaseName}-{location} → remove first segment (hp) and last segment (location)
// Reversed: {hpBaseName}-{location}-hp → remove last two segments (location-hp)
var arrHostPoolName = split(hostPoolName, '-')
var hpBaseName = nameConvReversed
  ? join(take(arrHostPoolName, length(arrHostPoolName) - 2), '-') // Remove last 2 segments (location-hp)
  : join(take(skip(arrHostPoolName, 1), length(arrHostPoolName) - 2), '-') // Remove first (hp) and last (location)
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

// Private endpoint naming conventions
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

// Session host replacer resource names

// Shared Application Insights naming - same name across all Session Host Replacer deployments
// This enables multi-host-pool monitoring with a single App Insights instance
var appInsightsName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.applicationInsights),
    'TOKEN-',
    'sessionhostreplacer-'
  ),
  'LOCATION',
  functionAppRegionAbbreviation
)

// Enterprise Workbook naming - single workbook for all host pools across all regions
// Azure Monitor Workbooks require GUID names for deterministic deployment
// Removing location enables cross-region monitoring with a single dashboard (like AVD Insights)
var workbookName = guid(subscription().subscriptionId, 'session-host-replacer-workbook')

// Function App naming - unique per host pool
var functionAppName = replace(
  replace(
    replace(
      replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.functionApps),
      'LOCATION',
      functionAppRegionAbbreviation
    ),
    'TOKEN-',
    'shr-${uniqueStringHosts}-'
  ),
  'LOCATION',
  functionAppRegionAbbreviation
)
var storageAccountName = toLower(replace(
  replace(
    replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', ''), 'LOCATION', functionAppRegionAbbreviation),
    'TOKEN-',
    'shr-${uniqueStringHosts}'
  ),
  '-',
  ''
))
var encryptionKeyName = '${hpBaseName}-encryption-key-${storageAccountName}'
var templateSpecNameFinal = !empty(templateSpecName)
  ? templateSpecName
  : replace(
      replace(
        replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.templateSpecs),
        'TOKEN',
        'sessionhost'
      ),
      'LOCATION',
      functionAppRegionAbbreviation
    )

// Virtual Machine naming conventions
var availabilitySetNameConv = nameConvReversed
  ? replace(
      replace(
        replace(
          replace(nameConv_HP_Resources, 'RESOURCETYPE', '##-RESOURCETYPE'),
          'RESOURCETYPE',
          resourceAbbreviations.availabilitySets
        ),
        'LOCATION',
        virtualMachinesRegionAbbreviation
      ),
      'TOKEN-',
      ''
    )
  : '${replace(replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.availabilitySets), 'LOCATION', virtualMachinesRegionAbbreviation), 'TOKEN-', '')}-##'
var virtualMachineNameConv = nameConvReversed
  ? 'VMNAMEPREFIX###-${resourceAbbreviations.virtualMachines}'
  : '${resourceAbbreviations.virtualMachines}-VMNAMEPREFIX###'
var diskNameConv = nameConvReversed
  ? 'VMNAMEPREFIX###-${resourceAbbreviations.osdisks}'
  : '${resourceAbbreviations.osdisks}-VMNAMEPREFIX###'
var networkInterfaceNameConv = nameConvReversed
  ? 'VMNAMEPREFIX###-${resourceAbbreviations.networkInterfaces}'
  : '${resourceAbbreviations.networkInterfaces}-VMNAMEPREFIX###'

// Extract compute gallery resource ID from custom image resource ID
// Image definition format: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gallery}/images/{imageName}
// Image version format: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gallery}/images/{imageName}/versions/{version}
// Gallery format: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gallery}
var computeGalleryResourceId = !empty(customImageResourceId)
  ? join(take(split(customImageResourceId, '/'), 9), '/')
  : ''

// Conditional Session Host Parameters
var paramArtifactsContainerUri = !empty(artifactsContainerUri) ? { artifactsContainerUri: artifactsContainerUri } : {}
var paramArtifactsUserAssignedIdentityResourceId = !empty(artifactsUserAssignedIdentityResourceId) ? { artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId } : {}
var paramAvailabilityZones = !empty(availabilityZones) ? { availabilityZones: availabilityZones } : {}
var paramAvdInsightsDataCollectionRulesResourceId = !empty(avdInsightsDataCollectionRulesResourceId) ? { avdInsightsDataCollectionRulesResourceId: avdInsightsDataCollectionRulesResourceId } : {}
var paramConfidentialVMOSDiskEncryption = confidentialVMOSDiskEncryption ? { confidentialVMOSDiskEncryption: confidentialVMOSDiskEncryption } : {}
var paramDataCollectionEndpointResourceId = !empty(dataCollectionEndpointResourceId) ? { dataCollectionEndpointResourceId: dataCollectionEndpointResourceId } : {}
var paramDiskEncryptionSetResourceId = !empty(diskEncryptionSetResourceId) ? { diskEncryptionSetResourceId: diskEncryptionSetResourceId } : {}
var paramDomainName = !empty(domainName) ? { domainName: domainName } : {}
var paramEnableMonitoring = enableMonitoring ? { enableMonitoring: enableMonitoring } : {}
var paramIntegrityMonitoring = integrityMonitoring ? { integrityMonitoring: integrityMonitoring } : {}
var paramIntuneEnrollment = intuneEnrollment ? { intuneEnrollment: intuneEnrollment } : {}
var paramOuPath = !empty(ouPath) ? { ouPath: ouPath } : {}
var paramSessionHostCustomizations = !empty(sessionHostCustomizations) ? { sessionHostCustomizations: sessionHostCustomizations } : {}
var paramVmInsightsDataCollectionRulesResourceId = !empty(vmInsightsDataCollectionRulesResourceId) ? { vmInsightsDataCollectionRulesResourceId: vmInsightsDataCollectionRulesResourceId } : {}

// FSLogix conditional parameters
var paramFslogixConfigureSessionHosts = fslogixConfigureSessionHosts ? { fslogixConfigureSessionHosts: fslogixConfigureSessionHosts } : {}
var paramFslogixContainerType = fslogixConfigureSessionHosts ? { fslogixContainerType: fslogixContainerType } : {}
var paramFslogixFileShareNames = fslogixConfigureSessionHosts && !empty(fslogixFileShareNames) ? { fslogixFileShareNames: fslogixFileShareNames } : {}
var paramFslogixLocalNetAppVolumeResourceIds = fslogixConfigureSessionHosts && !empty(fslogixLocalNetAppVolumeResourceIds) ? { fslogixLocalNetAppVolumeResourceIds: fslogixLocalNetAppVolumeResourceIds } : {}
var paramFslogixLocalStorageAccountResourceIds = fslogixConfigureSessionHosts && !empty(fslogixLocalStorageAccountResourceIds) ? { fslogixLocalStorageAccountResourceIds: fslogixLocalStorageAccountResourceIds } : {}
var paramFslogixOSSGroups = fslogixConfigureSessionHosts && !empty(fslogixOSSGroups) ? { fslogixOSSGroups: fslogixOSSGroups } : {}
var paramFslogixRemoteNetAppVolumeResourceIds = fslogixConfigureSessionHosts && !empty(fslogixRemoteNetAppVolumeResourceIds) ? { fslogixRemoteNetAppVolumeResourceIds: fslogixRemoteNetAppVolumeResourceIds } : {}
var paramFslogixRemoteStorageAccountResourceIds = fslogixConfigureSessionHosts && !empty(fslogixRemoteStorageAccountResourceIds) ? { fslogixRemoteStorageAccountResourceIds: fslogixRemoteStorageAccountResourceIds } : {}
var paramFslogixSizeInMBs = fslogixConfigureSessionHosts ? { fslogixSizeInMBs: fslogixSizeInMBs } : {}
var paramFslogixStorageService = fslogixConfigureSessionHosts ? { fslogixStorageService: fslogixStorageService } : {}

// Session Host Parameters - Passed to Template Spec Deployment
// These parameters are passed to the function app which will use them when deploying new session hosts
var sessionHostParameters = union(
  {
    availability: availability
    availabilitySetNameConv: availabilitySetNameConv
    avdAgentsDSCPackage: avdAgentsDSCPackage
    credentialsKeyVaultResourceId: credentialsKeyVaultResourceId
    diskSizeGB: diskSizeGB
    diskSku: diskSku
    enableAcceleratedNetworking: enableAcceleratedNetworking
    encryptionAtHost: encryptionAtHost
    hostPoolResourceId: hostPoolResourceId
    identitySolution: identitySolution
    imageReference: empty(customImageResourceId)
      ? {
          publisher: imagePublisher
          offer: imageOffer
          sku: imageSku
        }
      : {
          id: customImageResourceId
        }
    location: virtualMachineResourceGroupLocation
    networkInterfaceNameConv: networkInterfaceNameConv
    osDiskNameConv: diskNameConv
    secureBootEnabled: secureBootEnabled
    securityType: securityType
    sessionHostNameIndexLength: sessionHostNameIndexLength
    subnetResourceId: virtualMachineSubnetResourceId
    tags: tags
    timeZone: timeZone
    virtualMachineNameConv: virtualMachineNameConv
    virtualMachineSize: virtualMachineSize
    vTpmEnabled: vTpmEnabled
  },
  paramArtifactsContainerUri,
  paramArtifactsUserAssignedIdentityResourceId,
  paramAvailabilityZones,
  paramAvdInsightsDataCollectionRulesResourceId,
  paramConfidentialVMOSDiskEncryption,
  paramDataCollectionEndpointResourceId,
  paramDiskEncryptionSetResourceId,
  paramDomainName,
  paramEnableMonitoring,
  paramIntegrityMonitoring,
  paramIntuneEnrollment,
  paramOuPath,
  paramSessionHostCustomizations,
  paramVmInsightsDataCollectionRulesResourceId,
  paramFslogixConfigureSessionHosts,
  paramFslogixContainerType,
  paramFslogixFileShareNames,
  paramFslogixLocalNetAppVolumeResourceIds,
  paramFslogixLocalStorageAccountResourceIds,
  paramFslogixOSSGroups,
  paramFslogixRemoteNetAppVolumeResourceIds,
  paramFslogixRemoteStorageAccountResourceIds,
  paramFslogixSizeInMBs,
  paramFslogixStorageService
)

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: last(split(sessionHostReplacerUserAssignedIdentityResourceId, '/'))
  scope: resourceGroup(
    split(sessionHostReplacerUserAssignedIdentityResourceId, '/')[2],
    split(sessionHostReplacerUserAssignedIdentityResourceId, '/')[4]
  )
}

// Conditional Template Spec for Session Host Deployment
module templateSpec 'modules/sessionHostTemplateSpec.bicep' = if (empty(sessionHostTemplateSpecResourceId)) {
  name: 'SessionHostTemplateSpec-${deploymentSuffix}'
  params: {
    location: location
    templateSpecName: templateSpecNameFinal
    templateSpecVersion: templateSpecVersion
    tags: tags[?'Microsoft.Resources/templateSpecs'] ?? {}
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
    planPricing: appServicePlanSku
    tags: tags
    zoneRedundant: zoneRedundant
  }
}

var monitoringResourceGroupId = !empty(avdInsightsDataCollectionRulesResourceId)
  ? '/subscriptions/${split(avdInsightsDataCollectionRulesResourceId, '/')[2]}/resourceGroups/${split(avdInsightsDataCollectionRulesResourceId, '/')[4]}'
  : !empty(vmInsightsDataCollectionRulesResourceId)
      ? '/subscriptions/${split(vmInsightsDataCollectionRulesResourceId, '/')[2]}/resourceGroups/${split(vmInsightsDataCollectionRulesResourceId, '/')[4]}'
      : !empty(dataCollectionEndpointResourceId)
          ? '/subscriptions/${split(dataCollectionEndpointResourceId, '/')[2]}/resourceGroups/${split(dataCollectionEndpointResourceId, '/')[4]}'
          : ''

var hostPoolResourceGroupId = '/subscriptions/${hostPoolSubscriptionId}/resourceGroups/${hostPoolResourceGroupName}'

var roleAssignmentsResourceGroups = union(
  [
    {
      resourceGroupId: hostPoolResourceGroupId
      roleDefinitionId: 'e307426c-f9b6-4e81-87de-d99efb3c32bc'
      roleDescription: 'DVHPCont' // Desktop Virtualization Host Pool Contributor
    }
  ],
  !empty(monitoringResourceGroupId)
    ? [
        {
          resourceGroupId: virtualMachinesResourceGroupId
          roleDefinitionId: '749f88d5-cbae-40b8-bcfc-e573ddc772fa' // Monitoring Contributor (needed for data collection rule associations on VMs)
          roleDescription: 'MonCont'
        }
      ]
    : [],
  !empty(monitoringResourceGroupId) && monitoringResourceGroupId != virtualMachinesResourceGroupId
    ? [
        {
          resourceGroupId: monitoringResourceGroupId
          roleDefinitionId: '749f88d5-cbae-40b8-bcfc-e573ddc772fa' // Monitoring Contributor
          roleDescription: 'MonCont'
        }
      ]
    : []
)

module roleAssignmentsKeyVault '../../sharedModules/resources/key-vault/vault/rbac.bicep' = {
  name: 'RoleAssign-KeyVault-KVCont-${deploymentSuffix}'
  scope: resourceGroup(split(credentialsKeyVaultResourceId, '/')[2], split(credentialsKeyVaultResourceId, '/')[4])
  params: {
    principalId: userAssignedIdentity.properties.principalId
    roleDefinitionId: 'f25e0fa2-a7c8-4377-a976-54943a77a395' // Key Vault Contributor
    keyVaultName: last(split(credentialsKeyVaultResourceId, '/'))
    principalType: 'ServicePrincipal'
  }
}

module roleAssignmentVirtualMachinesSubscription '../../sharedModules/resources/authorization/role-assignment/subscription/main.bicep' = {
  name: 'RoleAssign-Sub-VirtMachCont-${deploymentSuffix}'
  scope: subscription(virtualMachinesSubscriptionId)
  params: {
    principalId: userAssignedIdentity.properties.principalId
    roleDefinitionId: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c' // Virtual Machine Contributor
    subscriptionId: virtualMachinesSubscriptionId
    principalType: 'ServicePrincipal'
  }
}

module roleAssignmentHostPoolSubscription '../../sharedModules/resources/authorization/role-assignment/subscription/main.bicep' = {
  name: 'RoleAssign-Sub-Reader-${deploymentSuffix}'
  scope: subscription(hostPoolSubscriptionId)
  params: {
    principalId: userAssignedIdentity.properties.principalId
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader - needed to read scaling plans that may be in different resource groups
    subscriptionId: hostPoolSubscriptionId
    principalType: 'ServicePrincipal'
  }
}

module roleAssignmentsRGs '../../sharedModules/resources/authorization/role-assignment/resource-group/main.bicep' = [
  for rgRole in roleAssignmentsResourceGroups: {
    name: 'RoleAssign-${last(split(rgRole.resourceGroupId, '/'))}-${rgRole.roleDescription}-${deploymentSuffix}'
    scope: resourceGroup(split(rgRole.resourceGroupId, '/')[2], split(rgRole.resourceGroupId, '/')[4])
    params: {
      principalId: userAssignedIdentity.properties.principalId
      roleDefinitionId: rgRole.roleDefinitionId
      resourceGroupName: last(split(rgRole.resourceGroupId, '/'))
      principalType: 'ServicePrincipal'
    }
  }
]

module roleAssignmentTemplateSpec '../../sharedModules/resources/resources/templateSpecs/rbac.bicep' = {
  name: 'RoleAssign-TemplateSpec-Reader-${deploymentSuffix}'
  params: {
    principalId: userAssignedIdentity.properties.principalId
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    principalType: 'ServicePrincipal'
    templateSpecResourceId: !empty(sessionHostTemplateSpecResourceId)
      ? sessionHostTemplateSpecResourceId
      : templateSpec!.outputs.templateSpecResourceId
  }
}

module roleAssignmentComputeGallery '../../sharedModules/resources/compute/gallery/rbac.bicep' = if (!empty(customImageResourceId)) {
  name: 'RoleAssign-ComputeGallery-Reader-${deploymentSuffix}'
  scope: resourceGroup(split(computeGalleryResourceId, '/')[2], split(computeGalleryResourceId, '/')[4])
  params: {
    principalId: userAssignedIdentity.properties.principalId
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    galleryName: empty(computeGalleryResourceId) ? '' : last(split(computeGalleryResourceId, '/'))
    principalType: 'ServicePrincipal'
  }
}

module roleAssignmentUaiArtifacts '../../sharedModules/resources/managed-identity/user-assigned-identity/rbac.bicep' = if(!empty(artifactsUserAssignedIdentityResourceId)) {
  name: 'RoleAssign-UAI-Artifacts-MngdIdOperator-${deploymentSuffix}'
  scope: resourceGroup(
    split(artifactsUserAssignedIdentityResourceId, '/')[2],
    split(artifactsUserAssignedIdentityResourceId, '/')[4]
  )
  params: {
    principalId: userAssignedIdentity.properties.principalId
    roleDefinitionId: 'f1a07417-d97a-45cb-824c-7a7467783830' // Managed Identity Operator
    principalType: 'ServicePrincipal'
    identityName: empty(artifactsUserAssignedIdentityResourceId) ? '' : last(split(artifactsUserAssignedIdentityResourceId, '/'))
  }
}

module functionApp '../../sharedModules/custom/functionApp/functionApp.bicep' = {
  name: 'SessionHostReplacerFunctionApp-${deploymentSuffix}'
  params: {
    location: location
    applicationInsightsName: appInsightsName
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureFunctionAppPrivateDnsZoneResourceId: azureFunctionAppPrivateDnsZoneResourceId
    azureTablePrivateDnsZoneResourceId: azureTablePrivateDnsZoneResourceId
    deploymentSuffix: deploymentSuffix
    enableApplicationInsights: !empty(logAnalyticsWorkspaceResourceId)
    enableQueueStorage: false
    enableTableStorage: true
    encryptionKeyName: encryptionKeyName
    encryptionKeyVaultResourceId: encryptionKeyVaultResourceId
    functionAppAppSettings: union(
      [
        {
          name: 'DeploymentPrefix'
          value: 'shr-${uniqueStringHosts}'
        }
        {
          name: 'DrainGracePeriodHours'
          value: string(drainGracePeriodHours)
        }
        {
          name: 'MinimumDrainMinutes'
          value: string(minimumDrainMinutes)
        }
        {
          name: 'ReplacementMode'
          value: replacementMode
        }
        {
          name: 'MinimumCapacityPercentage'
          value: string(minimumCapacityPercentage)
        }
      ],
      replacementMode == 'DeleteFirst'
        ? [
            {
              name: 'MaxDeletionsPerCycle'
              value: string(maxDeletionsPerCycle)
            }
          ]
        : [],
      [
        {
          name: 'EnableProgressiveScaleUp'
          value: string(enableProgressiveScaleUp)
        }
        {
          name: 'FixSessionHostTags'
          value: string(fixSessionHostTags)
        }
        {
          name: 'GraphEndpoint'
          value: graphEndpoint
        }
        {
          name: 'HostPoolName'
          value: hostPoolName
        }
        {
          name: 'HostPoolResourceGroupName'
          value: hostPoolResourceGroupName
        }
        {
          name: 'HostPoolSubscriptionId'
          value: hostPoolSubscriptionId
        }
        {
          name: 'IncludePreExistingSessionHosts'
          value: string(includePreExistingSessionHosts)
        }
        {
          name: 'InitialDeploymentPercentage'
          value: string(initialDeploymentPercentage)
        }
      ],
      replacementMode == 'SideBySide'
        ? [
            {
              name: 'MaxDeploymentBatchSize'
              value: string(maxDeploymentBatchSize)
            }
          ]
        : [],
      replacementMode == 'SideBySide'
        ? [
            {
              name: 'MinimumHostIndex'
              value: string(minimumHostIndex)
            }
          ]
        : [],
      replacementMode == 'SideBySide'
        ? [
            {
              name: 'EnableShutdownRetention'
              value: string(enableShutdownRetention)
            }
          ]
        : [],
      replacementMode == 'SideBySide'
        ? [
            {
              name: 'ShutdownRetentionDays'
              value: string(shutdownRetentionDays)
            }
          ]
        : [],
      [
        {
          name: 'RemoveEntraDevice'
          value: string(removeEntraDevice)
        }
        {
          name: 'RemoveIntuneDevice'
          value: string(removeIntuneDevice)
        }
        {
          name: 'ReplaceSessionHostOnNewImageVersionDelayDays'
          value: string(replaceSessionHostOnNewImageVersionDelayDays)
        }
        {
          name: 'AllowImageVersionRollback'
          value: string(allowImageVersionRollback)
        }
        {
          name: 'ScaleUpIncrementPercentage'
          value: string(scaleUpIncrementPercentage)
        }
        {
          name: 'SessionHostNameIndexLength'
          value: string(sessionHostNameIndexLength)
        }
        {
          name: 'SessionHostNamePrefix'
          value: sessionHostNamePrefix
        }
        {
          name: 'SessionHostParameters'
          value: string(sessionHostParameters)
        }
        {
          name: 'SessionHostTemplate'
          value: !empty(sessionHostTemplateSpecResourceId)
            ? sessionHostTemplateSpecResourceId
            : templateSpec!.outputs.templateSpecResourceId
        }
        {
          name: 'SubscriptionId'
          value: subscription().subscriptionId
        }
        {
          name: 'SuccessfulRunsBeforeScaleUp'
          value: string(successfulRunsBeforeScaleUp)
        }
        {
          name: 'Tag_DeployTimestamp'
          value: tagDeployTimestamp
        }
        {
          name: 'Tag_IncludeInAutomation'
          value: tagIncludeInAutomation
        }
        {
          name: 'Tag_PendingDrainTimestamp'
          value: tagPendingDrainTimestamp
        }
        {
          name: 'Tag_ShutdownTimestamp'
          value: tagShutdownTimestamp
        }
        {
          name: 'Tag_ScalingPlanExclusionTag'
          value: tagScalingPlanExclusionTag
        }
        {
          name: 'TargetSessionHostCount'
          value: string(targetSessionHostCount)
        }
        {
          name: 'VirtualMachinesResourceGroupName'
          value: virtualMachinesResourceGroupName
        }
        {
          name: 'VirtualMachinesSubscriptionId'
          value: virtualMachinesSubscriptionId
        }
        {
          name: 'WEBSITE_TIME_ZONE'
          value: timeZone
        }
      ]
    )
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
    serverFarmId: !empty(appServicePlanResourceId) ? appServicePlanResourceId : hostingPlan!.outputs.hostingPlanId
    storageAccountName: storageAccountName
    storageAccountRoleDefinitionIds: [
      '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor (for deployment state management)
    ]
    tags: tags
  }
}

module functionCode '../../sharedModules/custom/functionApp/function.bicep' = {
  name: 'SessionHostReplacerFunction-${deploymentSuffix}'
  params: {
    files: {
      'run.ps1': loadTextContent('functions/run.ps1')
      '../profile.ps1': loadTextContent('functions/profile.ps1')
      '../requirements.psd1': loadTextContent('functions/requirements.psd1')
      '../Modules/SessionHostReplacer/SessionHostReplacer.Core.psm1': loadTextContent('functions/Modules/SessionHostReplacer/SessionHostReplacer.Core.psm1')
      '../Modules/SessionHostReplacer/SessionHostReplacer.Deployment.psm1': loadTextContent('functions/Modules/SessionHostReplacer/SessionHostReplacer.Deployment.psm1')
      '../Modules/SessionHostReplacer/SessionHostReplacer.ImageManagement.psm1': loadTextContent('functions/Modules/SessionHostReplacer/SessionHostReplacer.ImageManagement.psm1')
      '../Modules/SessionHostReplacer/SessionHostReplacer.Planning.psm1': loadTextContent('functions/Modules/SessionHostReplacer/SessionHostReplacer.Planning.psm1')
      '../Modules/SessionHostReplacer/SessionHostReplacer.DeviceCleanup.psm1': loadTextContent('functions/Modules/SessionHostReplacer/SessionHostReplacer.DeviceCleanup.psm1')
      '../Modules/SessionHostReplacer/SessionHostReplacer.Lifecycle.psm1': loadTextContent('functions/Modules/SessionHostReplacer/SessionHostReplacer.Lifecycle.psm1')
      '../Modules/SessionHostReplacer/SessionHostReplacer.Monitoring.psm1': loadTextContent('functions/Modules/SessionHostReplacer/SessionHostReplacer.Monitoring.psm1')
      '../Modules/SessionHostReplacer/SessionHostReplacer.psm1': loadTextContent('functions/Modules/SessionHostReplacer/SessionHostReplacer.psm1')
      '../Modules/SessionHostReplacer/SessionHostReplacer.psd1': loadTextContent('functions/Modules/SessionHostReplacer/SessionHostReplacer.psd1')
    }
    functionAppName: functionApp.outputs.functionAppName
    functionName: 'session-host-replacer'
    schedule: timerSchedule
  }
}

module workbook 'modules/workBook/workbook.bicep' = if (deployWorkbook && !empty(logAnalyticsWorkspaceResourceId)) {
  name: 'SessionHostReplacerWorkbook-${deploymentSuffix}'
  params: {
    workbookName: workbookName
    location: workbookLocation
    applicationInsightsResourceId: functionApp.outputs.applicationInsightsResourceId
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Insights/workbooks'] ?? {})
  }
}

// ========== //
// Outputs    //
// ========== //

@description('The name of the deployed function app.')
output functionAppName string = functionApp.outputs.functionAppName

@description('The resource ID of the monitoring workbook.')
output workbookId string = (deployWorkbook && !empty(logAnalyticsWorkspaceResourceId))
  ? workbook!.outputs.workbookId
  : ''
