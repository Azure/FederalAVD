metadata name = 'AVD Session Host Replacer Add-On'
metadata description = 'Deploys automated session host lifecycle management for Azure Virtual Desktop'
metadata owner = 'FederalAVD'

// ========== //
// Parameters //
// ========== //

@description('Required. The resource ID of the AVD Host Pool to manage.')
param hostPoolResourceId string

@description('Required. The resource ID of the resource group where virtual machines are deployed.')
param virtualMachinesResourceGroupId string

@description('Optional. The resource ID of the Template Spec version for session host deployments.')
param sessionHostTemplateSpecVersionResourceId string

@description('Required. The resource ID of the User-Assigned Managed Identity with Microsoft Graph API permissions (Device.ReadWrite.All, DeviceManagementManagedDevices.ReadWrite.All).')
param sessionHostReplacerUserAssignedIdentityResourceId string

@description('Optional. The resource ID of an existing App Service Plan for the function app. If not provided, a new plan will be deployed.')
param appServicePlanResourceId string = ''

@description('Optional. Whether to deploy the App Service Plan with zone redundancy. Only applies if appServicePlanResourceId is not provided. Default is false.')
param zoneRedundant bool = false

@description('Optional. The maximum number of session hosts to replace per execution. Default is 1 for safety.')
@minValue(1)
@maxValue(20)
param maxSessionHostsToReplace int = 1

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

@description('Optional. Whether to include pre-existing session hosts in automation. Default is false.')
param includePreExistingSessionHosts bool = false

@description('Optional. Tag name to identify session hosts included in automation. Default is IncludeInAutoReplace.')
param tagIncludeInAutomation string = 'IncludeInAutoReplace'

@description('Optional. Tag name for deploy timestamp. Default is AutoReplaceDeployTimestamp.')
param tagDeployTimestamp string = 'AutoReplaceDeployTimestamp'

@description('Optional. Tag name for pending drain timestamp. Default is AutoReplacePendingDrainTimestamp.')
param tagPendingDrainTimestamp string = 'AutoReplacePendingDrainTimestamp'

@description('Optional. Tag name for scaling plan exclusion. Default is ScalingPlanExclusion.')
param tagScalingPlanExclusionTag string = 'ScalingPlanExclusion'

@description('Optional. Whether to remove Entra ID device records when deleting session hosts. Default is false.')
param removeEntraDevice bool = false

@description('Optional. Whether to remove Intune device records when deleting session hosts. Default is false.')
param removeIntuneDevice bool = false

@description('Optional. Timer schedule for the function app (cron expression). Default is every 6 hours.')
param timerSchedule string = '0 0 */6 * * *'

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

@description('Optional. The resource ID of the User-Assigned Managed Identity for encryption.')
param encryptionUserAssignedIdentityResourceId string

@description('Required. The URI of the Key Vault for encryption.')
param encryptionKeyVaultUri string

@description('Optional. Key management solution for storage accounts. Options: Platform, Customer.')
@allowed([
  'Platform'
  'Customer'
])
param keyManagementStorageAccounts string = 'Platform'

@description('Optional. Log Analytics Workspace resource ID for Application Insights.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Private Link Scope resource ID for Application Insights.')
param privateLinkScopeResourceId string = ''

@description('Optional. The location for all resources. Defaults to deployment location.')
param location string = resourceGroup().location

@description('Optional. Tags for all resources.')
param tags object = {}

@description('Required. The resource ID of the Key Vault containing session host credential secrets (VirtualMachineAdminPassword, VirtualMachineAdminUserName, DomainJoinUserPassword, DomainJoinUserPrincipalName).')
param credentialsKeyVaultResourceId string

// Session Host Parameters - passed from Template Spec deployment
@description('Optional. Session host deployment parameters. These are passed to the Template Spec during deployment.')
param sessionHostParameters object = {}

@description('Required. The VM name prefix used for session hosts.')
param virtualMachineNamePrefix string

// ========== //
// Variables  //
// ========== //

var deploymentSuffix = uniqueString(resourceGroup().id, deployment().name)
var hostPoolName = split(hostPoolResourceId, '/')[8]
var hostPoolResourceGroupName = split(hostPoolResourceId, '/')[4]
var virtualMachineResourceGroupLocation = reference(virtualMachinesResourceGroupId, '2021-04-01', 'Full').location
var virtualMachinesResourceGroupName = last(split(virtualMachinesResourceGroupId, '/'))

// Naming Convention Logic (derived from resourceNames.bicep)
var cloud = toLower(environment().name)
var locationsObject = loadJsonContent('../../../.common/data/locations.json')
var locationsEnvProperty = startsWith(cloud, 'us') ? 'other' : cloud
var locations = locationsObject[locationsEnvProperty]

var graphEndpoint = environment().name == 'AzureCloud' ? 'https://graph.microsoft.com' : environment().name == 'AzureUSGovernment' ? 'https://graph.microsoft.us' : startsWith(environment().name, 'us') ? 'https://graph.${environment().suffixes.storage}' : 'https//dod-graph.microsoft.us'

#disable-next-line BCP329
var varLocationVirtualMachines = startsWith(cloud, 'us')
  ? substring(virtualMachineResourceGroupLocation, 5, length(virtualMachineResourceGroupLocation) - 5)
  : virtualMachineResourceGroupLocation
var virtualMachinesRegionAbbreviation = locations[varLocationVirtualMachines].abbreviation

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
var uniqueStringHosts = take(uniqueString(subscription().subscriptionId, virtualMachinesResourceGroupName), 6)

// App Service Plan naming convention
var nameConv_Shared_Resources = nameConvReversed
  ? 'avd-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-TOKEN-${nameConvSuffix}'
var appServicePlanName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.appServicePlans),
    'LOCATION',
    virtualMachinesRegionAbbreviation
  ),
  'TOKEN-',
  ''
)

// Resource naming conventions for session host replacer
var appInsightsNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.applicationInsights),
  'LOCATION',
  virtualMachinesRegionAbbreviation
)
var functionAppNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.functionApps),
  'LOCATION',
  virtualMachinesRegionAbbreviation
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

// ========== //
// Deployments //
// ========== //

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
    encryptionKeyVaultUri: encryptionKeyVaultUri
    encryptionUserAssignedIdentityResourceId: encryptionUserAssignedIdentityResourceId
    functionAppAppSettings: [      
      {
        name: 'GraphEndpoint'
        value: graphEndpoint
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
        value: sessionHostTemplateSpecVersionResourceId
      }
      {
        name: 'SessionHostParameters'
        value: string(sessionHostParameters)
      }
      {
        name: 'MaxSessionHostsToReplace'
        value: string(maxSessionHostsToReplace)
      }
      {
        name: 'RemoveEntraDevice'
        value: string(removeEntraDevice)
      }
      {
        name: 'RemoveIntuneDevice'
        value: string(removeIntuneDevice)
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
    resourceGroupRoleAssignments: [
      {
        roleDefinitionId: '21090545-7ca7-4776-b22c-e363652d74d2' // Desktop Virtualization Virtual Machine Contributor
        scope: virtualMachinesResourceGroupName
      }
      {
        roleDefinitionId: '4a9ae827-6dc8-4573-8ac7-8239d42aa03f' // Tag Contributor
        scope: virtualMachinesResourceGroupName
      }
      {
        roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
        scope: hostPoolResourceGroupName
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
      'requirements.psd1': loadTextContent('functions/SessionHostReplacer/requirements.psd1')
      'run.ps1': loadTextContent('functions/SessionHostReplacer/run.ps1')
      '../profile.ps1': loadTextContent('functions/SessionHostReplacer/profile.ps1')
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
