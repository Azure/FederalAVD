@description('Name of the parent AVD host pool.')
param hostPoolName string

@export()
type KeyVaultCredentialsProperties = {
  passwordKeyVaultSecretUri: string
  usernameKeyVaultSecretUri: string
}

@export()
type ActiveDirectoryInfoProperties = {
  domainCredentials: KeyVaultCredentialsProperties
  domainName: string?
  ouPath: string
}

@export()
type AzureActiveDirectoryInfoProperties = {
  mdmProviderGuid: string
}

@export()
type DomainInfoProperties = {
  activeDirectoryInfo: ActiveDirectoryInfoProperties?
  azureActiveDirectoryInfo: AzureActiveDirectoryInfoProperties?
  joinType: 'ActiveDirectory' | 'AzureActiveDirectory'
}

@export()
type CustomImageInfoProperties = {
  resourceId: string
}

@export()
type MarketplaceImageInfoProperties = {
  exactVersion: string
  offer: string
  publisher: string
  sku: string
}

@export()
type ImageInfoProperties = {
  customInfo: CustomImageInfoProperties?
  marketplaceInfo: MarketplaceImageInfoProperties?
  type: 'Marketplace' | 'Custom'
}

@export()
type NetworkInfoProperties = {
  securityGroupId: string?
  subnetId: string
}

@export()
type ManagedDiskProperties = {
  type: 'Standard_LRS' | 'Premium_LRS' | 'StandardSSD_LRS'
}

@export()
type DiffDiskProperties = {
  option: 'Local'?
  placement: 'CacheDisk' | 'ResourceDisk'?
}

@export()
type DiskInfoProperties = {
  diffDiskSettings: DiffDiskProperties?
  managedDisk: ManagedDiskProperties?
}

@export()
type BootDiagnosticsInfoProperties = {
  enabled: bool?
  storageUri: string?
}

@export()
type SecurityInfoProperties = {
  secureBootEnabled: bool?
  type: 'Standard' | 'TrustedLaunch' | 'ConfidentialVM'?
  vTpmEnabled: bool?
}

@export()
type SessionHostConfigurationProperties = {
  availabilityZones: int[]?
  bootDiagnosticsInfo: BootDiagnosticsInfoProperties?
  customConfigurationScriptUrl: string?
  diskInfo: DiskInfoProperties
  domainInfo: DomainInfoProperties
  @maxLength(260)
  friendlyName: string?
  imageInfo: ImageInfoProperties
  networkInfo: NetworkInfoProperties
  securityInfo: SecurityInfoProperties?
  vmAdminCredentials: KeyVaultCredentialsProperties
  vmLocation: string?
  @maxLength(11)
  vmNamePrefix: string
  vmResourceGroup: string?
  vmSizeId: string
  vmTags: object?
}

@description('Session host configuration properties.')
param properties SessionHostConfigurationProperties

resource hostpool 'Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview' existing = {
  name: hostPoolName
}

resource sessionHostConfiguration 'Microsoft.DesktopVirtualization/hostPools/sessionHostConfigurations@2025-11-01-preview' = {
  name: 'default'
  parent: hostpool
  properties: properties
}

output resourceId string = sessionHostConfiguration.id
output name string = sessionHostConfiguration.name
output version string = string(sessionHostConfiguration.properties.?version ?? '')
