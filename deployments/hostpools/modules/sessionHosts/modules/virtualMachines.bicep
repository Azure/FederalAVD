param agentBootLoaderDownloadUrl string
param agentDownloadUrl string
param agentFallBackDownloadUrl string
param artifactsContainerUri string
param artifactsUserAssignedIdentityClientId string
param artifactsUserAssignedIdentityResourceId string
param availability string
param availabilitySetNameConv string
param availabilityZones array
param avdInsightsDataCollectionRulesResourceId string
param confidentialVMOSDiskEncryptionType string
param customImageResourceId string
param dataCollectionEndpointResourceId string
param dedicatedHostGroupResourceId string
param dedicatedHostGroupZones array
param dedicatedHostResourceId string
param diskAccessId string
param diskEncryptionSetResourceId string
param diskSizeGB int
param diskSku string
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param domainName string
param enableAcceleratedNetworking bool
param enableIPv6 bool
param enableMonitoring bool
param encryptionAtHost bool
param fslogixConfigureSessionHosts bool
param fslogixContainerType string
param fslogixFileShareNames array
param fslogixLocalNetAppServerFqdns array
param fslogixLocalStorageAccountResourceIds array
param fslogixOSSGroups array
param fslogixRemoteNetAppServerFqdns array
param fslogixRemoteStorageAccountResourceIds array
param fslogixSizeInMBs int
param fslogixStorageService string
param hibernationEnabled bool
param hostPoolResourceId string
param identitySolution string
param imageOffer string
param imagePublisher string
param imageSku string
param integrityMonitoring bool
param intuneEnrollment bool
param location string
param networkInterfaceNameConv string
param osDiskNameConv string
param ouPath string
param sessionHostCustomizations array
param sessionHostCount int
param sessionHostIndex int
param vmNameIndexLength int
param securityType string
param secureBootEnabled bool
param storageSuffix string
param subnetResourceId string
param tags object
param deploymentSuffix string
param timeZone string
@secure()
param virtualMachineAdminPassword string
@secure()
param virtualMachineAdminUserName string
param virtualMachineNameConv string
param virtualMachineNamePrefix string
param virtualMachineSize string
param vmInsightsDataCollectionRulesResourceId string
param vTpmEnabled bool
param hasAmdGpu bool
param hasNvidiaGpu bool
param nvidiaDriverVersion string

// Storage Accounts
var fslogixLocalStorageAccountNames = [for id in fslogixLocalStorageAccountResourceIds: last(split(id, '/'))]
var fslogixRemoteStorageAccountNames = [for id in fslogixRemoteStorageAccountResourceIds: last(split(id, '/'))]
//  only get keys if EntraId
var fslogixLocalSAKey1 = identitySolution == 'EntraId' && !empty(fslogixLocalStorageAccountResourceIds)
  ? [localStorageAccounts[0].listkeys().keys[0].value]
  : []
var fslogixLocalSAKey2 = identitySolution == 'EntraId' && length(fslogixLocalStorageAccountResourceIds) > 1
  ? [localStorageAccounts[1].listkeys().keys[0].value]
  : []
var fslogixLocalStorageAccountKeys = union(fslogixLocalSAKey1, fslogixLocalSAKey2)
var fslogixRemoteAKey1 = identitySolution == 'EntraId' && !empty(fslogixRemoteStorageAccountResourceIds)
  ? [remoteStorageAccounts[0].listkeys().keys[0].value]
  : []
var fslogixRemoteSAKey2 = identitySolution == 'EntraId' && length(fslogixRemoteStorageAccountResourceIds) > 1
  ? [remoteStorageAccounts[1].listkeys().keys[0].value]
  : []
var fslogixRemoteStorageAccountKeys = union(fslogixRemoteAKey1, fslogixRemoteSAKey2)

var identityType = (!contains(identitySolution, 'DomainServices') || enableMonitoring ? true : false)
  ? (!empty(artifactsUserAssignedIdentityResourceId) ? 'SystemAssigned, UserAssigned' : 'SystemAssigned')
  : (!empty(artifactsUserAssignedIdentityResourceId) ? 'UserAssigned' : 'None')

var userAssignedIdentities = !empty(artifactsUserAssignedIdentityResourceId)
  ? {
      '${artifactsUserAssignedIdentityResourceId}': {}
    }
  : {}

var identity = identityType != 'None'
  ? {
      type: identityType
      userAssignedIdentities: !empty(userAssignedIdentities) ? userAssignedIdentities : null
    }
  : null

var ImageReference = empty(customImageResourceId)
  ? {
      publisher: imagePublisher
      offer: imageOffer
      sku: imageSku
      version: 'latest'
    }
  : {
      id: customImageResourceId
    }

// All customizations now run BEFORE registration
// The runAfterHostPoolJoin property is deprecated and ignored

// call on the host pool to get the registration token
resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' existing = {
  name: last(split(hostPoolResourceId, '/'))
  scope: resourceGroup(split(hostPoolResourceId, '/')[2], split(hostPoolResourceId, '/')[4])
}

// call on new storage accounts only if we need the Storage Key(s)
resource localStorageAccounts 'Microsoft.Storage/storageAccounts@2023-01-01' existing = [
  for resId in fslogixLocalStorageAccountResourceIds: if (identitySolution == 'EntraId' && !empty(fslogixLocalStorageAccountResourceIds)) {
    name: last(split(resId, '/'))
    scope: resourceGroup(split(resId, '/')[2], split(resId, '/')[4])
  }
]

// call on remote storage accounts only if we need the Storage Key(s)
resource remoteStorageAccounts 'Microsoft.Storage/storageAccounts@2023-01-01' existing = [
  for resId in fslogixRemoteStorageAccountResourceIds: if (identitySolution == 'EntraId' && !empty(fslogixRemoteStorageAccountResourceIds)) {
    name: last(split(resId, '/'))
    scope: resourceGroup(split(resId, '/')[2], split(resId, '/')[4])
  }
]

resource networkInterface 'Microsoft.Network/networkInterfaces@2020-05-01' = [
  for i in range(0, sessionHostCount): {
    name: replace(networkInterfaceNameConv, '###', padLeft((i + sessionHostIndex), vmNameIndexLength, '0'))
    location: location
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Network/networkInterfaces'] ?? {})
    properties: {
      ipConfigurations: union(
        [
          {
            name: 'ipv4config'
            properties: {
              privateIPAllocationMethod: 'Dynamic'
              subnet: {
                id: subnetResourceId
              }
              primary: true
              privateIPAddressVersion: 'IPv4'
            }
          }
        ],
        enableIPv6
          ? [
              {
                name: 'ipv6config'
                properties: {
                  privateIPAllocationMethod: 'Dynamic'
                  subnet: {
                    id: subnetResourceId
                  }
                  primary: false
                  privateIPAddressVersion: 'IPv6'
                }
              }
            ]
          : []
      )
      enableAcceleratedNetworking: enableAcceleratedNetworking
      enableIPForwarding: false
    }
  }
]

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-03-01' = [
  for i in range(0, sessionHostCount): {
    name: replace(virtualMachineNameConv, '###', padLeft((i + sessionHostIndex), vmNameIndexLength, '0'))
    location: location
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Compute/virtualMachines'] ?? {})
    zones: !empty(dedicatedHostResourceId) || !empty(dedicatedHostGroupResourceId)
      ? dedicatedHostGroupZones
      : availability == 'AvailabilityZones' && !empty(availabilityZones)
          ? [
              availabilityZones[(i + sessionHostIndex) % length(availabilityZones)]
            ]
          : null
    identity: identity
    properties: {
      additionalCapabilities: {
        hibernationEnabled: hibernationEnabled
      }
      availabilitySet: availability == 'AvailabilitySets'
        ? {
            id: resourceId(
              'Microsoft.Compute/availabilitySets',
              replace(availabilitySetNameConv, '##', padLeft((((i + sessionHostIndex) - 1) / 200) + 1, 2, '0'))
            )
          }
        : null
      diagnosticsProfile: {
        bootDiagnostics: {
          enabled: true
        }
      }
      hardwareProfile: {
        vmSize: virtualMachineSize
      }
      host: !empty(dedicatedHostResourceId)
        ? {
            id: dedicatedHostResourceId
          }
        : null
      hostGroup: !empty(dedicatedHostGroupResourceId) && empty(dedicatedHostResourceId)
        ? {
            id: dedicatedHostGroupResourceId
          }
        : null
      storageProfile: {
        imageReference: ImageReference
        osDisk: {
          diskSizeGB: diskSizeGB != 0 ? diskSizeGB : null
          name: replace(osDiskNameConv, '###', padLeft((i + sessionHostIndex), vmNameIndexLength, '0'))
          osType: 'Windows'
          createOption: 'FromImage'
          caching: 'ReadWrite'
          deleteOption: 'Delete'
          managedDisk: {
            diskEncryptionSet: securityType != 'ConfidentialVM' && !empty(diskEncryptionSetResourceId)
              ? {
                  id: diskEncryptionSetResourceId
                }
              : null
            securityProfile: securityType == 'ConfidentialVM'
              ? {
                  diskEncryptionSet: !empty(diskEncryptionSetResourceId)
                    ? {
                        id: diskEncryptionSetResourceId
                      }
                    : null
                  securityEncryptionType: confidentialVMOSDiskEncryptionType
                }
              : null
            storageAccountType: diskSku
          }
        }
        dataDisks: []
      }
      osProfile: {
        computerName: '${virtualMachineNamePrefix}${padLeft((i + sessionHostIndex), vmNameIndexLength, '0')}'
        adminUsername: virtualMachineAdminUserName
        adminPassword: virtualMachineAdminPassword
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
            id: networkInterface[i].id
            properties: {
              deleteOption: 'Delete'
            }
          }
        ]
      }
      securityProfile: {
        encryptionAtHost: encryptionAtHost ? true : null
        securityType: securityType != 'Standard' ? securityType : null
        uefiSettings: securityType != 'Standard'
          ? {
              secureBootEnabled: secureBootEnabled
              vTpmEnabled: vTpmEnabled
            }
          : null
      }
      licenseType: ((imagePublisher == 'MicrosoftWindowsDesktop' || !empty(customImageResourceId))
        ? 'Windows_Client'
        : 'Windows_Server')
    }
    dependsOn: [
      networkInterface
    ]
  }
]

resource extension_JsonADDomainExtension 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = [
  for i in range(0, sessionHostCount): if (contains(identitySolution, 'DomainServices')) {
    parent: virtualMachine[i]
    name: 'JsonADDomainExtension'
    location: location
    properties: {
      forceUpdateTag: deploymentSuffix
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
]

resource extension_AADLoginForWindows 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = [
  for i in range(0, sessionHostCount): if (startsWith(identitySolution, 'EntraKerberos') || identitySolution == 'EntraId') {
    parent: virtualMachine[i]
    name: 'AADLoginForWindows'
    location: location
    properties: {
      publisher: 'Microsoft.Azure.ActiveDirectory'
      type: 'AADLoginForWindows'
      typeHandlerVersion: '1.0'
      autoUpgradeMinorVersion: true
      settings: intuneEnrollment
        ? {
            mdmId: '0000000a-0000-0000-c000-000000000000'
          }
        : null
    }
  }
]

resource extension_AzureMonitorWindowsAgent 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = [
  for i in range(0, sessionHostCount): if (enableMonitoring) {
    parent: virtualMachine[i]
    name: 'AzureMonitorWindowsAgent'
    location: location
    properties: {
      publisher: 'Microsoft.Azure.Monitor'
      type: 'AzureMonitorWindowsAgent'
      typeHandlerVersion: '1.1'
      autoUpgradeMinorVersion: true
      enableAutomaticUpgrade: true
    }
    dependsOn: [
      extension_AADLoginForWindows
      extension_JsonADDomainExtension
    ]
  }
]

resource dataCollectionEndpointAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = [
  for i in range(0, sessionHostCount): if (enableMonitoring && !empty(dataCollectionEndpointResourceId)) {
    scope: virtualMachine[i]
    name: 'configurationAccessEndpoint'
    properties: {
      dataCollectionEndpointId: dataCollectionEndpointResourceId
      description: 'Data Collection Endpoint Association'
    }
    dependsOn: [
      extension_AzureMonitorWindowsAgent
    ]
  }
]

resource avdInsightsDataCollectionRuleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = [
  for i in range(0, sessionHostCount): if (enableMonitoring && !empty(avdInsightsDataCollectionRulesResourceId)) {
    scope: virtualMachine[i]
    name: '${virtualMachine[i].name}-avdInsights-data-coll-rule-assoc'
    properties: {
      dataCollectionRuleId: avdInsightsDataCollectionRulesResourceId
      description: 'AVD Insights data collection rule association'
    }
    dependsOn: [
      extension_AzureMonitorWindowsAgent
    ]
  }
]

resource vmInsightsDataCollectionRuleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = [
  for i in range(0, sessionHostCount): if (enableMonitoring && !empty(vmInsightsDataCollectionRulesResourceId)) {
    scope: virtualMachine[i]
    name: '${virtualMachine[i].name}-vmInsights-data-coll-rule-assoc'
    properties: {
      dataCollectionRuleId: vmInsightsDataCollectionRulesResourceId
      description: 'VM Insights data collection rule association'
    }
    dependsOn: [
      extension_AzureMonitorWindowsAgent
    ]
  }
]

resource extension_GuestAttestation 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [
  for i in range(0, sessionHostCount): if (integrityMonitoring) {
    parent: virtualMachine[i]
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
    dependsOn: [
      extension_AADLoginForWindows
      extension_JsonADDomainExtension
      extension_AzureMonitorWindowsAgent
    ]
  }
]

resource extension_AmdGpuDriverWindows 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = [
  for i in range(0, sessionHostCount): if (hasAmdGpu) {
    parent: virtualMachine[i]
    name: 'AmdGpuDriverWindows'
    location: location
    properties: {
      publisher: 'Microsoft.HpcCompute'
      type: 'AmdGpuDriverWindows'
      typeHandlerVersion: '1.0'
      autoUpgradeMinorVersion: true
      settings: {}
    }
    dependsOn: [
      extension_AADLoginForWindows
      extension_JsonADDomainExtension
      extension_AzureMonitorWindowsAgent
    ]
  }
]

resource extension_NvidiaGpuDriverWindows 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = [
  for i in range(0, sessionHostCount): if (hasNvidiaGpu) {
    parent: virtualMachine[i]
    name: 'NvidiaGpuDriverWindows'
    location: location
    properties: {
      publisher: 'Microsoft.HpcCompute'
      type: 'NvidiaGpuDriverWindows'
      typeHandlerVersion: '1.10'
      autoUpgradeMinorVersion: true
      settings: empty(nvidiaDriverVersion)
        ? {}
        : {
            driverVersion: nvidiaDriverVersion
          }
    }
    dependsOn: [
      extension_AADLoginForWindows
      extension_JsonADDomainExtension
      extension_AzureMonitorWindowsAgent
    ]
  }
]

module customizations 'invokeCustomizations.bicep' = [
  for i in range(0, sessionHostCount): if (!empty(sessionHostCustomizations)) {
    name: '${virtualMachine[i].name}-Customizations-${deploymentSuffix}'
    params: {
      artifactsContainerUri: artifactsContainerUri
      customizations: sessionHostCustomizations
      userAssignedIdentityClientId: artifactsUserAssignedIdentityClientId
      virtualMachineName: virtualMachine[i].name
    }
    dependsOn: [
      extension_AADLoginForWindows
      extension_JsonADDomainExtension
      extension_AmdGpuDriverWindows
      extension_NvidiaGpuDriverWindows
      extension_AzureMonitorWindowsAgent
      extension_GuestAttestation
    ]
  }
]

// Initialize Session Host: Configure + Install Agents + Register
resource runCommand_InitializeSessionHost 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = [
  for i in range(0, sessionHostCount): {
    parent: virtualMachine[i]
    name: 'initializeSessionHost'
    location: location
    properties: {
      parameters: [
        {
          name: 'AADJoin'
          value: !contains(identitySolution, 'DomainServices') ? 'true' : 'false'
        }
        {
          name: 'AgentBootLoaderUrl'
          value: agentBootLoaderDownloadUrl
        }
        {
          name: 'AgentUrl'
          value: agentDownloadUrl
        }
        {
          name: 'FallBackUrl'
          value: agentFallBackDownloadUrl
        }
        {
          name: 'ApiVersion'
          value: startsWith(environment().name, 'USN') ? '2017-08-01' : '2018-02-01'
        }
        {
          name: 'StorageSuffix'
          value: storageSuffix
        }
        {
          name: 'MdmId'
          value: intuneEnrollment ? '0000000a-0000-0000-c000-000000000000' : ''
        }
        {
          name: 'UserAssignedIdentityClientId'
          value: artifactsUserAssignedIdentityClientId
        }
        {
          name: 'TimeZone'
          value: timeZone
        }
        {
          name: 'AmdVmSize'
          value: hasAmdGpu ? 'true' : 'false'
        }
        {
          name: 'NvidiaVmSize'
          value: hasNvidiaGpu ? 'true' : 'false'
        }
        {
          name: 'DisableUpdates'
          value: 'false'
        }
        {
          name: 'ConfigureFSLogix'
          value: fslogixConfigureSessionHosts ? 'true' : 'false'
        }
        {
          name: 'CloudCache'
          value: contains(fslogixContainerType, 'CloudCache') ? 'true' : 'false'
        }
        {
          name: 'IdentitySolution'
          value: identitySolution
        }
        {
          name: 'LocalNetAppServers'
          value: string(fslogixLocalNetAppServerFqdns)
        }
        {
          name: 'LocalStorageAccountNames'
          value: string(fslogixLocalStorageAccountNames)
        }
        {
          name: 'OSSGroups'
          value: string(fslogixOSSGroups)
        }
        {
          name: 'RemoteNetAppServers'
          value: string(fslogixRemoteNetAppServerFqdns)
        }
        {
          name: 'RemoteStorageAccountNames'
          value: string(fslogixRemoteStorageAccountNames)
        }
        {
          name: 'Shares'
          value: string(fslogixFileShareNames)
        }
        {
          name: 'SizeInMBs'
          value: string(fslogixSizeInMBs)
        }
        {
          name: 'StorageService'
          value: fslogixStorageService
        }
      ]
      protectedParameters: fslogixConfigureSessionHosts
        ? [
            {
              name: 'RegistrationToken'
              value: last(hostPool.listRegistrationTokens().value).token
            }
            {
              name: 'LocalStorageAccountKeys'
              value: string(fslogixLocalStorageAccountKeys)
            }
            {
              name: 'RemoteStorageAccountKeys'
              value: string(fslogixRemoteStorageAccountKeys)
            }
          ]
        : [
            {
              name: 'RegistrationToken'
              value: last(hostPool.listRegistrationTokens().value).token
            }
          ]
      source: {
        script: loadTextContent('../../../../../.common/scripts/Initialize-SessionHost.ps1')
      }
      treatFailureAsDeploymentFailure: true
      timeoutInSeconds: 900
    }
    dependsOn: [
      extension_AADLoginForWindows[i]
      extension_JsonADDomainExtension[i]
      extension_AmdGpuDriverWindows[i]
      extension_NvidiaGpuDriverWindows[i]
      extension_AzureMonitorWindowsAgent[i]
      extension_GuestAttestation[i]
      customizations[i]
    ]
  }
]

module updateOSDiskNetworkAccess 'getOSDisk.bicep' = [
  for i in range(0, sessionHostCount): {
    name: '${virtualMachine[i].name}-disable-osDisk-PublicAccess-${deploymentSuffix}'
    params: {
      diskAccessId: diskAccessId
      diskName: virtualMachine[i].properties.storageProfile.osDisk.name
      location: location
      deploymentSuffix: deploymentSuffix
      vmName: virtualMachine[i].name
    }
  }
]

// debugging outputs
output virtualMachineNames array = [for i in range(0, sessionHostCount): virtualMachine[i].name]
