targetScope = 'subscription'

param policyDefinitionName string = 'avdSessionHostConfigureFSLogix-DeployIfNotExists'
param policyDefinitionDisplayName string = 'Configure FSLogix on AVD session host virtual machines'
param policyDefinitionDescription string = 'Deploys a VM Run Command that configures FSLogix when the named command has not succeeded.'

var configureFSLogixTemplate = loadJsonContent('../templates/RunCommand/ConfigureFSLogix.json')

resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2024-05-01' = {
  name: policyDefinitionName
  properties: {
    description: policyDefinitionDescription
    displayName: policyDefinitionDisplayName
    mode: 'All'
    metadata: {
      category: 'Azure Virtual Desktop'
      version: '1.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        allowedValues: [
          'DeployIfNotExists'
          'Disabled'
        ]
        defaultValue: 'DeployIfNotExists'
        metadata: {
          displayName: 'Effect'
          description: 'Enable or disable FSLogix Run Command deployment.'
        }
      }
      runCommandName: {
        type: 'String'
        defaultValue: 'ConfigureFSLogix'
        metadata: {
          displayName: 'Run Command name'
        }
      }
      identitySolution: {
        type: 'String'
        allowedValues: [
          'ActiveDirectoryDomainServices'
          'EntraDomainServices'
          'EntraKerberos-CloudOnly'
          'EntraKerberos-Hybrid'
          'EntraId'
        ]
        defaultValue: 'EntraKerberos-CloudOnly'
        metadata: {
          displayName: 'Identity solution'
          description: 'SMB authentication mode. EntraId uses storage keys; all other modes use identity-based authentication.'
        }
      }
      fslogixStorageService: {
        type: 'String'
        allowedValues: [
          'AzureFiles'
          'AzureNetAppFiles'
        ]
        defaultValue: 'AzureFiles'
        metadata: {
          displayName: 'FSLogix storage service'
        }
      }
      fslogixContainerType: {
        type: 'String'
        allowedValues: [
          'CloudCacheProfileContainer'
          'CloudCacheProfileOfficeContainer'
          'ProfileContainer'
          'ProfileOfficeContainer'
        ]
        defaultValue: 'ProfileContainer'
        metadata: {
          displayName: 'FSLogix container type'
        }
      }
      fslogixFileShareNames: {
        type: 'Array'
        defaultValue: [
          'profile-containers'
        ]
        metadata: {
          displayName: 'FSLogix file share names'
        }
      }
      fslogixLocalStorageAccountResourceIds: {
        type: 'Array'
        defaultValue: []
        metadata: {
          displayName: 'Local Azure Files storage account resource IDs'
        }
      }
      fslogixRemoteStorageAccountResourceIds: {
        type: 'Array'
        defaultValue: []
        metadata: {
          displayName: 'Remote Azure Files storage account resource IDs'
        }
      }
      fslogixLocalNetAppServerFqdns: {
        type: 'Array'
        defaultValue: []
        metadata: {
          displayName: 'Local Azure NetApp Files SMB server FQDNs'
        }
      }
      fslogixRemoteNetAppServerFqdns: {
        type: 'Array'
        defaultValue: []
        metadata: {
          displayName: 'Remote Azure NetApp Files SMB server FQDNs'
        }
      }
      fslogixOSSGroups: {
        type: 'Array'
        defaultValue: []
        metadata: {
          displayName: 'FSLogix object-specific settings groups'
        }
      }
      profileSizeInMBs: {
        type: 'Integer'
        defaultValue: 30000
        metadata: {
          displayName: 'Profile container size in MB'
        }
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Compute/virtualMachines'
          }
          {
            field: 'Microsoft.Compute/virtualMachines/storageProfile.osDisk.osType'
            equals: 'Windows'
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          type: 'Microsoft.Compute/virtualMachines/runCommands'
          name: '[concat(field(\'name\'), \'/\', parameters(\'runCommandName\'))]'
          evaluationDelay: 'AfterProvisioningSuccess'
          roleDefinitionIds: [
            '/providers/Microsoft.Authorization/roleDefinitions/9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
            '/providers/Microsoft.Authorization/roleDefinitions/81a9662b-bebf-436f-a333-f67b29880f12'
          ]
          existenceCondition: {
            field: 'Microsoft.Compute/virtualMachines/runCommands/provisioningState'
            equals: 'Succeeded'
          }
          deployment: {
            properties: {
              mode: 'Incremental'
              parameters: {
                fslogixContainerType: {
                  value: '[parameters(\'fslogixContainerType\')]'
                }
                fslogixFileShareNames: {
                  value: '[parameters(\'fslogixFileShareNames\')]'
                }
                fslogixLocalStorageAccountResourceIds: {
                  value: '[parameters(\'fslogixLocalStorageAccountResourceIds\')]'
                }
                fslogixLocalNetAppServerFqdns: {
                  value: '[parameters(\'fslogixLocalNetAppServerFqdns\')]'
                }
                fslogixOSSGroups: {
                  value: '[parameters(\'fslogixOSSGroups\')]'
                }
                fslogixRemoteStorageAccountResourceIds: {
                  value: '[parameters(\'fslogixRemoteStorageAccountResourceIds\')]'
                }
                fslogixRemoteNetAppServerFqdns: {
                  value: '[parameters(\'fslogixRemoteNetAppServerFqdns\')]'
                }
                fslogixStorageService: {
                  value: '[parameters(\'fslogixStorageService\')]'
                }
                identitySolution: {
                  value: '[parameters(\'identitySolution\')]'
                }
                location: {
                  value: '[field(\'location\')]'
                }
                profileSizeInMBs: {
                  value: '[parameters(\'profileSizeInMBs\')]'
                }
                runCommandName: {
                  value: '[parameters(\'runCommandName\')]'
                }
                virtualMachineName: {
                  value: '[field(\'name\')]'
                }
              }
              template: configureFSLogixTemplate
            }
          }
        }
      }
    }
  }
}

output policyDefinitionResourceId string = policyDefinition.id