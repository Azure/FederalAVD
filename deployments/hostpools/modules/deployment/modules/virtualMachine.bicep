param identitySolution string
param diskName string
param diskSku string
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param domainName string
param encryptionAtHost bool
param location string
param networkInterfaceName string
param ouPath string
param subnetResourceId string
param tagsNetworkInterfaces object
param tagsVirtualMachines object
param timeStamp string = utcNow('yyyyMMddhhmmss')
param userAssignedIdentitiesResourceIds object
param virtualMachineName string
@secure()
param virtualMachineAdminPassword string
@secure()
param virtualMachineAdminUserName string
param vmSize string

resource networkInterface 'Microsoft.Network/networkInterfaces@2020-05-01' = {
  name: networkInterfaceName
  location: location
  tags: tagsNetworkInterfaces
  properties: {
    ipConfigurations: [
      {
        name: 'Ipv4config'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetResourceId
          }
          primary: true
          privateIPAddressVersion: 'IPv4'
        }
      }
    ]
    enableAcceleratedNetworking: false
    enableIPForwarding: false
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2021-11-01' = {
  name: virtualMachineName
  location: location
  tags: tagsVirtualMachines
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2019-datacenter-core-g2'
        version: 'latest'
      }
      osDisk: {
        name: diskName
        osType: 'Windows'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        caching: 'None'
        managedDisk: {
          storageAccountType: diskSku
        }
      }
      dataDisks: []
    }
    osProfile: {
      computerName: virtualMachineName
      adminUsername: virtualMachineAdminUserName
      adminPassword: virtualMachineAdminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
      secrets: []
      allowExtensionOperations: true
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    securityProfile: {
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
      securityType: 'trustedLaunch'
      encryptionAtHost: encryptionAtHost
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: false
      }
    }
    licenseType: 'Windows_Server'
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: userAssignedIdentitiesResourceIds
  }
}

resource extension_IaasAntimalware 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = if(!startsWith(environment().name, 'USN')) {
  parent: virtualMachine
  name: 'IaaSAntimalware'
  location: location
  tags: tagsVirtualMachines
  properties: {
    publisher: 'Microsoft.Azure.Security'
    type: 'IaaSAntimalware'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: false
    settings: {
      AntimalwareEnabled: true
      RealtimeProtectionEnabled: 'true'
      ScheduledScanSettings: {
        isEnabled: 'true'
        day: '7' // Day of the week for scheduled scan (1-Sunday, 2-Monday, ..., 7-Saturday)
        time: '120' // When to perform the scheduled scan, measured in minutes from midnight (0-1440). For example: 0 = 12AM, 60 = 1AM, 120 = 2AM.
        scanType: 'Quick' //Indicates whether scheduled scan setting type is set to Quick or Full (default is Quick)
      }
      Exclusions: {}
    }
  }
}

resource extension_GuestAttestation 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = {
  parent: virtualMachine
  name: 'GuestAttestation'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Security.WindowsAttestation'
    type: 'GuestAttestation'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    settings: {
      AttestationConfig: {
        MaaSettings: {
          maaEndpoint: ''
          maaTenantName: 'GuestAttestation'
        }
        AscSettings: {
          ascReportingEndpoint: ''
          ascReportingFrequency: ''
        }
        useCustomToken: 'false'
        disableAlerts: 'false'
      }
    }
  }
}

resource extension_JsonADDomainExtension 'Microsoft.Compute/virtualMachines/extensions@2019-07-01' = if(contains(identitySolution, 'DomainServices')) {
  parent: virtualMachine
  name: 'JsonADDomainExtension'
  location: location
  properties: {
    forceUpdateTag: timeStamp
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: domainName
      User: domainJoinUserPrincipalName
      Restart: 'true'
      Options: '3'
      OUPath: ouPath
    }
    protectedSettings: {
      Password: domainJoinUserPassword
    }
  }
}

output Name string = virtualMachine.name
