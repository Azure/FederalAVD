param galleryName string
param imageDefinitionName string
param versionName string
param sourceVmId string
param defaultReplicaCount int
param excludedFromLatest bool
param regionReplications array = [
  {
    name: 'eastus2'
    regionalReplicaCount: 1
    storageAccountType: 'Standard_ZRS'
    encryption: {
      osDiskImage: {
        securityProfile: {
          confidentialVMEncryptionType: 'EncryptedVMGuestStateOnlyWithPmk'
        }
      }
    }
  }
]
param location string
param replicationMode string

resource galleryName_imageDefinitionName_version 'Microsoft.Compute/galleries/images/versions@2023-07-03' = {
  name: '${galleryName}/${imageDefinitionName}/${versionName}'
  location: location
  properties: {
    publishingProfile: {
      replicaCount: defaultReplicaCount
      targetRegions: regionReplications
      excludeFromLatest: excludedFromLatest
      replicationMode: replicationMode
    }
    storageProfile: {
      source: {
        virtualMachineId: sourceVmId
      }
    }
  }
  tags: {}
  dependsOn: []
}
