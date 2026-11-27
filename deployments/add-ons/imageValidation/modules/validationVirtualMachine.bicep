import { artifactCustomizationType } from '../../../shared/modules/orchestration/customizations/types.bicep'

param acceleratedNetworking bool = true
param artifactsContainerUri string = ''
param artifactsUserAssignedIdentityResourceId string = ''
param bootDiagnostics bool = true
param diskAccessResourceId string = ''
param diskControllerType string = 'SCSI'
param diskEncryptionSetResourceId string = ''
param diskName string
param diskNetworkAccess string = 'DenyAll'
param encryptionAtHost bool = true
param hibernation bool = false
param imageVersionResourceId string
param integrityMonitoring bool = true
param keyVaultResourceId string
param licenseType string = 'Windows_Client'
param location string = resourceGroup().location
param networkInterfaceName string
param privateIPAddress string
param secureBoot bool = true
param securityType string = 'TrustedLaunch'
param subnetResourceId string
param tags object = {}
param virtualMachineName string
param virtualMachineSize string
param vmCustomizations artifactCustomizationType[] = []
param vTpm bool = true

var integrityMonitoringValidation = integrityMonitoring && (!secureBoot || !vTpm) && securityType != 'Standard'
  ? fail('Integrity monitoring requires Secure Boot and vTPM to be enabled.')
  : integrityMonitoring

resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' existing = {
  scope: resourceGroup(split(keyVaultResourceId, '/')[2], split(keyVaultResourceId, '/')[4])
  name: last(split(keyVaultResourceId, '/'))
}

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = if (!empty(artifactsUserAssignedIdentityResourceId)) {
  scope: resourceGroup(split(artifactsUserAssignedIdentityResourceId, '/')[2], split(artifactsUserAssignedIdentityResourceId, '/')[4])
  name: last(split(artifactsUserAssignedIdentityResourceId, '/'))
}

module virtualMachine '../../../shared/modules/resourceModules/compute/virtualMachines/deploy.bicep' = {
  params: {
    adminPassword: keyVault.getSecret('LocalAdminPassword')
    adminUsername: keyVault.getSecret('LocalAdminUsername')
    bootDiagnosticsEnabled: bootDiagnostics
    customImageResourceId: imageVersionResourceId
    diskAccessId: diskAccessResourceId
    diskControllerType: diskControllerType
    //diskNetworkAccess: diskNetworkAccess // Add this setting once all clouds support 2026-04-01 or later
    diskEncryptionSetResourceId: diskEncryptionSetResourceId
    enableAcceleratedNetworking: acceleratedNetworking
    encryptionAtHost: encryptionAtHost
    hibernationEnabled: hibernation
    licenseType: licenseType
    location: location
    name: virtualMachineName
    nicDeleteOption: 'Detach'
    nicName: networkInterfaceName
    nicPrivateIPAddress: privateIPAddress
    nicPrivateIPAllocationMethod: 'Static'
    osDiskName: diskName
    secureBootEnabled: secureBoot
    securityType: securityType
    subnetResourceId: subnetResourceId
    tags: tags
    userAssignedIdentityResourceIds: empty(artifactsUserAssignedIdentityResourceId) ? [] : [
      artifactsUserAssignedIdentityResourceId
    ]
    vmSize: virtualMachineSize
    vTpmEnabled: vTpm
  }
}

module extension_GuestAttestation '../../../shared/modules/resourceModules/compute/virtualMachines/extensions/guestAttestation.bicep' = if (securityType != 'Standard' && integrityMonitoringValidation) {
  params: {
    location: location
    tags: tags
    virtualMachineName: virtualMachine.outputs.name
  }
}

module customizations '../../../shared/modules/orchestration/sessionHosts/invokeCustomizations.bicep' = if (!empty(artifactsUserAssignedIdentityResourceId) && !empty(vmCustomizations)) {
  params: {
    artifactsContainerUri: artifactsContainerUri
    customizations: vmCustomizations
    userAssignedIdentityClientId: userAssignedIdentity!.properties.clientId
    virtualMachineName: virtualMachineName
  }
  dependsOn: [
    virtualMachine
  ]
}
