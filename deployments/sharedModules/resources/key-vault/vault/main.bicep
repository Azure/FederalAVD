@description('Required. Name of the Key Vault. Must be globally unique.')
@maxLength(24)
param name string

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Optional. All secrets to create.')
@secure()
param secrets object = {}

@description('Optional. All keys to create.')
param keys array = []

@description('Optional. Specifies if the vault is enabled for deployment by script or compute.')
param enableVaultForDeployment bool = true

@description('Optional. Specifies if the vault is enabled for a template deployment.')
param enableVaultForTemplateDeployment bool = true

@description('Optional. Specifies if the azure platform has access to the vault for enabling disk encryption scenarios.')
param enableVaultForDiskEncryption bool = true

@description('Required. Switch to enable/disable Key Vault\'s soft delete feature.')
param enableSoftDelete bool = false

@description('Optional. softDelete data retention days. It accepts >=7 and <=90.')
param softDeleteRetentionInDays int = 0

@description('Optional. Property that controls how data actions are authorized. When true, the key vault will use Role Based Access Control (RBAC) for authorization of data actions, and the access policies specified in vault properties will be ignored. When false, the key vault will use the access policies specified in vault properties, and any policy stored on Azure Resource Manager will be ignored. Note that management actions are always authorized with RBAC.')
param enableRbacAuthorization bool = true

@description('Optional. The vault\'s create mode to indicate whether the vault need to be recovered or not. - recover or default.')
param createMode string = 'default'

@description('Optional. Provide \'true\' to enable Key Vault\'s purge protection feature.')
param enablePurgeProtection bool = false

@description('Optional. Specifies the SKU for the vault.')
@allowed([
  'premium'
  'standard'
])
param vaultSku string = 'premium'

@description('Optional. Service endpoint object information. For security reasons, it is recommended to set the DefaultAction Deny.')
param networkAcls object = {}

@description('Optional. Whether or not public network access is allowed for this resource. For security reasons it should be disabled. If not specified, it will be disabled by default if private endpoints are set and networkAcls are not set.')
@allowed([
  ''
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = ''

@description('Optional. Resource ID of the diagnostic storage account. For security reasons, it is recommended to set diagnostic settings to send data to either storage account, log analytics workspace or event hub.')
param diagnosticStorageAccountId string = ''

@description('Optional. Resource ID of the diagnostic log analytics workspace. For security reasons, it is recommended to set diagnostic settings to send data to either storage account, log analytics workspace or event hub.')
param diagnosticWorkspaceId string = ''

@description('Optional. Resource ID of the diagnostic event hub authorization rule for the Event Hubs namespace in which the event hub should be created or streamed to.')
param diagnosticEventHubAuthorizationRuleId string = ''

@description('Optional. Name of the diagnostic event hub within the namespace to which logs are streamed. Without this, an event hub is created for each log category. For security reasons, it is recommended to set diagnostic settings to send data to either storage account, log analytics workspace or event hub.')
param diagnosticEventHubName string = ''

@description('Optional. Configuration details for private endpoints. For security reasons, it is recommended to use private endpoints whenever possible.')
param privateEndpoints array = []

@description('Optional. Resource tags.')
param tags object = {}

@description('Optional. The name of logs that will be streamed. "allLogs" includes all possible logs for the resource. Set to \'\' to disable log collection.')
@allowed([
  ''
  'allLogs'
  'AuditEvent'
  'AzurePolicyEvaluationDetails'
])
param diagnosticLogCategoriesToEnable array = [
  'allLogs'
]

@description('Optional. The name of metrics that will be streamed.')
@allowed([
  'AllMetrics'
])
param diagnosticMetricsToEnable array = [
  'AllMetrics'
]

@description('Optional. The name of the diagnostic setting, if deployed. If left empty, it defaults to "<resourceName>-diagnosticSettings".')
param diagnosticSettingsName string = ''

var diagnosticsLogsSpecified = [for category in filter(diagnosticLogCategoriesToEnable, item => item != 'allLogs' && item != ''): {
  category: category
  enabled: true
}]

var diagnosticsLogs = contains(diagnosticLogCategoriesToEnable, 'allLogs') ? [
  {
    categoryGroup: 'allLogs'
    enabled: true
  }
] : contains(diagnosticLogCategoriesToEnable, '') ? [] : diagnosticsLogsSpecified

var diagnosticsMetrics = [for metric in diagnosticMetricsToEnable: {
  category: metric
  timeGrain: null
  enabled: true
}]

var secretList = !empty(secrets) ? secrets.secureList : []

// Determine bypass value based on the publicNetworkAccess, privateEndpoints, and networkAcls parameters
var varPublicNetworkAccess = !empty(publicNetworkAccess) ? any(publicNetworkAccess) : ( !empty(privateEndpoints) && empty(networkAcls) ? 'Disabled' : null )
// If networkAcls are not set, then bypass must be set. If vault is enabled for deployment, template deployment, or vm disk encryption, or publicNetworkAccess is disabled then Bypass must = AzureServices
var bypass = enableVaultForDeployment || enableVaultForTemplateDeployment || enableVaultForDiskEncryption || varPublicNetworkAccess == 'Disabled' ? 'AzureServices' : 'None'

resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    enabledForDeployment: enableVaultForDeployment
    enabledForTemplateDeployment: enableVaultForTemplateDeployment
    enabledForDiskEncryption: enableVaultForDiskEncryption
    enableSoftDelete: enableSoftDelete ? enableSoftDelete : null
    softDeleteRetentionInDays: enableSoftDelete ? softDeleteRetentionInDays : null
    enableRbacAuthorization: enableRbacAuthorization
    createMode: createMode
    enablePurgeProtection: enablePurgeProtection ? enablePurgeProtection : null
    tenantId: subscription().tenantId
    sku: {
      name: vaultSku
      family: 'A'
    }
    networkAcls: !empty(networkAcls) ? {
      bypass: networkAcls.?bypass ?? null
      defaultAction: networkAcls.?defaultAction ?? null
      virtualNetworkRules: networkAcls.?virtualNetworkRules ?? []
      ipRules: networkAcls.?ipRules ?? []
    } : {
      bypass: bypass
      defaultAction: 'Deny'
    }
    publicNetworkAccess: varPublicNetworkAccess
  }
}

resource keyVault_diagnosticSettings 'Microsoft.Insights/diagnosticsettings@2021-05-01-preview' = if ((!empty(diagnosticStorageAccountId)) || (!empty(diagnosticWorkspaceId)) || (!empty(diagnosticEventHubAuthorizationRuleId)) || (!empty(diagnosticEventHubName))) {
  name: !empty(diagnosticSettingsName) ? diagnosticSettingsName : '${name}-diagnosticSettings'
  properties: {
    storageAccountId: !empty(diagnosticStorageAccountId) ? diagnosticStorageAccountId : null
    workspaceId: !empty(diagnosticWorkspaceId) ? diagnosticWorkspaceId : null
    eventHubAuthorizationRuleId: !empty(diagnosticEventHubAuthorizationRuleId) ? diagnosticEventHubAuthorizationRuleId : null
    eventHubName: !empty(diagnosticEventHubName) ? diagnosticEventHubName : null
    metrics: diagnosticsMetrics
    logs: diagnosticsLogs
  }
  scope: keyVault
}

module keyVault_secrets 'secret/main.bicep' = [for (secret, index) in secretList: {
  name: 'KeyVault-Secret-${index}-${uniqueString(deployment().name, location)}'
  params: {
    name: secret.name
    value: secret.value
    keyVaultName: keyVault.name
    attributesEnabled: secret.?attributesEnabled ?? true
    attributesExp: secret.?attributesExp ?? -1
    attributesNbf: secret.?attributesNbf ?? -1
    contentType: secret.?contentType ?? ''
    tags: secret.?tags ?? {}
  }
}]

module keyVault_keys 'key/main.bicep' = [for (key, index) in keys: {
  name: 'KeyVault-Key-${index}-${uniqueString(deployment().name, location)}'
  params: {
    name: key.name
    keyVaultName: keyVault.name
    attributesEnabled: key.?attributesEnabled ?? true
    attributesExp: key.?attributesExp ?? -1
    attributesExportable: key.?attributesExportable ?? false
    attributesNbf: key.?attributesNbf ?? -1
    curveName: key.?curveName ?? 'P-256'
    keyOps: key.?keyOps ?? []
    keySize: key.?keySize ?? -1
    kty: key.?kty ?? 'EC'
    tags: key.?tags ?? {}
    rotationPolicy: key.?rotationPolicy ?? {}
  }
}]

module keyVault_privateEndpoints '../../network/private-endpoint/main.bicep' = [for (privateEndpoint, index) in privateEndpoints: {
  name: 'KeyVault-PrivateEndpoint-${index}-${uniqueString(deployment().name, location)}'
  params: {
    groupIds: [
      privateEndpoint.service
    ]
    name: privateEndpoint.?name ?? 'pe-${last(split(keyVault.id, '/'))}-${privateEndpoint.service}-${index}'
    serviceResourceId: keyVault.id
    subnetResourceId: privateEndpoint.subnetResourceId
    location: privateEndpoint.?location ?? reference(split(privateEndpoint.subnetResourceId, '/subnets/')[0], '2020-06-01', 'Full').location
    privateDnsZoneGroup: privateEndpoint.?privateDnsZoneGroup ?? {}
    tags: privateEndpoint.?tags ?? {}
    manualPrivateLinkServiceConnections: privateEndpoint.?manualPrivateLinkServiceConnections ?? []
    customDnsConfigs: privateEndpoint.?customDnsConfigs ?? []
    ipConfigurations: privateEndpoint.?ipConfigurations ?? []
    applicationSecurityGroups: privateEndpoint.?applicationSecurityGroups ?? []
    customNetworkInterfaceName: privateEndpoint.?customNetworkInterfaceName ?? ''
  }
}]

@description('The resource ID of the key vault.')
output resourceId string = keyVault.id

@description('The name of the resource group the key vault was created in.')
output resourceGroupName string = resourceGroup().name

@description('The name of the key vault.')
output name string = keyVault.name

@description('The URI of the key vault.')
output uri string = keyVault.properties.vaultUri

@description('The location the resource was deployed into.')
output location string = keyVault.location
