// AVD Session Host Replacer Add-On
// Deploys automated session host lifecycle management for Azure Virtual Desktop

targetScope = 'subscription'

// ========== //
// Parameters //
// ========== //

// ================================================================================================
// Common Parameters
// These parameters apply to the overall deployment and are shared across multiple resources.
// ================================================================================================

@description('Required. The location for all resources.')
param location string = deployment().location

@description('Required. Name of the resource group where the function app and its supporting resources are deployed. Defaults to the virtual machines resource group.')
param functionAppResourceGroupName string = last(split(virtualMachinesResourceGroupId, '/'))

@description('Optional. Tags for all resources.')
param tags object = {}

// ================================================================================================
// Naming Convention Parameters
// ================================================================================================

@description('''Naming convention controlling how Function App infrastructure resources are named.
Should match the convention used when deploying the host pool. Pre-populated from the
hpNamingConvention tag on the host pool resource.''')
param namingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

@description('Optional. The host pool base name / identifier used for naming (e.g. desktop-01). Pre-populated from the hpIdentifier tag on the host pool resource. When empty, falls back to a generic placeholder.')
param identifier string = ''

@description('Optional. Overrides for resource type abbreviations used when computing infrastructure resource names. Only the keys you provide are overridden; all others use CAF defaults. Supported keys: functionApps, appServicePlans, applicationInsights, templateSpecs, userAssignedIdentities, privateEndpoints, networkInterfaces.')
param namingResourceTypeCodes object = {}

// ================================================================================================
// Brownfield Naming Override Parameters
// These parameters allow explicit control over resource naming for brownfield deployments.
// When specified, these override the naming convention for individual resources.
// ================================================================================================

@description('Optional. Explicit name for the Function App. If not provided, name is derived from host pool naming convention. Use this for brownfield deployments with non-standard host pool names. Must be globally unique and follow Azure naming rules (2-60 chars, alphanumeric and hyphens).')
@maxLength(60)
param functionAppNameOverride string = ''

@description('Optional. Explicit name for the Storage Account (used by Function App). If not provided, name is derived from host pool naming convention. Use this for brownfield deployments with non-standard host pool names. Must be globally unique, 3-24 chars, lowercase alphanumeric only.')
@maxLength(24)
param storageAccountNameOverride string = ''

@description('Optional. Explicit name for the storage encryption user-assigned identity. If not provided, name is derived from host pool naming convention. Use this for brownfield deployments where a CMK identity was previously created with a specific name. Must follow Azure naming rules (3-128 chars, alphanumeric, hyphens, underscores).')
@maxLength(128)
param storageEncryptionIdentityNameOverride string = ''

@description('Optional. Explicit name for the Application Insights instance. If not provided, name is derived from shared naming convention. Use this for brownfield deployments with non-standard naming. Must follow Azure naming rules (1-260 chars, alphanumeric, hyphens, underscores, parentheses, periods).')
@maxLength(260)
param applicationInsightsNameOverride string = ''

@description('Required. Naming convention for session host virtual machines. SHNAME is replaced with the session host name at deploy time (e.g., "vm-SHNAME" becomes "vm-avdhost001"). Pre-populated from the virtualMachineNameConv tag on the hosts resource group.')
param virtualMachineNameConv string = 'vm-SHNAME'

@description('Required. Naming convention for session host OS disks. SHNAME is replaced with the session host name at deploy time. Pre-populated from the virtualMachineDiskNameConv tag on the hosts resource group.')
param virtualMachineDiskNameConv string = 'disk-SHNAME'

@description('Required. Naming convention for session host network interfaces. SHNAME is replaced with the session host name at deploy time. Pre-populated from the virtualMachineNicNameConv tag on the hosts resource group.')
param virtualMachineNicNameConv string = 'nic-SHNAME'

@description('Required. Naming convention for availability sets. ## is replaced with the set index (e.g., "avset-##" becomes "avset-01"). Pre-populated from the availabilitySetNameConv tag on the hosts resource group.')
param availabilitySetNameConv string = 'avset-##'

@description('Optional. Explicit name for the App Service Plan. If not provided, name is derived from the naming convention. Use this for brownfield deployments where an existing plan was created with a non-standard name, or when sharing an ASP across add-ons.')
@maxLength(40)
param appServicePlanNameOverride string = ''

// ================================================================================================
// Function App Infrastructure Parameters
// These parameters configure the Azure Function App infrastructure including networking, 
// security, encryption, and monitoring capabilities.
// ================================================================================================

@description('Optional. The resource ID of the User-Assigned Managed Identity with Microsoft Graph API permissions (Device.ReadWrite.All, DeviceManagementManagedDevices.ReadWrite.All). If not provided, the function app will use its system-assigned managed identity.')
param sessionHostReplacerUserAssignedIdentityResourceId string = ''

@description('Optional. The resource ID of an existing App Service Plan for the function app. If not provided, a new plan will be deployed.')
param existingAppServicePlanResourceId string = ''

@description('Optional. The name of the resource group to deploy the new App Service Plan into. Leave empty to deploy into the same resource group as the function app. Useful when sharing a single App Service Plan across multiple add-ons in a central operations resource group.')
param appServicePlanResourceGroupName string = ''

@description('Optional. The SKU for the App Service Plan. Only applies if existingAppServicePlanResourceId is not provided. Default is P0v3 for cost optimization.')
@allowed([
  'PremiumV3_P0v3'
  'PremiumV3_P1v3'
  'PremiumV3_P2v3'
  'PremiumV3_P3v3'
])
param appServicePlanSku string = 'PremiumV3_P0v3'

@description('Optional. Whether to deploy the App Service Plan with zone redundancy. Only applies if existingAppServicePlanResourceId is not provided. Default is false.')
param zoneRedundant bool = false

@description('Optional. Enable private endpoints for function app and storage. Default is false.')
param privateEndpoint bool = false

@description('Optional. Array of permitted IP addresses or CIDR blocks for the function app storage account firewall. Use when managing from a trusted workstation outside the Azure network boundary.')
param permittedIPs array = []

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
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
param keyManagementStorageAccounts string = 'PlatformManaged'

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
param credentialsKeyVaultResourceId string = ''

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
@minValue(20)
@maxValue(100)
param minimumCapacityPercentage int = 80

@description('Optional. Maximum number of hosts to delete and deploy per cycle in DeleteFirst mode. Controls the pace of replacements - function deletes this many idle hosts, then deploys the same number of replacements. Lower values = slower, safer updates. Only applies when replacementMode is DeleteFirst. Default is 5.')
@minValue(1)
@maxValue(100)
param maxDeletionsPerCycle int = 50

@description('Optional. Minimum host index for hostname numbering. Gap-filling logic starts from this index when deploying new hosts (e.g., 1 allows host01, host02; 10 allows host10, host11). Applies to both DeleteFirst and SideBySide modes. Default is 1.')
@minValue(0)
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
param virtualMachinesResourceGroupId string = ''

@description('Required. The resource ID of the AVD Host Pool where session hosts will be registered.')
param hostPoolResourceId string = ''

@description('Required. The VM name prefix used for session hosts.')
param sessionHostNamePrefix string = ''

@description('Optional. VM name index length for padding.')
param sessionHostNameIndexLength int = 2

@description('Required. Image reference for session host VMs. Use {"publisher":"...","offer":"...","sku":"..."} for marketplace images or {"id":"..."} for Compute Gallery images.')
param imageReference object = {}

@description('Optional. The VM size for session hosts.')
param virtualMachineSize string = 'Standard_D4ads_v6'

@description('Required. The subnet resource ID for session host NICs.')
param virtualMachineSubnetResourceId string = ''

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

@description('Optional. Enable IPv6 dynamic private IP on session hosts.')
param enableIPv6 bool = false

@description('Optional. Enable monitoring with Azure Monitor Agent.')
param enableMonitoring bool = false

@description('Optional. Existing disk encryption set resource ID.')
param diskEncryptionSetResourceId string = ''

@description('Optional. AVD Insights data collection rules resource ID.')
param avdInsightsDataCollectionRulesResourceId string = ''

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

@description('Optional. Custom URL for AVD Agent Boot Loader MSI installer. When empty, defaults to publicly documented sources (go.microsoft.com links for public clouds, aka.ms perma-links for air-gapped clouds).')
param agentBootLoaderDownloadUrl string = ''

@description('Optional. Custom URL for AVD Agent MSI installer. When empty, defaults to publicly documented sources (go.microsoft.com links for public clouds, aka.ms perma-links for air-gapped clouds).')
param agentDownloadUrl string = ''

@description('Optional. Artifacts container URI for custom scripts.')
param artifactsContainerUri string = ''

@description('Optional. Artifacts user assigned identity resource ID.')
param artifactsUserAssignedIdentityResourceId string = ''

@description('''Optional.
Array of objects containing the following properties
-name: The name of the script or application that is running minus extension
-blobNameOrUri: The blob name when used with the artifactsContainerUri or the full URI of the file to download.
-arguments: Arguments required by the installer or script being ran.

JSON example:
[
  {
    "name": "FSLogix",
    "blobNameOrUri": "https://aka.ms/fslogix_download"
  },
  {
    "name": "VSCode",
    "blobNameOrUri": "VSCode.zip",
    "arguments": "/verysilent /mergetasks=!runcode"
  }
]
''')
param sessionHostCustomizations array = []
