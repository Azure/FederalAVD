targetScope = 'subscription'

import { entraGroupType } from '../shared/modules/resourceModules/types/identityTypes.bicep'
import { namingPolicy, resourceName, hostPoolNames } from '../shared/modules/orchestration/naming/naming.bicep'

@maxLength(16)
@description('Required. Short name identifying the disposable PoC deployment.')
param identifier string

@secure()
@description('Required. Local administrator password for the PoC session hosts.')
param virtualMachineAdminPassword string

@secure()
@description('Required. Local administrator username for the PoC session hosts.')
param virtualMachineAdminUserName string

@description('Required. Microsoft Entra security groups assigned to the desktop application group and VM User Login role.')
param appGroupSecurityGroups entraGroupType[]

@minLength(1)
@maxLength(14)
@description('Required. Session-host virtual machine name prefix.')
param virtualMachineNamePrefix string

@description('Optional. Region-available Windows 11 multi-session Microsoft 365 marketplace image SKU.')
param imageSku string = 'win11-25h2-avd-m365'

@description('Optional. Region-available virtual machine SKU.')
param virtualMachineSize string = 'Standard_D4ads_v5'

@description('Optional. Deploys Azure Files storage and configures FSLogix profile containers. Two session hosts are deployed when enabled; otherwise one is deployed.')
param deployFSLogixStorage bool = true

@description('Optional. Deploys Log Analytics, an AVD Insights data collection rule, and a data collection endpoint.')
param enableMonitoring bool = false

@description('Optional. Address prefix for the standalone PoC virtual network.')
param virtualNetworkAddressPrefix string = '10.250.0.0/16'

@description('Optional. Address prefix for the private PoC session-host subnet.')
param sessionHostSubnetAddressPrefix string = '10.250.0.0/24'

@description('Optional. Key/value metadata applied to supported PoC resources.')
param tags object = {}

var location = deployment().location
var hpBaseName = toLower(identifier)
var sessionHostCount = deployFSLogixStorage ? 2 : 1
var fslogixFileShareNames = [
  'profile-containers'
]

var naming = hostPoolNames(namingPolicy.defaults, hpBaseName, {
  subscriptionId: subscription().subscriptionId
  cloud: environment().name
  virtualMachinesLocation: location
  controlPlaneLocation: location
  globalFeedLocation: ''
  existingFeedWorkspaceResourceId: ''
  sharedServicesSubscriptionId: subscription().subscriptionId
})

var resourceGroupName = naming.resourceGroupConsolidated
var virtualNetworkName = resourceName(namingPolicy.defaults, 'pocVirtualNetwork', naming.vmLocationAbbreviation, hpBaseName, '')
var sessionHostSubnetName = resourceName(namingPolicy.defaults, 'pocHostsSubnet', naming.vmLocationAbbreviation, hpBaseName, '')
var virtualNetworkResourceId = resourceId(
  subscription().subscriptionId,
  resourceGroupName,
  'Microsoft.Network/virtualNetworks',
  virtualNetworkName
)
var sessionHostSubnetResourceId = resourceId(
  subscription().subscriptionId,
  resourceGroupName,
  'Microsoft.Network/virtualNetworks/subnets',
  virtualNetworkName,
  sessionHostSubnetName
)
var hostPoolResourceId = resourceId(
  subscription().subscriptionId,
  resourceGroupName,
  'Microsoft.DesktopVirtualization/hostPools',
  naming.hostPoolName
)
var vmConfigurationTags = {
  vmIdentityType: 'EntraId'
  vmNamePrefix: virtualMachineNamePrefix
  vmIndexPadding: 3
  vmOSDiskType: 'Premium_LRS'
  vmDiskSizeGB: 0
  vmSize: virtualMachineSize
  vmAvailability: 'No infrastructure redundancy required'
  vmEncryptionAtHost: false
  vmAcceleratedNetworking: true
  vmIPv6: false
  vmHibernate: false
  vmSecurityType: 'TrustedLaunch'
  vmSecureBoot: true
  vmVirtualTPM: true
  vmIntegrityMonitoring: true
  vmSubnetId: sessionHostSubnetResourceId
  virtualMachineNameConv: naming.virtualMachineNameConv
  virtualMachineDiskNameConv: naming.virtualMachineDiskNameConv
  virtualMachineNicNameConv: naming.virtualMachineNicNameConv
  availabilitySetNameConv: naming.availabilitySetNameConv
  vmIntuneEnrollment: false
  vmImagePublisher: 'MicrosoftWindowsDesktop'
  vmImageOffer: 'office-365'
  vmImageSku: imageSku
}
var fslogixConfigurationTags = deployFSLogixStorage
  ? {
      fslContainerType: 'ProfileContainer'
      fslContainerSizeInMBs: 30000
      fslStorageService: 'AzureFiles'
      fslFileShareNames: string(fslogixFileShareNames)
      fslSharding: 'None'
      fslLocalStorageAccountNames: string([
        '${naming.fslogixStorageAccountNamePrefix}01'
      ])
    }
  : {}
var parentTag = {
  'cm-resource-parent': hostPoolResourceId
}

module resourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = {
  params: {
    location: location
    name: resourceGroupName
    tags: union(
      tags[?'Microsoft.Resources/resourceGroups'] ?? {},
      vmConfigurationTags,
      fslogixConfigurationTags,
      parentTag
    )
  }
}

module network '../networking/modules/vnet-sub-module.bicep' = {
  params: {
    deployVnetResourceGroup: false
    vnetName: virtualNetworkName
    vnetAddressPrefixes: [
      virtualNetworkAddressPrefix
    ]
    subnets: [
      {
        name: sessionHostSubnetName
        addressPrefix: sessionHostSubnetAddressPrefix
        purpose: 'hosts'
      }
    ]
    defaultRouting: 'nat'
    includeAvdBypassRoutes: false
    rdpShortpathManagedNetworks: false
    rdpShortpathPublicNetworks: false
    natGatewayName: resourceName(namingPolicy.defaults, 'pocNatGateway', naming.vmLocationAbbreviation, hpBaseName, '')
    publicIPName: resourceName(namingPolicy.defaults, 'pocPublicIP', naming.vmLocationAbbreviation, hpBaseName, '')
    routeTableName: ''
    nsgName: resourceName(namingPolicy.defaults, 'pocSecurityGroup', naming.vmLocationAbbreviation, hpBaseName, '')
    logAnalyticsWorkspaceResourceId: ''
    nvaIPAddress: ''
    customDNSServers: []
    deployDDoSNetworkProtection: false
    hubVnetName: ''
    hubVnetResourceGroup: ''
    hubVnetSubscriptionId: ''
    virtualNetworkGatewayOnHub: false
    vnetResourceGroupName: resourceGroupName
    location: location
    tags: tags
  }
  dependsOn: [
    resourceGroup
  ]
}

module monitoring '../shared/modules/orchestration/monitoring/monitoring.bicep' = if (enableMonitoring) {
  params: {
    azureMonitorPrivateLinkScopeResourceId: ''
    dataCollectionEndpointName: naming.sharedDataCollectionEndpointName
    location: location
    logAnalyticsWorkspaceName: naming.sharedLogAnalyticsWorkspaceName
    resourceGroupMonitoring: resourceGroupName
    tags: tags
  }
  dependsOn: [
    resourceGroup
  ]
}

var logAnalyticsWorkspaceResourceId = enableMonitoring
  ? monitoring!.outputs.logAnalyticsWorkspaceResourceId
  : ''
var avdInsightsDataCollectionRuleResourceId = enableMonitoring
  ? monitoring!.outputs.avdInsightsDataCollectionRuleResourceId
  : ''
var dataCollectionEndpointResourceId = enableMonitoring
  ? monitoring!.outputs.dataCollectionEndpointResourceId
  : ''

module workspace '../shared/modules/orchestration/avdWorkspace/avdWorkspace.bicep' = {
  params: {
    workspaceMode: 'Create'
    manageWorkspace: true
    workspaceName: naming.workspaceName
    workspaceResourceId: ''
    workspaceResourceGroupName: resourceGroupName
    createWorkspaceResourceGroup: false
    workspaceLocation: location
    workspaceFriendlyName: ''
    workspacePublicNetworkAccess: 'Enabled'
    workspaceFeedPrivateEndpointSubnetResourceId: ''
    avdPrivateDnsZoneResourceId: ''
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    manageGlobalWorkspace: false
    globalWorkspaceMode: 'Create'
    globalWorkspaceName: ''
    globalWorkspaceResourceId: ''
    globalWorkspaceResourceGroupName: ''
    globalFeedPrivateEndpointSubnetResourceId: ''
    globalFeedPrivateDnsZoneResourceId: ''
    privateEndpointNameConv: naming.privateEndpointNameConv
    privateEndpointNICNameConv: naming.privateEndpointNICNameConv
    tags: tags
  }
  dependsOn: [
    resourceGroup
  ]
}

module roleAssignmentVirtualMachineUserLogin '../hostpools/modules/rbac/vmUserLoginAssignments.bicep' = {
  params: {
    resourceGroupHosts: resourceGroupName
    appGroupSecurityGroups: map(appGroupSecurityGroups, group => group.id)
  }
  dependsOn: [
    resourceGroup
  ]
}

var hostPoolVmTemplate = {
  namePrefix: virtualMachineNamePrefix
  hibernate: false
  osDiskType: 'Premium_LRS'
  diskSizeGB: 0
  securityType: 'TrustedLaunch'
  secureBoot: true
  vTPM: true
  vmInfrastructureType: 'Cloud'
  virtualProcessorCount: null
  memoryGB: null
  minimumMemoryGB: null
  dynamicMemoryConfig: false
}

module controlPlane '../hostpools/modules/control-plane/controlPlane.bicep' = {
  params: {
    appGroupSecurityGroups: map(appGroupSecurityGroups, group => group.id)
    avdPrivateDnsZoneResourceId: ''
    avdPrivateLinkPrivateRoutes: 'None'
    controlPlaneRegion: location
    deployScalingPlan: false
    deploymentUserAssignedIdentityClientId: ''
    deploymentVirtualMachineName: ''
    desktopApplicationGroupName: naming.desktopApplicationGroupName
    desktopFriendlyName: ''
    enableMonitoring: enableMonitoring
    existingFeedWorkspaceResourceId: workspace.outputs.workspaceResourceId
    hostPoolCustomTags: union(
      {
        hostsResourceGroupId: subscriptionResourceId('Microsoft.Resources/resourceGroups', resourceGroupName)
        hpIdentifier: hpBaseName
        hpNamingConvention: string(union(namingPolicy.defaults, {
          vmsLocationAbbreviation: naming.vmLocationAbbreviation
        }))
      },
      deployFSLogixStorage
        ? {
            storageResourceGroupId: subscriptionResourceId(
              'Microsoft.Resources/resourceGroups',
              resourceGroupName
            )
          }
        : {}
    )
    hostPoolMaxSessionLimit: 4
    hostPoolName: naming.hostPoolName
    hostPoolPrivateEndpointSubnetResourceId: ''
    hostPoolPublicNetworkAccess: 'Enabled'
    hostPoolRDPProperties: 'enablerdsaadauth:i:1;'
    hostPoolType: 'Pooled DepthFirst'
    hostPoolValidationEnvironment: false
    hostPoolVmTemplate: hostPoolVmTemplate
    virtualMachinesRegion: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    privateEndpointNameConv: naming.privateEndpointNameConv
    privateEndpointNICNameConv: naming.privateEndpointNICNameConv
    resourceGroupControlPlane: resourceGroupName
    resourceGroupDeployment: ''
    scalingPlanName: naming.scalingPlanName
    scalingPlanPooledSchedules: []
    scalingPlanPersonalSchedules: []
    scalingPlanExclusionTag: ''
    startVMOnConnect: true
    tags: tags
    virtualMachinesTimeZone: 'Eastern Standard Time'
  }
  dependsOn: [
    resourceGroup
  ]
}

module fslogix '../shared/modules/orchestration/fslogix/fslogix.bicep' = if (deployFSLogixStorage) {
  params: {
    activeDirectoryConnection: false
    appUpdateUserAssignedIdentityResourceId: ''
    azureFilePrivateDnsZoneResourceId: ''
    deploymentUserAssignedIdentityClientId: ''
    deploymentVirtualMachineName: ''
    domainJoinUserPassword: ''
    domainJoinUserPrincipalName: ''
    domainName: ''
    encryptionKeyVaultUri: ''
    fslogixAdminGroups: []
    fslogixEncryptionKeyNameConv: naming.encryptionKeyNameFSLogix
    fslogixFileShares: fslogixFileShareNames
    fslogixShardOptions: 'None'
    fslogixUserGroups: []
    hostPoolResourceId: controlPlane.outputs.hostPoolResourceId
    identitySolution: 'EntraId'
    kerberosEncryptionType: 'AES256'
    keyManagementStorageAccounts: 'PlatformManaged'
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    netAppVolumesSubnetResourceId: ''
    netAppAccountName: naming.netAppAccountName
    netAppCapacityPoolName: naming.netAppCapacityPoolName
    ouPath: ''
    privateEndpoint: false
    privateEndpointNameConv: naming.privateEndpointNameConv
    privateEndpointNICNameConv: naming.privateEndpointNICNameConv
    privateEndpointSubnetResourceId: ''
    resourceGroupDeployment: ''
    resourceGroupStorage: resourceGroupName
    shareSizeInGB: 100
    smbServerLocation: naming.vmsLocAbbr
    storageAccountNamePrefix: naming.fslogixStorageAccountNamePrefix
    storageCount: 1
    storageIndex: 1
    storageSku: 'Standard'
    fslogixStorageRedundancy: 'LocallyRedundant'
    storageSolution: 'AzureFiles'
    permittedIPs: []
    tags: tags
    encryptionUserAssignedIdentityResourceId: ''
    fslogixSoftDeleteRetentionDays: 14
    recoveryServicesVaultResourceId: ''
    fileSharePolicyName: ''
  }
  dependsOn: [
    resourceGroup
  ]
}

module sessionHosts '../hostpools/modules/hosts/hosts.bicep' = {
  params: {
    resourceGroupHosts: resourceGroupName
    agentBootLoaderDownloadUrl: ''
    agentDownloadUrl: ''
    artifactsContainerUri: ''
    artifactsUserAssignedIdentityResourceId: ''
    avdInsightsDataCollectionRulesResourceId: avdInsightsDataCollectionRuleResourceId
    availability: 'None'
    availabilitySetNameConv: naming.availabilitySetNameConv
    availabilitySetsCount: 1
    availabilitySetsIndex: 0
    availabilityZones: []
    confidentialVMOSDiskEncryption: false
    customImageResourceId: ''
    customImageLicenseType: 'Windows_Client'
    dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
    dedicatedHostGroupResourceId: ''
    dedicatedHostResourceId: ''
    diskAccessId: ''
    diskSizeGB: 0
    diskSku: 'Premium_LRS'
    domainJoinUserPassword: ''
    domainJoinUserPrincipalName: ''
    domainName: ''
    enableAcceleratedNetworking: true
    enableIPv6: false
    enableMonitoring: enableMonitoring
    encryptionAtHost: false
    diskEncryptionSetResourceId: ''
    fslogixConfigureSessionHosts: deployFSLogixStorage
    fslogixContainerType: 'ProfileContainer'
    fslogixFileShareNames: fslogixFileShareNames
    fslogixLocalStorageAccountResourceIds: deployFSLogixStorage
      ? fslogix!.outputs.storageAccountResourceIds
      : []
    fslogixLocalNetAppVolumeResourceIds: []
    fslogixOSSGroups: []
    fslogixRemoteNetAppVolumeResourceIds: []
    fslogixRemoteStorageAccountResourceIds: []
    fslogixSizeInMBs: 30000
    fslogixStorageService: 'AzureFiles'
    hibernationEnabled: false
    hostPoolResourceId: controlPlane.outputs.hostPoolResourceId
    identitySolution: 'EntraId'
    imageOffer: 'office-365'
    imagePublisher: 'MicrosoftWindowsDesktop'
    imageSku: imageSku
    integrityMonitoring: true
    intuneEnrollment: false
    location: location
    virtualMachineDiskNameConv: naming.virtualMachineDiskNameConv
    ouPath: ''
    virtualMachineNicNameConv: naming.virtualMachineNicNameConv
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    sessionHostCount: sessionHostCount
    sessionHostCustomizations: []
    sessionHostIndex: 1
    vmNameIndexLength: 3
    subnetResourceId: sessionHostSubnetResourceId
    tags: tags
    timeZone: 'Eastern Standard Time'
    virtualMachineAdminPassword: virtualMachineAdminPassword
    virtualMachineAdminUserName: virtualMachineAdminUserName
    virtualMachineNameConv: naming.virtualMachineNameConv
    virtualMachineNamePrefix: virtualMachineNamePrefix
    virtualMachineSize: virtualMachineSize
    vTpmEnabled: true
    deployRecoveryServices: false
    createVault: false
    existingVmBackupVaultResourceId: ''
    vaultName: ''
    vaultStorageRedundancy: 'LocallyRedundant'
    backupRetentionDays: 30
    keyManagementType: 'PlatformManaged'
    encryptionKeyVaultResourceId: ''
    encryptionKeyVaultUri: ''
    encryptionKeyName: ''
    deployPrivateEndpoints: false
    vaultPrivateEndpointSubnetResourceId: ''
    azureBackupPrivateDnsZoneResourceId: ''
    azureBlobPrivateDnsZoneResourceId: ''
    azureQueuePrivateDnsZoneResourceId: ''
    privateEndpointNameConv: naming.privateEndpointNameConv
    privateEndpointNICNameConv: naming.privateEndpointNICNameConv
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
  }
  dependsOn: [
    resourceGroup
    network
    roleAssignmentVirtualMachineUserLogin
  ]
}

output hostPoolResourceId string = controlPlane.outputs.hostPoolResourceId
output workspaceResourceId string = workspace.outputs.workspaceResourceId
output logAnalyticsWorkspaceResourceId string = logAnalyticsWorkspaceResourceId
output avdInsightsDataCollectionRuleResourceId string = avdInsightsDataCollectionRuleResourceId
output dataCollectionEndpointResourceId string = dataCollectionEndpointResourceId
output fslogixLocalStorageAccountResourceIds array = deployFSLogixStorage
  ? fslogix!.outputs.storageAccountResourceIds
  : []
output hostResourceGroupId string = subscriptionResourceId('Microsoft.Resources/resourceGroups', resourceGroupName)
output virtualMachineNames array = sessionHosts.outputs.virtualMachineNames
output virtualNetworkResourceId string = virtualNetworkResourceId
output sessionHostSubnetResourceId string = sessionHostSubnetResourceId
