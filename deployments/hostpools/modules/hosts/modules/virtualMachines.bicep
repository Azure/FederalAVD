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
param dataCollectionEndpointResourceId string
param dedicatedHostGroupResourceIds array
param dedicatedHostResourceIds array
param preferredZones array
param diskAccessId string = ''
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
param hibernationEnabled bool = false
param hostPoolResourceId string
param identitySolution string
param imageReference object
param integrityMonitoring bool
param intuneEnrollment bool
param location string
param networkInterfaceNameConv string
param osDiskNameConv string
param ouPath string
param sessionHostCustomizations array
param sessionHostNames array
param vmNumbers array
param securityType string
param secureBootEnabled bool
param subnetResourceId string
param tags object
param deploymentSuffix string
param timeZone string
@secure()
param virtualMachineAdminPassword string
@secure()
param virtualMachineAdminUserName string
param virtualMachineNameConv string
param virtualMachineSize string
param vTpmEnabled bool
param hasAmdGpu bool
param hasNvidiaGpu bool
param recoveryServicesVaultResourceId string = ''
param vmBackupPolicyName string = 'AvdPolicyVm'

var storageSuffix = environment().suffixes.storage

var sessionHostCount = length(sessionHostNames)

var fslogixLocalStorageAccountNames = [for id in fslogixLocalStorageAccountResourceIds: last(split(id, '/'))]
var fslogixRemoteStorageAccountNames = [for id in fslogixRemoteStorageAccountResourceIds: last(split(id, '/'))]
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

var networkInterfaceNames = [for i in range(0, sessionHostCount): empty(networkInterfaceNameConv) ? sessionHostNames[i] : replace(networkInterfaceNameConv, 'SHNAME', sessionHostNames[i])]
var virtualMachineNames = [for i in range(0, sessionHostCount): empty(virtualMachineNameConv) ? sessionHostNames[i] : replace(virtualMachineNameConv, 'SHNAME', sessionHostNames[i])]
var osDiskNames = [for i in range(0, sessionHostCount): empty(osDiskNameConv) ? '${sessionHostNames[i]}-osdisk' : replace(osDiskNameConv, 'SHNAME', sessionHostNames[i])]

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' existing = {
  name: last(split(hostPoolResourceId, '/'))
  scope: resourceGroup(split(hostPoolResourceId, '/')[2], split(hostPoolResourceId, '/')[4])
}

resource localStorageAccounts 'Microsoft.Storage/storageAccounts@2023-01-01' existing = [
  for resId in fslogixLocalStorageAccountResourceIds: if (identitySolution == 'EntraId' && !empty(fslogixLocalStorageAccountResourceIds)) {
    name: last(split(resId, '/'))
    scope: resourceGroup(split(resId, '/')[2], split(resId, '/')[4])
  }
]

resource remoteStorageAccounts 'Microsoft.Storage/storageAccounts@2023-01-01' existing = [
  for resId in fslogixRemoteStorageAccountResourceIds: if (identitySolution == 'EntraId' && !empty(fslogixRemoteStorageAccountResourceIds)) {
    name: last(split(resId, '/'))
    scope: resourceGroup(split(resId, '/')[2], split(resId, '/')[4])
  }
]

resource networkInterface 'Microsoft.Network/networkInterfaces@2020-05-01' = [
  for i in range(0, sessionHostCount): {
    name: networkInterfaceNames[i]
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
    name: virtualMachineNames[i]
    location: location
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Compute/virtualMachines'] ?? {})
    zones: !empty(preferredZones) && i < length(preferredZones) && !empty(preferredZones[i])
      ? [preferredZones[i]]
      : availability == 'AvailabilityZones' && !empty(availabilityZones)
          ? [availabilityZones[int(vmNumbers[i] - 1) % length(availabilityZones)]]
          : null
    identity: identity
    properties: {
      additionalCapabilities: hibernationEnabled ? { hibernationEnabled: true } : null
      availabilitySet: availability == 'AvailabilitySets'
        ? {
            id: resourceId(
              'Microsoft.Compute/availabilitySets',
              replace(availabilitySetNameConv, '##', padLeft(((vmNumbers[i] - 1) / 200) + 1, 2, '0'))
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
      host: !empty(dedicatedHostResourceIds)
        ? { id: length(dedicatedHostResourceIds) == 1 ? dedicatedHostResourceIds[0] : dedicatedHostResourceIds[i] }
        : null
      hostGroup: !empty(dedicatedHostGroupResourceIds) && empty(dedicatedHostResourceIds)
        ? { id: length(dedicatedHostGroupResourceIds) == 1 ? dedicatedHostGroupResourceIds[0] : dedicatedHostGroupResourceIds[i] }
        : null
      storageProfile: {
        imageReference: imageReference
        osDisk: {
          diskSizeGB: diskSizeGB != 0 ? diskSizeGB : null
          name: osDiskNames[i]
          osType: 'Windows'
          createOption: 'FromImage'
          caching: 'ReadWrite'
          deleteOption: 'Delete'
          managedDisk: {
            diskEncryptionSet: securityType != 'ConfidentialVM' && !empty(diskEncryptionSetResourceId)
              ? { id: diskEncryptionSetResourceId }
              : null
            securityProfile: securityType == 'ConfidentialVM'
              ? {
                  diskEncryptionSet: !empty(diskEncryptionSetResourceId) ? { id: diskEncryptionSetResourceId } : null
                  securityEncryptionType: confidentialVMOSDiskEncryptionType
                }
              : null
            storageAccountType: diskSku
          }
        }
        dataDisks: []
      }
      osProfile: {
        computerName: sessionHostNames[i]
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
      licenseType: (!empty(imageReference.?id) || imageReference.?publisher == 'MicrosoftWindowsDesktop')
        ? 'Windows_Client'
        : 'Windows_Server'
    }
    dependsOn: [
      networkInterface
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
  }
]

resource extension_JsonADDomainExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [
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
    dependsOn: [
      extension_GuestAttestation[i]
    ]
  }
]

resource extension_AADLoginForWindows 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [
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
    dependsOn: [
      extension_GuestAttestation[i]
    ]
  }
]

resource extension_AzureMonitorWindowsAgent 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [
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
      extension_GuestAttestation[i]
      extension_AADLoginForWindows[i]
      extension_JsonADDomainExtension[i]
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
      extension_AzureMonitorWindowsAgent[i]
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
      extension_AzureMonitorWindowsAgent[i]
    ]
  }
]

resource extension_AmdGpuDriverWindows 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [
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
      extension_GuestAttestation[i]
      extension_AADLoginForWindows[i]
      extension_JsonADDomainExtension[i]
      extension_AzureMonitorWindowsAgent[i]
    ]
  }
]

resource extension_NvidiaGpuDriverWindows 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [
  for i in range(0, sessionHostCount): if (hasNvidiaGpu) {
    parent: virtualMachine[i]
    name: 'NvidiaGpuDriverWindows'
    location: location
    properties: {
      publisher: 'Microsoft.HpcCompute'
      type: 'NvidiaGpuDriverWindows'
      typeHandlerVersion: '1.10'
      autoUpgradeMinorVersion: true
      settings: {}
    }
    dependsOn: [
      extension_GuestAttestation[i]
      extension_AADLoginForWindows[i]
      extension_JsonADDomainExtension[i]
      extension_AzureMonitorWindowsAgent[i]
    ]
  }
]

module customizations 'invokeCustomizations.bicep' = [
  for i in range(0, sessionHostCount): if (!empty(sessionHostCustomizations)) {
    name: '${virtualMachineNames[i]}-Customizations-${deploymentSuffix}'
    params: {
      artifactsContainerUri: artifactsContainerUri
      customizations: sessionHostCustomizations
      userAssignedIdentityClientId: artifactsUserAssignedIdentityClientId
      virtualMachineName: virtualMachineNames[i]
    }
    dependsOn: [
      extension_AADLoginForWindows[i]
      extension_JsonADDomainExtension[i]
      extension_AmdGpuDriverWindows[i]
      extension_NvidiaGpuDriverWindows[i]
      extension_AzureMonitorWindowsAgent[i]
      extension_GuestAttestation[i]
    ]
  }
]

resource runCommand_InitializeSessionHost 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = [
  for i in range(0, sessionHostCount): {
    parent: virtualMachine[i]
    name: 'initializeSessionHost'
    location: location
    properties: {
      parameters: [
        { name: 'AADJoin', value: !contains(identitySolution, 'DomainServices') ? 'true' : 'false' }
        { name: 'AgentBootLoaderUrl', value: agentBootLoaderDownloadUrl }
        { name: 'AgentUrl', value: agentDownloadUrl }
        { name: 'FallBackUrl', value: agentFallBackDownloadUrl }
        { name: 'ApiVersion', value: startsWith(environment().name, 'USN') ? '2017-08-01' : '2018-02-01' }
        { name: 'StorageSuffix', value: storageSuffix }
        { name: 'MdmId', value: intuneEnrollment ? '0000000a-0000-0000-c000-000000000000' : '' }
        { name: 'UserAssignedIdentityClientId', value: artifactsUserAssignedIdentityClientId }
        { name: 'TimeZone', value: timeZone }
        { name: 'AmdVmSize', value: hasAmdGpu ? 'true' : 'false' }
        { name: 'NvidiaVmSize', value: hasNvidiaGpu ? 'true' : 'false' }
        { name: 'ConfigureFSLogix', value: fslogixConfigureSessionHosts ? 'true' : 'false' }
        { name: 'CloudCache', value: contains(fslogixContainerType, 'CloudCache') ? 'true' : 'false' }
        { name: 'IdentitySolution', value: identitySolution }
        { name: 'LocalNetAppServers', value: string(fslogixLocalNetAppServerFqdns) }
        { name: 'LocalStorageAccountNames', value: string(fslogixLocalStorageAccountNames) }
        { name: 'OSSGroups', value: string(fslogixOSSGroups) }
        { name: 'RemoteNetAppServers', value: string(fslogixRemoteNetAppServerFqdns) }
        { name: 'RemoteStorageAccountNames', value: string(fslogixRemoteStorageAccountNames) }
        { name: 'Shares', value: string(fslogixFileShareNames) }
        { name: 'SizeInMBs', value: string(fslogixSizeInMBs) }
        { name: 'StorageService', value: fslogixStorageService }
      ]
      protectedParameters: fslogixConfigureSessionHosts
        ? [
            { name: 'RegistrationToken', value: last(hostPool.listRegistrationTokens().value).token }
            { name: 'LocalStorageAccountKeys', value: string(fslogixLocalStorageAccountKeys) }
            { name: 'RemoteStorageAccountKeys', value: string(fslogixRemoteStorageAccountKeys) }
          ]
        : [
            { name: 'RegistrationToken', value: last(hostPool.listRegistrationTokens().value).token }
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

module updateOSDiskNetworkAccess '../../../../../.common/bicepModules/custom/disableOSDiskPublicAccess/getOSDisk.bicep' = [
  for i in range(0, sessionHostCount): {
    name: '${virtualMachineNames[i]}-disable-osDisk-PublicAccess-${deploymentSuffix}'
    params: {
      diskAccessId: diskAccessId
      diskName: virtualMachine[i].properties.storageProfile.osDisk.name
      location: location
      deploymentSuffix: deploymentSuffix
      vmName: virtualMachineNames[i]
    }
  }
]

module vmBackupRegistration '../../operations/vmBackupItems.bicep' = if (!empty(recoveryServicesVaultResourceId)) {
  name: 'VmBackupRegistration-${deploymentSuffix}'
  scope: resourceGroup(split(recoveryServicesVaultResourceId, '/')[2], split(recoveryServicesVaultResourceId, '/')[4])
  params: {
    hostPoolResourceId: hostPoolResourceId
    policyName: vmBackupPolicyName
    recoveryServicesVaultName: last(split(recoveryServicesVaultResourceId, '/'))!
    resourceGroupHosts: resourceGroup().name
    virtualMachineNames: [for i in range(0, sessionHostCount): virtualMachineNames[i]]
  }
}

output virtualMachineNames array = [for i in range(0, sessionHostCount): virtualMachineNames[i]]
