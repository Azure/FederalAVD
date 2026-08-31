param netAppAccountName string
param capacityPoolName string
param name string
param location string = resourceGroup().location
param tags object = {}

@description('Resource ID of the delegated subnet.')
param subnetResourceId string

@description('Provisioned quota in bytes (e.g. 107374182400 = 100 GiB).')
param usageThreshold int

@allowed(['Premium', 'Standard', 'Ultra'])
param serviceLevel string = 'Standard'

@allowed(['NFSv3', 'NFSv4.1', 'CIFS'])
param protocolType string = 'CIFS'

@description('Volume creation token, used in the NFS/SMB path. Defaults to the volume name.')
param creationToken string = name

resource netAppAccount 'Microsoft.NetApp/netAppAccounts@2023-07-01' existing = {
  name: netAppAccountName
}

resource capacityPool 'Microsoft.NetApp/netAppAccounts/capacityPools@2023-07-01' existing = {
  parent: netAppAccount
  name: capacityPoolName
}

resource volume 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2023-07-01' = {
  parent: capacityPool
  name: name
  location: location
  tags: tags
  properties: {
    creationToken: creationToken
    serviceLevel: serviceLevel
    usageThreshold: usageThreshold
    subnetId: subnetResourceId
    protocolTypes: [protocolType]
  }
}

output resourceId string = volume.id
output name string = volume.name
output smbServerFqdn string = volume.properties.mountTargets[0].smbServerFqdn
