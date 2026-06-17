targetScope = 'subscription'

// Deploys an Azure Virtual Desktop host pool including the AVD control plane (host pool, workspace, application groups),
// session host VMs, FSLogix storage, monitoring, private networking, and optional Customer Managed Key encryption.
// Subscription-scoped; creates and manages multiple resource groups for compute, storage, and operations resources.

// Basics

@maxLength(9)
@description('''Required. Short name identifying the host pool persona (e.g. "finance", "developers"). Max 9 characters.
Used as the primary component of all resource names in this deployment. Combined with the index parameter
(when provided) to form the base name for the host pool, desktop application group, session hosts, and all
associated resources.
''')
param identifier string

@description('''Optional. An index value used to distinquish each host pool with the same persona identifier.
This can be provided to shard the host pool across multiple groups for performance reasons or to uniquely define host pools under the same identifier.
Valid values are 0-99. If not provided, the host pool will be created without an index in the name.
''')
param index int = -1

@description('''Optional. Naming convention controlling how all resources in this deployment are named.
The default value produces Cloud Adoption Framework (CAF)-compliant names in the format: resourceType-workload-purpose-location.
All properties are optional when using the default convention; override only what needs to change.
Key properties:
  components          — ordered array of name segments, e.g. ["resourceType","workload","purpose","location"]
  delimiter           — separator between segments, e.g. "-"
  workload            — solution identifier inserted into names, e.g. "avd"
  freeform1           — static text slot before the workload
  environment         — environment token, e.g. "prod"
  freeform2           — static text slot after the environment
  vmsLocationAbbreviation  — override for the VMs region abbreviation
  cpLocationAbbreviation   — override for the control plane region abbreviation
  fslogixStoragePrefix     — custom prefix for FSLogix storage accounts (≤13 lowercase alphanumeric)
  resourceTypeCodes   — object with per-resource-type abbreviation overrides
This object is produced automatically when deploying via the Azure Portal UI.''')
param namingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

// Identity

@allowed([
  'ActiveDirectoryDomainServices' // User accounts are sourced from and Session Hosts are joined to same Active Directory domain.
  'EntraDomainServices' // User accounts are sourced from either Azure Active Directory or Active Directory Domain Services and Session Hosts are joined to Azure Active Directory Domain Services.
  'EntraKerberos-Hybrid' // User accounts are sourced from Active Directory and Session Hosts are joined to Entra Id.
  'EntraKerberos-CloudOnly' // User accounts and Session Hosts are located in Entra ID only. FSLogix uses Entra Kerberos for authentication. Supported in Azure Commercial and Azure US Government. Air-gapped cloud support is unknown.
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
param existingCredentialsKeyVaultResourceId string = ''

@description('Optional. The name of the domain that provides ADDS to the AVD session hosts and is synchronized with Azure AD')
param domainName string = ''

@description('Optional. The distinguished name for the target Organization Unit in Active Directory Domain Services.')
param vmOUPath string = ''

// Control Plane

@description('Optional. The deployment location for the AVD Control Plane resources. When not provided, defaults to the virtual machines region.')
param controlPlaneLocation string = ''

@description('Optional. The subscription Id where the AVD Control Plane resources are deployed. If not provided, the deployment subscription will be used.')
param controlPlaneSubscriptionId string = ''

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
param startVMOnConnect bool = true

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

@description('Optional. Determines whether or not to enable IPv6 for the session host VMs. This is an edge case scenario and is not recommended for most deployments. WARNING: Without specific route table entries configured for IPv6 traffic, outbound communication will not work properly.')
param enableIPv6 bool = false

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
-runAfterHostPoolJoin: (Optional, boolean, defaults to false) When true, the customization runs AFTER the host joins the AVD host pool. When false, it runs BEFORE joining the host pool.

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
  },
  {
    "name": "PostJoinConfig",
    "blobNameOrUri": "PostJoinConfig.ps1",
    "arguments": "-Environment Production",
    "runAfterHostPoolJoin": true
  }
]
''')
param sessionHostCustomizations array = []

@description('Optional. The URL to download the AVD Agent Boot Loader. If not provided, the URL is determined based on the cloud environment.')
param agentBootLoaderDownloadUrl string = ''

@description('Optional. The URL to download the AVD Agent. If not provided, the URL is determined based on the cloud environment.')
param agentDownloadUrl string = ''

// User Profiles

@description('Optional. Determines whether resources to support FSLogix profile storage are deployed.')
param deployFSLogixStorage bool = false

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

@allowed([
  'LocallyRedundant'
  'ZoneRedundant'
])
@description('Optional. Storage redundancy for newly created Azure Files accounts used by FSLogix. Independent from session host availability settings.')
param fslogixStorageRedundancy string = 'LocallyRedundant'

@description('Optional. Number of days to retain deleted FSLogix file shares (1–365). Applies to share-level soft delete — protects against accidental share deletion.')
@minValue(1)
@maxValue(365)
param fslogixSoftDeleteRetentionDays int = 14

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
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
@description('Optional. Key management mode for Azure Files (FSLogix) storage account encryption.')
param keyManagementStorage string = 'PlatformManaged'

@allowed([
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
@description('Optional. Key management mode for Recovery Services Vault encryption. When CustomerManaged is combined with deployPrivateEndpoints=true, the encryption Key Vault must have full public network access enabled (Azure Backup does not use the AzureServices trusted service bypass). Set encryptionKeyVaultForcePublicAccess=true to explicitly allow this — otherwise RSV CMK is automatically disabled.')
param keyManagementRecoveryServicesVault string = 'PlatformManaged'

@description('Optional. When true, the inline encryption Key Vault is deployed with public network access enabled and all IP-based firewall restrictions cleared. Required when keyManagementRecoveryServicesVault is CustomerManaged and deployPrivateEndpoints is true, because Azure Backup does not use the AzureServices trusted service bypass and its regional IPs are not fixed. Default false silently disables RSV CMK in that combination.')
param encryptionKeyVaultForcePublicAccess bool = false

@description('Optional. Array of permitted IP addresses or CIDR blocks allowed through the firewall of all PaaS components (storage accounts, Key Vaults). Use when managing the deployment from a trusted workstation outside the Azure network boundary.')
param permittedIPs array = []

@description('Optional. Enable VM backups via a Recovery Services Vault. Only applies to Personal host pools. For pooled host pools, Azure Files storage protection uses soft delete and snapshots configured directly on the storage accounts.')
param recoveryServices bool = false

@description('Optional. Storage redundancy for the Recovery Services vault. Controls how backup recovery points are stored — independently of the storage account redundancy.')
@allowed(['LocallyRedundant', 'ZoneRedundant', 'GeoRedundant'])
param recoveryServicesVaultStorageRedundancy string = 'LocallyRedundant'

@description('Optional. Number of daily recovery points or snapshots to retain (1–365). Used for VM backup on Personal host pools and Azure Files snapshot backup on pooled host pools — never both in the same deployment.')
@minValue(1)
@maxValue(365)
param backupRetentionDays int = 30

@description('Optional. Resource ID of an existing VM backup Recovery Services Vault. When provided with recoveryServices = true, uses this vault instead of creating a new one.')
param existingVmBackupVaultResourceId string = ''

@description('Optional. Resource ID of an existing Azure Files backup Recovery Services Vault (pooled host pools). When provided with recoveryServices = true and Azure Files storage, uses this vault instead of creating a new one.')
param existingFilesBackupVaultResourceId string = ''

@description('Optional. The resource ID of an existing Encryption Key Vault containing customer-managed keys. When provided, the deployment uses this vault for CMK instead of creating one inline.')
param existingEncryptionKeyVaultResourceId string = ''

@description('Optional. Deploys a Secrets Key Vault as part of this deployment to store session host credentials. When using an external Foundation deployment, leave this false and provide existingCredentialsKeyVaultResourceId instead.')
param deploySecretsKeyVault bool = false

@description('Optional. Enables soft delete on the inline-created Secrets Key Vault.')
param secretsKeyVaultEnableSoftDelete bool = true

@description('Optional. Enables purge protection on the inline-created Secrets Key Vault.')
param secretsKeyVaultEnablePurgeProtection bool = true

@description('Optional. The soft delete retention period in days for the inline-created Secrets Key Vault. Use 7 in test environments to minimise the wait before a deleted vault name can be reused; keep 90 in production.')
@minValue(7)
@maxValue(90)
param secretsKeyVaultRetentionInDays int = 90

@description('Optional. The soft delete retention period in days for the inline-created Encryption Key Vault. Use 7 in test environments to minimise the wait before a deleted vault name can be reused; keep 90 in production.')
@minValue(7)
@maxValue(90)
param encryptionKeyVaultRetentionInDays int = 90

// Monitoring

@description('Optional. Deploys the required monitoring resources to enable AVD Insights and monitor features in the automation account.')
param enableMonitoring bool = true

@description('Optional. The subscription Id where monitoring resources will be deployed. If not provided, the deployment subscription will be used.')
param monitoringSubscriptionId string = ''

@description('Optional. The resource Id of an existing Log Analytics Workspace. When provided and enableMonitoring is true, monitoring resources are not created inline — this workspace is used instead.')
param existingLogAnalyticsWorkspaceResourceId string = ''

@description('Optional. The resource Id of an existing AVD Insights Data Collection Rule. When provided and enableMonitoring is true, uses this DCR instead of creating one inline.')
param existingAVDInsightsDataCollectionRuleResourceId string = ''

@description('Optional. The resource Id of an existing Data Collection Endpoint. When provided and enableMonitoring is true, uses this endpoint instead of creating one inline.')
param existingDataCollectionEndpointResourceId string = ''

// Zero Trust

@description('Optional. Create private endpoints for all deployed management and storage resources where applicable.')
param deployPrivateEndpoints bool = false

@description('Conditional. The Resource Id of the subnet on which to create private endpoints for operations resources (Key Vaults, Recovery Services Vault). Required when "deployPrivateEndpoints" = true and any operations resource is deployed inline.')
param operationsPrivateEndpointSubnetResourceId string = ''

@description('Conditional. The Resource Id of the subnet on which to create the storage account and other resources private link. Required when "deployPrivateEndpoints" = true.')
param hostPoolResourcesPrivateEndpointSubnetResourceId string = ''

@description('Conditional. If using private endpoints with Azure files, input the Resource ID for the Private DNS Zone linked to your hub virtual network. Required when "deployPrivateEndpoints" is true.')
param azureBackupPrivateDnsZoneResourceId string = ''

@description('Conditional. If using private endpoints with Azure files, input the Resource ID for the Private DNS Zone linked to your hub virtual network. Required when "deployPrivateEndpoints" is true.')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Conditional. If using private endpoints with Azure files, input the Resource ID for the Private DNS Zone linked to your hub virtual network. Required when "deployPrivateEndpoints" is true.')
param azureFilesPrivateDnsZoneResourceId string = ''

@description('Conditional. The resource ID of the Azure Key Vault Private DNS Zone. Required when "deployPrivateEndpoints" is true and Key Vaults are deployed inline.')
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

var effectiveControlPlaneSubscription = empty(controlPlaneSubscriptionId)
  ? subscription().subscriptionId
  : controlPlaneSubscriptionId
var effectiveMonitoringSubscription = empty(monitoringSubscriptionId)
  ? subscription().subscriptionId
  : monitoringSubscriptionId

var rbacSubs = union([effectiveControlPlaneSubscription], [subscription().subscriptionId])

var globalFeedRegion = !empty(globalFeedPrivateEndpointSubnetResourceId)
  ? avdPrivateLinkGlobalFeedNetwork.?location
  : ''
var virtualMachinesRegion = vmVirtualNetwork.location
var effectiveControlPlaneRegion = empty(controlPlaneLocation) ? virtualMachinesRegion : controlPlaneLocation

var createDeploymentVm = deployFSLogixStorage || confidentialVMOSDiskEncryption || !empty(desktopFriendlyName)

// deployKeyVaults controls inline KV creation within this deployment.
//   (a) deploySecretsKeyVault = true: user explicitly requested a secrets KV deployed inline
//   (b) CMK is needed but no external encryptionKeyVaultResourceId was provided (e.g., portal all-in-one)
// When using the Foundation deployment, encryptionKeyVaultResourceId will be non-empty so deployInlineEncryptionKv stays false.
var cmkIsRequested = contains(keyManagementStorage, 'CustomerManaged') || contains(keyManagementRecoveryServicesVault, 'CustomerManaged') || contains(
  keyManagementDisks,
  'CustomerManaged'
) || confidentialVMOSDiskEncryption
var deployInlineEncryptionKv = empty(existingEncryptionKeyVaultResourceId) && cmkIsRequested
var deployKeyVaults = deploySecretsKeyVault || deployInlineEncryptionKv

// Top-level CMK: run keys + DES/UAI + role assignments early so RBAC propagation
// completes during the monitoring/controlPlane phases — well before VMs or storage deploy.
var deployDiskCmk = contains(keyManagementDisks, 'CustomerManaged') && !confidentialVMOSDiskEncryption && (deployInlineEncryptionKv || !empty(existingEncryptionKeyVaultResourceId))
var deployStorageCmk = deployFSLogixStorage && split(fslogixStorageService, ' ')[0] == 'AzureFiles' && keyManagementStorage != 'PlatformManaged' && (deployInlineEncryptionKv || !empty(existingEncryptionKeyVaultResourceId))
var deployRecoveryServicesAzureFiles = recoveryServices && !contains(hostPoolType, 'Personal') && deployFSLogixStorage && startsWith(fslogixStorageService, 'AzureFiles')
// CVM CMK: CVM keys must be created via Key Vault data plane (Run Command) because ARM key PUT
// does not support key release policies. The DES is then created by the shared CMK module with skipKeyCreation=true.
var deployCvmDiskCmk = confidentialVMOSDiskEncryption && (deployInlineEncryptionKv || !empty(existingEncryptionKeyVaultResourceId))

var deployDiskAccessResource = contains(hostPoolType, 'Personal') && recoveryServices && deployPrivateEndpoints

var effectiveDiskAccessId = deployDiskAccessResource ? diskAccess!.outputs.diskAccessId : ''

var hostPoolVmTemplate = {
  namePrefix: virtualMachineNamePrefix //1
  hibernate: hibernationEnabled // 2
  osDiskType: diskSku // 3
  diskSizeGB: diskSizeGB // 4
  securityType: securityType
  secureBoot: secureBootEnabled
  vTPM: vTpmEnabled
  vmInfrastructureType: 'Cloud'
  virtualProcessorCount: vCPUs == 0 ? null : vCPUs
  memoryGB: memoryGB == 0 ? null : memoryGB
  minimumMemoryGB: memoryGB == 0 ? null : memoryGB
  dynamicMemoryConfig: false
}

// Conditional Host Resource Group Tags

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

//  BATCH SESSION HOSTS
// The batching calculation is performed in the sessionHosts module to encapsulate deployment logic
//  BATCH AVAILABILITY SETS
// The following variables are used to determine the number of availability sets.
var maxAvSetMembers = 200 // This is the max number of session hosts that can be deployed in an availability set.
var beginAvSetRange = sessionHostIndex / maxAvSetMembers // This determines the availability set to start with.
var endAvSetRange = (sessionHostCount + sessionHostIndex) / maxAvSetMembers // This determines the availability set to end with.
var availabilitySetsCount = length(range(beginAvSetRange, (endAvSetRange - beginAvSetRange) + 1))

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
resource kvCredentials 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(existingCredentialsKeyVaultResourceId)) {
  name: last(split(existingCredentialsKeyVaultResourceId, '/'))
  scope: resourceGroup(split(existingCredentialsKeyVaultResourceId, '/')[2], split(existingCredentialsKeyVaultResourceId, '/')[4])
}

// Existing Encryption Key Vault — provided from Foundation deployment or pre-existing KV.
// Only referenced when encryptionKeyVaultResourceId is non-empty (not when inline creation is used).
resource kvEncryption 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(existingEncryptionKeyVaultResourceId)) {
  name: last(split(existingEncryptionKeyVaultResourceId, '/'))
  scope: resourceGroup(split(existingEncryptionKeyVaultResourceId, '/')[2], split(existingEncryptionKeyVaultResourceId, '/')[4])
}

// Deployments

var hpIndexString = index >= 0 ? format('{0:00}', index) : ''
var hpBaseName = empty(hpIndexString) ? toLower(identifier) : '${toLower(identifier)}-${hpIndexString}'

// ── Naming module ─────────────────────────────────────────────────────────────
// All resource names for this host pool are resolved by the naming module.
// References below use naming.outputs.<name> instead of local vars.
module naming './modules/naming.bicep' = {
  name: 'Naming-${deploymentSuffix}'
  scope: subscription()
  params: {
    namingConvention: namingConvention
    virtualMachinesRegion: virtualMachinesRegion
    controlPlaneRegion: effectiveControlPlaneRegion
    identifier: hpBaseName
    globalFeedRegion: globalFeedRegion
    existingFeedWorkspaceResourceId: existingFeedWorkspaceResourceId
  }
}

var fslogixShareNamesLookup = {
  CloudCacheProfileContainer: [
    'profile-containers'
  ]
  CloudCacheProfileOfficeContainer: [
    'profile-containers'
    'office-containers'
  ]
  ProfileContainer: [
    'profile-containers'
  ]
  ProfileOfficeContainer: [
    'profile-containers'
    'office-containers'
  ]
}

// ============================================================================
// Derived Variables
// All vars below depend on the naming convention block above.
// ============================================================================

// Resource Group ID tags — used on resources for cost management / chargeback
// Custom Tags for Host Pool
var hostsResourceGroupIdTag = {
  hostsResourceGroupId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${naming.outputs.resourceGroupHosts}'
}
var storageResourceGroupIdTag = deployFSLogixStorage
  ? {
      storageResourceGroupId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${naming.outputs.resourceGroupStorage}'
    }
  : {}

// Disk encryption set name — selects the right DES convention based on key management settings

// FSLogix storage configuration
var fslogixFileShareNames = fslogixShareNamesLookup[fslogixContainerType]
var fslogixStorageCount = identitySolution == 'EntraId' || fslogixShardOptions == 'None' ? 1 : length(fslogixUserGroups)

// NOTE: the name formula below must stay in sync with azureFiles.bicep: '${storageAccountNamePrefix}${padLeft(i + storageIndex, 2, '0')}'
var fslLocalStorageAccountNames = deployFSLogixStorage && startsWith(fslogixStorageService, 'AzureFiles')
  ? {
      fslLocalStorageAccountNames: string(map(
        range(0, fslogixStorageCount),
        i => '${naming.outputs.fslogixStorageAccountNamePrefix}${padLeft(i + fslogixStorageIndex, 2, '0')}'
      ))
    }
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
// NOTE: the resource ID path below must stay in sync with azureNetAppFiles.bicep scoped to naming.outputs.resourceGroupStorage.
var fslLocalNetAppVolumeResourceIds = deployFSLogixStorage && startsWith(fslogixStorageService, 'AzureNetAppFiles')
  ? {
      fslLocalNetAppVolumeResourceIds: string(map(
        fslogixShareNamesLookup[fslogixContainerType],
        share =>
          '/subscriptions/${subscription().subscriptionId}/resourceGroups/${naming.outputs.resourceGroupStorage}/providers/Microsoft.NetApp/netAppAccounts/${naming.outputs.netAppAccountName}/capacityPools/${naming.outputs.netAppCapacityPoolName}/volumes/${share}'
      ))
    }
  : !empty(fslogixExistingLocalNetAppVolumeResourceIds)
      ? { fslLocalNetAppVolumeResourceIds: string(fslogixExistingLocalNetAppVolumeResourceIds) }
      : {}
var fslRemoteNetAppVolumeResourceIds = !empty(fslogixExistingRemoteNetAppVolumeResourceIds)
  ? { fslRemoteNetAppVolumeResourceIds: string(fslogixExistingRemoteNetAppVolumeResourceIds) }
  : {}

// FSLogix configuration tags for hosts resource group.
// Applied whenever any storage is associated (deployed or existing) so that the hosts RG
// carries the configuration for future reference.
var hasAssociatedFslStorage = deployFSLogixStorage || !empty(fslogixExistingLocalStorageAccountResourceIds) || !empty(fslogixExistingLocalNetAppVolumeResourceIds)
var fslogixConfigurationTags = hasAssociatedFslStorage
  ? union(
      { fslContainerType: fslogixContainerType },
      { fslContainerSizeInMBs: fslogixSizeInMBs },
      { fslStorageService: split(fslogixStorageService, ' ')[0] },
      { fslFileShareNames: string(fslogixShareNamesLookup[fslogixContainerType]) },
      { fslSharding: fslogixShardOptions },
      fslLocalStorageAccountNames,
      fslRemoteStorageAccountNames,
      fslLocalNetAppVolumeResourceIds,
      fslRemoteNetAppVolumeResourceIds
    )
  : {}

// Disk encryption set name — selects the right DES convention based on key management settings
var diskEncryptionSetName = confidentialVMOSDiskEncryption
  ? naming.outputs.diskEncryptionSetNameConfidentialVMs
  : startsWith(keyManagementDisks, 'CustomerManaged')
      ? naming.outputs.diskEncryptionSetNameCustomerManaged
      : contains(keyManagementDisks, 'PlatformManagedAndCustomerManaged')
          ? naming.outputs.diskEncryptionSetNamePlatformAndCustomerManaged
          : null

// VM configuration tags — stamped on the hosts RG for operational reference
var vmIntuneEnrollment = contains(identitySolution, 'DomainServices') ? {} : { vmIntuneEnrollment: intuneEnrollment }
var vmDomain = contains(identitySolution, 'DomainServices') && !empty(domainName) ? { vmDomain: domainName } : {}
var vmOU = contains(identitySolution, 'DomainServices') && !empty(vmOUPath) ? { vmOUPath: vmOUPath } : {}
var vmCustomImageId = empty(customImageResourceId) ? {} : { vmCustomImageId: customImageResourceId }
var vmImageOffer = !empty(customImageResourceId) || empty(imageOffer) ? {} : { vmImageOffer: imageOffer }
var vmImagePublisher = !empty(customImageResourceId) || empty(imagePublisher)
  ? {}
  : { vmImagePublisher: imagePublisher }
var vmImageSku = !empty(customImageResourceId) || empty(imageSku) ? {} : { vmImageSku: imageSku }
var vmDiskEncryptionSetName = empty(diskEncryptionSetName) ? {} : { vmDiskEncryptionSetName: diskEncryptionSetName }

// VM configuration tags for hosts resource group
var vmConfigurationTags = union(
  {
    vmIdentityType: identitySolution
    vmNamePrefix: virtualMachineNamePrefix
    vmIndexPadding: vmNameIndexLength
    vmImageType: empty(customImageResourceId) ? 'Gallery' : 'CustomImage'
    vmOSDiskType: diskSku
    vmDiskSizeGB: diskSizeGB
    vmSize: virtualMachineSize
    vmAvailability: availability == 'AvailabilityZones'
      ? 'Availability Zones'
      : availability == 'AvailabilitySets' ? 'Availability Sets' : 'No infrastructure redundancy required'
    vmEncryptionAtHost: encryptionAtHost
    vmAcceleratedNetworking: enableAcceleratedNetworking
    vmIPv6: enableIPv6
    vmHibernate: hibernationEnabled
    vmSecurityType: securityType
    vmSecureBoot: secureBootEnabled
    vmVirtualTPM: vTpmEnabled
    vmIntegrityMonitoring: integrityMonitoring
    vmSubnetId: virtualMachineSubnetResourceId
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

// Resource Groups
module deploymentResourceGroup '../../.common/bicepModules/resources/resourceGroups/deploy.bicep' = if (createDeploymentVm) {
  name: 'Resource-Group-Deployment-${deploymentSuffix}'
  params: {
    location: virtualMachinesRegion
    name: naming.outputs.resourceGroupDeployment
    tags: union(tags[?'Microsoft.Resources/resourceGroups'] ?? {}, {
      'cm-resource-parent': '${subscription().id}/resourceGroups/${naming.outputs.resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostpools/${naming.outputs.hostPoolName}'
    })
  }
}

module monitoringResourceGroup '../../.common/bicepModules/resources/resourceGroups/deploy.bicep' = if (enableMonitoring && empty(existingLogAnalyticsWorkspaceResourceId)) {
  name: 'Resource-Group-Monitoring-${deploymentSuffix}'
  scope: subscription(effectiveMonitoringSubscription)
  params: {
    location: virtualMachinesRegion
    name: naming.outputs.resourceGroupMonitoring
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module controlPlaneResourceGroup '../../.common/bicepModules/resources/resourceGroups/deploy.bicep' = if (empty(existingFeedWorkspaceResourceId)) {
  name: 'Resource-Group-Control-Plane-${deploymentSuffix}'
  scope: subscription(effectiveControlPlaneSubscription)
  params: {
    location: effectiveControlPlaneRegion
    name: naming.outputs.resourceGroupControlPlane
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module globalFeedResourceGroup '../../.common/bicepModules/resources/resourceGroups/deploy.bicep' = if (avdPrivateLinkPrivateRoutes == 'All' && !empty(globalFeedPrivateEndpointSubnetResourceId) && empty(existingGlobalFeedResourceId)) {
  name: 'Resource-Group-Global-Feed-${deploymentSuffix}'
  scope: subscription(effectiveControlPlaneSubscription)
  params: {
    location: globalFeedRegion!
    name: naming.outputs.globalFeedResourceGroupName
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module hostsResourceGroup '../../.common/bicepModules/resources/resourceGroups/deploy.bicep' = {
  name: 'Resource-Group-Hosts-${deploymentSuffix}'
  params: {
    location: virtualMachinesRegion
    name: naming.outputs.resourceGroupHosts
    tags: union(tags[?'Microsoft.Resources/resourceGroups'] ?? {}, vmConfigurationTags, fslogixConfigurationTags, {
      'cm-resource-parent': '${subscription().id}/resourceGroups/${naming.outputs.resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostpools/${naming.outputs.hostPoolName}'
    })
  }
}

module operationsResourceGroup '../../.common/bicepModules/resources/resourceGroups/deploy.bicep' = if (deployKeyVaults || deployRecoveryServicesAzureFiles) {
  name: 'Resource-Group-Operations-${deploymentSuffix}'
  params: {
    location: virtualMachinesRegion
    name: naming.outputs.resourceGroupOperations
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

module storageResourceGroup '../../.common/bicepModules/resources/resourceGroups/deploy.bicep' = if (deployFSLogixStorage) {
  name: 'Resource-Group-FSLogix-Storage-${deploymentSuffix}'
  params: {
    location: virtualMachinesRegion
    name: naming.outputs.resourceGroupStorage
    tags: union(tags[?'Microsoft.Resources/resourceGroups'] ?? {}, {
      'cm-resource-parent': '${subscription().id}/resourceGroups/${naming.outputs.resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostpools/${naming.outputs.hostPoolName}'
    })
  }
}

// PowerOn/PowerOff/Restart VM Run Command permissions for AVD Service Principal
module avdServicePrincipalRbac 'modules/rbac/avdServicePrincipalRbac.bicep' = [
  for (subId, i) in rbacSubs: if (!empty(avdObjectId) && (deployScalingPlan || startVMOnConnect)) {
    name: 'Subscription-Role-Assignment-${i}-${deploymentSuffix}'
    scope: subscription(subId)
    params: {
      avdObjectId: avdObjectId
      deployScalingPlan: deployScalingPlan
      startVMOnConnect: startVMOnConnect
    }
  }
]

// VM User Login — required for Entra ID-joined session hosts so users can sign in
module roleAssignment_VirtualMachineUserLogin 'modules/rbac/vmUserLoginAssignments.bicep' = if (!contains(identitySolution, 'DomainServices')) {
  name: 'RA-Hosts-VMLoginUser-${deploymentSuffix}'
  params: {
    resourceGroupHosts: naming.outputs.resourceGroupHosts
    appGroupSecurityGroups: map(appGroupSecurityGroups, group => group.id)
    deploymentSuffix: deploymentSuffix
  }
  dependsOn: [
    hostsResourceGroup
  ]
}

// Deployment VM for Prerequisites
module deploymentPrereqs 'modules/deployment/deployment.bicep' = if (createDeploymentVm) {
  name: 'Deployment-Prereqs-${deploymentSuffix}'
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
          : !empty(existingCredentialsKeyVaultResourceId) ? kvCredentials!.getSecret('DomainJoinUserPassword') : ''
      : ''
    #disable-next-line BCP422
    domainJoinUserPrincipalName: contains(identitySolution, 'DomainServices') || identitySolution == 'EntraKerberos-Hybrid'
      ? !empty(domainJoinUserPrincipalName)
          ? domainJoinUserPrincipalName
          : !empty(existingCredentialsKeyVaultResourceId) ? kvCredentials!.getSecret('DomainJoinUserPrincipalName') : ''
      : ''
    domainName: domainName
    encryptionAtHost: encryptionAtHost
    fslogix: deployFSLogixStorage
    fslogixAppUpdateUserAssignedIdentityResourceId: fslogixAppUpdateUserAssignedIdentityResourceId
    hostPoolName: naming.outputs.hostPoolName
    identitySolution: identitySolution
    keyManagementDisks: keyManagementDisks
    keyManagementStorageAccounts: keyManagementStorage
    location: virtualMachinesRegion
    ouPath: vmOUPath
    resourceGroupControlPlane: naming.outputs.resourceGroupControlPlane
    resourceGroupDeployment: naming.outputs.resourceGroupDeployment
    resourceGroupHosts: naming.outputs.resourceGroupHosts
    // When an existing KV is provided it lives in a pre-existing RG; use that RG for the
    // KeyVaultCryptoOfficer / RBACAdmin role assignments instead of the calculated operations
    // RG name, which may not exist if no inline KV or Recovery Services vault is being deployed.
    resourceGroupSecurity: !empty(existingEncryptionKeyVaultResourceId)
      ? split(existingEncryptionKeyVaultResourceId, '/')[4]
      : naming.outputs.resourceGroupOperations
    resourceGroupStorage: naming.outputs.resourceGroupStorage
    tags: tags
    userAssignedIdentityNameConv: naming.outputs.userAssignedIdentityNameConv
    #disable-next-line BCP422
    virtualMachineAdminPassword: !empty(existingCredentialsKeyVaultResourceId)
      ? kvCredentials!.getSecret('VirtualMachineAdminPassword')
      : virtualMachineAdminPassword
    #disable-next-line BCP422
    virtualMachineAdminUserName: !empty(existingCredentialsKeyVaultResourceId)
      ? kvCredentials!.getSecret('VirtualMachineAdminUserName')
      : virtualMachineAdminUserName
    virtualMachineName: naming.outputs.depVirtualMachineName
    virtualMachineNICName: naming.outputs.depVirtualMachineNicName
    virtualMachineDiskName: naming.outputs.depVirtualMachineDiskName
    virtualMachineSubnetResourceId: virtualMachineSubnetResourceId
  }
  dependsOn: [
    deploymentResourceGroup
  ]
}

// KeyVaults: Inline Key Vault creation — only runs when Security KVs were not provided.
// For all-in-one portal deployments: deploys encryption KV when CMK is requested, secrets KV when deploySecretsKeyVault=true.
// For Security-first deployments: skipped entirely because encryptionKeyVaultResourceId will be non-empty.
module keyVaults '../../.common/bicepModules/custom/keyVaults/keyVaults.bicep' = if (deployKeyVaults) {
  name: 'KeyVaults-${deploymentSuffix}'
  params: {
    azureKeyVaultPrivateDnsZoneResourceId: azureKeyVaultPrivateDnsZoneResourceId
    deploymentSuffix: deploymentSuffix
    encryptionKeyVaultName: naming.outputs.keyVaultNameEncryption
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    deployEncryptionKeyVault: deployInlineEncryptionKv
    deploySecretsKeyVault: deploySecretsKeyVault
    secretsKeyVaultEnablePurgeProtection: secretsKeyVaultEnablePurgeProtection
    secretsKeyVaultEnableSoftDelete: secretsKeyVaultEnableSoftDelete
    secretsKeyVaultName: naming.outputs.keyVaultNameSecrets
    secretsKeyVaultRetentionInDays: secretsKeyVaultRetentionInDays
    encryptionKeyVaultRetentionInDays: encryptionKeyVaultRetentionInDays
    logAnalyticsWorkspaceResourceId: enableMonitoring
      ? (empty(existingLogAnalyticsWorkspaceResourceId)
          ? monitoring!.outputs.logAnalyticsWorkspaceResourceId
          : existingLogAnalyticsWorkspaceResourceId)
      : ''
    privateEndpointSubnetResourceId: operationsPrivateEndpointSubnetResourceId
    privateEndpoint: deployPrivateEndpoints
    encryptionKeyVaultForcePublicAccess: encryptionKeyVaultForcePublicAccess
    permittedIPs: permittedIPs
    privateEndpointNameConv: naming.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: naming.outputs.privateEndpointNICNameConv
    resourceGroupName: naming.outputs.resourceGroupOperations
    tags: tags
    virtualMachineAdminPassword: virtualMachineAdminPassword
    virtualMachineAdminUserName: virtualMachineAdminUserName
  }
  dependsOn: [
    operationsResourceGroup
  ]
}

// Effective encryption KV resource ID: prefer the externally-provided value (from Foundation or existing KV),
// fall back to the inline-created one if the management module ran.
var effectiveEncryptionKeyVaultResourceId = !empty(existingEncryptionKeyVaultResourceId)
  ? existingEncryptionKeyVaultResourceId
  : (deployInlineEncryptionKv ? keyVaults!.outputs.encryptionKeyVaultResourceId : '')
#disable-next-line BCP318
var effectiveEncryptionKeyVaultUri = !empty(existingEncryptionKeyVaultResourceId)
  ? kvEncryption!.properties.vaultUri
  : (deployInlineEncryptionKv ? keyVaults!.outputs.encryptionKeyVaultUri : '')

// Disk CMK: DES + key + role assignment — runs in parallel with monitoring/controlPlane,
// giving sufficient RBAC propagation buffer before sessionHosts needs the DES.
// Confidential VM disk encryption is handled separately by cvmDiskCmk below.
module diskCmk 'modules/cmk/diskCmk.bicep' = if (deployDiskCmk) {
  name: 'Disk-CMK-${deploymentSuffix}'
  params: {
    resourceGroupName: naming.outputs.resourceGroupHosts
    keyVaultResourceId: effectiveEncryptionKeyVaultResourceId
    keyManagementType: contains(keyManagementDisks, 'HSM')
      ? (contains(keyManagementDisks, 'Platform') ? 'PlatformManagedAndCustomerManagedHSM' : 'CustomerManagedHSM')
      : (contains(keyManagementDisks, 'Platform') ? 'PlatformManagedAndCustomerManaged' : 'CustomerManaged')
    keyExpirationInDays: keyExpirationInDays
    location: virtualMachinesRegion
    tags: tags
    deploymentSuffix: deploymentSuffix
    keyName: naming.outputs.encryptionKeyNameVMs
    diskEncryptionSetName: !contains(keyManagementDisks, 'Platform')
      ? naming.outputs.diskEncryptionSetNameCustomerManaged
      : naming.outputs.diskEncryptionSetNamePlatformAndCustomerManaged
  }
  dependsOn: [
    hostsResourceGroup
  ]
}

// CVM CMK: two-step flow — Run Command creates the key with a release policy (Key Vault data plane),
// then the shared CMK module creates the DES + role assignments (ARM, skipKeyCreation=true).
// Must run after deploymentPrereqs so the deployment VM and its Key Vault Crypto Officer role
// assignment are in place before the Run Command executes.
module cvmDiskCmk 'modules/cmk/cvmDiskCmk.bicep' = if (deployCvmDiskCmk) {
  name: 'CVM-Disk-CMK-${deploymentSuffix}'
  params: {
    resourceGroupHosts: naming.outputs.resourceGroupHosts
    resourceGroupDeployment: naming.outputs.resourceGroupDeployment
    keyVaultResourceId: effectiveEncryptionKeyVaultResourceId
    keyVaultUri: effectiveEncryptionKeyVaultUri
    keyName: naming.outputs.encryptionKeyNameConfidentialVMs
    diskEncryptionSetName: naming.outputs.diskEncryptionSetNameConfidentialVMs
    confidentialVMOrchestratorObjectId: confidentialVMOrchestratorObjectId
    deploymentVirtualMachineName: deploymentPrereqs!.outputs.virtualMachineName
    deploymentUserAssignedIdentityClientId: deploymentPrereqs!.outputs.deploymentUserAssignedIdentityClientId
    location: virtualMachinesRegion
    tags: tags
    hostPoolResourceId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${naming.outputs.resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostPools/${naming.outputs.hostPoolName}'
    deploymentSuffix: deploymentSuffix
  }
  dependsOn: [
    hostsResourceGroup
  ]
}

// Effective DES resource ID: inline disk CMK or CVM CMK output, or empty when platform-managed.
var effectiveDiskEncryptionSetResourceId = deployDiskCmk
  ? diskCmk!.outputs.diskEncryptionSetResourceId
  : deployCvmDiskCmk ? cvmDiskCmk!.outputs.diskEncryptionSetResourceId : ''

// Storage CMK: UAI + keys + role assignments for FSLogix AzureFiles storage accounts.
// Runs in parallel with monitoring/controlPlane so role assignments propagate before azureFiles deploys.
module storageCmk 'modules/cmk/storageCmk.bicep' = if (deployStorageCmk) {
  name: 'Storage-CMK-${deploymentSuffix}'
  params: {
    resourceGroupName: naming.outputs.resourceGroupStorage
    keyVaultResourceId: effectiveEncryptionKeyVaultResourceId
    keyManagementType: contains(keyManagementStorage, 'HSM') ? 'CustomerManagedHSM' : 'CustomerManaged'
    keyExpirationInDays: keyExpirationInDays
    location: virtualMachinesRegion
    tags: tags
    deploymentSuffix: deploymentSuffix
    storageKeyNames: [
      for i in range(0, fslogixStorageCount): replace(naming.outputs.encryptionKeyNameFSLogix, '##', padLeft(i + fslogixStorageIndex, 2, '0'))
    ]
    identityName: replace(naming.outputs.userAssignedIdentityNameConv, 'TOKEN', 'storage-encryption')
  }
  dependsOn: [
    storageResourceGroup
  ]
}

// Monitoring: Log Analytics Workspace, Data Collection Endpoint, Data Collection Rules, Automation Account
module monitoring 'modules/monitoring/monitoring.bicep' = if (enableMonitoring && empty(existingLogAnalyticsWorkspaceResourceId)) {
  name: 'Monitoring-${deploymentSuffix}'
  scope: subscription(effectiveMonitoringSubscription)
  params: {
    azureMonitorPrivateLinkScopeResourceId: azureMonitorPrivateLinkScopeResourceId
    dataCollectionEndpointName: naming.outputs.dataCollectionEndpointName
    deploymentSuffix: deploymentSuffix
    location: virtualMachinesRegion
    logAnalyticsWorkspaceName: naming.outputs.logAnalyticsWorkspaceName
    resourceGroupMonitoring: naming.outputs.resourceGroupMonitoring
    tags: tags
  }
  dependsOn: [
    monitoringResourceGroup
  ]
}

// AVD Control Plane Resources: workspace, host pool, and desktop application group
module controlPlane 'modules/controlPlane/controlPlane.bicep' = {
  name: 'ControlPlane-${deploymentSuffix}'
  scope: subscription(effectiveControlPlaneSubscription)
  params: {
    appGroupSecurityGroups: map(appGroupSecurityGroups, group => group.id)
    avdPrivateDnsZoneResourceId: avdPrivateDnsZoneResourceId
    avdPrivateLinkPrivateRoutes: avdPrivateLinkPrivateRoutes
    controlPlaneRegion: effectiveControlPlaneRegion
    deployScalingPlan: deployScalingPlan
    deploymentSuffix: deploymentSuffix
    deploymentUserAssignedIdentityClientId: createDeploymentVm
      ? deploymentPrereqs!.outputs.deploymentUserAssignedIdentityClientId
      : ''
    deploymentVirtualMachineName: createDeploymentVm ? deploymentPrereqs!.outputs.virtualMachineName : ''
    desktopApplicationGroupName: naming.outputs.desktopApplicationGroupName
    desktopFriendlyName: desktopFriendlyName
    enableMonitoring: enableMonitoring
    existingFeedWorkspaceResourceId: existingFeedWorkspaceResourceId
    existingGlobalWorkspaceResourceId: existingGlobalFeedResourceId
    globalFeedPrivateDnsZoneResourceId: globalFeedPrivateDnsZoneResourceId
    globalFeedPrivateEndpointSubnetResourceId: globalFeedPrivateEndpointSubnetResourceId
    globalFeedRegion: globalFeedRegion!
    globalWorkspaceName: naming.outputs.globalFeedWorkspaceName
    hostPoolCustomTags: union(hostsResourceGroupIdTag, storageResourceGroupIdTag)
    hostPoolMaxSessionLimit: hostPoolMaxSessionLimit
    hostPoolName: naming.outputs.hostPoolName
    hostPoolPrivateEndpointSubnetResourceId: hostpoolPrivateEndpointSubnetResourceId
    hostPoolPublicNetworkAccess: hostPoolPublicNetworkAccess
    hostPoolRDPProperties: hostPoolRDPProperties
    hostPoolType: hostPoolType
    hostPoolValidationEnvironment: hostPoolValidationEnvironment
    hostPoolVmTemplate: hostPoolVmTemplate
    virtualMachinesRegion: virtualMachinesRegion
    logAnalyticsWorkspaceResourceId: enableMonitoring
      ? (empty(existingLogAnalyticsWorkspaceResourceId)
          ? monitoring!.outputs.logAnalyticsWorkspaceResourceId
          : existingLogAnalyticsWorkspaceResourceId)
      : ''
    privateEndpointNameConv: naming.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: naming.outputs.privateEndpointNICNameConv
    resourceGroupControlPlane: naming.outputs.resourceGroupControlPlane
    resourceGroupGlobalFeed: naming.outputs.globalFeedResourceGroupName
    resourceGroupDeployment: naming.outputs.resourceGroupDeployment
    scalingPlanName: naming.outputs.scalingPlanName
    scalingPlanSchedules: scalingPlanSchedules
    scalingPlanExclusionTag: scalingPlanExclusionTag
    startVMOnConnect: startVMOnConnect
    tags: tags
    virtualMachinesTimeZone: virtualMachinesTimeZone
    workspaceFeedPrivateEndpointSubnetResourceId: workspaceFeedPrivateEndpointSubnetResourceId
    workspaceFriendlyName: workspaceFriendlyName
    workspaceName: naming.outputs.workspaceName
    workspacePublicNetworkAccess: workspaceFeedPublicNetworkAccess
  }
  dependsOn: [
    controlPlaneResourceGroup
  ]
}

// VM Recovery Services: vault deployment is handled inside modules/hosts/hosts.bicep.
var deployRecoveryServices = recoveryServices && contains(hostPoolType, 'Personal')

var recoveryServicesFileSharePolicyName = 'filesharepolicy'

// Azure Files Recovery Services Vault — shared vault in the Operations RG for pooled host pool FSLogix snapshot backup.
// No CMK required: vault holds only metadata; snapshot data stays in the storage account.
module recoveryServicesAzureFilesModule 'modules/operations/recoveryServices.bicep' = if (deployRecoveryServicesAzureFiles) {
  name: 'RecoveryServices-AzureFiles-${deploymentSuffix}'
  params: {
    createVault: empty(existingFilesBackupVaultResourceId)
    existingRecoveryServicesVaultResourceId: existingFilesBackupVaultResourceId
    vaultName: naming.outputs.recoveryServicesVaultNameFSLogix
    resourceGroupOperations: naming.outputs.resourceGroupOperations
    location: virtualMachinesRegion
    deploymentSuffix: deploymentSuffix
    logAnalyticsWorkspaceResourceId: enableMonitoring
      ? (empty(existingLogAnalyticsWorkspaceResourceId)
          ? monitoring!.outputs.logAnalyticsWorkspaceResourceId
          : existingLogAnalyticsWorkspaceResourceId)
      : ''
    privateEndpoint: deployPrivateEndpoints
    privateEndpointSubnetResourceId: operationsPrivateEndpointSubnetResourceId
    azureBackupPrivateDnsZoneResourceId: azureBackupPrivateDnsZoneResourceId
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    privateEndpointNameConv: naming.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: naming.outputs.privateEndpointNICNameConv
    tags: tags
    timeZone: virtualMachinesTimeZone
    fileSharePolicyName: recoveryServicesFileSharePolicyName
    backupRetentionDays: backupRetentionDays
  }
  dependsOn: [
    operationsResourceGroup
  ]
}

var effectiveFilesBackupVaultResourceId = deployRecoveryServicesAzureFiles
  ? (empty(existingFilesBackupVaultResourceId)
      ? recoveryServicesAzureFilesModule!.outputs.recoveryServicesVaultResourceId
      : existingFilesBackupVaultResourceId)
  : ''

// FSLogix Storage
module fslogix 'modules/fslogix-storage/fslogix.bicep' = if (deployFSLogixStorage && split(hostPoolType, ' ')[0] == 'Pooled') {
  name: 'FSLogix-${deploymentSuffix}'
  params: {
    activeDirectoryConnection: existingSharedActiveDirectoryConnection
    appUpdateUserAssignedIdentityResourceId: fslogixAppUpdateUserAssignedIdentityResourceId
    azureFilePrivateDnsZoneResourceId: azureFilesPrivateDnsZoneResourceId
    deploymentUserAssignedIdentityClientId: createDeploymentVm
      ? deploymentPrereqs!.outputs.deploymentUserAssignedIdentityClientId
      : ''
    deploymentVirtualMachineName: createDeploymentVm ? deploymentPrereqs!.outputs.virtualMachineName : ''
    #disable-next-line BCP422
    domainJoinUserPassword: contains(identitySolution, 'DomainServices') || identitySolution == 'EntraKerberos-Hybrid'
      ? !empty(domainJoinUserPassword)
          ? domainJoinUserPassword
          : !empty(existingCredentialsKeyVaultResourceId) ? kvCredentials!.getSecret('DomainJoinUserPassword') : ''
      : ''
    #disable-next-line BCP422
    domainJoinUserPrincipalName: contains(identitySolution, 'DomainServices') || identitySolution == 'EntraKerberos-Hybrid'
      ? !empty(domainJoinUserPrincipalName)
          ? domainJoinUserPrincipalName
          : !empty(existingCredentialsKeyVaultResourceId) ? kvCredentials!.getSecret('DomainJoinUserPrincipalName') : ''
      : ''
    domainName: domainName
    encryptionKeyVaultUri: effectiveEncryptionKeyVaultUri
    fslogixAdminGroups: fslogixAdminGroups
    fslogixEncryptionKeyNameConv: naming.outputs.encryptionKeyNameFSLogix
    fslogixFileShares: fslogixFileShareNames
    fslogixShardOptions: fslogixShardOptions
    fslogixUserGroups: fslogixUserGroups
    hostPoolResourceId: controlPlane!.outputs.hostPoolResourceId
    identitySolution: identitySolution
    kerberosEncryptionType: fslogixStorageKerberosEncryptionType
    keyManagementStorageAccounts: keyManagementStorage
    location: virtualMachinesRegion
    logAnalyticsWorkspaceResourceId: enableMonitoring
      ? (empty(existingLogAnalyticsWorkspaceResourceId)
          ? monitoring!.outputs.logAnalyticsWorkspaceResourceId
          : existingLogAnalyticsWorkspaceResourceId)
      : ''
    netAppVolumesSubnetResourceId: netAppVolumesSubnetResourceId
    netAppAccountName: naming.outputs.netAppAccountName
    netAppCapacityPoolName: naming.outputs.netAppCapacityPoolName
    ouPath: empty(fslogixOUPath) ? vmOUPath : fslogixOUPath
    privateEndpoint: deployPrivateEndpoints
    privateEndpointNameConv: naming.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: naming.outputs.privateEndpointNICNameConv
    privateEndpointSubnetResourceId: hostPoolResourcesPrivateEndpointSubnetResourceId
    resourceGroupDeployment: naming.outputs.resourceGroupDeployment
    resourceGroupStorage: naming.outputs.resourceGroupStorage
    shareSizeInGB: fslogixShareSizeInGB
    smbServerLocation: naming.outputs.vmsLocAbbr
    storageAccountNamePrefix: naming.outputs.fslogixStorageAccountNamePrefix
    storageCount: fslogixStorageCount
    storageIndex: fslogixStorageIndex
    storageSku: fslogixStorageService == 'None' ? 'None' : split(fslogixStorageService, ' ')[1]
    fslogixStorageRedundancy: fslogixStorageRedundancy
    storageSolution: split(fslogixStorageService, ' ')[0]
    permittedIPs: permittedIPs
    tags: tags
    deploymentSuffix: deploymentSuffix
    encryptionUserAssignedIdentityResourceId: deployStorageCmk ? storageCmk!.outputs.storageEncryptionIdentityResourceId : ''
    fslogixSoftDeleteRetentionDays: fslogixSoftDeleteRetentionDays
    recoveryServicesVaultResourceId: deployRecoveryServicesAzureFiles ? effectiveFilesBackupVaultResourceId : ''
    fileSharePolicyName: recoveryServicesFileSharePolicyName
  }
  dependsOn: [
    storageResourceGroup
  ]
}

// Session Hosts
module diskAccess 'modules/hosts/modules/diskAccess.bicep' = if (deployDiskAccessResource) {
  name: 'DiskAccess-${deploymentSuffix}'
  params: {
    resourceGroupHosts: naming.outputs.resourceGroupHosts
    diskAccessName: naming.outputs.diskAccessName
    location: virtualMachinesRegion
    hostPoolResourceId: controlPlane!.outputs.hostPoolResourceId
    deploymentSuffix: deploymentSuffix
    tags: tags
    deployPrivateEndpoint: deployPrivateEndpoints
    privateEndpointSubnetResourceId: hostPoolResourcesPrivateEndpointSubnetResourceId
    privateEndpointNameConv: naming.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: naming.outputs.privateEndpointNICNameConv
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
  }
}

module diskAccessPolicy 'modules/hosts/modules/diskNetworkAccessPolicy.bicep' = if (deployDiskAccessPolicy) {
  name: 'ManagedDisks-NetworkAccess-Policy-${deploymentSuffix}'
  params: {
    diskAccessId: deployDiskAccessResource ? diskAccess!.outputs.diskAccessId : ''
    location: virtualMachinesRegion
    resourceGroupName: naming.outputs.resourceGroupHosts
  }
}

module sessionHosts 'modules/hosts/hosts.bicep' = {
  name: 'Hosts-${deploymentSuffix}'
  params: {
    resourceGroupHosts: naming.outputs.resourceGroupHosts
    agentBootLoaderDownloadUrl: agentBootLoaderDownloadUrl
    agentDownloadUrl: agentDownloadUrl
    artifactsContainerUri: artifactsContainerUri
    artifactsUserAssignedIdentityResourceId: artifactsUserAssignedIdentityResourceId
    avdInsightsDataCollectionRulesResourceId: enableMonitoring
      ? (empty(existingAVDInsightsDataCollectionRuleResourceId)
          ? monitoring!.outputs.avdInsightsDataCollectionRulesResourceId
          : existingAVDInsightsDataCollectionRuleResourceId)
      : ''
    availability: availability
    availabilitySetNameConv: naming.outputs.availabilitySetNameConv
    availabilitySetsCount: availabilitySetsCount
    availabilitySetsIndex: beginAvSetRange
    availabilityZones: availabilityZones
    confidentialVMOSDiskEncryption: confidentialVMOSDiskEncryption
    customImageResourceId: customImageResourceId
    dataCollectionEndpointResourceId: enableMonitoring
      ? (empty(existingDataCollectionEndpointResourceId)
          ? monitoring!.outputs.dataCollectionEndpointResourceId
          : existingDataCollectionEndpointResourceId)
      : ''
    dedicatedHostGroupResourceId: dedicatedHostGroupResourceId
    dedicatedHostResourceId: dedicatedHostResourceId
    diskAccessId: effectiveDiskAccessId
    diskSizeGB: diskSizeGB
    diskSku: diskSku
    #disable-next-line BCP422
    domainJoinUserPassword: contains(identitySolution, 'DomainServices')
      ? !empty(domainJoinUserPassword)
          ? domainJoinUserPassword
          : !empty(existingCredentialsKeyVaultResourceId) ? kvCredentials!.getSecret('DomainJoinUserPassword') : ''
      : ''
    #disable-next-line BCP422
    domainJoinUserPrincipalName: contains(identitySolution, 'DomainServices')
      ? !empty(domainJoinUserPrincipalName)
          ? domainJoinUserPrincipalName
          : !empty(existingCredentialsKeyVaultResourceId) ? kvCredentials!.getSecret('DomainJoinUserPrincipalName') : ''
      : ''
    domainName: domainName
    enableAcceleratedNetworking: enableAcceleratedNetworking
    enableIPv6: enableIPv6
    enableMonitoring: enableMonitoring
    encryptionAtHost: encryptionAtHost
    diskEncryptionSetResourceId: effectiveDiskEncryptionSetResourceId
    fslogixConfigureSessionHosts: fslogixConfigureSessionHosts
    fslogixContainerType: fslogixContainerType
    fslogixFileShareNames: fslogixFileShareNames
    fslogixLocalStorageAccountResourceIds: deployFSLogixStorage
      ? fslogix!.outputs.storageAccountResourceIds
      : fslogixExistingLocalStorageAccountResourceIds
    fslogixLocalNetAppVolumeResourceIds: deployFSLogixStorage
      ? fslogix!.outputs.netAppVolumeResourceIds
      : fslogixExistingLocalNetAppVolumeResourceIds
    fslogixOSSGroups: fslogixShardOptions == 'ShardOSS' ? map(fslogixUserGroups, group => group.name) : []
    fslogixRemoteNetAppVolumeResourceIds: fslogixExistingRemoteNetAppVolumeResourceIds
    fslogixRemoteStorageAccountResourceIds: fslogixExistingRemoteStorageAccountResourceIds
    fslogixSizeInMBs: fslogixSizeInMBs
    fslogixStorageService: split(fslogixStorageService, ' ')[0]
    hibernationEnabled: hibernationEnabled
    hostPoolResourceId: controlPlane!.outputs.hostPoolResourceId
    identitySolution: identitySolution
    imageOffer: imageOffer
    imagePublisher: imagePublisher
    imageSku: imageSku
    integrityMonitoring: integrityMonitoring
    intuneEnrollment: intuneEnrollment
    location: virtualMachinesRegion
    osDiskNameConv: naming.outputs.diskNameConv
    ouPath: vmOUPath
    networkInterfaceNameConv: naming.outputs.networkInterfaceNameConv
    securityType: securityType
    secureBootEnabled: secureBootEnabled
    sessionHostCount: sessionHostCount
    sessionHostCustomizations: sessionHostCustomizations
    sessionHostIndex: sessionHostIndex
    vmNameIndexLength: vmNameIndexLength
    subnetResourceId: virtualMachineSubnetResourceId
    tags: hostTags
    deploymentSuffix: deploymentSuffix
    timeZone: virtualMachinesTimeZone
    #disable-next-line BCP422
    virtualMachineAdminPassword: !empty(existingCredentialsKeyVaultResourceId)
      ? kvCredentials!.getSecret('VirtualMachineAdminPassword')
      : virtualMachineAdminPassword
    #disable-next-line BCP422
    virtualMachineAdminUserName: !empty(existingCredentialsKeyVaultResourceId)
      ? kvCredentials!.getSecret('VirtualMachineAdminUserName')
      : virtualMachineAdminUserName
    virtualMachineNameConv: naming.outputs.virtualMachineNameConv
    virtualMachineNamePrefix: virtualMachineNamePrefix
    virtualMachineSize: virtualMachineSize
    vTpmEnabled: vTpmEnabled
    // VM backup — vault is deployed inside hosts.bicep when deployRecoveryServices is true.
    deployRecoveryServices: deployRecoveryServices
    createVault: empty(existingVmBackupVaultResourceId)
    existingVmBackupVaultResourceId: existingVmBackupVaultResourceId
    vaultName: naming.outputs.recoveryServicesVaultNameVMs
    vaultStorageRedundancy: recoveryServicesVaultStorageRedundancy
    backupRetentionDays: backupRetentionDays
    keyManagementType: keyManagementRecoveryServicesVault
    keyExpirationInDays: keyExpirationInDays
    encryptionKeyVaultResourceId: effectiveEncryptionKeyVaultResourceId
    encryptionKeyVaultUri: effectiveEncryptionKeyVaultUri
    encryptionKeyName: naming.outputs.encryptionKeyNameRecoveryServices
    keyVaultPrivateOnly: deployPrivateEndpoints && !encryptionKeyVaultForcePublicAccess
    deployPrivateEndpoints: deployPrivateEndpoints
    vaultPrivateEndpointSubnetResourceId: hostPoolResourcesPrivateEndpointSubnetResourceId
    azureBackupPrivateDnsZoneResourceId: azureBackupPrivateDnsZoneResourceId
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    privateEndpointNameConv: naming.outputs.privateEndpointNameConv
    privateEndpointNICNameConv: naming.outputs.privateEndpointNICNameConv
    logAnalyticsWorkspaceResourceId: enableMonitoring
      ? (empty(existingLogAnalyticsWorkspaceResourceId)
          ? monitoring!.outputs.logAnalyticsWorkspaceResourceId
          : existingLogAnalyticsWorkspaceResourceId)
      : ''
  }
  dependsOn: [
    hostsResourceGroup
  ]
}

// Clean Up Deployment VM and Role Assignments
module cleanUp 'modules/cleanUp/cleanUp.bicep' = if (createDeploymentVm) {
  name: 'CleanUp-${deploymentSuffix}'
  params: {
    location: virtualMachinesRegion
    deploymentVirtualMachineName: createDeploymentVm ? deploymentPrereqs!.outputs.virtualMachineName : ''
    resourceGroupDeployment: naming.outputs.resourceGroupDeployment
    resourceGroupHosts: naming.outputs.resourceGroupHosts
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
output hostPoolResourceId string = controlPlane!.outputs.hostPoolResourceId
output workspaceResourceId string = empty(existingFeedWorkspaceResourceId)
  ? controlPlane!.outputs.workspaceResourceId
  : existingFeedWorkspaceResourceId
output fslogixLocalStorageAccountResourceIds array = deployFSLogixStorage
  ? fslogix!.outputs.storageAccountResourceIds
  : fslogixExistingLocalStorageAccountResourceIds
output hostResouceGroupId string = hostsResourceGroup!.outputs.resourceId
output virtualMachineNames array = sessionHosts.outputs.virtualMachineNames
