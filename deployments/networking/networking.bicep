targetScope = 'subscription'

@description('The region to deploy the network resources to.')
param location string = deployment().location

@description('Determines whether or not to deploy the virtual network.')
param deployVnet bool = false

@description('Determines whether or not to deploy the resource group for the virtual network.')
param deployVnetResourceGroup bool = false

@description('Conditional. The name of the resource group to deploy the virtual network to. Required when "deployVnet" is "true".')
param vnetResourceGroupName string = ''

@description('Conditional. The name of the virtual network. Required when "deployVnet" is "true".')
param vnetName string = ''

@description('Conditional. The address prefixes for the virtual network. Required when "deployVnet" is "true".')
param vnetAddressPrefixes array = []

@description('Conditional. The hosts subnet to create within the virtual network. Required when "deployVnet" is "true".')
param hostsSubnet object = {}

@description('Optional. The private endpoint subnet to create within the virtual network.')
param privateEndpointsSubnet object = {}

@description('Optional. The function app subnet to create within the virtual network.')
param functionAppSubnet object = {}

@description('Optional. The type of default routing used on the subnets.')
@allowed([
  'default'
  'nva'
  'nat'
])
param defaultRouting string = 'default'

@description('Optional. Determines if the resources should be named with the resource type at the end.')
param nameConvResTypeAtEnd bool = false

@description('Conditional. The IP Address the network virtual appliance. Required when "defaultRouting" is "nva".')
param nvaIPAddress string = ''

@description('Optional. The custom DNS servers to use for the virtual network.')
param customDNSServers array = []

@description('Optional. Determines if DDoS network protection should be deployed.')
param deployDDoSNetworkProtection bool = false

@description('Optional. The resource id of the hub virtual network to which the virtual network should be peered.')
param hubVnetResourceId string = ''

@description('Optional. Determines if a virtual network gateway is present on the hub virtual network.')
param virtualNetworkGatewayOnHub bool = false

@description('Optional. The subscription id of the subscription to where the private DNS zones should be deployed.')
param privateDNSZonesSubscriptionId string = subscription().subscriptionId

@description('Optional. Determines if the private DNS zones resource group should be deployed.')
param deployPrivateDNSZonesResourceGroup bool = false

@description('Conditional. The name of the private DNS zones resource group. Required when any of the private DNS Zones are deployed based on the "createZone" parameters.')
param privateDNSZonesResourceGroupName string = ''

@description('Optional. Determines if the Azure Backup private DNS zone should be created.')
param createAzureBackupZone bool = false

@description('Optional. The Resource Id of the existing Azure Backup Private DNS Zone.')
param azureBackupZoneId string = ''

@description('Optional. Determines if the Azure Blob Storage private DNS zone should be created.')
param createAzureBlobZone bool = false

@description('Optional. The Resource Id of the existing Azure Blob Storage Private DNS Zone.')
param azureBlobZoneId string = ''

@description('Optional. Determines if the Azure Files Storage private DNS zone should be created.')
param createAzureFilesZone bool = false

@description('Optional. The Resource Id of the existing Azure Files Storage Private DNS Zone.')
param azureFilesZoneId string = ''

@description('Optional. Determines if the Azure Queue Storage private DNS zone should be created.')
param createAzureQueueZone bool = false

@description('Optional. The Resource Id of the existing Azure Queue Storage Private DNS Zone.')
param azureQueueZoneId string = ''

@description('Optional. Determines if the Azure Table Storage private DNS zone should be created.')
param createAzureTableZone bool = false

@description('Optional. The Resource Id of the existing Azure Table Storage Private DNS Zone.')
param azureTableZoneId string = ''

@description('Optional. Determines if the Azure Key Vault private DNS zone should be created.')
param createAzureKeyVaultZone bool = false

@description('Optional. The Resource Id of the existing Azure Key Vault Private DNS Zone.')
param azureKeyVaultZoneId string = ''

@description('Optional. Determines if the AVD feed private DNS zone should be created.')
param createAvdFeedZone bool = false

@description('Optional. The Resource Id of the existing AVD Feed Private DNS Zone.')
param avdFeedZoneId string = ''

@description('Optional. Determines if the AVD global feed private DNS zone should be created.')
param createAvdGlobalFeedZone bool = false

@description('Optional. The Resource Id of the existing AVD Global Feed Private DNS Zone.')
param avdGlobalFeedZoneId string = ''

@description('Optional. Determines if the Azure Web App private DNS zone should be created.')
param createAzureWebAppZone bool = false

@description('Optional. The Resource Id of the existing Azure Web App Private DNS Zone.')
param azureWebAppZoneId string = ''

@description('Optional. Determines if the private DNS zones should be linked to a new virtual network.')
param linkPrivateDnsZonesToNewVnet bool = false

@description('Conditional. The resource id of the virtual network to link the private DNS zones to. Required when "linkPrivateDnsZonesToNewVnet" is "false" and any of the private DNS Zones are deployed or resource Ids provided.')
param privateDnsZonesVnetId string = ''

@description('Optional. The tags by resource type to apply to the resources.')
param tags object = {}

// Non Specified Values
@description('DO NOT MODIFY THIS VALUE! The timeStamp is needed to differentiate deployments for certain Azure resources and must be set using a parameter.')
param timeStamp string = utcNow('yyyyMMddhhmmss')

var createPrivateDNSZones = createAzureBackupZone || createAzureBlobZone || createAzureFilesZone || createAzureQueueZone || createAzureTableZone || createAzureKeyVaultZone || createAvdFeedZone || createAvdGlobalFeedZone || createAzureWebAppZone
var locations = (loadJsonContent('../../.common/data/locations.json'))[environment().name]
var resourceAbbreviations = loadJsonContent('../../.common/data/resourceAbbreviations.json')
var nameConvSuffix = nameConvResTypeAtEnd ? 'LOCATION-RESOURCETYPE' : 'LOCATION'

var nameConv_Shared_Resources = nameConvResTypeAtEnd
  ? 'avd-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-TOKEN-${nameConvSuffix}'
var natGatewayName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.natGateways),
    'LOCATION',
    locations[location].abbreviation
  ),
  'TOKEN-',
  ''
)
var publicIPName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.publicIPAddresses),
    'LOCATION',
    locations[location].abbreviation
  ),
  'TOKEN-',
  ''
)
var routeTableName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.routeTables),
    'LOCATION',
    locations[location].abbreviation
  ),
  'TOKEN-',
  ''
)

var cloudSuffix = replace(
  replace(
    replace(
      environment().resourceManager,
      'https://management.azure.',
      ''
    ),
    'https://management.',
    ''
  ),
  '/',
  ''
)

var privateDnsZones_AzureVirtualDesktop = {
  AzureCloud: 'privatelink.wvd.microsoft.com'
  AzureUSGovernment: 'privatelink.wvd.azure.us'
  USNat: 'privatelink.wvd.${cloudSuffix}'
  USSec: 'privatelink.wvd.${cloudSuffix}'
}

var privateDnsZones_AzureVirtualDesktopGlobalFeed = {
  AzureCloud: 'privatelink-global.wvd.microsoft.com'
  AzureUSGovernment: 'privatelink-global.wvd.azure.us'
  USNat: 'privatelink.wvd.${cloudSuffix}'
  USSec: 'privatelink.wvd.${cloudSuffix}'
}

var privateDnsZoneSuffixes_AzureWebApps = {
  AzureCloud: 'net'
  AzureUSGovernment: 'us'
  USNat: cloudSuffix
  USSec: cloudSuffix
}

var privateDnsZoneSuffixes_Backup = {
  AzureCloud: 'com'
  AzureUSGovernment: 'us'
  USNat: cloudSuffix
  USSec: cloudSuffix
}
/*
var privateDnsZoneSuffixes_AzureAutomation = {
  AzureCloud: 'net'
  AzureUSGovernment: 'us'
  USNat: cloudSuffix
  USSec: cloudSuffix
}

var privateDnsZoneSuffixes_Monitor = {
  AzureCloud: 'com'
  AzureUSGovernment: 'us'
  USNat: cloudSuffix
  USSec: cloudSuffix
}
*/
var backupPrivateDnsZone = createAzureBackupZone ? 'privatelink.${locations[location].recoveryServicesGeo}.backup.windowsazure.${privateDnsZoneSuffixes_Backup[environment().name]}' : ''
var blobPrivateDnsZone = createAzureBlobZone ? 'privatelink.blob.${environment().suffixes.storage}' : ''
var filesPrivateDnsZone = createAzureFilesZone ? 'privatelink.file.${environment().suffixes.storage}' : ''
var queuePrivateDnsZone = createAzureQueueZone ? 'privatelink.queue.${environment().suffixes.storage}' : ''
var tablePrivateDnsZone = createAzureTableZone ? 'privatelink.table.${environment().suffixes.storage}' : ''
var keyVaultPrivateDnsZone = createAzureKeyVaultZone ? 'privatelink${replace(environment().suffixes.keyvaultDns, 'vault', 'vaultcore')}' : ''
var avdFeedPrivateDnsZone = createAvdFeedZone ? privateDnsZones_AzureVirtualDesktop[environment().name] : ''
var avdGlobalFeedPrivateDnsZone = createAvdGlobalFeedZone ? privateDnsZones_AzureVirtualDesktopGlobalFeed[environment().name] : ''
var webAppPrivateDnsZone = createAzureWebAppZone ? 'privatelink.azurewebsites.${privateDnsZoneSuffixes_AzureWebApps[environment().name]}' : ''

var privateDnsZones = [
  backupPrivateDnsZone
  blobPrivateDnsZone
  filesPrivateDnsZone
  queuePrivateDnsZone
  tablePrivateDnsZone
  keyVaultPrivateDnsZone
  avdFeedPrivateDnsZone
  avdGlobalFeedPrivateDnsZone
  webAppPrivateDnsZone
]

var existingPrivateDnsZones = [
  azureBackupZoneId
  azureBlobZoneId
  azureFilesZoneId
  azureQueueZoneId
  azureTableZoneId
  azureKeyVaultZoneId
  avdFeedZoneId
  avdGlobalFeedZoneId
  azureWebAppZoneId
]

module vnetResources 'modules/vnet-sub-module.bicep' = if (deployVnet) {
  name: 'Network-Resources-${timeStamp}'
  params: {
    customDNSServers: customDNSServers
    deployVnetResourceGroup: deployVnetResourceGroup
    defaultRouting: defaultRouting
    deployDDoSNetworkProtection: deployDDoSNetworkProtection
    functionAppSubnet: functionAppSubnet
    hostsSubnet: hostsSubnet
    hubVnetName: !empty(hubVnetResourceId) ? last(split(hubVnetResourceId, '/')) : ''
    hubVnetResourceGroup: !empty(hubVnetResourceId) ? split(hubVnetResourceId, '/')[4] : ''
    hubVnetSubscriptionId: !empty(hubVnetResourceId) ? split(hubVnetResourceId, '/')[2] : ''
    location: location
    natGatewayName: natGatewayName
    nvaIPAddress: !empty(nvaIPAddress) ? nvaIPAddress : ''
    privateEndpointsSubnet: !empty(privateEndpointsSubnet) ? privateEndpointsSubnet : {}
    publicIPName: publicIPName
    routeTableName: routeTableName
    tags: tags
    timeStamp: timeStamp
    virtualNetworkGatewayOnHub: virtualNetworkGatewayOnHub
    vnetAddressPrefixes: vnetAddressPrefixes
    vnetName: vnetName
    vnetResourceGroupName: vnetResourceGroupName
  }
}

module privateDNSZonesResources 'modules/privateDNS-sub-module.bicep' = if (createPrivateDNSZones || linkPrivateDnsZonesToNewVnet || !empty(privateDnsZonesVnetId)) {
  name: 'Private-DNS-Zones-Resources-${timeStamp}'
  scope: subscription(privateDNSZonesSubscriptionId)
  params: {
    createPrivateDNSZones: createPrivateDNSZones
    deployPrivateDNSZonesResourceGroup: deployPrivateDNSZonesResourceGroup
    existingPrivateDnsZoneIds: filter(existingPrivateDnsZones, (zone) => !empty(zone))
    location: location
    privateDNSZonesResourceGroupName: privateDNSZonesResourceGroupName
    privateDnsZonesToCreate: filter(privateDnsZones, (zone) => !empty(zone))
    privateDnsZonesVnetId: !empty(privateDnsZonesVnetId)
      ? privateDnsZonesVnetId
      : (linkPrivateDnsZonesToNewVnet ? vnetResources.outputs.vNetResourceId : '')
    tags: tags
    timeStamp: timeStamp
  }
}
