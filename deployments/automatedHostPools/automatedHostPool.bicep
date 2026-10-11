targetScope = 'subscription'

import { artifactCustomizationType } from '../shared/modules/resourceModules/types/customizationTypes.bicep'
import { vmApplicationAssignmentType } from '../shared/modules/orchestration/sessionHostPolicy/vmApplicationTypes.bicep'
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
  rampUpLoadBalancingAlgorithm: ('BreadthFirst' | 'DepthFirst')?
  rampUpMinimumHostsPct: string
  rampUpCapacityThresholdPct: string
  rampUpMinimumHostPoolSize: string
  rampUpMaximumHostPoolSize: string
  peakStartTime: string
  peakLoadBalancingAlgorithm: ('BreadthFirst' | 'DepthFirst')?
  rampDownStartTime: string
  rampDownLoadBalancingAlgorithm: ('BreadthFirst' | 'DepthFirst')?
  rampDownMinimumHostsPct: string
  rampDownCapacityThresholdPct: string
  rampDownMinimumHostPoolSize: string
  rampDownMaximumHostPoolSize: string
  rampDownForceLogoffUsers: bool?
  rampDownWaitTimeMinutes: string?
  rampDownNotificationMessage: string?
  rampDownStopHostsWhen: ('ZeroSessions' | 'ZeroActiveSessions')?
  offPeakStartTime: string
  offPeakLoadBalancingAlgorithm: ('BreadthFirst' | 'DepthFirst')?
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

@description('Optional. Existing Key Vault resource ID containing the VM administrator and optional domain-join credentials. When empty, the orchestrator creates the Shared Services secrets Key Vault.')
param credentialsKeyVaultResourceId string = ''

@secure()
@description('Conditional. Local administrator username stored in a newly created Shared Services secrets Key Vault.')
param virtualMachineAdminUserName string = ''

@secure()
@description('Conditional. Local administrator password stored in a newly created Shared Services secrets Key Vault.')
param virtualMachineAdminPassword string = ''

@secure()
@description('Conditional. Domain-join user principal name stored in a newly created Shared Services secrets Key Vault.')
param domainJoinUserPrincipalName string = ''

@secure()
@description('Conditional. Domain-join password stored in a newly created Shared Services secrets Key Vault.')
param domainJoinUserPassword string = ''

@description('Optional. Enable purge protection on a newly created Shared Services secrets Key Vault.')
param secretsKeyVaultEnablePurgeProtection bool = true

@description('Optional. Soft-delete retention in days for a newly created Shared Services secrets Key Vault.')
@minValue(7)
@maxValue(90)
param secretsKeyVaultRetentionInDays int = 90

@description('Optional. Complete name override for a newly created Shared Services secrets Key Vault.')
@maxLength(24)
#disable-next-line secure-secrets-in-params
param secretsKeyVaultNameOverride string = ''

@description('Optional. Soft-delete retention in days for a newly created Shared Services encryption Key Vault.')
@minValue(7)
@maxValue(90)
param encryptionKeyVaultRetentionInDays int = 90

@description('Optional. Complete name override for a newly created Shared Services encryption Key Vault.')
@maxLength(24)
param encryptionKeyVaultNameOverride string = ''

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

@description('Required. Prefix used by Azure Virtual Desktop when naming session-host VMs. Maximum 10 characters.')
@maxLength(10)
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
  'TempDisk'
])
@description('Optional. Local storage used for the ephemeral OS disk. Use TempDisk for VM resource-disk placement.')
param ephemeralOsDiskPlacement string = 'TempDisk'

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

@allowed([
  'AvailabilityZones'
  'AvailabilitySets'
  'None'
])
@description('Optional. Infrastructure redundancy for session hosts. AvailabilitySets creates one managed Availability Set and requires update headroom within its 200-VM limit.')
param availability string = !empty(availabilityZones) ? 'AvailabilityZones' : 'None'

@description('Optional. Availability zones used for new session hosts when availability is AvailabilityZones.')
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
param existingFeedWorkspaceResourceId string = ''

@allowed([
  'Shared'
  'HostPoolSpecific'
])
@description('Optional. Controls naming when a new AVD workspace is created. Shared preserves the production-compatible region-level name. HostPoolSpecific includes the host-pool identifier for an isolated PoC. Ignored when existingFeedWorkspaceResourceId is supplied.')
param workspaceCreationScope string = 'Shared'

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
param fslogixStorageService string = 'AzureFiles Premium'

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

@description('Optional. Register newly deployed FSLogix Azure Files shares for snapshot backup. When no existing vault is supplied, Shared Services creates the vault and policy.')
param enableFSLogixBackup bool = false

@description('Optional. Name of the Azure Files snapshot backup policy in the existing Recovery Services vault.')
param existingFilesBackupPolicyName string = 'filesharepolicy'

@minValue(1)
@maxValue(200)
@description('Optional. Number of daily Azure Files snapshot recovery points retained when Shared Services creates the backup policy.')
param backupRetentionDays int = 30

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

@description('Optional. Deploy private endpoints for newly created Shared Services Key Vault and Recovery Services resources.')
param deployPrivateEndpoints bool = false

@description('Conditional. Resource ID of the subnet for newly created Shared Services private endpoints.')
param operationsPrivateEndpointSubnetResourceId string = ''

@description('Optional. Resource ID of the Azure Key Vault private DNS zone.')
param azureKeyVaultPrivateDnsZoneResourceId string = ''

@description('Optional. Resource ID of the Azure Backup private DNS zone.')
param azureBackupPrivateDnsZoneResourceId string = ''

@description('Optional. Resource ID of the Azure Blob private DNS zone required by Azure Backup private endpoints.')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Optional. Resource ID of the Azure Queue private DNS zone required by Azure Backup private endpoints.')
param azureQueuePrivateDnsZoneResourceId string = ''

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
@description('Optional. Authoritative ordered list of Azure Compute Gallery application version references assigned to automated session hosts through Azure Policy. References may select a specific version or use /versions/latest. Azure supports at most 25 VM Applications per VM.')
param sessionHostVmApplications vmApplicationAssignmentType[] = []

@description('Optional. Maximum VMs replaced concurrently during a Session Host Configuration update.')
@minValue(1)
param updateMaxVmsRemoved int = 1

@description('Optional. Minutes users have to sign out before an updated host is removed. Must be between 0 and 60 minutes.')
@minValue(0)
@maxValue(60)
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

var deploySharedSecretsKeyVault = empty(credentialsKeyVaultResourceId)
var encryptionKeyVaultIsRequired = deployDiskEncryptionSet && empty(diskEncryptionSetResourceId) || contains(
  fslogixKeyManagementStorage,
  'CustomerManaged'
)
var existingSharedEncryptionKeyVaultResourceId = !empty(encryptionKeyVaultResourceId)
  ? encryptionKeyVaultResourceId
  : fslogixEncryptionKeyVaultResourceId
var deploySharedEncryptionKeyVault = encryptionKeyVaultIsRequired && empty(existingSharedEncryptionKeyVaultResourceId)
var fslogixBackupIsRequested = enableFSLogixBackup || !empty(existingFilesBackupVaultResourceId)
var deploySharedFilesBackup = fslogixBackupIsRequested && deployFSLogixStorage && startsWith(
  fslogixStorageService,
  'AzureFiles'
) && empty(existingFilesBackupVaultResourceId)
var createHostPoolSpecificWorkspace = empty(existingFeedWorkspaceResourceId) && workspaceCreationScope == 'HostPoolSpecific'
var effectiveNamingConvention = union(
  namingConvention,
  !empty(secretsKeyVaultNameOverride) ? { secretsKeyVaultNameOverride: secretsKeyVaultNameOverride } : {},
  !empty(encryptionKeyVaultNameOverride) ? { encryptionKeyVaultNameOverride: encryptionKeyVaultNameOverride } : {}
)

module naming '../shared/modules/orchestration/naming/hostPool.bicep' = {
  params: {
    namingConvention: effectiveNamingConvention
    virtualMachinesRegion: location
    controlPlaneRegion: controlPlaneLocation
    identifier: toLower(identifier)
    globalFeedRegion: avdPrivateLinkPrivateRoutes == 'All' ? controlPlaneLocation : ''
    existingFeedWorkspaceResourceId: existingFeedWorkspaceResourceId
  }
}

var deploySharedMonitoring = enableMonitoring && empty(logAnalyticsWorkspaceResourceId)
var deploySharedOperationsResourceGroup = deploySharedSecretsKeyVault || deploySharedEncryptionKeyVault || deploySharedFilesBackup
var sharedPrivateEndpoint = deployPrivateEndpoints && (deploySharedSecretsKeyVault || deploySharedEncryptionKeyVault || deploySharedFilesBackup)
var sharedWorkspaceResourceGroupName = createHostPoolSpecificWorkspace
  ? naming.outputs.resourceGroupControlPlane
  : naming.outputs.sharedResourceGroupControlPlane
var sharedWorkspaceName = createHostPoolSpecificWorkspace
  ? naming.outputs.workspaceName
  : naming.outputs.sharedWorkspaceName

module sharedMonitoring '../shared/modules/orchestration/monitoring/monitoring.bicep' = if (deploySharedMonitoring) {
  params: {
    location: controlPlaneLocation
    azureMonitorPrivateLinkScopeResourceId: ''
    dataCollectionEndpointName: naming.outputs.sharedDataCollectionEndpointName
    logAnalyticsWorkspaceName: naming.outputs.sharedLogAnalyticsWorkspaceName
    resourceGroupMonitoring: naming.outputs.sharedResourceGroupMonitoring
    tags: tags
  }
  dependsOn: [sharedMonitoringResourceGroup]
}

var effectiveLogAnalyticsWorkspaceResourceId = enableMonitoring
  ? (deploySharedMonitoring ? sharedMonitoring!.outputs.logAnalyticsWorkspaceResourceId : logAnalyticsWorkspaceResourceId)
  : ''
var effectiveDataCollectionRuleResourceId = enableMonitoring
  ? (deploySharedMonitoring ? sharedMonitoring!.outputs.avdInsightsDataCollectionRuleResourceId : dataCollectionRuleResourceId)
  : ''
var effectiveDataCollectionEndpointResourceId = enableMonitoring
  ? (deploySharedMonitoring ? sharedMonitoring!.outputs.dataCollectionEndpointResourceId : dataCollectionEndpointResourceId)
  : ''

module sharedKeyVaults '../shared/modules/orchestration/keyVaults/keyVaults.bicep' = {
  params: {
    resourceGroupName: naming.outputs.sharedResourceGroupOperations
    deploySecretsKeyVault: deploySharedSecretsKeyVault
    secretsKeyVaultName: naming.outputs.sharedKeyVaultNameSecrets
    secretsKeyVaultEnableSoftDelete: true
    secretsKeyVaultEnablePurgeProtection: secretsKeyVaultEnablePurgeProtection
    secretsKeyVaultRetentionInDays: secretsKeyVaultRetentionInDays
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    virtualMachineAdminPassword: virtualMachineAdminPassword
    virtualMachineAdminUserName: virtualMachineAdminUserName
    deployEncryptionKeyVault: deploySharedEncryptionKeyVault
    encryptionKeyVaultName: naming.outputs.sharedKeyVaultNameEncryption
    encryptionKeyVaultRetentionInDays: encryptionKeyVaultRetentionInDays
    privateEndpoint: sharedPrivateEndpoint
    privateEndpointSubnetResourceId: operationsPrivateEndpointSubnetResourceId
    azureKeyVaultPrivateDnsZoneResourceId: azureKeyVaultPrivateDnsZoneResourceId
    privateEndpointNameConv: naming.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: naming.outputs.privateEndpointNICNameConv
    permittedIPs: []
    logAnalyticsWorkspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId
    tags: tags
  }
  dependsOn: [sharedOperationsResourceGroup]
}

var effectiveCredentialsKeyVaultResourceId = deploySharedSecretsKeyVault
  ? sharedKeyVaults.outputs.secretsKeyVaultResourceId
  : credentialsKeyVaultResourceId
var effectiveEncryptionKeyVaultResourceId = deploySharedEncryptionKeyVault
  ? sharedKeyVaults.outputs.encryptionKeyVaultResourceId
  : existingSharedEncryptionKeyVaultResourceId
var effectiveDiskEncryptionKeyVaultResourceId = deployDiskEncryptionSet
  ? (!empty(encryptionKeyVaultResourceId) ? encryptionKeyVaultResourceId : effectiveEncryptionKeyVaultResourceId)
  : ''
var effectiveFSLogixEncryptionKeyVaultResourceId = contains(fslogixKeyManagementStorage, 'CustomerManaged')
  ? (!empty(fslogixEncryptionKeyVaultResourceId) ? fslogixEncryptionKeyVaultResourceId : effectiveEncryptionKeyVaultResourceId)
  : ''

module sharedAvdWorkspace '../shared/modules/orchestration/avdWorkspace/avdWorkspace.bicep' = {
  params: {
    workspaceMode: empty(existingFeedWorkspaceResourceId) ? 'Create' : 'Adopt'
    manageWorkspace: true
    workspaceName: sharedWorkspaceName
    workspaceResourceId: existingFeedWorkspaceResourceId
    workspaceResourceGroupName: sharedWorkspaceResourceGroupName
    createWorkspaceResourceGroup: !createHostPoolSpecificWorkspace
    workspaceLocation: controlPlaneLocation
    workspaceFriendlyName: workspaceFriendlyName
    workspacePublicNetworkAccess: workspaceFeedPublicNetworkAccess
    workspaceFeedPrivateEndpointSubnetResourceId: contains(['FeedAndHostPool', 'All'], avdPrivateLinkPrivateRoutes)
      ? workspaceFeedPrivateEndpointSubnetResourceId
      : ''
    avdPrivateDnsZoneResourceId: avdPrivateDnsZoneResourceId
    logAnalyticsWorkspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId
    manageGlobalWorkspace: avdPrivateLinkPrivateRoutes == 'All' && empty(existingGlobalFeedResourceId)
    globalWorkspaceMode: empty(existingGlobalFeedResourceId) ? 'Create' : 'Adopt'
    globalWorkspaceName: naming.outputs.globalFeedWorkspaceName
    globalWorkspaceResourceId: existingGlobalFeedResourceId
    globalWorkspaceResourceGroupName: naming.outputs.globalFeedResourceGroupName
    globalWorkspacePublicNetworkAccess: workspaceFeedPublicNetworkAccess
    globalFeedPrivateEndpointSubnetResourceId: globalFeedPrivateEndpointSubnetResourceId
    globalFeedPrivateDnsZoneResourceId: globalFeedPrivateDnsZoneResourceId
    privateEndpointNameConv: naming.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: naming.outputs.privateEndpointNICNameConv
    tags: tags
  }
  dependsOn: [controlPlaneResourceGroup]
}

var effectiveFeedWorkspaceResourceId = sharedAvdWorkspace.outputs.workspaceResourceId
var hostPoolPrivateLinkPrivateRoutes = avdPrivateLinkPrivateRoutes == 'None' ? 'None' : 'HostPool'

module sharedFilesBackup '../shared/modules/resourceModules/recoveryServices/fslogixBackupVault.bicep' = if (deploySharedFilesBackup) {
  params: {
    createVault: true
    manageBackupPolicy: true
    vaultName: naming.outputs.sharedRecoveryServicesVaultNameFSLogix
    resourceGroupOperations: naming.outputs.sharedResourceGroupOperations
    location: controlPlaneLocation
    logAnalyticsWorkspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId
    privateEndpoint: sharedPrivateEndpoint
    privateEndpointSubnetResourceId: operationsPrivateEndpointSubnetResourceId
    azureBackupPrivateDnsZoneResourceId: azureBackupPrivateDnsZoneResourceId
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    privateEndpointNameConv: naming.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: naming.outputs.privateEndpointNICNameConv
    tags: tags
    timeZone: 'UTC'
    fileSharePolicyName: existingFilesBackupPolicyName
    backupRetentionDays: backupRetentionDays
  }
  dependsOn: [sharedOperationsResourceGroup]
}

var effectiveFilesBackupVaultResourceId = fslogixBackupIsRequested
  ? (deploySharedFilesBackup
      ? sharedFilesBackup!.outputs.recoveryServicesVaultResourceId
      : existingFilesBackupVaultResourceId)
  : ''
var effectiveFilesBackupPolicyName = deploySharedFilesBackup
  ? sharedFilesBackup!.outputs.fileShareBackupPolicyName
  : (!empty(existingFilesBackupVaultResourceId) ? existingFilesBackupPolicyName : '')

resource credentialsKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: last(split(effectiveCredentialsKeyVaultResourceId, '/'))!
  scope: resourceGroup(split(effectiveCredentialsKeyVaultResourceId, '/')[2], split(effectiveCredentialsKeyVaultResourceId, '/')[4])
}

var commercialCloudIsValid = environment().name == 'AzureCloud'
  ? true
  : fail('Automated host pools are currently supported only in Azure Commercial.')
var hpBaseName = toLower(identifier)
var domainJoinRequired = contains(identitySolution, 'DomainServices')
var credentialsKeyVaultSecretBaseUri = 'https://${last(split(effectiveCredentialsKeyVaultResourceId, '/'))}.${environment().suffixes.keyvaultDns}/secrets'
var effectiveVmAdministratorUsernameSecretUri = !empty(vmAdministratorUsernameSecretUri) ? vmAdministratorUsernameSecretUri : '${credentialsKeyVaultSecretBaseUri}/VirtualMachineAdminUserName'
var effectiveVmAdministratorPasswordSecretUri = !empty(vmAdministratorPasswordSecretUri) ? vmAdministratorPasswordSecretUri : '${credentialsKeyVaultSecretBaseUri}/VirtualMachineAdminPassword'
var effectiveDomainJoinUsernameSecretUri = !empty(domainJoinUsernameSecretUri) ? domainJoinUsernameSecretUri : '${credentialsKeyVaultSecretBaseUri}/DomainJoinUserPrincipalName'
var effectiveDomainJoinPasswordSecretUri = !empty(domainJoinPasswordSecretUri) ? domainJoinPasswordSecretUri : '${credentialsKeyVaultSecretBaseUri}/DomainJoinUserPassword'
var domainConfigurationIsValid = !domainJoinRequired || !empty(domainName)
  ? true
  : fail('Domain-joined automated session hosts require domainName.')
var monitoringConfigurationIsValid = !enableMonitoring || !empty(effectiveDataCollectionRuleResourceId)
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
  rampUpLoadBalancingAlgorithm: schedule.?rampUpLoadBalancingAlgorithm ?? 'BreadthFirst'
  rampUpMinimumHostsPct: int(schedule.rampUpMinimumHostsPct)
  rampUpCapacityThresholdPct: int(schedule.rampUpCapacityThresholdPct)
  rampUpMinimumHostPoolSize: int(schedule.rampUpMinimumHostPoolSize)
  rampUpMaximumHostPoolSize: int(schedule.rampUpMaximumHostPoolSize)
  peakStartTime: parseScalingTime(schedule.peakStartTime)
  peakLoadBalancingAlgorithm: schedule.?peakLoadBalancingAlgorithm ?? 'BreadthFirst'
  rampDownStartTime: parseScalingTime(schedule.rampDownStartTime)
  rampDownLoadBalancingAlgorithm: schedule.?rampDownLoadBalancingAlgorithm ?? 'DepthFirst'
  rampDownMinimumHostsPct: int(schedule.rampDownMinimumHostsPct)
  rampDownCapacityThresholdPct: int(schedule.rampDownCapacityThresholdPct)
  rampDownMinimumHostPoolSize: int(schedule.rampDownMinimumHostPoolSize)
  rampDownMaximumHostPoolSize: int(schedule.rampDownMaximumHostPoolSize)
  rampDownForceLogoffUsers: schedule.?rampDownForceLogoffUsers ?? false
  rampDownWaitTimeMinutes: (schedule.?rampDownForceLogoffUsers ?? false)
    ? (empty(schedule.?rampDownWaitTimeMinutes ?? '') ? 30 : int(schedule.rampDownWaitTimeMinutes!))
    : 0
  rampDownNotificationMessage: (schedule.?rampDownForceLogoffUsers ?? false)
    ? (empty(schedule.?rampDownNotificationMessage ?? '') ? 'Save your work and sign out. This session host is being removed by autoscale.' : schedule.rampDownNotificationMessage!)
    : ''
  rampDownStopHostsWhen: schedule.?rampDownStopHostsWhen ?? 'ZeroSessions'
  offPeakStartTime: parseScalingTime(schedule.offPeakStartTime)
  offPeakLoadBalancingAlgorithm: schedule.?offPeakLoadBalancingAlgorithm ?? 'DepthFirst'
})
var invalidDynamicScalingLimits = filter(effectiveDynamicScalingSchedules, schedule => schedule.rampUpMinimumHostPoolSize > schedule.rampUpMaximumHostPoolSize || schedule.rampDownMinimumHostPoolSize > schedule.rampDownMaximumHostPoolSize)
var dynamicScalingLimitsAreValid = !deployDynamicScalingPlan || empty(invalidDynamicScalingLimits)
  ? true
  : fail('Dynamic scaling minimum host-pool sizes cannot exceed their corresponding maximum sizes.')
var dynamicScalingMaximumHostPoolSizes = flatten(map(effectiveDynamicScalingSchedules, schedule => [
  schedule.rampUpMaximumHostPoolSize
  schedule.rampDownMaximumHostPoolSize
]))
var maximumSessionHostCapacity = deployDynamicScalingPlan
  ? max(concat(dynamicScalingMaximumHostPoolSizes, [0]))
  : sessionHostCount
var availabilitySetCapacityIsValid = availability != 'AvailabilitySets'
  ? true
  : !deleteOriginalVm
      ? fail('Availability Sets require deleteOriginalVm to be true so replaced VMs do not permanently consume the single Availability Set capacity.')
      : maximumSessionHostCapacity + updateMaxVmsRemoved <= 200
          ? true
          : fail('Availability Set capacity is limited to 200 VMs. The initial sessionHostCount, or largest dynamic scaling maximum, plus updateMaxVmsRemoved must not exceed 200. For higher capacity, use Availability Zones when supported or select no infrastructure redundancy.')
var deployAvailabilitySet = availability == 'AvailabilitySets' && availabilitySetCapacityIsValid
var invalidDynamicScalingRampDownSettings = filter(effectiveDynamicScalingSchedules, schedule => schedule.rampDownWaitTimeMinutes < 0 || schedule.rampDownWaitTimeMinutes > 120 || schedule.rampDownForceLogoffUsers && empty(schedule.rampDownNotificationMessage))
var dynamicScalingRampDownSettingsAreValid = !deployDynamicScalingPlan || empty(invalidDynamicScalingRampDownSettings)
  ? true
  : fail('Dynamic scaling ramp-down waits must be between 0 and 120 minutes, and force logoff requires a notification message.')
var dynamicScalingScheduleNames = map(effectiveDynamicScalingSchedules, schedule => toLower(schedule.name))
var dynamicScalingScheduleDays = flatten(map(effectiveDynamicScalingSchedules, schedule => schedule.daysOfWeek))
var dynamicScalingSchedulesAreValid = !deployDynamicScalingPlan || !empty(effectiveDynamicScalingSchedules) && length(dynamicScalingScheduleNames) == length(union(dynamicScalingScheduleNames, dynamicScalingScheduleNames)) && length(dynamicScalingScheduleDays) == length(union(dynamicScalingScheduleDays, dynamicScalingScheduleDays))
  ? true
  : fail('Dynamic scaling requires at least one schedule, unique schedule names, and each day assigned to no more than one schedule.')
var availabilityConfigurationIsValid = availability == 'AvailabilityZones'
  ? (!empty(availabilityZones) ? true : fail('Select at least one availability zone when availability is AvailabilityZones.'))
  : (empty(availabilityZones) ? true : fail('Availability Zones and an Availability Set are mutually exclusive. Supply availabilityZones only when availability is AvailabilityZones.'))
var hostPoolPrivateEndpointConfigurationIsValid = hostPoolPrivateLinkPrivateRoutes == 'None' || !empty(hostPoolPrivateEndpointSubnetResourceId)
var workspaceConfigurationIsValid = !empty(effectiveFeedWorkspaceResourceId)
  ? true
  : fail('effectiveFeedWorkspaceResourceId is required. Create or adopt the workspace through the host-pool orchestrator or AVD Shared Services.')
var avdPrivateLinkConfigurationIsValid = workspaceConfigurationIsValid && hostPoolPrivateEndpointConfigurationIsValid
  ? true
  : fail('AVD Private Link requires a host-pool endpoint subnet, a workspace feed endpoint subnet for FeedAndHostPool or All, and an existing global feed or global endpoint subnet for All.')
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
var fslogixStorageCmkConfigurationIsValid = !deployFslogixStorageCmk || !empty(existingSharedEncryptionKeyVaultResourceId) || deploySharedEncryptionKeyVault
  ? true
  : fail('fslogixEncryptionKeyVaultResourceId is required when Azure Files uses customer-managed keys.')
var diskEncryptionSetConfigurationIsValid = !deployDiskEncryptionSet || (empty(diskEncryptionSetResourceId) && (!empty(existingSharedEncryptionKeyVaultResourceId) || deploySharedEncryptionKeyVault))
  ? true
  : fail('When deployDiskEncryptionSet is true, encryptionKeyVaultResourceId is required and diskEncryptionSetResourceId must be empty.')
var effectiveDiskEncryptionSetName = contains(keyManagementDisks, 'PlatformManagedAndCustomerManaged')
  ? naming.outputs.diskEncryptionSetNamePlatformAndCustomerManaged
  : naming.outputs.diskEncryptionSetNameCustomerManaged
var effectiveDiskEncryptionSetResourceId = deployDiskEncryptionSet
  ? virtualMachinesDiskCmk!.outputs.diskEncryptionSetResourceId
  : diskEncryptionSetResourceId

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

module controlPlaneResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = {
  params: {
    name: naming.outputs.resourceGroupControlPlane
    location: controlPlaneLocation
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module sharedOperationsResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (deploySharedOperationsResourceGroup) {
  params: {
    name: naming.outputs.sharedResourceGroupOperations
    location: controlPlaneLocation
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module sharedMonitoringResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (deploySharedMonitoring) {
  params: {
    name: naming.outputs.sharedResourceGroupMonitoring
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

module availabilitySet 'modules/availabilitySet.bicep' = if (deployAvailabilitySet) {
  params: {
    resourceGroupName: naming.outputs.resourceGroupHosts
    nameConvention: naming.outputs.availabilitySetNameConv
    location: location
    tags: union(parentResourceTag, tags[?'Microsoft.Compute/availabilitySets'] ?? {})
  }
  dependsOn: [sessionHostResourceGroup]
}

module storageResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (deployFSLogixStorage) {
  params: {
    name: naming.outputs.resourceGroupStorage
    location: location
    tags: union(tags[?'Microsoft.Resources/resourceGroups'] ?? {}, parentResourceTag)
  }
}

module deploymentResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = {
  params: {
    name: naming.outputs.resourceGroupDeployment
    location: location
    tags: union(tags[?'Microsoft.Resources/resourceGroups'] ?? {}, parentResourceTag)
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

module virtualMachinesDiskCmk '../shared/modules/orchestration/customerManagedKeys/diskCmk.bicep' = if (deployDiskEncryptionSet) {
  params: {
    resourceGroupName: naming.outputs.resourceGroupHosts
    keyVaultResourceId: diskEncryptionSetConfigurationIsValid ? effectiveDiskEncryptionKeyVaultResourceId : effectiveDiskEncryptionKeyVaultResourceId
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

module deploymentHelper '../shared/modules/orchestration/deploymentHelper/deploy.bicep' = {
  params: {
    confidentialVMOSDiskEncryption: false
    deploymentVmSize: deploymentVirtualMachineSize
    desktopFriendlyName: desktopFriendlyName
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
    existingFeedWorkspaceResourceId: effectiveFeedWorkspaceResourceId
    desktopFriendlyName: desktopFriendlyName
    deploymentVirtualMachineName: deploymentHelper.outputs.virtualMachineName
    deploymentUserAssignedIdentityClientId: deploymentHelper.outputs.deploymentUserAssignedIdentityClientId
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
    sessionHostVmApplications: sessionHostVmApplications
    credentialsKeyVaultResourceId: effectiveCredentialsKeyVaultResourceId
    diskEncryptionSetResourceId: effectiveDiskEncryptionSetResourceId
    avdServicePrincipalObjectId: deployDynamicScalingPlan ? avdServicePrincipalObjectId : ''
    sessionHostConfigurationProperties: {
      // Ascending order keeps the stored value consistent with portal edits, which submit zones numerically.
      availabilityZones: availabilityConfigurationIsValid && availability == 'AvailabilityZones'
        ? sort(availabilityZones, (a, b) => a < b)
        : null
      diskInfo: {
        managedDisk: {
          type: diskSku
        }
        diffDiskSettings: useEphemeralOsDisk
          ? {
              option: 'Local'
              // Compute SKU capabilities call this placement ResourceDisk, but the AVD API enum is TempDisk.
              placement: any(ephemeralOsDiskPlacement)
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
    avdPrivateLinkPrivateRoutes: avdPrivateLinkConfigurationIsValid ? hostPoolPrivateLinkPrivateRoutes : hostPoolPrivateLinkPrivateRoutes
    hostPoolPrivateEndpointSubnetResourceId: hostPoolPrivateEndpointSubnetResourceId
    avdPrivateDnsZoneResourceId: avdPrivateDnsZoneResourceId
    hostPoolPublicNetworkAccess: hostPoolPublicNetworkAccess
    privateEndpointNameConv: naming.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: naming.outputs.privateEndpointNICNameConv
    logAnalyticsWorkspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId
    tags: tags
  }
  dependsOn: [
    avdServicePrincipalRbac
    controlPlaneResourceGroup
  ]
}

module fslogixStorageCmk '../shared/modules/orchestration/customerManagedKeys/storageCmk.bicep' = if (deployFslogixStorageCmk && fslogixStorageCmkConfigurationIsValid) {
  params: {
    resourceGroupName: naming.outputs.resourceGroupStorage
    keyVaultResourceId: effectiveFSLogixEncryptionKeyVaultResourceId
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
    deploymentUserAssignedIdentityClientId: deploymentHelper.outputs.deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deploymentHelper.outputs.virtualMachineName
    #disable-next-line BCP422
    domainJoinUserPassword: fslogixDomainCredentialsRequired
      ? credentialsKeyVault.getSecret(last(split(effectiveDomainJoinPasswordSecretUri, '/'))!)
      : ''
    #disable-next-line BCP422
    domainJoinUserPrincipalName: fslogixDomainCredentialsRequired
      ? credentialsKeyVault.getSecret(last(split(effectiveDomainJoinUsernameSecretUri, '/'))!)
      : ''
    domainName: domainName
    encryptionKeyVaultUri: deployFslogixStorageCmk
      ? 'https://${last(split(effectiveFSLogixEncryptionKeyVaultResourceId, '/'))}.${environment().suffixes.keyvaultDns}/'
      : ''
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
    recoveryServicesVaultResourceId: effectiveFilesBackupVaultResourceId
    fileSharePolicyName: effectiveFilesBackupPolicyName
    hostPoolResourceId: controlPlane.outputs.hostPoolResourceId
    identitySolution: identitySolution
    kerberosEncryptionType: fslogixStorageKerberosEncryptionType
    keyManagementStorageAccounts: fslogixKeyManagementStorage
    location: location
    logAnalyticsWorkspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId
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
    availabilitySetResourceId: deployAvailabilitySet ? availabilitySet!.outputs.resourceId : ''
    disableManagedDiskPublicNetworkAccess: disableManagedDiskPublicNetworkAccess
    enableMonitoring: monitoringConfigurationIsValid && monitoringIdentityConfigurationIsValid
      ? enableMonitoring
      : enableMonitoring
    dataCollectionRuleResourceId: effectiveDataCollectionRuleResourceId
    dataCollectionEndpointResourceId: effectiveDataCollectionEndpointResourceId
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
    virtualMachineName: deploymentHelper.outputs.virtualMachineName
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

module cleanupDeploymentHelper '../shared/modules/orchestration/deploymentHelper/cleanup.bicep' = {
  params: {
    location: location
    resourceGroupDeployment: naming.outputs.resourceGroupDeployment
    resourceGroupHosts: naming.outputs.resourceGroupHosts
    userAssignedIdentityClientId: deploymentHelper.outputs.deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deploymentHelper.outputs.virtualMachineName
    roleAssignmentIds: deploymentHelper.outputs.deploymentUserAssignedIdentityRoleAssignmentIds
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
output workspaceFeedPrivateEndpointResourceId string = sharedAvdWorkspace.outputs.workspaceFeedPrivateEndpointResourceId
output globalFeedWorkspaceResourceId string = sharedAvdWorkspace.outputs.globalWorkspaceResourceId
output globalFeedPrivateEndpointResourceId string = sharedAvdWorkspace.outputs.globalFeedPrivateEndpointResourceId
