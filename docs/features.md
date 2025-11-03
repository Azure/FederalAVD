[**Home**](../README.md) | [**Design**](design.md) | [**Get Started**](quickStart.md) | [**Limitations**](limitations.md) | [**Troubleshooting**](troubleshooting.md) | [**Parameters**](parameters.md) | [**Zero Trust Framework**](zeroTrustFramework.md)

# Features

## Backups

This optional feature enables backups to protect user profile data. When selected, if the host pool is "pooled" and the storage solution is Azure Files, the solution will protect the file share. If the host pool is "personal", the solution will protect the virtual machines.

**Reference:** [Azure Backup - Microsoft Docs](https://docs.microsoft.com/en-us/azure/backup/backup-overview)

**Deployed Resources:**

- Recovery Services Vault
- Backup Policy
- Protection Container (File Share Only)
- Protected Item

## Identity Solutions

This solution supports four different identity configurations to meet various organizational requirements. The `identitySolution` parameter determines how user authentication and session host domain membership are handled.

### Active Directory Domain Services (ADDS)

**Configuration:** `identitySolution = 'ActiveDirectoryDomainServices'`

This is the traditional hybrid identity model where both user accounts and session hosts exist in the same Active Directory domain.

**Requirements:**
- On-premises Active Directory Domain Services
- Azure AD Connect for identity synchronization
- Network connectivity between Azure and on-premises (VPN/ExpressRoute)
- Custom DNS configuration pointing to domain controllers

**Session Host Behavior:**
- Session hosts are domain-joined to the on-premises Active Directory domain
- Users authenticate using their traditional domain credentials
- Group Policy can be applied from on-premises domain controllers

**Azure Files Integration:**
- Storage accounts can be domain-joined to Active Directory
- Supports Kerberos authentication with AES256 or RC4 encryption
- NTFS permissions are managed through Active Directory groups
- Requires a management VM to facilitate domain join operations

### Entra Domain Services

**Configuration:** `identitySolution = 'EntraDomainServices'`

This cloud-managed domain service option provides domain services without requiring on-premises domain controllers.

**Requirements:**
- Azure AD Domain Services (managed domain)
- User accounts can exist in Azure AD or be synchronized from on-premises AD
- Virtual network integration with Azure AD Domain Services

**Session Host Behavior:**
- Session hosts are domain-joined to the Azure AD Domain Services managed domain
- Users authenticate using synchronized identities
- Managed Group Policy through Azure AD Domain Services

**Azure Files Integration:**
- Storage accounts are domain-joined to Azure AD Domain Services
- Supports Kerberos authentication
- NTFS permissions are managed through Azure AD Domain Services groups
- Management VM facilitates domain join to the managed domain

### Entra Kerberos (Hybrid)

**Configuration:** `identitySolution = 'EntraKerberos'`

This hybrid approach allows session hosts to be Azure AD joined while still supporting traditional Active Directory user accounts for Azure Files access.

**Requirements:**
- On-premises Active Directory Domain Services
- Azure AD Connect with Password Hash Synchronization or Pass-through Authentication
- Azure AD Kerberos functionality enabled
- Domain GUID configuration

**Session Host Behavior:**
- Session hosts are Azure AD joined (not domain-joined)
- Users authenticate with Azure AD credentials
- No traditional domain Group Policy (use Intune for management)

**Azure Files Integration:**
- Storage accounts use Azure AD Kerberos authentication
- User accounts must exist in on-premises Active Directory (synchronized to Azure AD)
- Kerberos tickets are obtained from Azure AD but use on-premises AD credentials for file access
- NTFS permissions are based on on-premises Active Directory groups

> [!IMPORTANT]
> For Entra Kerberos, additional manual configuration is required:
> 1. Grant admin consent to the storage account service principal in Azure AD
> 2. Disable multifactor authentication for the storage account identity
> 3. Configure the `domainGuid` parameter with your Active Directory domain GUID

### Entra ID (Cloud-Only)

**Configuration:** `identitySolution = 'EntraId'`

This is a pure cloud identity solution using only Azure AD identities with no on-premises dependencies.

**Requirements:**
- Azure AD tenant with user accounts
- No on-premises Active Directory required
- Optional: Intune enrollment for device management

**Session Host Behavior:**
- Session hosts are Azure AD joined
- Users authenticate with Azure AD credentials
- Device management through Intune (if `intuneEnrollment = true`)

**Azure Files Integration:**
- Limited Azure Files integration (Azure AD authentication has restrictions)
- Only supports single storage account configuration
- Uses Azure AD identities for access control
- No traditional NTFS permissions - uses Azure RBAC

**Limitations:**
- FSLogix sharding options are limited (`fslogixShardOptions = 'None'`)
- Only one storage account can be used for FSLogix profiles
- Storage account access is managed through Azure RBAC roles rather than NTFS permissions

## FSLogix Profile Storage

If selected, this solution will deploy the required resources and configurations so that FSLogix is fully configured and ready for immediate use post deployment.

Azure Files and Azure NetApp Files are the only two SMB storage services available in this solution. The storage configuration varies significantly based on the selected identity solution:

### FSLogix Container Types

FSLogix containers can be configured in multiple ways:

- **Profile Container** (Recommended) - Stores user profile data
- **Profile & Office Container** - Stores user profile and Microsoft Office cache data in separate containers
- **Cloud Cache Profile Container** - Uses Cloud Cache for active/active redundancy with profile data
- **Cloud Cache Profile & Office Container** - Uses Cloud Cache for both profile and Office containers

**Reference:** [FSLogix - Microsoft Docs](https://docs.microsoft.com/en-us/fslogix/overview)

### Storage Configuration by Identity Solution

#### Active Directory Domain Services & Entra Domain Services

When using domain-based identity solutions, you have full flexibility for FSLogix storage:

**Storage Account Domain Join:**
- A management VM is deployed to facilitate domain join of Azure Files storage accounts
- Storage accounts are joined to the domain using the computer identity
- NTFS permissions are configured automatically based on security groups

**Sharding Options:**
- `fslogixShardOptions = 'None'` - Single storage account for all users
- `fslogixShardOptions = 'ShardPerms'` - Multiple storage accounts with group-based permissions
- `fslogixShardOptions = 'ShardOSS'` - Multiple storage accounts with Object Specific Settings

**Group Configuration:**
- `fslogixUserGroups` - Security groups that need access to FSLogix storage
- `fslogixAdminGroups` - Administrative groups with full control access
- Groups must be sourced from Active Directory and synchronized to Azure AD

#### Entra Kerberos

Similar to domain-based solutions with some differences:

**Authentication Method:**
- Uses Azure AD Kerberos for storage account authentication
- User accounts must exist in on-premises Active Directory (synchronized to Azure AD)
- Session hosts are Azure AD joined but access storage using Kerberos tickets

**Configuration Requirements:**
- `domainGuid` parameter must be configured with the on-premises domain GUID
- Storage account service principal requires admin consent in Azure AD
- Multifactor authentication must be disabled for storage account access

#### Entra ID (Cloud-Only)

Limited FSLogix configuration due to Azure AD authentication constraints:

**Restrictions:**
- `fslogixShardOptions` must be set to `'None'`
- Only one storage account can be deployed
- No traditional NTFS permissions - uses Azure RBAC instead

**Authentication:**
- Uses Azure AD authentication for storage access
- Storage account access controlled through Azure RBAC roles
- No domain join process required

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

- Location abbreviation
- Resource naming conventions
- Identity solution requirements
- Index numbers for sharded configurations

**FSLogix Storage Index:**
The `fslogixStorageIndex` parameter (0-99) allows you to:
- Deploy additional storage accounts for capacity expansion
- Create storage accounts with non-overlapping name ranges
- Support multi-region storage deployments

### Cloud Cache Configuration

For business continuity, you can configure Cloud Cache with remote storage accounts:

**Local Storage Accounts:**
- `fslogixExistingLocalStorageAccountResourceIds` - Storage accounts in the same region as session hosts
- `fslogixExistingLocalNetAppVolumeResourceIds` - NetApp volumes in the same region

**Remote Storage Accounts:**
- `fslogixExistingRemoteStorageAccountResourceIds` - Storage accounts in different regions
- `fslogixExistingRemoteNetAppVolumeResourceIds` - NetApp volumes in different regions

This supports active/active disaster recovery configurations as documented in the FSLogix Cloud Cache guidance.

### Identity Solution Parameter Configuration

Each identity solution requires specific parameter configurations for proper deployment:

#### Active Directory Domain Services Parameters

```bicep
identitySolution = 'ActiveDirectoryDomainServices'
domainName = 'contoso.com'                              // Required: Domain FQDN
domainJoinUserPrincipalName = 'svc-avd@contoso.com'     // Required: Service account UPN
domainJoinUserPassword = 'SecurePassword123!'           // Required: Service account password
vmOUPath = 'OU=AVD,OU=Computers,DC=contoso,DC=com'     // Optional: OU for session hosts
fslogixOUPath = 'OU=Storage,OU=Computers,DC=contoso,DC=com'  // Optional: OU for storage accounts
fslogixStorageKerberosEncryptionType = 'AES256'          // Optional: Kerberos encryption type
```

#### Entra Domain Services Parameters

```bicep
identitySolution = 'EntraDomainServices'
domainName = 'contoso.onmicrosoft.com'                  // Required: Managed domain name
domainJoinUserPrincipalName = 'avd-admin@contoso.onmicrosoft.com'  // Required: AAD DC Admin
domainJoinUserPassword = 'SecurePassword123!'           // Required: Admin password
vmOUPath = 'OU=AADDC Computers'                         // Optional: Default AADDS OU
fslogixStorageKerberosEncryptionType = 'AES256'          // Optional: Kerberos encryption type
```

#### Entra Kerberos Parameters

```bicep
identitySolution = 'EntraKerberos'
domainName = 'contoso.com'                              // Required: On-premises domain FQDN
domainGuid = '12345678-1234-1234-1234-123456789012'     // Required: On-premises domain GUID
intuneEnrollment = true                                  // Recommended: Enable Intune management
fslogixStorageKerberosEncryptionType = 'AES256'          // Optional: Kerberos encryption type
// Note: No domain join credentials needed for session hosts
// Note: Manual post-deployment steps required for storage account service principals
```

#### Entra ID Parameters

```bicep
identitySolution = 'EntraId'
intuneEnrollment = true                                  // Recommended: Enable Intune management
fslogixShardOptions = 'None'                            // Required: Must be 'None' for Entra ID
// Note: Limited FSLogix storage options
// Note: No domain-related parameters needed
```

### Identity-Specific FSLogix Configuration

#### Domain-Based Identity Solutions (ADDS/AADDS)

**Full Flexibility:**
- All FSLogix sharding options available
- Multiple storage accounts supported
- Traditional NTFS permissions
- Domain-joined storage accounts

**Security Group Configuration:**
```bicep
appGroupSecurityGroups = [
  {
    id: '11111111-1111-1111-1111-111111111111'
    name: 'AVD-Users-Finance'
  }
  {
    id: '22222222-2222-2222-2222-222222222222'
    name: 'AVD-Users-HR'
  }
]

fslogixUserGroups = [
  {
    id: '11111111-1111-1111-1111-111111111111'
    name: 'AVD-Users-Finance'
  }
  {
    id: '22222222-2222-2222-2222-222222222222'
    name: 'AVD-Users-HR'
  }
]

fslogixAdminGroups = [
  {
    id: '33333333-3333-3333-3333-333333333333'
    name: 'AVD-Admins'
  }
]
```

#### Entra Kerberos Identity Solution

**Hybrid Configuration:**
- Session hosts are Azure AD joined
- Storage uses on-premises AD groups for NTFS permissions
- Users must exist in both Azure AD and on-premises AD (synchronized)

**Required Manual Steps:**
1. **Service Principal Consent:**
   ```powershell
   # Grant admin consent to storage account service principal
   Connect-AzureAD
   $servicePrincipal = Get-AzureADServicePrincipal -Filter "DisplayName eq 'storageaccountname'"
   New-AzureADServiceAppRoleAssignment -ObjectId $servicePrincipal.ObjectId -PrincipalId $servicePrincipal.ObjectId -ResourceId $servicePrincipal.ObjectId -Id "00000000-0000-0000-0000-000000000000"
   ```

2. **Disable MFA for Storage Account:**
   - Create conditional access policy excluding the storage account service principal from MFA requirements
   - Apply to all cloud apps but exclude the specific storage account application

#### Entra ID Identity Solution

**Restricted Configuration:**
- Single storage account only (`fslogixShardOptions = 'None'`)
- Azure RBAC instead of NTFS permissions
- Limited group-based access control

**Required Role Assignments:**
```bicep
// Users need these roles on the storage account:
// - Storage File Data SMB Share Contributor (read/write access)
// - Storage File Data SMB Share Reader (read access)
// - Storage File Data SMB Share Elevated Contributor (full control)
```

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

> [!IMPORTANT]
> This solution does not complete all the steps required for Entra Kerberos authentication on your Azure Files storage account(s). You must grant admin consent to the new service principal(s) representing the Azure Files storage account(s) and disable multifactor authentication on each storage account. See [Enable Microsoft Entra Keberos authentication for hybrid identities on Azure Files](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable?tabs=azure-portal%2Cintune) for all the required steps.

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

**Management Resources:**
- Management Virtual Machine (for domain-based identity solutions)
  - Facilitates storage account domain join operations
  - Configures NTFS permissions on file shares
  - Applies security group access rights
- Network Interface for management VM
- OS Disk for management VM

**Security and Access:**
- Private Endpoints (Optional, when Zero Trust is enabled)
  - Azure Files private endpoints with private DNS integration
  - Secure network access to storage resources
- User Assigned Managed Identity (for storage account access)
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

**Prerequisites**

You must have already deployed at least one dedicated host into a dedicated host group in one of the Azure US Government regions. For more information about dedicated hosts, see (https://learn.microsoft.com/en-us/azure/virtual-machines/dedicated-hosts).

**Reference:**

[Azure Government isolation guidelines for Impact Level 5 - Azure Government | Microsoft Learn](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-impact-level-5)

**Deployed Resources**

- Azure Key Vault Premium (Virtual Machine Managed Disks - 1 per host pool)
  - Customer Managed Key protected by HSM (Auto Rotate enabled)
- Disk Encryption Set
- Azure Key Vault Premium (FSLogix Storage Accounts - 1 per storage account)
  - Customer Managed Key protected by HSM (Auto Rotate enabled)

For an example of the required parameter values, see: [IL5 Isolation Requirements on IL4](parameters.md#il5-isolation-requirements-on-il4)
