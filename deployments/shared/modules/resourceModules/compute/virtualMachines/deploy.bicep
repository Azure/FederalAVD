metadata name = 'Windows virtual machine'
metadata description = 'Deploys a Windows VM, its private NIC and OS disk, plus optional extensions. Requires an existing subnet and image; domain join and AVD registration are caller-supplied customizations.'

import { extensionType } from '../../types/computeTypes.bicep'

@description('Required. Name of the windows virtual machine to deploy.')
param name string
@description('Optional. Azure region for the windows virtual machine; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the windows virtual machine.')
param tags object = {}

@description('Optional. Azure VM size; must support the selected image, security settings and networking capabilities.')
param vmSize string = 'Standard_D4ads_v6'
@description('Required. Local administrator account name for the Windows VM.')
param adminUsername string
@secure()
@description('Required. Local administrator password for the Windows VM, passed as a secure value.')
param adminPassword string

@description('Required. Resource ID of the existing subnet used by the VM NIC.')
param subnetResourceId string
@description('Required. Name of the private network interface created for the VM.')
param nicName string
@description('Required. Name of the managed OS disk created from the selected image.')
param osDiskName string

@description('Optional. Custom image resource ID. Overrides imagePublisher/imageOffer/imageSku when provided.')
param customImageResourceId string = ''
@description('Optional. Marketplace image publisher, used only when no custom image resource ID is supplied.')
param imagePublisher string = 'MicrosoftWindowsDesktop'
@description('Optional. Marketplace image offer, used only when no custom image resource ID is supplied.')
param imageOffer string = 'windows-11'
@description('Optional. Marketplace image SKU; the latest version is used when no custom image resource ID is supplied.')
param imageSku string = 'win11-25h2-avd'

@allowed(['Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS', 'UltraSSD_LRS'])
@description('Optional. Storage account type for the managed OS disk; must be supported by the selected VM and image.')
param osDiskSku string = 'Premium_LRS'

@description('OS disk size in GB. 0 uses the image default.')
param osDiskSizeGB int = 0

@description('Optional. The disk controller type. When empty, Azure selects automatically based on the VM SKU.')
@allowed(['SCSI', 'NVMe', ''])
param diskControllerType string = ''

@description('Disk access resource ID for restricting disk network access.')
param diskAccessId string = ''

@description('Disk encryption set resource ID for customer-managed key encryption.')
param diskEncryptionSetResourceId string = ''

@description('Optional. Enable accelerated networking on the NIC; the consuming VM size and OS must support it.')
param enableAcceleratedNetworking bool = true
@description('Optional. Enable host-level VM encryption; the selected VM size must support it.')
param encryptionAtHost bool = true
@description('Optional. Enable VM hibernation capability; the selected VM size and image must support it.')
param hibernationEnabled bool = false

@allowed(['Standard', 'TrustedLaunch', 'ConfidentialVM'])
@description('Optional. VM security model; the image and VM size must support the selected model.')
param securityType string = 'TrustedLaunch'
@description('Optional. Enable Secure Boot when the VM security type is not Standard.')
param secureBootEnabled bool = true
@description('Optional. Enable the virtual TPM when the VM security type is not Standard.')
param vTpmEnabled bool = true

@description('Availability set resource ID. Empty = no availability set.')
param availabilitySetResourceId string = ''

@description('User-assigned managed identity resource IDs.')
param userAssignedIdentityResourceIds array = []

@description('VM extensions to install.')
param extensions extensionType[] = []

@description('Optional. Windows Server license type for Azure Hybrid Benefit.')
@allowed(['Windows_Server', 'Windows_Client', 'None'])
param licenseType string = 'None'

@description('Optional. Enable boot diagnostics with managed storage account.')
param bootDiagnosticsEnabled bool = true

@description('Optional. Enable system-assigned managed identity in addition to any user-assigned identities.')
param systemAssignedIdentity bool = false

var imageReference = !empty(customImageResourceId)
  ? { id: customImageResourceId }
  : {
      publisher: imagePublisher
      offer: imageOffer
      sku: imageSku
      version: 'latest'
    }

var securityProfile = securityType != 'Standard'
  ? {
      securityType: securityType
      uefiSettings: {
        secureBootEnabled: secureBootEnabled
        vTpmEnabled: vTpmEnabled
      }
      encryptionAtHost: encryptionAtHost
    }
  : { encryptionAtHost: encryptionAtHost }

var userAssignedIdentities = reduce(
  userAssignedIdentityResourceIds,
  {},
  (cur, id) => union(cur, { '${id}': {} })
)

var identityType = systemAssignedIdentity && !empty(userAssignedIdentityResourceIds)
  ? 'SystemAssigned, UserAssigned'
  : systemAssignedIdentity
      ? 'SystemAssigned'
      : !empty(userAssignedIdentityResourceIds)
          ? 'UserAssigned'
          : 'None'

resource networkInterface 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: enableAcceleratedNetworking
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetResourceId
          }
        }
      }
    ]
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: identityType
    userAssignedIdentities: !empty(userAssignedIdentityResourceIds) ? userAssignedIdentities : null
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    availabilitySet: !empty(availabilitySetResourceId)
      ? { id: availabilitySetResourceId }
      : null
    securityProfile: securityProfile
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        name: osDiskName
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: osDiskSku
          diskEncryptionSet: !empty(diskEncryptionSetResourceId)
            ? { id: diskEncryptionSetResourceId }
            : null
          securityProfile: securityType == 'ConfidentialVM'
            ? { securityEncryptionType: 'VMGuestStateOnly' }
            : null
        }
        diskSizeGB: osDiskSizeGB > 0 ? osDiskSizeGB : null
      }
      diskControllerType: empty(diskControllerType) ? null : diskControllerType
    }
    additionalCapabilities: hibernationEnabled
      ? { hibernationEnabled: true }
      : (!empty(diskAccessId) ? { ultraSSDEnabled: false } : null)
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: { deleteOption: 'Delete' }
        }
      ]
    }
    osProfile: {
      computerName: take(name, 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: false
        patchSettings: {
          patchMode: 'Manual'
        }
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: bootDiagnosticsEnabled
      }
    }
    licenseType: licenseType != 'None' ? licenseType : null
  }
}

resource vmExtensions 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [
  for ext in extensions: {
    parent: virtualMachine
    name: ext.name
    location: location
    tags: tags
    properties: {
      publisher: ext.publisher
      type: ext.type
      typeHandlerVersion: ext.typeHandlerVersion
      autoUpgradeMinorVersion: ext.?autoUpgradeMinorVersion ?? true
      enableAutomaticUpgrade: ext.?enableAutomaticUpgrade ?? false
      settings: ext.?settings ?? null
      protectedSettings: ext.?protectedSettings ?? null
    }
  }
]

@description('Resource ID of the windows virtual machine.')
output resourceId string = virtualMachine.id
@description('Azure resource name of the windows virtual machine.')
output name string = virtualMachine.name
@description('VM identity principal ID when systemAssignedIdentity is true or no user-assigned identities are supplied; otherwise an empty string.')
output principalId string = (systemAssignedIdentity || empty(userAssignedIdentityResourceIds)) ? virtualMachine.identity.principalId : ''
