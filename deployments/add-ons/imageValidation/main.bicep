targetScope = 'subscription'

metadata name = 'Image validation infrastructure'
metadata description = 'Deploys private Windows PowerShell timer Function infrastructure. Validation code and workload permissions are supplied by the operator.'

import { functionAppNames, namingPolicy, resourceNameForType } from '../../shared/modules/orchestration/naming/naming.bicep'

@description('Optional. Complete name override for a new App Service plan. Ignored when using an existing plan ID.')
param appServicePlanNameOverride string = ''

@description('Optional. URI of the storage container containing the customization artifacts.')
param artifactsContainerUri string = ''

@description('Optional. Client ID of the user-assigned identity used to access the customization artifacts.')
param artifactsUserAssignedIdentityClientId string = ''

@description('Required for private mode. Existing target-cloud blob private DNS zone ID, linked to the integration VNet.')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Required for private mode. Existing target-cloud Function App private DNS zone ID, linked to the integration VNet.')
param azureFunctionAppPrivateDnsZoneResourceId string = ''

@description('Required for private mode. Existing target-cloud Key Vault private DNS zone ID, linked to the integration VNet.')
param azureKeyVaultPrivateDnsZoneResourceId string = ''

@description('Optional. Enable boot diagnostics for the validation VM.')
param bootDiagnosticsEnabled bool = true

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

@description('Optional. Complete name override for the new storage encryption Key Vault.')
@maxLength(24)
param encryptionKeyVaultNameOverride string = ''

@description('Optional. Enable accelerated networking for the validation VM network interface.')
param enableAcceleratedNetworking bool = true

@description('Optional. Enable encryption at host for the validation VM.')
param encryptionAtHost bool = true

@description('Optional. Existing same-region Windows Dedicated App Service plan ID. Empty creates a dedicated PremiumV3_P0v3 plan.')
param existingAppServicePlanResourceId string = ''

@description('Required for private mode. Existing Microsoft.Web/serverFarms-delegated integration subnet in the app region, separate from the endpoint subnet.')
param functionAppDelegatedSubnetResourceId string = ''

@description('Optional. Complete Function App name override.')
@maxLength(60)
param functionAppNameOverride string = ''

@description('Optional. Enable hibernation for the validation VM.')
param hibernationEnabled bool = false

@description('Optional. Short add-on identifier used by the centralized naming policy. Use distinct identifiers for independent instances.')
@minLength(1)
param identifier string = 'iv'

@description('Required. License type for the image.')
@allowed([
  'Windows_Client'
  'Windows_Server'
])
param imageLicenseType string = 'Windows_Client'

@description('Required. Existing image version resource ID under imageDefinitionResourceId for the validation VM.')
@minLength(1)
param imageVersionResourceId string

@description('Required. Existing credentials Key Vault ID containing LocalAdminUsername and LocalAdminPassword secrets. Enable template deployment and authorize the deployment principal.')
@minLength(1)
param keyVaultResourceId string

@description('Optional. Azure region for the resource group and Function infrastructure.')
param location string = deployment().location

@description('Optional. Existing workspace ID. Nonempty enables Application Insights and FunctionAppLogs diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Shared naming convention overrides. Empty uses the centralized FederalAVD defaults.')
param namingConvention object = {}

@description('Optional. Create private endpoints and disable public app/storage access. Requires existing subnets and private DNS zones.')
param privateEndpoint bool = true

@description('Required for private mode. Existing subnet for app and blob private endpoints.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. Existing Azure Monitor Private Link Scope ID. Without it, enabled Insights uses public ingestion and query endpoints.')
param privateLinkScopeResourceId string = ''

@description('Required. Available static IPv4 address in the validation VM subnet.')
@minLength(1)
param privateIPAddress string

@description('Optional. Complete resource group name override. The deployment manages this group.')
param resourceGroupNameOverride string = ''

@description('Optional. Enable secure boot for the validation VM.')
param secureBootEnabled bool = true

@description('Optional. Security type for the validation VM.')
@allowed([
  'TrustedLaunch'
  'ConfidentialVM'
])
param securityType string = 'TrustedLaunch'

@description('Required. Timer schedule in six-field Functions NCRONTAB format or a supported app-setting reference.')
@minLength(1)
param schedule string

@description('Optional. Complete runtime storage name override, also useful when generated storage names exceed 24 characters.')
@maxLength(24)
param storageAccountNameOverride string = ''

@description('Required. Existing subnet resource ID for the validation VM, separate from Function App integration networking.')
@minLength(1)
param subnetResourceId string

@description('Optional. Tags applied to all resources that support tags.')
param tags object = {}

@description('Optional. Existing user-assigned identity resource IDs for the validation VM.')
param userAssignedIdentityResourceIds array = []

@description('Optional. Complete name override for the Function App identity.')
param userAssignedIdentityNameOverride string = ''

@description('Optional. Customizations applied to the validation VM.')
param virtualMachineCustomizations object = {}

@description('Required. Windows VM size supported by the selected image and region, including accelerated networking.')
@minLength(1)
param virtualMachineSize string 

@description('Optional. Enable vTPM for the validation VM.')
param vTpmEnabled bool = true

var groupContext = {
  subscriptionId: subscription().subscriptionId
  resourceGroupName: ''
  location: location
  cloud: environment().name
}
var resourceGroupName = !empty(resourceGroupNameOverride)
  ? resourceGroupNameOverride
  : resourceNameForType(namingConvention, 'resourceGroups', identifier, groupContext)
var namingContext = union(groupContext, { resourceGroupName: resourceGroupName })
var validationVirtualMachineName = resourceNameForType(namingConvention, 'virtualMachines', identifier, namingContext)
var names = union(
  functionAppNames(namingConvention, identifier, namingContext, {
    functionAppName: functionAppNameOverride
    storageAccountName: storageAccountNameOverride
  }),
  {
    resourceGroup: resourceGroupName
    diskName: resourceNameForType(namingConvention, 'osdisks', identifier, namingContext)
    networkInterfaceName: resourceNameForType(namingConvention, 'networkInterfaces', identifier, namingContext)
    encryptionKeyVaultName: !empty(encryptionKeyVaultNameOverride)
      ? encryptionKeyVaultNameOverride
      : resourceNameForType(namingConvention, 'keyVaults', identifier, namingContext)
    templateSpecName: resourceNameForType(namingConvention, 'templateSpecs', identifier, namingContext)
    virtualMachineName: length(validationVirtualMachineName) > namingPolicy.limits.deploymentVm
      ? fail('Generated validation VM name exceeds the shared Windows computer-name limit. Shorten the identifier or naming-convention values.')
      : validationVirtualMachineName
    userAssignedIdentity: !empty(userAssignedIdentityNameOverride)
      ? userAssignedIdentityNameOverride
      : resourceNameForType(namingConvention, 'userAssignedIdentities', identifier, namingContext)
    appServicePlanName: !empty(existingAppServicePlanResourceId)
      ? last(split(existingAppServicePlanResourceId, '/'))
      : !empty(appServicePlanNameOverride)
          ? appServicePlanNameOverride
          : resourceNameForType(namingConvention, 'appServicePlans', identifier, namingContext)
  }
)

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
  name: names.resourceGroup
  location: location
  tags: tags
}

module userAssignedIdentity '../../shared/modules/resourceModules/managedIdentity/userAssignedIdentities/deploy.bicep' = {
  scope: rg
  params: {
    location: location
    name: names.userAssignedIdentity
    tags: tags
  }
}

module templateSpec 'modules/templateSpec.bicep' = {
  scope: rg
  params: {
    imageDefinitionName: split(imageVersionResourceId, '/')[10]
    location: location
    tags: tags
    templateSpecName: names.templateSpecName
  }
}

// Shared vault orchestration also owns private endpoints, DNS zone groups and diagnostics.
module encryptionKeyVault '../../shared/modules/orchestration/keyVaults/keyVaults.bicep' = {
  params: {
    resourceGroupName: rg.name
    deploySecretsKeyVault: false
    secretsKeyVaultName: ''
    deployEncryptionKeyVault: true
    encryptionKeyVaultName: names.encryptionKeyVaultName
    azureKeyVaultPrivateDnsZoneResourceId: vaultDnsZoneId
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    privateEndpoint: privateEndpoint
    privateEndpointSubnetResourceId: endpointSubnetId
    privateEndpointNameConv: names.privateEndpointNameConv
    privateEndpointNICNameConv: names.privateEndpointNICNameConv
    paasPublicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    tags: tags
  }
}

module storageCmk '../../shared/modules/orchestration/customerManagedKeys/customerManagedKeys.bicep' = {
  scope: rg
  params: {
    keyVaultResourceId: encryptionKeyVault.outputs.encryptionKeyVaultResourceId
    keyManagementType: 'CustomerManagedHSM'
    keyNames: [names.storageAccountName]
    identityName: names.storageEncryptionIdentityName
    location: location
    tags: tags
  }
}

module serverFarm '../../shared/modules/resourceModules/functionApp/functionAppHostingPlan.bicep' = if (empty(existingAppServicePlanResourceId)) {
  scope: rg
  params: {
    functionAppKind: 'functionapp'
    hostingPlanType: 'Dedicated'
    location: location
    name: names.appServicePlanName
    planPricing: 'PremiumV3_P0v3'
    tags: tags
    zoneRedundant: false
  }
}

module functionApp '../../shared/modules/resourceModules/functionApp/functionApp.bicep' = {
  scope: rg
  params: {
    applicationInsightsName: names.applicationInsightsName
    azureBlobPrivateDnsZoneResourceId: blobDnsZoneId
    azureFunctionAppPrivateDnsZoneResourceId: appDnsZoneId
    enableApplicationInsights: !empty(logAnalyticsWorkspaceResourceId)
    enableQueueStorage: false
    enableTableStorage: false
    encryptionKeyName: names.storageAccountName
    encryptionKeyVaultResourceId: encryptionKeyVault.outputs.encryptionKeyVaultResourceId
    functionAppAppSettings: concat([
      {
        name: 'artifactsContainerUri'
        value: artifactsContainerUri
      }
      {
        name: 'artifactsUserAssignedIdentityClientId'
        value: artifactsUserAssignedIdentityClientId
      }
      {
        name: 'bootDiagnosticsEnabled'
        value: string(bootDiagnosticsEnabled)
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
        value: names.diskName
      }
      {
        name: 'enableAcceleratedNetworking'
        value: string(enableAcceleratedNetworking)
      }
      {
        name: 'encryptionAtHost'
        value: string(encryptionAtHost)
      }
      {
        name: 'hibernationEnabled'
        value: string(hibernationEnabled)
      }
      {
        name: 'imageVersionResourceId'
        value: imageVersionResourceId
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
        value: names.networkInterfaceName
      }
      {
        name: 'privateIPAddress'
        value: privateIPAddress
      }
      {
        name: 'secureBootEnabled'
        value: string(secureBootEnabled)
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
        value: string(tags)
      }
      {
        name: 'userAssignedIdentityResourceIds'
        value: string(union(userAssignedIdentityResourceIds, [userAssignedIdentity.outputs.resourceId]))
      }
      {
        name: 'virtualMachineName'
        value: names.virtualMachineName
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
        name: 'vTpmEnabled'
        value: string(vTpmEnabled)
      }
    ])
    functionAppDelegatedSubnetResourceId: integrationSubnetId
    functionAppName: names.functionAppName
    functionAppUserAssignedIdentityResourceId: userAssignedIdentity.outputs.resourceId
    hostPoolResourceId: ''
    keyManagementStorageAccounts: 'CustomerManagedHSM'
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    paasPublicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    privateEndpoint: privateEndpoint
    privateEndpointNameConv: names.privateEndpointNameConv
    privateEndpointNICNameConv: names.privateEndpointNICNameConv
    privateEndpointSubnetResourceId: endpointSubnetId
    privateLinkScopeResourceId: privateLinkScopeResourceId
    serverFarmId: !empty(existingAppServicePlanResourceId)
      ? existingAppServicePlanResourceId
      : serverFarm!.outputs.hostingPlanId
    storageAccountName: names.storageAccountName
    storageEncryptionIdentityName: names.storageEncryptionIdentityName
    tags: tags
  }
  // The shared app module computes the encryption identity ID from its name, so gate key/RBAC completion explicitly.
  dependsOn: [
    storageCmk
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
}

@description('Resolved infrastructure and validation VM names from the shared naming policy.')
output generatedNames object = names

@description('Managed identity principal ID for granting validation workload permissions.')
output userAssignedIdentityPrincipalId string = userAssignedIdentity.outputs.principalId
