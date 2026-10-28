metadata name = 'Session host VM batch orchestration'
metadata description = 'Deploys session-host VM batches with NICs, initialization, optional extensions and monitoring, disk access controls, and backup.'

import { artifactCustomizationType } from '../../resourceModules/types/customizationTypes.bicep'
import { osDiskNamePattern } from '../naming/naming.bicep'

@description('Required. AVD Agent Boot Loader installer URL forwarded to initialization; the caller resolves cloud-specific defaults.')
param agentBootLoaderDownloadUrl string
@description('Required. AVD Agent installer URL forwarded to initialization; the caller resolves cloud-specific defaults.')
param agentDownloadUrl string
@description('Required. Base URI of the existing artifact container used to resolve relative customization blob names.')
param artifactsContainerUri string
@description('Required. Client ID of the artifact-read identity attached to each VM, forwarded to initialization and customization commands.')
param artifactsUserAssignedIdentityClientId string
@description('Required. Resource ID of the existing artifact-read identity to attach to session hosts; empty omits that identity.')
param artifactsUserAssignedIdentityResourceId string
@description('Required. Placement mode used to select availability sets or availability zones.')
param availability string
@description('Required. Availability set name pattern containing ## for the two-digit set number.')
param availabilitySetNameConv string
@description('Required. Ordered availability zone strings used for rotation based on each VM numeric suffix.')
param availabilityZones string[]
@description('Required. Resource ID of the existing AVD Insights data collection rule; empty skips its association when monitoring is enabled.')
param avdInsightsDataCollectionRulesResourceId string
@description('Required. Confidential VM managed disk security encryption type, such as VMGuestStateOnly or DiskWithVMGuestState.')
param confidentialVMOSDiskEncryptionType string
@description('Required. Resource ID of an existing data collection endpoint; empty skips its association.')
param dataCollectionEndpointResourceId string
@description('Required. Existing dedicated host group IDs; one applies to all VMs, otherwise entries align with the VM names. Used only when no dedicated hosts are supplied.')
param dedicatedHostGroupResourceIds string[]
@description('Required. Existing dedicated host IDs; one applies to all VMs, otherwise entries align with the VM names. Takes precedence over host groups.')
param dedicatedHostResourceIds string[]
@description('Optional. Resource ID of an existing disk access resource; empty selects DenyAll instead of AllowPrivate network access.')
param diskAccessId string = ''
@description('Required. Resource ID of an existing disk encryption set; empty uses platform-managed disk encryption.')
param diskEncryptionSetResourceId string
@description('Required. OS disk size in GB; zero preserves the image disk size.')
param diskSizeGB int
@description('Required. Managed OS disk storage account type.')
param diskSku string
@secure()
@description('Required. Domain account password used when domain operations are selected; otherwise pass an empty string.')
param domainJoinUserPassword string
@secure()
@description('Required. Domain account UPN used when domain operations are selected; otherwise pass an empty string.')
param domainJoinUserPrincipalName string
@description('Required. DNS domain name for selected domain operations; otherwise pass an empty string.')
param domainName string
@description('Required. Whether to enable accelerated networking on each session-host NIC.')
param enableAcceleratedNetworking bool
@description('Required. Whether to add an IPv6 configuration alongside IPv4 on each session-host NIC.')
param enableIPv6 bool
@description('Required. Whether to deploy Azure Monitor Agent and any supplied data collection associations.')
param enableMonitoring bool
@description('Required. Whether to enable encryption at host on the deployed VMs.')
param encryptionAtHost bool
@description('Required. Whether to forward enabled FSLogix configuration and required storage inputs to session-host initialization.')
param fslogixConfigureSessionHosts bool
@description('Required. FSLogix container selection forwarded to initialization; names containing CloudCache select its CloudCache argument.')
param fslogixContainerType string
@description('Required. Ordered share name strings for initialization, with profile before Office when both are present.')
param fslogixFileShareNames string[]
@description('Required. Array of local NetApp SMB server FQDN strings aligned with the ordered share names.')
param fslogixLocalNetAppServerFqdns string[]
@description('Required. Array of existing local Azure Files storage account IDs forwarded to FSLogix initialization.')
param fslogixLocalStorageAccountResourceIds string[]
@description('Required. Array of group name strings forwarded as the initialization script OSSGroups argument.')
param fslogixOSSGroups string[]
@description('Required. Array of remote NetApp SMB server FQDN strings aligned with the ordered share names.')
param fslogixRemoteNetAppServerFqdns string[]
@description('Required. Array of existing remote Azure Files storage account IDs for FSLogix Cloud Cache initialization.')
param fslogixRemoteStorageAccountResourceIds string[]
@description('Required. Profile container size in MB forwarded to session-host initialization.')
param fslogixSizeInMBs int
@description('Required. Storage backend name forwarded to initialization, AzureFiles or AzureNetAppFiles.')
param fslogixStorageService string
@description('Optional. Whether to enable the VM hibernation additional capability.')
param hibernationEnabled bool = false
@description('Required. Resource ID of the existing AVD host pool with an active registration token read during VM initialization; also used for ownership tags.')
param hostPoolResourceId string
@description('Required. Selected session-host or SMB identity mode used to choose domain, Entra, and storage configuration paths.')
param identitySolution string
@description('Required. Compute image reference object: { id } for a custom/Gallery image or { publisher, offer, sku, version } for marketplace images.')
param imageReference object
// Marketplace license type is derived from imageReference.publisher instead of this override.
@description('Optional. License type applied to custom/gallery image VMs; ignored for marketplace images.')
@allowed(['Windows_Client', 'Windows_Server'])
param customImageLicenseType string = 'Windows_Client'
@description('Required. Whether to deploy the Guest Attestation extension on each session host.')
param integrityMonitoring bool
@description('Required. Whether to pass the Intune MDM identifier to applicable Entra sign-in and initialization configuration.')
param intuneEnrollment bool
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. NIC name pattern containing SHNAME; empty uses the session-host name unchanged.')
param virtualMachineNicNameConv string
@description('Required. OS disk name pattern containing SHNAME; empty uses the shared naming policy disk pattern.')
param virtualMachineDiskNameConv string
@description('Required. Distinguished name of the target organizational unit for selected domain operations; empty uses the domain default.')
param ouPath string
@description('Required. Optional per-VM zone strings that override rotated zones when nonempty, aligned with VM names.')
param preferredZones string[]
@description('Required. Ordered artifact customization objects with name and blobNameOrUri, plus optional arguments and successExitCodes; empty skips customization commands.')
param sessionHostCustomizations artifactCustomizationType[]
@description('Required. Ordered session-host computer name strings, each ending in the numeric suffix used for placement.')
param sessionHostNames string[]
@description('Required. Numeric suffix values aligned one-to-one with sessionHostNames for availability-zone rotation and availability-set placement.')
param vmNumbers int[]
@description('Required. VM security type; Standard omits the security type and UEFI settings from the request.')
param securityType string
@description('Required. Whether to enable secure boot for a non-Standard VM security type.')
param secureBootEnabled bool
@description('Required. Resource ID of the existing session-host subnet used by each NIC.')
param subnetResourceId string
@description('Required. Tag bags keyed by Azure resource type; each bag is applied to resources of that type.')
param tags object
@description('Required. Windows time zone identifier forwarded to the initialization script.')
param timeZone string
@secure()
@description('Required. Local administrator password for the deployed VM.')
param virtualMachineAdminPassword string
@secure()
@description('Required. Local administrator account name for the deployed VM.')
param virtualMachineAdminUserName string
@description('Required. VM resource name pattern containing SHNAME; empty uses the session-host name unchanged.')
param virtualMachineNameConv string
@description('Required. Azure VM size for each session host.')
param virtualMachineSize string
@description('Required. Whether to enable virtual TPM for a non-Standard VM security type.')
param vTpmEnabled bool
@description('Required. Whether to deploy the AMD GPU driver extension and forward AMD initialization selection.')
param hasAmdGpu bool
@description('Required. Whether to deploy the NVIDIA GPU driver extension and forward NVIDIA initialization selection.')
param hasNvidiaGpu bool
@description('Optional. Resource ID of an existing Recovery Services vault; empty disables backup registration.')
param recoveryServicesVaultResourceId string = ''
@description('Optional. Name of the existing VM backup policy in the selected Recovery Services vault.')
param vmBackupPolicyName string = 'AvdPolicyVm'

@description('Changes on each deployment to force the domain-join extension to execute when configured.')
param domainJoinForceUpdateTag string = utcNow('yyyyMMddHHmmss')

var storageSuffix = environment().suffixes.storage

var sessionHostCount = length(sessionHostNames)

var effectiveFslogixLocalStorageAccountResourceIds = identitySolution == 'EntraId'
  ? take(fslogixLocalStorageAccountResourceIds, 1)
  : fslogixLocalStorageAccountResourceIds
var effectiveFslogixRemoteStorageAccountResourceIds = identitySolution == 'EntraId'
  ? take(fslogixRemoteStorageAccountResourceIds, 1)
  : fslogixRemoteStorageAccountResourceIds
var fslogixLocalStorageAccountNames = [for id in effectiveFslogixLocalStorageAccountResourceIds: last(split(id, '/'))]
var fslogixRemoteStorageAccountNames = [for id in effectiveFslogixRemoteStorageAccountResourceIds: last(split(id, '/'))]
var fslogixLocalStorageAccountKeys = identitySolution == 'EntraId' && !empty(effectiveFslogixLocalStorageAccountResourceIds)
  ? [localStorageAccounts[0].listkeys().keys[0].value]
  : []
var fslogixRemoteStorageAccountKeys = identitySolution == 'EntraId' && !empty(effectiveFslogixRemoteStorageAccountResourceIds)
  ? [remoteStorageAccounts[0].listkeys().keys[0].value]
  : []

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

var networkInterfaceNames = [for i in range(0, sessionHostCount): empty(virtualMachineNicNameConv) ? sessionHostNames[i] : replace(virtualMachineNicNameConv, 'SHNAME', sessionHostNames[i])]
var virtualMachineNames = [for i in range(0, sessionHostCount): empty(virtualMachineNameConv) ? sessionHostNames[i] : replace(virtualMachineNameConv, 'SHNAME', sessionHostNames[i])]
var osDiskNames = [for i in range(0, sessionHostCount): replace(empty(virtualMachineDiskNameConv) ? osDiskNamePattern : virtualMachineDiskNameConv, 'SHNAME', sessionHostNames[i])]

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' existing = {
  name: last(split(hostPoolResourceId, '/'))
  scope: resourceGroup(split(hostPoolResourceId, '/')[2], split(hostPoolResourceId, '/')[4])
}

resource localStorageAccounts 'Microsoft.Storage/storageAccounts@2023-01-01' existing = [
  for resId in effectiveFslogixLocalStorageAccountResourceIds: if (identitySolution == 'EntraId') {
    name: last(split(resId, '/'))
    scope: resourceGroup(split(resId, '/')[2], split(resId, '/')[4])
  }
]

resource remoteStorageAccounts 'Microsoft.Storage/storageAccounts@2023-01-01' existing = [
  for resId in effectiveFslogixRemoteStorageAccountResourceIds: if (identitySolution == 'EntraId') {
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
      licenseType: !empty(imageReference.?id)
        ? customImageLicenseType
        : (imageReference.?publisher == 'MicrosoftWindowsDesktop' ? 'Windows_Client' : 'Windows_Server')
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
      forceUpdateTag: domainJoinForceUpdateTag
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
      typeHandlerVersion: '1.1'
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
    name: '${virtualMachineNames[i]}-customizations'
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

// Initialization waits for identity/domain, GPU, monitoring, attestation, and customization steps.
// Disk network updates and backup registration below are separate module branches.
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
        script: loadTextContent('../../../scripts/Initialize-SessionHost.ps1')
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
    name: '${virtualMachineNames[i]}-update-os-disk-network-access'
    params: {
      diskAccessId: diskAccessId
      diskName: virtualMachine[i].properties.storageProfile.osDisk.name
      location: location
    }
  }
]

module vmBackupRegistration 'vmBackupItems.bicep' = if (!empty(recoveryServicesVaultResourceId)) {
  scope: resourceGroup(split(recoveryServicesVaultResourceId, '/')[2], split(recoveryServicesVaultResourceId, '/')[4])
  params: {
    hostPoolResourceId: hostPoolResourceId
    policyName: vmBackupPolicyName
    recoveryServicesVaultName: last(split(recoveryServicesVaultResourceId, '/'))!
    resourceGroupHosts: resourceGroup().name
    virtualMachineNames: [for i in range(0, sessionHostCount): virtualMachineNames[i]]
  }
}

@description('VM resource name strings in sessionHostNames order after applying virtualMachineNameConv.')
output virtualMachineNames array = [for i in range(0, sessionHostCount): virtualMachineNames[i]]
