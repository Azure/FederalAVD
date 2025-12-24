targetScope = 'subscription'

param netAppVolumeResourceId string

resource netAppAccount 'Microsoft.NetApp/netAppAccounts@2023-11-01' existing = {
  name: split(netAppVolumeResourceId, '/')[8]
  scope: resourceGroup(split(netAppVolumeResourceId, '/')[2], split(netAppVolumeResourceId, '/')[4])
  resource capacityPool 'capacityPools' existing = {
    name: split(netAppVolumeResourceId, '/')[10]
    resource volume 'volumes' existing = {
      name: last(split(netAppVolumeResourceId, '/'))
    }
  }      
}

output smbServerFqdn string = netAppAccount::capacityPool::volume.properties.mountTargets[0].smbServerFqdn
