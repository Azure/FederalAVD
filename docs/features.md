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

## Multi-Subscription Support

This solution supports deploying Azure Virtual Desktop resources across multiple Azure subscriptions, enabling flexible resource organization, cost management, and adherence to organizational governance policies. You can separate the control plane, monitoring infrastructure, and compute resources into different subscriptions based on your requirements.

### Supported Deployment Patterns

**Control Plane and Monitoring in Separate Subscriptions:**

- AVD workspace, host pools, and application groups deployed to a control plane subscription
- Log Analytics workspace and monitoring resources deployed to a monitoring subscription
- Session hosts, storage accounts, and associated compute resources deployed to the current deployment subscription
- Ideal for centralized AVD control plane management with separate monitoring infrastructure

**Control Plane in Separate Subscription:**

- AVD control plane resources in one subscription
- Monitoring, session hosts, storage, and compute resources in the deployment subscription
- Useful for organizations with dedicated subscriptions for AVD management resources

### Configuration Parameters

Use the following subscription ID parameters in your parameter files or through the deployment UI:

| Parameter | Purpose | Default Behavior |
|-----------|---------|------------------|
| `controlPlaneSubscriptionId` | Subscription for AVD control plane resources (workspace, host pools, application groups) | Current deployment subscription if not specified |
| `monitoringSubscriptionId` | Subscription for Log Analytics workspace and monitoring resources | Current deployment subscription if not specified |

**Note:** Session hosts, storage accounts, and all other resources are deployed to the current deployment subscription context. To deploy these resources to a different subscription, you must run the deployment from that target subscription.

### Prerequisites for Multi-Subscription Deployments

1. **Service Principal or User Permissions**: The identity deploying the solution must have appropriate permissions (Contributor or equivalent) in all target subscriptions
2. **Network Connectivity**: If resources are in different subscriptions, ensure proper virtual network connectivity (peering, hub-spoke, or vWAN)
3. **Resource Provider Registration**: Required Azure resource providers must be registered in each subscription
4. **Azure Policy Compliance**: Ensure any subscription-level policies allow the required resource deployments

### Example Configuration

**Bicep Parameter File:**

```bicep
controlPlaneSubscriptionId = '11111111-1111-1111-1111-111111111111'   // Control plane subscription
monitoringSubscriptionId = '22222222-2222-2222-2222-222222222222'     // Monitoring subscription
// Session hosts and storage deploy to the current deployment subscription (where you run the deployment)
```

**Benefits:**

- **Cost Management**: Separate billing and cost tracking per workload or department
- **Governance**: Apply different Azure Policies and compliance requirements per subscription
- **Quota Management**: Distribute resources across subscriptions to avoid quota limitations
- **Security Boundaries**: Implement subscription-level isolation for sensitive workloads
- **Scale**: Overcome subscription-level resource limits by distributing components

**Considerations:**

- Cross-subscription resource references require proper RBAC assignments
- Networking between subscriptions requires virtual network peering or connectivity through a hub
- Private endpoints work across subscriptions but require proper network line-of-sight
- Managed identity assignments may need to span subscription boundaries
- To deploy session hosts and storage to a different subscription than monitoring/control plane, run the deployment from that target subscription context

## Identity Solutions

This solution supports five different identity configurations to meet various organizational requirements. The `identitySolution` parameter determines how user authentication, session host domain membership, and azure files authentication are handled.

### Active Directory Domain Services (ADDS)

This is the traditional hybrid identity model where both user accounts and session hosts exist in the same Active Directory domain.

**Requirements:**

- Active Directory Domain Services domain controllers deployed in Azure or on-premises
- Entra Id Connect for identity synchronization
- Network connectivity between Azure and on-premises (VPN/ExpressRoute) if domain controllers are not deployed to Azure.
- Custom DNS configuration pointing to domain controllers

**Session Host Behavior:**

- Session hosts are domain-joined to the Active Directory domain
- Users authenticate using their traditional domain credentials
- Group Policy can be applied from domain controllers

**FSLogix Storage:**

- Supports both Azure Files and Azure NetApp Files
- Storage resources are domain-joined to Active Directory
- Kerberos authentication with AES256 or RC4 encryption
- See [FSLogix Profile Storage](#fslogix-profile-storage) section below for complete configuration details

**Parameter Configuration:**

```bicep
identitySolution = 'ActiveDirectoryDomainServices'
domainName = 'contoso.com'                                   // Required: Domain FQDN
domainJoinUserPrincipalName = 'svc-avd@contoso.com'          // Required (unless credentialsKeyVaultResourceId is provided)
domainJoinUserPassword = 'SecurePassword123!'                // Required (unless credentialsKeyVaultResourceId is provided)
credentialsKeyVaultResourceId = '<resourceId>'               // Optional: Key Vault with domain join credentials
vmOUPath = 'OU=AVD,OU=Computers,DC=contoso,DC=com'           // Optional: OU for session hosts
```

### Entra Domain Services

This cloud-managed domain service option provides domain services without requiring on-premises domain controllers.

**Requirements:**

- Entra Domain Services (managed domain)
- User accounts can be native to Entra Id or be synchronized from Active Directory Domain Services
- Virtual network integration with Entra Id Domain Services

**Session Host Behavior:**

- Session hosts are domain-joined to the Entra Domain Services managed domain
- Users authenticate using synchronized identities
- Managed Group Policy through Entra Id Domain Services

**FSLogix Storage:**

- Supports Azure Files only (Azure NetApp Files not supported)
- Storage accounts are domain-joined to Entra Domain Services
- See [FSLogix Profile Storage](#fslogix-profile-storage) section below for complete configuration details

**Parameter Configuration:**

```bicep
identitySolution = 'EntraDomainServices'
domainName = 'contoso.com'                                   // Required: Domain FQDN
domainJoinUserPrincipalName = 'svc-avd@contoso.com'          // Required (unless credentialsKeyVaultResourceId is provided)
domainJoinUserPassword = 'SecurePassword123!'                // Required (unless credentialsKeyVaultResourceId is provided)
credentialsKeyVaultResourceId = '<resourceId>'               // Optional: Key Vault with domain join credentials
vmOUPath = 'OU=AADDC Computers,DC=contoso,DC=com'            // Optional: OU for session hosts
```

### Entra Kerberos (Hybrid)

This hybrid approach allows session hosts to be Entra joined while still supporting traditional Active Directory user accounts for Azure Files access.

**Requirements:**

- On-premises Active Directory Domain Services
- Entra Id Connect with Password Hash Synchronization or Pass-through Authentication
- Entra Id Kerberos functionality enabled
- Optionally, network line of site from the session host vnet to the domain controller(s) so the deployment vm can:
  - Configure the domain name and domain guid in the Entra Kerberos settings
  - Apply least privilege NTFS permissions or sharding via NTFS permissions.

**Session Host Behavior:**

- Session hosts are Entra Id joined (not domain-joined)
- Users authenticate with Entra Id credentials that are synced from Active Directory
- Device management through Intune (if `intuneEnrollment = true`)

**FSLogix Storage:**

- Supports Azure Files only (Azure NetApp Files not supported)
- Storage accounts use Entra Id Kerberos authentication
- User accounts must exist in Active Directory (synchronized to Entra Id)
- See [FSLogix Profile Storage](#fslogix-profile-storage) section below for complete configuration details

> [!IMPORTANT]
> For Entra Kerberos with Hybrid Identities, this solution can automate the required App Registration updates (Private Link URIs), domain name and domain guid configuration, and admin consent, if you provide a User Assigned Managed Identity with the correct permissions.
>
> See [Entra Kerberos for Azure Files with Hybrid Identities](entraKerberosHybrid.md) for details on the required permissions and manual steps if you choose not to use the automation.

**Parameter Configuration:**

```bicep
identitySolution = 'EntraKerberos-Hybrid'
domainName = 'contoso.com'                                      // Optional: Required for sharding or least privilege NTFS
domainJoinUserPrincipalName = 'svc-avd@contoso.com'             // Optional: Required for sharding/NTFS config
domainJoinUserPassword = 'SecurePassword123!'                   // Optional: Required for sharding/NTFS config
credentialsKeyVaultResourceId = '<resourceId>'                  // Optional: Alternative to providing credentials directly
vmOUPath = 'OU=AVD,OU=Computers,DC=contoso,DC=com'              // Optional: OU for deployment VM
fslogixAppUpdateUserAssignedIdentityResourceId = '<resourceId>' // Optional: Required for automated configuration
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

**FSLogix Storage:**

- Supports Azure Files only (Azure NetApp Files not supported)
- Storage accounts use Entra Kerberos authentication
- See [FSLogix Profile Storage](#fslogix-profile-storage) section below for complete configuration details

> [!IMPORTANT]
> For Entra Kerberos with Cloud Only Identities, this solution can automate the required App Registration updates (Private Link URIs, group support tag, and admin consent), if you provide a User Assigned Managed Identity with the correct permissions.
>
>
> See [Entra Kerberos Cloud Only Support for Azure Files](entraKerberosCloudOnly.md) for details on the required permissions and manual steps if you choose not to use the automation.

**Limitations:**

- While in preview, it is only supported in Azure Commercial

**Parameter Configuration:**

```bicep
identitySolution = 'EntraKerberos-CloudOnly'
fslogixAppUpdateUserAssignedIdentityResourceId = '<resourceId>' // Optional: Required for automated configuration
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

**FSLogix Storage:**

- Supports Azure Files only (Azure NetApp Files not supported)
- Session hosts use storage account keys for authentication (no Kerberos)
- Single storage account only - no sharding or NTFS permissions
- See [FSLogix Profile Storage](#fslogix-profile-storage) section below for complete configuration details

**Parameter Configuration:**

```bicep
identitySolution = 'EntraId'
```

## FSLogix Profile Storage

This solution deploys and fully configures FSLogix profile storage, making it ready for immediate use post-deployment. Azure Files and Azure NetApp Files are the supported SMB storage services. The storage configuration varies based on your selected identity solution.

**Reference:** [FSLogix Overview - Microsoft Docs](https://docs.microsoft.com/en-us/fslogix/overview)

### Identity Solution Compatibility

FSLogix storage authentication and configuration depends on your identity solution:

| Identity Solution | Azure Files | Azure NetApp Files | Authentication Method | Sharding Support | NTFS Permissions |
|-------------------|:-----------:|:-------------------:|----------------------|------------------|------------------|
| Active Directory Domain Services | ✅ | ✅ | Kerberos (domain-joined storage) | All options | AD groups |
| Entra Domain Services | ✅ | ❌ | Kerberos (domain-joined storage) | All options | Entra DS groups |
| Entra Kerberos - Hybrid | ✅ | ❌ | Entra Kerberos | All options | AD groups (synced) |
| Entra Kerberos - Cloud Only | ✅ | ❌ | Entra Kerberos | None, ShardPerms | Entra groups |
| Entra Id (Storage Keys) | ✅ | ❌ | Storage account key | None | Not supported |

**Domain Integration Requirements:**

- **Active Directory Domain Services & Entra Domain Services**: Storage accounts/volumes are domain-joined; requires deployment VM for domain join and NTFS configuration
- **Entra Kerberos**: Storage accounts use Entra Kerberos authentication; deployment VM required only when configuring sharding or least-privilege NTFS permissions
- **Entra Id**: Storage account keys securely stored on session hosts using credential manager; no domain integration

### Container Types

FSLogix containers can be configured in multiple ways:

| Container Type | Parameter Value | Use Case |
|----------------|-----------------|----------|
| Profile Container | `ProfileContainer` | Standard user profile storage (recommended) |
| Profile & Office Container | `ProfileOfficeContainer` | Separate containers for profile and Office cache data |
| Cloud Cache Profile Container | `CloudCacheProfileContainer` | Active/active redundancy with local caching |
| Cloud Cache Profile & Office Container | `CloudCacheProfileOfficeContainer` | Cloud Cache for both profile and Office data |

**Parameter:** `fslogixContainerType`

### Sharding Options

Sharding distributes user profiles across multiple storage accounts to overcome performance or capacity limits:

| Sharding Option | Parameter Value | Description | Identity Solution Support |
|-----------------|-----------------|-------------|---------------------------|
| None | `None` | Single storage account for all users | All identity solutions |
| Sharding with Permissions | `ShardPerms` | Multiple storage accounts with group-based NTFS permissions | All except EntraId |
| Sharding with Object Specific Settings | `ShardOSS` | Multiple storage accounts using FSLogix's Object Specific Settings registry configuration | ADDS, Entra DS, Entra Kerberos Hybrid only |

**Parameter:** `fslogixShardOptions`

**Prerequisites for Sharding:**

- `fslogixUserGroups` parameter must define security groups that map users to specific storage accounts
- For domain-based identity solutions: Groups must exist in Active Directory or Entra Domain Services
- For Entra Kerberos solutions: Additional configuration via User Assigned Managed Identity (see [Entra Kerberos documentation](entraKerberosHybrid.md))

### Security Group Configuration

Define security groups that control access to FSLogix storage:

**User Groups (`fslogixUserGroups`):**

- Security groups whose members need access to FSLogix storage
- Required when using sharding or configuring least-privilege NTFS permissions
- For domain-based solutions: Use on-premises AD or Entra Domain Services group names
- For Entra Kerberos/EntraId solutions: Use Entra group names

**Admin Groups (`fslogixAdminGroups`):**

- Administrative groups that receive full control access to storage
- Optional but recommended for troubleshooting and management
- Can be AD groups, Entra DS groups, or Entra groups depending on identity solution

**Parameter Format:**

```bicep
fslogixUserGroups = [
  {
    name: 'AVD-Users-Group1'     // Group name (AD or Entra)
    id: '<guid>'                 // Entra Object Id
  }
  {
    name: 'AVD-Users-Group2'
    id: '<guid>'
  }
]

fslogixAdminGroups = [
  {
    name: 'AVD-Admins'
    id: '<guid>'
  }
]
```

### Storage Service Options

**Azure Files:**

| Service Tier | Parameter Value | Performance | Features |
|--------------|-----------------|-------------|----------|
| Premium | `AzureFiles Premium` | Up to 100,000 IOPS per share, sub-millisecond latency | SMB Multichannel automatically enabled, Zone-Redundant Storage (ZRS) support |
| Standard | `AzureFiles Standard` | Standard performance tier | Large file share option enabled |

**Azure NetApp Files:**

| Service Tier | Parameter Value | Performance | Compatibility |
|--------------|-----------------|-------------|---------------|
| Premium | `AzureNetAppFiles Premium` | Up to 450,000 IOPS | ADDS only |
| Standard | `AzureNetAppFiles Standard` | Up to 320,000 IOPS | ADDS only |

**Parameter:** `fslogixStorageService`

**Azure NetApp Files Requirements:**

- `netAppVolumesSubnetResourceId` - Subnet delegated to Microsoft.Netapp/volumes
- Active Directory connection (new or existing via `existingSharedActiveDirectoryConnection`)
- Appropriate capacity pool sizing
- Only supported with Active Directory Domain Services identity solution

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

### Deployed Resources

**Storage Resources:**

- Azure Storage Account(s) with Azure Files shares (quantity depends on sharding configuration)
  - OR -
- Azure NetApp Account with Capacity Pool and Volume(s)
- Private Endpoints for secure access (optional)
- Encryption with customer-managed keys (optional)

**Configuration Resources:**

- Deployment Virtual Machine (for domain join operations and NTFS configuration)
  - Network Interface and OS Disk
  - Automatically removed after configuration is complete
- User Assigned Managed Identity
  - For Entra Kerberos: Can automate App Registration configuration via Microsoft Graph
  - For customer-managed keys: Access to Key Vault

**Management Resources (Azure Files Premium only):**

- Function App for automatic quota increase management
- App Service Plan, Application Insights, and metadata storage account

**Backup Resources (optional):**

- Recovery Services Vault with Backup Policy
- Protected Item configuration for each file share

## GPU Drivers & Settings

When an appropriate VM size (Nv, Nvv3, Nvv4, or NCasT4_v3 series) is selected, this solution will automatically deploy the appropriate virtual machine extension to install the graphics driver and configure the recommended registry settings.

**Reference:** [Configure GPU Acceleration - Microsoft Docs](https://docs.microsoft.com/en-us/azure/virtual-desktop/configure-vm-gpu)

**Deployed Resources:**

- Virtual Machines Extensions
  - AmdGpuDriverWindows
  - NvidiaGpuDriverWindows
  - CustomScriptExtension

## Resiliency

This solution provides multiple layers of resiliency to ensure high availability and disaster recovery capabilities for your Azure Virtual Desktop environment. These features work together to protect against infrastructure failures, regional outages, and data loss.

### Availability Zones and Availability Sets

Deploy session hosts across Availability Zones or Availability Sets to provide infrastructure-level redundancy and higher SLAs. This feature is available for "pooled" host pools where load balancing distributes users across multiple session hosts.

**Availability Options:**

- **Availability Zones**: Physically separate datacenters within an Azure region (SLA: 99.99%)
- **Availability Sets**: Logical grouping to protect against rack-level failures (SLA: 99.95%)
- **No Redundancy**: Single virtual machine deployment (SLA: 99.9% with Premium SSD)

**Reference:** [Availability options for Azure Virtual Machines](https://docs.microsoft.com/en-us/azure/virtual-machines/availability)

**Parameter Configuration:**

```bicep
availability = 'availabilityZones'         // Deploy across availability zones
availabilityZones = ['1', '2', '3']        // Use zones 1, 2, and 3
// OR
availability = 'availabilitySets'          // Deploy to availability sets
// OR  
availability = 'None'                      // No infrastructure redundancy
```

**Deployed Resources:**

- Availability Set(s) (when using availability sets)
- Virtual machines distributed across zones or availability sets

### Zone Redundant Storage

Zone-Redundant Storage for FSLogix is automatically configured based on the availability setting. When you deploy session hosts across availability zones, the FSLogix storage accounts are automatically configured with Zone-Redundant Storage (ZRS) to match the compute redundancy, protecting user profile data against datacenter-level failures.

**Storage Redundancy Behavior:**

- **availability = 'availabilityZones'**: Storage accounts use Zone-Redundant Storage (ZRS)
- **availability = 'availabilitySets' or 'None'**: Storage accounts use Locally-Redundant Storage (LRS)

**Storage Service Options:**

- **'AzureFiles Premium'**: Premium file shares with ZRS or LRS based on availability setting
- **'AzureFiles Standard'**: Standard file shares with large file share option
- **'AzureNetAppFiles Premium'**: Azure NetApp Files with premium tier (450,000 IOPS)
- **'AzureNetAppFiles Standard'**: Azure NetApp Files with standard tier (320,000 IOPS)

**Reference:** [Azure Storage redundancy](https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy)

**Parameter Configuration:**

```bicep
availability = 'availabilityZones'              // Automatically enables ZRS for storage
fslogixStorageService = 'AzureFiles Premium'    // Storage service and tier
```

**Benefits:**

- Automatic failover between availability zones
- No data loss during zone failures
- No user impact during zone maintenance
- Complements availability zones for session hosts

### FSLogix Cloud Cache

Configure FSLogix Cloud Cache to enable local caching of user profiles with synchronization to cloud storage. This provides improved performance and resilience by maintaining a local copy of profile data while asynchronously syncing to Azure Storage or Azure NetApp Files.

**Cloud Cache Benefits:**

- Reduced latency for profile operations (local disk performance)
- Continued operation during temporary storage connectivity issues
- Automatic synchronization when connectivity is restored
- Support for multiple storage locations as redundancy targets

**Reference:** [FSLogix Cloud Cache](https://learn.microsoft.com/en-us/fslogix/concepts-container-types#cloud-cache)

**Parameter Configuration:**

```bicep
fslogixContainerType = 'CloudCacheProfileContainer'             // Profile containers with Cloud Cache
// OR
fslogixContainerType = 'CloudCacheProfileOfficeContainer'       // Profile + Office containers with Cloud Cache
```

**Available Container Types:**

- `ProfileContainer` - FSLogix Profile Container (standard)
- `ProfileOfficeContainer` - FSLogix Profile & Office Container (standard)
- `CloudCacheProfileContainer` - FSLogix Cloud Cache Profile Container
- `CloudCacheProfileOfficeContainer` - FSLogix Cloud Cache Profile & Office Container

**Deployment Considerations:**

- Requires additional local disk space for cache (minimum 20GB per user)
- Configure cache location on high-performance local disk (preferably SSD)
- Monitor cache sync status and disk space usage

### Multi-Region Redundancy

Configure FSLogix to use storage accounts in multiple Azure regions, providing geographic redundancy and disaster recovery capabilities. This is achieved through the FSLogix Cloud Cache feature combined with multi-region storage account deployments.

**Multi-Region Patterns:**

**Active-Passive Configuration:**

- Deploy session hosts in primary region pointing to primary storage
- Deploy storage account in secondary region for disaster recovery
- Use Cloud Cache container types to support multiple storage locations
- FSLogix automatically failover to secondary if primary is unavailable

**Active-Active Configuration:**

- Deploy session hosts in multiple regions
- Each region has its own storage accounts
- Cloud Cache can synchronize across regions
- Users can connect to either region seamlessly
- Use Azure Front Door or Traffic Manager for global load balancing

**Reference:** [Multi-region FSLogix configuration](https://learn.microsoft.com/en-us/fslogix/concepts-container-storage-options)

**Implementation Approach:**

1. **Deploy Host Pools in Multiple Regions**: Use separate host pool deployments for each region with the same `identifier` parameter
2. **Enable Cloud Cache**: Set `fslogixContainerType = 'CloudCacheProfileContainer'` or `'CloudCacheProfileOfficeContainer'`
3. **Configure Multiple Storage Locations**: Session hosts are configured to point to storage accounts in both regions through FSLogix registry settings
4. **Network Connectivity**: Ensure virtual network connectivity between regions (peering or virtual WAN)

**Example Multi-Region Deployment:**

**Region 1 (Primary) - East US:**

```bicep
identifier = 'finance'
availability = 'availabilityZones'
availabilityZones = ['1', '2', '3']
fslogixContainerType = 'CloudCacheProfileContainer'
fslogixStorageService = 'AzureFiles Premium'
fslogixExistingRemoteStorageAccountResourceIds = [           // Reference primary region storage
  '/subscriptions/.../resourceGroups/rg-finance-01-storage-usw/providers/Microsoft.Storage/storageAccounts/stfinance01usw'
]
deployFSLogixStorage = true                                   // Deploy storage in primary region
controlPlaneLocation = 'eastus'
```

**Region 2 (Secondary) - West US:**

```bicep
identifier = 'finance'
availability = 'availabilityZones'
availabilityZones = ['1', '2', '3']
fslogixContainerType = 'CloudCacheProfileContainer'
fslogixStorageService = 'AzureFiles Premium'
deployFSLogixStorage = true                                   // Deploy storage in secondary region
fslogixExistingRemoteStorageAccountResourceIds = [           // Reference primary region storage
  '/subscriptions/.../resourceGroups/rg-finance-01-storage-use/providers/Microsoft.Storage/storageAccounts/stfinance01use'
]
controlPlaneLocation = 'westus'
```

**Session Host Configuration:**
FSLogix session hosts in each region are configured via registry to use both local and remote storage locations. The Cloud Cache type automatically handles synchronization and failover between the locations. The `fslogixExistingRemoteStorageAccountResourceIds` parameter adds the remote region's storage account to the FSLogix configuration.

**Deployment Considerations:**

- Plan for network latency between regions when accessing remote storage
- Use Azure Front Door or Traffic Manager for global load balancing to route users to nearest region
- Consider costs of cross-region data transfer and storage replication
- Implement monitoring for failover detection and alerting
- Test disaster recovery procedures regularly
- Ensure adequate bandwidth between regions for Cloud Cache synchronization

### Resiliency Best Practices

**Compute Layer:**

1. Use availability zones for production workloads when available in your region
2. Deploy sufficient session hosts per zone to handle zone failure (N+1 or N+2)
3. Use Azure Site Recovery for disaster recovery of personal host pools

**Storage Layer:**

1. Enable Zone-Redundant Storage (ZRS) for FSLogix storage accounts
2. Configure Cloud Cache for improved performance and temporary resilience
3. Implement multi-region storage for critical workloads
4. Enable backup for Azure Files shares using Azure Backup

**Network Layer:**

1. Use redundant connectivity paths between on-premises and Azure
2. Deploy Azure Firewall or Network Virtual Appliances in HA configuration
3. Configure DNS for failover between regions

**Monitoring:**

1. Set up Azure Monitor alerts for zone failures
2. Monitor FSLogix Cloud Cache sync status
3. Track storage account availability metrics
4. Implement health probes for session hosts

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

**Deployed Resources:**

- Scaling Plan with schedule configuration
- Role assignment for scaling plan to manage host pool

## Customer Managed Keys for Encryption

This optional feature deploys the required resources & configuration to enable virtual machine managed disk encryption on the session hosts using a customer managed key. The configuration also enables double encryption which uses a platform managed key in combination with the customer managed key. The FSLogix storage account can also be encrypted using Customer Managed Keys.

**Reference:** [Azure Server-Side Encryption - Microsoft Docs](https://learn.microsoft.com/azure/virtual-machines/disk-encryption)

**Deployed Resources:**

- Key Vault
  - Key Encryption Key (1 per host pool for VM disks, 1 for each fslogix storage account)
- Disk Encryption Set

## SMB Multichannel

This feature is automatically enabled when Azure Files Premium is selected for FSLogix storage. SMB Multichannel allows multiple network connections from each session host to the SMB share, significantly improving throughput for large files.

**Automatic Enablement:**

- Only supported with Azure Files Premium (`fslogixStorageService = 'AzureFiles Premium'`)
- No additional configuration required
- Multiple connections established automatically between session hosts and storage

**Reference:** [SMB Multichannel Performance - Microsoft Docs](https://docs.microsoft.com/en-us/azure/storage/files/storage-files-smb-multichannel-performance)

## Start VM On Connect

This optional feature allows end users to automatically start a deallocated session host when attempting to connect. When all session hosts are stopped/deallocated, the first user attempting to access a resource triggers an automatic start of an available session host.

**Benefits:**

- Reduces compute costs by allowing session hosts to remain deallocated during off-hours
- Complements AutoScale by ensuring availability on-demand
- Transparent to end users - slight delay while VM starts, then normal connection

**Reference:** [Start VM On Connect - Microsoft Docs](https://docs.microsoft.com/en-us/azure/virtual-desktop/start-virtual-machine-connect?tabs=azure-portal)

**Deployed Resources:**

- Role assignment (Desktop Virtualization Power On Contributor) on host pool
- Host pool configuration enabling Start VM On Connect

## Trusted Launch

Trusted Launch provides foundational security for virtual machines with secure boot and virtual Trusted Platform Module (vTPM) capabilities. This feature is automatically enabled when supported by the selected VM image and size.

**Automatic Enablement Conditions:**

- Generation 2 ("g2") image SKU is selected
- VM size supports Trusted Launch
- Secure Boot and vTPM automatically configured

**Security Protection:**

Trusted Launch protects virtual machines from:

- Boot kits
- Rootkits
- Kernel-level malware

**Reference:** [Trusted Launch - Microsoft Docs](https://docs.microsoft.com/en-us/azure/virtual-machines/trusted-launch)

**Deployed Resources:**

- Virtual machines with Trusted Launch configuration
- Guest Attestation extension for attestation reporting

## Confidential VMs

Azure confidential VMs provide hardware-based trusted execution environments (TEE) that protect data in use. They create a hardware-enforced boundary between your application and the virtualization stack, ensuring the VM's state remains protected even from the hypervisor.

**Key Features:**

- Hardware-enforced isolation using AMD SEV-SNP or Intel TDX
- Memory encryption with VM-specific keys
- Support for cloud migration without code modifications
- Compatible with existing applications and workloads

**Reference:** [Confidential Virtual Machines - Microsoft Docs](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-overview)

**Deployed Resources:**

- Azure Key Vault Premium with HSM-protected keys
- Disk Encryption Set for confidential disk encryption
- Virtual machines with confidential computing capabilities

## IL5 Isolation

Azure Government supports applications that use Impact Level 5 (IL5) data in all available regions. IL5 requirements are defined in the US Department of Defense (DoD) Cloud Computing Security Requirements Guide (SRG). IL5 workloads require a higher degree of security controls than IL4.

**IL5 Requirements:**

When deploying to Azure Government IL4 regions (Arizona, Texas, Virginia), you can meet IL5 isolation requirements through:

1. **Dedicated Hosts**: Deploy virtual machines to dedicated physical servers
2. **HSM-Protected Keys**: Use customer-managed keys stored in Azure Key Vault Premium with FIPS 140 Level 3 validated Hardware Security Modules

**Prerequisites:**

- At least one dedicated host deployed in a dedicated host group in an Azure Government region
- See: [Azure Dedicated Hosts documentation](https://learn.microsoft.com/en-us/azure/virtual-machines/dedicated-hosts)

**Reference:** [Azure Government isolation guidelines for Impact Level 5](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-impact-level-5)

**Deployed Resources:**

- Azure Key Vault Premium (1 per host pool for VM disks)
  - Customer-managed keys protected by HSM with auto-rotation
- Disk Encryption Set for VM disk encryption
- Azure Key Vault Premium (1 per FSLogix storage account)
  - Customer-managed keys protected by HSM with auto-rotation
- Virtual machines deployed to dedicated hosts

**Parameter Reference:** For example parameter values, see [IL5 Isolation Requirements on IL4](parameters.md#il5-isolation-requirements-on-il4)

## Backups

This optional feature enables backups to protect user profile data. When selected, if the host pool is "pooled" and the storage solution is Azure Files, the solution will protect the file share. If the host pool is "personal", the solution will protect the virtual machines.

**Reference:** [Azure Backup - Microsoft Docs](https://docs.microsoft.com/en-us/azure/backup/backup-overview)

**Deployed Resources:**

- Recovery Services Vault
- Backup Policy
- Protection Container (File Share Only)
- Protected Item