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
param storageSolution string
param tagsNetAppAccount object
param timeStamp string

#disable-next-line BCP329
var ouRelativePath = contains(ouPath, 'DC') ? substring(split(ouPath, 'DC')[0], 0, length(split(ouPath, 'DC')[0]) - 1) : ouPath
var shareSizeInBytes = shareSizeInGB * 1024 * 1024 * 1024

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  scope: resourceGroup(split(netAppVolumesSubnetResourceId, '/')[2], split(netAppVolumesSubnetResourceId, '/')[4])
  name: split(netAppVolumesSubnetResourceId, '/')[8]
}

resource netAppAccount 'Microsoft.NetApp/netAppAccounts@2021-06-01' = {
  name: netAppAccountName
  location: location
  tags: tagsNetAppAccount
  properties: {
    activeDirectories: activeDirectoryConnection ? [
      {
        aesEncryption: true
        domain: domainName
        dns: string(vnet.properties.dhcpOptions.dnsServers)
        organizationalUnit: ouRelativePath
        password: domainJoinUserPassword
        smbServerName: 'anf-${smbServerLocation}'
        username: split(domainJoinUserPrincipalName, '@')[0]
      }
    ] : null
    encryption: {
      keySource: 'Microsoft.NetApp'
    }
  }
}

resource capacityPool 'Microsoft.NetApp/netAppAccounts/capacityPools@2021-06-01' = {
  parent: netAppAccount
  name: netAppCapacityPoolName
  location: location
  tags: tagsNetAppAccount
  properties: {
    coolAccess: false
    encryptionType: 'Single'
    qosType: 'Auto'
    serviceLevel: storageSku
    size: 4398046511104
  }
}

resource volumes 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2021-06-01' = [for i in range(0, length(shares)): {
  parent: capacityPool
  name: shares[i]
  location: location
  tags: tagsNetAppAccount
  properties: {
    avsDataStore: 'Disabled'
    // backupId: 'string'
    coolAccess: false
    // coolnessPeriod: int
    creationToken: shares[i]
    // dataProtection: {
    //   backup: {
    //     backupEnabled: bool
    //     backupPolicyId: 'string'
    //     policyEnforced: bool
    //     vaultId: 'string'
    //   }
    //   replication: {
    //     endpointType: 'string'
    //     remoteVolumeRegion: 'string'
    //     remoteVolumeResourceId: 'string'
    //     replicationId: 'string'
    //     replicationSchedule: 'string'
    //   }
    //   snapshot: {
    //     snapshotPolicyId: 'string'
    //   }
    // }
    defaultGroupQuotaInKiBs: 0
    defaultUserQuotaInKiBs: 0
    encryptionKeySource: 'Microsoft.NetApp'
    // exportPolicy: {
    //   rules: [
    //     {
    //       allowedClients: 'string'
    //       chownMode: 'string'
    //       cifs: bool
    //       hasRootAccess: bool
    //       kerberos5iReadWrite: bool
    //       kerberos5pReadWrite: bool
    //       kerberos5ReadWrite: bool
    //       nfsv3: bool
    //       nfsv41: bool
    //       ruleIndex: int
    //       unixReadWrite: bool
    //     }
    //   ]
    // }
    isDefaultQuotaEnabled: false
    // isRestoring: bool
    kerberosEnabled: false
    ldapEnabled: false
    networkFeatures: 'Standard'
    protocolTypes: [
      'CIFS'
    ]
    securityStyle: 'ntfs'
    serviceLevel: storageSku
    smbContinuouslyAvailable: true // recommended for FSLogix: https://docs.microsoft.com/en-us/azure/azure-netapp-files/enable-continuous-availability-existing-smb
    smbEncryption: true
    snapshotDirectoryVisible: true
    // snapshotId: 'string'
    subnetId: netAppVolumesSubnetResourceId
    // throughputMibps: int
    // unixPermissions: 'string'
    usageThreshold: shareSizeInBytes
    // volumeType: 'string'
  }
}]

var netappServerFqdns = length(shares) > 1 ? [
  volumes[0].properties.mountTargets[0].smbServerFqdn
  volumes[1].properties.mountTargets[0].smbServerFqdn
] : [
  volumes[0].properties.mountTargets[0].smbServerFqdn
]

module SetNTFSPermissions 'domainJoinSetNTFSPermissions.bicep' = {
  name: 'Set-NTFSPermissions_${timeStamp}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    adminGroupNames: map(shareAdminGroups, group => group.displayName)  
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    domainJoinUserPassword: domainJoinUserPassword
    location: location  
    netAppServers: netappServerFqdns
    shardingOptions: 'None'
    shares: shares
    storageSolution: storageSolution
    timeStamp: timeStamp
    userGroupNames: map(shareUserGroups, group => group.displayName)
    virtualMachineName: deploymentVirtualMachineName
  }
  dependsOn: [
    volumes
  ]
}

output volumeResourceIds array = [for i in range(0, length(shares)): volumes[i].id]
