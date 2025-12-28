targetScope = 'subscription'

// Basics

@allowed([
  'Complete'
  'HostpoolOnly'
  'SessionHostsOnly'
])
@description('''Optional. The type of deployment to perform.
- "Complete" deployment will deploy the host pool, selected other resources, and session hosts.
- "HostpoolOnly" deployment will only deploy the host pool portion of the control plane and the session hosts, while referencing existing resources for management and monitoring.
- "SessionHostsOnly" deployment will only deploy the session hosts.
''')
param deploymentType string = 'Complete'

@maxLength(9)
@description('''Required. Identifier used to describe the persona of the hostpool(s).
A persona refers to a detailed profile that represents a specific user type, considering their unique needs,
usage patterns, and requirements. Essentially, it's a fictional character that helps IT professionals
understand and address the varying demands of different users within an organization.
Each persona might include details like:
- Role: What job they perform within the organization.  
- Applications: What applications they use regularly.
- Workload: The intensity of resource usage, such as compute, storage, and network.
- Access Needs: How they access the virtual desktop—remotely or on-premises.
- Security Requirements: Specific security measures necessary for their role.
This identifier combined with the index parameter (when provided) is used to create the host pool, desktop application group,
and other host pool specific resource names.
''')
param identifier string = ''

@maxLength(2)
@description('''Optional. An index value used to distinquish each host pool with the same persona identifier.
This can be provided to shard the host pool across multiple groups for performance reasons or to uniquely define host pools under the same identifier.
''')
param index string = ''

@description('Optional. Reverse the normal Cloud Adoption Framework naming convention by putting the resource type abbreviation at the end of the resource name.')
param nameConvResTypeAtEnd bool = false

// Identity

@allowed([
  'ActiveDirectoryDomainServices' // User accounts are sourced from and Session Hosts are joined to same Active Directory domain.
  'EntraDomainServices' // User accounts are sourced from either Azure Active Directory or Active Directory Domain Services and Session Hosts are joined to Azure Active Directory Domain Services.
  'EntraKerberos-Hybrid' // User accounts are sourced from Active Directory and Session Hosts are joined to Entra Id.
  'EntraKerberos-CloudOnly' // Preview feature with Kerberos support. User accounts and Session Hosts are located in Azure Active Directory Only (Cloud Only Scenario)
  'EntraId' // User accounts and Session Hosts are located in Azure Active Directory Only (Cloud Only Scenario) 
])
@description('Required. The service providing domain services for Azure Virtual Desktop.  This is needed to properly configure the session hosts and if applicable, the Azure Storage Account.')
param identitySolution string

@description('Optional. Determines if Entra Joined Virtual Machines automatically enroll in intune.')
param intuneEnrollment bool = false

@secure()
@description('Conditional. Local administrator password for the AVD session hosts')
param virtualMachineAdminPassword string = ''

@secure()
@description('Conditional. The Local Administrator Username for the Session Hosts')
param virtualMachineAdminUserName string = ''

@secure()
@description('Optional. The password of the privileged account to domain join the AVD session hosts to your domain. Required when "identitySolution" contains "DomainServices".')
param domainJoinUserPassword string = ''

@secure()
@description('''Conditional. The UPN of the privileged account to domain join the AVD session hosts to your domain.
This should be an account the resides within the domain you are joining. Required when "identitySolution" contains "DomainServices".
''')
param domainJoinUserPrincipalName string = ''

@description('Optional. The Resource Id of the Key Vault containing the credential secrets.')
param credentialsKeyVaultResourceId string = ''

@description('Optional. The name of the domain that provides ADDS to the AVD session hosts and is synchronized with Azure AD')
param domainName string = ''

@description('Optional. The distinguished name for the target Organization Unit in Active Directory Domain Services.')
param vmOUPath string = ''

// Control Plane

@description('Conditional. The deployment location for the AVD Control Plane resources. Required when DeploymentType is "Complete" or "HostpoolOnly".')
param controlPlaneLocation string = ''

@description('Optional. The subscription Id where the AVD Control Plane resources are deployed. If not provided, the deployment subscription will be used.')
param controlPlaneSubscriptionId string = ''

@description('Optional. The resource Id of an existing AVD host pool to which the session hosts will be registered. Only used when "DeploymentType" is "SessionHostOnly".')
param existingHostPoolResourceId string = ''

@description('Optional. The resource Id of an existing AVD workspace to which the desktop application group will be registered.')
param existingFeedWorkspaceResourceId string = ''

@description('Optional. The friendly name for the AVD workspace that is displayed in the client.')
param workspaceFriendlyName string = ''

@description('Optional. The friendly name for the Desktop in the AVD workspace.')
param desktopFriendlyName string = ''

@allowed([
  'Pooled DepthFirst'
  'Pooled BreadthFirst'
  'Personal Automatic'
  'Personal Direct'
])
@description('Optional. These options specify the host pool type and depending on the type provides the load balancing options and assignment types.')
param hostPoolType string = 'Pooled DepthFirst'

@description('Optional. The maximum number of sessions per AVD session host.')
param hostPoolMaxSessionLimit int = 4

@description('''Optional. Input RDP properties to add or remove RDP functionality on the AVD host pool.
Settings reference: https://learn.microsoft.com/windows-server/remote/remote-desktop-services/clients/rdp-files
''')
param hostPoolRDPProperties string = ''

@description('Optional. The value determines whether the hostPool should receive early AVD updates for testing.')
param hostPoolValidationEnvironment bool = false

@description('Optional. Determines if the Start VM on Connect Feature is enabled for the Host Pool.')
param startVmOnConnect bool = true

@description('''Optional.
An array of objects, defining the security groups that are assigned permissions to the desktop application group created by this solution.
Each object must contain the following properties from the Entra Id group:
  id: Id
  name: DisplayName
If the 'fslogixShardGroups' is not defined, the value of this parameter is used to determine the number of storage accounts and permissions for each.
''')
param appGroupSecurityGroups array = []

@description('Optional. Determines if the scaling plan is deployed to the host pool.')
param deployScalingPlan bool = false

@description('''Optional.
The Object ID for the Windows Virtual Desktop Enterprise Application in Azure AD.
The Object ID can found by selecting Microsoft Applications using the Application type filter in the Enterprise Applications blade of Entra Id.
When Start VM On Connect is selected or you deploy a scaling plan, this object ID is assigned the proper role on the subscription.
''')
param avdObjectId string = ''

@description('Optional. The tag used to exclude virtual machines from the scaling plan.')
param scalingPlanExclusionTag string = ''

@description('Optional. The scaling plan weekday ramp up schedule')
param scalingPlanRampUpSchedule object = {
  startTime: '8:00'
  minimumHostsPct: 20
  capacityThresholdPct: 60
  loadBalancingAlgorithm: 'DepthFirst'
}

@description('Optional. The scaling plan weekday peak schedule.')
param scalingPlanPeakSchedule object = {
  startTime: '9:00'
  loadBalancingAlgorithm: 'DepthFirst'
}

@description('Optional. The scaling plan weekday rampdown schedule.')
param scalingPlanRampDownSchedule object = {
  startTime: '17:00'
  minimumHostsPct: 10
  capacityThresholdPct: 90
  loadBalancingAlgorithm: 'DepthFirst'
}

@description('Optional. The scaling plan weakday off peak schedule.')
param scalingPlanOffPeakSchedule object = {
  startTime: '20:00'
  loadBalancingAlgorithm: 'DepthFirst'
}

@description('Optional. Determines if the scaling plan will forcefully log off users when scaling down.')
param scalingPlanForceLogoff bool = false

@description('Optional. The number of minutes to wait before forcefully logging off users when scaling down.')
param scalingPlanMinsBeforeLogoff int = 0

// Session Hosts

@description('Optional. The TimeZone of the AVD session hosts.')
param virtualMachinesTimeZone string = 'Eastern Standard Time'

@description('Conditional. The name of the existing hosts resource group. Only used used when "DeploymentType" is "SessionHostOnly".')
param existingHostsResourceGroupName string = ''

@minLength(1)
@maxLength(14)
@description('Required. The Virtual Machine Name prefix.')
param virtualMachineNamePrefix string

@maxValue(5000)
@minValue(0)
@description('Optional. The number of session hosts to deploy in the host pool. Ensure you have the approved quota to deploy the desired count.')
param sessionHostCount int = 1

@maxValue(4999)
@minValue(0)
@description('Optional. The starting number for the session hosts. This is important when adding virtual machines to ensure an update deployment is not performed on an exiting, active session host.')
param sessionHostIndex int = 1

@minValue(1)
@maxValue(4)
param vmNameIndexLength int = 3

@description('Required. The resource ID of the subnet to place the network interfaces for the AVD session hosts.')
param virtualMachineSubnetResourceId string

@allowed([
  'Standard'
  'ConfidentialVM'
  'TrustedLaunch'
])
@description('Optional. The Security Type of the AVD Session Hosts.  ConfidentialVM and TrustedLaunch are only available in certain regions.')
param securityType string = 'TrustedLaunch'

@description('Optional. Enable Secure Boot on the Trusted Luanch or Confidential VMs.')
param secureBootEnabled bool = true

@description('Optional. Enable the Virtual TPM on Trusted Launch or Confidential VMs.')
param vTpmEnabled bool = true

@description('Optional. Integrity monitoring enables cryptographic attestation and verification of VM boot integrity along with monitoring alerts if the VM did not boot because attestation failed with the defined baseline.')
param integrityMonitoring bool = true

@description('''Optional. Encryption at host encrypts temporary disks and ephemeral OS disks with platform-managed keys,
OS and data disk caches with the key specified in the "keyManagementDisks" parameter, and flows encrypted to the Storage service.
''')
param encryptionAtHost bool = true

@allowed([
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
  'PlatformManagedAndCustomerManaged'
  'PlatformManagedAndCustomerManagedHSM'
])
@description('''Optional. The type of encryption key management used for the storage. (Default: "PlatformManaged")
- Platform-managed keys (PMKs) are key encryption keys that are generated, stored, and managed entirely by Azure. Choose Platform Managed for the best balance of security and ease of use.
- Customer-managed keys (CMKs) are key encryption keys that are generated, stored, and managed by you, the customer, in your Azure Key Vault. Choose Customer Managed if you need to meet specific compliance requirements.
- Customer-managed keys (CMKs) storage in a premium KeyVault backed by a Hardware Security Module (HSM). The Hardware Security Module is FIPS 140 Level 3 validated.
- Double encryption is 2 layers of encryption: an infrastructure encryption layer with platform managed keys and a disk encryption layer with customer managed keys defined by disk encryption sets.
Choose Platform Managed and Customer Managed if you need double encryption. This option does not apply to confidential VMs.
- Choose Platform Managed and Customer Managed with HSM if you must incorporate double encryption and protect the customer managed key with the Hardware Security Module. This option does not apply to confidential VMs.
''')
param keyManagementDisks string = 'PlatformManaged'

@description('Optional. The resource Id of an existing Disk Encryption Set that session hosts will utilize for customer managed keys. Only used when "DeploymentType" is "SessionHostOnly".')
param existingDiskEncryptionSetResourceId string = ''

@description('Optional. The rotation period for the customer-managed keys in the Azure Key Vault.')
param keyExpirationInDays int = 180

@description('Optional. Confidential disk encryption is an additional layer of encryption which binds the disk encryption keys to the virtual machine TPM and makes the disk content accessible only to the VM.')
param confidentialVMOSDiskEncryption bool = false

@description('''Optional. The object ID of the Confidential VM Orchestrator enterprise application with application ID "bf7b6499-ff71-4aa2-97a4-f372087be7f0".
This is required when "confidentialVMOSDiskEncryption" is set to "true". You must create this application in your tenant before deploying this solution using the following PowerShell script:
  Connect-AzureAD -Tenant "your tenant ID"
  New-AzureADServicePrincipal -AppId bf7b6499-ff71-4aa2-97a4-f372087be7f0 -DisplayName "Confidential VM Orchestrator"
''')
param confidentialVMOrchestratorObjectId string = ''

@description('Optional. The resource Id of the Dedicated Host on which to deploy the Virtual Machines.')
param dedicatedHostResourceId string = ''

@description('Optional. The resource Id of the Dedicated Host Group on to which the Virtual Machines are to be deployed. The Dedicated Host Group must support Automatic Host Assignment for this value to be used.')
param dedicatedHostGroupResourceId string = ''

@allowed([
  0
  32
  64
  128
  256
  512
  1024
  2048
])
@description('Optional. The size of the OS disk in GB for the AVD session hosts. When set to 0 it defaults to the image size - typically 128 GB.')
param diskSizeGB int = 0

@allowed([
  'Standard_LRS'
  'StandardSSD_LRS'
  'Premium_LRS'
])
@description('Optional. The storage SKU for the AVD session host disks.  Production deployments should use Premium_LRS.')
param diskSku string = 'Premium_LRS'

@description('Optional. The VM SKU for the AVD session hosts.')
param virtualMachineSize string = 'Standard_D4ads_v5'

@description('Optional. The Number of cores for the AVD session hosts.')
param vCPUs int = 0

@description('Optional. The amount of memory in GB for the AVD session hosts.')
param memoryGB int = 0

@description('Optional. Determines whether or not to enable accelerated networking for the session host VMs.')
param enableAcceleratedNetworking bool = true

@description('Optional. Determines whether or not to enable hibernation for the session host VMs.')
param hibernationEnabled bool = false

@allowed([
  'AvailabilitySets'
  'AvailabilityZones'
  'None'
])
@description('Optional. Set the desired availability / SLA with a pooled host pool.  The best practice is to deploy to availability Zones for resilency. Not used when either "dedicatedHostResourceId" or "dedicatedHostGroupResourceId" is specified.')
param availability string = 'AvailabilityZones'

@description('Conditional. The availability zones allowed for the AVD session hosts deployment location. Used when "availability" is set to "availabilityZones".')
param availabilityZones array = []

@description('Optional. Offer for the virtual machine image')
param imageOffer string = 'office-365'

@description('Optional. Publisher for the virtual machine image')
param imagePublisher string = 'MicrosoftWindowsDesktop'

@description('Optional. SKU for the virtual machine image')
param imageSku string = 'win11-24h2-avd-m365'

@description('Required. The resource ID for the Compute Gallery Image Version. Do not set this value if using a marketplace image.')
param customImageResourceId string = ''

@description('Optional. The DSC package name or full Url used by the PowerShell DSC extension to install the AVD Agent and register the virtual machine as a Session Host.')
param avdAgentsDSCPackage string = 'Configuration_1.0.03211.1002.zip'

@description('Optional. Instruct the AVD Agent Installation script to automatically download the latest agent version during installation.zip.')
param useAgentDownloadEndpoint bool = false

@description('''Optional.
The Uri of the container hosting the scripts or installers that are used to customize the session host Virtual Machines.
Do not include the trailing slash.
''')
param artifactsContainerUri string = ''

@description('''Optional.
The Resource Id of the managed identity with Storage Blob Data Reader Access to the artifacts container if using Azure Blob Storage.
Required when accessing artifacts from the storage account when they do not enable anonymous access. 
''')
param artifactsUserAssignedIdentityResourceId string = ''

@description('''Optional.
Array of objects containing the following properties
-name: The name of the script or application that is running minus extension
-blobNameOrUri: The blob name when used with the artifactsContainerUri or the full URI of the file to download.
-arguments: Arguments required by the installer or script being ran.

JSON example:
[
  {
    "name": "FSLogix",
    "blobNameOrUri": "https://aka.ms/fslogix_download"
  },
  {
    "name": "VSCode",
    "blobNameOrUri": "VSCode.zip",
    "arguments": "/verysilent /mergetasks=!runcode"
  }
]
''')
param sessionHostCustomizations array = []

// User Profiles

@description('Optional. Determines whether resources to support FSLogix profile storage are deployed.')
param deployFSLogixStorage bool = false

@description('Optional. The custom prefix to use for the name of the Azure files storage accounts to use for FSLogix. If not specified, the name is generated automatically.')
param fslogixStorageCustomPrefix string = ''

@description('Optional. The file share size(s) in GB for the fslogix storage solution.')
param fslogixShareSizeInGB int = 100

@description('Optional. The type of FSLogix containers to use for FSLogix.')
@allowed([
  'CloudCacheProfileContainer' // FSLogix Cloud Cache Profile Container
  'CloudCacheProfileOfficeContainer' // FSLogix Cloud Cache Profile & Office Container
  'ProfileContainer' // FSLogix Profile Container
  'ProfileOfficeContainer' // FSLogix Profile & Office Container
])
param fslogixContainerType string = 'ProfileContainer'

@description('Optional. The size of the FSLogix containers in MB. This value is used to set the SizeInMBs registry key on the session hosts.')
param fslogixSizeInMBs int = 30000

@description('''Optional.
Determines whether or not to Shard Azure Files Storage by deploying more than one storage account, and if so how the Session Hosts are Configured.
- If 'None' is selected, then no sharding is performed and only 1 storage account is deployed when deploying storage accounts.
- If 'ShardOSS' is selected, then the fslogixShardGroups are used to assign share permissions and configure the session hosts with Object Specific Settings.
- If 'ShardPerms' is selected, then storage account permissions are assigned based on the groups defined in "appGroupSecurityGroups" or "fslogixShardPrincpals".
''')
@allowed([
  'None'
  'ShardOSS'
  'ShardPerms'
])
param fslogixShardOptions string = 'None'

@description('''Optional.
An array of objects, defining the administrator groups who will be granted full control access to the FSLogix share.
Each object must contain the following properties from the Entra Id group:
  id: Id
  name: DisplayName
''')
param fslogixAdminGroups array = []

@description('''Optional.
An array of objects, defining the user groups that are assigned permissions to each share.
Each object must contain the following properties from the Entra Id group:
  id: Id
  name: DisplayName
''')
param fslogixUserGroups array = []

@description('''Optional.
The resource Id of the User Assigned Identity that has been granted the Application Admnistrator Entra ID role in order to add tags
to the enterprise application created when the storage account is enabled for Entra Kerberos Authentication. Required in order to
automate the configuration of least priveledge permissions on the file share(s) in the Entra Kerberos (Cloud Only Identity) configuration.
''')
param fslogixAppUpdateUserAssignedIdentityResourceId string = ''

@allowed([
  'AzureNetAppFiles Premium' // ANF with the Premium SKU, 450,000 IOPS
  'AzureNetAppFiles Standard' // ANF with the Standard SKU, 320,000 IOPS
  'AzureFiles Premium' // Azure files Premium with a Service Endpoint, 100,000 IOPs
  'AzureFiles Standard' // Azure files Standard with the Large File Share option and the default public endpoint, 20,000 IOPS
])
@description('Optional. The storage service to use for storing FSLogix containers. The service & SKU should provide sufficient IOPS for all of your users. https://docs.microsoft.com/en-us/azure/architecture/example-scenario/wvd/windows-virtual-desktop-fslogix#performance-requirements')
param fslogixStorageService string = 'AzureFiles Standard'

@description('Optional. The OU Path where the FSLogix Storage Accounts or NetApp Accounts will be joined in the ADDS.')
param fslogixOUPath string = ''

@description('Optional. The resource Id of the subnet delegated to Microsoft.Netapp/volumes to which the NetApp volume will be attached when the "fslogixStorageService" is "AzureNetAppFiles Premium" or "AzureNetAppFiles Standard".')
param netAppVolumesSubnetResourceId string = ''

@description('Optional. Indicates whether or not there is an existing Active Directory Connection with Azure NetApp Volume.')
param existingSharedActiveDirectoryConnection bool = false

@description('Optional. Configure FSLogix agent on the session hosts via local registry keys.')
param fslogixConfigureSessionHosts bool = false

@description('''Optional. Existing local (in the same region as the session host VMs) NetApp Files Volume Resource Ids.
If Office Containers are used, then list the FSLogix Profile Container Volume first and the Office Container Volume second.
''')
param fslogixExistingLocalNetAppVolumeResourceIds array = []

@description('''Optional. Existing local (in the same region as the session host VMs) FSLogix Storage Account Resource Ids.
Only used when fslogixConfigureSessionHosts = true and deployFSLogixStorage = false.
If "identitySolution" is set to "EntraId" then only the first storage account listed will be used.
''')
param fslogixExistingLocalStorageAccountResourceIds array = []

@description('''Optional. Existing remote (not in the same region as the session host VMs) NetApp Files Volume Resource Ids.
If Office Containers are used, then list the FSLogix Profile Container Volume first and the Office Container Volume second.
''')
param fslogixExistingRemoteNetAppVolumeResourceIds array = []

@description('''Optional. Existing remote (not in the same region as the session host VMs) FSLogix Storage Account Resource Ids.
Only used when fslogixConfigureSessionHosts = true.
This list will be added to any storage accounts created when setting "fslogixStorageService" to any of the AzureFiles options. 
If "identitySolution" is set to "EntraId" then only the first storage account listed will be used.
''')
param fslogixExistingRemoteStorageAccountResourceIds array = []

@allowed([
  'AES256'
  'RC4'
])
@description('Optional. The Kerberos encryption type for the Azure Storage Account or Azure NetApp files Account.')
param fslogixStorageKerberosEncryptionType string = 'AES256'

@maxValue(99)
@minValue(0)
@description('Optional. The starting number for the storage accounts to support the required use case for the AVD stamp. https://docs.microsoft.com/en-us/azure/architecture/patterns/sharding')
param fslogixStorageIndex int = 1

@allowed([
  'MicrosoftManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
@description('Optional. The type of key management used for the Azure Files storage account encryption.')
param keyManagementStorageAccounts string = 'MicrosoftManaged'

// Management

@description('Optional. Enable backups to an Azure Recovery Services vault.  For a pooled host pool this will enable backups on the Azure file share.  For a personal host pool this will enable backups on the AVD sessions hosts.')
param recoveryServices bool = false

@description('Optional. The resource Id of an existing Recovery Services Vault that will be used to store Virtual Machine Backups. Only used when "DeploymentType" is "SessionHostOnly".')
param existingRecoveryServicesVaultResourceId string = ''

@description('Optional. The resource Id of an existing Key Vault that contains the customer managed keys for disk encryption and/or FSLogix storage account encryption. Only used when "DeploymentType" is "HostpoolOnly".')
param existingEncryptionKeyVaultResourceId string = ''

@description('Optional. Deploys the secrets Key Vault.')
param deploySecretsKeyVault bool = false

@description('Optional. Enables soft delete on the secrets key vault.')
param secretsKeyVaultEnableSoftDelete bool = true

@description('Optional. Enables soft delete on the secrets key vault.')
param secretsKeyVaultEnablePurgeProtection bool = true

@description('Optional. The retention period for the Azure Key Vault.')
@minValue(7)
@maxValue(90)
param keyVaultRetentionInDays int = 90

// Monitoring

@description('Optional. Deploys the required monitoring resources to enable AVD and VM Insights and monitor features in the automation account.')
param enableMonitoring bool = true

@description('Optional. The subscription Id where monitoring resources will be deployed. If not provided, the deployment subscription will be used.')
param monitoringSubscriptionId string = ''

@description('Optional. The resource Id of the existing Log Analytics Workspace for AVD Control Plane monitoring solution. Only used when "DeploymentType" is "HostpoolOnly".')
param existingLogAnalyticsWorkspaceResourceId string = ''

@description('Optional. The resource Id of the existing AVD Insights Data Collection Rule. Only used when "DeploymentType" is "SessionHostOnly".')
param existingAVDInsightsDataCollectionRuleResourceId string = ''

@description('Optional. The resource Id of the existing VM Insights Data Collection Rule. Only used when "DeploymentType" is "SessionHostOnly".')
param existingVMInsightsDataCollectionRuleResourceId string = ''

@description('Optional. The resource Id of the existing Data Collection Endpoint. Only used when "DeploymentType" is "SessionHostOnly".')
param existingDataCollectionEndpointResourceId string = ''

@description('Optional. The resource ID of the data collection rule used for Azure Sentinel and / or Defender for Cloud when using the Azure Monitor Agent.')
param securityDataCollectionRulesResourceId string = ''

// Zero Trust

@description('Optional. The resource id of the existing disk access resource for private link access to the managed disks. Only used when "DeploymentType" is "SessionHostOnly".')
param existingDiskAccessResourceId string = ''

@description('Optional. Create private endpoints for all deployed management and storage resources where applicable.')
param deployPrivateEndpoints bool = false

@description('Conditional. The Resource Id of the subnet on which to create the secrets Key Vault private endpoint. Required when "deployPrivateEndpoints" = true and "deploySecretsKeyVault" = true.')
param keyVaultPrivateEndpointSubnetResourceId string = ''

@description('Conditional. The Resource Id of the subnet on which to create the storage account and other resources private link. Required when "deployPrivateEndpoints" = true.')
param hostPoolResourcesPrivateEndpointSubnetResourceId string = ''

@description('Conditional. If using private endpoints with Azure files, input the Resource ID for the Private DNS Zone linked to your hub virtual network. Required when "deployPrivateEndpoints" is true.')
param azureBackupPrivateDnsZoneResourceId string = ''

@description('Conditional. If using private endpoints with Azure files, input the Resource ID for the Private DNS Zone linked to your hub virtual network. Required when "deployPrivateEndpoints" is true.')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Conditional. If using private endpoints with Azure files, input the Resource ID for the Private DNS Zone linked to your hub virtual network. Required when "deployPrivateEndpoints" is true.')
param azureFilesPrivateDnsZoneResourceId string = ''

@description('Conditional. If using private endpoints with Key Vaults, input the Resource ID for the Private DNS Zone linked to your hub virtual network. Required when "deployPrivateEndpoints" is true.')
param azureKeyVaultPrivateDnsZoneResourceId string = ''

@description('Conditional. If using private endpoints with Azure files, input the Resource ID for the Private DNS Zone linked to your hub virtual network. Required when "deployPrivateEndpoints" is true.')
param azureQueuePrivateDnsZoneResourceId string = ''

@description('Optional. Deploy the Zero Trust Compliant Disk Access Policy to deny Public Access to the Virtual Machine Managed Disks.')
param deployDiskAccessPolicy bool = false

@description('Optional. The resource Id of the Azure Monitor Private Link Scope to which monitoring resources should be linked. There should only be one Azure Monitor Private Link Scope per network that shares the same DNS.')
param azureMonitorPrivateLinkScopeResourceId string = ''

@allowed([
  'None'
  'HostPool'
  'FeedAndHostPool'
  'All'
])
@description('Optional. Determines if Azure Private Link with Azure Virtual Desktop is enabled. Selecting "None" disables AVD Private Link deployment. Selecting one of the other options enables deployment of the required endpoints.')
param avdPrivateLinkPrivateRoutes string = 'None'

@description('Conditional. The resource ID of the subnet where the hostpool private endpoint will be attached. Required when "avdPrivateLinkPrivateRoutes" is not equal to "None".')
param hostpoolPrivateEndpointSubnetResourceId string = ''

@description('Conditional. The resource Id of the AVD Private Link Private DNS Zone used for feed download and connections to host pools. Required when "avdPrivateLinkPrivateRoutes" is not equal to "None".')
param avdPrivateDnsZoneResourceId string = ''

@allowed([
  'Disabled'
  'Enabled'
  'EnabledForClientsOnly'
])
@description('''Optional. Allow public access to the hostpool through the control plane. Applicable only when "avdPrivateLinkPrivateRoutes" is not equal to "None". 
  "Enabled" allows this resource to be accessed from both public and private networks.
  "Disabled" allows this resource to only be accessed via private endpoints.
  "EnabledForClientsOnly" allows this resource to be accessed only when the session hosts are configured to use private routes.
''')
param hostPoolPublicNetworkAccess string = 'Enabled'

@description('Conditional. The resource Id of the subnet where the workspace feed private endpoint will be attached. Required when "avdPrivateLinkPrivateRoutes" is set to "FeedAndHostPool" or "All".')
param workspaceFeedPrivateEndpointSubnetResourceId string = ''

@allowed([
  'Disabled'
  'Enabled'
])
@description('''Optional. Defines the public access configuration for the workspace feed. Applicable when "avdPrivateLinkPrivateRoutes" is "FeedAndHostPool" or "All".
  "Enabled" allows the AVD workspace to be accessed from both public and private networks.
  "Disabled" allows this resource to only be accessed via private endpoints.
''')
param workspaceFeedPublicNetworkAccess string = 'Enabled'

@description('Optional. The resource Id of the existing global feed workspace. If provided, then the global feed will not be deployed regardless of other AVD Private Link settings.')
param existingGlobalFeedResourceId string = ''

@description('Conditional. The resource Id of the AVD Private Link global feed Private DNS Zone. Required when the "avdPrivateLinkPrivateRoutes" is set to "All" and the "existingGlobalFeedResourceId" is not provided.')
param globalFeedPrivateDnsZoneResourceId string = ''

@description('Conditional. The resource Id of the subnet to which the global feed workspace private endpoint will be attached. Required when the "avdPrivateLinkPrivateRoutes" is set to "All" and the "existingGlobalFeedResourceId" is not provided.')
param globalFeedPrivateEndpointSubnetResourceId string = ''

// Tags

@description('Optional. Key / value pairs of metadata for the Azure resource groups and resources.')
param tags object = {}

// Non-Specified Values

@description('Optional. The vm size of the management VM.')
param deploymentVmSize string = 'Standard_B2s'

@description('DO NOT MODIFY THIS VALUE! The timeStamp is needed to differentiate deployments for certain Azure resources and must be set using a parameter.')
param timeStamp string = utcNow('yyyyMMddHHmmss')

// Variables

var deploymentSuffix = startsWith(deployment().name, 'Microsoft.Template-')
  ? substring(deployment().name, 19, 14)
  : timeStamp

var controlPlaneSubscription = empty(controlPlaneSubscriptionId)
  ? subscription().subscriptionId
  : controlPlaneSubscriptionId
var monitoringSubscription = empty(monitoringSubscriptionId) ? subscription().subscriptionId : monitoringSubscriptionId
var hostsSubscription = subscription().subscriptionId
var deploymentSubscription = subscription().subscriptionId
var managementSubscription = subscription().subscriptionId
var storageSubscription = subscription().subscriptionId

var rbacSubs = union([controlPlaneSubscription], [hostsSubscription])

var globalFeedRegion = !empty(globalFeedPrivateEndpointSubnetResourceId)
  ? avdPrivateLinkGlobalFeedNetwork.?location
  : ''
var virtualMachinesRegion = vmVirtualNetwork.location
var controlPlaneRegion = empty(controlPlaneLocation) ? virtualMachinesRegion : controlPlaneLocation

var createDeploymentVm = deploymentType != 'SessionHostsOnly' && (deployFSLogixStorage || contains(
  keyManagementDisks,
  'CustomerManaged'
) || confidentialVMOSDiskEncryption || !empty(desktopFriendlyName))
var deployManagementResources = deploymentType == 'Complete' && (deploySecretsKeyVault || contains(
  keyManagementStorageAccounts,
  'CustomerManaged'
) || contains(keyManagementDisks, 'CustomerManaged') || confidentialVMOSDiskEncryption)

var hostPoolVmTemplate = deploymentType != 'SessionHostsOnly'
  ? {
      resourceGroup: resourceNames.outputs.resourceGroupHosts
      identityType: identitySolution
      intuneEnrollment: intuneEnrollment
      domain: !empty(domainName) ? domainName : null
      ouPath: !empty(vmOUPath) ? vmOUPath : null
      namePrefix: virtualMachineNamePrefix
      indexPadding: vmNameIndexLength
      imageType: empty(customImageResourceId) ? 'Gallery' : 'CustomImage'
      imageUri: null
      customImageId: empty(customImageResourceId) ? null : customImageResourceId
      galleryImageOffer: empty(customImageResourceId) ? imageOffer : null
      galleryImagePublisher: empty(customImageResourceId) ? imagePublisher : null
      galleryImageSku: empty(customImageResourceId) ? imageSku : null
      osDiskType: diskSku
      diskSizeGB: diskSizeGB
      useManagedDisks: true
      vmSize: {
        id: virtualMachineSize
        cores: vCPUs == 0 ? null : vCPUs
        ram: memoryGB == 0 ? null : memoryGB
      }
      encryptionAtHost: encryptionAtHost
      acceleratedNetworking: enableAcceleratedNetworking
      diskEncryptionSetName: confidentialVMOSDiskEncryption
        ? resourceNames.outputs.diskEncryptionSetNames.confidentialVMs
        : startsWith(keyManagementDisks, 'CustomerManaged')
            ? resourceNames.outputs.diskEncryptionSetNames.customerManaged
            : contains(keyManagementDisks, 'PlatformManagedAndCustomerManaged')
                ? resourceNames.outputs.diskEncryptionSetNames.platformAndCustomerManaged
                : null
      hibernate: hibernationEnabled
      securityType: securityType
      secureBoot: secureBootEnabled
      vTPM: vTpmEnabled
      subnetId: virtualMachineSubnetResourceId
      availability: availability == 'AvailabilityZones'
        ? 'Availability Zones'
        : availability == 'AvailabilitySets' ? 'Availability Sets' : 'No infrastructure redundancy required'
      vmInfrastructureType: 'Cloud'
    }
  : {}

// Conditional Host Resource Group Tags
var vmIntuneEnrollment = contains(identitySolution, 'DomainServices') ? {} : { vmIntuneEnrollment: intuneEnrollment }
var vmDomain = contains(identitySolution, 'DomainServices') && !empty(domainName) ? { vmDomain: domainName } : {}
var vmOU = contains(identitySolution, 'DomainServices') && !empty(vmOUPath) ? { vmOUPath: vmOUPath } : {}
var vmCustomImageId = empty(customImageResourceId) ? {} : { vmCustomImageId: customImageResourceId }
var vmImageOffer = !empty(customImageResourceId) || empty(imageOffer) ? {} : { vmImageOffer: imageOffer }
var vmImagePublisher = !empty(customImageResourceId) || empty(imagePublisher)
  ? {}
  : { vmImagePublisher: imagePublisher }
var vmImageSku = !empty(customImageResourceId) || empty(imageSku) ? {} : { vmImageSku: imageSku }
var vmDiskEncryptionSetName = empty(hostPoolVmTemplate.diskEncryptionSetName)
  ? {}
  : { vmDiskEncryptionSetName: hostPoolVmTemplate.diskEncryptionSetName }

var fslLocalStorageAccountNames = deployFSLogixStorage && startsWith(fslogixStorageService, 'AzureFiles')
  ? { fslLocalStorageAccountNames: string(map(fslogix!.outputs.storageAccountResourceIds, id => last(split(id, '/')))) }
  : !empty(fslogixExistingLocalStorageAccountResourceIds)
      ? {
          fslLocalStorageAccountNames: string(map(
            fslogixExistingLocalStorageAccountResourceIds,
            id => last(split(id, '/'))
          ))
        }
      : {}
var fslRemoteStorageAccountNames = !empty(fslogixExistingRemoteStorageAccountResourceIds)
  ? {
      fslRemoteStorageAccountNames: string(map(
        fslogixExistingRemoteStorageAccountResourceIds,
        id => last(split(id, '/'))
      ))
    }
  : {}
var fslLocalNetAppVolumeResourceIds = deployFSLogixStorage && startsWith(fslogixStorageService, 'AzureNetAppFiles')
  ? { fslLocalNetAppVolumeResourceIds: string(fslogix!.outputs.netAppVolumeResourceIds) }
  : !empty(fslogixExistingLocalNetAppVolumeResourceIds)
      ? { fslLocalNetAppVolumeResourceIds: string(fslogixExistingLocalNetAppVolumeResourceIds) }
      : {}
var fslRemoteNetAppVolumeResourceIds = !empty(fslogixExistingRemoteNetAppVolumeResourceIds)
  ? { fslRemoteNetAppVolumeResourceIds: string(fslogixExistingRemoteNetAppVolumeResourceIds) }
  : {}

// FSLogix tags for hosts resource group
var fslogixConfigurationTags = fslogixConfigureSessionHosts
  ? union(
      { fslContainerType: fslogixContainerType },
      { fslContainerSizeInMBs: fslogixSizeInMBs },
      { fslStorageService: split(fslogixStorageService, '')[0] },
      { fslFileShareNames: string(resourceNames.outputs.fslogixFileShareNames[fslogixContainerType]) },
      { fslSharding: fslogixShardOptions },
      fslLocalStorageAccountNames,
      fslRemoteStorageAccountNames,
      fslLocalNetAppVolumeResourceIds,
      fslRemoteNetAppVolumeResourceIds
    )
  : {}

var vmConfigurationTags = union(
  {
    vmResourceGroup: hostPoolVmTemplate.resourceGroup
    vmIdentityType: hostPoolVmTemplate.identityType
    vmNamePrefix: hostPoolVmTemplate.namePrefix
    vmIndexPadding: hostPoolVmTemplate.indexPadding
    vmImageType: hostPoolVmTemplate.imageType
    vmOSDiskType: hostPoolVmTemplate.osDiskType
    vmDiskSizeGB: hostPoolVmTemplate.diskSizeGB
    vmSize: hostPoolVmTemplate.vmSize.id
    vmAvailability: hostPoolVmTemplate.availability
    vmEncryptionAtHost: hostPoolVmTemplate.?encryptionAtHost ?? false
    vmAcceleratedNetworking: hostPoolVmTemplate.?acceleratedNetworking ?? false
    vmHibernate: hostPoolVmTemplate.?hibernate ?? false
    vmSecurityType: hostPoolVmTemplate.?securityType ?? 'Standard'
    vmSecureBoot: hostPoolVmTemplate.?secureBoot ?? false
    vmVirtualTPM: hostPoolVmTemplate.?vTPM ?? false
    vmSubnetId: hostPoolVmTemplate.subnetId
  },
  vmDomain,
  vmOU,
  vmCustomImageId,
  vmImageOffer,
  vmImagePublisher,
  vmImageSku,
  vmIntuneEnrollment,
  vmDiskEncryptionSetName
)

var scalingPlanSchedules = deployScalingPlan
  ? [
      {
        rampUpStartTime: {
          hour: first(split(scalingPlanRampUpSchedule.startTime, ':')[0]) == '0'
            ? int(last(split(scalingPlanRampUpSchedule.startTime, ':')[0]))
            : int(split(scalingPlanRampUpSchedule.startTime, ':')[0])
          minute: first(split(scalingPlanRampUpSchedule.startTime, ':')[1]) == '0'
            ? int(last(split(scalingPlanRampUpSchedule.startTime, ':')[1]))
            : int(split(scalingPlanRampUpSchedule.startTime, ':')[1])
        }
        peakStartTime: {
          hour: first(split(scalingPlanPeakSchedule.startTime, ':')[0]) == '0'
            ? int(last(split(scalingPlanPeakSchedule.startTime, ':')[0]))
            : int(split(scalingPlanPeakSchedule.startTime, ':')[0])
          minute: first(split(scalingPlanPeakSchedule.startTime, ':')[1]) == '0'
            ? int(last(split(scalingPlanPeakSchedule.startTime, ':')[1]))
            : int(split(scalingPlanPeakSchedule.startTime, ':')[1])
        }
        rampDownStartTime: {
          hour: first(split(scalingPlanRampDownSchedule.startTime, ':')[0]) == '0'
            ? int(last(split(scalingPlanRampDownSchedule.startTime, ':')[0]))
            : int(split(scalingPlanRampDownSchedule.startTime, ':')[0])
          minute: first(split(scalingPlanRampDownSchedule.startTime, ':')[1]) == '0'
            ? int(last(split(scalingPlanRampDownSchedule.startTime, ':')[1]))
            : int(split(scalingPlanRampDownSchedule.startTime, ':')[1])
        }
        offPeakStartTime: {
          hour: first(split(scalingPlanOffPeakSchedule.startTime, ':')[0]) == '0'
            ? int(last(split(scalingPlanOffPeakSchedule.startTime, ':')[0]))
            : int(split(scalingPlanOffPeakSchedule.startTime, ':')[0])
          minute: first(split(scalingPlanOffPeakSchedule.startTime, ':')[1]) == '0'
            ? int(last(split(scalingPlanOffPeakSchedule.startTime, ':')[1]))
            : int(split(scalingPlanOffPeakSchedule.startTime, ':')[1])
        }
        name: 'weekdays_schedule'
        daysOfWeek: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
        rampUpLoadBalancingAlgorithm: scalingPlanRampUpSchedule.loadBalancingAlgorithm
        rampUpMinimumHostsPct: scalingPlanRampUpSchedule.minimumHostsPct
        rampUpCapacityThresholdPct: scalingPlanRampUpSchedule.capacityThresholdPct
        peakLoadBalancingAlgorithm: scalingPlanPeakSchedule.loadBalancingAlgorithm
        rampDownLoadBalancingAlgorithm: scalingPlanRampDownSchedule.loadBalancingAlgorithm
        rampDownMinimumHostsPct: scalingPlanRampDownSchedule.minimumHostsPct
        rampDownCapacityThresholdPct: scalingPlanRampDownSchedule.capacityThresholdPct
        rampDownForceLogoffUsers: scalingPlanForceLogoff
        rampDownWaitTimeMinutes: scalingPlanMinsBeforeLogoff
        rampDownNotificationMessage: scalingPlanForceLogoff
          ? 'You will be logged off in ${scalingPlanMinsBeforeLogoff} minutes. Make sure to save your work.'
          : null
        rampDownStopHostsWhen: 'ZeroSessions'
        offPeakLoadBalancingAlgorithm: scalingPlanOffPeakSchedule.loadBalancingAlgorithm
      }
    ]
  : []

var exclusionTag = !empty(scalingPlanExclusionTag) && deployScalingPlan
  ? {
      'Microsoft.Compute/virtualMachines': {
        '${scalingPlanExclusionTag}': ''
      }
    }
  : {}

var hostTags = !empty(exclusionTag) ? union(tags, exclusionTag) : tags

var fslogixFileShareNames = resourceNames.outputs.fslogixFileShareNames[fslogixContainerType]
var fslogixStorageCount = identitySolution == 'EntraId' || fslogixShardOptions == 'None' ? 1 : length(fslogixUserGroups)

//  BATCH SESSION HOSTS
// The following variables are used to determine the batches to deploy any number of AVD session hosts.
var maxVMsPerDeployment = 40 // The maximum number of VMs deployed per batch to stay within ARM template resource limits. Math: (800 - <Number of Static Resources>) / <Number of Resources per VM> 
var divisionValue = sessionHostCount / maxVMsPerDeployment // The number of full batches (integer division).
var divisionRemainderValue = sessionHostCount % maxVMsPerDeployment // The number of VMs in the final partial batch (0 if all batches are full).
var sessionHostBatchCount = divisionRemainderValue > 0 ? divisionValue + 1 : divisionValue // The total number of batches needed (full batches + 1 partial batch if remainder exists).

//  BATCH AVAILABILITY SETS
// The following variables are used to determine the number of availability sets.
var maxAvSetMembers = 200 // This is the max number of session hosts that can be deployed in an availability set.
var beginAvSetRange = sessionHostIndex / maxAvSetMembers // This determines the availability set to start with.
var endAvSetRange = (sessionHostCount + sessionHostIndex) / maxAvSetMembers // This determines the availability set to end with.
var availabilitySetsCount = length(range(beginAvSetRange, (endAvSetRange - beginAvSetRange) + 1))

var sessionHostRegistrationDSCStorageAccount = startsWith(environment().name, 'USN')
  ? 'wvdexportalcontainer'
  : 'wvdportalstorageblob'
var sessionHostRegistrationDSCUrl = startsWith(avdAgentsDSCPackage, 'https://')
  ? avdAgentsDSCPackage
  : 'https://${sessionHostRegistrationDSCStorageAccount}.blob.${environment().suffixes.storage}/galleryartifacts/${avdAgentsDSCPackage}'

var deployDiskAccessResource = contains(hostPoolType, 'Personal') && recoveryServices && deployPrivateEndpoints
  ? true
  : false

var dedicatedHostGroupName = !empty(dedicatedHostResourceId)
  ? split(dedicatedHostResourceId, '/')[8]
  : !empty(dedicatedHostGroupResourceId) ? last(split(dedicatedHostGroupResourceId, '/')) : ''
var dedicatedHostSub = !empty(dedicatedHostResourceId)
  ? split(dedicatedHostResourceId, '/')[2]
  : !empty(dedicatedHostGroupResourceId) ? split(dedicatedHostGroupResourceId, '/')[2] : ''
var dedicatedHostRG = !empty(dedicatedHostResourceId)
  ? split(dedicatedHostResourceId, '/')[4]
  : !empty(dedicatedHostGroupResourceId) ? split(dedicatedHostGroupResourceId, '/')[4] : ''

// Custom Tags for Host Pool
var hostsResourceGroupIdTag = {
  hostResourceGroupId: '/subscriptions/${hostsSubscription}/resourceGroups/${resourceNames.outputs.resourceGroupHosts}'
}
var storageResourceGroupIdTag = deployFSLogixStorage
  ? {
      storageResourceGroupId: '/subscriptions/${storageSubscription}/resourceGroups/${resourceNames.outputs.resourceGroupStorage}'
    }
  : {}

var encryptionKeyVaultResourceId = contains(keyManagementStorageAccounts, 'Customer') || contains(
    keyManagementDisks,
    'Customer'
  )
  ? (deploymentType == 'Complete'
      ? management!.outputs.encryptionKeyVaultResourceId
      : existingEncryptionKeyVaultResourceId)
  : ''
#disable-next-line BCP318
var encryptionKeyVaultUri = contains(keyManagementStorageAccounts, 'Customer') || contains(
    keyManagementDisks,
    'Customer'
  )
  ? (deploymentType == 'Complete'
      ? management!.outputs.encryptionKeyVaultUri
      : (empty(existingEncryptionKeyVaultResourceId) ? '' : kvEncryption!.properties.vaultUri))
  : ''

// Existing Resources

resource dedicatedHostGroup 'Microsoft.Compute/hostGroups@2024-11-01' existing = if (!empty(dedicatedHostGroupName)) {
  scope: resourceGroup(dedicatedHostSub, dedicatedHostRG)
  name: dedicatedHostGroupName
}

resource existingHostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' existing = if (!empty(existingHostPoolResourceId)) {
  name: last(split(existingHostPoolResourceId, '/'))
  scope: resourceGroup(split(existingHostPoolResourceId, '/')[2], split(existingHostPoolResourceId, '/')[4])
}

// Existing Session Host Virtual Network location
resource vmVirtualNetwork 'Microsoft.Network/virtualNetworks@2023-04-01' existing = {
  name: split(virtualMachineSubnetResourceId, '/')[8]
  scope: resourceGroup(split(virtualMachineSubnetResourceId, '/')[2], split(virtualMachineSubnetResourceId, '/')[4])
}

// Existing  Virtual Network for the AVD Private Link Global Feed Private Endpoint
resource avdPrivateLinkGlobalFeedNetwork 'Microsoft.Network/virtualNetworks@2023-04-01' existing = if (!empty(globalFeedPrivateEndpointSubnetResourceId)) {
  name: split(globalFeedPrivateEndpointSubnetResourceId, '/')[8]
  scope: resourceGroup(
    split(globalFeedPrivateEndpointSubnetResourceId, '/')[2],
    split(globalFeedPrivateEndpointSubnetResourceId, '/')[4]
  )
}

// Existing Key Vaults for secrets (only used for UI deployments since you can specify references in Parameter files.)
resource kvCredentials 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(credentialsKeyVaultResourceId)) {
  name: last(split(credentialsKeyVaultResourceId, '/'))
  scope: resourceGroup(split(credentialsKeyVaultResourceId, '/')[2], split(credentialsKeyVaultResourceId, '/')[4])
}

// Existing Key Vault for Customer Managed Keys
resource kvEncryption 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(existingEncryptionKeyVaultResourceId)) {
  name: last(split(existingEncryptionKeyVaultResourceId, '/'))
  scope: resourceGroup(
    split(existingEncryptionKeyVaultResourceId, '/')[2],
    split(existingEncryptionKeyVaultResourceId, '/')[4]
  )
}

// Deployments

// Resource Names
module resourceNames 'modules/resourceNames.bicep' = {
  name: 'Resource-Names-${deploymentSuffix}'
  params: {
    existingFeedWorkspaceResourceId: existingFeedWorkspaceResourceId
    existingHostPoolResourceId: existingHostPoolResourceId
    fslogixStorageCustomPrefix: fslogixStorageCustomPrefix
    identifier: identifier
    index: index
    controlPlaneRegion: controlPlaneRegion
    globalFeedRegion: globalFeedRegion!
    virtualMachinesRegion: virtualMachinesRegion
    nameConvResTypeAtEnd: deploymentType != 'SessionHostsOnly'
      ? nameConvResTypeAtEnd
      : bool(existingHostPool.?tags.?nameConvResTypeAtEnd) ?? false
    virtualMachineNamePrefix: virtualMachineNamePrefix
  }
}

// Resource Groups
module deploymentResourceGroup 'modules/resourceGroups.bicep' = if (createDeploymentVm) {
  scope: subscription(deploymentSubscription)
  name: 'Resource-Group-Deployment-${deploymentSuffix}'
  params: {
    location: virtualMachinesRegion
    resourceGroupName: resourceNames.outputs.resourceGroupDeployment
    tags: union(tags[?'Microsoft.Resources/resourceGroups'] ?? {}, {
      'cm-resource-parent': '${subscription().id}/resourceGroups/${resourceNames.outputs.resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostpools/${resourceNames.outputs.hostPoolName}'
    })
  }
}

module monitoringResourceGroup 'modules/resourceGroups.bicep' = if (deploymentType == 'Complete' && enableMonitoring) {
  name: 'Resource-Group-Monitoring-${deploymentSuffix}'
  scope: subscription(monitoringSubscription)
  params: {
    location: virtualMachinesRegion
    resourceGroupName: resourceNames.outputs.resourceGroupMonitoring
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module managementResourceGroup 'modules/resourceGroups.bicep' = if (deployManagementResources) {
  name: 'Resource-Group-Management-${deploymentSuffix}'
  scope: subscription(managementSubscription)
  params: {
    location: virtualMachinesRegion
    resourceGroupName: resourceNames.outputs.resourceGroupManagement
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module controlPlaneResourceGroup 'modules/resourceGroups.bicep' = if (deploymentType == 'Complete' && empty(existingFeedWorkspaceResourceId)) {
  name: 'Resource-Group-Control-Plane-${deploymentSuffix}'
  scope: subscription(controlPlaneSubscription)
  params: {
    location: controlPlaneRegion
    resourceGroupName: resourceNames.outputs.resourceGroupControlPlane
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module globalFeedResourceGroup 'modules/resourceGroups.bicep' = if (avdPrivateLinkPrivateRoutes == 'All' && !empty(globalFeedPrivateEndpointSubnetResourceId) && empty(existingGlobalFeedResourceId)) {
  name: 'Resource-Group-Global-Feed-${deploymentSuffix}'
  scope: subscription(controlPlaneSubscription)
  params: {
    location: globalFeedRegion!
    resourceGroupName: resourceNames.outputs.resourceGroupGlobalFeed
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

// Host Resource Group with No Tags to prevent circular dependency between deployment prerequisites and outputs from fslogix.

module hostsResourceGroupNoTags 'modules/resourceGroups.bicep' = if (deploymentType != 'SessionHostsOnly') {
  name: 'Resource-Group-Hosts-${deploymentSuffix}'
  scope: subscription(hostsSubscription)
  params: {
    location: virtualMachinesRegion
    resourceGroupName: resourceNames.outputs.resourceGroupHosts
    tags: {}
  }
}

module hostsResourceGroupWithTags 'modules/resourceGroups.bicep' = if (deploymentType != 'SessionHostsOnly') {
  name: 'Resource-Group-Hosts-Tags-${deploymentSuffix}'
  scope: subscription(hostsSubscription)
  params: {
    location: virtualMachinesRegion
    resourceGroupName: resourceNames.outputs.resourceGroupHosts
    tags: union(
      tags[?'Microsoft.Resources/resourceGroups'] ?? {},
      vmConfigurationTags,
      fslogixConfigurationTags,
      {
        'cm-resource-parent': '${subscription().id}/resourceGroups/${resourceNames.outputs.resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostpools/${resourceNames.outputs.hostPoolName}'
      }
    )
  }
}

module storageResourceGroup 'modules/resourceGroups.bicep' = if (deployFSLogixStorage) {
  name: 'Resource-Group-FSLogix-Storage-${deploymentSuffix}'
  scope: subscription(storageSubscription)
  params: {
    location: virtualMachinesRegion
    resourceGroupName: resourceNames.outputs.resourceGroupStorage
    tags: union(tags[?'Microsoft.Resources/resourceGroups'] ?? {}, {
      'cm-resource-parent': '${subscription().id}/resourceGroups/${resourceNames.outputs.resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostpools/${resourceNames.outputs.hostPoolName}'
    })
  }
}

// Subscrpiption Level RBAC Assignments
module rbac 'modules/rbac/rbac.bicep' = [
  for (subId, i) in rbacSubs: if (deploymentType != 'SessionHostsOnly' && !empty(avdObjectId) && (deployScalingPlan || startVmOnConnect)) {
    name: 'Subscription-Role-Assignment-${i}-${deploymentSuffix}'
    scope: subscription(subId)
    params: {
      avdObjectId: avdObjectId
      deployScalingPlan: deployScalingPlan
      startVmOnConnect: startVmOnConnect
    }
  }
]

// Deployment VM for Prerequisites
module deploymentPrereqs 'modules/deployment/deployment.bicep' = if (createDeploymentVm) {
  name: 'Deployment-Prereqs-${deploymentSuffix}'
  scope: subscription(deploymentSubscription)
  params: {
    confidentialVMOSDiskEncryption: confidentialVMOSDiskEncryption
    deploymentSuffix: deploymentSuffix
    deploymentVmSize: deploymentVmSize
    desktopFriendlyName: desktopFriendlyName
    diskSku: diskSku
    #disable-next-line BCP422
    domainJoinUserPassword: contains(identitySolution, 'DomainServices') || identitySolution == 'EntraKerberos-Hybrid'
      ? !empty(domainJoinUserPassword)
          ? domainJoinUserPassword
          : !empty(credentialsKeyVaultResourceId) ? kvCredentials.getSecret('DomainJoinUserPassword') : ''
      : ''
    #disable-next-line BCP422
    domainJoinUserPrincipalName: contains(identitySolution, 'DomainServices') || identitySolution == 'EntraKerberos-Hybrid'
      ? !empty(domainJoinUserPrincipalName)
          ? domainJoinUserPrincipalName
          : !empty(credentialsKeyVaultResourceId) ? kvCredentials.getSecret('DomainJoinUserPrincipalName') : ''
      : ''
    domainName: domainName
    encryptionAtHost: encryptionAtHost
    fslogix: deployFSLogixStorage
    fslogixAppUpdateUserAssignedIdentityResourceId: fslogixAppUpdateUserAssignedIdentityResourceId
    hostPoolName: resourceNames.outputs.hostPoolName
    identitySolution: identitySolution
    keyManagementDisks: keyManagementDisks
    keyManagementStorageAccounts: keyManagementStorageAccounts
    location: virtualMachinesRegion
    ouPath: vmOUPath
    resourceGroupControlPlane: deploymentType != 'SessionHostsOnly'
      ? resourceNames.outputs.resourceGroupControlPlane
      : split(existingHostPoolResourceId, '/')[4]
    resourceGroupDeployment: resourceNames.outputs.resourceGroupDeployment
    resourceGroupHosts: deploymentType != 'SessionHostsOnly'
      ? resourceNames.outputs.resourceGroupHosts
      : existingHostsResourceGroupName
    resourceGroupManagement: resourceNames.outputs.resourceGroupManagement
    resourceGroupStorage: resourceNames.outputs.resourceGroupStorage
    tags: tags
    userAssignedIdentityNameConv: resourceNames.outputs.userAssignedIdentityNameConv
    #disable-next-line BCP422
    virtualMachineAdminPassword: !empty(credentialsKeyVaultResourceId)
      ? kvCredentials.getSecret('VirtualMachineAdminPassword')
      : virtualMachineAdminPassword
    #disable-next-line BCP422
    virtualMachineAdminUserName: !empty(credentialsKeyVaultResourceId)
      ? kvCredentials.getSecret('VirtualMachineAdminUserName')
      : virtualMachineAdminUserName
    virtualMachineName: resourceNames.outputs.depVirtualMachineName
    virtualMachineNICName: resourceNames.outputs.depVirtualMachineNicName
    virtualMachineDiskName: resourceNames.outputs.depVirtualMachineDiskName
    virtualMachineSubnetResourceId: virtualMachineSubnetResourceId
  }
  dependsOn: [
    deploymentResourceGroup
  ]
}

// Monitoring: Log Analytics Workspace, Data Collection Endpoint, Data Collection Rules, Automation Account
module monitoring 'modules/monitoring/monitoring.bicep' = if (deploymentType == 'Complete' && enableMonitoring) {
  name: 'Monitoring-${deploymentSuffix}'
  scope: subscription(monitoringSubscription)
  params: {
    azureMonitorPrivateLinkScopeResourceId: azureMonitorPrivateLinkScopeResourceId
    dataCollectionEndpointName: resourceNames.outputs.dataCollectionEndpointName
    deploymentSuffix: deploymentSuffix
    location: virtualMachinesRegion
    logAnalyticsWorkspaceName: resourceNames.outputs.logAnalyticsWorkspaceName
    resourceGroupMonitoring: resourceNames.outputs.resourceGroupMonitoring
    tags: tags
  }
  dependsOn: [
    monitoringResourceGroup
  ]
}

// Management Services: Monitoring, secrets, and App Service Plan (if needed)
module management 'modules/management/management.bicep' = if (deployManagementResources) {
  name: 'Management-${deploymentSuffix}'
  scope: subscription(managementSubscription)
  params: {
    azureKeyVaultPrivateDnsZoneResourceId: azureKeyVaultPrivateDnsZoneResourceId
    deploymentSuffix: deploymentSuffix
    encryptionKeysKeyVaultName: resourceNames.outputs.keyVaultNames.encryptionKeys
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    deployEncryptionKeysKeyVault: deploymentType == 'Complete' && (contains(keyManagementDisks, 'Customer') || contains(
      keyManagementStorageAccounts,
      'Customer'
    ))
    deploySecretsKeyVault: deploySecretsKeyVault
    keyVaultEnablePurgeProtection: secretsKeyVaultEnablePurgeProtection
    keyVaultEnableSoftDelete: secretsKeyVaultEnableSoftDelete
    secretsKeyVaultName: resourceNames.outputs.keyVaultNames.secrets
    keyVaultRetentionInDays: keyVaultRetentionInDays
    logAnalyticsWorkspaceResourceId: enableMonitoring
      ? (deploymentType == 'Complete'
          ? monitoring!.outputs.logAnalyticsWorkspaceResourceId
          : existingLogAnalyticsWorkspaceResourceId)
      : ''
    privateEndpointSubnetResourceId: keyVaultPrivateEndpointSubnetResourceId
    privateEndpoint: deployPrivateEndpoints
    privateEndpointNameConv: resourceNames.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: resourceNames.outputs.privateEndpointNICNameConv
    resourceGroupManagement: resourceNames.outputs.resourceGroupManagement
    tags: tags
    virtualMachineAdminPassword: virtualMachineAdminPassword
    virtualMachineAdminUserName: virtualMachineAdminUserName
  }
  dependsOn: [
    managementResourceGroup
  ]
}

// AVD Control Plane Resources: workspace, host pool, and desktop application group
module controlPlane 'modules/controlPlane/controlPlane.bicep' = if (deploymentType != 'SessionHostsOnly') {
  name: 'ControlPlane-${deploymentSuffix}'
  scope: subscription(controlPlaneSubscription)
  params: {
    appGroupSecurityGroups: map(appGroupSecurityGroups, group => group.id)
    avdPrivateDnsZoneResourceId: avdPrivateDnsZoneResourceId
    avdPrivateLinkPrivateRoutes: avdPrivateLinkPrivateRoutes
    controlPlaneRegion: controlPlaneRegion
    deployScalingPlan: deployScalingPlan
    deploymentSuffix: deploymentSuffix
    deploymentUserAssignedIdentityClientId: createDeploymentVm
      ? deploymentPrereqs!.outputs.deploymentUserAssignedIdentityClientId
      : ''
    deploymentVirtualMachineName: createDeploymentVm ? deploymentPrereqs!.outputs.virtualMachineName : ''
    desktopApplicationGroupName: resourceNames.outputs.desktopApplicationGroupName
    desktopFriendlyName: desktopFriendlyName
    enableMonitoring: enableMonitoring
    existingFeedWorkspaceResourceId: existingFeedWorkspaceResourceId
    existingGlobalWorkspaceResourceId: existingGlobalFeedResourceId
    globalFeedPrivateDnsZoneResourceId: globalFeedPrivateDnsZoneResourceId
    globalFeedPrivateEndpointSubnetResourceId: globalFeedPrivateEndpointSubnetResourceId
    globalFeedRegion: globalFeedRegion!
    globalWorkspaceName: resourceNames.outputs.globalFeedWorkspaceName
    hostPoolCustomTags: union(hostsResourceGroupIdTag, storageResourceGroupIdTag)
    hostPoolMaxSessionLimit: hostPoolMaxSessionLimit
    hostPoolName: resourceNames.outputs.hostPoolName
    hostPoolPrivateEndpointSubnetResourceId: hostpoolPrivateEndpointSubnetResourceId
    hostPoolPublicNetworkAccess: hostPoolPublicNetworkAccess
    hostPoolRDPProperties: hostPoolRDPProperties
    hostPoolType: hostPoolType
    hostPoolValidationEnvironment: hostPoolValidationEnvironment
    hostPoolVmTemplate: hostPoolVmTemplate
    virtualMachinesRegion: virtualMachinesRegion
    logAnalyticsWorkspaceResourceId: enableMonitoring
      ? (deploymentType == 'Complete'
          ? monitoring!.outputs.logAnalyticsWorkspaceResourceId
          : existingLogAnalyticsWorkspaceResourceId)
      : ''
    privateEndpointNameConv: resourceNames.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: resourceNames.outputs.privateEndpointNICNameConv
    resourceGroupControlPlane: resourceNames.outputs.resourceGroupControlPlane
    resourceGroupGlobalFeed: resourceNames.outputs.resourceGroupGlobalFeed
    resourceGroupDeployment: resourceNames.outputs.resourceGroupDeployment
    scalingPlanName: resourceNames.outputs.scalingPlanName
    scalingPlanSchedules: scalingPlanSchedules
    scalingPlanExclusionTag: scalingPlanExclusionTag
    startVmOnConnect: startVmOnConnect
    tags: tags
    virtualMachinesTimeZone: virtualMachinesTimeZone
    workspaceFeedPrivateEndpointSubnetResourceId: workspaceFeedPrivateEndpointSubnetResourceId
    workspaceFriendlyName: workspaceFriendlyName
    workspaceName: resourceNames.outputs.workspaceName
    workspacePublicNetworkAccess: workspaceFeedPublicNetworkAccess
  }
  dependsOn: [
    controlPlaneResourceGroup
  ]
}

// FSLogix Storage
module fslogix 'modules/fslogix/fslogix.bicep' = if (deploymentType != 'SessionHostsOnly' && deployFSLogixStorage) {
  name: 'FSLogix-${deploymentSuffix}'
  scope: subscription(storageSubscription)
  params: {
    activeDirectoryConnection: existingSharedActiveDirectoryConnection
    appUpdateUserAssignedIdentityResourceId: fslogixAppUpdateUserAssignedIdentityResourceId
    availability: availability
    azureBackupPrivateDnsZoneResourceId: azureBackupPrivateDnsZoneResourceId
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureFilePrivateDnsZoneResourceId: azureFilesPrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    deploymentUserAssignedIdentityClientId: createDeploymentVm
      ? deploymentPrereqs!.outputs.deploymentUserAssignedIdentityClientId
      : ''
    deploymentVirtualMachineName: createDeploymentVm ? deploymentPrereqs!.outputs.virtualMachineName : ''
    #disable-next-line BCP422
    domainJoinUserPassword: contains(identitySolution, 'DomainServices') || identitySolution == 'EntraKerberos-Hybrid'
      ? !empty(domainJoinUserPassword)
          ? domainJoinUserPassword
          : !empty(credentialsKeyVaultResourceId) ? kvCredentials.getSecret('DomainJoinUserPassword') : ''
      : ''
    #disable-next-line BCP422
    domainJoinUserPrincipalName: contains(identitySolution, 'DomainServices') || identitySolution == 'EntraKerberos-Hybrid'
      ? !empty(domainJoinUserPrincipalName)
          ? domainJoinUserPrincipalName
          : !empty(credentialsKeyVaultResourceId) ? kvCredentials.getSecret('DomainJoinUserPrincipalName') : ''
      : ''
    domainName: domainName
    encryptionKeyVaultResourceId: encryptionKeyVaultResourceId
    encryptionKeyVaultUri: encryptionKeyVaultUri
    fslogixAdminGroups: fslogixAdminGroups
    fslogixEncryptionKeyNameConv: resourceNames.outputs.encryptionKeyNames.fslogix
    fslogixFileShares: fslogixFileShareNames
    fslogixShardOptions: fslogixShardOptions
    fslogixUserGroups: fslogixUserGroups
    hostPoolResourceId: deploymentType == 'SessionHostsOnly'
      ? existingHostPoolResourceId
      : controlPlane!.outputs.hostPoolResourceId
    identitySolution: identitySolution
    kerberosEncryptionType: fslogixStorageKerberosEncryptionType
    keyExpirationInDays: keyExpirationInDays
    keyManagementStorageAccounts: keyManagementStorageAccounts
    location: virtualMachinesRegion
    logAnalyticsWorkspaceResourceId: enableMonitoring
      ? (deploymentType == 'Complete'
          ? monitoring!.outputs.logAnalyticsWorkspaceResourceId
          : existingLogAnalyticsWorkspaceResourceId)
      : ''
    netAppVolumesSubnetResourceId: netAppVolumesSubnetResourceId
    netAppAccountName: resourceNames.outputs.netAppAccountName
    netAppCapacityPoolName: resourceNames.outputs.netAppCapacityPoolName
    ouPath: empty(fslogixOUPath) ? vmOUPath : fslogixOUPath
    privateEndpoint: deployPrivateEndpoints
    privateEndpointNameConv: resourceNames.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: resourceNames.outputs.privateEndpointNICNameConv
    privateEndpointSubnetResourceId: hostPoolResourcesPrivateEndpointSubnetResourceId
    recoveryServices: recoveryServices
    recoveryServicesVaultName: resourceNames.outputs.recoveryServicesVaultNames.fslogixStorage
    resourceGroupDeployment: resourceNames.outputs.resourceGroupDeployment
    resourceGroupStorage: resourceNames.outputs.resourceGroupStorage
    shareSizeInGB: fslogixShareSizeInGB
    smbServerLocation: resourceNames.outputs.smbServerLocation
    storageAccountNamePrefix: resourceNames.outputs.storageAccountNames.fslogix
    storageCount: fslogixStorageCount
    storageIndex: fslogixStorageIndex
    storageSku: fslogixStorageService == 'None' ? 'None' : split(fslogixStorageService, ' ')[1]
    storageSolution: split(fslogixStorageService, ' ')[0]
    tags: tags
    deploymentSuffix: deploymentSuffix
    timeZone: virtualMachinesTimeZone
    userAssignedIdentityNameConv: resourceNames.outputs.userAssignedIdentityNameConv
  }
  dependsOn: [
    storageResourceGroup
  ]
}

// Session Hosts
module sessionHosts 'modules/sessionHosts/sessionHosts.bicep' = {
  name: 'Session-Hosts-${deploymentSuffix}'
  scope: subscription(hostsSubscription)
  params: {
    appGroupSecurityGroups: deploymentType == 'Complete' ? map(appGroupSecurityGroups, group => group.id) : []
    artifactsContainerUri: artifactsContainerUri
    artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
    avdInsightsDataCollectionRulesResourceId: enableMonitoring
      ? (deploymentType == 'Complete'
          ? monitoring!.outputs.avdInsightsDataCollectionRulesResourceId
          : existingAVDInsightsDataCollectionRuleResourceId)
      : ''
    availability: availability
    availabilitySetNamePrefix: resourceNames.outputs.availabilitySetNamePrefix
    availabilitySetsCount: availabilitySetsCount
    availabilitySetsIndex: beginAvSetRange
    availabilityZones: availabilityZones
    azureBackupPrivateDnsZoneResourceId: azureBackupPrivateDnsZoneResourceId
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    confidentialVMOrchestratorObjectId: confidentialVMOrchestratorObjectId
    confidentialVMOSDiskEncryption: confidentialVMOSDiskEncryption
    customImageResourceId: customImageResourceId
    dataCollectionEndpointResourceId: enableMonitoring
      ? (deploymentType == 'Complete'
          ? monitoring!.outputs.dataCollectionEndpointResourceId
          : existingDataCollectionEndpointResourceId)
      : ''
    dedicatedHostGroupResourceId: dedicatedHostGroupResourceId
    dedicatedHostGroupZones: !empty(dedicatedHostGroupName) ? dedicatedHostGroup!.zones : []
    dedicatedHostResourceId: dedicatedHostResourceId
    deployDiskAccessPolicy: deployDiskAccessPolicy
    deployDiskAccessResource: deployDiskAccessResource
    deploymentType: deploymentType
    deploymentUserAssignedIdentityClientId: createDeploymentVm
      ? deploymentPrereqs!.outputs.deploymentUserAssignedIdentityClientId
      : ''
    deploymentVirtualMachineName: createDeploymentVm ? deploymentPrereqs!.outputs.virtualMachineName : ''
    diskAccessName: resourceNames.outputs.diskAccessName
    diskEncryptionSetNames: resourceNames.outputs.diskEncryptionSetNames
    diskSizeGB: diskSizeGB
    diskSku: diskSku
    divisionRemainderValue: divisionRemainderValue
    #disable-next-line BCP422
    domainJoinUserPassword: contains(identitySolution, 'DomainServices')
      ? !empty(domainJoinUserPassword)
          ? domainJoinUserPassword
          : !empty(credentialsKeyVaultResourceId) ? kvCredentials.getSecret('DomainJoinUserPassword') : ''
      : ''
    #disable-next-line BCP422
    domainJoinUserPrincipalName: contains(identitySolution, 'DomainServices')
      ? !empty(domainJoinUserPrincipalName)
          ? domainJoinUserPrincipalName
          : !empty(credentialsKeyVaultResourceId) ? kvCredentials.getSecret('DomainJoinUserPrincipalName') : ''
      : ''
    domainName: domainName
    enableAcceleratedNetworking: enableAcceleratedNetworking
    enableMonitoring: enableMonitoring
    encryptionAtHost: encryptionAtHost
    encryptionKeyName: confidentialVMOSDiskEncryption
      ? resourceNames.outputs.encryptionKeyNames.confidentialVMs
      : resourceNames.outputs.encryptionKeyNames.virtualMachines
    encryptionKeyVaultResourceId: encryptionKeyVaultResourceId
    encryptionKeyVaultUri: encryptionKeyVaultUri
    existingDiskAccessResourceId: existingDiskAccessResourceId
    existingDiskEncryptionSetResourceId: existingDiskEncryptionSetResourceId
    existingRecoveryServicesVaultResourceId: existingRecoveryServicesVaultResourceId
    fslogixConfigureSessionHosts: fslogixConfigureSessionHosts
    fslogixContainerType: fslogixContainerType
    fslogixFileShareNames: fslogixFileShareNames
    fslogixLocalStorageAccountResourceIds: deploymentType == 'Complete' && deployFSLogixStorage
      ? fslogix!.outputs.storageAccountResourceIds
      : fslogixExistingLocalStorageAccountResourceIds
    fslogixLocalNetAppVolumeResourceIds: deploymentType == 'Complete' && deployFSLogixStorage
      ? fslogix!.outputs.netAppVolumeResourceIds
      : fslogixExistingLocalNetAppVolumeResourceIds
    fslogixOSSGroups: fslogixShardOptions == 'ShardOSS' ? map(fslogixUserGroups, group => group.name) : []
    fslogixRemoteNetAppVolumeResourceIds: fslogixExistingRemoteNetAppVolumeResourceIds
    fslogixRemoteStorageAccountResourceIds: fslogixExistingRemoteStorageAccountResourceIds
    fslogixSizeInMBs: fslogixSizeInMBs
    fslogixStorageService: split(fslogixStorageService, ' ')[0]
    hibernationEnabled: hibernationEnabled
    hostPoolResourceId: deploymentType == 'SessionHostsOnly'
      ? existingHostPoolResourceId
      : controlPlane!.outputs.hostPoolResourceId
    identitySolution: identitySolution
    imageOffer: imageOffer
    imagePublisher: imagePublisher
    imageSku: imageSku
    integrityMonitoring: integrityMonitoring
    intuneEnrollment: intuneEnrollment
    keyExpirationInDays: keyExpirationInDays
    keyManagementDisks: keyManagementDisks
    logAnalyticsWorkspaceResourceId: enableMonitoring
      ? (deploymentType == 'Complete'
          ? monitoring!.outputs.logAnalyticsWorkspaceResourceId
          : existingLogAnalyticsWorkspaceResourceId)
      : ''
    location: virtualMachinesRegion
    maxVMsPerDeployment: maxVMsPerDeployment
    osDiskNameConv: resourceNames.outputs.virtualMachineDiskNameConv
    ouPath: vmOUPath
    pooledHostPool: split(hostPoolType, ' ')[0] == 'Pooled' ? true : false
    privateEndpoint: deployPrivateEndpoints
    privateEndpointNameConv: resourceNames.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: resourceNames.outputs.privateEndpointNICNameConv
    privateEndpointSubnetResourceId: hostPoolResourcesPrivateEndpointSubnetResourceId
    networkInterfaceNameConv: resourceNames.outputs.virtualMachineNicNameConv
    recoveryServices: deploymentType != 'SessionHostsOnly'
      ? (contains(hostPoolType, 'Personal') ? recoveryServices : false)
      : recoveryServices
    recoveryServicesVaultName: resourceNames.outputs.recoveryServicesVaultNames.virtualMachines
    resourceGroupHosts: deploymentType != 'SessionHostsOnly'
      ? resourceNames.outputs.resourceGroupHosts
      : existingHostsResourceGroupName
    resourceGroupDeployment: resourceNames.outputs.resourceGroupDeployment
    securityDataCollectionRulesResourceId: securityDataCollectionRulesResourceId
    securityType: securityType
    secureBootEnabled: secureBootEnabled
    sessionHostBatchCount: sessionHostBatchCount
    sessionHostCustomizations: sessionHostCustomizations
    sessionHostIndex: sessionHostIndex
    vmNameIndexLength: vmNameIndexLength
    sessionHostRegistrationDSCUrl: sessionHostRegistrationDSCUrl
    storageSuffix: environment().suffixes.storage
    subnetResourceId: virtualMachineSubnetResourceId
    tags: hostTags
    deploymentSuffix: deploymentSuffix
    timeZone: virtualMachinesTimeZone
    useAgentDownloadEndpoint: useAgentDownloadEndpoint
    #disable-next-line BCP422
    virtualMachineAdminPassword: !empty(credentialsKeyVaultResourceId)
      ? kvCredentials.getSecret('VirtualMachineAdminPassword')
      : virtualMachineAdminPassword
    #disable-next-line BCP422
    virtualMachineAdminUserName: !empty(credentialsKeyVaultResourceId)
      ? kvCredentials.getSecret('VirtualMachineAdminUserName')
      : virtualMachineAdminUserName
    virtualMachineNameConv: resourceNames.outputs.virtualMachineNameConv
    virtualMachineNamePrefix: virtualMachineNamePrefix
    virtualMachineSize: virtualMachineSize
    vmInsightsDataCollectionRulesResourceId: enableMonitoring
      ? (deploymentType == 'Complete'
          ? monitoring!.outputs.vmInsightsDataCollectionRulesResourceId
          : existingVMInsightsDataCollectionRuleResourceId)
      : ''
    vTpmEnabled: vTpmEnabled
  }
  dependsOn: [
    hostsResourceGroupWithTags
  ]
}

// Session Host Replacer has been moved to a separate add-on deployment.
// See deployments/add-ons/SessionHostReplacer/ for deployment instructions.
// To deploy the session host replacer, use the add-on template with the following parameters:
// - hostPoolResourceId: The resource ID of the host pool
// - sessionHostResourceGroupName: The name of the resource group containing session hosts
// - sessionHostTemplateSpecVersionResourceId: The Template Spec version resource ID
// - sessionHostReplacerUserAssignedIdentityResourceId: UAI with Graph API permissions

// Clean Up Deployment VM and Role Assignments
module cleanUp 'modules/cleanUp/cleanUp.bicep' = if (createDeploymentVm) {
  name: 'CleanUp-${deploymentSuffix}'
  scope: subscription(deploymentSubscription)
  params: {
    location: virtualMachinesRegion
    deploymentVirtualMachineName: createDeploymentVm ? deploymentPrereqs!.outputs.virtualMachineName : ''
    resourceGroupDeployment: resourceNames.outputs.resourceGroupDeployment
    resourceGroupHosts: resourceNames.outputs.resourceGroupHosts
    roleAssignmentIds: createDeploymentVm
      ? deploymentPrereqs!.outputs.deploymentUserAssignedIdentityRoleAssignmentIds
      : []
    deploymentSuffix: deploymentSuffix
    userAssignedIdentityClientId: createDeploymentVm
      ? deploymentPrereqs!.outputs.deploymentUserAssignedIdentityClientId
      : ''
    virtualMachineNames: sessionHosts.outputs.virtualMachineNames
  }
  dependsOn: [
    deploymentResourceGroup
  ]
}

// Outputs
output hostPoolResourceId string = deploymentType != 'SessionHostsOnly'
  ? controlPlane!.outputs.hostPoolResourceId
  : existingHostPoolResourceId
output workspaceResourceId string = empty(existingFeedWorkspaceResourceId)
  ? (deploymentType == 'Complete' ? controlPlane!.outputs.workspaceResourceId : '')
  : existingFeedWorkspaceResourceId
output fslogixLocalStorageAccountResourceIds array = deploymentType != 'SessionHostsOnly' && deployFSLogixStorage
  ? fslogix!.outputs.storageAccountResourceIds
  : fslogixExistingLocalStorageAccountResourceIds
output virtualMachineNames array = sessionHosts.outputs.virtualMachineNames
