@description('The base URI where artifacts required by this template are located.')
param artifactsLocation string

@description('The availability zones to equally distribute VMs amongst')
param availabilityZones array = []

@description('(Required when vmImageType = Gallery) Gallery image Offer.')
param vmGalleryImageOffer string = ''

@description('(Required when vmImageType = Gallery) Gallery image Publisher.')
param vmGalleryImagePublisher string = ''

@description('Whether the VM image has a plan or not')
param vmGalleryImageHasPlan bool = false

@description('(Required when vmImageType = Gallery) Gallery image SKU.')
param vmGalleryImageSKU string = ''

@description('(Required when vmImageType = Gallery) Gallery image version.')
param vmGalleryImageVersion string = ''

@description('This prefix will be used in combination with the VM number to create the VM name. This value includes the dash, so if using “rdsh” as the prefix, VMs would be named “rdsh-0”, “rdsh-1”, etc. You should use a unique prefix to reduce name collisions in Active Directory.')
param rdshPrefix string = take(toLower(resourceGroup().name), 10)

@description('Number of session hosts that will be created and added to the hostpool.')
param rdshNumberOfInstances int

@description('The VM disk type for the VM: HDD, SSD or EOSD.')
@allowed([
  'Premium_LRS'
  'StandardSSD_LRS'
  'Standard_LRS'
  'CacheDisk'
  'ResourceDisk'
  'NvmeDisk'
])
param rdshVMDiskType string

@description('The size of the session host VMs.')
param rdshVmSize string = 'Standard_A2'

@description('The size of the disk on the vm in GB')
param rdshVmDiskSizeGB int = 0

@description('Whether or not the VM is hibernate enabled')
param rdshHibernate bool = false

@description('Enables Accelerated Networking feature, notice that VM size must support it, this is supported in most of general purpose and compute-optimized instances with 2 or more vCPUs, on instances that supports hyperthreading it is required minimum of 4 vCPUs.')
param enableAcceleratedNetworking bool = false

@description('The username for the domain admin account.')
param administratorAccountUsername string = ''

@description('The password associated with the domain admin account.')
@secure()
param administratorAccountPassword string = ''

@description('A username to be used as the virtual machine administrator account.')
param vmAdministratorAccountUsername string

@description('The password associated with the virtual machine administrator account.')
@secure()
param vmAdministratorAccountPassword string

@description('The unique id of the subnet for the nics.')
param subnet_id string

@description('The unique id of the load balancer backend pool id for the nics.')
param loadBalancerBackendPoolId string = ''

@description('Resource ID of the image.')
param rdshImageSourceId string = ''

@description('Location for all resources to be created in.')
param location string = ''

@description('The EdgeZone extended location of the session host VMs.')
param extendedLocation object = {}

@description('Whether to create a new network security group or use an existing one')
param createNetworkSecurityGroup bool = false

@description('The resource id of an existing network security group')
param networkSecurityGroupId string = ''

@description('The name of the new network security group')
param newNetworkSecurityGroupName string = ''

@description('The tags to be assigned to the network interfaces')
param networkInterfaceTags object = {}

@description('The tags to be assigned to the virtual machines')
param virtualMachineTags object = {}

@description('VM name prefix initial number.')
param vmInitialNumber int = 0

@description('The token for adding VMs to the hostpool')
@secure()
param hostpoolToken string

@description('The name of the hostpool')
param hostpoolName string

@description('OUPath for the domain join')
param ouPath string = ''

@description('Domain to join')
param domain string = ''

@description('IMPORTANT: You can use this parameter for the test purpose only as AAD Join is public preview. True if AAD Join, false if AD join')
param aadJoin bool = false

@description('IMPORTANT: Please don\'t use this parameter as intune enrollment is not supported yet. True if intune enrollment is selected.  False otherwise')
param intune bool = false

@description('Boot diagnostics object taken as body of Diagnostics Profile in VM creation')
param bootDiagnostics object = {
  enabled: false
}

@description('The name of user assigned identity that will assigned to the VMs. This is an optional parameter.')
param userAssignedIdentity string = ''

@description('The PowerShell script URL to be run as part of post update custom configuration')
param customConfigurationScriptUrl string = ''

@description('The timestamp for when template was executed.')
param customScriptTimestamp string = utcNow('yyyyMMddhhmmss')

@description('Session host configuration version of the host pool.')
param SessionHostConfigurationVersion string = ''

@description('System data is used for internal purposes, such as support preview features.')
param systemData object = {}

@description('Specifies the SecurityType of the virtual machine. It is set as TrustedLaunch to enable UefiSettings. Default: UefiSettings will not be enabled unless this property is set as TrustedLaunch.')
@allowed([
  'Standard'
  'TrustedLaunch'
  'ConfidentialVM'
])
param securityType string = 'Standard'

@description('Specifies whether secure boot should be enabled on the virtual machine.')
param secureBoot bool = false

@description('Specifies whether vTPM (Virtual Trusted Platform Module) should be enabled on the virtual machine.')
param vTPM bool = false

@description('Managed disk security encryption type.')
@allowed([
  'VMGuestStateOnly'
  'DiskWithVMGuestState'
])
param managedDiskSecurityEncryptionType string = 'VMGuestStateOnly'

var emptyArray = []
var domain_var = ((domain == '') ? last(split(administratorAccountUsername, '@')) : domain)
var storageAccountType = rdshVMDiskType
var nsgId = (createNetworkSecurityGroup
  ? resourceId('Microsoft.Network/networkSecurityGroups', newNetworkSecurityGroupName)
  : networkSecurityGroupId)
var planInfoEmpty = (empty(vmGalleryImageSKU) || empty(vmGalleryImagePublisher) || empty(vmGalleryImageOffer))
var marketplacePlan = {
  name: vmGalleryImageSKU
  publisher: vmGalleryImagePublisher
  product: vmGalleryImageOffer
}
var vmPlan = ((planInfoEmpty || (!vmGalleryImageHasPlan)) ? null : marketplacePlan)
var vmIdentityType = (aadJoin
  ? ((!empty(userAssignedIdentity)) ? 'SystemAssigned, UserAssigned' : 'SystemAssigned')
  : ((!empty(userAssignedIdentity)) ? 'UserAssigned' : 'None'))
var vmIdentityTypeProperty = {
  type: vmIdentityType
}
var vmUserAssignedIdentityProperty = {
  userAssignedIdentities: {
    '${resourceId('Microsoft.ManagedIdentity/userAssignedIdentities/',userAssignedIdentity)}': {}
  }
}
var vmIdentity = ((!empty(userAssignedIdentity))
  ? union(vmIdentityTypeProperty, vmUserAssignedIdentityProperty)
  : vmIdentityTypeProperty)

var securityProfile = {
  uefiSettings: {
    secureBootEnabled: secureBoot
    vTpmEnabled: vTPM
  }
  securityType: securityType
}
var managedDiskSecurityProfile = {
  securityEncryptionType: managedDiskSecurityEncryptionType
}
var countOfSelectedAZ = length(availabilityZones)
var loadBalancerBackendPoolIdArray = [
  {
    id: loadBalancerBackendPoolId
  }
]
var loadBalancerBackendAddressPools = (empty(loadBalancerBackendPoolId) ? null : loadBalancerBackendPoolIdArray)

resource nics 'Microsoft.Network/networkInterfaces@2022-11-01' = [
  for i in range(0, rdshNumberOfInstances): {
    name: '${rdshPrefix}${(i+vmInitialNumber)}-nic'
    location: location
    extendedLocation: (empty(extendedLocation) ? null : extendedLocation)
    tags: networkInterfaceTags
    properties: {
      ipConfigurations: [
        {
          name: 'ipconfig'
          properties: {
            privateIPAllocationMethod: 'Dynamic'
            subnet: {
              id: subnet_id
            }
            loadBalancerBackendAddressPools: loadBalancerBackendAddressPools
          }
        }
      ]
      enableAcceleratedNetworking: enableAcceleratedNetworking
      networkSecurityGroup: empty(nsgId)
        ? null
        : {
            id: nsgId
          }
    }
  }
]

resource vms_newType 'Microsoft.Compute/virtualMachines@2022-11-01' = [
  for i in range(0, rdshNumberOfInstances): if ((rdshVMDiskType == 'CacheDisk') || (rdshVMDiskType == 'ResourceDisk') || (rdshVMDiskType == 'NvmeDisk')) {
    name: '${rdshPrefix}${(i + vmInitialNumber)}'
    location: location
    extendedLocation: (empty(extendedLocation) ? null : extendedLocation)
    tags: virtualMachineTags
    plan: vmPlan
    identity: vmIdentity
    properties: {
      hardwareProfile: {
        vmSize: rdshVmSize
      }
      osProfile: {
        computerName: '${rdshPrefix}${(i + vmInitialNumber)}'
        adminUsername: vmAdministratorAccountUsername
        adminPassword: vmAdministratorAccountPassword
      }
      securityProfile: (securityType == 'TrustedLaunch' || securityType == 'ConfidentialVM') ? securityProfile : null
      storageProfile: {
        imageReference: {
          publisher: vmGalleryImagePublisher
          offer: vmGalleryImageOffer
          sku: vmGalleryImageSKU
          version: (empty(vmGalleryImageVersion) ? 'latest' : vmGalleryImageVersion)
        }
        osDisk: {
          deleteOption: 'Delete'
          createOption: 'FromImage'
          caching: 'ReadOnly'
          diffDiskSettings: {
            option: 'Local'
            placement: rdshVMDiskType
          }
        }
      }
      networkProfile: {
        networkInterfaces: [
          {
            id: nics[i].id
            properties: {
              deleteOption: 'Delete'
            }
          }
        ]
      }
      diagnosticsProfile: {
        bootDiagnostics: bootDiagnostics
      }
      additionalCapabilities: {
        hibernationEnabled: rdshHibernate
      }
      licenseType: 'Windows_Client'
    }
    zones: ((countOfSelectedAZ == 0) ? emptyArray : array(availabilityZones[(i % countOfSelectedAZ)]))
  }
]

resource vms_regularDisks 'Microsoft.Compute/virtualMachines@2022-11-01' = [
  for i in range(0, rdshNumberOfInstances): if ((rdshVMDiskType == 'Premium_LRS') || (rdshVMDiskType == 'StandardSSD_LRS') || (rdshVMDiskType == 'Standard_LRS')) {
    name: '${rdshPrefix}${(i + vmInitialNumber)}'
    location: location
    extendedLocation: (empty(extendedLocation) ? null : extendedLocation)
    tags: virtualMachineTags
    plan: vmPlan
    identity: vmIdentity
    properties: {
      hardwareProfile: {
        vmSize: rdshVmSize
      }
      osProfile: {
        computerName: '${rdshPrefix}${(i + vmInitialNumber)}'
        adminUsername: vmAdministratorAccountUsername
        adminPassword: vmAdministratorAccountPassword
      }
      securityProfile: (securityType == 'TrustedLaunch' || securityType == 'ConfidentialVM') ? securityProfile : null
      storageProfile: {
        imageReference: {
          publisher: vmGalleryImagePublisher
          offer: vmGalleryImageOffer
          sku: vmGalleryImageSKU
          version: (empty(vmGalleryImageVersion) ? 'latest' : vmGalleryImageVersion)
        }
        osDisk: {
          deleteOption: 'Delete'
          createOption: 'FromImage'
          diskSizeGB: rdshVmDiskSizeGB == 0 ? null : rdshVmDiskSizeGB
          managedDisk: {
            storageAccountType: storageAccountType
            securityProfile: securityType == 'ConfidentialVM' ? managedDiskSecurityProfile : null
          }
        }
      }
      networkProfile: {
        networkInterfaces: [
          {
            id: nics[i].id
            properties: {
              deleteOption: 'Delete'
            }
          }
        ]
      }
      diagnosticsProfile: {
        bootDiagnostics: bootDiagnostics
      }
      additionalCapabilities: {
        hibernationEnabled: rdshHibernate
      }
      licenseType: 'Windows_Client'
    }
    zones: ((countOfSelectedAZ == 0) ? emptyArray : array(availabilityZones[(i % countOfSelectedAZ)]))
  }
]

resource powerShell_DSC 'Microsoft.Compute/virtualMachines/extensions@2021-07-01' = [
  for i in range(0, rdshNumberOfInstances): {
    parent: vms_regularDisks[i]
    name: 'Microsoft.PowerShell.DSC'
    location: location
    properties: {
      publisher: 'Microsoft.Powershell'
      type: 'DSC'
      typeHandlerVersion: '2.73'
      autoUpgradeMinorVersion: true
      settings: {
        modulesUrl: artifactsLocation
        configurationFunction: 'Configuration.ps1\\AddSessionHost'
        properties: {
          hostPoolName: hostpoolName
          registrationInfoTokenCredential: {
            UserName: 'PLACEHOLDER_DO_NOT_USE'
            Password: 'PrivateSettingsRef:RegistrationInfoToken'
          }
          aadJoin: aadJoin
          UseAgentDownloadEndpoint: true
          aadJoinPreview: (contains(systemData, 'aadJoinPreview') && systemData.aadJoinPreview)
          mdmId: (intune ? '0000000a-0000-0000-c000-000000000000' : '')
          sessionHostConfigurationLastUpdateTime: SessionHostConfigurationVersion
        }
      }
      protectedSettings: {
        Items: {
          RegistrationInfoToken: hostpoolToken
        }
      }
    }
  }
]

resource rdshPrefix_vmInitialNumber_AADLoginForWindows 'Microsoft.Compute/virtualMachines/extensions@2021-07-01' = [
  for i in range(0, rdshNumberOfInstances): if (aadJoin && (contains(systemData, 'aadJoinPreview')
    ? (!systemData.aadJoinPreview)
    : true)) {
      parent: vms_regularDisks[i]
    name: 'AADLoginForWindows'
    location: location
    properties: {
      publisher: 'Microsoft.Azure.ActiveDirectory'
      type: 'AADLoginForWindows'
      typeHandlerVersion: '1.0'
      autoUpgradeMinorVersion: true
      settings: intune
        ? {
            mdmId: '0000000a-0000-0000-c000-000000000000'
          }
        : null

    dependsOn: [
      powerShell_DSC[i]
    ]
  }
    }
]
