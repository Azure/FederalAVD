[**Home**](../README.md) | [**Design**](design.md) | [**Get Started**](quickStart.md) | [**Artifacts Guide**](artifacts-guide.md) | [**Limitations**](limitations.md) | [**Troubleshooting**](troubleshooting.md) | [**Parameters**](parameters.md)

# Features

## Zero Trust Architecture

This solution is designed to align with Microsoft's Zero Trust security principles for Azure Virtual Desktop. Zero Trust is a security framework that assumes breach and verifies each request as though it originates from an uncontrolled network. The implementation includes multiple layers of security controls that work together to protect your AVD environment.

**Reference:** [Apply Zero Trust principles to Azure Virtual Desktop](https://learn.microsoft.com/en-us/security/zero-trust/azure-infrastructure-avd)

### Key Zero Trust Capabilities

**Network Security:**

- Private endpoints for Azure Storage Accounts, Key Vaults, Recovery Services Vaults, and other PaaS solutions eliminate public internet exposure
- Optional integration with Azure Firewall or Network Virtual Appliances for inspection

**Identity and Access:**

- Supports multiple identity solutions including Microsoft Entra ID (cloud-only and hybrid)
- Managed identities for Azure resource authentication (no stored credentials)

**Data Protection:**

- Customer-managed encryption keys stored in Azure Key Vault Premium with HSM protection
- Encryption at rest for all managed disks and storage accounts
- TLS 1.2 encryption for data in transit
- Private connectivity for FSLogix profile containers

**Least Privilege Access:**

- Role-based access control (RBAC) with minimal permissions assigned
- Separation of duties between control plane and data plane resources
- Azure Policy enforcement for compliance and governance
- User assignment restrictions on application groups

**Monitoring and Threat Detection:**

- Azure Monitor integration for comprehensive logging
- Log Analytics workspace for centralized log collection
- Data Collection Rules for performance and diagnostic data
- Microsoft Defender for Cloud integration capabilities

**Configuration Management:**

- Immutable infrastructure through automated image builds
- Artifact-based software deployment with integrity verification

### Zero Trust Deployment Considerations

When deploying with Zero Trust principles:

1. **Disable Public Access**: Set `enablePrivateEndpoint = true` for storage accounts and ensure session hosts have no public IP addresses
2. **Use Managed Identities**: Configure `artifactsUserAssignedIdentityResourceId` for artifact downloads instead of storage account keys
3. **Implement Network Segmentation**: Deploy session hosts to dedicated subnets with restrictive NSG rules
4. **Enable Monitoring**: Configure Log Analytics workspace for all diagnostic logs and performance data
5. **Apply Encryption**: Enable customer-managed keys for disks and storage accounts using Key Vault
6. **Secure Bastion Access**: Use Azure Bastion for administrative access instead of RDP over public internet

For detailed guidance on implementing Zero Trust for AVD, refer to Microsoft's comprehensive documentation linked above.

## Identity Solutions

This solution supports five different identity configurations to meet various organizational requirements. The `identitySolution` parameter determines how user authentication, session host domain membership, and azure files authentication are handled.

### Active Directory Domain Services (ADDS)

This is the traditional hybrid identity model where both user accounts and session hosts exist in the same Active Directory domain.

**Requirements:**

- On-premises Active Directory Domain Services
- Entra Id Connect for identity synchronization
- Network connectivity between Azure and on-premises (VPN/ExpressRoute)
- Custom DNS configuration pointing to domain controllers

**Session Host Behavior:**

- Session hosts are domain-joined to the on-premises Active Directory domain
- Users authenticate using their traditional domain credentials
- Group Policy can be applied from on-premises domain controllers

**FSlogix Storage Integration:**

- Azure NetApp Files or Azure Files storage accounts are domain-joined to Active Directory
- Supports Kerberos authentication with AES256 or RC4 encryption
- NTFS permissions are managed through Active Directory groups
- Requires a deployment VM to facilitate Azure Files domain join operations and configure NTFS permissions.
- Sharding Options:
  - `fslogixShardOptions = 'None'` - Single storage account for all users
  - `fslogixShardOptions = 'ShardPerms'` - Multiple storage accounts with group-based permissions
  - `fslogixShardOptions = 'ShardOSS'` - Multiple storage accounts with group-based permissions and Object Specific Settings

**Parameter Configuration:**

```bicep
identitySolution = 'ActiveDirectoryDomainServices'
domainName = 'contoso.com'                                   // Required: Domain FQDN
domainJoinUserPrincipalName = 'svc-avd@contoso.com'          // Required(Unless credentialsKeyVaultResourceID is provided): Service account UPN
domainJoinUserPassword = 'SecurePassword123!'                // Required (Unless credentialsKeyVaultResourceID is provided): service account password
credentialsKeyVaultResourceId = '<resourceId>'               // Optional: can use for vm admin and domain join credentials
vmOUPath = 'OU=AVD,OU=Computers,DC=contoso,DC=com'           // Optional: OU for session hosts
fslogixOUPath = 'OU=Storage,OU=Computers,DC=contoso,DC=com'  // Optional: OU for storage accounts
fslogixShardOptions = 'None'                                 // Optional: Determines if storage is split across multiple user groups.
fslogixUserGroups = [
  {
    name: '<ADDS Group Name>'
    id: '<Entra Object Id>'
  }
]                                                            // User security groups that need access to FSLogix storage
fslogixAdminGroups = [
  {
    name: '<ADDS or Entra Group Name>'
    id: '<Entra Object Id>'
  }
]                                                            // Administrative groups with full control access
```

### Entra Domain Services

This cloud-managed domain service option provides domain services without requiring on-premises domain controllers.

**Requirements:**

- Entra Domain Services (managed domain)
- User accounts can be native to Entra Id or be synchronized from on-premises AD
- Virtual network integration with Entra Id Domain Services

**Session Host Behavior:**

- Session hosts are domain-joined to the Entra Domain Services managed domain
- Users authenticate using synchronized identities
- Managed Group Policy through Entra Id Domain Services

**FSLogix Storage Integration:**

- Azure NetApp Files are not supported.
- Storage accounts are domain-joined to Entra Domain Services
- Supports Kerberos authentication
- NTFS permissions are managed through Entra Domain Services groups
- Requires a deployment VM to configure the NTFS permissions.
- Sharding Options:
  - `fslogixShardOptions = 'None'` - Single storage account for all users
  - `fslogixShardOptions = 'ShardPerms'` - Multiple storage accounts with group-based permissions
  - `fslogixShardOptions = 'ShardOSS'` - Multiple storage accounts with group-based permissions and Object Specific Settings

**Parameter Configuration:**

```bicep
identitySolution = 'EntraDomainServices'
domainName = 'contoso.com'                                   // Required: Domain FQDN
domainJoinUserPrincipalName = 'svc-avd@contoso.com'          // Required(Unless credentialsKeyVaultResourceID is provided): Service account UPN
domainJoinUserPassword = 'SecurePassword123!'                // Required (Unless credentialsKeyVaultResourceID is provided): service account password
credentialsKeyVaultResourceId = '<resourceId>'               // Optional: can use for vm admin and domain join credentials
vmOUPath = 'OU=AADDC Computers,DC=contoso,DC=com'            // Optional: OU for session hosts
fslogixOUPath = 'OU=AADDC Computers,DC=contoso,DC=com'       // Optional: OU for storage accounts
fslogixShardOptions = 'None'                                 // Optional: Determines if storage is split across multiple user groups.
fslogixUserGroups = [
  {
    name: '<Entra Group Name>'
    id: '<Entra Object Id>'
  }
]                                                            // User security groups that need access to FSLogix storage
fslogixAdminGroups = [
  {
    name: '<Entra Group Name>'
    id: '<Entra Object Id>'
  }
]                                                            // Administrative groups with full control access
```

### Entra Kerberos (Hybrid)

This hybrid approach allows session hosts to be Entra joined while still supporting traditional Active Directory user accounts for Azure Files access.

**Requirements:**

- On-premises Active Directory Domain Services
- Entra Id Connect with Password Hash Synchronization or Pass-through Authentication
- Entra Id Kerberos functionality enabled
- Optionally, network line of site from the session host vnet so the a domain controller so the deployment vm can:
  - Configure the domain name and domain guid in the Entra Kerberos settings
  - Least privilege NTFS permissions or sharding via NTFS permissions.

**Session Host Behavior:**

- Session hosts are Entra Id joined (not domain-joined)
- Users authenticate with Entra Id credentials that are synced from Active Directory
- Device management through Intune (if `intuneEnrollment = true`)

**FSLogix Storage Integration:**

- Azure NetApp files are not supported.
- Storage accounts use Entra Id Kerberos authentication
- User accounts must exist in on-premises Active Directory (synchronized to Entra Id)
- Kerberos tickets are obtained from Entra Id but use on-premises AD credentials for file access
- Least privilege NTFS permissions are based on on-premises Active Directory groups
- Sharding Options:
  - `fslogixShardOptions = 'None'` - Single storage account for all users
  - `fslogixShardOptions = 'ShardPerms'` - Multiple storage accounts with group-based permissions
  - `fslogixShardOptions = 'ShardOSS'` - Multiple storage accounts with group-based permissions and Object Specific Settings

> [!IMPORTANT]
> For Entra Kerberos with Hybrid Identities, this solution can automate the required App Registration updates (Private Link URIs), domain name and domain guid configuration, and admin consent, if you provide a User Assigned Managed Identity with the correct permissions.
>
> See [Entra Kerberos for Azure Files with Hybrid Identities](entraKerberosHybrid.md) for details on the required permissions and manual steps if you choose not to use the automation.

**Parameter Configuration:**

```bicep
identitySolution = 'EntraKerberos-Hybrid'
domainName = 'contoso.com'                                   // Optional (Required to configure Sharding or Least Privilege NTFS): Domain FQDN
domainJoinUserPrincipalName = 'svc-avd@contoso.com'          // Optional (Required to configure Sharding or Least Privilege NTFS, Unless credentialsKeyVaultResourceID is provided): Service account UPN
domainJoinUserPassword = 'SecurePassword123!'                // Optional (Required to configure Sharding or Least Privilege NTFS, Unless credentialsKeyVaultResourceID is provided): service account password
credentialsKeyVaultResourceId = '<resourceId>'               // Optional (Required to configure Sharding or Least Privilege NTFS if secrets aren't provided): can use for vm admin and domain join credentials
vmOUPath = 'OU=AVD,OU=Computers,DC=contoso,DC=com'           // Optional (Used when configuring Least Privilege NTFS permissions or Sharding): OU for deployment VM
fslogixAppUpdateUserAssignedIdentityResourceId = '<resourceId>' // Optional (Required to configure Sharding or Least Privilege NTFS): User Assigned Identity with required graph permissions
fslogixShardOptions = 'None'                                 // Optional: Determines if storage is split across multiple user groups.
fslogixUserGroups = [
  {
    name: '<ADDS Group Name>'
    id: '<Entra Object Id>'
  }
]                                                            // Optional (Required to configure Sharding or Least Privilege NTFS): User security groups that need access to FSLogix storage
fslogixAdminGroups = [
  {
    name: '<ADDS or Entra Group Name>'
    id: '<Entra Object Id>'
  }
]                                                            // Optional: Administrative groups with full control access
```

### Entra Kerberos (Cloud-Only)

This is a pure cloud identity solution using only Entra Id identities with no on-premises dependencies.

**Requirements:**

- Entra Id tenant with user accounts
- No on-premises Active Directory required

**Session Host Behavior:**

- Session hosts are Entra Id joined
- Users authenticate with Entra Id credentials
- Device management through Intune (if `intuneEnrollment = true`)

**FSLogix Storage Integration:**

- Azure NetApp Files are not supported.
- Storage accounts use Entra Kerberos authentication
- Kerberos tickets are obtained from Entra Id
- Least privilege NTFS permissions are based on Entra Kerberos groups
- Sharding Options:
  - `fslogixShardOptions = 'None'` - Single storage account for all users
  - `fslogixShardOptions = 'ShardPerms'` - Multiple storage accounts with group-based permissions

> [!IMPORTANT]
> For Entra Kerberos with Cloud Only Identity, this solution can automate the required App Registration updates (Private Link URIs), group support tag, and admin consent, if you provide a User Assigned Managed Identity with the correct permissions.
>
> See [Entra Kerberos Cloud Only Support for Azure Files](entraKerberosCloudOnly.md) for details on the required permissions and manual steps if you choose not to use the automation.

**Limitations:**

- While in preview, it is only supported in Azure Commercial

**Parameter Configuration:**

```bicep
identitySolution = 'EntraKerberos-CloudOnly'
fslogixAppUpdateUserAssignedIdentityResourceId = '<resourceId>' // Optional (Required to configure Sharding or Least Privilege NTFS): User Assigned Identity with required graph permissions
fslogixShardOptions = 'None'                                 // Optional: Determines if storage is split across multiple user groups.
fslogixUserGroups = [
  {
    name: '<ADDS Group Name>'
    id: '<Entra Object Id>'
  }
]                                                            // Optional (Required to configure Sharding or Least Privilege NTFS): User security groups that need access to FSLogix storage
fslogixAdminGroups = [
  {
    name: '<ADDS or Entra Group Name>'
    id: '<Entra Object Id>'
  }
]                                                            // Optional: Administrative groups with full control access
```

### Entra Id (using Storage Account Keys)

**Configuration:** `identitySolution = 'EntraId'`

This is a pure cloud identity solution using only Entra Id identities with no on-premises dependencies.

**Requirements:**

- Entra Id tenant with user accounts
- No on-premises Active Directory required
- Optional: Intune enrollment for device management

**Session Host Behavior:**

- Session hosts are Entra Id joined
- Users authenticate with Entra Id credentials
- Device management through Intune (if `intuneEnrollment = true`)

**FSLogix Storage Integration:**

- Azure NetApp files are not supported
- Session Hosts are automatically configured to connect to the storage account on behalf of the user using the storage account key.
- Only supports single storage account configuration
- No traditional NTFS permissions
- No Sharding support

**Parameter Configuration:**

```bicep
identitySolution = 'EntraId'
fslogixAdminGroups = [
  {
    name: '<ADDS or Entra Group Name>'
    id: '<Entra Object Id>'
  }
]                                                            // Optional: Administrative groups with full control access
```

## FSLogix Profile Storage

If selected, this solution will deploy the required resources and configurations so that FSLogix is fully configured and ready for immediate use post deployment.

Azure Files and Azure NetApp Files are the only two SMB storage services available in this solution. The storage configuration varies significantly based on the selected identity solution as described above and below.

### FSLogix Container Types

FSLogix containers can be configured in multiple ways:

- **Profile Container** (Recommended) - Stores user profile data
- **Profile & Office Container** - Stores user profile and Microsoft Office cache data in separate containers
- **Cloud Cache Profile Container** - Uses Cloud Cache for active/active redundancy with profile data
- **Cloud Cache Profile & Office Container** - Uses Cloud Cache for both profile and Office containers

**Reference:** [FSLogix - Microsoft Docs](https://docs.microsoft.com/en-us/fslogix/overview)

### Sharding Options:**

- `fslogixShardOptions = 'None'` - Single storage account for all users
- `fslogixShardOptions = 'ShardPerms'` - Multiple storage accounts with group-based permissions
- `fslogixShardOptions = 'ShardOSS'` - Multiple storage accounts with Object Specific Settings

**Group Configuration:**

- `fslogixUserGroups` - Security groups that need access to FSLogix storage
- `fslogixAdminGroups` - Administrative groups with full control access
- Groups source is determined by Identity Solution

### Azure Files Premium Features

When `fslogixStorageService = 'AzureFiles Premium'` is selected:

**SMB Multichannel:**

- Automatically enabled for improved performance
- Allows multiple network connections from each session host
- Significantly improves throughput for large files

**Performance Characteristics:**

- Up to 100,000 IOPS per share
- Sub-millisecond latency
- Predictable performance scaling

### Storage Account Naming and Organization

The solution automatically generates storage account names based on:

- a name prefix - 'fslogix'
- a unique string deterministically generated from the storage resource group id guaranteeing uniqueness across the Azure environment.
- Index numbers for sharded configurations

**FSLogix Storage Index:**

The `fslogixStorageIndex` parameter (0-99) allows you to:

- Deploy additional storage accounts for capacity expansion
- Create storage accounts with non-overlapping name ranges

### Cloud Cache Configuration

For business continuity, you can configure Cloud Cache with remote storage accounts:

- `fslogixExistingRemoteStorageAccountResourceIds` - Storage accounts in different regions
- `fslogixExistingRemoteNetAppVolumeResourceIds` - NetApp volumes in different regions

This supports active/active disaster recovery configurations as documented in the FSLogix Cloud Cache guidance.

### Azure NetApp Files Integration

When using Azure NetApp Files (`fslogixStorageService = 'AzureNetAppFiles Standard'` or `'AzureNetAppFiles Premium'`):

**Requirements:**

- `netAppVolumesSubnetResourceId` - Subnet delegated to Microsoft.Netapp/volumes
- Active Directory connection configuration
- Appropriate capacity pool sizing

**Performance Tiers:**

- **Standard:** Up to 320,000 IOPS
- **Premium:** Up to 450,000 IOPS

**Domain Integration:**

- `existingSharedActiveDirectoryConnection` - Use existing AD connection or create new one
- Supports the same identity solutions as Azure Files

**Deployed Resources:**

**Core Resources:**

- Azure Storage Account(s) (Optional, quantity depends on identity solution and sharding options)
  - File Services with Premium or Standard performance tiers
  - File Share(s) for Profile and/or Office containers
  - Private Endpoint for secure access (when `deployPrivateEndpoints = true`)
- Azure NetApp Account (Optional, when using NetApp Files)
  - Capacity Pool with appropriate performance tier
  - Volume(s) for Profile and/or Office containers
  - Active Directory connection configuration

**Deployment Resources:**

- Deployment Virtual Machine
  - For ActiveDirectoryDomainServices identity, facilitates storage account domain join operations
  - Configures NTFS permissions on file shares
  - For Entra Kerberos Identity Scenarios - can perform required storage account service principal configuration via Microsoft Graph.
- Network Interface for deployment VM
- OS Disk for deployment VM
- User Assigned Identity

**Security and Access:**

- Private Endpoints (Optional, when Private Endpoints are enabled)
  - Azure Files private endpoints with private DNS integration
  - Secure network access to storage resources
- User Assigned Managed Identity (for customer managed keys)
- Encryption Key Vault and encryption key (for customer managed keys)
- Role Assignments for storage account access
- NTFS permissions configured based on security groups

**Function App Resources (Optional, for Premium Azure Files):**

- Function App for automatic quota increase management
- App Service Plan for function hosting
- Application Insights for function monitoring
- Storage Account for function metadata

**Encryption and Keys (Optional):**

- Azure Key Vault for Customer Managed Keys (when `keyManagementStorageAccounts` includes 'Customer')
- Encryption keys with auto-rotation enabled
- Disk Encryption Sets for storage encryption

**Backup Resources (Optional):**

- Recovery Services Vault for Azure Files backup
- Backup Policy for file share protection
- Protected Item configuration for each file share

## GPU Drivers & Settings

When an appropriate VM size (Nv, Nvv3, Nvv4, or NCasT4_v3 series) is selected, this solution will automatically deploy the appropriate virtual machine extension to install the graphics driver and configure the recommended registry settings.

**Reference:** [Configure GPU Acceleration - Microsoft Docs](https://docs.microsoft.com/en-us/azure/virtual-desktop/configure-vm-gpu)

**Deployed Resources:**

- Virtual Machines Extensions
  - AmdGpuDriverWindows
  - NvidiaGpuDriverWindows
  - CustomScriptExtension

## High Availability

This optional feature will deploy the selected availability option and only provides high availability for "pooled" host pools since it is a load balanced solution.  Virtual machines can be deployed in either Availability Zones or Availability Sets, to provide a higher SLA for your solution.  SLA: 99.99% for Availability Zones, 99.95% for Availability Sets.  

**Reference:** [Availability options for Azure Virtual Machines - Microsoft Docs](https://docs.microsoft.com/en-us/azure/virtual-machines/availability)

**Deployed Resources:**

- Availability Set(s) (Optional)

## Monitoring

This feature deploys the required resources to enable the AVD Insights workbook in the Azure Virtual Desktop blade in the Azure Portal.

**Reference:** [Azure Monitor for AVD - Microsoft Docs](https://docs.microsoft.com/en-us/azure/virtual-desktop/azure-monitor)

In addition to Insights Monitoring, the solution also allows you to send security relevant logs to another log analytics workspace. This can be accomplished by configuring the `securityLogAnalyticsWorkspaceResourceId` parameter for the legacy Log Analytics Agent or the `securityDataCollectionRulesResourceId` parameter for the Azure Monitor Agent.

**Deployed Resources:**

- Log Analytics Workspace
- Data Collection Endpoint
- Data Collection Rules
  - AVD Insights
  - VM Insights
- Azure Monitor Agent extension
- System Assigned Identity on all deployed Virtual Machines
- Diagnostic Settings
  - Host Pool
  - Workspace

## AutoScale Scaling Plan

Autoscale lets you scale your session host virtual machines (VMs) in a host pool up or down according to schedule to optimize deployment costs.

**Reference:** [AutoScale Scaling Plan - Microsoft Docs](https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-create-assign-scaling-plan)

## Customer Managed Keys for Encryption

This optional feature deploys the required resources & configuration to enable virtual machine managed disk encryption on the session hosts using a customer managed key. The configuration also enables double encryption which uses a platform managed key in combination with the customer managed key. The FSLogix storage account can also be encrypted using Customer Managed Keys.

**Reference:** [Azure Server-Side Encryption - Microsoft Docs](https://learn.microsoft.com/azure/virtual-machines/disk-encryption)

**Deployed Resources:**

- Key Vault
  - Key Encryption Key (1 per host pool for VM disks, 1 for each fslogix storage account)
- Disk Encryption Set

## SMB Multichannel

This feature is automatically enabled when Azure Files Premium is selected for FSLogix storage. This feature is only supported with Azure Files Premium and it allows multiple connections to an SMB share from an SMB client.

**Reference:** [SMB Multichannel Performance - Microsoft Docs](https://docs.microsoft.com/en-us/azure/storage/files/storage-files-smb-multichannel-performance)

## Start VM On Connect

This optional feature allows your end users to turn on a session host when all the session hosts have been stopped / deallocated. This is done automatically when the end user opens the AVD client and attempts to access a resource.  Start VM On Connect compliments scaling solutions by ensuring the session hosts can be turned off to reduce cost but made available when needed.

**Reference:** [Start VM On Connect - Microsoft Docs](https://docs.microsoft.com/en-us/azure/virtual-desktop/start-virtual-machine-connect?tabs=azure-portal)

**Deployed Resources:**

- Role Assignment
- Host Pool

## Trusted Launch

This feature is enabled automatically with the safe boot and vTPM settings when the following conditions are met:

- a generation 2, "g2", image SKU is selected
- the VM size supports the feature

It is a security best practice to enable this feature to protect your virtual machines from:

- boot kits
- rootkits
- kernel-level malware

**Reference:** [Trusted Launch - Microsoft Docs](https://docs.microsoft.com/en-us/azure/virtual-machines/trusted-launch)

**Deployed Resources:**

- Virtual Machines
  - Guest Attestation extension

## Confidential VMs

Azure confidential VMs offer strong security and confidentiality for tenants. They create a hardware-enforced boundary between your application and the virtualization stack. You can use them for cloud migrations without modifying your code, and the platform ensures your VM’s state remains protected.

**Reference:** [Confidential Virtual Machines - Microsoft Docs](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-overview)

**Deployed Resources:**

- Azure Key Vault Premium
  - Key Encryption Key protected by HSM
- Disk Encryption Set

## IL5 Isolation

Azure Government supports applications that use Impact Level 5 (IL5) data in all available regions. IL5 requirements are defined in the [US Department of Defense (DoD) Cloud Computing Security Requirements Guide (SRG)](https://public.cyber.mil/dccs/dccs-documents/). IL5 workloads have a higher degree of impact to the DoD and must be secured to a higher standard. When you deploy this solution to the IL4 Azure Government regions (Arizona, Texas, Virginia), you can meet the IL5 isolation requirements by configuring the parameters to deploy the Virtual Machines to dedicated hosts and using Customer Managed Keys that are maintained in Azure Key Vault and stored in FIPS 140 Level 3 validated Hardware Security Modules (HSMs).

**Prerequisites:**

You must have already deployed at least one dedicated host into a dedicated host group in one of the Azure US Government regions. For more information about dedicated hosts, see (https://learn.microsoft.com/en-us/azure/virtual-machines/dedicated-hosts).

**Reference:**

[Azure Government isolation guidelines for Impact Level 5 - Azure Government | Microsoft Learn](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-impact-level-5)

**Deployed Resources:**

- Azure Key Vault Premium (Virtual Machine Managed Disks - 1 per host pool)
  - Customer Managed Key protected by HSM (Auto Rotate enabled)
- Disk Encryption Set
- Azure Key Vault Premium (FSLogix Storage Accounts - 1 per storage account)
  - Customer Managed Key protected by HSM (Auto Rotate enabled)

For an example of the required parameter values, see: [IL5 Isolation Requirements on IL4](parameters.md#il5-isolation-requirements-on-il4)

## Backups

This optional feature enables backups to protect user profile data. When selected, if the host pool is "pooled" and the storage solution is Azure Files, the solution will protect the file share. If the host pool is "personal", the solution will protect the virtual machines.

**Reference:** [Azure Backup - Microsoft Docs](https://docs.microsoft.com/en-us/azure/backup/backup-overview)

**Deployed Resources:**

- Recovery Services Vault
- Backup Policy
- Protection Container (File Share Only)
- Protected Item
