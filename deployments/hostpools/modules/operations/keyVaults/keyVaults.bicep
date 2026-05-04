targetScope = 'subscription'

// Inline Key Vault fallback for the hostpool Complete deployment.
// Delegates all logic to the shared keyVaults module in .common, keeping the
// KV resource group and naming identical to the standalone Security deployment.

param azureKeyVaultPrivateDnsZoneResourceId string
param deploySecretsKeyVault bool
param encryptionKeyVaultName string
param deployEncryptionKeyVault bool
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
#disable-next-line secure-secrets-in-params
param secretsKeyVaultName string
param keyVaultEnableSoftDelete bool
param keyVaultEnablePurgeProtection bool
param keyVaultRetentionInDays int
param logAnalyticsWorkspaceResourceId string
param privateEndpointSubnetResourceId string
param privateEndpoint bool
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param resourceGroupSecurity string
param tags object
param deploymentSuffix string
@secure()
param virtualMachineAdminPassword string
@secure()
param virtualMachineAdminUserName string

module keyVaults '../../../../../.common/bicepModules/custom/keyVaults/keyVaults.bicep' = {
  name: 'KeyVaults-${deploymentSuffix}'
  scope: subscription()
  params: {
    resourceGroupName: resourceGroupSecurity
    deploySecretsKeyVault: deploySecretsKeyVault
    secretsKeyVaultName: secretsKeyVaultName
    keyVaultEnableSoftDelete: keyVaultEnableSoftDelete
    keyVaultEnablePurgeProtection: keyVaultEnablePurgeProtection
    keyVaultRetentionInDays: keyVaultRetentionInDays
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    virtualMachineAdminPassword: virtualMachineAdminPassword
    virtualMachineAdminUserName: virtualMachineAdminUserName
    deployEncryptionKeyVault: deployEncryptionKeyVault
    encryptionKeyVaultName: encryptionKeyVaultName
    privateEndpoint: privateEndpoint
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    azureKeyVaultPrivateDnsZoneResourceId: azureKeyVaultPrivateDnsZoneResourceId
    privateEndpointNameConv: privateEndpointNameConv
    privateEndpointNICNameConv: privateEndpointNICNameConv
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    tags: tags
    deploymentSuffix: deploymentSuffix
  }
}

output encryptionKeyVaultResourceId string = keyVaults.outputs.encryptionKeyVaultResourceId
output encryptionKeyVaultUri string = keyVaults.outputs.encryptionKeyVaultUri
