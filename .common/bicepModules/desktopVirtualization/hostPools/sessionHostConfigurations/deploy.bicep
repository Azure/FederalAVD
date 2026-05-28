@description('Name of the parent AVD host pool.')
param hostPoolName string

type KeyVaultCredentialsProperties = {
  passwordKeyVaultSecretUri: string
  usernameKeyVaultSecretUri: string
}

type ActiveDirectoryInfoProperties = {
  domainCredentials: KeyVaultCredentialsProperties
  domainName: string?
  ouPath: string
}

type AzureActiveDirectoryInfoProperties = {
  mdmProviderGuid: string
}

type DomainInfoProperties = {
  activeDirectoryInfo: ActiveDirectoryInfoProperties?
  azureActiveDirectoryInfo: AzureActiveDirectoryInfoProperties?
  joinType: 'ActiveDirectory' | 'AzureActiveDirectory'
}

type CustomImageInfoProperties = {
  resourceId: string
}

type MarketplaceImageInfoProperties = {
  exactVersion: string
  offer: string
  publisher: string
  sku: string
}

type ImageInfoProperties = {
  customInfo: CustomImageInfoProperties?
  marketplaceInfo: MarketplaceImageInfoProperties?
  type: 'Marketplace' | 'Custom'
}

type NetworkInfoProperties = {
  securityGroupId: string?
  subnetId: string
}

type ManagedDiskProperties = {
  type: 'Standard_LRS' | 'Premium_LRS' | 'StandardSSD_LRS'
}

type DiffDiskProperties = {
  option: 'Local'?
  placement: 'CacheDisk' | 'ResourceDisk'?
}

type DiskInfoProperties = {
  diffDiskSettings: DiffDiskProperties?
  managedDisk: ManagedDiskProperties?
}

type BootDiagnosticsInfoProperties = {
  enabled: bool?
  storageUri: string?
}

type SecurityInfoProperties = {
  secureBootEnabled: bool?
  type: 'Standard' | 'TrustedLaunch' | 'ConfidentialVM'?
  vTpmEnabled: bool?
}

type SessionHostConfigurationProperties = {
  availabilityZones: int[]?
  bootDiagnosticsInfo: BootDiagnosticsInfoProperties?
  customConfigurationScriptUrl: string?
  diskInfo: DiskInfoProperties
  domainInfo: DomainInfoProperties
  friendlyName: string?
  imageInfo: ImageInfoProperties
  networkInfo: NetworkInfoProperties
  securityInfo: SecurityInfoProperties?
  vmAdminCredentials: KeyVaultCredentialsProperties
  vmLocation: string?
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
