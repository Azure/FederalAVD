targetScope = 'subscription'

param resourceGroupName string
param keyVaultResourceId string
param keyManagementType string
param keyExpirationInDays int
param location string
param tags object = {}
param deploymentSuffix string
param paasKeyNames array
param paasIdentityName string

module cmk '../../../../.common/bicepModules/custom/customerManagedKeys/customerManagedKeys.bicep' = {
  name: 'PaaS-CMK-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    keyVaultResourceId: keyVaultResourceId
    keyManagementType: keyManagementType
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    deploymentSuffix: deploymentSuffix
    paasKeyNames: paasKeyNames
    paasIdentityName: paasIdentityName
  }
}

@description('Resource ID of the shared PaaS encryption user-assigned identity.')
output paasIdentityResourceId string = cmk.outputs.paasIdentityResourceId
