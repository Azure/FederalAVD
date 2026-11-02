metadata name = 'FSLogix NetApp storage orchestration'
metadata description = 'Optionally creates a NetApp account and capacity pool, creates SMB volumes, and configures share permissions through an existing helper VM using supplied domain credentials.'

@description('Required. Whether to configure an Active Directory connection when creating the NetApp account.')
param activeDirectoryConnection bool
@description('Optional. Whether to create the NetApp account; when false, the named account must already exist.')
param createNetAppAccount bool = true
@description('Optional. Whether to create the NetApp capacity pool; when false, the named pool must already exist.')
param createNetAppCapacityPool bool = true
@secure()
@description('Required. Domain account password used when domain operations are selected; otherwise pass an empty string.')
param domainJoinUserPassword string
@secure()
@description('Required. Domain account UPN used when domain operations are selected; otherwise pass an empty string.')
param domainJoinUserPrincipalName string
@description('Required. DNS domain name for selected domain operations; otherwise pass an empty string.')
param domainName string
@description('Required. Quota per file share or NetApp volume in GiB.')
param shareSizeInGB int
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Name of the existing deployment helper VM used to execute storage or cleanup Run Commands.')
param deploymentVirtualMachineName string
@description('Required. Name of the NetApp account in the storage resource group; must already exist when account creation is disabled.')
param netAppAccountName string
@description('Required. Name of the NetApp capacity pool; must already exist when pool creation is disabled.')
param netAppCapacityPoolName string
@description('Required. Resource ID of the existing delegated subnet for NetApp volumes; its VNet supplies Active Directory DNS servers.')
param netAppVolumesSubnetResourceId string
@description('Required. Distinguished name of the target organizational unit for selected domain operations; empty uses the domain default.')
param ouPath string
@description('Required. Name of the existing resource group containing the deployment helper VM.')
param resourceGroupDeployment string
@description('Required. Array of NetApp volume/share name strings in profile-then-Office order.')
param shares array
@description('Required. Array of administrator group objects with id and name for Azure Files RBAC or NetApp/domain permissions.')
param shareAdminGroups array
@description('Required. Array of user group objects with id and name; the selected identity mode determines which field is forwarded.')
param shareUserGroups array
@description('Required. Location token appended to anf- for the NetApp Active Directory SMB server name.')
param smbServerLocation string
@description('Required. Storage tier: Standard or Premium for Azure Files, or the NetApp service level for NetApp volumes.')
param storageSku string
@description('Required. Tag name/value object applied to the NetApp account when created.')
param tagsNetAppAccount object
@description('Required. Tag name/value object applied to the capacity pool when created.')
param tagsNetAppCapacityPool object
@description('Required. Tag name/value object applied to every created NetApp volume.')
param tagsNetAppVolume object
#disable-next-line BCP329
var ouRelativePath = contains(ouPath, 'DC') ? substring(split(ouPath, 'DC')[0], 0, length(split(ouPath, 'DC')[0]) - 1) : ouPath
var shareSizeInBytes = shareSizeInGB * 1024 * 1024 * 1024

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  scope: resourceGroup(split(netAppVolumesSubnetResourceId, '/')[2], split(netAppVolumesSubnetResourceId, '/')[4])
  name: split(netAppVolumesSubnetResourceId, '/')[8]
}

// ─── NetApp Account ────────────────────────────────────────────────────────────
module netAppAccount '../../../resourceModules/netApp/netAppAccounts/deploy.bicep' = if (createNetAppAccount) {
  params: {
    name: netAppAccountName
    location: location
    tags: tagsNetAppAccount
    activeDirectory: activeDirectoryConnection
      ? {
          aesEncryption: true
          domain: domainName
          dns: string(vnet.properties.dhcpOptions.dnsServers)
          organizationalUnit: ouRelativePath
          password: domainJoinUserPassword
          smbServerName: 'anf-${smbServerLocation}'
          username: split(domainJoinUserPrincipalName, '@')[0]
        }
      : {}
  }
}

// ─── Capacity Pool ─────────────────────────────────────────────────────────────
module capacityPool '../../../resourceModules/netApp/netAppAccounts/capacityPools/deploy.bicep' = if (createNetAppCapacityPool) {
  params: {
    netAppAccountName: netAppAccountName
    name: netAppCapacityPoolName
    location: location
    serviceLevel: storageSku
    tags: tagsNetAppCapacityPool
  }
  dependsOn: [netAppAccount]
}

// ─── Volumes ───────────────────────────────────────────────────────────────────
module netAppVolumes '../../../resourceModules/netApp/netAppAccounts/capacityPools/volumes/deploy.bicep' = [
  for i in range(0, length(shares)): {
    params: {
      netAppAccountName: netAppAccountName
      capacityPoolName: netAppCapacityPoolName
      name: shares[i]
      location: location
      subnetResourceId: netAppVolumesSubnetResourceId
      usageThreshold: shareSizeInBytes
      serviceLevel: storageSku
      tags: tagsNetAppVolume
    }
    dependsOn: [capacityPool]
  }
]

var netappServerFqdns = length(shares) > 1
  ? [netAppVolumes[0].outputs.smbServerFqdn, netAppVolumes[1].outputs.smbServerFqdn]
  : [netAppVolumes[0].outputs.smbServerFqdn]

// ─── Set NTFS Permissions ──────────────────────────────────────────────────────
module setNTFSPermissions '../../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Set-NTFS-Permissions'
    location: location
    script: loadTextContent('../../../../scripts/Set-NtfsPermissionsNetApp.ps1')
    parameters: [
      { name: 'AdminGroupNames', value: string(map(shareAdminGroups, group => group.name)) }
      { name: 'NetAppServers', value: string(netappServerFqdns) }
      { name: 'Shares', value: string(shares) }
      { name: 'UserGroupNames', value: string(map(shareUserGroups, group => group.name)) }
    ]
    protectedParameters: [
      { name: 'DomainJoinUserPrincipalName', value: domainJoinUserPrincipalName }
      { name: 'DomainJoinUserPwd', value: domainJoinUserPassword }
    ]
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [netAppVolumes]
}

@description('Created NetApp volume resource IDs in the same order as shares.')
output volumeResourceIds array = [for i in range(0, length(shares)): netAppVolumes[i].outputs.resourceId]
@description('SMB server FQDN strings for the first share and, when present, the second share.')
output smbServerFqdns array = netappServerFqdns
