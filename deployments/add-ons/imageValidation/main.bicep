targetScope = 'subscription'

metadata name = 'Image Validation Add-On'
metadata description = 'The Image Validation add-on deploys an Azure Function App and supporting infrastructure to deploy and ensure the validation virtual machine is always using the latest image. This enables the security team to scan and validate your image before its release.'

import { artifactCustomizationType } from '../../shared/modules/resourceModules/types/customizationTypes.bicep'

@description('Required. Complete name for the Application Insights resource.')
@minLength(1)
@maxLength(260)
param applicationInsightsName string

@description('Optional. The name for a new App Service plan. Ignored when using an existing plan ID.')
@maxLength(40)
param appServicePlanName string = ''

@description('Optional. The SKU for a new App Service plan. Ignored when using an existing plan ID.')
@allowed([
  'P0v3'
  'P1v3'
  'P2v3'
  'P3v3'
])
param appServicePlanSku string = 'P0v3'

@description('Optional. Existing same-region Windows Dedicated App Service plan ID. Empty creates a dedicated PremiumV3_P0v3 plan.')
param appServicePlanResourceId string = ''

@description('Optional. URI of the storage container containing the customization artifacts.')
param artifactsContainerUri string = ''

@description('Optional. Resource ID of the user-assigned identity used to access the customization artifacts.')
param artifactsUserAssignedIdentityResourceId string = ''

@description('Required for private mode. Existing target-cloud blob private DNS zone ID, linked to the integration VNet.')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Required for private mode. Existing target-cloud Function App private DNS zone ID, linked to the integration VNet.')
param azureFunctionAppPrivateDnsZoneResourceId string = ''

@description('Required for private mode. Existing target-cloud Key Vault private DNS zone ID, linked to the integration VNet.')
param azureKeyVaultPrivateDnsZoneResourceId string = ''

@description('Optional. Enable boot diagnostics for the validation VM.')
param bootDiagnostics bool = true

@description('Optional. Existing disk access resource ID for the validation VM.')
param diskAccessResourceId string = ''

@description('Optional. Disk controller type for the validation VM.')
@allowed([
  'SCSI'
  'NVMe'
])
param diskControllerType string = 'SCSI'

@description('Optional. Existing disk encryption set resource ID for the validation VM.')
param diskEncryptionSetResourceId string = ''

@description('Required. Complete name for the validation VM disk.')
@minLength(1)
@maxLength(80)
param diskName string

@description('Optional. Enable accelerated networking for the validation VM network interface.')
param acceleratedNetworking bool = true

@description('Optional. Enable encryption at host for the validation VM.')
param encryptionAtHost bool = true

@description('Required for private mode. Existing Microsoft.Web/serverFarms-delegated integration subnet in the app region, separate from the endpoint subnet.')
param functionAppDelegatedSubnetResourceId string = ''

@description('Required. Complete Function App name.')
@minLength(2)
@maxLength(60)
param functionAppName string

@description('Required. License type for the image.')
@allowed([
  'Windows_Client'
  'Windows_Server'
])
param imageLicenseType string = 'Windows_Client'

@description('Required. Existing image version resource ID under imageDefinitionResourceId for the validation VM.')
@minLength(1)
param imageVersionResourceId string

@description('Optional. Enable hardware integrity monitoring for the validation VM.')
param integrityMonitoring bool = true

@description('Required. Complete name for the credentials Key Vault.')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Required. Existing credentials Key Vault ID containing LocalAdminUsername and LocalAdminPassword secrets. Enable template deployment and authorize the deployment principal.')
@minLength(1)
param keyVaultResourceId string

@description('Optional. Azure region for the resource group and Function infrastructure.')
param location string = deployment().location

@description('Optional. Existing workspace ID. Nonempty enables Application Insights and FunctionAppLogs diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Required. Complete name for the validation VM network interface.')
@minLength(1)
@maxLength(80)
param networkInterfaceName string

@description('Optional. Create private endpoints and disable public app/storage access. Requires existing subnets and private DNS zones.')
param privateEndpoint bool = true

@description('Required for private mode. Existing subnet for app and blob private endpoints.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. Existing Azure Monitor Private Link Scope ID. Without it, enabled Insights uses public ingestion and query endpoints.')
param privateLinkScopeResourceId string = ''

@description('Required. Available static IPv4 address in the validation VM subnet.')
@minLength(1)
param privateIPAddress string

@description('Required. Complete resource group name. The deployment manages this group.')
@minLength(1)
@maxLength(90)
param resourceGroupName string

@description('Required. Timer schedule in six-field Functions NCRONTAB format or a supported app-setting reference.')
@minLength(1)
param schedule string

@description('Optional. Enable secure boot for the validation VM.')
param secureBoot bool = true

@description('Optional. Security type for the validation VM.')
@allowed([
  'TrustedLaunch'
  'ConfidentialVM'
  'Standard'
])
param securityType string = 'TrustedLaunch'

@description('Required. Complete runtime storage name, also useful when generated storage names exceed 24 characters.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Required. Existing subnet resource ID for the validation VM, separate from Function App integration networking.')
@minLength(1)
param subnetResourceId string

@description('Optional. Tags applied to all resources that support tags.')
param tags object = {}

@description('Required. Complete name for the template spec.')
@minLength(1)
@maxLength(90)
param templateSpecName string

@description('Required. Complete name for the Function App identity.')
@minLength(3)
@maxLength(128)
param userAssignedIdentityName string

@description('Optional. Customizations applied to the validation VM.')
param virtualMachineCustomizations artifactCustomizationType[] = []

@description('Required. The name for the validation VM.')
@minLength(1)
@maxLength(15)
param virtualMachineName string

@description('Required. The size of the virtual machine supported by the selected image and region.')
param virtualMachineSize string

@description('Optional. Enable vTPM for the validation VM.')
param vTpm bool = true

var integrationSubnetId = privateEndpoint && empty(trim(functionAppDelegatedSubnetResourceId))
  ? fail('Private mode requires functionAppDelegatedSubnetResourceId.')
  : functionAppDelegatedSubnetResourceId
var endpointSubnetId = privateEndpoint && empty(trim(privateEndpointSubnetResourceId))
  ? fail('Private mode requires privateEndpointSubnetResourceId.')
  : privateEndpointSubnetResourceId
var blobDnsZoneId = privateEndpoint && empty(trim(azureBlobPrivateDnsZoneResourceId))
  ? fail('Private mode requires azureBlobPrivateDnsZoneResourceId.')
  : azureBlobPrivateDnsZoneResourceId
var appDnsZoneId = privateEndpoint && empty(trim(azureFunctionAppPrivateDnsZoneResourceId))
  ? fail('Private mode requires azureFunctionAppPrivateDnsZoneResourceId.')
  : azureFunctionAppPrivateDnsZoneResourceId
var vaultDnsZoneId = privateEndpoint && empty(trim(azureKeyVaultPrivateDnsZoneResourceId))
  ? fail('Private mode requires azureKeyVaultPrivateDnsZoneResourceId.')
  : azureKeyVaultPrivateDnsZoneResourceId

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
}

module networkInterface '../../shared/modules/resourceModules/network/networkInterfaces/deploy.bicep' = {
  scope: rg
  params: {
    enableAcceleratedNetworking: acceleratedNetworking
    location: location
    name: networkInterfaceName
    subnetResourceId: subnetResourceId
    privateIPAddress: privateIPAddress
    privateIPAllocationMethod: 'Static'
    tags: tags[?'Microsoft.Network/networkInterfaces'] ?? {}
  }
}

module userAssignedIdentity '../../shared/modules/resourceModules/managedIdentity/userAssignedIdentities/deploy.bicep' = {
  scope: rg
  params: {
    location: location
    name: userAssignedIdentityName
    tags: tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {}
  }
  dependsOn: [
    networkInterface
  ]
}

module templateSpec '../../shared/modules/resourceModules/resources/templateSpecs/deploy.bicep' = {
  scope: rg
  params: {
    description: 'Deploys a virtual machine to validate a new image version.'
    displayName: 'Image Validation for ${split(imageVersionResourceId, '/')[10]}'
    location: location
    mainTemplate: loadJsonContent('modules/validationVirtualMachine.json')
    name: templateSpecName
    tags: tags[?'Microsoft.Resources/templateSpecs'] ?? {}
  }
  dependsOn: [
    networkInterface
  ]
}

module keyVault '../../shared/modules/orchestration/keyVaults/keyVaults.bicep' = {
  params: {
    resourceGroupName: rg.name
    deploySecretsKeyVault: false
    secretsKeyVaultName: ''
    deployEncryptionKeyVault: true
    encryptionKeyVaultName: '${keyVaultName}-enc'
    azureKeyVaultPrivateDnsZoneResourceId: vaultDnsZoneId
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    privateEndpoint: privateEndpoint
    privateEndpointSubnetResourceId: endpointSubnetId
    privateEndpointNameConv: 'pe-${keyVaultName}'
    privateEndpointNICNameConv: 'nic-pe-${keyVaultName}'
    paasPublicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    tags: tags
  }
  dependsOn: [
    networkInterface
  ]
}

module keys '../../shared/modules/orchestration/customerManagedKeys/customerManagedKeys.bicep' = {
  scope: rg
  params: {
    keyVaultResourceId: keyVault.outputs.encryptionKeyVaultResourceId
    keyManagementType: 'CustomerManagedHSM'
    keyNames: [storageAccountName]
    identityName: '${userAssignedIdentityName}-enc'
    location: location
    tags: tags
  }
  dependsOn: [
    networkInterface
  ]
}

module serverFarm '../../shared/modules/resourceModules/functionApp/functionAppHostingPlan.bicep' = if (empty(appServicePlanResourceId)) {
  scope: rg
  params: {
    functionAppKind: 'functionapp'
    hostingPlanType: 'Dedicated'
    location: location
    name: appServicePlanName
    planPricing: 'PremiumV3_${appServicePlanSku}'
    tags: tags
    zoneRedundant: false
  }
  dependsOn: [
    networkInterface
  ]
}

module functionApp '../../shared/modules/resourceModules/functionApp/functionApp.bicep' = {
  scope: rg
  params: {
    applicationInsightsName: applicationInsightsName
    azureBlobPrivateDnsZoneResourceId: blobDnsZoneId
    azureFunctionAppPrivateDnsZoneResourceId: appDnsZoneId
    enableApplicationInsights: !empty(logAnalyticsWorkspaceResourceId)
    enableQueueStorage: false
    enableTableStorage: false
    encryptionKeyName: storageAccountName
    encryptionKeyVaultResourceId: keyVault.outputs.encryptionKeyVaultResourceId
    functionAppAppSettings: concat([
      {
        name: 'artifactsContainerUri'
        value: artifactsContainerUri
      }
      {
        name: 'artifactsUserAssignedIdentityResourceId'
        value: artifactsUserAssignedIdentityResourceId
      }
      {
        name: 'bootDiagnostics'
        value: string(bootDiagnostics)
      }
      {
        name: 'diskAccessResourceId'
        value: diskAccessResourceId
      }
      {
        name: 'diskControllerType'
        value: diskControllerType
      }
      {
        name: 'diskEncryptionSetResourceId'
        value: diskEncryptionSetResourceId
      }
      {
        name: 'diskName'
        value: diskName
      }
      {
        name: 'acceleratedNetworking'
        value: string(acceleratedNetworking)
      }
      {
        name: 'encryptionAtHost'
        value: string(encryptionAtHost)
      }
      {
        name: 'imageVersionResourceId'
        value: imageVersionResourceId
      }
      {
        name: 'integrityMonitoring'
        value: string(integrityMonitoring)
      }
      {
        name: 'keyVaultResourceId'
        value: keyVaultResourceId
      }
      {
        name: 'licenseType'
        value: imageLicenseType
      }
      {
        name: 'location'
        value: location
      }
      {
        name: 'networkInterfaceName'
        value: networkInterfaceName
      }
      {
        name: 'privateIPAddress'
        value: privateIPAddress
      }
      {
        name: 'secureBoot'
        value: string(secureBoot)
      }
      {
        name: 'securityType'
        value: securityType
      }
      {
        name: 'subnetResourceId'
        value: subnetResourceId
      }
      {
        name: 'tags'
        value: string(tags[?'Microsoft.Compute/virtualMachines'] ?? {})
      }
      {
        name: 'virtualMachineName'
        value: virtualMachineName
      }
      {
        name: 'virtualMachineSize'
        value: virtualMachineSize
      }
      {
        name: 'vmCustomizations'
        value: string(virtualMachineCustomizations)
      }
      {
        name: 'vTpm'
        value: string(vTpm)
      }
    ])
    functionAppDelegatedSubnetResourceId: integrationSubnetId
    functionAppName: functionAppName
    functionAppUserAssignedIdentityResourceId: userAssignedIdentity.outputs.resourceId
    hostPoolResourceId: ''
    keyManagementStorageAccounts: 'CustomerManagedHSM'
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    paasPublicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    privateEndpoint: privateEndpoint
    privateEndpointNameConv: 'pe-${functionAppName}'
    privateEndpointNICNameConv: 'nic-pe-${functionAppName}'
    privateEndpointSubnetResourceId: endpointSubnetId
    privateLinkScopeResourceId: privateLinkScopeResourceId
    serverFarmId: empty(appServicePlanResourceId)
      ? serverFarm!.outputs.hostingPlanId
      : appServicePlanResourceId
    storageAccountName: storageAccountName
    storageEncryptionIdentityName: '${userAssignedIdentityName}-enc'
    tags: tags
  }
  dependsOn: [
    keys
    networkInterface
  ]
}

module function '../../shared/modules/resourceModules/functionApp/function.bicep' = {
  scope: rg
  params: {
    files: {
      'requirements.psd1': loadTextContent('./scripts/requirements.psd1')
      'run.ps1': loadTextContent('./scripts/run.ps1')
      '../profile.ps1': loadTextContent('./scripts/profile.ps1')
    }
    functionAppName: functionApp.outputs.functionAppName
    functionName: 'ImageValidation'
    schedule: schedule
  }
  dependsOn: [
    networkInterface
  ]
}
