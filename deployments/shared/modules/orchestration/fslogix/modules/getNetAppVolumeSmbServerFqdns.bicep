metadata name = 'NetApp SMB endpoint lookup'
metadata description = 'Reads the first mount-target SMB FQDN for existing local and remote NetApp volumes across resource groups, enforcing one volume per share in each nonempty input array.'

targetScope = 'subscription'

@description('Required. Existing local NetApp volume IDs; empty or one per enabled container in Profile-then-Office order.')
param localNetAppVolumeResourceIds array
@description('Required. Existing remote NetApp volume IDs; empty or one per enabled container in Profile-then-Office order.')
param remoteNetAppVolumeResourceIds array
@description('Required. FSLogix container selection used to validate Profile-then-Office volume counts.')
param fslogixContainerType string

// Each provided NetApp volume array must align with the enabled container roles by index.
// For Profile+Office scenarios, index 0 is profile and index 1 is office.
// Calculate the count directly to avoid importing a share-name function just to measure its array.
var shareCount = contains(fslogixContainerType, 'Office') ? 2 : 1
var volumeCountsAreValid = (empty(localNetAppVolumeResourceIds) || length(localNetAppVolumeResourceIds) == shareCount) && (empty(remoteNetAppVolumeResourceIds) || length(remoteNetAppVolumeResourceIds) == shareCount)
  ? true
  : fail('Existing Azure NetApp Files volume arrays must contain one volume per FSLogix share, in profile-then-Office order.')

resource localNetAppVolumes 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2023-11-01' existing = [for volumeId in (volumeCountsAreValid ? localNetAppVolumeResourceIds : []): {
  name: '${split(volumeId, '/')[8]}/${split(volumeId, '/')[10]}/${split(volumeId, '/')[12]}'
  scope: resourceGroup(split(volumeId, '/')[2], split(volumeId, '/')[4])
}]

resource remoteNetAppVolumes 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2023-11-01' existing = [for volumeId in (volumeCountsAreValid ? remoteNetAppVolumeResourceIds : []): {
  name: '${split(volumeId, '/')[8]}/${split(volumeId, '/')[10]}/${split(volumeId, '/')[12]}'
  scope: resourceGroup(split(volumeId, '/')[2], split(volumeId, '/')[4])
}]

@description('First mount-target SMB FQDN per local volume, preserving input order; empty when no local volumes are supplied.')
output localNetAppVolumeSmbServerFqdns array = [for i in range(0, volumeCountsAreValid ? length(localNetAppVolumeResourceIds) : 0): localNetAppVolumes[i].properties.mountTargets[0].smbServerFqdn]
@description('First mount-target SMB FQDN per remote volume, preserving input order; empty when no remote volumes are supplied.')
output remoteNetAppVolumeSmbServerFqdns array = [for i in range(0, volumeCountsAreValid ? length(remoteNetAppVolumeResourceIds) : 0): remoteNetAppVolumes[i].properties.mountTargets[0].smbServerFqdn]
