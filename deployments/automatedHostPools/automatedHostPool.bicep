targetScope = 'subscription'

type entraGroupType = {
  id: string
  name: string
}

type sessionHostCustomizationType = {
  name: string
  blobNameOrUri: string
  arguments: string?
}

type scalingDayType = 'Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' | 'Friday' | 'Saturday' | 'Sunday'

type scalingTimeType = {
  hour: int
  minute: int
}

type dynamicScalingScheduleInputType = {
  name: string
  daysOfWeek: scalingDayType[]
  rampUpStartTime: string
  rampUpMinimumHostsPct: string
  rampUpCapacityThresholdPct: string
  rampUpMinimumHostPoolSize: string
  rampUpMaximumHostPoolSize: string
  peakStartTime: string
  rampDownStartTime: string
  rampDownMinimumHostsPct: string
  rampDownCapacityThresholdPct: string
  rampDownMinimumHostPoolSize: string
  rampDownMaximumHostPoolSize: string
  offPeakStartTime: string
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
  'EntraId'
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

@description('Optional. Number of session hosts provisioned by Session Host Management.')
@minValue(1)
param sessionHostCount int = 1

@description('Optional. Marketplace image publisher. Ignored when customImageResourceId is supplied.')
param imagePublisher string = 'MicrosoftWindowsDesktop'

@description('Optional. Marketplace image offer. Ignored when customImageResourceId is supplied.')
param imageOffer string = 'office-365'

@description('Optional. Marketplace image SKU. Ignored when customImageResourceId is supplied.')
param imageSku string = 'win11-25h2-avd-m365'

@description('Optional. Exact marketplace image version.')
param imageVersion string = 'latest'

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

@description('Optional. Named dynamic scaling schedules. Days may be grouped when they share a schedule.')
param dynamicScalingSchedules dynamicScalingScheduleInputType[] = [
  {
    name: 'Weekdays'
    daysOfWeek: [
      'Monday'
      'Tuesday'
      'Wednesday'
      'Thursday'
      'Friday'
    ]
    rampUpStartTime: '06:30'
    rampUpMinimumHostsPct: '20'
    rampUpCapacityThresholdPct: '60'
    rampUpMinimumHostPoolSize: '2'
    rampUpMaximumHostPoolSize: '10'
    peakStartTime: '08:30'
    rampDownStartTime: '17:00'
    rampDownMinimumHostsPct: '10'
    rampDownCapacityThresholdPct: '90'
    rampDownMinimumHostPoolSize: '1'
    rampDownMaximumHostPoolSize: '5'
    offPeakStartTime: '20:00'
  }
]

@description('Optional. Existing AVD workspace resource ID. When empty, a workspace is created.')
param existingWorkspaceResourceId string = ''

@description('Optional. Friendly name shown for a newly created workspace.')
param workspaceFriendlyName string = ''

@description('Optional. Friendly name shown for the desktop application group.')
param desktopFriendlyName string = ''

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

@description('Optional. Existing local Azure NetApp Files volume resource IDs used to configure FSLogix without deploying storage.')
param fslogixExistingLocalNetAppVolumeResourceIds string[] = []

@description('Optional. Existing remote Azure NetApp Files volume resource IDs used by FSLogix Cloud Cache.')
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

@description('Optional. IP addresses or CIDR blocks permitted through the Azure Files firewall.')
param fslogixPermittedIPs string[] = []

@description('Optional. Deploy a Disk Encryption Set and policy for session-host OS disks.')
param deployDiskEncryptionSet bool = false

@description('Optional. Existing Disk Encryption Set resource ID used by policy.')
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
param sessionHostCustomizations sessionHostCustomizationType[] = []

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

@description('Optional. Unique suffix for nested deployment names and temporary FSLogix resources.')
param deploymentSuffix string = utcNow('yyyyMMddHHmmss')

resource credentialsKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: last(split(credentialsKeyVaultResourceId, '/'))!
  scope: resourceGroup(split(credentialsKeyVaultResourceId, '/')[2], split(credentialsKeyVaultResourceId, '/')[4])
}

var commercialCloudIsValid = environment().name == 'AzureCloud'
  ? true
  : bool('Automated host pools are currently supported only in Azure Commercial.')
var credentialsKeyVaultConfigurationIsValid = credentialsKeyVault.properties.enableRbacAuthorization == true && credentialsKeyVault.properties.enabledForTemplateDeployment == true
  ? true
  : bool('The credentials Key Vault must use Azure RBAC and allow Azure Resource Manager template deployment.')
var domainJoinRequired = contains(identitySolution, 'DomainServices')
var credentialsKeyVaultSecretBaseUri = 'https://${last(split(credentialsKeyVaultResourceId, '/'))}.${environment().suffixes.keyvaultDns}/secrets'
var effectiveVmAdministratorUsernameSecretUri = !empty(vmAdministratorUsernameSecretUri) ? vmAdministratorUsernameSecretUri : '${credentialsKeyVaultSecretBaseUri}/VirtualMachineAdminUserName'
var effectiveVmAdministratorPasswordSecretUri = !empty(vmAdministratorPasswordSecretUri) ? vmAdministratorPasswordSecretUri : '${credentialsKeyVaultSecretBaseUri}/VirtualMachineAdminPassword'
var effectiveDomainJoinUsernameSecretUri = !empty(domainJoinUsernameSecretUri) ? domainJoinUsernameSecretUri : '${credentialsKeyVaultSecretBaseUri}/DomainJoinUserPrincipalName'
var effectiveDomainJoinPasswordSecretUri = !empty(domainJoinPasswordSecretUri) ? domainJoinPasswordSecretUri : '${credentialsKeyVaultSecretBaseUri}/DomainJoinUserPassword'
var domainConfigurationIsValid = !domainJoinRequired || !empty(domainName)
  ? true
  : bool('Domain-joined automated session hosts require domainName.')
var monitoringConfigurationIsValid = !enableMonitoring || !empty(dataCollectionRuleResourceId)
  ? true
  : bool('dataCollectionRuleResourceId is required when enableMonitoring is true.')
var avdServicePrincipalIsValid = !(deployDynamicScalingPlan || startVMOnConnect) || !empty(avdServicePrincipalObjectId)
  ? true
  : bool('avdServicePrincipalObjectId is required when dynamic scaling or Start VM on Connect is enabled.')

func parseScalingTime(value string) scalingTimeType => {
  hour: int(first(split(value, ':')))
  minute: int(last(split(value, ':')))
}

var effectiveDynamicScalingSchedules = map(dynamicScalingSchedules, schedule => {
      name: schedule.name
      daysOfWeek: schedule.daysOfWeek
      rampUpStartTime: parseScalingTime(schedule.rampUpStartTime)
      rampUpLoadBalancingAlgorithm: 'BreadthFirst'
      rampUpMinimumHostsPct: int(schedule.rampUpMinimumHostsPct)
      rampUpCapacityThresholdPct: int(schedule.rampUpCapacityThresholdPct)
      rampUpMinimumHostPoolSize: int(schedule.rampUpMinimumHostPoolSize)
      rampUpMaximumHostPoolSize: int(schedule.rampUpMaximumHostPoolSize)
      peakStartTime: parseScalingTime(schedule.peakStartTime)
      peakLoadBalancingAlgorithm: 'BreadthFirst'
      rampDownStartTime: parseScalingTime(schedule.rampDownStartTime)
      rampDownLoadBalancingAlgorithm: 'DepthFirst'
      rampDownMinimumHostsPct: int(schedule.rampDownMinimumHostsPct)
      rampDownCapacityThresholdPct: int(schedule.rampDownCapacityThresholdPct)
      rampDownMinimumHostPoolSize: int(schedule.rampDownMinimumHostPoolSize)
      rampDownMaximumHostPoolSize: int(schedule.rampDownMaximumHostPoolSize)
      rampDownForceLogoffUsers: false
      rampDownWaitTimeMinutes: 30
      rampDownNotificationMessage: 'Save your work and sign out. This session host is being removed by autoscale.'
      rampDownStopHostsWhen: 'ZeroSessions'
      offPeakStartTime: parseScalingTime(schedule.offPeakStartTime)
      offPeakLoadBalancingAlgorithm: 'DepthFirst'
    })
var invalidDynamicScalingLimits = filter(effectiveDynamicScalingSchedules, schedule => schedule.rampUpMinimumHostPoolSize > schedule.rampUpMaximumHostPoolSize || schedule.rampDownMinimumHostPoolSize > schedule.rampDownMaximumHostPoolSize)
var dynamicScalingLimitsAreValid = !deployDynamicScalingPlan || empty(invalidDynamicScalingLimits)
  ? true
  : bool('Dynamic scaling minimum host-pool sizes cannot exceed their corresponding maximum sizes.')
var dynamicScalingScheduleNames = map(effectiveDynamicScalingSchedules, schedule => toLower(schedule.name))
var dynamicScalingScheduleDays = flatten(map(effectiveDynamicScalingSchedules, schedule => schedule.daysOfWeek))
var dynamicScalingSchedulesAreValid = !deployDynamicScalingPlan || !empty(effectiveDynamicScalingSchedules) && length(dynamicScalingScheduleNames) == length(union(dynamicScalingScheduleNames, dynamicScalingScheduleNames)) && length(dynamicScalingScheduleDays) == length(union(dynamicScalingScheduleDays, dynamicScalingScheduleDays))
  ? true
  : bool('Dynamic scaling requires at least one schedule, unique schedule names, and each day assigned to no more than one schedule.')

module naming '../hostpools/modules/naming.bicep' = {
  params: {
    identifier: identifier
    virtualMachinesRegion: location
    controlPlaneRegion: controlPlaneLocation
    existingFeedWorkspaceResourceId: existingWorkspaceResourceId
    namingConvention: namingConvention
  }
}

module controlPlaneResourceGroup '../shared/modules/resources/resourceGroups/deploy.bicep' = if (empty(existingWorkspaceResourceId)) {
  params: {
    name: naming.outputs.resourceGroupControlPlane
    location: controlPlaneLocation
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module sessionHostResourceGroup '../shared/modules/resources/resourceGroups/deploy.bicep' = {
  params: {
    name: naming.outputs.resourceGroupHosts
    location: commercialCloudIsValid ? location : location
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
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
    appGroupSecurityGroupIds: appGroupSecurityGroupIds
    maxSessionLimit: hostPoolMaxSessionLimit
    loadBalancerType: loadBalancerType
    customRdpProperty: hostPoolRDPProperties
    validationEnvironment: hostPoolValidationEnvironment
    startVMOnConnect: startVMOnConnect
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    tags: tags
  }
  dependsOn: [controlPlaneResourceGroup]
}

module hostPoolPermissions 'modules/permissions.bicep' = {
  params: {
    hostPoolName: naming.outputs.hostPoolName
    controlPlaneResourceGroupName: naming.outputs.resourceGroupControlPlane
    sessionHostResourceGroupName: naming.outputs.resourceGroupHosts
    subnetResourceId: virtualMachineSubnetResourceId
    customImageResourceId: customImageResourceId
    credentialsKeyVaultResourceId: credentialsKeyVaultConfigurationIsValid ? credentialsKeyVaultResourceId : credentialsKeyVaultResourceId
    principalId: controlPlane.outputs.hostPoolPrincipalId
  }
  dependsOn: [sessionHostResourceGroup]
}

module sessionHostConfiguration 'modules/sessionHostConfiguration.bicep' = {
  params: {
    resourceGroupName: naming.outputs.resourceGroupControlPlane
    hostPoolName: naming.outputs.hostPoolName
    properties: {
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
              exactVersion: imageVersion
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
        { 'cm-resource-parent': controlPlane.outputs.hostPoolResourceId }
      )
    }
  }
  dependsOn: [hostPoolPermissions]
}

// The API requires instanceCount to be at least one. Omitting provisioning is its zero-host state.
module initialSessionHostManagement 'modules/sessionHostManagement.bicep' = {
  params: {
    resourceGroupName: naming.outputs.resourceGroupControlPlane
    hostPoolName: naming.outputs.hostPoolName
    properties: {
      failedSessionHostCleanupPolicy: failedSessionHostCleanupPolicy
      scheduledDateTimeZone: virtualMachinesTimeZone
      update: {
        deleteOriginalVm: deleteOriginalVm
        logOffDelayMinutes: updateLogOffDelayMinutes
        logOffMessage: updateLogOffMessage
        maxVmsRemoved: updateMaxVmsRemoved
      }
    }
  }
  dependsOn: [sessionHostConfiguration]
}

module fslogixStorage '../add-ons/fslogixStorage/main.bicep' = if (deployFSLogixStorage) {
  params: {
    location: location
    identifier: identifier
    namingConvention: namingConvention
    storageResourceGroupName: naming.outputs.resourceGroupStorage
    createStorageResourceGroup: true
    deploymentVirtualMachineSubnetResourceId: virtualMachineSubnetResourceId
    identitySolution: identitySolution
    credentialsKeyVaultResourceId: credentialsKeyVaultResourceId
    domainName: domainName
    organizationalUnitPath: empty(fslogixOUPath) ? organizationalUnitPath : fslogixOUPath
    appUpdateUserAssignedIdentityResourceId: fslogixAppUpdateUserAssignedIdentityResourceId
    fslogixStorageService: fslogixStorageService
    fslogixStorageRedundancy: fslogixStorageRedundancy
    fslogixContainerType: fslogixContainerType
    profileSizeInMBs: fslogixProfileSizeInMBs
    shareSizeInGB: fslogixShareSizeInGB
    fslogixShardOptions: fslogixShardOptions
    fslogixAdminGroups: fslogixAdminGroups
    fslogixUserGroups: fslogixUserGroups
    storageAccountNamePrefix: naming.outputs.fslogixStorageAccountNamePrefix
    storageIndex: fslogixStorageIndex
    softDeleteRetentionDays: fslogixSoftDeleteRetentionDays
    kerberosEncryptionType: fslogixStorageKerberosEncryptionType
    keyManagementStorage: fslogixKeyManagementStorage
    existingEncryptionKeyVaultResourceId: fslogixEncryptionKeyVaultResourceId
    keyExpirationInDays: fslogixKeyExpirationInDays
    netAppVolumesSubnetResourceId: netAppVolumesSubnetResourceId
    existingSharedActiveDirectoryConnection: existingSharedActiveDirectoryConnection
    remoteStorageAccountResourceIds: fslogixExistingRemoteStorageAccountResourceIds
    remoteNetAppServerFqdns: empty(fslogixExistingRemoteNetAppVolumeResourceIds) ? [] : existingNetAppVolumeFqdns!.outputs.remoteNetAppVolumeSmbServerFqdns
    privateEndpoint: fslogixPrivateEndpoint
    privateEndpointSubnetResourceId: fslogixPrivateEndpointSubnetResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    permittedIPs: fslogixPermittedIPs
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    parentResourceId: controlPlane.outputs.hostPoolResourceId
    tags: tags
    deploymentSuffix: deploymentSuffix
  }
}

var fslogixFileShareNames = contains(fslogixContainerType, 'OfficeContainer')
  ? ['profile-containers', 'office-containers']
  : ['profile-containers']

module existingNetAppVolumeFqdns '../hostpools/modules/hosts/modules/getNetAppVolumeSmbServerFqdns.bicep' = if (fslogixConfigureSessionHosts && ((!deployFSLogixStorage && !empty(fslogixExistingLocalNetAppVolumeResourceIds)) || !empty(fslogixExistingRemoteNetAppVolumeResourceIds))) {
  name: 'Resolve-FSLogix-NetApp-${deploymentSuffix}'
  params: {
    localNetAppVolumeResourceIds: fslogixExistingLocalNetAppVolumeResourceIds
    remoteNetAppVolumeResourceIds: fslogixExistingRemoteNetAppVolumeResourceIds
    shareNames: fslogixFileShareNames
  }
}

var existingFslogixConfiguration = {
  identitySolution: identitySolution
  storageService: split(fslogixStorageService, ' ')[0]
  containerType: fslogixContainerType
  fileShareNames: fslogixFileShareNames
  localStorageAccountResourceIds: fslogixExistingLocalStorageAccountResourceIds
  remoteStorageAccountResourceIds: fslogixExistingRemoteStorageAccountResourceIds
  localNetAppServerFqdns: empty(fslogixExistingLocalNetAppVolumeResourceIds) ? [] : existingNetAppVolumeFqdns!.outputs.localNetAppVolumeSmbServerFqdns
  remoteNetAppServerFqdns: empty(fslogixExistingRemoteNetAppVolumeResourceIds) ? [] : existingNetAppVolumeFqdns!.outputs.remoteNetAppVolumeSmbServerFqdns
  objectSpecificSettingsGroups: fslogixShardOptions == 'ShardOSS' ? map(fslogixUserGroups, group => group.name) : []
  profileSizeInMBs: fslogixProfileSizeInMBs
}

module sessionHostPolicy 'policy/main.bicep' = {
  params: {
    location: location
    sessionHostResourceGroupName: naming.outputs.resourceGroupHosts
    hostPoolResourceId: controlPlane.outputs.hostPoolResourceId
    policyResourceGroupName: '${naming.outputs.resourceGroupHosts}-policy'
    createPolicyResourceGroup: true
    deployDiskEncryptionSet: deployDiskEncryptionSet
    diskEncryptionSetResourceId: diskEncryptionSetResourceId
    encryptionKeyVaultResourceId: encryptionKeyVaultResourceId
    keyManagementDisks: keyManagementDisks
    disableManagedDiskPublicNetworkAccess: disableManagedDiskPublicNetworkAccess
    enableMonitoring: monitoringConfigurationIsValid ? enableMonitoring : enableMonitoring
    dataCollectionRuleResourceId: dataCollectionRuleResourceId
    dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
    integrityMonitoring: integrityMonitoring
    encryptionAtHost: encryptionAtHost
    diskSizeGB: diskSizeGB
    enableAcceleratedNetworking: enableAcceleratedNetworking
    virtualMachinesTimeZone: virtualMachinesTimeZone
    configureFSLogix: fslogixConfigureSessionHosts
    fslogixConfiguration: deployFSLogixStorage ? fslogixStorage!.outputs.fslogixConfiguration : existingFslogixConfiguration
    artifactsContainerUri: artifactsContainerUri
    artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
    sessionHostCustomizations: sessionHostCustomizations
    tags: tags
  }
  dependsOn: [initialSessionHostManagement]
}

module finalSessionHostManagement 'modules/sessionHostManagement.bicep' = {
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
    fslogixStorage
    sessionHostPolicy
  ]
}

module dynamicScalingPlan 'modules/dynamicScalingPlan.bicep' = if (deployDynamicScalingPlan) {
  params: {
    resourceGroupName: naming.outputs.resourceGroupControlPlane
    name: naming.outputs.scalingPlanName
    location: controlPlaneLocation
    tags: tags[?'Microsoft.DesktopVirtualization/scalingPlans'] ?? {}
    timeZone: avdServicePrincipalIsValid && dynamicScalingLimitsAreValid && dynamicScalingSchedulesAreValid ? scalingPlanTimeZone : scalingPlanTimeZone
    exclusionTag: scalingPlanExclusionTag
    hostPoolResourceId: controlPlane.outputs.hostPoolResourceId
    schedules: effectiveDynamicScalingSchedules
  }
  dependsOn: [
    finalSessionHostManagement
    avdServicePrincipalRbac
  ]
}

module avdServicePrincipalRbac 'modules/avdServicePrincipalRbac.bicep' = if (deployDynamicScalingPlan || startVMOnConnect) {
  params: {
    avdServicePrincipalObjectId: avdServicePrincipalIsValid ? avdServicePrincipalObjectId : avdServicePrincipalObjectId
    deployDynamicScalingPlan: deployDynamicScalingPlan
    startVMOnConnect: startVMOnConnect
  }
}

output hostPoolResourceId string = controlPlane.outputs.hostPoolResourceId
output workspaceResourceId string = controlPlane.outputs.workspaceResourceId
output applicationGroupResourceId string = controlPlane.outputs.applicationGroupResourceId
output sessionHostConfigurationResourceId string = sessionHostConfiguration.outputs.resourceId
output sessionHostManagementResourceId string = finalSessionHostManagement.outputs.resourceId
output sessionHostResourceGroupId string = sessionHostResourceGroup.outputs.resourceId
output fslogixStorageAccountResourceIds array = deployFSLogixStorage ? fslogixStorage!.outputs.storageAccountResourceIds : []
output policyIdentityResourceId string = sessionHostPolicy.outputs.policyIdentityResourceId
output scalingPlanResourceId string = deployDynamicScalingPlan ? dynamicScalingPlan!.outputs.resourceId : ''
