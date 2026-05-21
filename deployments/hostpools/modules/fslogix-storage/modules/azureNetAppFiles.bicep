param activeDirectoryConnection bool
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param domainName string
param shareSizeInGB int
param location string
param deploymentVirtualMachineName string
param netAppAccountName string
param netAppCapacityPoolName string
param netAppVolumesSubnetResourceId string
param ouPath string
param resourceGroupDeployment string
param shares array
param shareAdminGroups array
param shareUserGroups array
param smbServerLocation string
param storageSku string
param tagsNetAppAccount object
param deploymentSuffix string

#disable-next-line BCP329
var ouRelativePath = contains(ouPath, 'DC') ? substring(split(ouPath, 'DC')[0], 0, length(split(ouPath, 'DC')[0]) - 1) : ouPath
var shareSizeInBytes = shareSizeInGB * 1024 * 1024 * 1024

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  scope: resourceGroup(split(netAppVolumesSubnetResourceId, '/')[2], split(netAppVolumesSubnetResourceId, '/')[4])
  name: split(netAppVolumesSubnetResourceId, '/')[8]
}

// ─── NetApp Account ────────────────────────────────────────────────────────────
module netAppAccount '../../../../../.common/bicepModules/netApp/netAppAccounts/deploy.bicep' = {
  name: 'NetAppAccount-${deploymentSuffix}'
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
module capacityPool '../../../../../.common/bicepModules/netApp/netAppAccounts/capacityPools/deploy.bicep' = {
  name: 'CapacityPool-${deploymentSuffix}'
  params: {
    netAppAccountName: netAppAccountName
    name: netAppCapacityPoolName
    location: location
    serviceLevel: storageSku
    tags: tagsNetAppAccount
  }
  dependsOn: [netAppAccount]
}

// ─── Volumes ───────────────────────────────────────────────────────────────────
module netAppVolumes '../../../../../.common/bicepModules/netApp/netAppAccounts/capacityPools/volumes/deploy.bicep' = [
  for i in range(0, length(shares)): {
    name: 'Volume-${shares[i]}-${deploymentSuffix}'
    params: {
      netAppAccountName: netAppAccountName
      capacityPoolName: netAppCapacityPoolName
      name: shares[i]
      location: location
      subnetResourceId: netAppVolumesSubnetResourceId
      usageThreshold: shareSizeInBytes
      serviceLevel: storageSku
      tags: tagsNetAppAccount
    }
    dependsOn: [capacityPool]
  }
]

var netappServerFqdns = length(shares) > 1
  ? [netAppVolumes[0].outputs.smbServerFqdn, netAppVolumes[1].outputs.smbServerFqdn]
  : [netAppVolumes[0].outputs.smbServerFqdn]

// ─── Set NTFS Permissions ──────────────────────────────────────────────────────
module setNTFSPermissions '../../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  name: 'Set-NTFSPermissions-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Set-NTFS-Permissions'
    location: location
    script: loadTextContent('../../../../../.common/scripts/Set-NtfsPermissionsNetApp.ps1')
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

output volumeResourceIds array = [for i in range(0, length(shares)): netAppVolumes[i].outputs.resourceId]
