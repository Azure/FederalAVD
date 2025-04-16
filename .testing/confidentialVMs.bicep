param vaults_kv_confvm_name string = 'kv-confvm'
param virtualMachines_confVm3_name string = 'confVm3'
param virtualMachines_confvmtest_name string = 'confvmtest'
param virtualMachines_confvmtest2_name string = 'confvmtest2'
param networkInterfaces_confvm3238_name string = 'confvm3238'
param diskEncryptionSets_des_confvm_name string = 'des-confvm'
param networkInterfaces_confvmtest255_name string = 'confvmtest255'
param networkInterfaces_confvmtest2498_name string = 'confvmtest2498'
param virtualNetworks_vnet_avd_use2_externalid string = '/subscriptions/67edfd17-f0d1-466a-aacb-ca9daeabb9b8/resourceGroups/rg-avd-networking-use2/providers/Microsoft.Network/virtualNetworks/vnet-avd-use2'

resource vaults_kv_confvm_name_resource 'Microsoft.KeyVault/vaults@2024-12-01-preview' = {
  name: vaults_kv_confvm_name
  location: 'eastus2'
  properties: {
    sku: {
      family: 'A'
      name: 'Premium'
    }
    tenantId: '46856615-1aee-4ade-b52c-00116107c075'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Allow'
      ipRules: []
      virtualNetworkRules: []
    }
    accessPolicies: []
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enableRbacAuthorization: true
    enablePurgeProtection: true
    vaultUri: 'https://${vaults_kv_confvm_name}.vault.azure.net/'
    provisioningState: 'Succeeded'
    publicNetworkAccess: 'Enabled'
  }
}

resource networkInterfaces_confvm3238_name_resource 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: networkInterfaces_confvm3238_name
  location: 'eastus2'
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        type: 'Microsoft.Network/networkInterfaces/ipConfigurations'
        properties: {
          privateIPAddress: '10.0.2.168'
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${virtualNetworks_vnet_avd_use2_externalid}/subnets/snet-avd-auto-hosts'
          }
          primary: true
          privateIPAddressVersion: 'IPv4'
        }
      }
    ]
    dnsSettings: {
      dnsServers: []
    }
    enableAcceleratedNetworking: false
    enableIPForwarding: false
    disableTcpStateTracking: false
    nicType: 'Standard'
    auxiliaryMode: 'None'
    auxiliarySku: 'None'
  }
}

resource networkInterfaces_confvmtest2498_name_resource 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: networkInterfaces_confvmtest2498_name
  location: 'eastus2'
  kind: 'Regular'
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        id: '${networkInterfaces_confvmtest2498_name_resource.id}/ipConfigurations/ipconfig1'
        type: 'Microsoft.Network/networkInterfaces/ipConfigurations'
        properties: {
          privateIPAddress: '10.0.2.167'
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${virtualNetworks_vnet_avd_use2_externalid}/subnets/snet-avd-auto-hosts'
          }
          primary: true
          privateIPAddressVersion: 'IPv4'
        }
      }
    ]
    dnsSettings: {
      dnsServers: []
    }
    enableAcceleratedNetworking: false
    enableIPForwarding: false
    disableTcpStateTracking: false
    nicType: 'Standard'
    auxiliaryMode: 'None'
    auxiliarySku: 'None'
  }
}

resource networkInterfaces_confvmtest255_name_resource 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: networkInterfaces_confvmtest255_name
  location: 'eastus2'
  kind: 'Regular'
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        id: '${networkInterfaces_confvmtest255_name_resource.id}/ipConfigurations/ipconfig1'
        type: 'Microsoft.Network/networkInterfaces/ipConfigurations'
        properties: {
          privateIPAddress: '10.0.2.10'
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${virtualNetworks_vnet_avd_use2_externalid}/subnets/snet-avd-marketplace-hosts'
          }
          primary: true
          privateIPAddressVersion: 'IPv4'
        }
      }
    ]
    dnsSettings: {
      dnsServers: []
    }
    enableAcceleratedNetworking: false
    enableIPForwarding: false
    disableTcpStateTracking: false
    nicType: 'Standard'
    auxiliaryMode: 'None'
    auxiliarySku: 'None'
  }
}

resource diskEncryptionSets_des_confvm_name_resource 'Microsoft.Compute/diskEncryptionSets@2024-03-02' = {
  name: diskEncryptionSets_des_confvm_name
  location: 'eastus2'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    activeKey: {
      sourceVault: {
        id: vaults_kv_confvm_name_resource.id
      }
      keyUrl: 'https://kv-confvm.vault.azure.net/keys/confvm-key/bfcf4be716664f9db64affdd687d737c'
    }
    encryptionType: 'ConfidentialVmEncryptedWithCustomerKey'
  }
}

resource virtualMachines_confVm3_name_resource 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: virtualMachines_confVm3_name
  location: 'eastus2'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_DC2eds_v5'
    }
    additionalCapabilities: {
      hibernationEnabled: false
    }
    storageProfile: {
      imageReference: {
        publisher: 'microsoftwindowsdesktop'
        offer: 'windows-11'
        sku: 'win11-24h2-avd'
        version: 'latest'
      }
      osDisk: {
        osType: 'Windows'
        name: '${virtualMachines_confVm3_name}_OsDisk_1_845f82ef204c4af4bef1a9c559c8a4ad'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          securityProfile: {
            securityEncryptionType: 'VMGuestStateOnly'
          }
          storageAccountType: 'Premium_LRS'
          id: resourceId(
            'Microsoft.Compute/disks',
            '${virtualMachines_confVm3_name}_OsDisk_1_845f82ef204c4af4bef1a9c559c8a4ad'
          )
        }
        deleteOption: 'Delete'
        diskSizeGB: 127
      }
      dataDisks: []
      diskControllerType: 'SCSI'
    }
    osProfile: {
      computerName: virtualMachines_confVm3_name
      adminUsername: 'vmadmin'
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
          assessmentMode: 'ImageDefault'
          enableHotpatching: false
        }
      }
      secrets: []
      allowExtensionOperations: true
      requireGuestProvisionSignal: true
    }
    securityProfile: {
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
      encryptionAtHost: true
      securityType: 'ConfidentialVM'
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterfaces_confvm3238_name_resource.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    licenseType: 'Windows_Client'
  }
}

resource virtualMachines_confvmtest_name_resource 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: virtualMachines_confvmtest_name
  location: 'eastus2'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_DC2eds_v5'
    }
    additionalCapabilities: {
      hibernationEnabled: false
    }
    storageProfile: {
      imageReference: {
        publisher: 'microsoftwindowsdesktop'
        offer: 'windows-11'
        sku: 'win11-24h2-avd'
        version: 'latest'
      }
      osDisk: {
        osType: 'Windows'
        name: '${virtualMachines_confvmtest_name}_OsDisk_1_8dd495e86e2a41c3a441507d75ce4caf'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          securityProfile: {
            securityEncryptionType: 'DiskWithVMGuestState'
          }
          storageAccountType: 'Premium_LRS'
          id: resourceId(
            'Microsoft.Compute/disks',
            '${virtualMachines_confvmtest_name}_OsDisk_1_8dd495e86e2a41c3a441507d75ce4caf'
          )
        }
        deleteOption: 'Delete'
        diskSizeGB: 127
      }
      dataDisks: []
      diskControllerType: 'SCSI'
    }
    osProfile: {
      computerName: virtualMachines_confvmtest_name
      adminUsername: 'vmadmin'
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
          assessmentMode: 'ImageDefault'
          enableHotpatching: false
        }
      }
      secrets: []
      allowExtensionOperations: true
      requireGuestProvisionSignal: true
    }
    securityProfile: {
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
      encryptionAtHost: true
      securityType: 'ConfidentialVM'
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterfaces_confvmtest255_name_resource.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    licenseType: 'Windows_Client'
  }
}

resource vaults_kv_confvm_name_confvm_key 'Microsoft.KeyVault/vaults/keys@2024-12-01-preview' = {
  parent: vaults_kv_confvm_name_resource
  name: 'confvm-key'
  location: 'eastus2'
  properties: {
    attributes: {
      enabled: true
      exportable: true
    }
  }
}

resource virtualMachines_confvmtest2_name_resource 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: virtualMachines_confvmtest2_name
  location: 'eastus2'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_DC2eds_v5'
    }
    additionalCapabilities: {
      hibernationEnabled: false
    }
    storageProfile: {
      imageReference: {
        publisher: 'microsoftwindowsdesktop'
        offer: 'windows-11'
        sku: 'win11-24h2-avd'
        version: 'latest'
      }
      osDisk: {
        osType: 'Windows'
        name: '${virtualMachines_confvmtest2_name}_OsDisk_1_f2f4fe8b3b9c40d79de3baafe3fb3add'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          securityProfile: {
            securityEncryptionType: 'DiskWithVMGuestState'
            diskEncryptionSet: {
              id: diskEncryptionSets_des_confvm_name_resource.id
            }
          }
          storageAccountType: 'Premium_LRS'
          id: resourceId(
            'Microsoft.Compute/disks',
            '${virtualMachines_confvmtest2_name}_OsDisk_1_f2f4fe8b3b9c40d79de3baafe3fb3add'
          )
        }
        deleteOption: 'Delete'
        diskSizeGB: 127
      }
      dataDisks: []
      diskControllerType: 'SCSI'
    }
    osProfile: {
      computerName: virtualMachines_confvmtest2_name
      adminUsername: 'portalim'
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
          assessmentMode: 'ImageDefault'
          enableHotpatching: false
        }
      }
      secrets: []
      allowExtensionOperations: true
      requireGuestProvisionSignal: true
    }
    securityProfile: {
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
      encryptionAtHost: true
      securityType: 'ConfidentialVM'
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterfaces_confvmtest2498_name_resource.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    licenseType: 'Windows_Client'
  }
}
