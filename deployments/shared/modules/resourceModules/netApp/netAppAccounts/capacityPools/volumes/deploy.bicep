metadata name = 'NetApp volume'
metadata description = 'Deploys a volume under an existing NetApp capacity pool using an existing delegated subnet. SMB requires account-level Active Directory setup; the module returns the first mount target SMB FQDN.'

@description('Required. Name of the existing parent NetApp account in the deployment resource group.')
param netAppAccountName string
@description('Required. Name of the existing parent capacity pool within the selected NetApp account.')
param capacityPoolName string
@description('Required. Name of the netApp volume within its parent resource.')
param name string
@description('Optional. Azure region for the netApp volume; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the netApp volume.')
param tags object = {}

@description('Resource ID of the delegated subnet.')
param subnetResourceId string

@description('Provisioned quota in bytes (e.g. 107374182400 = 100 GiB).')
param usageThreshold int

@allowed(['Premium', 'Standard', 'Ultra'])
@description('Optional. NetApp service level; must be compatible with the selected account or capacity pool.')
param serviceLevel string = 'Standard'

@allowed(['NFSv3', 'NFSv4.1', 'CIFS'])
@description('Optional. Volume protocol; CIFS requires Active Directory configuration on the parent NetApp account.')
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

@description('Resource ID of the netApp volume.')
output resourceId string = volume.id
@description('Azure resource name of the netApp volume.')
output name string = volume.name
@description('SMB server FQDN from the first volume mount target; intended for CIFS consumers.')
output smbServerFqdn string = volume.properties.mountTargets[0].smbServerFqdn
