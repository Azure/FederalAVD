@description('Required. The name of the virtual machine to be created. You should use a unique prefix to reduce name collisions in Active Directory. If no value is provided, a 10 character long unique string will be generated based on the Resource Group\'s name.')
param name string

@description('Optional. Can be used if the computer name needs to be different from the Azure VM resource name. If not used, the resource name will be used as computer name.')
param computerName string = name

@description('Required. Specifies the size for the VMs.')
param vmSize string

@description('Optional. This property can be used by user in the request to enable or disable the Host Encryption for the virtual machine. This will enable the encryption for all the disks including Resource/Temp disk at host itself. For security reasons, it is recommended to set encryptionAtHost to True. Restrictions: Cannot be enabled if Azure Disk Encryption (guest-VM encryption using bitlocker/DM-Crypt) is enabled on your VMs.')
param encryptionAtHost bool = true

@description('Optional. Specifies the SecurityType of the virtual machine. It is set as TrustedLaunch to enable UefiSettings.')
@allowed([
  'TrustedLaunch'
  'ConfidentialVM'
  'Standard'
])
param securityType string = 'Standard'

@description('Optional. Specifies whether secure boot should be enabled on the virtual machine. This parameter is part of the UefiSettings. SecurityType should be set to TrustedLaunch to enable UefiSettings.')
param secureBootEnabled bool = false

@description('Optional. Specifies whether vTPM should be enabled on the virtual machine. This parameter is part of the UefiSettings.  SecurityType should be set to TrustedLaunch to enable UefiSettings.')
param vTpmEnabled bool = false

@description('Required. OS image reference. In case of marketplace images, it\'s the combination of the publisher, offer, sku, version attributes. In case of custom images it\'s the resource ID of the custom image.')
param imageReference object

@description('Optional. Specifies information about the marketplace image used to create the virtual machine. This element is only used for marketplace images. Before you can use a marketplace image from an API, you must enable the image for programmatic use.')
param plan object = {}

@description('Required. Specifies the OS disk. For security reasons, it is recommended to specify DiskEncryptionSet into the osDisk object.  Restrictions: DiskEncryptionSet cannot be enabled if Azure Disk Encryption (guest-VM encryption using bitlocker/DM-Crypt) is enabled on your VMs.')
param osDisk object

@allowed([
  'SCSI'
  'NVMe'
])
@description('Optional. Specifies the disk controller type. Default value is SCSI.')
param diskControllerType string = 'SCSI'

@description('Optional. Specifies the data disks. For security reasons, it is recommended to specify DiskEncryptionSet into the dataDisk object. Restrictions: DiskEncryptionSet cannot be enabled if Azure Disk Encryption (guest-VM encryption using bitlocker/DM-Crypt) is enabled on your VMs.')
param dataDisks array = []

@description('Optional. Specifies the hibernation state for the virtual machine. Restrictions: Hibernation is not supported for virtual machines with nested virtualization enabled.')
param hibernationEnabled bool = false

@description('Optional. The flag that enables or disables a capability to have one or more managed data disks with UltraSSD_LRS storage account type on the VM or VMSS. Managed disks with storage account type UltraSSD_LRS can be added to a virtual machine or virtual machine scale set only if this property is enabled.')
param ultraSSDEnabled bool = false

@description('Required. Administrator username.')
@secure()
param adminUsername string

@description('Optional. When specifying a Windows Virtual Machine, this value should be passed.')
@secure()
param adminPassword string = ''

@description('Optional. Custom data associated to the VM, this value will be automatically converted into base64 to account for the expected VM format.')
param customData string = ''

@description('Optional. Specifies set of certificates that should be installed onto the virtual machine.')
param certificatesToBeInstalled array = []

@description('Optional. Specifies the priority for the virtual machine.')
@allowed([
  'Regular'
  'Low'
  'Spot'
])
param priority string = 'Regular'

@description('Optional. Specifies the eviction policy for the low priority virtual machine. Will result in \'Deallocate\' eviction policy.')
param enableEvictionPolicy bool = false

@description('Optional. Specifies the maximum price you are willing to pay for a low priority VM/VMSS. This price is in US Dollars.')
param maxPriceForLowPriorityVm int = -1

@description('Optional. Specifies resource ID about the dedicated host that the virtual machine resides in.')
param dedicatedHostId string = ''

@description('Optional. Specifies that the image or disk that is being used was licensed on-premises. This element is only used for images that contain the Windows Server operating system.')
@allowed([
  'Windows_Client'
  'Windows_Server'
  ''
])
param licenseType string = ''

@description('Optional. The list of SSH public keys used to authenticate with linux based VMs.')
param publicKeys array = []

@description('Optional. Enables system assigned managed identity on the resource. The system-assigned managed identity will automatically be enabled if extensionAadJoinConfig.enabled = "True".')
param systemAssignedIdentity bool = false

@description('Optional. The ID(s) to assign to the resource.')
param userAssignedIdentities object = {}

@description('Optional. Whether boot diagnostics should be enabled on the Virtual Machine. Boot diagnostics will be enabled with a managed storage account if no bootDiagnosticsStorageAccountName value is provided. If bootDiagnostics and bootDiagnosticsStorageAccountName values are not provided, boot diagnostics will be disabled.')
param bootDiagnostics bool = false

@description('Optional. Custom storage account used to store boot diagnostic information. Boot diagnostics will be enabled with a custom storage account if a value is provided.')
param bootDiagnosticStorageAccountName string = ''

@description('Optional. Storage account boot diagnostic base URI.')
param bootDiagnosticStorageAccountUri string = '.blob.${environment().suffixes.storage}/'

@description('Optional. Resource ID of a proximity placement group.')
param proximityPlacementGroupResourceId string = ''

@description('Optional. Resource ID of an availability set. Cannot be used in combination with availability zone nor scale set.')
param availabilitySetResourceId string = ''

@description('Optional. If set to 1, 2 or 3, the availability zone for all VMs is hardcoded to that value. If zero, then availability zones is not used. Cannot be used in combination with availability set nor scale set.')
@allowed([
  0
  1
  2
  3
])
param availabilityZone int = 0

// External resources
@description('Required. Configures NICs and PIPs.')
param nicConfigurations array

@description('Optional. The name of the PIP diagnostic setting, if deployed.')
param pipDiagnosticSettingsName string = '${name}-diagnosticSettings'

@description('Optional. The name of logs that will be streamed. "allLogs" includes all possible logs for the resource. Set to \'\' to disable log collection.')
@allowed([
  ''
  'allLogs'
  'DDoSProtectionNotifications'
  'DDoSMitigationFlowLogs'
  'DDoSMitigationReports'
])
param pipdiagnosticLogCategoriesToEnable array = [
  'allLogs'
]

@description('Optional. The name of metrics that will be streamed.')
@allowed([
  'AllMetrics'
])
param pipdiagnosticMetricsToEnable array = [
  'AllMetrics'
]

@description('Optional. The name of the NIC diagnostic setting, if deployed.')
param nicDiagnosticSettingsName string = '${name}-diagnosticSettings'

@description('Optional. The name of metrics that will be streamed.')
@allowed([
  'AllMetrics'
])
param nicdiagnosticMetricsToEnable array = [
  'AllMetrics'
]

// Child resources
@description('Optional. Specifies whether extension operations should be allowed on the virtual machine. This may only be set to False when no extensions are present on the virtual machine.')
param allowExtensionOperations bool = true

@description('Optional. Required if name is specified. Password of the user specified in user parameter.')
@secure()
param extensionDomainJoinPassword string = ''

@description('Optional. The configuration for the [Domain Join] extension. Must at least contain the ["enabled": true] property to be executed.')
param extensionDomainJoinConfig object = {
  enabled: false
}

@description('Optional. The configuration for the [AAD Join] extension. Must at least contain the ["enabled": true] property to be executed.')
param extensionAadJoinConfig object = {
  enabled: false
}

@description('Optional. The configuration for the [Anti Malware] extension. Must at least contain the ["enabled": true] property to be executed.')
param extensionAntiMalwareConfig object = {
  enabled: false
}

@description('Optional. The configuration for the [Monitoring Agent] extension. Must at least contain the ["enabled": true] property to be executed.')
param extensionMonitoringAgentConfig object = {
  enabled: false
}

@description('Optional. Resource ID of the monitoring log analytics workspace. Must be set when extensionMonitoringAgentConfig is set to true.')
param monitoringWorkspaceId string = ''

@description('Optional. The configuration for the [Dependency Agent] extension. Must at least contain the ["enabled": true] property to be executed.')
param extensionDependencyAgentConfig object = {
  enabled: false
}

@description('Optional. The configuration for the [Network Watcher Agent] extension. Must at least contain the ["enabled": true] property to be executed.')
param extensionNetworkWatcherAgentConfig object = {
  enabled: false
}

@description('Optional. The configuration for the [Azure Disk Encryption] extension. Must at least contain the ["enabled": true] property to be executed. Restrictions: Cannot be enabled on disks that have encryption at host enabled. Managed disks encrypted using Azure Disk Encryption cannot be encrypted using customer-managed keys.')
param extensionAzureDiskEncryptionConfig object = {
  enabled: false
}

@description('Optional. The configuration for the [Desired State Configuration] extension. Must at least contain the ["enabled": true] property to be executed.')
param extensionDSCConfig object = {
  enabled: false
}

@description('Optional. The configuration for the [Custom Script] extension. Must at least contain the ["enabled": true] property to be executed.')
param extensionCustomScriptConfig object = {
  enabled: false
  fileData: []
}

@description('Optional. Any object that contains the extension specific protected settings.')
@secure()
param extensionCustomScriptProtectedSetting object = {}

// Shared parameters
@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Optional. Resource ID of the diagnostic storage account.')
param diagnosticStorageAccountId string = ''

@description('Optional. Resource ID of the diagnostic log analytics workspace.')
param diagnosticWorkspaceId string = ''

@description('Optional. Resource ID of the diagnostic event hub authorization rule for the Event Hubs namespace in which the event hub should be created or streamed to.')
param diagnosticEventHubAuthorizationRuleId string = ''

@description('Optional. Name of the diagnostic event hub within the namespace to which logs are streamed. Without this, an event hub is created for each log category.')
param diagnosticEventHubName string = ''

@description('Optional. Tags of the resource.')
param tags object = {}

@description('Generated. Do not provide a value! This date value is used to generate a registration token.')
param baseTime string = utcNow('u')

@description('Optional. SAS token validity length to use to download files from storage accounts. Usage: \'PT8H\' - valid for 8 hours; \'P5D\' - valid for 5 days; \'P1Y\' - valid for 1 year. When not provided, the SAS token will be valid for 8 hours.')
param sasTokenValidityLength string = 'PT8H'

@description('Required. The chosen OS type.')
@allowed([
  'Windows'
  'Linux'
])
param osType string

@description('Optional. Specifies whether password authentication should be disabled.')
param disablePasswordAuthentication bool = false

@description('Optional. Indicates whether virtual machine agent should be provisioned on the virtual machine. When this property is not specified in the request body, default behavior is to set it to true. This will ensure that VM Agent is installed on the VM so that extensions can be added to the VM later.')
param provisionVMAgent bool = true

@description('Optional. Indicates whether Automatic Updates is enabled for the Windows virtual machine. Default value is true. When patchMode is set to Manual, this parameter must be set to false. For virtual machine scale sets, this property can be updated and updates will take effect on OS reprovisioning.')
param enableAutomaticUpdates bool = true

@description('Optional. VM guest patching orchestration mode. \'AutomaticByOS\' & \'Manual\' are for Windows only, \'ImageDefault\' for Linux only. Refer to \'https://learn.microsoft.com/en-us/azure/virtual-machines/automatic-vm-guest-patching\'.')
@allowed([
  'AutomaticByPlatform'
  'AutomaticByOS'
  'Manual'
  'ImageDefault'
  ''
])
param patchMode string = ''

@description('Optional. VM guest patching assessment mode. Set it to \'AutomaticByPlatform\' to enable automatically check for updates every 24 hours.')
@allowed([
  'AutomaticByPlatform'
  'ImageDefault'
])
param patchAssessmentMode string = 'ImageDefault'

@description('Optional. Specifies the time zone of the virtual machine. e.g. \'Pacific Standard Time\'. Possible values can be `TimeZoneInfo.id` value from time zones returned by `TimeZoneInfo.GetSystemTimeZones`.')
param timeZone string = ''

@description('Optional. Specifies additional base-64 encoded XML formatted information that can be included in the Unattend.xml file, which is used by Windows Setup. - AdditionalUnattendContent object.')
param additionalUnattendContent array = []

@description('Optional. Specifies the Windows Remote Management listeners. This enables remote Windows PowerShell. - WinRMConfiguration object.')
param winRM array = []

@description('Required. The configuration profile of automanage.')
@allowed([
  '/providers/Microsoft.Automanage/bestPractices/AzureBestPracticesProduction'
  '/providers/Microsoft.Automanage/bestPractices/AzureBestPracticesDevTest'
  ''
])
param configurationProfile string = ''

var publicKeysFormatted = [for publicKey in publicKeys: {
  path: publicKey.path
  keyData: publicKey.keyData
}]

var linuxConfiguration = {
  disablePasswordAuthentication: disablePasswordAuthentication
  ssh: {
    publicKeys: publicKeysFormatted
  }
  provisionVMAgent: provisionVMAgent
  patchSettings: (provisionVMAgent && (patchMode =~ 'AutomaticByPlatform' || patchMode =~ 'ImageDefault')) ? {
    patchMode: patchMode
    assessmentMode: patchAssessmentMode
  } : null
}

var windowsConfiguration = {
  provisionVMAgent: provisionVMAgent
  enableAutomaticUpdates: enableAutomaticUpdates
  patchSettings: (provisionVMAgent && (patchMode =~ 'AutomaticByPlatform' || patchMode =~ 'AutomaticByOS' || patchMode =~ 'Manual')) ? {
    patchMode: patchMode
    assessmentMode: patchAssessmentMode
  } : null
  timeZone: empty(timeZone) ? null : timeZone
  additionalUnattendContent: empty(additionalUnattendContent) ? null : additionalUnattendContent
  winRM: !empty(winRM) ? {
    listeners: winRM
  } : null
}

var accountSasProperties = {
  signedServices: 'b'
  signedPermission: 'r'
  signedExpiry: dateTimeAdd(baseTime, sasTokenValidityLength)
  signedResourceTypes: 'o'
  signedProtocol: 'https'
}

/* Determine Identity Type.
  First, we determine if the System-Assigned Managed Identity should be enabled.
    If AADJoin Extension is enabled then we automatically add SystemAssigned to the identityType because AADJoin requires the System-Assigned Managed Identity.
    If the AADJoin Extension is not enabled then we add SystemAssigned to the identityType only if the value of the systemAssignedIdentity parameter is true.
  Second, we determine if User Assigned Identities are assigned to the VM via the userAssignedIdentities parameter.
  Third, we take the outcome of these two values and determine the identityType
    If the System Identity and User Identities are assigned then the identityType is 'SystemAssigned, UserAssigned'
    If only the system Identity is assigned then the identityType is 'SystemAssigned'
    If only user managed Identities are assigned, then the identityType is 'UserAssigned'
    Finally, if no identities are assigned, then the identityType is 'none'.
*/
var identityType = (extensionAadJoinConfig.enabled ? true : systemAssignedIdentity) ? (!empty(userAssignedIdentities) ? 'SystemAssigned, UserAssigned' : 'SystemAssigned') : (!empty(userAssignedIdentities) ? 'UserAssigned' : 'None')

var identity = identityType != 'None' ? {
  type: identityType
  userAssignedIdentities: !empty(userAssignedIdentities) ? userAssignedIdentities : null
} : null

module vm_nic '.bicep/nested_networkInterface.bicep' = [for (nicConfiguration, index) in nicConfigurations: {
  name: '${uniqueString(deployment().name, location)}-VM-Nic-${index}'
  params: {
    networkInterfaceName: '${name}${nicConfiguration.nicSuffix}'
    virtualMachineName: name
    location: location
    tags: tags
    enableIPForwarding: contains(nicConfiguration, 'enableIPForwarding') ? (!empty(nicConfiguration.enableIPForwarding) ? nicConfiguration.enableIPForwarding : false) : false
    enableAcceleratedNetworking: nicConfiguration.?enableAcceleratedNetworking ?? true
    dnsServers: contains(nicConfiguration, 'dnsServers') ? (!empty(nicConfiguration.dnsServers) ? nicConfiguration.dnsServers : []) : []
    networkSecurityGroupResourceId: nicConfiguration.?networkSecurityGroupResourceId ?? ''
    ipConfigurations: nicConfiguration.ipConfigurations
    diagnosticStorageAccountId: diagnosticStorageAccountId
    diagnosticWorkspaceId: diagnosticWorkspaceId
    diagnosticEventHubAuthorizationRuleId: diagnosticEventHubAuthorizationRuleId
    diagnosticEventHubName: diagnosticEventHubName
    pipDiagnosticSettingsName: pipDiagnosticSettingsName
    nicDiagnosticSettingsName: nicDiagnosticSettingsName
    pipdiagnosticMetricsToEnable: pipdiagnosticMetricsToEnable
    pipdiagnosticLogCategoriesToEnable: pipdiagnosticLogCategoriesToEnable
    nicDiagnosticMetricsToEnable: nicdiagnosticMetricsToEnable
  }
}]

resource vm 'Microsoft.Compute/virtualMachines@2022-11-01' = {
  name: name
  location: location
  identity: identity
  tags: tags
  zones: availabilityZone != 0 ? array(availabilityZone) : null
  plan: !empty(plan) ? plan : null
  properties: {
    additionalCapabilities: {
      hibernationEnabled: hibernationEnabled
      ultraSSDEnabled: ultraSSDEnabled
    }
    hardwareProfile: {
      vmSize: vmSize
    }
    securityProfile: {
      encryptionAtHost: encryptionAtHost ? encryptionAtHost : null
      securityType: securityType != 'Standard' ? securityType : null
      uefiSettings: securityType != 'Standard' ? {
        secureBootEnabled: secureBootEnabled
        vTpmEnabled: vTpmEnabled
      } : null
    }
    storageProfile: {
      imageReference: imageReference
      diskControllerType: diskControllerType
      osDisk: {
        name: '${name}-disk-os-01'
        createOption: osDisk.?createOption ?? 'FromImage'
        deleteOption: osDisk.?deleteOption ?? 'Delete'
        diskSizeGB: osDisk.diskSizeGB
        caching: osDisk.?caching ?? 'ReadOnly'
        managedDisk: {
          storageAccountType: osDisk.managedDisk.storageAccountType
          diskEncryptionSet: contains(osDisk.managedDisk, 'diskEncryptionSet') ? {
            id: osDisk.managedDisk.diskEncryptionSet.id
          } : null
        }
      }
      dataDisks: [for (dataDisk, index) in dataDisks: {
        lun: index
        name: '${name}-disk-data-${padLeft((index + 1), 2, '0')}'
        diskSizeGB: dataDisk.diskSizeGB
        createOption: dataDisk.?createOption ?? 'Empty'
        deleteOption: dataDisk.?deleteOption ?? 'Delete'
        caching: dataDisk.?caching ?? 'ReadOnly'
        managedDisk: {
          storageAccountType: dataDisk.managedDisk.storageAccountType
          diskEncryptionSet: contains(dataDisk.managedDisk, 'diskEncryptionSet') ? {
            id: dataDisk.managedDisk.diskEncryptionSet.id
          } : null
        }
      }]
    }

    osProfile: {
      computerName: computerName
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: !empty(customData) ? base64(customData) : null
      windowsConfiguration: osType == 'Windows' ? windowsConfiguration : null
      linuxConfiguration: osType == 'Linux' ? linuxConfiguration : null
      secrets: certificatesToBeInstalled
      allowExtensionOperations: allowExtensionOperations
    }
    networkProfile: {
      networkInterfaces: [for (nicConfiguration, index) in nicConfigurations: {
        properties: {
          deleteOption: nicConfiguration.?deleteOption ?? 'Delete'
          primary: index == 0 ? true : false
        }
        id: resourceId('Microsoft.Network/networkInterfaces', '${name}${nicConfiguration.nicSuffix}')
      }]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: !empty(bootDiagnosticStorageAccountName) ? true : bootDiagnostics
        storageUri: !empty(bootDiagnosticStorageAccountName) ? 'https://${bootDiagnosticStorageAccountName}${bootDiagnosticStorageAccountUri}' : null
      }
    }
    availabilitySet: !empty(availabilitySetResourceId) ? {
      id: availabilitySetResourceId
    } : null
    proximityPlacementGroup: !empty(proximityPlacementGroupResourceId) ? {
      id: proximityPlacementGroupResourceId
    } : null
    priority: priority
    evictionPolicy: enableEvictionPolicy ? 'Deallocate' : null
    billingProfile: !empty(priority) && maxPriceForLowPriorityVm != -1 ? {
      maxPrice: maxPriceForLowPriorityVm
    } : null
    host: !empty(dedicatedHostId) ? {
      id: dedicatedHostId
    } : null
    licenseType: !empty(licenseType) ? licenseType : null
  }
  dependsOn: [
    vm_nic
  ]
}

resource vm_configurationProfileAssignment 'Microsoft.Automanage/configurationProfileAssignments@2021-04-30-preview' = if (!empty(configurationProfile)) {
  name: 'default'
  properties: {
    configurationProfile: configurationProfile
  }
  scope: vm
}

module vm_aadJoinExtension 'extension/main.bicep' = if (extensionAadJoinConfig.enabled) {
  name: '${uniqueString(deployment().name, location)}-VM-AADLogin'
  params: {
    virtualMachineName: vm.name
    location: location
    name: 'AADLogin'
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: osType == 'Windows' ? 'AADLoginForWindows' : 'AADSSHLoginforLinux'
    typeHandlerVersion: extensionAadJoinConfig.?typeHandlerVersion ?? '1.0'
    autoUpgradeMinorVersion: extensionAadJoinConfig.?autoUpgradeMinorVersion ?? true
    enableAutomaticUpgrade: extensionAadJoinConfig.?enableAutomaticUpgrade ?? false
    settings: extensionAadJoinConfig.?settings ?? {}
    tags: extensionAadJoinConfig.?tags ?? {}
  }
}

module vm_domainJoinExtension 'extension/main.bicep' = if (extensionDomainJoinConfig.enabled) {
  name: '${uniqueString(deployment().name, location)}-VM-DomainJoin'
  params: {
    virtualMachineName: vm.name
    location: location
    name: 'DomainJoin'
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: extensionDomainJoinConfig.?typeHandlerVersion ?? '1.3'
    autoUpgradeMinorVersion: extensionDomainJoinConfig.?autoUpgradeMinorVersion ?? true
    enableAutomaticUpgrade: extensionDomainJoinConfig.?enableAutomaticUpgrade ?? false
    settings: extensionDomainJoinConfig.settings
    tags: extensionDomainJoinConfig.?tags ?? {}
    protectedSettings: {
      Password: extensionDomainJoinPassword
    }
  }
}

module vm_microsoftAntiMalwareExtension 'extension/main.bicep' = if (extensionAntiMalwareConfig.enabled) {
  name: '${uniqueString(deployment().name, location)}-VM-MicrosoftAntiMalware'
  params: {
    virtualMachineName: vm.name
    location: location
    name: 'MicrosoftAntiMalware'
    publisher: 'Microsoft.Azure.Security'
    type: 'IaaSAntimalware'
    typeHandlerVersion: extensionAntiMalwareConfig.?typeHandlerVersion ?? '1.3'
    autoUpgradeMinorVersion: extensionAntiMalwareConfig.?autoUpgradeMinorVersion ?? true
    enableAutomaticUpgrade: extensionAntiMalwareConfig.?enableAutomaticUpgrade ?? false
    settings: extensionAntiMalwareConfig.settings
    tags: extensionAntiMalwareConfig.?tags ?? {}
  }
}

resource vm_logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-06-01' existing = if (!empty(monitoringWorkspaceId)) {
  name: last(split(monitoringWorkspaceId, '/'))!
  scope: az.resourceGroup(split(monitoringWorkspaceId, '/')[2], split(monitoringWorkspaceId, '/')[4])
}

module vm_microsoftMonitoringAgentExtension 'extension/main.bicep' = if (extensionMonitoringAgentConfig.enabled) {
  name: '${uniqueString(deployment().name, location)}-VM-MicrosoftMonitoringAgent'
  params: {
    virtualMachineName: vm.name
    location: location
    name: 'MicrosoftMonitoringAgent'
    publisher: 'Microsoft.EnterpriseCloud.Monitoring'
    type: osType == 'Windows' ? 'MicrosoftMonitoringAgent' : 'OmsAgentForLinux'
    typeHandlerVersion: extensionMonitoringAgentConfig.?typeHandlerVersion ?? (osType == 'Windows' ? '1.0' : '1.7')
    autoUpgradeMinorVersion: extensionMonitoringAgentConfig.?autoUpgradeMinorVersion ?? true
    enableAutomaticUpgrade: extensionMonitoringAgentConfig.?enableAutomaticUpgrade ?? false
    settings: {
      workspaceId: !empty(monitoringWorkspaceId) ? vm_logAnalyticsWorkspace.properties.customerId : ''
    }
    tags: extensionMonitoringAgentConfig.?tags ?? {}
    protectedSettings: {
      workspaceKey: !empty(monitoringWorkspaceId) ? vm_logAnalyticsWorkspace.listKeys().primarySharedKey : ''
    }
  }
}

module vm_dependencyAgentExtension 'extension/main.bicep' = if (extensionDependencyAgentConfig.enabled) {
  name: '${uniqueString(deployment().name, location)}-VM-DependencyAgent'
  params: {
    virtualMachineName: vm.name
    location: location
    name: 'DependencyAgent'
    publisher: 'Microsoft.Azure.Monitoring.DependencyAgent'
    type: osType == 'Windows' ? 'DependencyAgentWindows' : 'DependencyAgentLinux'
    typeHandlerVersion: extensionDependencyAgentConfig.?typeHandlerVersion ?? '9.5'
    autoUpgradeMinorVersion: extensionDependencyAgentConfig.?autoUpgradeMinorVersion ?? true
    enableAutomaticUpgrade: extensionDependencyAgentConfig.?enableAutomaticUpgrade ?? true
    tags: extensionDependencyAgentConfig.?tags ?? {}
  }
}

module vm_networkWatcherAgentExtension 'extension/main.bicep' = if (extensionNetworkWatcherAgentConfig.enabled) {
  name: '${uniqueString(deployment().name, location)}-VM-NetworkWatcherAgent'
  params: {
    virtualMachineName: vm.name
    location: location
    name: 'NetworkWatcherAgent'
    publisher: 'Microsoft.Azure.NetworkWatcher'
    type: osType == 'Windows' ? 'NetworkWatcherAgentWindows' : 'NetworkWatcherAgentLinux'
    typeHandlerVersion: extensionNetworkWatcherAgentConfig.?typeHandlerVersion ?? '1.4'
    autoUpgradeMinorVersion: extensionNetworkWatcherAgentConfig.?autoUpgradeMinorVersion ?? true
    enableAutomaticUpgrade: extensionNetworkWatcherAgentConfig.?enableAutomaticUpgrade ?? false
    tags: extensionNetworkWatcherAgentConfig.?tags ?? {}
  }
}

module vm_desiredStateConfigurationExtension 'extension/main.bicep' = if (extensionDSCConfig.enabled) {
  name: '${uniqueString(deployment().name, location)}-VM-DesiredStateConfiguration'
  params: {
    virtualMachineName: vm.name
    location: location
    name: 'DesiredStateConfiguration'
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: extensionDSCConfig.?typeHandlerVersion ?? '2.77'
    autoUpgradeMinorVersion: extensionDSCConfig.?autoUpgradeMinorVersion ?? true
    enableAutomaticUpgrade: extensionDSCConfig.?enableAutomaticUpgrade ?? false
    settings: extensionDSCConfig.?settings ?? {}
    tags: extensionDSCConfig.?tags ?? {}
    protectedSettings: extensionDSCConfig.?protectedSettings ?? {}
  }
}

module vm_customScriptExtension 'extension/main.bicep' = if (extensionCustomScriptConfig.enabled) {
  name: '${uniqueString(deployment().name, location)}-VM-CustomScriptExtension'
  params: {
    virtualMachineName: vm.name
    location: location
    name: 'CustomScriptExtension'
    publisher: osType == 'Windows' ? 'Microsoft.Compute' : 'Microsoft.Azure.Extensions'
    type: osType == 'Windows' ? 'CustomScriptExtension' : 'CustomScript'
    typeHandlerVersion: extensionCustomScriptConfig.?typeHandlerVersion ?? (osType == 'Windows' ? '1.10' : '2.1')
    autoUpgradeMinorVersion: extensionCustomScriptConfig.?autoUpgradeMinorVersion ?? true
    enableAutomaticUpgrade: extensionCustomScriptConfig.?enableAutomaticUpgrade ?? false
    settings: {
      fileUris: [for fileData in extensionCustomScriptConfig.fileData: contains(fileData, 'storageAccountId') ? '${fileData.uri}?${listAccountSas(fileData.storageAccountId, '2019-04-01', accountSasProperties).accountSasToken}' : fileData.uri]
    }
    tags: extensionCustomScriptConfig.?tags ?? {}
    protectedSettings: extensionCustomScriptProtectedSetting
  }
  dependsOn: [
    vm_desiredStateConfigurationExtension
  ]
}

module vm_azureDiskEncryptionExtension 'extension/main.bicep' = if (extensionAzureDiskEncryptionConfig.enabled) {
  name: '${uniqueString(deployment().name, location)}-VM-AzureDiskEncryption'
  params: {
    virtualMachineName: vm.name
    location: location
    name: 'AzureDiskEncryption'
    publisher: 'Microsoft.Azure.Security'
    type: osType == 'Windows' ? 'AzureDiskEncryption' : 'AzureDiskEncryptionForLinux'
    typeHandlerVersion: extensionAzureDiskEncryptionConfig.?typeHandlerVersion ?? (osType == 'Windows' ? '2.2' : '1.1')
    autoUpgradeMinorVersion: extensionAzureDiskEncryptionConfig.?autoUpgradeMinorVersion ?? true
    enableAutomaticUpgrade: extensionAzureDiskEncryptionConfig.?enableAutomaticUpgrade ?? false
    forceUpdateTag: extensionAzureDiskEncryptionConfig.?forceUpdateTag ?? '1.0'
    settings: extensionAzureDiskEncryptionConfig.settings
    tags: extensionAzureDiskEncryptionConfig.?tags ?? {}
  }
  dependsOn: [
    vm_customScriptExtension
    vm_microsoftMonitoringAgentExtension
  ]
}

@description('The name of the VM.')
output name string = vm.name

@description('The resource ID of the VM.')
output resourceId string = vm.id

@description('The name of the resource group the VM was created in.')
output resourceGroupName string = resourceGroup().name

@description('The principal ID of the system assigned identity.')
output systemAssignedPrincipalId string = systemAssignedIdentity && contains(vm.identity, 'principalId') ? vm.identity.principalId : ''

@description('The location the resource was deployed into.')
output location string = vm.location
