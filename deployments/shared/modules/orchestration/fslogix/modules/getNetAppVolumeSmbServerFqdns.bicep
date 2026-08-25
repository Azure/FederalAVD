targetScope = 'subscription'

param localNetAppVolumeResourceIds array
param remoteNetAppVolumeResourceIds array
param shareNames array

var volumeCountsAreValid = (empty(localNetAppVolumeResourceIds) || length(localNetAppVolumeResourceIds) == length(shareNames)) && (empty(remoteNetAppVolumeResourceIds) || length(remoteNetAppVolumeResourceIds) == length(shareNames))
  ? true
  : bool('Existing Azure NetApp Files volume arrays must contain one volume per FSLogix share, in profile-then-Office order.')
var orderedLocalNetAppResourceIds = volumeCountsAreValid ? localNetAppVolumeResourceIds : localNetAppVolumeResourceIds
var orderedRemoteNetAppResourceIds = volumeCountsAreValid ? remoteNetAppVolumeResourceIds : remoteNetAppVolumeResourceIds

resource localNetAppVolumes 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2023-11-01' existing = [for i in range(0, length(orderedLocalNetAppResourceIds)): {
  name: last(split(orderedLocalNetAppResourceIds[i], '/'))
  scope: resourceGroup(split(orderedLocalNetAppResourceIds[i], '/')[2], split(orderedLocalNetAppResourceIds[i], '/')[4])
}]

resource remoteNetAppVolumes 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2023-11-01' existing = [for i in range(0, length(orderedRemoteNetAppResourceIds)): {
  name: last(split(orderedRemoteNetAppResourceIds[i], '/'))
  scope: resourceGroup(split(orderedRemoteNetAppResourceIds[i], '/')[2], split(orderedRemoteNetAppResourceIds[i], '/')[4])
}]

output localNetAppVolumeSmbServerFqdns array = [for i in range(0, length(orderedLocalNetAppResourceIds)): localNetAppVolumes[i].properties.mountTargets[0].smbServerFqdn]
output remoteNetAppVolumeSmbServerFqdns array = [for i in range(0, length(orderedRemoteNetAppResourceIds)): remoteNetAppVolumes[i].properties.mountTargets[0].smbServerFqdn]
