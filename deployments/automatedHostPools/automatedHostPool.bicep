targetScope = 'subscription'

import { artifactCustomizationType } from '../shared/modules/resourceModules/types/customizationTypes.bicep'
import { vmApplicationAssignmentType } from 'policy/modules/policy/bicep/vmApplicationTypes.bicep'
import { entraGroupType } from '../shared/modules/resourceModules/types/identityTypes.bicep'
import { scalingDayType } from '../shared/modules/resourceModules/types/scalingTypes.bicep'

type scalingTimeType = {
  hour: int
  minute: int
}

type dynamicScalingScheduleInputType = {
  name: string
  daysOfWeek: scalingDayType[]
  rampUpStartTime: string
  rampUpLoadBalancingAlgorithm: 'BreadthFirst' | 'DepthFirst'
  rampUpMinimumHostsPct: string
  rampUpCapacityThresholdPct: string
  rampUpMinimumHostPoolSize: string
  rampUpMaximumHostPoolSize: string
  peakStartTime: string
  peakLoadBalancingAlgorithm: 'BreadthFirst' | 'DepthFirst'
  rampDownStartTime: string
  rampDownLoadBalancingAlgorithm: 'BreadthFirst' | 'DepthFirst'
  rampDownMinimumHostsPct: string
  rampDownCapacityThresholdPct: string
  rampDownMinimumHostPoolSize: string
  rampDownMaximumHostPoolSize: string
  rampDownForceLogoffUsers: bool
  rampDownWaitTimeMinutes: string?
  rampDownNotificationMessage: string?
  rampDownStopHostsWhen: 'ZeroSessions' | 'ZeroActiveSessions'
  offPeakStartTime: string
  offPeakLoadBalancingAlgorithm: 'BreadthFirst' | 'DepthFirst'
}

@maxLength(16)
@description('Required. Short identifier used to name resources for this automated host pool.')
param identifier string

@description('Required. Azure region for session hosts and supporting resources. Automated host pools are supported only in Azure Commercial.')
param location string

@description('Optional. Azure region for AVD control-plane resources.')
param controlPlaneLocation string = location

@description('Optional. Naming convention shared with the standard host-pool deployment.')
param namingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

@description('Required. Resource ID of the subnet used by automated session hosts.')
param virtualMachineSubnetResourceId string

@description('Required. Existing Key Vault resource ID containing the VM administrator and optional domain-join credentials.')
param credentialsKeyVaultResourceId string

@description('Optional. Versionless Key Vault secret URI containing the local VM administrator username. Defaults to VirtualMachineAdminUserName in credentialsKeyVaultResourceId.')
param vmAdministratorUsernameSecretUri string = ''

@description('Optional. Versionless Key Vault secret URI containing the local VM administrator password. Defaults to VirtualMachineAdminPassword in credentialsKeyVaultResourceId.')
param vmAdministratorPasswordSecretUri string = ''

@allowed([
  'ActiveDirectoryDomainServices'
  'EntraDomainServices'
  'EntraKerberos-Hybrid'
  'EntraKerberos-CloudOnly'
])
@description('Required. Identity model used by the automated session hosts and FSLogix.')
param identitySolution string

@description('Optional. AD DS domain name. Required for domain-joined session hosts.')
param domainName string = ''

@description('Optional. AD DS organizational unit path.')
param organizationalUnitPath string = ''

@description('Optional. Versionless Key Vault secret URI containing the domain-join username. Defaults to DomainJoinUserPrincipalName in credentialsKeyVaultResourceId.')
param domainJoinUsernameSecretUri string = ''

@description('Optional. Versionless Key Vault secret URI containing the domain-join password. Defaults to DomainJoinUserPassword in credentialsKeyVaultResourceId.')
param domainJoinPasswordSecretUri string = ''

@description('Optional. Enroll Entra-joined session hosts in Microsoft Intune.')
param intuneEnrollment bool = false

@description('Required. Prefix used by Azure Virtual Desktop when naming session-host VMs. Maximum 11 characters.')
@maxLength(11)
param virtualMachineNamePrefix string

@description('Optional. VM size used by automated session hosts.')
param virtualMachineSize string = 'Standard_D4ads_v5'

@description('Optional. Number of session hosts provisioned when dynamic scaling is disabled. Dynamic scaling schedules own initial and ongoing capacity when enabled.')
@minValue(1)
param sessionHostCount int = 1

@description('Optional. Marketplace image publisher. Ignored when customImageResourceId is supplied.')
param imagePublisher string = 'MicrosoftWindowsDesktop'

@description('Optional. Marketplace image offer. Ignored when customImageResourceId is supplied.')
param imageOffer string = 'office-365'

@description('Optional. Marketplace image SKU. Ignored when customImageResourceId is supplied.')
param imageSku string = 'win11-25h2-avd-m365'

@description('Optional. Exact marketplace image version. Session Host Configuration does not support the latest sentinel.')
param imageVersion string = ''

@description('Optional. Resource ID of a Compute Gallery image version. When supplied, the marketplace image parameters are ignored.')
param customImageResourceId string = ''

@allowed([
  'Standard_LRS'
  'StandardSSD_LRS'
  'Premium_LRS'
])
@description('Optional. Managed OS disk SKU.')
param diskSku string = 'Premium_LRS'

@minValue(0)
@description('Optional. OS disk size in GB. Set to zero to preserve the image default.')
param diskSizeGB int = 0

@description('Optional. Use an ephemeral OS disk. The selected VM size must support the requested placement and have sufficient cache or resource disk capacity for the image.')
param useEphemeralOsDisk bool = false

@allowed([
  'CacheDisk'
  'ResourceDisk'
])
@description('Optional. Local storage used for the ephemeral OS disk.')
param ephemeralOsDiskPlacement string = 'ResourceDisk'

@allowed([
  'Standard'
  'TrustedLaunch'
  'ConfidentialVM'
])
@description('Optional. Session-host security type.')
param securityType string = 'TrustedLaunch'

@description('Optional. Enable Secure Boot.')
param secureBootEnabled bool = true

@description('Optional. Enable virtual TPM.')
param vTpmEnabled bool = true

@description('Optional. Availability zones used for new session hosts.')
param availabilityZones int[] = []

@description('Optional. Maximum concurrent sessions per session host.')
@minValue(1)
param hostPoolMaxSessionLimit int = 4

@allowed([
  'BreadthFirst'
  'DepthFirst'
])
@description('Optional. Pooled host load-balancing algorithm.')
param loadBalancerType string = 'DepthFirst'

@description('Optional. Custom RDP properties applied to the host pool.')
param hostPoolRDPProperties string = ''

@description('Optional. Deploy the host pool in the validation environment.')
param hostPoolValidationEnvironment bool = false

@description('Optional. Allow session hosts to start when a user connects.')
param startVMOnConnect bool = true

@description('Optional. Deploy an AVD dynamic scaling plan that can create, delete, start, and stop session hosts.')
param deployDynamicScalingPlan bool = false

@description('Optional. Object ID of the Azure Virtual Desktop service principal. Required when Start VM on Connect or dynamic scaling is enabled.')
param avdServicePrincipalObjectId string = ''

@description('Optional. Tag name that excludes a session host from dynamic scaling operations.')
param scalingPlanExclusionTag string = 'ScalingPlanExclusion'

@description('Optional. Time zone used by the dynamic scaling schedule.')
param scalingPlanTimeZone string = 'Eastern Standard Time'

@description('Required when deployDynamicScalingPlan is true. Complete named dynamic scaling schedules. Days may be grouped when they share a schedule.')
param dynamicScalingSchedules dynamicScalingScheduleInputType[] = []

@description('Optional. Existing AVD workspace resource ID. When empty, a workspace is created.')
param existingWorkspaceResourceId string = ''

@allowed([
  'None'
  'HostPool'
  'FeedAndHostPool'
  'All'
])
@description('Optional. AVD traffic routed through Private Link. All includes initial feed discovery, feed download, and remote session connections.')
param avdPrivateLinkPrivateRoutes string = 'None'

@description('Conditional. Subnet resource ID for the host-pool connection private endpoint.')
param hostPoolPrivateEndpointSubnetResourceId string = ''

@description('Optional. AVD Private DNS zone resource ID for host-pool connection and workspace feed endpoints.')
param avdPrivateDnsZoneResourceId string = ''

@description('Optional. Public network access mode for remote session connections.')
param hostPoolPublicNetworkAccess 'Disabled' | 'Enabled' | 'EnabledForClientsOnly' = 'Enabled'

@description('Conditional. Subnet resource ID for the workspace feed private endpoint.')
param workspaceFeedPrivateEndpointSubnetResourceId string = ''

@description('Optional. Public network access mode for workspace feed requests.')
param workspaceFeedPublicNetworkAccess 'Disabled' | 'Enabled' = 'Enabled'

@description('Optional. Existing global-feed workspace resource ID. When supplied, the deployment does not create another global-feed workspace or endpoint.')
param existingGlobalFeedResourceId string = ''

@description('Conditional. Subnet resource ID for a newly created global-feed private endpoint when all AVD traffic uses private routes.')
param globalFeedPrivateEndpointSubnetResourceId string = ''

@description('Optional. AVD global-feed Private DNS zone resource ID.')
param globalFeedPrivateDnsZoneResourceId string = ''

@description('Optional. Friendly name shown for a newly created workspace.')
param workspaceFriendlyName string = ''

@minLength(1)
@maxLength(20)
@description('Required. Friendly name shown for the desktop application group.')
param desktopFriendlyName string

@description('Optional. Entra group object IDs assigned access to the desktop application group.')
param appGroupSecurityGroupIds string[] = []

@description('Optional. Existing Log Analytics workspace resource ID used for AVD and storage diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Existing Data Collection Rule resource ID. Required when enableMonitoring is true.')
param dataCollectionRuleResourceId string = ''

@description('Optional. Existing Data Collection Endpoint resource ID.')
param dataCollectionEndpointResourceId string = ''

@description('Optional. Deploy Azure Monitor Agent policy assignments for automated session hosts.')
param enableMonitoring bool = false

@description('Deprecated. Azure Monitor Agent now uses each session host system-assigned identity. Leave empty.')
@metadata({
  strongType: 'Microsoft.ManagedIdentity/userAssignedIdentities'
})
param monitoringUserAssignedIdentityResourceId string = ''

@description('Optional. Deploy and configure FSLogix storage before provisioning session hosts.')
param deployFSLogixStorage bool = true

@description('Optional. Configure FSLogix registry settings on automated session hosts.')
param fslogixConfigureSessionHosts bool = deployFSLogixStorage

@allowed([
  'AzureFiles Premium'
  'AzureFiles Standard'
  'AzureNetAppFiles Premium'
  'AzureNetAppFiles Standard'
])
@description('Optional. FSLogix storage service and SKU.')
param fslogixStorageService string = 'AzureFiles Standard'

@allowed([
  'LocallyRedundant'
  'ZoneRedundant'
])
@description('Optional. Storage redundancy for newly created Azure Files accounts used by FSLogix.')
param fslogixStorageRedundancy string = 'LocallyRedundant'

@allowed([
  'CloudCacheProfileContainer'
  'CloudCacheProfileOfficeContainer'
  'ProfileContainer'
  'ProfileOfficeContainer'
])
@description('Optional. FSLogix container layout.')
param fslogixContainerType string = 'ProfileContainer'

@description('Optional. FSLogix file-share or volume size in GB.')
@minValue(1)
param fslogixShareSizeInGB int = 100

@description('Optional. FSLogix profile size configured on session hosts, in MB.')
@minValue(1)
param fslogixProfileSizeInMBs int = 30000

@description('Optional. OU path for FSLogix storage computer objects. Defaults to the session-host OU path.')
param fslogixOUPath string = ''

@description('Optional. Existing user-assigned identity that automates Entra Kerberos application updates and consent.')
param fslogixAppUpdateUserAssignedIdentityResourceId string = ''

@description('Optional. Starting index appended to newly created Azure Files storage account names.')
@minValue(0)
@maxValue(99)
param fslogixStorageIndex int = 1

@description('Optional. Number of days to retain deleted FSLogix Azure file shares.')
@minValue(1)
@maxValue(365)
param fslogixSoftDeleteRetentionDays int = 14

@description('Optional. Resource ID of an existing Recovery Services vault used to register newly deployed FSLogix Azure Files shares for snapshot backup.')
param existingFilesBackupVaultResourceId string = ''

@description('Optional. Name of the Azure Files snapshot backup policy in the existing Recovery Services vault.')
param existingFilesBackupPolicyName string = 'filesharepolicy'

@allowed([
  'AES256'
  'RC4'
])
@description('Optional. Kerberos encryption type used by Azure Files domain authentication.')
param fslogixStorageKerberosEncryptionType string = 'AES256'

@allowed([
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
@description('Optional. Key management mode for newly created FSLogix Azure Files storage accounts.')
param fslogixKeyManagementStorage string = 'PlatformManaged'

@description('Optional. Existing Key Vault resource ID used for FSLogix Azure Files customer-managed keys.')
param fslogixEncryptionKeyVaultResourceId string = ''

@description('Optional. Number of days before FSLogix Azure Files customer-managed keys expire and rotate.')
@minValue(7)
param fslogixKeyExpirationInDays int = 180

@allowed([
  'None'
  'ShardOSS'
  'ShardPerms'
])
@description('Optional. FSLogix sharding and permission model.')
param fslogixShardOptions string = 'None'

@description('Optional. Groups granted administrative access to FSLogix storage.')
param fslogixAdminGroups entraGroupType[] = []

@description('Optional. Groups granted user access to FSLogix storage and used for sharding.')
param fslogixUserGroups entraGroupType[] = []

@description('Optional. Existing local Azure Files storage account resource IDs used to configure FSLogix without deploying storage.')
param fslogixExistingLocalStorageAccountResourceIds string[] = []

@description('Optional. Existing remote Azure Files storage account resource IDs used by FSLogix Cloud Cache.')
param fslogixExistingRemoteStorageAccountResourceIds string[] = []

@description('Optional. Existing local Azure NetApp Files volume resource IDs used to configure FSLogix without deploying storage. Provide one ID for Profile Container, or two IDs for Profile and Office Containers in profile-then-office order.')
param fslogixExistingLocalNetAppVolumeResourceIds string[] = []

@description('Optional. Existing remote Azure NetApp Files volume resource IDs used by FSLogix Cloud Cache. Provide none, one ID for Profile Container, or two IDs for Profile and Office Containers in profile-then-office order.')
param fslogixExistingRemoteNetAppVolumeResourceIds string[] = []

@description('Optional. Resource ID of the subnet delegated to Microsoft.NetApp/volumes.')
param netAppVolumesSubnetResourceId string = ''

@description('Optional. Indicates that the Azure NetApp Files account already has the required shared Active Directory connection.')
param existingSharedActiveDirectoryConnection bool = false

@description('Optional. Deploy private endpoints for Azure Files storage.')
param fslogixPrivateEndpoint bool = true

@description('Optional. Resource ID of the Azure Files private endpoint subnet.')
param fslogixPrivateEndpointSubnetResourceId string = virtualMachineSubnetResourceId

@description('Optional. Resource ID of the Azure Files private DNS zone.')
param azureFilePrivateDnsZoneResourceId string = ''

@description('Optional. VM size used by the temporary FSLogix deployment virtual machine. Select an available 2-vCPU SKU in the deployment region.')
param deploymentVirtualMachineSize string = 'Standard_D2ads_v5'

@description('Optional. IP addresses or CIDR blocks permitted through the Azure Files firewall.')
param fslogixPermittedIPs string[] = []

@description('Optional. Deploy a Disk Encryption Set for the deployment helper and session-host OS disks, with policy enforcement for session hosts.')
param deployDiskEncryptionSet bool = false

@description('Optional. Existing Disk Encryption Set resource ID used by the deployment helper and session-host policy.')
param diskEncryptionSetResourceId string = ''

@description('Optional. Existing Key Vault resource ID used when creating the Disk Encryption Set.')
param encryptionKeyVaultResourceId string = ''

@allowed([
  'CustomerManaged'
  'CustomerManagedHSM'
  'PlatformManagedAndCustomerManaged'
  'PlatformManagedAndCustomerManagedHSM'
])
@description('Optional. Customer-managed encryption mode used when creating the Disk Encryption Set.')
param keyManagementDisks string = 'CustomerManagedHSM'

@description('Optional. Disable public network access for managed disks through policy.')
param disableManagedDiskPublicNetworkAccess bool = true

@description('Optional. Enable Guest Attestation policy for Trusted Launch and Confidential VM session hosts.')
param integrityMonitoring bool = true

@description('Optional. Enable encryption at host through policy.')
param encryptionAtHost bool = true

@description('Optional. Enable accelerated networking through policy.')
param enableAcceleratedNetworking bool = true

@description('Optional. Windows time zone for automated session hosts and update scheduling.')
param virtualMachinesTimeZone string = 'Eastern Standard Time'

@description('Optional. HTTPS URI of the private artifact container used by policy customizations.')
param artifactsContainerUri string = ''

@description('Optional. Resource ID of the managed identity that can read customization artifacts.')
param artifactsUserAssignedIdentityResourceId string = ''

@description('Optional. Ordered, idempotent policy-based session-host customizations.')
param sessionHostCustomizations artifactCustomizationType[] = []

@minLength(0)
@maxLength(25)
@description('Optional. Authoritative ordered list of existing Azure Compute Gallery application versions assigned to automated session hosts through Azure Policy. Azure supports at most 25 VM Applications per VM.')
param sessionHostVmApplications vmApplicationAssignmentType[] = []

@description('Optional. Maximum VMs replaced concurrently during a Session Host Configuration update.')
@minValue(1)
param updateMaxVmsRemoved int = 1

@description('Optional. Minutes users have to sign out before an updated host is removed.')
@minValue(0)
param updateLogOffDelayMinutes int = 30

@description('Optional. Message shown to users before an updated host is removed.')
param updateLogOffMessage string = 'This session host is being updated. Save your work and sign out.'

@description('Optional. Delete the original VM after a successful update.')
param deleteOriginalVm bool = true

@allowed([
  'KeepAll'
  'KeepOne'
  'KeepNone'
])
@description('Optional. Cleanup behavior for failed session-host provisioning.')
param failedSessionHostCleanupPolicy string = 'KeepOne'

@description('Optional. Tags keyed by Azure resource type.')
param tags object = {}

resource credentialsKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: last(split(credentialsKeyVaultResourceId, '/'))!
  scope: resourceGroup(split(credentialsKeyVaultResourceId, '/')[2], split(credentialsKeyVaultResourceId, '/')[4])
}

var commercialCloudIsValid = environment().name == 'AzureCloud'
  ? true
  : fail('Automated host pools are currently supported only in Azure Commercial.')
var hpBaseName = toLower(identifier)
var credentialsKeyVaultConfigurationIsValid = credentialsKeyVault.properties.enableRbacAuthorization == true && credentialsKeyVault.properties.enabledForTemplateDeployment == true
  ? true
  : fail('The credentials Key Vault must use Azure RBAC and allow Azure Resource Manager template deployment.')
var domainJoinRequired = contains(identitySolution, 'DomainServices')
var credentialsKeyVaultSecretBaseUri = 'https://${last(split(credentialsKeyVaultResourceId, '/'))}.${environment().suffixes.keyvaultDns}/secrets'
var effectiveVmAdministratorUsernameSecretUri = !empty(vmAdministratorUsernameSecretUri) ? vmAdministratorUsernameSecretUri : '${credentialsKeyVaultSecretBaseUri}/VirtualMachineAdminUserName'
var effectiveVmAdministratorPasswordSecretUri = !empty(vmAdministratorPasswordSecretUri) ? vmAdministratorPasswordSecretUri : '${credentialsKeyVaultSecretBaseUri}/VirtualMachineAdminPassword'
var effectiveDomainJoinUsernameSecretUri = !empty(domainJoinUsernameSecretUri) ? domainJoinUsernameSecretUri : '${credentialsKeyVaultSecretBaseUri}/DomainJoinUserPrincipalName'
var effectiveDomainJoinPasswordSecretUri = !empty(domainJoinPasswordSecretUri) ? domainJoinPasswordSecretUri : '${credentialsKeyVaultSecretBaseUri}/DomainJoinUserPassword'
var domainConfigurationIsValid = !domainJoinRequired || !empty(domainName)
  ? true
  : fail('Domain-joined automated session hosts require domainName.')
var monitoringConfigurationIsValid = !enableMonitoring || !empty(dataCollectionRuleResourceId)
  ? true
  : fail('dataCollectionRuleResourceId is required when enableMonitoring is true.')
var monitoringIdentityConfigurationIsValid = empty(monitoringUserAssignedIdentityResourceId)
  ? true
  : fail('monitoringUserAssignedIdentityResourceId is no longer supported. Azure Monitor Agent uses each session host system-assigned identity.')
var marketplaceImageConfigurationIsValid = !empty(customImageResourceId) || (!empty(imageVersion) && toLower(imageVersion) != 'latest')
  ? true
  : fail('Marketplace automated host pools require a concrete imageVersion. The latest sentinel is not supported by Session Host Configuration.')
var avdServicePrincipalIsValid = !(deployDynamicScalingPlan || startVMOnConnect) || !empty(avdServicePrincipalObjectId)
  ? true
  : fail('avdServicePrincipalObjectId is required when dynamic scaling or Start VM on Connect is enabled.')

func parseScalingTime(value string) scalingTimeType => {
  hour: int(first(split(value, ':')))
  minute: int(last(split(value, ':')))
}

var effectiveDynamicScalingSchedules = map(dynamicScalingSchedules, schedule => {
  name: schedule.name
  daysOfWeek: schedule.daysOfWeek
  rampUpStartTime: parseScalingTime(schedule.rampUpStartTime)
  rampUpLoadBalancingAlgorithm: schedule.rampUpLoadBalancingAlgorithm
  rampUpMinimumHostsPct: int(schedule.rampUpMinimumHostsPct)
  rampUpCapacityThresholdPct: int(schedule.rampUpCapacityThresholdPct)
  rampUpMinimumHostPoolSize: int(schedule.rampUpMinimumHostPoolSize)
  rampUpMaximumHostPoolSize: int(schedule.rampUpMaximumHostPoolSize)
  peakStartTime: parseScalingTime(schedule.peakStartTime)
  peakLoadBalancingAlgorithm: schedule.peakLoadBalancingAlgorithm
  rampDownStartTime: parseScalingTime(schedule.rampDownStartTime)
  rampDownLoadBalancingAlgorithm: schedule.rampDownLoadBalancingAlgorithm
  rampDownMinimumHostsPct: int(schedule.rampDownMinimumHostsPct)
  rampDownCapacityThresholdPct: int(schedule.rampDownCapacityThresholdPct)
  rampDownMinimumHostPoolSize: int(schedule.rampDownMinimumHostPoolSize)
  rampDownMaximumHostPoolSize: int(schedule.rampDownMaximumHostPoolSize)
  rampDownForceLogoffUsers: schedule.rampDownForceLogoffUsers
  rampDownWaitTimeMinutes: schedule.rampDownForceLogoffUsers
    ? (empty(schedule.?rampDownWaitTimeMinutes ?? '') ? 30 : int(schedule.rampDownWaitTimeMinutes!))
    : 0
  rampDownNotificationMessage: schedule.rampDownForceLogoffUsers
    ? (empty(schedule.?rampDownNotificationMessage ?? '') ? 'Save your work and sign out. This session host is being removed by autoscale.' : schedule.rampDownNotificationMessage!)
    : ''
  rampDownStopHostsWhen: schedule.rampDownStopHostsWhen
  offPeakStartTime: parseScalingTime(schedule.offPeakStartTime)
  offPeakLoadBalancingAlgorithm: schedule.offPeakLoadBalancingAlgorithm
})
var invalidDynamicScalingLimits = filter(effectiveDynamicScalingSchedules, schedule => schedule.rampUpMinimumHostPoolSize > schedule.rampUpMaximumHostPoolSize || schedule.rampDownMinimumHostPoolSize > schedule.rampDownMaximumHostPoolSize)
var dynamicScalingLimitsAreValid = !deployDynamicScalingPlan || empty(invalidDynamicScalingLimits)
  ? true
  : fail('Dynamic scaling minimum host-pool sizes cannot exceed their corresponding maximum sizes.')
var invalidDynamicScalingRampDownSettings = filter(effectiveDynamicScalingSchedules, schedule => schedule.rampDownWaitTimeMinutes < 0 || schedule.rampDownWaitTimeMinutes > 120 || schedule.rampDownForceLogoffUsers && empty(schedule.rampDownNotificationMessage))
var dynamicScalingRampDownSettingsAreValid = !deployDynamicScalingPlan || empty(invalidDynamicScalingRampDownSettings)
  ? true
  : fail('Dynamic scaling ramp-down waits must be between 0 and 120 minutes, and force logoff requires a notification message.')
var dynamicScalingScheduleNames = map(effectiveDynamicScalingSchedules, schedule => toLower(schedule.name))
var dynamicScalingScheduleDays = flatten(map(effectiveDynamicScalingSchedules, schedule => schedule.daysOfWeek))
var dynamicScalingSchedulesAreValid = !deployDynamicScalingPlan || !empty(effectiveDynamicScalingSchedules) && length(dynamicScalingScheduleNames) == length(union(dynamicScalingScheduleNames, dynamicScalingScheduleNames)) && length(dynamicScalingScheduleDays) == length(union(dynamicScalingScheduleDays, dynamicScalingScheduleDays))
  ? true
  : fail('Dynamic scaling requires at least one schedule, unique schedule names, and each day assigned to no more than one schedule.')
var hostPoolPrivateEndpointConfigurationIsValid = avdPrivateLinkPrivateRoutes == 'None' || !empty(hostPoolPrivateEndpointSubnetResourceId)
var workspaceFeedPrivateEndpointConfigurationIsValid = !contains(['FeedAndHostPool', 'All'], avdPrivateLinkPrivateRoutes) || !empty(workspaceFeedPrivateEndpointSubnetResourceId)
var globalFeedPrivateEndpointConfigurationIsValid = avdPrivateLinkPrivateRoutes != 'All' || !empty(existingGlobalFeedResourceId) || !empty(globalFeedPrivateEndpointSubnetResourceId)
var avdPrivateLinkConfigurationIsValid = hostPoolPrivateEndpointConfigurationIsValid && workspaceFeedPrivateEndpointConfigurationIsValid && globalFeedPrivateEndpointConfigurationIsValid
  ? true
  : fail('AVD Private Link requires a host-pool endpoint subnet, a workspace feed endpoint subnet for FeedAndHostPool or All, and an existing global feed or global endpoint subnet for All.')
var deployGlobalFeed = avdPrivateLinkPrivateRoutes == 'All' && empty(existingGlobalFeedResourceId)
var createDeploymentVm = deployFSLogixStorage || !empty(desktopFriendlyName)
var fslogixStorageSolution 'AzureFiles' | 'AzureNetAppFiles' = startsWith(fslogixStorageService, 'AzureFiles') ? 'AzureFiles' : 'AzureNetAppFiles'
var fslogixDomainCredentialsRequired = contains(identitySolution, 'DomainServices') || fslogixStorageSolution == 'AzureNetAppFiles' || (identitySolution == 'EntraKerberos-Hybrid' && !empty(fslogixUserGroups))
var fslogixShareNamesLookup = {
  CloudCacheProfileContainer: ['profile-containers']
  CloudCacheProfileOfficeContainer: ['profile-containers', 'office-containers']
  ProfileContainer: ['profile-containers']
  ProfileOfficeContainer: ['profile-containers', 'office-containers']
}
var fslogixFileShareNames = fslogixShareNamesLookup[fslogixContainerType]
var fslogixStorageCount = fslogixShardOptions == 'None' ? 1 : length(fslogixUserGroups)
var deployFslogixStorageCmk = deployFSLogixStorage && fslogixStorageSolution == 'AzureFiles' && contains(fslogixKeyManagementStorage, 'CustomerManaged')
var fslogixShardingConfigurationIsValid = (!deployFSLogixStorage && !fslogixConfigureSessionHosts) || fslogixShardOptions == 'None' || !empty(fslogixUserGroups)
  ? true
  : fail('fslogixUserGroups must contain at least one group when sharding is enabled.')
var fslogixExistingLocalStorageConfigurationIsValid = !fslogixConfigureSessionHosts || deployFSLogixStorage || fslogixStorageSolution != 'AzureFiles' || length(fslogixExistingLocalStorageAccountResourceIds) == fslogixStorageCount
var fslogixExistingRemoteStorageConfigurationIsValid = !fslogixConfigureSessionHosts || fslogixStorageSolution != 'AzureFiles' || empty(fslogixExistingRemoteStorageAccountResourceIds) || length(fslogixExistingRemoteStorageAccountResourceIds) == fslogixStorageCount
var fslogixExistingStorageConfigurationIsValid = fslogixExistingLocalStorageConfigurationIsValid && fslogixExistingRemoteStorageConfigurationIsValid
  ? true
  : fail('Existing FSLogix Azure Files storage must include one local account, and when supplied one remote account, per shard.')
var fslogixExistingLocalNetAppConfigurationIsValid = !fslogixConfigureSessionHosts || deployFSLogixStorage || fslogixStorageSolution != 'AzureNetAppFiles' || length(fslogixExistingLocalNetAppVolumeResourceIds) == length(fslogixFileShareNames)
var fslogixExistingRemoteNetAppConfigurationIsValid = !fslogixConfigureSessionHosts || fslogixStorageSolution != 'AzureNetAppFiles' || empty(fslogixExistingRemoteNetAppVolumeResourceIds) || length(fslogixExistingRemoteNetAppVolumeResourceIds) == length(fslogixFileShareNames)
var fslogixExistingNetAppConfigurationIsValid = fslogixExistingLocalNetAppConfigurationIsValid && fslogixExistingRemoteNetAppConfigurationIsValid
  ? true
  : fail('Existing Azure NetApp Files storage must include one volume per FSLogix share, in profile-then-Office order. Remote volumes are optional but must follow the same rule when supplied.')
var fslogixStorageIdentityConfigurationIsValid = !deployFSLogixStorage || fslogixStorageSolution != 'AzureNetAppFiles' || contains(identitySolution, 'DomainServices')
  ? true
  : fail('Azure NetApp Files requires ActiveDirectoryDomainServices or EntraDomainServices.')
var fslogixStorageCmkConfigurationIsValid = !deployFslogixStorageCmk || !empty(fslogixEncryptionKeyVaultResourceId)
  ? true
  : fail('fslogixEncryptionKeyVaultResourceId is required when Azure Files uses customer-managed keys.')
var diskEncryptionSetConfigurationIsValid = !deployDiskEncryptionSet || (empty(diskEncryptionSetResourceId) && !empty(encryptionKeyVaultResourceId))
  ? true
  : fail('When deployDiskEncryptionSet is true, encryptionKeyVaultResourceId is required and diskEncryptionSetResourceId must be empty.')
var effectiveDiskEncryptionSetName = contains(keyManagementDisks, 'PlatformManagedAndCustomerManaged')
  ? naming.outputs.diskEncryptionSetNamePlatformAndCustomerManaged
  : naming.outputs.diskEncryptionSetNameCustomerManaged
var effectiveDiskEncryptionSetResourceId = deployDiskEncryptionSet
  ? diskCmk!.outputs.diskEncryptionSetResourceId
  : diskEncryptionSetResourceId

resource fslogixEncryptionKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (deployFslogixStorageCmk && fslogixStorageCmkConfigurationIsValid) {
  name: last(split(fslogixEncryptionKeyVaultResourceId, '/'))!
  scope: resourceGroup(split(fslogixEncryptionKeyVaultResourceId, '/')[2], split(fslogixEncryptionKeyVaultResourceId, '/')[4])
}

resource globalFeedPrivateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if (deployGlobalFeed && !empty(globalFeedPrivateEndpointSubnetResourceId)) {
  name: split(globalFeedPrivateEndpointSubnetResourceId, '/')[8]
  scope: resourceGroup(split(globalFeedPrivateEndpointSubnetResourceId, '/')[2], split(globalFeedPrivateEndpointSubnetResourceId, '/')[4])
}

var globalFeedRegion = deployGlobalFeed && !empty(globalFeedPrivateEndpointSubnetResourceId)
  ? globalFeedPrivateEndpointVirtualNetwork!.location
  : ''

module naming '../shared/modules/orchestration/naming/hostPool.bicep' = {
  params: {
    identifier: hpBaseName
    virtualMachinesRegion: location
    controlPlaneRegion: controlPlaneLocation
    globalFeedRegion: globalFeedRegion
    existingFeedWorkspaceResourceId: existingWorkspaceResourceId
    namingConvention: namingConvention
  }
}

var hostPoolResourceId = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${naming.outputs.resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostPools/${naming.outputs.hostPoolName}'
var parentResourceTag = { 'cm-resource-parent': hostPoolResourceId }
var hostPoolCustomTags = union(
  {
    hostsResourceGroupId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${naming.outputs.resourceGroupHosts}'
    hostPoolManagementType: 'Automated'
    hpIdentifier: hpBaseName
    hpNamingConvention: string({
      components: namingConvention.?components ?? ['resourceType', 'workload', 'purpose', 'location']
      delimiter: namingConvention.?delimiter ?? '-'
      workload: !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
      vmsLocationAbbreviation: naming.outputs.vmLocationAbbreviation
    })
  },
  deployFSLogixStorage
    ? { storageResourceGroupId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${naming.outputs.resourceGroupStorage}' }
    : {}
)

module controlPlaneResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (empty(existingWorkspaceResourceId)) {
  params: {
    name: naming.outputs.resourceGroupControlPlane
    location: controlPlaneLocation
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module sessionHostResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = {
  params: {
    name: naming.outputs.resourceGroupHosts
    location: commercialCloudIsValid ? location : location
    tags: union(tags[?'Microsoft.Resources/resourceGroups'] ?? {}, parentResourceTag)
  }
}

module storageResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (deployFSLogixStorage) {
  params: {
    name: naming.outputs.resourceGroupStorage
    location: location
    tags: union(tags[?'Microsoft.Resources/resourceGroups'] ?? {}, parentResourceTag)
  }
}

module deploymentResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (createDeploymentVm) {
  params: {
    name: naming.outputs.resourceGroupDeployment
    location: location
    tags: union(tags[?'Microsoft.Resources/resourceGroups'] ?? {}, parentResourceTag)
  }
}

module globalFeedResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (deployGlobalFeed && !empty(globalFeedPrivateEndpointSubnetResourceId)) {
  params: {
    name: naming.outputs.globalFeedResourceGroupName
    location: globalFeedRegion
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

// Start subscription-level AVD service-principal RBAC early so it can propagate while the
// control plane, storage, policy, and session-host configuration are prepared.
module avdServicePrincipalRbac '../shared/modules/orchestration/avdServicePrincipalRbac.bicep' = if (deployDynamicScalingPlan || startVMOnConnect) {
  params: {
    avdServicePrincipalObjectId: avdServicePrincipalIsValid ? avdServicePrincipalObjectId : avdServicePrincipalObjectId
    scalingMethod: deployDynamicScalingPlan ? 'CreateDeletePowerManage' : 'None'
    startVMOnConnect: startVMOnConnect
  }
}

module diskCmk '../shared/modules/orchestration/customerManagedKeys/diskCmk.bicep' = if (deployDiskEncryptionSet) {
  params: {
    resourceGroupName: naming.outputs.resourceGroupHosts
    keyVaultResourceId: diskEncryptionSetConfigurationIsValid ? encryptionKeyVaultResourceId : encryptionKeyVaultResourceId
    keyManagementType: keyManagementDisks
    keyExpirationInDays: 180
    location: location
    tags: tags
    parentResourceId: hostPoolResourceId
    keyName: naming.outputs.encryptionKeyNameVMs
    diskEncryptionSetName: effectiveDiskEncryptionSetName
  }
  dependsOn: [sessionHostResourceGroup]
}

module deploymentHelper '../shared/modules/orchestration/deploymentHelper/deploy.bicep' = if (createDeploymentVm) {
  params: {
    confidentialVMOSDiskEncryption: false
    deploymentVmSize: deploymentVirtualMachineSize
    desktopFriendlyName: desktopFriendlyName
    diskSku: 'StandardSSD_LRS'
    diskEncryptionSetResourceId: effectiveDiskEncryptionSetResourceId
    #disable-next-line BCP422
    domainJoinUserPassword: fslogixDomainCredentialsRequired
      ? credentialsKeyVault.getSecret(last(split(effectiveDomainJoinPasswordSecretUri, '/'))!)
      : ''
    #disable-next-line BCP422
    domainJoinUserPrincipalName: fslogixDomainCredentialsRequired
      ? credentialsKeyVault.getSecret(last(split(effectiveDomainJoinUsernameSecretUri, '/'))!)
      : ''
    domainName: domainName
    domainJoinDeploymentVirtualMachine: deployFSLogixStorage && fslogixStorageSolution == 'AzureNetAppFiles'
    encryptionAtHost: true
    fslogix: deployFSLogixStorage
    fslogixAppUpdateUserAssignedIdentityResourceId: fslogixAppUpdateUserAssignedIdentityResourceId
    hostPoolName: naming.outputs.hostPoolName
    identitySolution: identitySolution
    keyManagementDisks: 'PlatformManaged'
    keyManagementStorageAccounts: fslogixKeyManagementStorage
    location: location
    ouPath: organizationalUnitPath
    resourceGroupControlPlane: naming.outputs.resourceGroupControlPlane
    resourceGroupDeployment: naming.outputs.resourceGroupDeployment
    resourceGroupHosts: naming.outputs.resourceGroupHosts
    resourceGroupSecurity: naming.outputs.resourceGroupHosts
    resourceGroupStorage: naming.outputs.resourceGroupStorage
    tags: tags
    userAssignedIdentityNameConv: naming.outputs.userAssignedIdentityNameConv
    virtualMachineName: naming.outputs.depVirtualMachineName
    virtualMachineNICName: naming.outputs.depVirtualMachineNicName
    virtualMachineDiskName: naming.outputs.depVirtualMachineDiskName
    virtualMachineSubnetResourceId: virtualMachineSubnetResourceId
    manageHostResourcePermissions: false
  }
  dependsOn: [
    deploymentResourceGroup
    storageResourceGroup
    controlPlaneResourceGroup
  ]
}

module controlPlane 'modules/controlPlane.bicep' = {
  params: {
    resourceGroupName: naming.outputs.resourceGroupControlPlane
    location: controlPlaneLocation
    hostPoolName: naming.outputs.hostPoolName
    applicationGroupName: naming.outputs.desktopApplicationGroupName
    workspaceName: naming.outputs.workspaceName
    existingWorkspaceResourceId: existingWorkspaceResourceId
    workspaceFriendlyName: workspaceFriendlyName
    desktopFriendlyName: desktopFriendlyName
    deploymentVirtualMachineName: createDeploymentVm ? deploymentHelper!.outputs.virtualMachineName : ''
    deploymentUserAssignedIdentityClientId: createDeploymentVm
      ? deploymentHelper!.outputs.deploymentUserAssignedIdentityClientId
      : ''
    deploymentResourceGroupName: naming.outputs.resourceGroupDeployment
    deploymentLocation: location
    appGroupSecurityGroupIds: appGroupSecurityGroupIds
    maxSessionLimit: hostPoolMaxSessionLimit
    loadBalancerType: loadBalancerType
    customRdpProperty: hostPoolRDPProperties
    validationEnvironment: hostPoolValidationEnvironment
    startVMOnConnect: startVMOnConnect
    sessionHostResourceGroupName: naming.outputs.resourceGroupHosts
    subnetResourceId: virtualMachineSubnetResourceId
    customImageResourceId: customImageResourceId
    credentialsKeyVaultResourceId: credentialsKeyVaultConfigurationIsValid ? credentialsKeyVaultResourceId : credentialsKeyVaultResourceId
    diskEncryptionSetResourceId: effectiveDiskEncryptionSetResourceId
    avdServicePrincipalObjectId: deployDynamicScalingPlan ? avdServicePrincipalObjectId : ''
    sessionHostConfigurationProperties: {
      availabilityZones: !empty(availabilityZones) ? availabilityZones : null
      diskInfo: {
        managedDisk: {
          type: diskSku
        }
        diffDiskSettings: useEphemeralOsDisk
          ? {
              option: 'Local'
              placement: ephemeralOsDiskPlacement
            }
          : null
      }
      domainInfo: {
        joinType: domainJoinRequired ? 'ActiveDirectory' : 'AzureActiveDirectory'
        activeDirectoryInfo: domainJoinRequired
          ? {
              domainCredentials: {
                usernameKeyVaultSecretUri: domainConfigurationIsValid ? effectiveDomainJoinUsernameSecretUri : effectiveDomainJoinUsernameSecretUri
                passwordKeyVaultSecretUri: effectiveDomainJoinPasswordSecretUri
              }
              domainName: domainName
              ouPath: organizationalUnitPath
            }
          : null
        azureActiveDirectoryInfo: !domainJoinRequired && intuneEnrollment
          ? {
              mdmProviderGuid: '0000000a-0000-0000-c000-000000000000'
            }
          : null
      }
      imageInfo: !empty(customImageResourceId)
        ? {
            type: 'Custom'
            customInfo: {
              resourceId: customImageResourceId
            }
          }
        : {
            type: 'Marketplace'
            marketplaceInfo: {
              publisher: imagePublisher
              offer: imageOffer
              sku: imageSku
              exactVersion: marketplaceImageConfigurationIsValid ? imageVersion : imageVersion
            }
          }
      networkInfo: {
        subnetId: virtualMachineSubnetResourceId
      }
      securityInfo: {
        type: securityType
        secureBootEnabled: secureBootEnabled
        vTpmEnabled: vTpmEnabled
      }
      vmAdminCredentials: {
        usernameKeyVaultSecretUri: effectiveVmAdministratorUsernameSecretUri
        passwordKeyVaultSecretUri: effectiveVmAdministratorPasswordSecretUri
      }
      vmLocation: location
      vmNamePrefix: virtualMachineNamePrefix
      vmResourceGroup: naming.outputs.resourceGroupHosts
      vmSizeId: virtualMachineSize
      vmTags: union(
        tags[?'Microsoft.Compute/virtualMachines'] ?? {},
        {
          'cm-resource-parent': resourceId(
            subscription().subscriptionId,
            naming.outputs.resourceGroupControlPlane,
            'Microsoft.DesktopVirtualization/hostPools',
            naming.outputs.hostPoolName
          )
        }
      )
    }
    sessionHostManagementPrepareProperties: {
      failedSessionHostCleanupPolicy: failedSessionHostCleanupPolicy
      scheduledDateTimeZone: virtualMachinesTimeZone
      update: {
        deleteOriginalVm: deleteOriginalVm
        logOffDelayMinutes: updateLogOffDelayMinutes
        logOffMessage: updateLogOffMessage
        maxVmsRemoved: updateMaxVmsRemoved
      }
    }
    deployDynamicScalingPlan: deployDynamicScalingPlan
    scalingPlanName: naming.outputs.scalingPlanName
    scalingPlanTimeZone: avdServicePrincipalIsValid && dynamicScalingLimitsAreValid && dynamicScalingRampDownSettingsAreValid && dynamicScalingSchedulesAreValid
      ? scalingPlanTimeZone
      : scalingPlanTimeZone
    scalingPlanExclusionTag: scalingPlanExclusionTag
    dynamicScalingSchedules: effectiveDynamicScalingSchedules
    hostPoolCustomTags: hostPoolCustomTags
    avdPrivateLinkPrivateRoutes: avdPrivateLinkConfigurationIsValid ? avdPrivateLinkPrivateRoutes : avdPrivateLinkPrivateRoutes
    hostPoolPrivateEndpointSubnetResourceId: hostPoolPrivateEndpointSubnetResourceId
    avdPrivateDnsZoneResourceId: avdPrivateDnsZoneResourceId
    hostPoolPublicNetworkAccess: hostPoolPublicNetworkAccess
    workspaceFeedPrivateEndpointSubnetResourceId: workspaceFeedPrivateEndpointSubnetResourceId
    workspacePublicNetworkAccess: workspaceFeedPublicNetworkAccess
    existingGlobalWorkspaceResourceId: existingGlobalFeedResourceId
    globalFeedPrivateEndpointSubnetResourceId: globalFeedPrivateEndpointSubnetResourceId
    globalFeedPrivateDnsZoneResourceId: globalFeedPrivateDnsZoneResourceId
    globalWorkspaceName: naming.outputs.globalFeedWorkspaceName
    resourceGroupGlobalFeed: naming.outputs.globalFeedResourceGroupName
    privateEndpointNameConv: naming.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: naming.outputs.privateEndpointNICNameConv
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    tags: tags
  }
  dependsOn: [
    avdServicePrincipalRbac
    controlPlaneResourceGroup
    globalFeedResourceGroup
  ]
}

module fslogixStorageCmk '../shared/modules/orchestration/customerManagedKeys/storageCmk.bicep' = if (deployFslogixStorageCmk && fslogixStorageCmkConfigurationIsValid) {
  params: {
    resourceGroupName: naming.outputs.resourceGroupStorage
    keyVaultResourceId: fslogixEncryptionKeyVaultResourceId
    keyManagementType: contains(fslogixKeyManagementStorage, 'HSM') ? 'CustomerManagedHSM' : 'CustomerManaged'
    keyExpirationInDays: fslogixKeyExpirationInDays
    location: location
    tags: tags
    parentResourceId: hostPoolResourceId
    storageKeyNames: [
      for i in range(0, fslogixStorageCount): replace(naming.outputs.encryptionKeyNameFSLogix, '##', padLeft(i + fslogixStorageIndex, 2, '0'))
    ]
    identityName: replace(naming.outputs.userAssignedIdentityNameConv, 'TOKEN', 'storage${naming.outputs.delimiter}cmk')
  }
  dependsOn: [storageResourceGroup]
}

module fslogixStorage '../shared/modules/orchestration/fslogix/fslogix.bicep' = if (deployFSLogixStorage) {
  params: {
    activeDirectoryConnection: fslogixStorageIdentityConfigurationIsValid ? existingSharedActiveDirectoryConnection : existingSharedActiveDirectoryConnection
    createNetAppAccount: true
    createNetAppCapacityPool: true
    appUpdateUserAssignedIdentityResourceId: fslogixAppUpdateUserAssignedIdentityResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    deploymentUserAssignedIdentityClientId: deploymentHelper!.outputs.deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deploymentHelper!.outputs.virtualMachineName
    #disable-next-line BCP422
    domainJoinUserPassword: fslogixDomainCredentialsRequired
      ? credentialsKeyVault.getSecret(last(split(effectiveDomainJoinPasswordSecretUri, '/'))!)
      : ''
    #disable-next-line BCP422
    domainJoinUserPrincipalName: fslogixDomainCredentialsRequired
      ? credentialsKeyVault.getSecret(last(split(effectiveDomainJoinUsernameSecretUri, '/'))!)
      : ''
    domainName: domainName
    #disable-next-line BCP318
    encryptionKeyVaultUri: deployFslogixStorageCmk ? fslogixEncryptionKeyVault.properties.vaultUri : ''
    encryptionUserAssignedIdentityResourceId: deployFslogixStorageCmk
      ? fslogixStorageCmk!.outputs.storageEncryptionIdentityResourceId
      : ''
    fslogixAdminGroups: fslogixAdminGroups
    fslogixEncryptionKeyNameConv: naming.outputs.encryptionKeyNameFSLogix
    fslogixFileShares: fslogixFileShareNames
    fslogixShardOptions: fslogixShardingConfigurationIsValid ? fslogixShardOptions : fslogixShardOptions
    fslogixSoftDeleteRetentionDays: fslogixSoftDeleteRetentionDays
    fslogixStorageRedundancy: fslogixStorageRedundancy
    fslogixUserGroups: fslogixUserGroups
    recoveryServicesVaultResourceId: existingFilesBackupVaultResourceId
    fileSharePolicyName: existingFilesBackupPolicyName
    hostPoolResourceId: controlPlane.outputs.hostPoolResourceId
    identitySolution: identitySolution
    kerberosEncryptionType: fslogixStorageKerberosEncryptionType
    keyManagementStorageAccounts: fslogixKeyManagementStorage
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    netAppAccountName: naming.outputs.netAppAccountName
    netAppCapacityPoolName: naming.outputs.netAppCapacityPoolName
    netAppVolumesSubnetResourceId: netAppVolumesSubnetResourceId
    ouPath: empty(fslogixOUPath) ? organizationalUnitPath : fslogixOUPath
    permittedIPs: fslogixPermittedIPs
    privateEndpoint: fslogixPrivateEndpoint
    privateEndpointNameConv: naming.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: naming.outputs.privateEndpointNICNameConv
    privateEndpointSubnetResourceId: fslogixPrivateEndpointSubnetResourceId
    resourceGroupDeployment: naming.outputs.resourceGroupDeployment
    resourceGroupStorage: naming.outputs.resourceGroupStorage
    shareSizeInGB: fslogixShareSizeInGB
    smbServerLocation: naming.outputs.vmsLocAbbr
    storageAccountNamePrefix: naming.outputs.fslogixStorageAccountNamePrefix
    storageCount: fslogixStorageCount
    storageIndex: fslogixStorageIndex
    storageSku: split(fslogixStorageService, ' ')[1]
    storageSolution: fslogixStorageSolution
    tags: tags
  }
  dependsOn: [storageResourceGroup]
}

module existingNetAppVolumeFqdns '../shared/modules/orchestration/fslogix/modules/getNetAppVolumeSmbServerFqdns.bicep' = if (fslogixConfigureSessionHosts && ((!deployFSLogixStorage && !empty(fslogixExistingLocalNetAppVolumeResourceIds)) || !empty(fslogixExistingRemoteNetAppVolumeResourceIds))) {
  params: {
    localNetAppVolumeResourceIds: fslogixExistingLocalNetAppVolumeResourceIds
    remoteNetAppVolumeResourceIds: fslogixExistingRemoteNetAppVolumeResourceIds
    shareNames: fslogixFileShareNames
  }
}

var existingFslogixConfiguration = {
  identitySolution: identitySolution
  storageService: fslogixStorageSolution
  containerType: fslogixContainerType
  fileShareNames: fslogixFileShareNames
  localStorageAccountResourceIds: fslogixExistingLocalStorageAccountResourceIds
  remoteStorageAccountResourceIds: fslogixExistingRemoteStorageAccountResourceIds
  localNetAppServerFqdns: empty(fslogixExistingLocalNetAppVolumeResourceIds) ? [] : existingNetAppVolumeFqdns!.outputs.localNetAppVolumeSmbServerFqdns
  remoteNetAppServerFqdns: empty(fslogixExistingRemoteNetAppVolumeResourceIds) ? [] : existingNetAppVolumeFqdns!.outputs.remoteNetAppVolumeSmbServerFqdns
  objectSpecificSettingsGroups: fslogixShardOptions == 'ShardOSS' ? map(fslogixUserGroups, group => group.name) : []
  profileSizeInMBs: fslogixProfileSizeInMBs
}

var deployedFslogixConfiguration = {
  identitySolution: identitySolution
  storageService: fslogixStorageSolution
  containerType: fslogixContainerType
  fileShareNames: fslogixFileShareNames
  localStorageAccountResourceIds: fslogixStorage!.outputs.storageAccountResourceIds
  remoteStorageAccountResourceIds: fslogixExistingRemoteStorageAccountResourceIds
  localNetAppServerFqdns: fslogixStorage!.outputs.netAppServerFqdns
  remoteNetAppServerFqdns: empty(fslogixExistingRemoteNetAppVolumeResourceIds) ? [] : existingNetAppVolumeFqdns!.outputs.remoteNetAppVolumeSmbServerFqdns
  objectSpecificSettingsGroups: fslogixShardOptions == 'ShardOSS' ? map(fslogixUserGroups, group => group.name) : []
  profileSizeInMBs: fslogixProfileSizeInMBs
}

module sessionHostPolicy 'policy/main.bicep' = {
  params: {
    location: location
    sessionHostResourceGroupName: naming.outputs.resourceGroupHosts
    hostPoolResourceId: controlPlane.outputs.hostPoolResourceId
    policyIdentityName: naming.outputs.policyRemediationIdentityName
    diskEncryptionSetResourceId: effectiveDiskEncryptionSetResourceId
    disableManagedDiskPublicNetworkAccess: disableManagedDiskPublicNetworkAccess
    enableMonitoring: monitoringConfigurationIsValid && monitoringIdentityConfigurationIsValid
      ? enableMonitoring
      : enableMonitoring
    dataCollectionRuleResourceId: dataCollectionRuleResourceId
    dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
    integrityMonitoring: integrityMonitoring
    encryptionAtHost: encryptionAtHost
    diskSizeGB: diskSizeGB
    enableAcceleratedNetworking: enableAcceleratedNetworking
    virtualMachinesTimeZone: virtualMachinesTimeZone
    configureFSLogix: fslogixShardingConfigurationIsValid && fslogixExistingStorageConfigurationIsValid && fslogixExistingNetAppConfigurationIsValid
      ? fslogixConfigureSessionHosts
      : fslogixConfigureSessionHosts
    fslogixConfiguration: deployFSLogixStorage ? deployedFslogixConfiguration : existingFslogixConfiguration
    artifactsContainerUri: artifactsContainerUri
    artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
    sessionHostCustomizations: sessionHostCustomizations
    sessionHostVmApplications: sessionHostVmApplications
    tags: tags
  }
  dependsOn: [sessionHostResourceGroup]
}

module policyPropagationWait 'modules/waitForPolicyPropagation.bicep' = {
  params: {
    resourceGroupName: naming.outputs.resourceGroupDeployment
    virtualMachineName: deploymentHelper!.outputs.virtualMachineName
    location: location
  }
  dependsOn: [sessionHostPolicy]
}

module finalSessionHostManagement 'modules/sessionHostManagement.bicep' = if (!deployDynamicScalingPlan) {
  params: {
    resourceGroupName: naming.outputs.resourceGroupControlPlane
    hostPoolName: naming.outputs.hostPoolName
    properties: {
      failedSessionHostCleanupPolicy: failedSessionHostCleanupPolicy
      provisioning: {
        instanceCount: sessionHostCount
        canaryPolicy: 'Auto'
        setDrainMode: false
      }
      scheduledDateTimeZone: virtualMachinesTimeZone
      update: {
        deleteOriginalVm: deleteOriginalVm
        logOffDelayMinutes: updateLogOffDelayMinutes
        logOffMessage: updateLogOffMessage
        maxVmsRemoved: updateMaxVmsRemoved
      }
    }
  }
  dependsOn: [
    controlPlane
    policyPropagationWait
  ]
}

module activateDynamicScalingPlan 'modules/activateDynamicScalingPlan.bicep' = if (deployDynamicScalingPlan) {
  params: {
    resourceGroupName: naming.outputs.resourceGroupControlPlane
    scalingPlanName: naming.outputs.scalingPlanName
    location: controlPlaneLocation
    tags: tags[?'Microsoft.DesktopVirtualization/scalingPlans'] ?? {}
    scalingPlanTimeZone: scalingPlanTimeZone
    scalingPlanExclusionTag: scalingPlanExclusionTag
    hostPoolResourceId: controlPlane.outputs.hostPoolResourceId
  }
  dependsOn: [
    policyPropagationWait
  ]
}

module cleanupDeploymentHelper '../shared/modules/orchestration/deploymentHelper/cleanup.bicep' = if (createDeploymentVm) {
  params: {
    location: location
    resourceGroupDeployment: naming.outputs.resourceGroupDeployment
    resourceGroupHosts: naming.outputs.resourceGroupHosts
    userAssignedIdentityClientId: deploymentHelper!.outputs.deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deploymentHelper!.outputs.virtualMachineName
    roleAssignmentIds: deploymentHelper!.outputs.deploymentUserAssignedIdentityRoleAssignmentIds
    virtualMachineNames: []
    removeHostRunCommands: false
  }
  dependsOn: [policyPropagationWait]
}

output hostPoolResourceId string = controlPlane.outputs.hostPoolResourceId
output workspaceResourceId string = controlPlane.outputs.workspaceResourceId
output applicationGroupResourceId string = controlPlane.outputs.applicationGroupResourceId
output sessionHostConfigurationResourceId string = controlPlane.outputs.sessionHostConfigurationResourceId
output sessionHostManagementResourceId string = deployDynamicScalingPlan
  ? controlPlane.outputs.sessionHostManagementPrepareResourceId
  : finalSessionHostManagement!.outputs.resourceId
output sessionHostResourceGroupId string = sessionHostResourceGroup.outputs.resourceId
output fslogixStorageAccountResourceIds array = deployFSLogixStorage ? fslogixStorage!.outputs.storageAccountResourceIds : []
output policyIdentityResourceId string = sessionHostPolicy.outputs.policyIdentityResourceId
output scalingPlanResourceId string = controlPlane.outputs.scalingPlanResourceId
output hostPoolPrivateEndpointResourceId string = controlPlane.outputs.hostPoolPrivateEndpointResourceId
output workspaceFeedPrivateEndpointResourceId string = controlPlane.outputs.workspaceFeedPrivateEndpointResourceId
output globalFeedWorkspaceResourceId string = controlPlane.outputs.globalFeedWorkspaceResourceId
output globalFeedPrivateEndpointResourceId string = controlPlane.outputs.globalFeedPrivateEndpointResourceId
