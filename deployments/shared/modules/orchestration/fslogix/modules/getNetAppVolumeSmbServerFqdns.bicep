targetScope = 'subscription'

param localNetAppVolumeResourceIds array
param remoteNetAppVolumeResourceIds array
param shareNames array

// Contract: each provided NetApp volume array must align 1:1 with shareNames by index.
// For Profile+Office scenarios, index 0 is profile and index 1 is office.
var volumeCountsAreValid = (empty(localNetAppVolumeResourceIds) || length(localNetAppVolumeResourceIds) == length(shareNames)) && (empty(remoteNetAppVolumeResourceIds) || length(remoteNetAppVolumeResourceIds) == length(shareNames))
  ? true
  : fail('Existing Azure NetApp Files volume arrays must contain one volume per FSLogix share, in profile-then-Office order.')

resource localNetAppVolumes 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2023-11-01' existing = [for i in range(0, volumeCountsAreValid ? length(localNetAppVolumeResourceIds) : 0): {
  name: last(split(localNetAppVolumeResourceIds[i], '/'))
  scope: resourceGroup(split(localNetAppVolumeResourceIds[i], '/')[2], split(localNetAppVolumeResourceIds[i], '/')[4])
}]

resource remoteNetAppVolumes 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2023-11-01' existing = [for i in range(0, volumeCountsAreValid ? length(remoteNetAppVolumeResourceIds) : 0): {
  name: last(split(remoteNetAppVolumeResourceIds[i], '/'))
  scope: resourceGroup(split(remoteNetAppVolumeResourceIds[i], '/')[2], split(remoteNetAppVolumeResourceIds[i], '/')[4])
}]

output localNetAppVolumeSmbServerFqdns array = [for i in range(0, volumeCountsAreValid ? length(localNetAppVolumeResourceIds) : 0): localNetAppVolumes[i].properties.mountTargets[0].smbServerFqdn]
output remoteNetAppVolumeSmbServerFqdns array = [for i in range(0, volumeCountsAreValid ? length(remoteNetAppVolumeResourceIds) : 0): remoteNetAppVolumes[i].properties.mountTargets[0].smbServerFqdn]
