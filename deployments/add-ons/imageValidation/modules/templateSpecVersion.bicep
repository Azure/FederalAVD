import { artifactCustomizationType } from '../../../shared/modules/resourceModules/types/customizationTypes.bicep'

param artifactsContainerUri string = ''
param artifactsUserAssignedIdentityClientId string = ''
param bootDiagnosticsEnabled bool = true
param diskAccessResourceId string = ''
param diskControllerType string = 'SCSI'
param diskEncryptionSetResourceId string = ''
param diskName string
param enableAcceleratedNetworking bool = true
param encryptionAtHost bool = true
param hibernationEnabled bool = false
param imageVersionResourceId string
param keyVaultResourceId string
param licenseType string = 'Windows_Client'
param location string = resourceGroup().location
param networkInterfaceName string
param privateIPAddress string
param secureBootEnabled bool = true
param securityType string = 'TrustedLaunch'
param subnetResourceId string
param tags object = {}
param userAssignedIdentityResourceIds array = []
param virtualMachineName string
param virtualMachineSize string
param vmCustomizations artifactCustomizationType[] = []
param vTpmEnabled bool = true

resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' existing = {
  scope: resourceGroup(split(keyVaultResourceId, '/')[2], split(keyVaultResourceId, '/')[4])
  name: last(split(keyVaultResourceId, '/'))
}

module virtualMachine '../../../shared/modules/resourceModules/compute/virtualMachines/deploy.bicep' = {
  params: {
    adminPassword: keyVault.getSecret('LocalAdminPassword')
    adminUsername: keyVault.getSecret('LocalAdminUsername')
    bootDiagnosticsEnabled: bootDiagnosticsEnabled
    customImageResourceId: imageVersionResourceId
    diskAccessId: diskAccessResourceId
    diskControllerType: diskControllerType
    diskEncryptionSetResourceId: diskEncryptionSetResourceId
    enableAcceleratedNetworking: enableAcceleratedNetworking
    encryptionAtHost: encryptionAtHost
    hibernationEnabled: hibernationEnabled
    licenseType: licenseType
    location: location
    name: virtualMachineName
    nicDeleteOption: 'Detach'
    nicName: networkInterfaceName
    nicPrivateIPAddress: privateIPAddress
    nicPrivateIPAllocationMethod: 'Static'
    osDiskName: diskName
    secureBootEnabled: secureBootEnabled
    securityType: securityType
    subnetResourceId: subnetResourceId
    tags: tags
    userAssignedIdentityResourceIds: userAssignedIdentityResourceIds
    vmSize: virtualMachineSize
    vTpmEnabled: vTpmEnabled
  }
}

module customizations '../../../shared/modules/orchestration/sessionHosts/invokeCustomizations.bicep' = {
  params: {
    artifactsContainerUri: artifactsContainerUri
    customizations: vmCustomizations
    userAssignedIdentityClientId: artifactsUserAssignedIdentityClientId
    virtualMachineName: virtualMachineName
  }
  dependsOn: [
    virtualMachine
  ]
}
