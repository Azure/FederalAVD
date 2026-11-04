import { runCommandParameterType } from '../../../shared/modules/resourceModules/types/customizationTypes.bicep'

type runCommandSettingType = {
  name: string
  script: string
  parameters: runCommandParameterType[]
}

param diskName string
param imageVersionResourceId string
param keyVaultResourceId string
param licenseType string
param location string
param networkInterfaceName string
param privateIPAddress string
param subnetResourceId string
param userAssignedIdentityResourceId string
param virtualMachineName string
param virtualMachineSize string
param runCommandSettings runCommandSettingType[]

resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' existing = {
  scope: resourceGroup(split(keyVaultResourceId, '/')[2], split(keyVaultResourceId, '/')[4])
  name: last(split(keyVaultResourceId, '/'))
}

module virtualMachine 'virtualMachine.bicep' = {
  params: {
    diskName: diskName
    licenseType: licenseType
    imageVersionResourceId: imageVersionResourceId
    location: location
    networkInterfaceName: networkInterfaceName
    privateIPAddress: privateIPAddress
    runCommandSettings: runCommandSettings
    subnetResourceId: subnetResourceId
    tags: keyVault.tags
    userAssignedIdentityResourceId: userAssignedIdentityResourceId
    virtualMachineName: virtualMachineName
    virtualMachinePassword: keyVault.getSecret('LocalAdminPassword')
    virtualMachineSize: virtualMachineSize
    virtualMachineUsername: keyVault.getSecret('LocalAdminUsername')
  }
}
