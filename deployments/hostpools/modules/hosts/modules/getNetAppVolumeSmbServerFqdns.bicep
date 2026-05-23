param localNetAppVolumeResourceIds array
param remoteNetAppVolumeResourceIds array
param shareNames array

// create new arrays that always contain the profile-containers volume as the first element.
var localNetAppProfileContainerVolumeResourceIds = !empty(localNetAppVolumeResourceIds)
  ? filter(localNetAppVolumeResourceIds, id => contains(id, shareNames[0]))
  : []
var localNetAppOfficeContainerVolumeResourceIds = !empty(localNetAppVolumeResourceIds) && length(shareNames) > 1
  ? filter(localNetAppVolumeResourceIds, id => contains(id, shareNames[1]))
  : []
var sortedLocalNetAppResourceIds = union(
  localNetAppProfileContainerVolumeResourceIds,
  localNetAppOfficeContainerVolumeResourceIds
)
var remoteNetAppProfileContainerVolumeResourceIds = !empty(remoteNetAppVolumeResourceIds)
  ? filter(remoteNetAppVolumeResourceIds, id => contains(id, shareNames[0]))
  : []
var remoteNetAppOfficeContainerVolumeResourceIds = !empty(remoteNetAppVolumeResourceIds) && length(shareNames) > 1
  ? filter(remoteNetAppVolumeResourceIds, id => !contains(id, shareNames[0]))
  : []
var sortedRemoteNetAppResourceIds = union(
  remoteNetAppProfileContainerVolumeResourceIds,
  remoteNetAppOfficeContainerVolumeResourceIds
)

resource localNetAppVolumes 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2023-11-01' existing = [for i in range(0, length(sortedLocalNetAppResourceIds)): {
  name: last(split(sortedLocalNetAppResourceIds[i], '/'))
  scope: resourceGroup(split(sortedLocalNetAppResourceIds[i], '/')[2], split(sortedLocalNetAppResourceIds[i], '/')[4])
}]

resource remoteNetAppVolumes 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2023-11-01' existing = [for i in range(0, length(sortedRemoteNetAppResourceIds)): {
  name: last(split(sortedRemoteNetAppResourceIds[i], '/'))
  scope: resourceGroup(split(sortedRemoteNetAppResourceIds[i], '/')[2], split(sortedRemoteNetAppResourceIds[i], '/')[4])
}]

output localNetAppVolumeSmbServerFqdns array = [for i in range(0, length(sortedLocalNetAppResourceIds)): localNetAppVolumes[i].properties.mountTargets[0].smbServerFqdn]  
output remoteNetAppVolumeSmbServerFqdns array = [for i in range(0, length(sortedRemoteNetAppResourceIds)): remoteNetAppVolumes[i].properties.mountTargets[0].smbServerFqdn]
