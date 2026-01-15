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
param sessionHostNameIndexLength int
param sessionHostNames array
param sessionHostRegistrationDSCUrl string
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
param vmInsightsDataCollectionRulesResourceId string
param vTpmEnabled bool

var storageSuffix = environment().suffixes.storage
var amdVmSize = contains(virtualMachineSize, 'Standard_NV') && (endsWith(virtualMachineSize, 'as_v4') || endsWith(
  virtualMachineSize,
  '_V710_v5'
))
var nvidiaVmSize = contains(virtualMachineSize, 'Standard_NV') && (endsWith(virtualMachineSize, '_v3') || endsWith(
  virtualMachineSize,
  '_A10_v5'
))

// Calculate session host count from the array length
var sessionHostCount = length(sessionHostNames)

// Extract VM numbers from names for zone distribution
var vmNumbers = [
  for name in sessionHostNames: int(substring(
    name,
    length(name) - sessionHostNameIndexLength,
    sessionHostNameIndexLength
  ))
]

// Extract padded index strings from VM names for use in naming conventions (e.g., 'avdhost001' -> '001')
var vmIndexStrings = [
  for name in sessionHostNames: substring(name, length(name) - sessionHostNameIndexLength, sessionHostNameIndexLength)
]
var vmPrefixStrings = [for name in sessionHostNames: substring(name, 0, length(name) - sessionHostNameIndexLength)]

var profileShareName = fslogixFileShareNames[0]
var officeShareName = length(fslogixFileShareNames) > 1 ? fslogixFileShareNames[1] : ''

// NetApp Volumes
var fslogixLocalNetAppProfileShare = !empty(fslogixLocalNetAppServerFqdns)
  ? '\\\\${fslogixLocalNetAppServerFqdns[0]}\\${profileShareName}'
  : ''
var fslogixLocalNetAppOfficeShare = length(fslogixLocalNetAppServerFqdns) > 1
  ? '\\\\${fslogixLocalNetAppServerFqdns[1]}\\${officeShareName}'
  : ''
var fslogixRemoteNetAppProfileShare = !empty(fslogixRemoteNetAppServerFqdns)
  ? '\\\\${fslogixRemoteNetAppServerFqdns[0]}\\${profileShareName}'
  : ''
var fslogixRemoteNetAppOfficeShare = length(fslogixRemoteNetAppServerFqdns) > 1
  ? '\\\\${fslogixRemoteNetAppServerFqdns[1]}\\${officeShareName}'
  : ''

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

// Dynamic parameters for the Anti-Malware Extension
var vhdxPath = '\\*\\*.VHDX'
var fslogixExclusionsCloudCache = contains(fslogixContainerType, 'CloudCache')
  ? '%ProgramData%\\FSLogix\\Cache\\*;%ProgramData%\\FSLogix\\Proxy\\*'
  : ''
var fslogixLocalSANameMinus2 = [for name in fslogixLocalStorageAccountNames: take(name, length(name) - 2)]
var fslogixLocalDedupedSANames = union(fslogixLocalSANameMinus2, fslogixLocalSANameMinus2)
var fslogixLocalMatchPrefix = length(fslogixLocalDedupedSANames) == 1 ? true : false
var fslogixLocalOfficeSharesPrefixMatch = !empty(fslogixLocalDedupedSANames) && !empty(officeShareName)
  ? ['\\\\${fslogixLocalDedupedSANames[0]}??.file.${storageSuffix}\\${officeShareName}${vhdxPath}']
  : []
var fslogixLocalProfileSharesPrefixMatch = !empty(fslogixLocalDedupedSANames)
  ? ['\\\\${fslogixLocalDedupedSANames[0]}??.file.${storageSuffix}\\${profileShareName}${vhdxPath}']
  : []
var fslogixLocalOfficeSharesNoMatch = !empty(officeShareName)
  ? map(fslogixLocalStorageAccountNames, name => ['\\\\${name}??.file.${storageSuffix}\\${officeShareName}${vhdxPath}'])
  : []
var fslogixLocalProfileSharesNoMatch = map(
  fslogixLocalStorageAccountNames,
  name => ['\\\\${name}.file.${storageSuffix}}\\${profileShareName}${vhdxPath}']
)
var fslogixLocalOfficeVHDXs = fslogixLocalMatchPrefix
  ? fslogixLocalOfficeSharesPrefixMatch
  : fslogixLocalOfficeSharesNoMatch
var fslogixLocalProfileVHDXs = fslogixLocalMatchPrefix
  ? fslogixLocalProfileSharesPrefixMatch
  : fslogixLocalProfileSharesNoMatch
var fslogixRemoteSANameMinus2 = [for name in fslogixRemoteStorageAccountNames: take(name, length(name) - 2)]
var fslogixRemoteDedupedSANames = union(fslogixRemoteSANameMinus2, fslogixRemoteSANameMinus2)
var fslogixRemoteMatchPrefix = length(fslogixRemoteDedupedSANames) == 1 ? true : false
var fslogixRemoteOfficeSharesPrefixMatch = !empty(fslogixRemoteDedupedSANames) && !empty(officeShareName)
  ? ['\\\\${fslogixRemoteDedupedSANames[0]}??.file.${storageSuffix}\\${officeShareName}${vhdxPath}']
  : []
var fslogixRemoteProfileSharesPrefixMatch = !empty(fslogixRemoteDedupedSANames)
  ? ['\\\\${fslogixRemoteDedupedSANames[0]}??.file.${storageSuffix}\\${profileShareName}${vhdxPath}']
  : []
var fslogixRemoteOfficeSharesNoMatch = !empty(fslogixRemoteStorageAccountNames) && !empty(officeShareName)
  ? map(
      fslogixRemoteStorageAccountNames,
      name => ['\\\\${name}??.file.${storageSuffix}\\${officeShareName}${vhdxPath}']
    )
  : []
var fslogixRemoteProfileSharesNoMatch = !empty(fslogixRemoteStorageAccountNames)
  ? map(
      fslogixRemoteStorageAccountNames,
      name => ['\\\\${name}.file.${storageSuffix}}\\${profileShareName}${vhdxPath}']
    )
  : []
var fslogixRemoteOfficeVHDXs = fslogixRemoteMatchPrefix
  ? fslogixRemoteOfficeSharesPrefixMatch
  : fslogixRemoteOfficeSharesNoMatch
var fslogixRemoteProfileVHDXs = fslogixRemoteMatchPrefix
  ? fslogixRemoteProfileSharesPrefixMatch
  : fslogixRemoteProfileSharesNoMatch
var fslogixOfficeVHDXs = fslogixStorageService == 'AzureFiles'
  ? union(fslogixLocalOfficeVHDXs, fslogixRemoteOfficeVHDXs)
  : (empty(fslogixLocalNetAppOfficeShare)
      ? []
      : (empty(fslogixRemoteNetAppOfficeShare)
          ? ['${fslogixLocalNetAppOfficeShare}${vhdxPath}']
          : ['${fslogixLocalNetAppOfficeShare}${vhdxPath}', '${fslogixRemoteNetAppOfficeShare}${vhdxPath}']))
var fslogixProfileVHDXs = fslogixStorageService == 'AzureFiles'
  ? union(fslogixLocalProfileVHDXs, fslogixRemoteProfileVHDXs)
  : (empty(fslogixLocalNetAppProfileShare)
      ? []
      : (empty(fslogixRemoteNetAppProfileShare)
          ? ['${fslogixRemoteNetAppProfileShare}${vhdxPath}']
          : ['${fslogixLocalNetAppProfileShare}${vhdxPath}', '${fslogixRemoteNetAppProfileShare}${vhdxPath}']))
var fslogixExclusionsOfficeArray = [
  for Path in fslogixOfficeVHDXs: '${Path};${Path}.lock;${Path}.meta;${Path}.metadata'
]
var fslogixExclusionProfileArray = [
  for Path in fslogixProfileVHDXs: '${Path};${Path}.lock;${Path}.meta;${Path}.metadata'
]
var fslogixExclusionsOfficeString = contains(fslogixContainerType, 'Office')
  ? join(fslogixExclusionsOfficeArray, ';')
  : ''
var fslogixExclusionsProfileString = join(fslogixExclusionProfileArray, ';')

var fslogixExclusionsArray = [
  '$TEMP%${vhdxPath}'
  '%WinDir%\\TEMP${vhdxPath}'
  fslogixExclusionsCloudCache
  fslogixExclusionsProfileString
  fslogixExclusionsOfficeString
]

var fslogixPathExclusions = join(filter(fslogixExclusionsArray, exclusion => !empty(exclusion)), ';')

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
    name: empty(networkInterfaceNameConv)
      ? 'nic-${sessionHostNames[i]}'
      : replace(replace(networkInterfaceNameConv, '###', vmIndexStrings[i]), 'VMNAMEPREFIX', vmPrefixStrings[i])
    location: location
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Network/networkInterfaces'] ?? {})
    properties: {
      ipConfigurations: union([
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
      enableIPv6 ? [
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
      ] : [])
      enableAcceleratedNetworking: enableAcceleratedNetworking
      enableIPForwarding: false
    }
  }
]

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-03-01' = [for i in range(0, sessionHostCount): {
  name: empty(virtualMachineNameConv) ? sessionHostNames[i] : replace(replace(virtualMachineNameConv, '###', vmIndexStrings[i]), 'VMNAMEPREFIX', vmPrefixStrings[i])
  location: location
  tags: union({'cm-resource-parent': hostPoolResourceId}, tags[?'Microsoft.Compute/virtualMachines'] ?? {})
  zones: !empty(preferredZones) && i < length(preferredZones) && !empty(preferredZones[i]) ? [preferredZones[i]] : availability == 'AvailabilityZones' && !empty(availabilityZones) ? [
    availabilityZones[(vmNumbers[i] - 1) % length(availabilityZones)]
  ] : null
  identity: identity
  properties: {
    availabilitySet: availability == 'AvailabilitySets' ? {
      id: resourceId('Microsoft.Compute/availabilitySets', replace(availabilitySetNameConv, '##', padLeft(((vmNumbers[i] - 1) / 200) + 1, 2, '0')))
    } : null
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
    hardwareProfile: {
      vmSize: virtualMachineSize
    }
    host: !empty(dedicatedHostResourceIds) && i < length(dedicatedHostResourceIds) && !empty(dedicatedHostResourceIds[i]) ? {
      id: dedicatedHostResourceIds[i]
    } : null
    hostGroup: !empty(dedicatedHostGroupResourceIds) && i < length(dedicatedHostGroupResourceIds) && !empty(dedicatedHostGroupResourceIds[i]) && (empty(dedicatedHostResourceIds) || i >= length(dedicatedHostResourceIds) || empty(dedicatedHostResourceIds[i])) ? {
      id: dedicatedHostGroupResourceIds[i]
    } : null
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        diskSizeGB: diskSizeGB != 0 ? diskSizeGB : null
        name: empty(osDiskNameConv) ? null : replace(replace(osDiskNameConv, '###', vmIndexStrings[i]), 'VMNAMEPREFIX', vmPrefixStrings[i])
        osType: 'Windows'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        deleteOption: 'Delete'
        managedDisk: {
          diskEncryptionSet: securityType != 'ConfidentialVM' && !empty(diskEncryptionSetResourceId) ? {
            id: diskEncryptionSetResourceId
          } : null
          securityProfile: securityType == 'ConfidentialVM' ? {
            diskEncryptionSet: !empty(diskEncryptionSetResourceId) ? {
              id: diskEncryptionSetResourceId
            } : null
            securityEncryptionType: confidentialVMOSDiskEncryptionType
          } : null
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
      uefiSettings: securityType != 'Standard' ? {
        secureBootEnabled: secureBootEnabled
        vTpmEnabled: vTpmEnabled
      } : null 
    }
    licenseType: (!empty(imageReference.?id) || imageReference.?publisher == 'MicrosoftWindowsDesktop') ? 'Windows_Client' : 'Windows_Server'
  }
  dependsOn: [
    networkInterface
  ]
}]

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

resource extension_IaasAntimalware 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = [
  for i in range(0, sessionHostCount): if (!startsWith(environment().name, 'USN')) {
    parent: virtualMachine[i]
    name: 'IaaSAntimalware'
    location: location
    properties: {
      publisher: 'Microsoft.Azure.Security'
      type: 'IaaSAntimalware'
      typeHandlerVersion: '1.3'
      autoUpgradeMinorVersion: true
      settings: {
        AntimalwareEnabled: true
        RealtimeProtectionEnabled: 'true'
        ScheduledScanSettings: {
          isEnabled: 'true'
          day: '7' // Day of the week for scheduled scan (1-Sunday, 2-Monday, ..., 7-Saturday)
          time: '120' // When to perform the scheduled scan, measured in minutes from midnight (0-1440). For example: 0 = 12AM, 60 = 1AM, 120 = 2AM.
          scanType: 'Quick' //Indicates whether scheduled scan setting type is set to Quick or Full (default is Quick)
        }
        Exclusions: {
          Paths: fslogixPathExclusions
        }
      }
    }
    dependsOn: [
      extension_AADLoginForWindows
      extension_JsonADDomainExtension
    ]
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
      extension_IaasAntimalware
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
      extension_IaasAntimalware
      extension_AzureMonitorWindowsAgent
    ]
  }
]

resource extension_AmdGpuDriverWindows 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = [
  for i in range(0, sessionHostCount): if (amdVmSize) {
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
      extension_IaasAntimalware
      extension_AzureMonitorWindowsAgent
    ]
  }
]

resource extension_NvidiaGpuDriverWindows 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = [
  for i in range(0, sessionHostCount): if (nvidiaVmSize) {
    parent: virtualMachine[i]
    name: 'NvidiaGpuDriverWindows'
    location: location
    properties: {
      publisher: 'Microsoft.HpcCompute'
      type: 'NvidiaGpuDriverWindows'
      typeHandlerVersion: '1.2'
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

resource runCommand_ConfigureSessionHost 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = [
  for i in range(0, sessionHostCount): {
    parent: virtualMachine[i]
    name: 'configureSessionHost'
    location: location
    properties: {
      parameters: [
        {
          name: 'AmdVmSize'
          value: amdVmSize ? 'true' : 'false'
        }
        {
          name: 'NvidiaVmSize'
          value: nvidiaVmSize ? 'true' : 'false'
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
          name: 'StorageAccountDNSSuffix'
          value: storageSuffix
        }
        {
          name: 'StorageService'
          value: fslogixStorageService
        }
        {
          name: 'TimeZone'
          value: timeZone
        }
      ]
      protectedParameters: fslogixConfigureSessionHosts
        ? [
            {
              name: 'LocalStorageAccountKeys'
              value: string(fslogixLocalStorageAccountKeys)
            }
            {
              name: 'RemoteStorageAccountKeys'
              value: string(fslogixRemoteStorageAccountKeys)
            }
          ]
        : null
      source: {
        script: loadTextContent('../../../../../../.common/scripts/Set-SessionHostConfiguration.ps1')
      }
      treatFailureAsDeploymentFailure: true
      timeoutInSeconds: 600
    }
    dependsOn: [
      extension_AADLoginForWindows
      extension_JsonADDomainExtension
      extension_AmdGpuDriverWindows
      extension_NvidiaGpuDriverWindows
      extension_IaasAntimalware
      extension_AzureMonitorWindowsAgent
      extension_GuestAttestation
    ]
  }
]

module postDeploymentScripts 'invokeCustomizations.bicep' = [
  for i in range(0, sessionHostCount): if (!empty(sessionHostCustomizations)) {
    name: 'shr-${virtualMachine[i].name}-customizations-${deploymentSuffix}'
    params: {
      artifactsContainerUri: artifactsContainerUri
      customizations: sessionHostCustomizations
      userAssignedIdentityClientId: artifactsUserAssignedIdentityClientId
      virtualMachineName: virtualMachine[i].name
    }
    dependsOn: [
      runCommand_ConfigureSessionHost
    ]
  }
]

resource extension_DSC_installAvdAgents 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = [
  for i in range(0, sessionHostCount): {
    parent: virtualMachine[i]
    name: 'AVDAgentInstallandConfig'
    location: location
    properties: {
      publisher: 'Microsoft.Powershell'
      type: 'DSC'
      typeHandlerVersion: '2.73'
      autoUpgradeMinorVersion: true
      settings: {
        modulesUrl: sessionHostRegistrationDSCUrl
        configurationFunction: 'Configuration.ps1\\AddSessionHost'
        properties: {
          hostPoolName: last(split(hostPoolResourceId, '/'))
          registrationInfoTokenCredential: {
            UserName: 'PLACEHOLDER_DO_NOT_USE'
            Password: 'PrivateSettingsRef:RegistrationInfoToken'
          }
          aadJoin: !contains(identitySolution, 'DomainServices')
          UseAgentDownloadEndpoint: false
          mdmId: intuneEnrollment ? '0000000a-0000-0000-c000-000000000000' : ''
        }
      }
      protectedSettings: {
        Items: {
          RegistrationInfoToken: hostPool.listRegistrationTokens().value[0].token
        }
      }
    }
    dependsOn: [
      runCommand_ConfigureSessionHost
      postDeploymentScripts
    ]
  }
]

module updateOSDiskNetworkAccess 'getOSDisk.bicep' = [
  for i in range(0, sessionHostCount): {
    name: 'shr-${virtualMachine[i].name}-disableDiskPublicAccess-${deploymentSuffix}'
    params: {
      diskAccessId: ''
      diskName: virtualMachine[i].properties.storageProfile.osDisk.name
      location: location
      deploymentSuffix: deploymentSuffix
      vmName: virtualMachine[i].name
    }
  }
]
