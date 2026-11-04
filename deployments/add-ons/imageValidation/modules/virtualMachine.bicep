import { runCommandParameterType } from '../../../shared/modules/resourceModules/types/customizationTypes.bicep'

type runCommandSettingType = {
  name: string
  script: string
  parameters: runCommandParameterType[]
}

param diskName string
param imageVersionResourceId string
param licenseType string
param location string
param networkInterfaceName string
param privateIPAddress string
param runCommandSettings runCommandSettingType[]
param subnetResourceId string
param tags object
param userAssignedIdentityResourceId string
param virtualMachineName string
@secure()
param virtualMachinePassword string
param virtualMachineSize string
@secure()
param virtualMachineUsername string

resource networkInterface 'Microsoft.Network/networkInterfaces@2020-05-01' = {
  name: networkInterfaceName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          primary: true
          privateIPAddress: privateIPAddress
          privateIPAddressVersion: 'IPv4'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: subnetResourceId
          }

        }
      }
    ]
    enableAcceleratedNetworking: true
    enableIPForwarding: false
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2021-11-01' = {
  name: virtualMachineName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityResourceId}': {}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: virtualMachineSize
    }
    storageProfile: {
      imageReference: {
        id: imageVersionResourceId
      }
      osDisk: {
        deleteOption: 'Delete'
        osType: 'Windows'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        name: diskName
      }
      dataDisks: []
    }
    osProfile: {
      computerName: virtualMachineName
      adminUsername: virtualMachineUsername
      adminPassword: virtualMachinePassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: false
      }
      secrets: []
      allowExtensionOperations: true
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            deleteOption: 'Detach'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: false
      }
    }
    licenseType: licenseType
  }
}

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = [for setting in runCommandSettings: if (!empty(runCommandSettings)) {
  parent: virtualMachine
  name: setting.name
  location: location
  tags: tags
  properties: {
    asyncExecution: false
    parameters: setting.parameters
    source: {
      script: setting.script
    }
    treatFailureAsDeploymentFailure: true
  }
}]
