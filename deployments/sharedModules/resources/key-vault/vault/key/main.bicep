param keyVaultName string
param name string
param tags object = {}
param attributesEnabled bool = true
param attributesExp int = -1
param attributesNbf int = -1
param curveName string = 'P-256'
param attributesExportable bool = false
param keyOps array = []
param keySize int = -1
param kty string = 'EC'
param release_policy object = {}
param rotationPolicy object = {}

resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' existing = {
  name: keyVaultName
}

resource key 'Microsoft.KeyVault/vaults/keys@2022-07-01' = {
  name: name
  parent: keyVault
  tags: empty(tags) ? null : tags
  properties: {
    attributes: {
      enabled: attributesEnabled
      exportable: attributesExportable
      exp: attributesExp != -1 ? attributesExp : null
      nbf: attributesNbf != -1 ? attributesNbf : null
    }
    curveName: curveName
    keyOps: keyOps
    keySize: keySize != -1 ? keySize : null
    kty: kty
    release_policy: empty(release_policy) ? null : release_policy
    rotationPolicy: empty(rotationPolicy) ? null : rotationPolicy
  }
}

output name string = key.name
output resourceId string = key.id
