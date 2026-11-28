metadata name = 'Typed PaaS networking scenarios'
metadata description = 'Shared networking intent, secure defaults and explicit service overrides. Resource modules retain their Azure-native inputs.'

import { servicePublicNetworkAccessMode, serviceEndpointSubnetIds } from './functions.bicep'

// Entry points expose only the families and namespaces that they own.
// Omitted properties normalize explicitly; object defaults do not merge nested properties.
// IP and service-endpoint allowlists remain separate for each service family in every mode.
@export()
@sealed()
type serviceNetworkingType = {
  publicNetworkAccess: servicePublicNetworkAccessMode?
  privateEndpoint: bool?
  permittedIPs: string[]?
  serviceEndpointSubnetResourceIds: string[]?
}

@export()
@sealed()
type backupNetworkingType = {
  publicNetworkAccess: ('Enabled' | 'Disabled')?
  privateEndpoint: bool?
}

@export()
@sealed()
type diskNetworkingType = {
  privateEndpoint: bool?
}

@export()
@sealed()
type paasNetworkingType = {
  publicNetworkAccess: servicePublicNetworkAccessMode?
  privateEndpoint: bool?
  storage: serviceNetworkingType?
  keyVault: serviceNetworkingType?
  backup: backupNetworkingType?
  disk: diskNetworkingType?
}

@export()
@sealed()
type imageManagementPaasNetworkingType = {
  publicNetworkAccess: servicePublicNetworkAccessMode?
  privateEndpoint: bool?
  storage: serviceNetworkingType?
}

@export()
@sealed()
type automatedHostPoolPaasNetworkingType = {
  publicNetworkAccess: servicePublicNetworkAccessMode?
  privateEndpoint: bool?
  storage: serviceNetworkingType?
  keyVault: serviceNetworkingType?
  backup: backupNetworkingType?
}

@export()
@sealed()
type sharedServicesPaasNetworkingType = {
  publicNetworkAccess: servicePublicNetworkAccessMode?
  privateEndpoint: bool?
  keyVault: serviceNetworkingType?
  backup: backupNetworkingType?
}

@export()
@sealed()
type functionAppPaasNetworkingType = {
  publicNetworkAccess: servicePublicNetworkAccessMode?
  privateEndpoint: bool?
  storage: serviceNetworkingType?
  functionApp: serviceNetworkingType?
}

@export()
@sealed()
type sessionHostReplacerPrivateDnsZoneResourceIdsType = {
  blob: string?
  table: string?
  websites: string?
}

@export()
@sealed()
type sharedPrivateEndpointSubnetResourceIdsType = {
  sharedResources: string?
}

@export()
@sealed()
type imageManagementPrivateDnsZoneResourceIdsType = {
  blob: string?
}

@export()
@sealed()
type sharedServicesPrivateDnsZoneResourceIdsType = {
  vault: string?
  backup: string?
  blob: string?
  queue: string?
  avdFeed: string?
  avdGlobalFeed: string?
}

@export()
@sealed()
type privateEndpointSubnetResourceIdsType = {
  sharedResources: string?
  hostPoolResources: string?
}

@export()
@sealed()
type privateDnsZoneResourceIdsType = {
  backup: string?
  blob: string?
  file: string?
  vault: string?
  queue: string?
  avdFeed: string?
  avdGlobalFeed: string?
}

type resolvedServiceNetworkingType = {
  publicNetworkAccess: servicePublicNetworkAccessMode
  privateEndpoint: bool
  permittedIPs: string[]
  serviceEndpointSubnetResourceIds: string[]
}

type resolvedBackupNetworkingType = {
  publicNetworkAccess: 'Enabled' | 'Disabled'
  privateEndpoint: bool
}

type resolvedPaasNetworkingType = {
  storage: resolvedServiceNetworkingType
  keyVault: resolvedServiceNetworkingType
  backup: resolvedBackupNetworkingType
  disk: {
    privateEndpoint: bool
  }
}

func resolveServiceNetworking(config serviceNetworkingType, publicAccess servicePublicNetworkAccessMode, privateEndpoint bool, created bool, family string) resolvedServiceNetworkingType => {
  publicNetworkAccess: created && (config.?publicNetworkAccess ?? publicAccess) == 'EnabledWithRestrictions' && !(config.?privateEndpoint ?? privateEndpoint) && empty(filter(config.?permittedIPs ?? [], ip => !empty(trim(ip)))) && empty(config.?serviceEndpointSubnetResourceIds ?? [])
    ? fail('${family} restricted public connectivity requires permittedIPs, serviceEndpointSubnetResourceIds, or a private endpoint.')
    : config.?publicNetworkAccess ?? publicAccess
  privateEndpoint: config.?privateEndpoint ?? privateEndpoint
  permittedIPs: config.?permittedIPs ?? []
  serviceEndpointSubnetResourceIds: config.?serviceEndpointSubnetResourceIds ?? []
}

// Recovery Services has no IP/subnet ACL equivalent. Never translate restricted public intent
// into unrestricted Backup public access without an explicit choice for a newly created vault.
func resolveBackupNetworking(config backupNetworkingType, publicAccess servicePublicNetworkAccessMode, privateEndpoint bool, created bool) resolvedBackupNetworkingType => {
  publicNetworkAccess: config.?publicNetworkAccess != null
    ? config.publicNetworkAccess!
    : created && publicAccess == 'EnabledWithRestrictions'
      ? fail('Restricted public connectivity requires an explicit paasNetworking.backup.publicNetworkAccess choice: Enabled or Disabled. Recovery Services vaults cannot enforce IP or service-endpoint subnet allowlists.')
      : publicAccess == 'Enabled' ? 'Enabled' : 'Disabled'
  privateEndpoint: config.?privateEndpoint ?? privateEndpoint
}

@export()
@description('Resolves omitted networking fields to private endpoints and disabled public access. Overrides preserve explicit false and independent service allowlists; only newly created resources require usable restricted-access inputs.')
func resolvePaasNetworking(config paasNetworkingType, storageCreated bool, keyVaultCreated bool, backupCreated bool) resolvedPaasNetworkingType => {
  storage: resolveServiceNetworking(config.?storage ?? {}, config.?publicNetworkAccess ?? 'Disabled', config.?privateEndpoint ?? true, storageCreated, 'Storage')
  keyVault: resolveServiceNetworking(config.?keyVault ?? {}, config.?publicNetworkAccess ?? 'Disabled', config.?privateEndpoint ?? true, keyVaultCreated, 'Key Vault')
  backup: resolveBackupNetworking(config.?backup ?? {}, config.?publicNetworkAccess ?? 'Disabled', config.?privateEndpoint ?? true, backupCreated)
  disk: {
    privateEndpoint: config.?disk.?privateEndpoint ?? config.?privateEndpoint ?? true
  }
}

@export()
@description('Resolves independent runtime Storage and Function App inbound policies for newly created infrastructure. Outbound integration and private endpoint placement remain separate inputs.')
func resolveFunctionAppNetworking(config functionAppPaasNetworkingType) {
  storage: resolvedServiceNetworkingType
  functionApp: resolvedServiceNetworkingType
} => {
  storage: resolveServiceNetworking(config.?storage ?? {}, config.?publicNetworkAccess ?? 'Disabled', config.?privateEndpoint ?? true, true, 'Storage')
  functionApp: resolveServiceNetworking(config.?functionApp ?? {}, config.?publicNetworkAccess ?? 'Disabled', config.?privateEndpoint ?? true, true, 'Function App')
}

@export()
@description('Requires an explicit subnet for applicable private endpoint consumers. Never falls back to public access or to the session-host subnet.')
func requirePrivateEndpointSubnet(id string, required bool, ownership string) string => required
  ? empty(trim(id))
    ? fail('privateEndpointSubnetResourceIds.${ownership} is required for the selected private endpoints.')
    : length(serviceEndpointSubnetIds([id])) == 1
      ? trim(id)
      : fail('privateEndpointSubnetResourceIds.${ownership} requires a complete subnet resource ID.')
  : id
