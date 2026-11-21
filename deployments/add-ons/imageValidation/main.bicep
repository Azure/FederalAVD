targetScope = 'subscription'

metadata name = 'Image Validation Add-On'
metadata description = 'The Image Validation add-on deploys an Azure Function App and supporting infrastructure to deploy and ensure the validation virtual machine is always using the latest image. This enables the security team to scan and validate your image before its release.'

import { artifactCustomizationType } from '../../shared/modules/resourceModules/types/customizationTypes.bicep'

@description('Optional. Enable accelerated networking for the validation VM network interface.')
param acceleratedNetworking bool = true

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

@description('Optional. Name of the disk access resource to protect the validation VM\'s disk.')
param diskAccessName string = ''

@description('Optional. Disk controller type for the validation VM.')
@allowed([
  'SCSI'
  'NVMe'
])
param diskControllerType string = 'SCSI'

@description('Optional. Name of the disk encryption set resource to protect the validation VM\'s disk.')
param diskEncryptionSetName string = ''

@description('Optional. Encryption type for the disk encryption set.')
@allowed([
  'EncryptionAtRestWithCustomerKey'
  'EncryptionAtRestWithPlatformAndCustomerKeys'
  'ConfidentialVmEncryptedWithCustomerKey'
])
param diskEncryptionType string = 'EncryptionAtRestWithPlatformAndCustomerKeys'

@description('Required. Complete name for the validation VM disk.')
@minLength(1)
@maxLength(80)
param diskName string

@description('Optional. Network access configuration for the validation VM\'s disk.')
@allowed([
  'AllowAll'
  'AllowPrivate'
  'DenyAll'
])
param diskNetworkAccess string = 'DenyAll'

@description('Optional. Enable encryption at host for the validation VM.')
param encryptionAtHost bool = true

@description('Optional. Endpoint type for the PaaS services.')
@allowed([
  'private'
  'public'
  'service'
])
param endpointType string = 'private'

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

@description('Optional. Existing Azure Monitor Private Link Scope ID. Without it, enabled Insights uses public ingestion and query endpoints.')
param privateLinkScopeResourceId string = ''

@description('Required. Available static IPv4 address in the validation VM subnet.')
@minLength(7)
param privateIPAddress string

@description('Required. Complete resource group name. The deployment manages this group.')
@minLength(1)
@maxLength(90)
param resourceGroupName string

@description('Required. Timer schedule in six-field Functions NCRONTAB format or a supported app-setting reference.')
@minLength(11)
param schedule string = '0 0 21 * * *'

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

@description('Optional. Time zone for the timer schedule in the Function App.')
@allowed([
  'Central Standard Time'
  'Eastern Standard Time'
  'Mountain Standard Time'
  'Pacific Standard Time'
  'UTC'
])
param timeZone string = 'UTC'

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

var integrationSubnetId = endpointType == 'private' && empty(trim(functionAppDelegatedSubnetResourceId))
  ? fail('Private mode requires functionAppDelegatedSubnetResourceId.')
  : functionAppDelegatedSubnetResourceId
var blobDnsZoneId = endpointType == 'private' && empty(trim(azureBlobPrivateDnsZoneResourceId))
  ? fail('Private mode requires azureBlobPrivateDnsZoneResourceId.')
  : azureBlobPrivateDnsZoneResourceId
var appDnsZoneId = endpointType == 'private' && empty(trim(azureFunctionAppPrivateDnsZoneResourceId))
  ? fail('Private mode requires azureFunctionAppPrivateDnsZoneResourceId.')
  : azureFunctionAppPrivateDnsZoneResourceId
var vaultDnsZoneId = endpointType == 'private' && empty(trim(azureKeyVaultPrivateDnsZoneResourceId))
  ? fail('Private mode requires azureKeyVaultPrivateDnsZoneResourceId.')
  : azureKeyVaultPrivateDnsZoneResourceId

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
}

resource roleDefinition_keyVaultDeployAction 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, 'KeyVaultDeployAction')
  properties: {
    roleName: 'KeyVaultDeployAction_${subscription().subscriptionId}'
    description: 'Allows a principal to get but not view Key Vault secrets for an ARM template deployment.'
    assignableScopes: [
      subscription().id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.KeyVault/vaults/deploy/action'
        ]
      }
    ]
  }
}

resource roleDefinition_subnetJoinAction 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, 'SubnetJoinAction')
  properties: {
    roleName: 'SubnetJoinAction_${subscription().subscriptionId}'
    description: 'Allows a principal to join subnets for an ARM template deployment.'
    assignableScopes: [
      subscription().id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.Network/virtualNetworks/subnets/join/action'
        ]
      }
    ]
  }
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

module diskAccess '../../shared/modules/resourceModules/compute/diskAccesses/deploy.bicep' = if (diskNetworkAccess == 'AllowPrivate') {
  scope: rg
  params: {
    name: diskAccessName
    location: location
    tags: tags[?'Microsoft.Compute/diskAccesses'] ?? {}
  }
}

module diskAccessPrivateEndpoint '../../shared/modules/resourceModules/network/privateEndpoints/deploy.bicep' = if (diskNetworkAccess == 'AllowPrivate') {
  scope: rg
  params: {
    groupId: 'disks'
    location: location
    name: 'pe-${diskAccessName}'
    privateDNSZoneIds: [
      blobDnsZoneId
    ]
    privateLinkServiceId: diskAccess!.outputs.resourceId
    subnetResourceId: subnetResourceId
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
  }
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
}

// This key vault is used for storing the encryption keys when using customer-managed keys for the storage account
module keyVault '../../shared/modules/resourceModules/keyVault/vaults/deploy.bicep' = {
  scope: rg
  params: {
    location: location
    name: keyVaultName
    networkAcls: endpointType == 'service'
      ? {
          bypass: 'AzureServices'
          defaultAction: 'Deny'
          ipRules: []
          virtualNetworkRules: [
            {
              id: subnetResourceId
              ignoreMissingVnetServiceEndpoint: false
            }
          ]
        }
      : {}
    publicNetworkAccess: endpointType == 'private' ? 'Disabled' : 'Enabled'
    tags: tags[?'Microsoft.KeyVault/vaults'] ?? {}
  }
}

module keyVaultPrivateEndpoint '../../shared/modules/resourceModules/network/privateEndpoints/deploy.bicep' = if (endpointType == 'private') {
  scope: rg
  params: {
    groupId: 'vault'
    location: location
    name: 'pe-${keyVaultName}'
    privateDNSZoneIds: [
      vaultDnsZoneId
    ]
    privateLinkServiceId: keyVault!.outputs.resourceId
    subnetResourceId: subnetResourceId
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
  }
}

module keys '../../shared/modules/orchestration/customerManagedKeys/customerManagedKeys.bicep' = {
  scope: rg
  params: {
    keyVaultResourceId: keyVault.outputs.resourceId
    keyManagementType: 'CustomerManagedHSM'
    keyNames: [
      diskEncryptionSetName
      storageAccountName
    ]
    identityName: userAssignedIdentityName
    location: location
    tags: tags
  }
}

module diskEncryptionSet '../../shared/modules/resourceModules/compute/diskEncryptionSets/deploy.bicep' = if (!empty(diskEncryptionSetName)) {
  scope: rg
  params: {
    encryptionType: diskEncryptionType
    keyName: diskEncryptionSetName
    keyVaultResourceId: keyVault.outputs.resourceId
    location: location
    name: diskEncryptionSetName
    tags: tags
  }
  dependsOn: [
    keys
  ]
}

module keyVaultKeysRoleAssignment '../../shared/modules/resourceModules/keyVault/vaults/roleAssignment.bicep' = if (!empty(diskEncryptionSetName)) {
  scope: rg
  params: {
    assignments: [
      {
        principalId: diskEncryptionSet!.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: 'e147488a-f6f5-4113-8e2d-b22465e65bf6' // Key Vault Crypto Service Encryption User
      }
    ]
    keyVaultName: last(split(keyVault.outputs.resourceId, '/'))
  }
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
    encryptionKeyVaultResourceId: keyVault.outputs.resourceId
    functionAppAppSettings: concat([
      {
        name: 'acceleratedNetworking'
        value: string(acceleratedNetworking)
      }
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
        value: diskNetworkAccess == 'AllowPrivate' ? diskAccess!.outputs.resourceId : ''
      }
      {
        name: 'diskControllerType'
        value: diskControllerType
      }
      {
        name: 'diskEncryptionSetResourceId'
        value: empty(diskEncryptionSetName) ? '' : diskEncryptionSet!.outputs.resourceId
      }
      {
        name: 'diskName'
        value: diskName
      }
      {
        name: 'diskNetworkAccess'
        value: diskNetworkAccess
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
        name: 'resourceGroupName'
        value: resourceGroupName
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
        name: 'subscriptionId'
        value: subscription().subscriptionId
      }
      {
        name: 'tags'
        value: string(tags[?'Microsoft.Compute/virtualMachines'] ?? {})
      }
      {
        name: 'templateSpecResourceId'
        value: templateSpec.outputs.versionResourceId
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
      {
        name: 'WEBSITE_TIME_ZONE'
        value: timeZone
      }
    ])
    functionAppDelegatedSubnetResourceId: integrationSubnetId
    functionAppName: functionAppName
    hostPoolResourceId: ''
    keyManagementStorageAccounts: 'CustomerManagedHSM'
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    paasPublicNetworkAccess: endpointType == 'private' ? 'Disabled' : 'Enabled'
    privateEndpoint: endpointType == 'private' ? true : false
    privateEndpointNameConv: 'pe-RESOURCE-SUBRESOURCE'
    privateEndpointNICNameConv: 'nic-pe-RESOURCE-SUBRESOURCE'
    privateEndpointSubnetResourceId: subnetResourceId
    privateLinkScopeResourceId: privateLinkScopeResourceId
    serverFarmId: empty(appServicePlanResourceId) ? serverFarm!.outputs.hostingPlanId : appServicePlanResourceId
    storageAccountName: storageAccountName
    storageEncryptionIdentityName: userAssignedIdentityName
    tags: tags
  }
  dependsOn: [
    keys
  ]
}

// Role assignment gives the Virtual Machine Contributor role to the function app to manage the validation virtual machine resources
module resourceGroupRoleAssignment '../../shared/modules/resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  scope: rg
  params: {
    principalId: functionApp.outputs.functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c' // Virtual Machine Contributor
  }
}

// Role assignment gives the subnet join action to the function app to add network interfaces to the virtual network (least privilege access)
module virtualNetworkRoleAssignment '../../shared/modules/resourceModules/network/virtualNetworks/roleAssignment.bicep' = {
  scope: resourceGroup(split(subnetResourceId, '/')[2], split(subnetResourceId, '/')[4])
  params: {
    assignments: [
      {
        principalId: functionApp.outputs.functionAppPrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: roleDefinition_subnetJoinAction.id
      }
    ]
    virtualNetworkName: split(subnetResourceId, '/')[8]
  }
}

// Role assignment gives the key vault deploy action to the function app to access key vault secrets for deployment (least privilege access)
module keyVaultRoleAssignment '../../shared/modules/resourceModules/keyVault/vaults/roleAssignment.bicep' = {
  scope: resourceGroup(split(keyVaultResourceId, '/')[2], split(keyVaultResourceId, '/')[4])
  params: {
    assignments: [
      {
        principalId: functionApp.outputs.functionAppPrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: roleDefinition_keyVaultDeployAction.id
      }
    ]
    keyVaultName: last(split(keyVaultResourceId, '/'))
  }
}

// Role assignment gives the Reader role to the function app to access the disk encryption set (least privilege access)
module diskEncryptionSetRoleAssignment '../../shared/modules/resourceModules/compute/diskEncryptionSets/roleAssignment.bicep' = if (!empty(diskEncryptionSetName)) {
  scope: rg
  params: {
    assignments: [
      {
        principalId: functionApp.outputs.functionAppPrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
      }
    ]
    diskEncryptionSetName: split(diskEncryptionSet!.outputs.resourceId, '/')[8]
  }
}

// Role assignment gives the Reader role to the function app for the compute gallery (least privilege access)
module galleryRoleAssignment '../../shared/modules/resourceModules/compute/galleries/roleAssignment.bicep' = {
  scope: resourceGroup(split(imageVersionResourceId, '/')[2], split(imageVersionResourceId, '/')[4])
  params: {
    assignments: [
      {
        principalId: functionApp.outputs.functionAppPrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
      }
    ]
    galleryName: split(imageVersionResourceId, '/')[8]
  }
}

// Role assignment gives the Template Spec Reader role to the function app for the template spec (least privilege access)
module templateSpecRoleAssignment '../../shared/modules/resourceModules/resources/templateSpecs/roleAssignment.bicep' = {
  scope: rg
  params: {
    assignments: [
      {
        principalId: functionApp.outputs.functionAppPrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: '392ae280-861d-42bd-9ea5-08ee6d83b80e' // Template Spec Reader
      }
    ]
    templateSpecName: templateSpec.outputs.name
  }
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
