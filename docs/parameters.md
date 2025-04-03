[**Home**](../README.md) | [**Design**](design.md) | [**Features**](features.md) | [**Get Started**](quickStart.md) | [**Troubleshooting**](troubleshooting.md) | [**Scope**](scope.md) | [**Zero Trust Framework**](zeroTrustFramework.md)

# Parameters

## AVD Host Pool Deployment Parameters

### Required Parameters

| Parameter | Description | Type | Allowed | Default |
| --------- | ----------- | :--: | :-----: | ------- |

| `identitySolution` | The service providing domain services for Azure Virtual Desktop.  This is needed to properly configure the session hosts and if applicable, the Azure Storage Account. | string | 'ActiveDirectoryDomainServices'<br/>'EntraDomainServices'<br/>'EntraId'<br/>'EntraIdIntuneEnrollment' | |
| `virtualMachineNamePrefix` | The prefix of the virtual machine name. Virtual Machines are named based on the prefix with the 3 character index incremented at the end (i.e., prefix001, prefix002, etc.) | string | 2 - 12 characters | |
| `virtualMachineSubnetResourceId` | The resource Id of the subnet onto which the Virtual Machines will be deployed. | string | resource id | |

### Conditional Parameters

| Parameter | Description | Type | Allowed | Default |
| --------- | ----------- | :--: | :-----: | ------- |
| `avdObjectId` | The Object ID for the Azure Virtual Desktop application in Entra Id with Application Id = '9cdead84-a844-4324-93f2-b2e6bb768d07'.  The Object ID can found by selecting Microsoft Applications using the Application type filter in the Enterprise Applications blade of Entra Id. If you use the custom UI and template spec, this value is obtained automatically or service Principal selector is presented. Required when `deploymentType` = 'Complete'. | string | object id | |
| `confidentialVMOrchestratorObjectId` | The object ID of the Confidential VM Orchestrator enterprise application with application ID "bf7b6499-ff71-4aa2-97a4-f372087be7f0". Required when `confidentialVMOSDiskEncryption` is set to true.  You must create this application in your tenant before deploying this solution using the powershell provided at https://learn.microsoft.com/en-us/azure/confidential-computing/quick-create-confidential-vm-portal#prerequisites. | string | object id | '' |
| `credentialsKeyVaultResourceId` | The secrets keyvault resource Id. This key vault must contain the following secrets: 'VirtualMachineAdminUserName', 'VirtualMachineAdminPassword', and if applicable, 'DomainJoinUserPrincipalName' and 'DomainJoinUserPassword'. This can be used in leueu of providing the `domainJoinUserPrincipalName`, `domainJoinUserPassword`, `virtualMachineAdminUserName`, and `virtualMachineAdminPassword` parameters. | string | resourceId | '' |
| `domainName` | The name of the domain that provides ADDS to the AVD session hosts and is synchronized with Azure AD. Required when `identitySolution` contains 'DomainServices'. | string | | '' |
| `domainJoinUserPrincipalName` | The User Principal Name of the user with the rights to join the computer to the domain in the specified OU path. Required when `identitySolution` contains 'DomainServices' and when not specifying the `credentialsKeyVaultResourceId`. | secure string | either a secure string or a reference to a key vault following the guidance at https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/key-vault-parameter?tabs=azure-cli. | '' |
| `domainJoinUserPassword` | The password of the user with the rights to join the computer to the domain in the specified OU path. Required when `identitySolution` contains 'DomainServices' and not specifying the `credentialsKeyVaultResourceId`. | secure string | either a secure string or a reference to a key vault following the guidance at https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/key-vault-parameter?tabs=azure-cli. | '' |
| `existingHostPoolResourceId` | The resource ID of the existing host to which hosts will be added when the `deploymentType` = 'SessionHostsOnly'. | string | resourceId | '' |
| `existingHostsResourceGroupName` | The name of the resource group housing the compute objects (i.e., virtual machines, disks, nics, recovery services vault, disk encryption sets, disk accesses, etc.) when the the `deploymentType` = 'SessionHostsOnly'. | string | | '' |
| `identifier` | An identifier used to distinquish each host pool. This normally represents the persona. Required when `deploymentType` = 'Complete'. | string | 3- 10 characters | |
| `secretsKeyVaultPrivateEndpointSubnetResourceId` | The resource id of the subnet on which to create the secrets Key Vault private endpoint. Required when the `deploySecretsKeyVault` and `deployPrivateEndpoints` parameters are set to true. | string | resource id | '' |
| `hostPoolResourcesPrivateEndpointSubnetResourceId` | The resource ID of the subnet where the host pool specific resources such as storage accounts and disk encryption key vaults private endpoints are attached. Required when `deployPrivateEndpoints` = true. | string | resource id | '' |
| `hostPoolPrivateEndpointSubnetResourceId` | The resource ID of the subnet where the AVD Private Link endpoints will be created. Required when `avdPrivateLinkPrivateRoutes` is not set to 'None'. | string | resource id | '' |
| `feedPrivateEndpointSubnetResourceId` | The resource ID of the subnet where the AVD Private Link endpoints will be created. Required when `avdPrivateLinkPrivateRoutes` is set to 'FeedAndHostPool' or 'All'. | string | resource id | '' |
| `globalFeedPrivateEndpointSubnetResourceId` | The resource ID of the subnet where the Global Feed AVD Private Link endpoint will be created. Required when `avdPrivateLinkPrivateRoutes` is set to 'All'. | string | resource id | '' |
| `virtualMachineAdminUserName` | The local administrator username. Required when not specifying the `credentialsKeyVaultResourceId`. | secure string | either a secure string or a reference to a key vault following the guidance at https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/key-vault-parameter?tabs=azure-cli or see the Zero Trust example below. | '' |
| `virtualMachineAdminPassword` | The local administrator password. Required when not specifying the `credentialsKeyVaultResourceId`. | secure string | either a secure string or a reference to a key vault following the guidance at https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/key-vault-parameter?tabs=azure-cli. | '' |

### Optional Parameters

| Parameter | Description | Type | Allowed | Default |
| --------- | ----------- | :--: | :-----: | ------- |
| `azureFilesPrivateDnsZoneResourceId` | The resource Id of the Azure Files private DNS zone which is resolvable from the subnet where the session hosts are deployed. | string | resource id | '' |
| `azureKeyVaultPrivateDnsZoneResourceId` | The resource Id of the Azure Key Vault private dns zone which is resolvable from the subnet that the session hosts will be placed upon. | string | resource id | '' |
| `avdGlobalFeedPrivateDnsZoneResourceId` | If using private endpoints with Azure Virtual Desktop, input the Resource Id for the Private DNS Zone used for initial feed discovery. (privatelink-global.wvd.microsoft.com) | string | resource id | '' |
| `avdPrivateDnsZoneResourceId` | If using private endpoints with Azure Virtual Desktop, input the Resource ID for the Private DNS Zone used for feed download and connections to host pools. (privatelink.wvd.microsoft.com) | string | resource id | '' |
| `index` | A string of integers from 00 to 99. This parameter is designed to uniquely identify host pools when sharding of the host pool is necessary. | string | 0-99 | '' |
| `appGroupSecurityGroups` | An array of objects that contain the Entra ID DisplayNames and ObjectIds that are assigned to the desktop application group created by this template. If you do not shard storage, then these groups are also granted permissions to the storage accounts. | array (of objects) | [{"DisplayName":"Entra Display Name", "ObjectId": "Entra Object Id"}] | [] |
| `artifactsContainerUri` | The full URI of the storage account and container that contains any scripts you want to run on each host during deployment. | string | resource id | '' |
| `artifactsUserAssignedIdentityResourceId` | The resource ID of the managed identity with Storage Blob Data Reader Access to the artifacts storage Account. Required when the cseUris parameter is not empty. | string | resource id | '' |
| `availability` | Set the desired availability / SLA with a pooled host pool.  The best practice is to deploy to availability Zones for resilency. | string | 'none'<br/>'availabilitySets'<br/>'availabilityZones' | 'availabilityZones' |
| `avdAgentsDSCPackage` | Sets the package name for the Desired State Configuration zip file where the script and installers are located for the AVD Agents. This parameter may need to be updated periodically to ensure you are using the latest version. You can obtain this value by going through the Add new session host flow inside a host pool and showing the template and parameters. This value will be exposed in the parameters. | string | Allowed | url | Configuration_*version*.zip | 
| `avdPrivateLinkPrivateRoutes` | Determines if Azure Private Link with Azure Virtual Desktop is enabled. Selecting "None" disables AVD Private Link deployment. Selecting one of the other options enables deployment of the required endpoints. See [AVD Private Link Setup](https://learn.microsoft.com/en-us/azure/virtual-desktop/private-link-setup?tabs=portal%2Cportal-2) for more information. | string | 'None'<br/>'HostPool'<br/>'FeedAndHostPool' | 'None' |
| `azureMonitorPrivateLinkScopeResourceId` | The resource Id of an existing Azure Monitor Private Link Scope resource. If specified, the log analytics workspace and data collection endpoint created by this solution will automatically be associated to this resource to configure private routing of Azure Monitor traffic. | string | valid resource Id | '' |
| `confidentialVMOSDiskEncryption` | Confidential disk encryption is an additional layer of encryption which binds the disk encryption keys to the virtual machine TPM and makes the disk content accessible only to the VM. | bool | true<br/>false | false |
| `customImageResourceId` | The resource ID for the Compute Gallery Image Version. Do not set this value if using a marketplace image. | string | resource id | '' |
| `dedicatedHostResourceId` | The resource Id of a specific Dedicated Host on which to deploy the Virtual Machines. This parameter takes precedence over the `dedicatedHostGroupResourceId` parameter. | string | resource id | '' |
| `dedicatedHostGroupResourceId` | The resource Id of the Dedicated Host Group on to which the Virtual Machines are to be deployed. The Dedicated Host Group must support Automatic Host Assignment for this value to be used. | string | resource id | '' |
| `deployFSLogixStorage` | Determines whether resources to support FSLogix profile storage are deployed. | bool | true<br/>true| false |
| `deploymentType` | Determines whether the control plane, management, and compute resources are deployed or if the deployment will just add session hosts to an existing pool. | string | 'Complete'</br>'SessionHostsOnly' | 'Complete' |
| `deployScalingPlan` | Determines if the scaling plan is deployed to the host pool. | bool | true<br/>false | false |
| `deploySecretsKeyVault` | Determine if the solution deploys the shared credentals key vault. | bool | true<br/>false | false |
| `diskSizeGB` | The size of the session host OS disks. When set to 0, it defaults to the image size. | int | 0<br/>32<br/>64<br/>128<br/>256<br/>512<br/>1024<br/>2048<br/> | 0 |
| `enableAcceleratedNetworking` | Determines whether or not to enable accelerated networking on the session host vms. | bool | true<br/>false | true | 
| `existingAVDInsightsDataCollectionRuleResourceId` | The resource Id of the AVD Insights data collection rule to use when `deploymentType` = 'SessionHostsOnly'. | string | resourceId | '' |
| `existingDataCollectionEndpointResourceId` | The resource Id of the Data Collection Endpoint to use when `deploymentType` = 'SessionHostsOnly'. | string | resourceId | '' |
| `existingDiskAccessResourceId` | The resource Id of the disk access to use when `deploymentType` = 'SessionHostsOnly' and the host pool type is personal. Used for allowing recovery services vault access to the managed disk in a zero trust configuration. | string | resourceId | '' |
| `existingDiskEncryptionSetResourceId` | The resource Id of the disk encryption set to use when `deploymentType` = 'SessionHostsOnly'. Used for customer-managed keys. | string | resourceId | '' |
| `existingFeedWorkspaceResourceId` | The resource Id of an existing AVD Workspace that you want to update with the new application group reference for the desktop application group. This parameter is required when deploying additional host pools to the same region and using the same businessUnitIdentifier or the workspace application groups will be overwritten with only the new application group reference. | string | valid resource id | '' |
| `existingRecoveryServicesVaultResourceId` | The resource Id of the recovery services vault to use when `deploymentType` = 'SessionHostsOnly'. Used for personal hosts pools only when `recoveryServices` = true. | string | resourceId | '' |
| `existingVMInsightsDataCollectionRuleResourceId` | The resource Id of the VM Insights data collection rule to use when `deploymentType` = 'SessionHostsOnly'. | string | resourceId | '' |
| `fslogixAdminGroups` |  An array of objects, defining the administrator groups who will be granted full control access to the FSLogix share. The groups must exist in AD and Entra.<br/>Each object must include the following key value pairs:<br/>- 'displayName': The display name of the security group.<br/>- 'objectId': The Object ID of the security group. | array (of objects) | [{"displayName":"EntraGroupDisplayName","objectId":"guid"}] | [] |
| `fslogixEXistingLocalNetAppVolumeResourceIds` | Existing local (in the same region as the session host VMs) NetApp Files Volume Resource Ids. If Office Containers are used, then list the FSLogix Profile Container Volume first and the Office Container Volume second. Only used when `deployFSLogixStorage` = 'false', `fslogixConfigureSessionHosts` = 'true' and `fslogixStorageService` contains 'AzureNetAppFiles'. | array | [] |
| `fslogixEXistingLocalStorageAccountResourceIds` | Existing local (in the same region as the session host VMs) Azure Storage account Resource Ids. Only used when `deployFSLogixStorage` = 'false', `fslogixConfigureSessionHosts` = 'true' and `fslogixStorageService` contains 'AzureFilesFiles'. | array | [] |
| `fslogixEXistingRemoteNetAppVolumeResourceIds` | Existing remote (not in the same region as the session host VMs) NetApp Files Volume Resource Ids. If Office Containers are used, then list the FSLogix Profile Container Volume first and the Office Container Volume second. Only used when `fslogixConfigureSessionHosts` = 'true', `fslogixContainerType` contains 'CloudCache' and `fslogixStorageService` contains 'AzureNetAppFiles'. | array | [] |
| `fslogixEXistingRemoteStorageAccountResourceIds` | Existing remote (not in the same region as the session host VMs) Azure Storage Account Resource Ids. Only used when `fslogixConfigureSessionHosts` = 'true', `fslogixContainerType` contains 'CloudCache' and `fslogixStorageService` contains 'AzureFiles'. | array | [] |
| `fslogixShardOptions` |  Determines whether or not to Shard Azure Files Storage by deploying more than one storage account, and if so how the Session Hosts are Configured.<br/>If 'None' is selected, then no sharding is performed and only 1 storage account is deployed when deploying storage accounts.<br/>If 'ShardOSS' is selected, then the fslogixShardGroups are used to assign share permissions and configure the session hosts with Object Specific Settings.<br/>If 'ShardPerms' is selected, then storage account permissions are assigned based on the groups defined in `appGroupSecurityGroups` or `fslogixUserGroups`. | string | 'None'<br/>'ShardPerms'<br/>'ShardOSS' | 'None' |
| `fslogixUserGroups` |  An array of objects, defining the user groups who will be granted full control access to the FSLogix share. For `fslogixShardOptions`='ShardOSS' or `fslogixStorageService` contains 'AzureNetAppFiles' the groups must exist in AD and Entra. Otherwise, they can be Entra ID only groups.<br/>Each object must include the following key value pairs:<br/>- 'displayName': The display name of the security group.<br/>- 'objectId': The Object ID of the security group. | array (of objects) | [{"displayName":"EntraGroupDisplayName","objectId":"guid"}] | [] |
| `scalingPlanExclusionTag` | The tag used to exclude virtual machines from the scaling plan. | string | | '' |
| `desktopFriendlyName` | The friendly name for the Desktop in the AVD workspace. | string | | '' |
| `workspaceFriendlyName` | The friendly name of the AVD Workspace. This name is displayed in the AVD client. | string | | '' |
| `diskSku` | The storage SKU for the AVD session host disks.  Production deployments should use Premium_LRS. | string | 'Premium_LRS'<br/>'Standard_LRS'<br/>'StandardSSD_LRS' | 'Premium_LRS' |
| `diskSizeGB` | The size of the OS Disk. | int | 0<br/>64<br/>128<br/>256<br/>512<br/>1024<br/>2048 | 0 (Defaults to Image Size) |
| `domainJoinUserPassword` | The password of the privileged account to domain join the AVD session hosts to your domain | string (secure) | | '' |
| `domainJoinUserPrincipalName` | The UPN of the privileged account to domain join the AVD session hosts to your domain. This should be an account that resides within the domain you are joining. | string (secure) | | '' |
| `ouPath` | The distinguished name of the target Organizational Unit in Domain Services where the session hosts computer accounts will be located. | string | distinguished name | '' |
| `deploySecretsKeyVault` | Determines if the Secrets Key Vault is deployed into the environment. This key vault will be deployed into the management resource group and would be required for session host configuration update deployments. | bool | true<br/>false | true |
| `drainMode` | Enable drain mode on new sessions hosts to prevent users from accessing them until they are validated. | bool | true<br/>false | false |
| `enableMonitoring` | Deploys the required monitoring resources to enable AVD and VM Insights. | bool | true<br/>false | true |
| `encryptionAtHost` | Encryption at host encrypts temporary disks and ephemeral OS disks with platform-managed keys, OS and data disk caches with the key specified in the "keyManagementDisksAndStorage" parameter, and flows encrypted to the Storage service. | bool | true<br/>false | true |
| `existingGlobalFeedResourceId` | The resource Id of the existing global feed workspace. If provided, then the global feed will not be deployed/redeployed regardless of the settings specified in `avdPrivateLinkPrivateRoutes` | string | string | '' |
| `fslogixConfigureSessionHosts` | Configure FSLogix agent on the session hosts via local registry keys. Only applicable when `identitySolution` is "EntraId" or "EntraIdIntuneEnrollment". | bool | true<br/>false | false |
| `fslogixContainerType` | The type of FSLogix containers to use for FSLogix. | string | 'CloudCacheProfileContainer'<br/>'CloudCacheProfileOfficeContainer'<br/>'ProfileContainer'<br/>'ProfileOfficeContainer' | 'ProfileContainer' |
| `fslogixNetAppVnetResourceId` | The resource Id of the Virtual Network delegated for NetApp Volumes. Required when `fslogixStorageService` contains 'AzureNetAppFiles'. | string | resource id | '' |
| `fslogixShareSizeInGB` | The file share size(s) in GB for the fslogix storage solution. | int | | 100 |
| `fslogixStorageAccountADKerberosEncryption` | The Active Directory computer object Kerberos encryption type for the Azure Storage Account or Azure NetApp files Account. | string | 'AES256'<br/>'RC4' | 'AES256' |
| `fslogixStorageCustomPrefix` | The custom prefix to use for the name of the Azure files storage accounts to use for FSLogix. If not specified, the name is generated automatically. | string | max length 13 | '' |
| `fslogixStorageIndex` | The starting number for the storage accounts to support the required use case for FSLogix. https://docs.microsoft.com/en-us/azure/architecture/patterns/sharding | int | 0 to 99 | 1 |
| `fslogixStorageService` | The storage service to use for storing FSLogix containers. The service & SKU should provide sufficient IOPS for all of your users. https://docs.microsoft.com/en-us/azure/architecture/example-scenario/wvd/windows-virtual-desktop-fslogix#performance-requirements | string | 'AzureNetAppFiles Premium'<br/>'AzureNetAppFiles Standard'<br/>'AzureFiles Premium'<br/>'AzureFiles Standard' | 'AzureFiles Standard' |
| `globalFeedPrivateEndpointSubnetResourceId` | The resource ID of the subnet where the global feed private endpoint will be created for AVD Private Link. | string | resource id | '' |
| `workspacePublicNetworkAccess` | Determines if the AVD Workspace allows public network access when using AVD Private link. Applicable when `avdPrivateLinkPrivateRoutes` is set to 'FeedAndHostPool' or 'All'. 'Enabled' allows the global AVD feed to be accessed from both public and private networks, 'Disabled' allows this resource to only be accessed via private endpoints. | string | 'Disabled'<br/>'Enabled' | 'Enabled' |
| `hibernationEnabled` | Hibernation allows you to pause VMs that aren't being used and save on compute costs where the VMs don't need to run 24/7. | bool | true<br/>false | false |
| `hostPoolMaxSessionLimit` | The maximum number of sessions per AVD session host. | int | | 4 |
| `hostPoolPublicNetworkAccess` | Applicable only when `avdPrivateLinkPrivateRoutes` is not set to 'None'. Allow public access to the hostpool through the control plane. 'Enabled' allows this resource to be accessed from both public and private networks. 'Disabled' allows this resource to only be accessed via private endpoints. 'EnabledForClientsOnly' allows this resource to be accessed only when the session hosts are configured to use private routes. | string | 'Disabled'<br/>'Enabled'<br/>'EnabledForClientsOnly' | 'Enabled' |
| `hostPoolRDPProperties` | The RDP properties to add or remove RDP functionality on the AVD host pool. Settings reference: https://learn.microsoft.com/windows-server/remote/remote-desktop-services/clients/rdp-files | string | | 'audiocapturemode:i:1;camerastoredirect:s:*;enablerdsaadauth:i:1' |
| `hostPoolType` | These options specify the host pool type and depending on the type provides the load balancing options and assignment types. | string | 'Pooled DepthFirst'<br/>'Pooled BreadthFirst'<br/>'Personal Automatic'<br/>'Personal Direct' | 'Pooled DepthFirst' |
| `hostPoolValidationEnvironment` | The value determines whether the hostPool should receive early AVD updates for testing. | bool | true<br/>false| false |
| `imageOffer` | Offer for the virtual machine image. Required if `customImageResourceId` is not specified. | string | valid marketplace offer | 'office-365' |
| `imagePublisher` | Publisher for the virtual machine image. Required if `customImageResourceId` is not specified. | string | valid marketplace publisher | 'MicrosoftWindowsDesktop' |
| `imageSku` | SKU for the virtual machine image. Required if `customImageResourceId` is not specified. | string | valid marketplace sku | 'win11-23h2-avd-m365' |
| `integrityMonitoring` | Integrity monitoring enables cryptographic attestation and verification of VM boot integrity along with monitoring alerts if the VM didn't boot because attestation failed with the defined baseline. | bool | true<br/>false | true |
| `keyExpirationInDays` | The number of days that key in the key vault will remain valid. | Int | 30-180 | 180 |
| `keyManagementDisks` | The type of encryption key management used for the OS disk. | string | 'PlatformManaged'<br/>'CustomerManaged'<br/>'<br/>'CustomerManagedHSM'<br/>'PlatformManagedAndCustomerManaged'<br/>'PlatformManagedAndCustomerManagedHSM' | 'PlatformManaged' |
| `keyManagementStorageAccounts` | The type of encryption key management used for the FSLogix storage accounts | string | 'MicrosoftManaged'<br/>'CustomerManaged'<br/>'CustomerManagedHSM' | 'MicrosoftManaged' |
| `keyVaultRetentionInDays` | The amount of time in days that a keyvault will be retained in soft delete status before being automatically purged. If purge protection is enabled as will be the case with the key vaults used for customer-managed keys, then this determines the time before a key vault can be permanent deleted. | int | | 90 |
| `managementPrivateEndpoints` | Determines if private endpoints are created for all management resources (i.e., Automation Accounts, Key Vaults) | bool | true<br/>false | false |
| `managementPrivateEndpointSubnetResourceId` | The resource id of the subnet on which to create the management resource private endpoints. | string | resource id | '' |
| `storagePrivateEndpoints` | Determines if private endpoints are created for all storage resources. | bool | true<br/>false | false |
| `nameConvResTypeAtEnd` | Reverse the normal Cloud Adoption Framework naming convention by putting the resource type abbreviation at the end of the resource name. | bool | true<br/>false | false |
| `regionControlPlane` | The deployment location for the AVD Control Plane resources (i.e., Host Pool, Workspace, and Application Group). Is not used if you specify an existing `workspaceResourceId`. | string | valid region | deployment.location |
| `secureBootEnabled` | Secure boot helps protect your VMs against boot kits, rootkits, and kernel-level malware. | bool | true<br/>false | true |
| `securityLogAnalyticsWorkspaceResourceId` | The resource Id of an existing Log Analytics workspace for security monitoring. Setting this value will install the legacy Microsoft Monitoring Agent (Log Analytics Agent) on the Virtual Machines and connect it to this workspace for log collection. | string | resource id | '' |
| `securityDataCollectionRulesResourceId` | The resource Id of an existing data collection rule designed to collect security relevant logs into a centralized Log Analytics workspace. Setting this value will install the Azure Monitor Agent on each virtual machine and associate the machine with the data collection rule. | string | resource id | '' |
| `securityType` | The Security Type of the Azure Virtual Machine. | string | 'Standard'<br/>'TrustedLaunch'<br/>'ConfidentialVM' | 'TrustedLaunch' |
| `sessionHostCustomizations` | An array of objects containing the customization scripts or application you want to run on each session host virtual machine. Each object must contain the 'name' and 'blobNameOrUri' properties and optionally an 'arguments' property that defines the script or installer arguments. | array (of objects) | | [] |
| `vTpmEnabled` | Virtual Trusted Platform Module (vTPM) is TPM2.0 compliant and validates your VM boot integrity apart from securely storing keys and secrets. | bool | true<br/>false | true |
| `virtualMachineSize` | The size of the virtual machine deployed by this solution. | string | valid size | 'Standard_D4ads_v5' |
| `vCPUs` | The number of virtual CPUs presented by the virtual machines. Used to create the vmTemplate property and tags on the host pool when `deploymentType` = 'Complete'. Not set if left at default. | int | | 0 |
| `memoryGB` | The amount of memory presented by the virtual machines in GB. Used to create the vmTemplate property and tags on the host pool when `deploymentType` = 'Complete'. Not set if left at default. | int | | 0 |
| `workspaceResourceId` | The resource Id of an existing Azure Virtual Desktop Workspace that will be updated with the new desktop application group. If specified, then the `regionControlPlane` is not used and instead the region and resource group where this workspace is located is used. | string | resource id | '' |

### UI Generated / Automatic Parameters

| Parameter | Description | Type | Allowed | Default |
| --------- | ----------- | :--: | :-----: | ------- |
| `timeStamp` | This value is automatically generated by the template when deployed and should not be provided or modified. | string | string | utc date time in yyyyMMddhhmmss format |

## Examples

### Required Parameters Only

This instance deploys an AVD host pool with default values.

``` json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "avdObjectId": {
            "value": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        },
        "identifier": {
            "value": "admin"
        },
        "identitySolution": {
            "value": "EntraId"
        },
        "virtualMachineNamePrefix": {
            "value": "avd-hp1-eus-"
        },
        "virtualMachineAdminUserName": {
            "value": "avdAdmin"
        },
        "virtualMachineAdminPassword": {
            "value": "<REDACTED>"
        },
        "virtualMachineSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/hosts"
        }            
    }
}
```

### Zero Trust Compliant

This example shows a Zero Trust Compliant host pool that includes AVD Private Link, private endpoints for the key vault, automation account, and storage accounts. In addition, all secrets are retrieved from an existing Key Vault.

``` json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        // required
        "avdObjectId": {
            "value": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        },
        "identifier": {
            "value": "admin"
        },
        "identitySolution": {
            "value": "EntraId"
        },            
        "virtualMachineSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/hosts"
        },
        "virtualMachineNamePrefix": {
            "value": "avd-hp1-eus-"
        },
        // Get Secrets from a Key Vault (Optional)
        "credentialsKeyVaultResourceId": {
            "value"  : "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-y5-admin-avd-management-use/providers/Microsoft.KeyVault/vaults/kv-y5-admin-sec-use"
        },  
        // Storage Private Endpoints (required)
        "deployFSLogix": {
            "value": true
        },
        "storagePrivateEndpoints": {
            "value": true
        },
        "storagePrivateEndpointSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/privateEndpoints"
        },            
        "azureFilesPrivateDnsZoneResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-networking-lab-eus/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net"
        },
        // Management Private Endpoints (required)
        "managementPrivateEndpoints": {
            "value": true
        },                        
        "managementPrivateEndpointSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/privateEndpoints"
        },            
        // AVD Private Link (optional)
        "avdPrivateLinkPrivateRoutes": {
            "value": "All"
        },
        "globalFeedPrivateEndpointSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-hub-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-hub-eastus/subnets/privateEndpoints"
        },
        "hostPoolPrivateEndpointSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/privateEndpoints"
        },
        "feedPrivateEndpointSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-hub-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-hub-eastus/subnets/privateEndpoints"
        },
        "avdGlobalFeedPrivateDnsZoneResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/privateDnsZones/privatelink-global.wvd.microsoft.com"
        },
        "avdPrivateDnsZoneResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/privateDnsZones/privatelink.wvd.microsoft.com"
        },
        "hostPoolPublicNetworkAccess": {
            "value": "Disabled"
        },
        "workspacePublicNetworkAccess": {
            "value": "Disabled"
        }
    }
}
```

### Shard FSLogix Storage with Permissions

This example deploys an AVD host pool with Virtual Machines joined to an Active Directory domain and two user groups assigned to the host pool to allow two different storage accounts to be used for user profile storage.

``` json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        // required
        "avdObjectId": {
            "value": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        },
        "identifier": {
            "value": "admin"
        },
        // must use Domain Services to Shard Storage
        "identitySolution": {
            "value": "ActiveDirectoryDomainServices"
        },
        "virtualMachineNamePrefix": {
            "value": "avd-hp1-eus-"
        },
        "virtualMachineAdminUserName": {
            "value": "avdAdmin"
        },
        "virtualMachineAdminPassword": {
            "value": "<REDACTED>"
        },            
        "virtualMachineSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/hosts"
        },
        "domainName": {
            "value": "contoso.com"
        },
        "ouPath": {
            "value": "OU=East,OU=AVD,DC=contoso,DC=com"
        },
        "domainJoinUserPrincipalName": {
            "value": "domjoin@contoso.com"
        },
        "domainJoinUserPassword": {
            "value": "<REDACTED>"
        },
        "deployFSLogix": {
            "value": true
        },
        "appGroupSecurityGroups": {
            "value": [
                {
                    "name": "AVD_Users",
                    "objectId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
                }
            ]
        },
        "fslogixShardOptions": {
            "value": "ShardOSS"
        },
        "fslogixUserGroups": {
            "value": [
                {
                    "name": "AVD_East_Storage_1_Users",
                    "objectId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
                },
                {
                    "name": "AVD_East_Storage_2_Users",
                    "objectId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
                }
            ]
        }
    }
}
```

### Enable Scaling Plan

This instance deploys a scaling plan and associates it with the host pool.

``` json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        // required
        "avdObjectId": {
            "value": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        },
        "artifactsStorageAccountResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.Storage/storageAccounts/saimageassetsusexj5oy5dp"
        },
        "identifier": {
            "value": "admin"
        },
        "identitySolution": {
            "value": "EntraId"
        },
        "virtualMachineNamePrefix": {
            "value": "avd-hp1-eus-"
        },
        "virtualMachineAdminUserName": {
            "value": "avdAdmin"
        },
        "virtualMachineAdminPassword": {
            "value": "<REDACTED>"
        },            
        "virtualMachineSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/hosts"
        },
        // Scaling Plan
        "deployScalingPlan": {
            "value": true
        },
        "scalingPlanExclusionTag": {
            "value": "ExcludedFromScaling"
        },
        "scalingPlanRampUpSchedule": {
            "value": {
                "startTime": "8:00",
                "minimumHostsPct": 20,
                "capacityThresholdPct": 60,
                "loadBalancingAlgorith": "BreadthFirst"
            }
        },
        "scalingPlanPeakSchedule": {
            "value": {
                "startTime": "9:00",
                "loadBalancingAlgorithm": "BreadthFirst"
            }
        },
        "scalingPlanRampDownSchedule": {
            "value": {
                "startTime": "17:00",
                "minimumHostsPct": 10,
                "capacityThresholdPct": 90,
                "loadBalancingAlgorith": "DepthFirst"
            }
        },
        "scalingPlanOffPeakSchedule": {
            "value": {
                "startTime": "20:00",
                "loadBalancingAlgorithm": "DepthFirst"
            }
        }
    }
}
```

### IL5 Isolation Requirements on IL4

This example shows a deployment to Azure US Government Regions which are IL4 that meets the isolation guidelines for IL5 workloads. This deployment includes Dedicated Hosts and Customer Managed Keys for the Virtual Machines and FSLogix Storage Accounts.

> [!Note]
> The `virtualMachineSize` must be compatible with the Dedicated Host (or one of the Dedicated Hosts in the Dedicated Host Group).

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        // required
        "avdObjectId": {
            "value": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        },
        "identifier": {
            "value": "IL5"
        },
        "identitySolution": {
            "value": "EntraId"
        },            
        "virtualMachineSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-usgva/providers/Microsoft.Network/virtualNetworks/vnet-avd-usgva/subnets/hosts"
        },
        "virtualMachineNamePrefix": {
            "value": "avd-il5-usgva-"
        },
        "virtualMachineAdminUserName": {
            "value": "avdAdmin"
        },
        "virtualMachineAdminPassword": {
            "value": "<REDACTED>"
        },
        "virtualMachineSize": {
            "value": "Standard_D4ads_v5"
        },
        // Storage Private Endpoints
        "deployFSLogix": {
            "value": true
        },
        "storagePrivateEndpoints": {
            "value": true
        },
        "storagePrivateEndpointSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-usgva/providers/Microsoft.Network/virtualNetworks/vnet-avd-usgva/subnets/privateEndpoints"
        },            
        "azureFilesPrivateDnsZoneResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-networking-usgva/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.usgovcloudapi.net"
        },
        // Management Private Endpoints
        "managementPrivateEndpoints": {
            "value": true
        },                        
        "managementPrivateEndpointSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-usgva/providers/Microsoft.Network/virtualNetworks/vnet-avd-usgva/subnets/privateEndpoints"
        },            
        "azureKeyVaultPrivateDnsZoneResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-networking-usgva/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.usgovcloudapi.net"
        },
        // Encryption At Rest (Storage Isolation Requirements)
        "keyManagementDisks": {
            "value": "PlatformManagedAndCustomerManagedHSM"
        },
        "keyManagementStorageAccounts": {
            "value": "CustomerManagedHSM"
        },
        // Dedicated Hosts (Compute Isolation Requirements)
        "dedicatedHostGroupResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-hostgroups-usgva/providers/Microsoft.Compute/hostGroups/hg-avd-usgva-zone1"
        }
    }
}
```

## AVD Image Management Parameters

This template deploys a Storage Account with a blob container (optionally with a Private Endpoint) and an Azure Compute Gallery.

### Optional Parameters

| Parameter | Description | Type | Allowed | Default |
| --- | --- | :---: | :---: | :---: |
| `artifactsContainerName` | Blob Container Name. Must start with a letter. Can only contain lower case letters, numbers, and -. | string | from 3 to 63 characters | 'artifacts' |
| `azureBlobPrivateDnsZoneResourceId` | The Resource Id of the Private DNS Zone where the Private Endpoint (if configured) A record will be registered. | string | resource id | '' |
| `location` | The region where the image management resources are being deployed. | string | valid region | `deployment().location` |
| `logAnalyticsWorkspaceResourceId` | Resource Id of an existing Log Analytics Workspace to which the storage account diagnostic logs will be sent. If not specified, then no diagnostic logs are collected. | string | resource id | '' |
| `nameConvResTypeAtEnd` | Reverse the normal Cloud Adoption Framework naming convention by putting the resource type abbreviation at the end of the resource name. | bool | true<br/>false | false |
| `privateEndpointSubnetResourceId` | The ResourceId of the private endpoint subnet to which the storage account private endpoint will be attached. | string | resource id | '' |
| `remoteLocation` | The remote region where another Azure Compute Gallery will be deployed to support recovery from a regional disaster/outage in the primary region. | string | region | '' |
| `storageAccessTier` | Required if the Storage Account kind is set to Blob Storage. The access tier is used for billing. The "Premium" access tier is the default value for premium block blobs storage account type and it cannot be changed for the premium block blobs storage account type. | string | 'Premium'<br/>'Hot'<br/>'Cool' | 'Hot' |
| `storageAllowSharedKeyAccess` | Indicates whether the storage account permits requests to be authorized with the account access key via Shared Key. If false, then all requests, including shared access signatures, must be authorized with Azure Active Directory (Azure AD). The default value is null, which is equivalent to true. | bool | true<br/>false | true |
| `storagePermittedIPs` | Array of permitted IPs or IP CIDR blocks that can access the storage account using the Public Endpoint. | array | | [] |
| `storagePublicNetworkAccess` | Whether or not public network access is allowed for this resource. To limit public network access, use the "PermittedIPs" and/or the "ServiceEndpointSubnetResourceIds" parameters. | string | 'Disabled'<br/>'Enabled' | 'Enabled' |
| `storageSASExpirationPeriod` | The SAS expiration period. DD.HH:MM:SS. | string | | '180.00:00:00' |
| `storageServiceEndpointSubnetResourceIds` | An array of subnet resource IDs where Service Endpoints will be created to allow access to the storage account through the public endpoint. | array | resource id | [] |
| `storageSkuName` | Storage Account Sku Name. | string | 'Standard_LRS'<br/>'Standard_GRS'<br/>'Standard_RAGRS'<br/>'Standard_ZRS'<br/>'Premium_LRS'<br/>'Premium_ZRS'<br/>'Standard_GZRS'<br/>'Standard_RAGZRS' | 'Standard_LRS' |
| `tags` | The tags by resource type to apply to the resources created by this template. See [Tags Example](#tags) | object | | {} |

## Examples

The following section provides usage examples for this template.

### Private Endpoints

This instance deploys the storage account with private endpoints to meet Zero Trust requirements.

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "privateEndpointSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/privateEndpoints"
        },
        "azureBlobPrivateDnsZoneResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-networking-lab-eus/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
        },
        "storagePublicNetworkAccess": {
            "value": "Disabled"
        }
    }
}
```

### Service Endpoints

This instance deploys the storage account with service endpoints and additionally allows a public ip range.

> [!Note]
> This configuration does not meet Zero Trust requirements, but it is more secure than not configuring the storage account firewall when enabling public access.

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "storageServiceEndpointSubnetResourceIds": {
            "value": [
                "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/hosts",
                "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus2/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus2/subnets/hosts"
            ]
        },
        "storagePermittedIPs": {
            "value": [
                "155.33.44.0/24"
            ]
        }
    }
}
```

### Tags

This instance deploys the resources with their default settings and applies resource tags.

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "tags":{
            "value": {
                "Microsoft.Storage/storageAccounts": {
                    "createdBy": "stmeyer"
                },
                "Microsoft.Compute/galleries": {
                    "createdBy": "stmeyer",
                    "environment": "Production"
                }
            }
        }
    }
}
```

## AVD Image Build Parameters

This template deploys a Storage Account with a blob container (optionally with a Private Endpoint) and an Azure Compute Gallery.

### Required Parameters

| Parameter | Description | Type | Allowed | Default |
| --- | --- | :---: | :---: | :---: |
| `artifactsContainerUri` | The full URI of the storage account and container that contains the artifacts used uring the custom image build. This storage account, container, and custom script blobs were uploaded with deploy-imagemanagement.ps1. | string | Uri | '' |
| `computeGalleryResourceId` | Azure Compute Gallery Resource Id. | string | resource id | |
| `storageAccountResourceId` | The resource Id of the storage account containing the artifacts (scripts, installers, etc) used during the image build. | string | resource id |  |
| `subnetResourceId` | The resource Id of the subnet to which the image build and management VMs will be attached. | string | resource id | |
| `userAssignedIdentityResourceId` | The resource Id of the user assigned managed identity used to access the storage account. | string | resource id | |
| `vmSize` | The size of the Image build and Management VMs. | string | valid vm size | |

### Conditional Parameters

| Parameter | Description | Type | Allowed | Default |
| --- | --- | :---: | :---: | :---: |
| `privateEndpointSubnetResourceId` | The resource id of the private endpoint subnet. Must be provided if `collectCustomizationLogs` is set to 'true'. | string | resource id | '' |
| `customImageDefinitionName` | The name of the image Definition to create in the Compute Gallery. Only valid if `imageDefinitionResourceId` is not provided. If left blank, the image definition name will be built on Cloud Adoption Framework principals and based on the `imageDefinitonPublisher`, `imageDefinitionOffer`, and `imageDefinitionSku` values. | string | up to 80 characters | '' |
| `imageDefinitionOffer` | The computer gallery image definition Offer. Required when the `imageDefinitionResourceId` is not defined. | string | up to 64 characters | '' |
| `imageDefinitionPublisher` | The compute gallery image definition Publisher. Required when the `imageDefinitionResourceId` is not defined. | string | up to 128 characters | '' |
| `imageDefinitionSku` | The compute gallery image definition Sku. Required when the `imageDefinitionResourceId` is not defined. | string | up to 64 characters | '' |
| `imageVersionDefaultRegion` | Specifies the default replication region when imageVersionTargetRegions is not supplied. | string | valid region | '' |
| `offer` | The Marketplace Image offer. Required when the `customSourceImageResourceId` is not defined. | string | valid marketplace offer | '' |
| `publisher` | The Marketplace Image publisher. Required when the `customSourceImageResourceId` is not defined. | string | valid marketplace publisher | '' |
| `sku` | The Marketplace Image sku. Required when the `customSourceImageResourceId` is not defined. | string | valid marketplace sku | '' |
| `wsusServer` | The WSUS Server Url if `installUpdates` is true and `updateService` is set to 'WSUS'. (i.e., https://wsus.corp.contoso.com:8531) | string | valid url | '' |

### Optional Parameters

| Parameter | Description | Type | Allowed | Default |
| --- | --- | :---: | :---: | :---: |
| `artifactsContainerName` | The name of the storage blob container which contains the artifacts (scripts, installers, etc) used during the image build. | string | lowercase string | 'artifacts' |
| `blobPrivateDnsZoneResourceId` | The resource id of the existing Azure storage account blob service private dns zone. This zone must be linked to or resolvable from the vnet referenced in the `privateEndpointSubnetResourceId` parameter. | string | resource id | '' |
| `collectCustomizationLogs` | Collect image customization logs. | bool | true<br/>false | false |
| `logStorageAccountNetworkAccess` | The network access configuration for the log storage account. | String | PrivateEndpoint<br/>ServiceEndpoint<br/>PublicEndpoint | PublicEndpoint |
| `customBuildResourceGroupName` | The custom name of the resource group where the image build and management vms will be created. Leave blank to create a new resource group based on Cloud Adoption Framework naming principals. | string | valid resource group name | '' |
| `customSourceImageResourceId` | The resource Id of the source image to use for the image build. If not provided, the latest image from the specified publisher, offer, and sku will be used. | string | resource id | '' |
| `customizations` | This parameter is array of objects that define additional installations and customizations that will be applied to your image. Each object must contain a 'name' property and 'blobNameOrUri' property. In addition, you can specify any script or installer arguments in the 'arguments' property on each object. **Important**, the "blobNameOrUri" property value is case sensitive. | array (of objects) | | [] |
| `location` | Deployment location. Note that the compute resources will be deployed to the region where the subnet is located. | string | valid region | `deployment().location` |
| `encryptionAtHost` | Determines if "EncryptionAtHost" is enabled on the VMs. | bool | true<br/>false | true |
| `imageBuildResourceGroupId` | The resource Id of an existing resource group in which to create the vms to build the image. Leave blank to create a new resource group. | string | resource id | '' |
| `imageDefinitionIsAcceleratedNetworkSupported` | Specifies whether the image definition supports the deployment of virtual machines with accelerated networking enabled. | bool | true<br/>false | false |
| `imageDefinitionIsHibernateSupported` | Specifies whether the image definition supports creating VMs with support for hibernation. | bool | true<br/>false | false |
| `imageDefinitionIsHigherStoragePerformanceSupported` | Specifies whether the image definition supports capturing images of NVMe disks or Virtual Machines. | bool | true<br/>false | false |
| `imageDefinitionResourceId` | The resource id of an existing Image Definition in the Compute gallery. | string | resource id | '' |
| `imageDefinitionSecurityType` | The security type of the image definition. | string | 'Standard'<br/>'ConfidentialVM'<br/>'ConfidentialVMSupported'<br/>'TrustedLaunch'<br/>'TrustedLaunchSupported'<br/>'TrustedLaunchAndConfidentialVMSupported' | 'TrustedLaunch' |
| `imageMajorVersion` | The image major version from 0 - 9999. In order to specify a custom image version you must specify the [imageMajorVersion], [imageMinorVersion], and [imagePatch]. Leave the default to automatically generate the image version. | int | -1 to 9999 | -1 |
| `imageMinorVersion` | The image minor version from 0 - 9999. In order to specify a custom image version you must specify the [imageMajorVersion], [imageMinorVersion], and [imagePatch]. Leave the default to automatically generate the image version. | int | -1 to 9999 | -1 |
| `imagePatch` | The image patch version from 0 - 9999. In order to specify a custom image version you must specify the [imageMajorVersion], [imageMinorVersion], and [imagePatch]. Leave the default to automatically generate the image version. | int | -1 to 9999 | -1 |
| `imageVersionDefaultReplicaCount` | The default image version replica count per region. This can be overwritten by the regional value. | int | 1 to 100. | 1 |
| `imageVersionDefaultStorageAccountType` | Specifies the storage account type to be used to store the image. This property is not updatable. | string | 'Standard_LRS'<br/>'Premium_LRS'<br/>'Standard_ZRS' | 'Standard_LRS' |
| `imageVersionEOLinDays` | The number of days from now that the image version will reach end of life. | int | 0 to 720 | 0 |
| `imageVersionExcludeFromLatest` | Exclude this image version from the latest. This property can be overwritten by the regional value. | bool | true<br/>false | false |
| `imageVersionTargetRegions` | The regions to which the image version will be replicated. (Default: deployment location with Standard_LRS storage and 1 replica.) | array | array of valid regions | [] |
| `appsToRemove` | A list of the built-in Appx Packages to remove. | array |  | [] |
| `office365AppsToInstall` | A list of Office 365 ProPlus apps to install | array | Access</br>Excel<br/>PowerPoint<br/>OneNote<br/>Outlook<br/>Project<br/>Publisher<br/>SkypeForBusiness<br/>Vision<br/>Word | [] |
| `installFsLogix` | Install FSLogix Agent. | bool | true<br/>false | false |
| `installOneDrive` | Install OneDrive (Per Machine) | bool | true<br/>false | false |
| `installTeams` | Install Microsoft Teams. | bool | true<br/>false | false |
| `installUpdates` | Determines if the latest updates from the specified update service will be installed. | bool | true<br/>false | true |
| `installVirtualDesktopOptimizationTool` | Apply the Virtual Desktop Optimization Tool customizations. | bool | true<br/>false | false |
| `tags` | The tags to apply to all resources deployed by this template. | object | | {} |
| `updateService` | The update service. | string | 'WU'<br/>'MU'<br/>'WSUS'<br/>'DCAT'<br/>'STORE'<br/>'OTHER' | 'MU' |

## Examples

The following section provides usage examples for this template.

### Required Parameters Only

This instance builds an AVD image from the latest Windows AVD SKU without Office 365, performs no customizations, generates a new image definition based on the source image publisher, offer, and sku and creates a version in the deployment region.

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "computeGalleryResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.Compute/galleries/gal_image_management_use"
        },
        "storageAccountResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.Storage/storageAccounts/saimageassetsusexj5oy5dp"
        },
        "subnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/hosts"
        },
        "userAssignedIdentityResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-image-management-use"
        },
        "vmSize": {
            "value": "Standard_D4ads_v5"
        }
    }
}
```

### Additional Customizations

This instance builds an image that has LGPO and VS Code installed.

> [!Warning]
> The blobName is case sensitive.

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "computeGalleryResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.Compute/galleries/gal_image_management_use"
        },
        "storageAccountResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.Storage/storageAccounts/saimageassetsusexj5oy5dp"
        },
        "subnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/hosts"
        },
        "userAssignedIdentityResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-image-management-use"
        },
        "vmSize": {
            "value": "Standard_D4ads_v5"
        },
        "customizations": {
            "value": [
                {
                    "name": "LGPO",
                    "blobName": "LGPO.zip"
                },
                {
                    "name": "VSCode",
                    "blobName": "VSCode.zip",
                    "arguments": "/verysilent"
                }
            ]
        }
    }
}
```

### Install Updates via Windows Update

This instance creates and image using default settings and installs updates from a Windows Server Update Services instance.

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "computeGalleryResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.Compute/galleries/gal_image_management_use"
        },
        "storageAccountResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.Storage/storageAccounts/saimageassetsusexj5oy5dp"
        },
        "subnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/hosts"
        },
        "userAssignedIdentityResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-image-management-use"
        },
        "vmSize": {
            "value": "Standard_D4ads_v5"
        },
        "installUpdates": {
            "value": true
        },
        "updateService": {
            "value": "WSUS"
        },
        "wsusServer": {
            "value": "https://wsus.contoso.com:8531"
        }
    }
}
```

### New Image Definition and multiple region distribution

This instance creates a new image definition (with a name based on the provide Publisher, Offer, and Sku) in the Azure Compute Gallery and creates a version that is distributed to multiple regions. It also tags the image definition and image version.

``` json
{
    "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "computeGalleryResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.Compute/galleries/gal_image_management_use"
        },
        "storageAccountResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.Storage/storageAccounts/saimageassetsusexj5oy5dp"
        },
        "userAssignedIdentityResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-image-management-use"
        },
        "subnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-eastus/providers/Microsoft.Network/virtualNetworks/vnet-avd-eastus/subnets/default"
        },
        "vmSize": {
            "value": "Standard_D4ads_v5"
        }, 
        "publisher": {
            "value": "MicrosoftWindowsDesktop"
        },
        "offer": {
            "value": "office-365"
        },
        "sku": {
            "value": "win11-23h2-avd-m365"
        },
        "installUpdates": {
            "value": true
        },
        "updateService": {
            "value": "MU"
        },        
        "customImageDefinitionName": {
            "value": ""
        },
        "imageDefinitionPublisher": {
            "value": "Contoso"
        },
        "imageDefinitionOffer": {
            "value": "office-365"
        },
        "imageDefinitionSku": {
            "value": "win11-23h2-avd-m365"
        },
        "imageDefinitionIsAcceleratedNetworkSupported": {
            "value": true
        },
        "imageDefinitionIsHibernateSupported": {
            "value": true
        },
        "imageDefinitionIsHigherStoragePerformanceSupported": {
            "value": false
        },
        "imageDefinitionSecurityType": {
            "value": "TrustedLaunch"
        },        
        "imageVersionEOLinDays": {
            "value": 0
        },
        "imageVersionDefaultReplicaCount": {
            "value": 1
        },
        "imageVersionDefaultStorageAccountType": {
            "value": "Standard_LRS"
        },
        "imageVersionDefaultRegion": {
            "value": ""
        },
        "imageVersionExcludeFromLatest": {
            "value": false
        },
        "imageVersionTargetRegions": {
            "value": [
                {
                    "storageAccountType": "Standard_LRS",
                    "name": "eastus",
                    "regionalReplicaCount": "10"
                },
                {
                    "storageAccountType": "Standard_LRS",
                    "name": "westus",
                    "regionalReplicaCount": "10"
                },
                {
                    "storageAccountType": "Standard_LRS",
                    "name": "westcentralus",
                    "regionalReplicaCount": "10"
                }
            ]
        },
        "tags": {
            "value": {
                "Microsoft.Compute/galleries/images": {
                    "createdBy": "stmeyer"
                },
                "Microsoft.Compute/galleries/images/versions": {
                    "createdBy": "stmeyer"
                }
            }
        }
    }
}
```