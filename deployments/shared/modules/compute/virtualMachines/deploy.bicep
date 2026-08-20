import { extensionType } from '../../types/computeTypes.bicep'

param name string
param location string = resourceGroup().location
param tags object = {}

param vmSize string = 'Standard_D4ads_v6'
param adminUsername string
@secure()
param adminPassword string

param subnetResourceId string
param nicName string
param osDiskName string

@description('Optional. Custom image resource ID. Overrides imagePublisher/imageOffer/imageSku when provided.')
param customImageResourceId string = ''
param imagePublisher string = 'MicrosoftWindowsDesktop'
param imageOffer string = 'windows-11'
param imageSku string = 'win11-25h2-avd'

@allowed(['Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS', 'UltraSSD_LRS'])
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

param enableAcceleratedNetworking bool = true
param encryptionAtHost bool = true
param hibernationEnabled bool = false

@allowed(['Standard', 'TrustedLaunch', 'ConfidentialVM'])
param securityType string = 'TrustedLaunch'
param secureBootEnabled bool = true
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

output resourceId string = virtualMachine.id
output name string = virtualMachine.name
output principalId string = (systemAssignedIdentity || empty(userAssignedIdentityResourceIds)) ? virtualMachine.identity.principalId : ''
