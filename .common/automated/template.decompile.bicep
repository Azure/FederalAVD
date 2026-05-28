@description('Whether to automatically assign required roles to the user assigned identity.')
param userAssignedIdentityAutoAssignRoles bool = false

@description('The base URI where artifacts required by this template are located.')
param nestedTemplatesLocation string

@description('The base URI where artifacts required by this template are located.')
param artifactsLocation string

@description('The name of the Hostpool to be created.')
param hostpoolName string

@description('The token of the host pool where the session hosts will be added.')
@secure()
param hostpoolToken string

@description('The friendly name of the Hostpool to be created.')
param hostpoolFriendlyName string = ''

@description('The description of the Hostpool to be created.')
param hostpoolDescription string = ''

@description('The storage uri to put the diagnostic logs')
param hostpoolDiagnosticSettingsStorageAccount string = ''

@description('The description of the Hostpool to be created.')
param hostpoolDiagnosticSettingsLogAnalyticsWorkspaceId string = ''

@description('The event hub name to send logs to')
param hostpoolDiagnosticSettingsEventHubName string = ''

@description('The event hub policy to use')
param hostpoolDiagnosticSettingsEventHubAuthorizationId string = ''

@description('Categories of logs to be created for hostpools')
param hostpoolDiagnosticSettingsLogCategories array = [
  'Checkpoint'
  'Error'
  'Management'
  'Connection'
  'HostRegistration'
  'AgentHealthStatus'
  'NetworkData'
  'SessionHostManagement'
]

@description('Categories of logs to be created for app groups')
param appGroupDiagnosticSettingsLogCategories array = [
  'Checkpoint'
  'Error'
  'Management'
]

@description('Categories of logs to be created for workspaces')
param workspaceDiagnosticSettingsLogCategories array = [
  'Checkpoint'
  'Error'
  'Management'
  'Feed'
]

@description('The location where the resources will be deployed.')
param location string

@description('The name of the workspace to be attach to new Applicaiton Group.')
param workSpaceName string = ''

@description('The location of the workspace.')
param workspaceLocation string = ''

@description('The workspace resource group Name.')
param workspaceResourceGroup string = ''

@description('True if the workspace is new. False if there is no workspace added or adding to an existing workspace.')
param isNewWorkspace bool = false

@description('The existing app groups references of the workspace selected.')
param allApplicationGroupReferences string = ''

@description('Whether to add applicationGroup to workspace.')
param addToWorkspace bool

@description('The username vault resource id that corresponds to the existing domain username. IMPORTANT: make sure that vault resource id and secret uri are pointing to the same vault.')
@secure()
param administratorAccountUsernameVaultResourceId string = ''

@description('The username secret uri without version that corresponds to the existing domain username. IMPORTANT: make sure that vault resource id and secret uri are pointing to the same vault.')
@secure()
param administratorAccountUsernameSecretUri string = ''

@description('The password vault resource id that corresponds to the existing domain username. IMPORTANT: make sure that vault resource id and secret uri are pointing to the same vault.')
@secure()
param administratorAccountPasswordVaultResourceId string = ''

@description('The password secret uri without version that corresponds to the existing domain username. IMPORTANT: make sure that vault resource id and secret uri are pointing to the same vault.')
@secure()
param administratorAccountPasswordSecretUri string = ''

@description('The username vault resource id associated with the virtual machine administrator account.IMPORTANT: make sure that latest version of secret uri and password are the same.')
@secure()
param vmAdministratorAccountUsernameVaultResourceId string

@description('The username secret uri without version that corresponds to the existing domain username. IMPORTANT: make sure that vault resource id and secret uri are pointing to the same vault')
@secure()
param vmAdministratorAccountUsernameSecretUri string

@description('The password vault resource id associated with the virtual machine administrator account.IMPORTANT: make sure that latest version of secret uri and password are the same.')
@secure()
param vmAdministratorAccountPasswordVaultResourceId string

@description('The password secret uri without version that corresponds to the existing domain username. IMPORTANT: make sure that vault resource id and secret uri are pointing to the same vault')
@secure()
param vmAdministratorAccountPasswordSecretUri string

@description('The availability zones to equally distribute VMs amongst')
param availabilityZones array = []

@description('The resource group of the session host VMs.')
param vmResourceGroup string

@description('The location of the session host VMs.')
param vmLocation string = ''

@description('The EdgeZone extended location of the session host VMs.')
param vmExtendedLocation object = {}

@description('The size of the session host VMs.')
param vmSize string = ''

@description('The virtual machine type, normal vm is default empty, Hybrid vm will have value like HCI/Vmware/SCVMM...')
param vmKind string = ''

@description('The size of the session host VMs in GB. If the value of this parameter is 0, the disk will be created with the default size set in the image.')
param vmDiskSizeGB int = 0

@description('Whether the VMs created will be hibernate enabled')
param vmHibernate bool = false

@description('Number of session hosts that will be created and added to the hostpool.')
param vmNumberOfInstances int = 0

@description('This prefix will be used in combination with the VM number to create the VM name. If using \'rdsh\' as the prefix, VMs would be named \'rdsh-0\', \'rdsh-1\', etc. You should use a unique prefix to reduce name collisions in Active Directory.')
param vmNamePrefix string = ''

@description('Select the image source for the session host vms. VMs from a Gallery image will be created with Managed Disks.')
@allowed([
  'CustomImage'
  'Gallery'
])
param vmImageType string = 'Gallery'

@description('(Required when vmImageType = Gallery) Gallery image Offer.')
param vmGalleryImageOffer string = ''

@description('(Required when vmImageType = Gallery) Gallery image Publisher.')
param vmGalleryImagePublisher string = ''

@description('Whether the VM has plan or not')
param vmGalleryImageHasPlan bool = false

@description('(Required when vmImageType = Gallery) Gallery image SKU.')
param vmGalleryImageSKU string = ''

@description('(Required when vmImageType = Gallery) Gallery image version.')
param vmGalleryImageVersion string = ''

@description('(Required when vmImageType = CustomImage) Resource ID of the image')
param vmCustomImageSourceId string = ''

@description('The VM disk type for the VM: HDD or SSD.')
@allowed([
  'Premium_LRS'
  'StandardSSD_LRS'
  'Standard_LRS'
])
param vmDiskType string = 'StandardSSD_LRS'

@description('Whether to enable public API version for EOSD support')
param enableEOSDPublicAPIVersion bool = false

@description('Whether to enable EOSD.')
param eosdEnabled bool = false

@description('The EOSD type for the VM: CacheDisk or TempDisk.')
@allowed([
  ''
  'CacheDisk'
  'TempDisk'
])
param eosdType string = ''

@description('The name of the virtual network the VMs will be connected to.')
param existingVnetName string = ''

@description('The subnet the VMs will be placed in.')
param existingSubnetName string = ''

@description('The resource group containing the existing virtual network.')
param virtualNetworkResourceGroupName string = ''

@description('Whether to create a new network security group or use an existing one')
param createNetworkSecurityGroup bool = false

@description('The resource id of an existing network security group')
param networkSecurityGroupId string = ''

@description('The rules to be given to the new network security group')
param networkSecurityGroupRules array = []

@description('Set this parameter to Personal if you would like to enable Persistent Desktop experience. Defaults to false.')
@allowed([
  'Personal'
  'Pooled'
])
param hostpoolType string

@description('LoadBalancer backend pool id')
param loadBalancerBackendPoolId string = ''

@description('Set the type of assignment for a Personal hostpool type')
@allowed([
  'Automatic'
  'Direct'
  ''
])
param personalDesktopAssignmentType string = ''

@description('Maximum number of sessions.')
param maxSessionLimit int = 99999

@description('Type of load balancer algorithm.')
@allowed([
  'BreadthFirst'
  'DepthFirst'
  'Persistent'
])
param loadBalancerType string = 'BreadthFirst'

@description('Hostpool rdp properties')
param customRdpProperty string = ''

@description('The necessary information for adding more VMs to this Hostpool')
param vmTemplate string = ''

@description('The tags to be assigned to the virtual machines')
param virtualMachineTags object = {}

@description('AVD api version')
param apiVersion string = '2019-12-10-preview'

@description('GUID for the deployment')
param deploymentId string = ''

@description('Whether to use validation enviroment.')
param validationEnvironment bool = false

@description('Preferred App Group type to display')
param preferredAppGroupType string = 'Desktop'

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

@description('PowerShell script URL to be run after the Virtual Machines are created.')
param customConfigurationScriptUrl string = ''

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

@description('Specifies which network routes are permitted for end users connecting to resources for this host pool and session hosts.')
@allowed([
  'Disabled'
  'Enabled'
  'EnabledForSessionHostsOnly'
  'EnabledForClientsOnly'
])
param publicNetworkAccess string = 'Enabled'

@description('Timestamp used on Session Host Management creation')
param defaultTimestamp string = utcNow('yyyy-MM-ddTHH:mm')

@description('Default timezone used in Session Host Management creation')
param defaultTimeZone string = 'UTC'

@description('Value is SystemAssigned, UserAssigned, or None')
param identityType string = ''

@description('(Required when identityType = UserAssigned) Resource ID of user assigned identity that will assigned to the host pool.')
param userAssignedIdentityResourceId string = ''

@description('enable session host provisioning feature or not')
param enableSessionHostProvisioning bool = false

var emptyArray = []
var desktopVirtualizationVirtualMachineContributor = 'a959dbd1-f747-45e3-8ba6-dd80f235f97c'
var virtualMachineContributor = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
var keyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var eosdApiVersion = (enableEOSDPublicAPIVersion ? '2025-04-01-preview' : '2024-07-15-privatepreview')
var autoAssignRoles = ((identityType == 'SystemAssigned') || ((identityType == 'UserAssigned') && (!empty(userAssignedIdentityResourceId)) && userAssignedIdentityAutoAssignRoles))
var createVMs = (vmNumberOfInstances > 0)
var rdshPrefix = '${vmNamePrefix}-'
var vnet_id = resourceId(virtualNetworkResourceGroupName, 'Microsoft.Network/virtualNetworks', existingVnetName)
var subnet_id = resourceId(
  virtualNetworkResourceGroupName,
  'Microsoft.Network/virtualNetworks/subnets',
  existingVnetName,
  existingSubnetName
)
var nsg_id = (createNetworkSecurityGroup
  ? resourceId('Microsoft.Network/networkSecurityGroups', newNetworkSecurityGroupName)
  : (empty(networkSecurityGroupId) ? null : networkSecurityGroupId))
var hostpoolName_var = replace(hostpoolName, '"', '')
var vmTemplateName = 'managedDisks-${toLower(replace(vmImageType,' ',''))}vm'
var vmTemplateUri = '${nestedTemplatesLocation}${vmTemplateName}.json'
var rdshVmNamesOutput = {
  rdshVmNamesCopy: [
    for j in range(0, (createVMs ? vmNumberOfInstances : 1)): {
      name: concat(rdshPrefix, j)
    }
  ]
}
var appGroupName = '${hostpoolName_var}-DAG'
var appGroupResourceId = [
  appGroup.id
]
var workspaceResourceGroup_var = (empty(workspaceResourceGroup) ? resourceGroup().name : workspaceResourceGroup)
var vmCustomImageResourceGroup = (empty(vmCustomImageSourceId)
  ? resourceGroup().name
  : split(vmCustomImageSourceId, '/')[4])
var nsgResourceGroup = (empty(nsg_id) ? resourceGroup().name : split(nsg_id, '/')[4])
var applicationGroupReferencesArr = (('' == allApplicationGroupReferences)
  ? appGroupResourceId
  : concat(split(allApplicationGroupReferences, ','), appGroupResourceId))
var hostpoolProps = {
  friendlyName: hostpoolFriendlyName
  description: hostpoolDescription
  hostpoolType: hostpoolType
  personalDesktopAssignmentType: personalDesktopAssignmentType
  maxSessionLimit: maxSessionLimit
  loadBalancerType: loadBalancerType
  validationEnvironment: validationEnvironment
  preferredAppGroupType: preferredAppGroupType
  ring: null
  vmTemplate: vmTemplate
  customRdpProperty: (empty(customRdpProperty) ? null : customRdpProperty)
  managementType: 'Automated'
  publicNetworkAccess: publicNetworkAccess
}
var workspacePublicNetworkAccess = ((publicNetworkAccess == 'EnabledForClientsOnly') ? 'Enabled' : publicNetworkAccess)
var newNetworkSecurityGroupName = '${rdshPrefix}nsg-${deploymentId}'
var sessionHostConfigurationImageMarketplaceInfoProps = {
  publisher: vmGalleryImagePublisher
  offer: vmGalleryImageOffer
  sku: vmGalleryImageSKU
  exactVersion: vmGalleryImageVersion
}
var sessionHostConfigurationImageCustomInfoProps = {
  resourceId: vmCustomImageSourceId
}
var sessionHostConfigurationDomainAzureActiveDirectoryInfoProps = {
  mdmProviderGuid: (intune ? '0000000a-0000-0000-c000-000000000000' : null)
}
var vmAdministratorAccountUsernameSecretName = split(vmAdministratorAccountUsernameSecretUri, '/secrets/')[1]
var vmAdministratorAccountPasswordSecretName = split(vmAdministratorAccountPasswordSecretUri, '/secrets/')[1]
var adDomainJoinUsernameSecretName = ((!aadJoin)
  ? split(administratorAccountUsernameSecretUri, '/secrets/')[1]
  : vmAdministratorAccountUsernameSecretName)
var adDomainJoinPasswordSecretName = ((!aadJoin)
  ? split(administratorAccountPasswordSecretUri, '/secrets/')[1]
  : vmAdministratorAccountPasswordSecretName)
var adDomainJoinUsernameVaultResourceId = ((!aadJoin)
  ? administratorAccountUsernameVaultResourceId
  : vmAdministratorAccountUsernameVaultResourceId)
var adDomainJoinPasswordVaultResourceId = ((!aadJoin)
  ? administratorAccountPasswordVaultResourceId
  : vmAdministratorAccountPasswordVaultResourceId)
var sendLogsToStorageAccount = (!empty(hostpoolDiagnosticSettingsStorageAccount))
var sendLogsToLogAnalytics = (!empty(hostpoolDiagnosticSettingsLogAnalyticsWorkspaceId))
var sendLogsToEventHub = (!empty(hostpoolDiagnosticSettingsEventHubName))
var storageAccountIdProperty = (sendLogsToStorageAccount ? hostpoolDiagnosticSettingsStorageAccount : null)
var hostpoolDiagnosticSettingsLogProperties = [
  for item in hostpoolDiagnosticSettingsLogCategories: {
    category: item
    enabled: true
    retentionPolicy: {
      enabled: false
      days: 0
    }
  }
]
var appGroupDiagnosticSettingsLogProperties = [
  for item in appGroupDiagnosticSettingsLogCategories: {
    category: item
    enabled: true
    retentionPolicy: {
      enabled: false
      days: 0
    }
  }
]
var workspaceDiagnosticSettingsLogProperties = [
  for item in workspaceDiagnosticSettingsLogCategories: {
    category: item
    enabled: true
    retentionPolicy: {
      enabled: false
      days: 0
    }
  }
]

module KeyVaultSecretRetrieval_deploymentId './nested_KeyVaultSecretRetrieval_deploymentId.bicep' = if (!aadJoin) {
  name: 'KeyVaultSecretRetrieval-${deploymentId}'
  params: {
    administratorAccountUsernameValue: ((domain == '') ? 'placeholder@contoso.com' : 'placeholder@${domain}')
    administratorAccountUsernameSecretUri: administratorAccountUsernameSecretUri
    administratorAccountPasswordSecretUri: administratorAccountPasswordSecretUri
    domain: domain
    ouPath: ouPath
  }
}

resource hostpool 'Microsoft.DesktopVirtualization/hostpools@${apiVersion}' = {
  name: hostpoolName
  location: location
  identity: (empty(identityType)
    ? json('null')
    : json('{"type": "${identityType}"${((identityType=='UserAssigned')?', "userAssignedIdentities": {"${userAssignedIdentityResourceId}": {}}':'')}}'))
  properties: hostpoolProps
  dependsOn: [
    KeyVaultSecretRetrieval_deploymentId
  ]
}

@description('Assigns the Desktop Virtualization Virtual Machine Contributor role to the managed identity of the host pool for the host pool.')
resource hostpoolName_AssignRole_HostPool_deploymentId 'Microsoft.DesktopVirtualization/hostpools/Microsoft.Resources/deployments@2021-04-01' = if (autoAssignRoles) {
  name: '${hostpoolName}/AssignRole-HostPool-${deploymentId}'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: [
        {
          type: 'Microsoft.Authorization/roleAssignments'
          scope: hostpool.id
          apiVersion: '2022-04-01'
          name: guid(concat(
            ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : deploymentId),
            desktopVirtualizationVirtualMachineContributor,
            hostpoolName
          ))
          properties: {
            roleDefinitionId: resourceId(
              'Microsoft.Authorization/roleDefinitions',
              desktopVirtualizationVirtualMachineContributor
            )
            principalId: ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : ((identityType == 'SystemAssigned')
                  ? reference(
                      'Microsoft.DesktopVirtualization/hostpools/${hostpoolName_var}',
                      '2024-11-01-preview',
                      'Full'
                    ).identity.principalId
                  : ''))
            principalType: 'ServicePrincipal'
          }
          condition: ((!empty(identityType)) && (identityType != 'None') && (!empty(hostpoolName)))
        }
      ]
    }
  }
}

@description('Assigns the Desktop Virtualization Virtual Machine Contributor role to the managed identity of the host pool for the session host VMs.')
resource hostpoolName_AssignRole_SessionHost_deploymentId 'Microsoft.DesktopVirtualization/hostpools/Microsoft.Resources/deployments@2021-04-01' = if (autoAssignRoles) {
  name: '${hostpoolName}/AssignRole-SessionHost-${deploymentId}'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: [
        {
          type: 'Microsoft.Authorization/roleAssignments'
          apiVersion: '2022-04-01'
          name: guid(concat(
            ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : deploymentId),
            desktopVirtualizationVirtualMachineContributor,
            vmResourceGroup
          ))
          properties: {
            roleDefinitionId: resourceId(
              'Microsoft.Authorization/roleDefinitions',
              desktopVirtualizationVirtualMachineContributor
            )
            principalId: ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : ((identityType == 'SystemAssigned')
                  ? reference(
                      'Microsoft.DesktopVirtualization/hostpools/${hostpoolName_var}',
                      '2024-11-01-preview',
                      'Full'
                    ).identity.principalId
                  : ''))
            principalType: 'ServicePrincipal'
          }
          condition: ((!empty(identityType)) && (identityType != 'None') && (!empty(vmResourceGroup)))
        }
      ]
    }
  }
  dependsOn: [
    hostpool
  ]
}

@description('Assigns the Desktop Virtualization Virtual Machine Contributor role to the managed identity of the host pool for the custom image resource group.')
resource hostpoolName_AssignRole_CustomImage_deploymentId 'Microsoft.DesktopVirtualization/hostpools/Microsoft.Resources/deployments@2021-04-01' = if (autoAssignRoles) {
  name: '${hostpoolName}/AssignRole-CustomImage-${deploymentId}'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: [
        {
          type: 'Microsoft.Authorization/roleAssignments'
          apiVersion: '2022-04-01'
          name: guid(concat(
            ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : deploymentId),
            desktopVirtualizationVirtualMachineContributor,
            vmCustomImageResourceGroup
          ))
          properties: {
            roleDefinitionId: resourceId(
              'Microsoft.Authorization/roleDefinitions',
              desktopVirtualizationVirtualMachineContributor
            )
            principalId: ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : ((identityType == 'SystemAssigned')
                  ? reference(
                      'Microsoft.DesktopVirtualization/hostpools/${hostpoolName_var}',
                      '2024-11-01-preview',
                      'Full'
                    ).identity.principalId
                  : ''))
            principalType: 'ServicePrincipal'
          }
          condition: ((!empty(identityType)) && (identityType != 'None') && (!empty(vmCustomImageSourceId)) && (!empty(vmCustomImageResourceGroup)))
        }
      ]
    }
  }
  dependsOn: [
    hostpool
  ]
}

@description('Assigns the Desktop Virtualization Virtual Machine Contributor role to the managed identity of the host pool for the VNet in SHC.')
resource hostpoolName_AssignRole_VNet_deploymentId 'Microsoft.DesktopVirtualization/hostpools/Microsoft.Resources/deployments@2021-04-01' = if (autoAssignRoles) {
  name: '${hostpoolName}/AssignRole-VNet-${deploymentId}'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: [
        {
          type: 'Microsoft.Authorization/roleAssignments'
          scope: vnet_id
          apiVersion: '2022-04-01'
          name: guid(concat(
            ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : deploymentId),
            desktopVirtualizationVirtualMachineContributor,
            vnet_id
          ))
          properties: {
            roleDefinitionId: resourceId(
              'Microsoft.Authorization/roleDefinitions',
              desktopVirtualizationVirtualMachineContributor
            )
            principalId: ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : ((identityType == 'SystemAssigned')
                  ? reference(
                      'Microsoft.DesktopVirtualization/hostpools/${hostpoolName_var}',
                      '2024-11-01-preview',
                      'Full'
                    ).identity.principalId
                  : ''))
            principalType: 'ServicePrincipal'
          }
          condition: ((!empty(identityType)) && (identityType != 'None') && (!empty(virtualNetworkResourceGroupName)) && (!empty(vnet_id)))
        }
        {
          type: 'Microsoft.Authorization/roleAssignments'
          scope: subnet_id
          apiVersion: '2022-04-01'
          name: guid(concat(
            ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : deploymentId),
            desktopVirtualizationVirtualMachineContributor,
            subnet_id
          ))
          properties: {
            roleDefinitionId: resourceId(
              'Microsoft.Authorization/roleDefinitions',
              desktopVirtualizationVirtualMachineContributor
            )
            principalId: ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : ((identityType == 'SystemAssigned')
                  ? reference(
                      'Microsoft.DesktopVirtualization/hostpools/${hostpoolName_var}',
                      '2024-11-01-preview',
                      'Full'
                    ).identity.principalId
                  : ''))
            principalType: 'ServicePrincipal'
          }
          condition: ((!empty(identityType)) && (identityType != 'None') && (!empty(virtualNetworkResourceGroupName)) && (!empty(subnet_id)))
        }
      ]
    }
  }
  dependsOn: [
    hostpool
  ]
}

@description('Assigns the Desktop Virtualization Virtual Machine Contributor role to the managed identity of the host pool for the NSG in SHC.')
resource hostpoolName_AssignRole_Nsg_deploymentId 'Microsoft.DesktopVirtualization/hostpools/Microsoft.Resources/deployments@2021-04-01' = if (autoAssignRoles) {
  name: '${hostpoolName}/AssignRole-Nsg-${deploymentId}'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: [
        {
          type: 'Microsoft.Authorization/roleAssignments'
          scope: nsg_id
          apiVersion: '2022-04-01'
          name: guid(concat(
            ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : deploymentId),
            desktopVirtualizationVirtualMachineContributor,
            ((nsg_id == null) ? '' : nsg_id)
          ))
          properties: {
            roleDefinitionId: resourceId(
              'Microsoft.Authorization/roleDefinitions',
              desktopVirtualizationVirtualMachineContributor
            )
            principalId: ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : ((identityType == 'SystemAssigned')
                  ? reference(
                      'Microsoft.DesktopVirtualization/hostpools/${hostpoolName_var}',
                      '2024-11-01-preview',
                      'Full'
                    ).identity.principalId
                  : ''))
            principalType: 'ServicePrincipal'
          }
          condition: ((!empty(identityType)) && (identityType != 'None') && (!empty(nsgResourceGroup)) && (!empty(nsg_id)))
        }
        {
          type: 'Microsoft.Authorization/roleAssignments'
          scope: nsg_id
          apiVersion: '2022-04-01'
          name: guid(concat(
            ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : deploymentId),
            virtualMachineContributor,
            ((nsg_id == null) ? '' : nsg_id)
          ))
          properties: {
            roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', virtualMachineContributor)
            principalId: ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : ((identityType == 'SystemAssigned')
                  ? reference(
                      'Microsoft.DesktopVirtualization/hostpools/${hostpoolName_var}',
                      '2024-11-01-preview',
                      'Full'
                    ).identity.principalId
                  : ''))
            principalType: 'ServicePrincipal'
          }
          condition: ((!empty(identityType)) && (identityType != 'None') && (!empty(nsgResourceGroup)) && (!empty(nsg_id)))
        }
      ]
    }
  }
  dependsOn: [
    hostpool
  ]
}

@description('Assigns the Key Vault Secrets User role to the managed identity for the admin account key vault in SHC.')
resource hostpoolName_AssignRole_AdminUserKV_deploymentId 'Microsoft.DesktopVirtualization/hostpools/Microsoft.Resources/deployments@2021-04-01' = if (autoAssignRoles) {
  name: '${hostpoolName}/AssignRole-AdminUserKV-${deploymentId}'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: [
        {
          type: 'Microsoft.Authorization/roleAssignments'
          scope: administratorAccountUsernameVaultResourceId
          apiVersion: '2022-04-01'
          name: guid(concat(
            ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : deploymentId),
            keyVaultSecretsUser,
            administratorAccountUsernameVaultResourceId
          ))
          properties: {
            roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUser)
            principalId: ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : ((identityType == 'SystemAssigned')
                  ? reference(
                      'Microsoft.DesktopVirtualization/hostpools/${hostpoolName_var}',
                      '2024-11-01-preview',
                      'Full'
                    ).identity.principalId
                  : ''))
            principalType: 'ServicePrincipal'
          }
          condition: ((!empty(identityType)) && (identityType != 'None') && (!empty(administratorAccountUsernameVaultResourceId)))
        }
      ]
    }
  }
  dependsOn: [
    hostpool
  ]
}

@description('Assigns the Key Vault Secrets User role to the managed identity for the admin account key vault in SHC.')
resource hostpoolName_AssignRole_AdminPassKV_deploymentId 'Microsoft.DesktopVirtualization/hostpools/Microsoft.Resources/deployments@2021-04-01' = if (autoAssignRoles) {
  name: '${hostpoolName}/AssignRole-AdminPassKV-${deploymentId}'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: [
        {
          type: 'Microsoft.Authorization/roleAssignments'
          scope: administratorAccountPasswordVaultResourceId
          apiVersion: '2022-04-01'
          name: guid(concat(
            ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : deploymentId),
            keyVaultSecretsUser,
            administratorAccountPasswordVaultResourceId
          ))
          properties: {
            roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUser)
            principalId: ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : ((identityType == 'SystemAssigned')
                  ? reference(
                      'Microsoft.DesktopVirtualization/hostpools/${hostpoolName_var}',
                      '2024-11-01-preview',
                      'Full'
                    ).identity.principalId
                  : ''))
            principalType: 'ServicePrincipal'
          }
          condition: ((!empty(identityType)) && (identityType != 'None') && (!empty(administratorAccountPasswordVaultResourceId)))
        }
      ]
    }
  }
  dependsOn: [
    hostpool
  ]
}

@description('Assigns the Key Vault Secrets User role to the managed identity for the VM admin account key vault in SHC.')
resource hostpoolName_AssignRole_VMAdminUserKV_deploymentId 'Microsoft.DesktopVirtualization/hostpools/Microsoft.Resources/deployments@2021-04-01' = if (autoAssignRoles) {
  name: '${hostpoolName}/AssignRole-VMAdminUserKV-${deploymentId}'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: [
        {
          type: 'Microsoft.Authorization/roleAssignments'
          scope: vmAdministratorAccountUsernameVaultResourceId
          apiVersion: '2022-04-01'
          name: guid(concat(
            ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : deploymentId),
            keyVaultSecretsUser,
            vmAdministratorAccountUsernameVaultResourceId
          ))
          properties: {
            roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUser)
            principalId: ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : ((identityType == 'SystemAssigned')
                  ? reference(
                      'Microsoft.DesktopVirtualization/hostpools/${hostpoolName_var}',
                      '2024-11-01-preview',
                      'Full'
                    ).identity.principalId
                  : ''))
            principalType: 'ServicePrincipal'
          }
          condition: ((!empty(identityType)) && (identityType != 'None') && (!empty(vmAdministratorAccountUsernameVaultResourceId)))
        }
      ]
    }
  }
  dependsOn: [
    hostpool
  ]
}

@description('Assigns the Key Vault Secrets User role to the managed identity for the VM admin account key vault in SHC.')
resource hostpoolName_AssignRole_VMAdminPassKV_deploymentId 'Microsoft.DesktopVirtualization/hostpools/Microsoft.Resources/deployments@2021-04-01' = if (autoAssignRoles) {
  name: '${hostpoolName}/AssignRole-VMAdminPassKV-${deploymentId}'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: [
        {
          type: 'Microsoft.Authorization/roleAssignments'
          scope: vmAdministratorAccountPasswordVaultResourceId
          apiVersion: '2022-04-01'
          name: guid(concat(
            ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : deploymentId),
            keyVaultSecretsUser,
            vmAdministratorAccountPasswordVaultResourceId
          ))
          properties: {
            roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUser)
            principalId: ((identityType == 'UserAssigned')
              ? reference(userAssignedIdentityResourceId, '2024-11-30').principalId
              : ((identityType == 'SystemAssigned')
                  ? reference(
                      'Microsoft.DesktopVirtualization/hostpools/${hostpoolName_var}',
                      '2024-11-01-preview',
                      'Full'
                    ).identity.principalId
                  : ''))
            principalType: 'ServicePrincipal'
          }
          condition: ((!empty(identityType)) && (identityType != 'None') && (!empty(vmAdministratorAccountPasswordVaultResourceId)))
        }
      ]
    }
  }
  dependsOn: [
    hostpool
  ]
}

resource Microsoft_DesktopVirtualization_hostpools_sessionHostConfigurations_hostpoolName_default 'Microsoft.DesktopVirtualization/hostpools/sessionHostConfigurations@[if(parameters(\'enableEOSDPublicAPIVersion\'), \'2025-04-01-preview\', \'2024-07-15-privatepreview\')]' = if (eosdEnabled) {
  name: '${hostpoolName}/default'
  properties: {
    vmResourceGroup: vmResourceGroup
    vmSizeId: vmSize
    diskInfo: {
      diffDiskSettings: {
        option: 'Local'
        placement: eosdType
      }
    }
    customConfigurationScriptUrl: (empty(customConfigurationScriptUrl) ? null : customConfigurationScriptUrl)
    imageInfo: {
      type: ((vmImageType == 'Gallery') ? 'Marketplace' : 'Custom')
      marketPlaceInfo: ((vmImageType == 'Gallery') ? sessionHostConfigurationImageMarketplaceInfoProps : null)
      customInfo: ((vmImageType == 'CustomImage') ? sessionHostConfigurationImageCustomInfoProps : null)
    }
    domainInfo: {
      joinType: (aadJoin ? 'AzureActiveDirectory' : 'ActiveDirectory')
      activeDirectoryInfo: ((!aadJoin)
        ? KeyVaultSecretRetrieval_deploymentId.properties.outputs.sessionHostConfigurationDomainActiveDirectoryInfoProps.value
        : null)
      azureActiveDirectoryInfo: (aadJoin ? sessionHostConfigurationDomainAzureActiveDirectoryInfoProps : null)
    }
    vmTags: (empty(virtualMachineTags) ? null : virtualMachineTags)
    vmLocation: vmLocation
    vmNamePrefix: vmNamePrefix
    availabilityZones: (empty(availabilityZones) ? null : availabilityZones)
    networkInfo: {
      subnetId: subnet_id
      securityGroupId: nsg_id
    }
    securityInfo: {
      type: securityType
      secureBootEnabled: secureBoot
      vTpmEnabled: vTPM
    }
    vmAdminCredentials: {
      usernameKeyVaultSecretUri: vmAdministratorAccountUsernameSecretUri
      passwordKeyVaultSecretUri: vmAdministratorAccountPasswordSecretUri
    }
    bootDiagnosticsInfo: bootDiagnostics
  }
  dependsOn: [
    hostpool
    (autoAssignRoles ? 'AssignRole-HostPool-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-SessionHost-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-CustomImage-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-VNet-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-Nsg-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-AdminUserKV-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-AdminPassKV-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-VMAdminUserKV-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-VMAdminPassKV-${deploymentId}' : hostpool.id)
  ]
}

resource Microsoft_DesktopVirtualization_hostpools_sessionHostConfigurations_hostpoolName_default 'Microsoft.DesktopVirtualization/hostpools/sessionHostConfigurations@[parameters(\'apiVersion\')]' = if (!eosdEnabled) {
  name: '${hostpoolName}/default'
  properties: {
    vmResourceGroup: vmResourceGroup
    vmSizeId: vmSize
    diskInfo: {
      type: vmDiskType
    }
    customConfigurationScriptUrl: (empty(customConfigurationScriptUrl) ? null : customConfigurationScriptUrl)
    imageInfo: {
      type: ((vmImageType == 'Gallery') ? 'Marketplace' : 'Custom')
      marketPlaceInfo: ((vmImageType == 'Gallery') ? sessionHostConfigurationImageMarketplaceInfoProps : null)
      customInfo: ((vmImageType == 'CustomImage') ? sessionHostConfigurationImageCustomInfoProps : null)
    }
    domainInfo: {
      joinType: (aadJoin ? 'AzureActiveDirectory' : 'ActiveDirectory')
      activeDirectoryInfo: ((!aadJoin)
        ? KeyVaultSecretRetrieval_deploymentId.properties.outputs.sessionHostConfigurationDomainActiveDirectoryInfoProps.value
        : null)
      azureActiveDirectoryInfo: (aadJoin ? sessionHostConfigurationDomainAzureActiveDirectoryInfoProps : null)
    }
    vmTags: (empty(virtualMachineTags) ? null : virtualMachineTags)
    vmLocation: vmLocation
    vmNamePrefix: vmNamePrefix
    availabilityZones: (empty(availabilityZones) ? null : availabilityZones)
    networkInfo: {
      subnetId: subnet_id
      securityGroupId: nsg_id
    }
    securityInfo: {
      type: securityType
      secureBootEnabled: secureBoot
      vTpmEnabled: vTPM
    }
    vmAdminCredentials: {
      usernameKeyVaultSecretUri: vmAdministratorAccountUsernameSecretUri
      passwordKeyVaultSecretUri: vmAdministratorAccountPasswordSecretUri
    }
    bootDiagnosticsInfo: bootDiagnostics
  }
  dependsOn: [
    hostpool
    (autoAssignRoles ? 'AssignRole-HostPool-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-SessionHost-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-CustomImage-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-VNet-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-Nsg-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-AdminUserKV-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-AdminPassKV-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-VMAdminUserKV-${deploymentId}' : hostpool.id)
    (autoAssignRoles ? 'AssignRole-VMAdminPassKV-${deploymentId}' : hostpool.id)
  ]
}

resource hostpoolName_defaultNoProvisioning 'Microsoft.DesktopVirtualization/hostpools/sessionHostManagements@[parameters(\'apiVersion\')]' = if (!enableSessionHostProvisioning) {
  name: '${hostpoolName}/default'
  properties: {
    scheduledDateTime: defaultTimestamp
    provisioning: null
    scheduledDateTimeZone: defaultTimeZone
    update: {
      deleteOriginalVm: false
      maxVmsRemoved: 1
      logOffDelayMinutes: 2
      logOffMessage: 'You will be signed out'
    }
  }
  dependsOn: [
    hostpool
  ]
}

resource hostpoolName_defaultWithProvisioning 'Microsoft.DesktopVirtualization/hostpools/sessionHostManagements@[parameters(\'apiVersion\')]' = if (enableSessionHostProvisioning) {
  name: '${hostpoolName}/default'
  properties: {
    failedSessionHostCleanupPolicy: 'KeepAll'
    provisioning: {
      instanceCount: vmNumberOfInstances
      canaryPolicy: 'Auto'
      setDrainMode: false
    }
    scheduledDateTime: defaultTimestamp
    scheduledDateTimeZone: defaultTimeZone
    update: {
      deleteOriginalVm: true
      maxVmsRemoved: 1
      logOffDelayMinutes: 2
      logOffMessage: 'You will be signed out'
    }
  }
  dependsOn: [
    hostpool
    Microsoft_DesktopVirtualization_hostpools_sessionHostConfigurations_hostpoolName_default
  ]
}

resource appGroup 'Microsoft.DesktopVirtualization/applicationgroups@[parameters(\'apiVersion\')]' = {
  name: appGroupName
  location: location
  properties: {
    hostpoolarmpath: hostpool.id
    friendlyName: 'Default Desktop'
    description: 'Desktop Application Group created through the Hostpool Wizard'
    applicationGroupType: 'Desktop'
  }
}

module Workspace_linkedTemplate_deploymentId './nested_Workspace_linkedTemplate_deploymentId.bicep' = if (addToWorkspace) {
  name: 'Workspace-linkedTemplate-${deploymentId}'
  params: {
    variables_applicationGroupReferencesArr: applicationGroupReferencesArr
    variables_workspacePublicNetworkAccess: workspacePublicNetworkAccess
    apiVersion: apiVersion
    workSpaceName: workSpaceName
    workspaceLocation: workspaceLocation
    isNewWorkspace: isNewWorkspace
  }
}

module vmCreation_linkedTemplate_deploymentId '?' /*TODO: replace with correct path to [variables('vmTemplateUri')]*/ = if (createVMs && (!enableSessionHostProvisioning)) {
  name: 'vmCreation-linkedTemplate-${deploymentId}'
  params: {
    artifactsLocation: artifactsLocation
    availabilityZones: availabilityZones
    vmGalleryImageOffer: vmGalleryImageOffer
    vmGalleryImagePublisher: vmGalleryImagePublisher
    vmGalleryImageHasPlan: vmGalleryImageHasPlan
    vmGalleryImageSKU: vmGalleryImageSKU
    vmGalleryImageVersion: vmGalleryImageVersion
    rdshPrefix: rdshPrefix
    rdshNumberOfInstances: vmNumberOfInstances
    rdshVMDiskType: (eosdEnabled ? replace(eosdType, 'TempDisk', 'ResourceDisk') : vmDiskType)
    rdshVmSize: vmSize
    rdshVmDiskSizeGB: vmDiskSizeGB
    rdshHibernate: vmHibernate
    enableAcceleratedNetworking: false
    vmAdministratorAccountUsername: 'placeholder-'
    vmAdministratorAccountPassword: 'placeholder-'
    administratorAccountUsername: 'placeholder-'
    administratorAccountPassword: 'placeholder-'
    'subnet-id': subnet_id
    loadBalancerBackendPoolId: loadBalancerBackendPoolId
    rdshImageSourceId: vmCustomImageSourceId
    location: vmLocation
    extendedLocation: vmExtendedLocation
    createNetworkSecurityGroup: createNetworkSecurityGroup
    networkSecurityGroupId: networkSecurityGroupId
    newNetworkSecurityGroupName: newNetworkSecurityGroupName
    networkSecurityGroupRules: networkSecurityGroupRules
    virtualMachineTags: virtualMachineTags
    hostpoolToken: hostpoolToken
    hostpoolName: hostpoolName
    domain: (aadJoin ? domain : KeyVaultSecretRetrieval_deploymentId.properties.outputs.domain.value)
    ouPath: ouPath
    aadJoin: aadJoin
    intune: intune
    bootDiagnostics: bootDiagnostics
    _guidValue: deploymentId
    userAssignedIdentity: userAssignedIdentity
    customConfigurationScriptUrl: customConfigurationScriptUrl
    SessionHostConfigurationVersion: Microsoft_DesktopVirtualization_hostpools_sessionHostConfigurations_hostpoolName_default.properties.version
    systemData: systemData
    securityType: securityType
    secureBoot: secureBoot
    vTPM: vTPM
  }
  dependsOn: [
    appGroup
  ]
}

resource hostpoolName_Microsoft_Insights_diagnosticSetting 'Microsoft.DesktopVirtualization/hostpools/providers/diagnosticSettings@2017-05-01-preview' = if (sendLogsToEventHub || sendLogsToLogAnalytics || sendLogsToStorageAccount) {
  name: '${hostpoolName}/Microsoft.Insights/diagnosticSetting'
  location: location
  properties: {
    storageAccountId: (sendLogsToStorageAccount ? storageAccountIdProperty : null)
    eventHubAuthorizationRuleId: (sendLogsToEventHub ? hostpoolDiagnosticSettingsEventHubAuthorizationId : null)
    eventHubName: (sendLogsToEventHub ? hostpoolDiagnosticSettingsEventHubName : null)
    workspaceId: (sendLogsToLogAnalytics ? hostpoolDiagnosticSettingsLogAnalyticsWorkspaceId : null)
    logs: hostpoolDiagnosticSettingsLogProperties
  }
  dependsOn: [
    hostpool
  ]
}

resource appGroupName_Microsoft_Insights_diagnosticSetting 'Microsoft.DesktopVirtualization/applicationgroups/providers/diagnosticSettings@2017-05-01-preview' = if (sendLogsToEventHub || sendLogsToLogAnalytics || sendLogsToStorageAccount) {
  name: '${appGroupName}/Microsoft.Insights/diagnosticSetting'
  location: location
  properties: {
    storageAccountId: (sendLogsToStorageAccount ? storageAccountIdProperty : null)
    eventHubAuthorizationRuleId: (sendLogsToEventHub ? hostpoolDiagnosticSettingsEventHubAuthorizationId : null)
    eventHubName: (sendLogsToEventHub ? hostpoolDiagnosticSettingsEventHubName : null)
    workspaceId: (sendLogsToLogAnalytics ? hostpoolDiagnosticSettingsLogAnalyticsWorkspaceId : null)
    logs: appGroupDiagnosticSettingsLogProperties
  }
  dependsOn: [
    appGroup
  ]
}

resource isNewWorkspace_workSpaceName_placeholder_Microsoft_Insights_diagnosticSetting 'Microsoft.DesktopVirtualization/workspaces/providers/diagnosticSettings@2017-05-01-preview' = if (isNewWorkspace && (sendLogsToEventHub || sendLogsToLogAnalytics || sendLogsToStorageAccount)) {
  name: '${(isNewWorkspace?workSpaceName:'placeholder')}/Microsoft.Insights/diagnosticSetting'
  location: location
  properties: {
    storageAccountId: (sendLogsToStorageAccount ? storageAccountIdProperty : null)
    eventHubAuthorizationRuleId: (sendLogsToEventHub ? hostpoolDiagnosticSettingsEventHubAuthorizationId : null)
    eventHubName: (sendLogsToEventHub ? hostpoolDiagnosticSettingsEventHubName : null)
    workspaceId: (sendLogsToLogAnalytics ? hostpoolDiagnosticSettingsLogAnalyticsWorkspaceId : null)
    logs: workspaceDiagnosticSettingsLogProperties
  }
  dependsOn: [
    Workspace_linkedTemplate_deploymentId
  ]
}

output rdshVmNamesObject object = rdshVmNamesOutput

