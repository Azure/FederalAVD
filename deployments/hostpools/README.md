# AVD Host Pool Deployment Template

> **📖 User Guide:** For deployment instructions and step-by-step guidance, see the [Host Pool Deployment Guide](../../docs/hostpool-deployment.md)
>
> **Script Reference:** See [Standard Host Pool PowerShell Scripts](scripts/README.md) for
> solution-owned scripts and links to the shared script reference.
>
> **First deployment:** Use the Host Pool Template Spec portal form. On **Review + create**, select
> **Create**, then download the generated template and parameters after submission. Use the
> PowerShell and parameter examples below for subsequent deployments, or as a fallback when the
> Template Spec UI is unavailable.

This template uses Azure Virtual Desktop **standard management**. You own session-host creation,
registration, update, and replacement. Compare it with the Commercial-only
[automated host pool](../automatedHostPools/README.md) before deployment; the management approach
can't be changed later. See the [management decision guide](../../docs/host-pool-management.md).

## Overview

`hostpool.bicep` is the standard host-pool entry orchestrator. It calls AVD Shared Services and
then directly composes the pool-specific control plane, FSLogix, session-host, security, backup,
and monitoring modules. The published entry template is `deployments/hostpools/hostpool.json`.

The orchestrator deploys a complete Azure Virtual Desktop (AVD) environment including host pools,
session hosts, storage, monitoring, security, and operational automation. It supports multiple
identity scenarios, Zero Trust architecture, and air-gapped cloud environments.

New workspaces use shared, region-level naming by default. The dedicated
[AVD Standard PoC](../hostpoolPoc/README.md) entry template separately composes the same lower-level
workspace, control-plane, storage, and session-host modules with host-pool-specific naming and a
fixed evaluation posture. The production orchestrator creates a shared workspace or selects one
with `existingFeedWorkspaceResourceId`. It appends only its application-group reference and
preserves the workspace's other references and properties. Shared Services manages an existing
workspace's public access and feed/global Private Link only when those options are explicitly
selected; otherwise those settings are preserved.

The dedicated PoC orchestrator creates its VNet, private subnet, NSG, NAT Gateway, Standard public
IP, and persistent AVD resources in one consolidated resource group. The production host-pool
template retains its normal separate resource-group model. When the deployment-helper VM is
required, its temporary resource group remains separate because the deployment removes that entire
resource group during cleanup. Entra ID cloud-only Azure Files deployments that use
storage-account-key authentication skip the helper and NTFS ACL step.

The Standard PoC is a disposable demonstration environment and intentionally omits production
capacity, availability, scaling, backup, private connectivity, encryption, and operational design
choices. Tear it down after the demonstration or first-step validation. Do not expand, harden,
reuse, or promote it into a pilot or production environment. Start a new pilot or production
deployment with the complete form and production parameters.

> **Shared workspace deployment concurrency:** Deploy host pools that register application groups
> to the same workspace serially. Registration is a read-modify-write update of the workspace
> application-group reference list, so concurrent deployments can overwrite one another.

## Desktop and application-group friendly names

When `desktopFriendlyName` is supplied, the standard deployment uses it for both
the desktop application group's friendly name and the published `SessionDesktop`
friendly name, matching the automated host-pool behavior. This does not change
the application group's Azure resource name or ID. An empty value leaves the
application-group friendly name unset and skips the desktop-name update.

## Purpose

Deploy production-ready AVD environments with:

- **Shared Services** - Workspace, feed/global Private Link, monitoring, Key Vaults, and shared
  FSLogix backup resources
- **Host-Pool Core** - Host pool, application group, pool connection endpoint, scaling, storage,
  encryption consumers, and session hosts
- **Session Hosts** - Virtual machines with AVD agents and customizations
- **Storage** - FSLogix profile storage with RBAC or Kerberos authentication
- **Monitoring** - Log Analytics, Azure Monitor, AVD Insights, diagnostic settings
- **Security** - Private endpoints, managed identities, encryption, Key Vault integration
- **Automation** - Auto-increase premium file share quota, session host lifecycle management
- **Networking** - Virtual network integration, private endpoints, NSG configurations

## Architecture

### Resource Deployments

The entry orchestrator deploys resources across multiple resource groups. Shared Services owns the
shared-resource groups and the host-pool-specific modules own the pool-specific groups:

```text
Subscription
├── Control Plane Resource Group
│   ├── Host Pool
│   ├── Desktop Application Group
│   ├── Scaling Plan (optional)
│   └── Private Endpoint (Host Pool connection, optional)
├── Shared AVD Control Plane Resource Group
│   ├── Workspace
│   └── Private Endpoint (Workspace feed, optional)
├── Global Feed Resource Group (optional)
│   ├── Global-feed Workspace
│   └── Private Endpoint (Global feed)
├── Session Hosts Resource Group
│   ├── Virtual Machines
│   ├── Network Interface Cards
│   ├── OS Disks
│   ├── Availability Set (optional)
│   ├── Disk Encryption Set (optional, Customer Managed Keys)
│   ├── Disk Access (optional, Personal host pool with private endpoints)
│   ├── Private Endpoint (Disk Access, optional)
│   ├── Recovery Services Vault (optional, Personal host pool VM backup)
│   ├── VM Backup Policy (optional, Personal host pool VM backup)
│   └── Private Endpoint (Recovery Services Vault, optional)
├── Operations Resource Group
│   ├── Key Vaults (secrets, encryption)
│   ├── Private Endpoints (Key Vaults, optional)
│   ├── Recovery Services Vault (optional, Shared Services-owned pooled FSLogix backup)
│   ├── File Share Backup Policy (optional, Shared Services-owned pooled FSLogix backup)
│   ├── Backup Protection Items (Storage Accounts / File Shares, optional)
│   └── Private Endpoint (Recovery Services Vault, optional)
├── Storage Resource Group
│   ├── Azure NetApp Files Account (optional)
│   ├── Capacity Pool (optional)
│   ├── Volumes (optional)
│   ├── Storage Account(s) for FSLogix profiles
│   ├── Azure Files Shares
│   ├── Private Endpoint(s) (Storage, optional)
│   └── RBAC Assignments or Kerberos Configuration
└── Monitoring Resource Group (optional)
    ├── Log Analytics Workspace
    ├── Data Collection Rules (AVD Insights — session host logs and performance counters)
    └── Data Collection Endpoint
```

## Key Features

### Identity Solutions

| Solution | Description | Domain Join | User Accounts |
| --- | --- | --- | --- |
| **ActiveDirectoryDomainServices** | Traditional AD DS | AD DS | AD DS |
| **EntraDomainServices** | Azure AD DS | Azure AD DS | Azure AD or AD DS |
| **EntraKerberos-Hybrid** | Hybrid Entra ID with Kerberos | Entra ID | AD DS (synced) |
| **EntraKerberos-CloudOnly** | Cloud-only Entra with Kerberos | Entra ID | Entra ID |
| **EntraId** | Pure cloud Entra join | Entra ID | Entra ID |

### Storage Solutions

- **Azure Files** - SMB shares for FSLogix profiles
- **Azure NetApp Files** - High-performance NFS/SMB for large deployments (1000+ users)
- **Authentication:** RBAC, Kerberos, or AD DS integration
- **Encryption:** At-rest encryption with customer-managed keys (optional)
- **Private Endpoints:** Zero Trust network isolation

### Session Host Customizations

- **Custom Script Extension** - Run PowerShell scripts during deployment
- **Custom Image** - Deploy from Azure Compute Gallery
- **Marketplace Image** - Deploy from Azure Marketplace
- **Trusted Launch** - Enhanced security with vTPM and Secure Boot
- **Confidential VMs** - Hardware-based isolation and encryption
- **Hibernation** - Fast startup for persistent VDI

### Monitoring & Operations

- **Azure Monitor** - AVD Insights data collection rules, performance counters, Windows Event logs
- **Data Collection Rules** - Centralized log collection configuration
- **Storage Quota Automation** - Auto-increase Azure Files quota when threshold reached
- **Session Host Replacer** - Automated session host lifecycle management (add-on)

### Security Features

- **Private Endpoints** - Storage, Key Vault, Workspace, Automation Account
- **Customer-Managed Keys** - Disk encryption, storage encryption
- **Recovery Services CMK** - When CMK is enabled for Recovery Services vault creation the vault uses its own **System-Assigned Identity (SAI)**. The encryption key is host-pool-scoped (name: `{hpBaseName}-encryption-key-rsv`) — each personal host pool's vault has its own dedicated key, consistent with VM disk and storage key treatment. No user-assigned identity is created for RSV.
- **Managed Identities** - No stored credentials for Azure service access
- **Key Vault Integration** - Secrets management for credentials
- **Disk Encryption Sets** - Centralized key management for VM disks

## Prerequisites

### Required Information

1. **Identity Configuration**
   - Identity solution choice (Entra ID, AD DS, hybrid)
   - Domain name and OU path (if using domain services)
   - Domain join credentials (if using domain services)

2. **Networking**
   - Virtual network resource ID
   - Subnet resource ID for session hosts
   - Private endpoint subnet (for Zero Trust)

3. **Compute**
   - VM size (e.g., `Standard_D4ads_v6`)
   - VM count
   - Availability zone preferences

4. **Storage**
   - Storage solution (Azure Files or Azure NetApp Files)
   - Storage account SKU (if Azure Files)
   - ANF service level (if Azure NetApp Files)

### Optional Prerequisites

- **Custom Image Resource ID** (for custom images)
- **Log Analytics Workspace** (for existing monitoring)
- **Key Vault** (for customer-managed keys)
- **Private DNS Zones** (for private endpoints)

## Parameters

### Core Deployment Settings

#### `identifier`

- **Type:** String (max 9 chars)
- **Required:** Yes
- **Description:** Persona identifier for host pool naming
- **Example:** `finance`, `callctr`, `dev`

#### `index`

- **Type:** Integer (0-99)
- **Default:** `-1` (no index)
- **Description:** Index for sharding host pools with same persona

#### `namingConvention`

- **Type:** Object
- **Default:** CAF-aligned (`resourceType-workload-purpose-location`)
- **Description:** Controls how every resource in the deployment is named. Leave at its default for CAF-compliant names. Pass the same object to all solutions (sharedServices, imageManagement, hostpool) for a consistent enterprise naming convention. See the **[Naming Convention guide](../../docs/naming-convention.md)** for the full parameter schema, segment descriptions, and cross-solution examples.

### Identity & Authentication

#### `identitySolution`

- **Type:** String
- **Required:** Yes
- **Allowed Values:**
  - `ActiveDirectoryDomainServices`
  - `EntraDomainServices`
  - `EntraKerberos-Hybrid`
  - `EntraKerberos-CloudOnly`
  - `EntraId`

#### `virtualMachineAdminUserName`

- **Type:** String (secure)
- **Required:** Yes
- **Description:** Local administrator username

#### `virtualMachineAdminPassword`

- **Type:** String (secure)
- **Required:** Yes
- **Description:** Local administrator password

#### `domainJoinUserPrincipalName`

- **Type:** String (secure)
- **Required when:** Using domain services
- **Description:** UPN for domain join account

#### `domainJoinUserPassword`

- **Type:** String (secure)
- **Required when:** Using domain services
- **Description:** Password for domain join account

#### `domainName`

- **Type:** String
- **Required when:** Using domain services
- **Description:** FQDN of domain
- **Example:** `contoso.com`

#### `vmOUPath`

- **Type:** String
- **Optional**
- **Description:** OU path for session hosts
- **Example:** `OU=AVD,OU=Computers,DC=contoso,DC=com`

### Control Plane

#### `controlPlaneLocation`

- **Type:** String
- **Default:** Subscription deployment location
- **Description:** Location for control plane resources
- **Example:** `eastus2`, `usgovvirginia`

#### `virtualMachinesLocation`

- **Type:** String
- **Default:** `controlPlaneLocation`
- **Description:** Location for session hosts, storage, deployment helpers and
  their centralized names. Must match the session-host subnet's VNet location.
  The Portal passes its selected VM location explicitly.
- **Validation:** Set both locations explicitly for split-location deployments;
  empty strings are invalid.
  See [location validation](../../docs/hostpool-deployment.md#explicit-deployment-locations).

#### `hostPoolType`

- **Type:** String
- **Allowed:** `Pooled`, `Personal`
- **Default:** `Pooled`
- **Description:** Host pool type

#### `loadBalancerType`

- **Type:** String
- **Allowed:** `BreadthFirst`, `DepthFirst`, `Persistent`
- **Default:** `BreadthFirst`
- **Description:** Load balancing algorithm (Pooled only)

#### `maxSessionLimit`

- **Type:** Integer
- **Default:** `12`
- **Description:** Maximum sessions per session host (Pooled only)

#### `validationEnvironment`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Enable validation environment (early features)

#### `startVMOnConnect`

- **Type:** Boolean
- **Default:** `true`
- **Description:** Enables the Start VM on Connect feature so deallocated session hosts are powered on when a user connects

### Session Hosts

#### `virtualMachineSize`

- **Type:** String
- **Required:** Yes
- **Description:** Azure VM size
- **Example:** `Standard_D4ads_v5`, `Standard_E4as_v5`

#### `virtualMachineCount`

- **Type:** Integer
- **Required:** Yes
- **Description:** Number of session hosts to deploy
- **Example:** `5`, `10`, `50`

#### `virtualMachineNamePrefix`

- **Type:** String (max 11 chars)
- **Required:** Yes
- **Description:** Prefix for VM names
- **Example:** `avd-vm-`

#### `availabilityZones`

- **Type:** Array
- **Optional**
- **Description:** Availability zones for VMs
- **Example:** `["1", "2", "3"]`

#### `virtualMachineSubnetResourceId`

- **Type:** String
- **Required:** Yes
- **Description:** Existing subnet resource ID for session hosts

#### `customImageLicenseType`

- **Type:** String
- **Allowed:** `Windows_Client`, `Windows_Server`
- **Default:** `Windows_Client`
- **Description:** License type applied to session hosts when deploying from a custom/gallery image (`customImageResourceId`). Ignored for marketplace images, where license type is determined automatically from `imagePublisher`. In the portal UI, this defaults dynamically from the selected image definition's `sourceImagePublisher` tag (set by the Image Build deployment) when available.

### Storage

#### `fslogixStorageService`

- **Type:** String
- **Allowed:** `AzureFiles Standard`, `AzureFiles Premium`, `AzureNetAppFiles Standard`, `AzureNetAppFiles Premium`
- **Default:** `AzureFiles Standard`
- **Description:** Storage solution and performance tier for FSLogix profiles.

#### `fslogixStorageRedundancy`

- **Type:** String (Azure Files only)
- **Allowed:** `LocallyRedundant`, `ZoneRedundant`
- **Default:** `LocallyRedundant`
- **Description:** Redundancy for newly created Azure Files storage accounts used by FSLogix. The
  Portal form defaults this to `ZoneRedundant` when session hosts use Availability Zones and warns
  if the operator overrides it to `LocallyRedundant`. Direct Bicep and parameter-file deployments
  retain the `LocallyRedundant` parameter default.

#### `keyManagementStorage`

- **Type:** String
- **Allowed:** `PlatformManaged`, `CustomerManaged`, `CustomerManagedHSM`
- **Default:** `PlatformManaged`
- **Description:** Key management mode for Azure Files (FSLogix) storage account encryption.

#### `keyManagementRecoveryServicesVault`

- **Type:** String
- **Allowed:** `PlatformManaged`, `CustomerManaged`, `CustomerManagedHSM`
- **Default:** `PlatformManaged`
- **Description:** Key management mode for Recovery Services Vault encryption.

#### `fslogixShareSizeInGB`

- **Type:** Integer
- **Default:** `100`
- **Description:** Azure Files share quota in GB

#### `fslogixStorageIndex`

- **Type:** Integer
- **Default:** `1`
- **Description:** Starting index for created FSLogix storage accounts.

#### `fslogixOUPath`

- **Type:** String
- **Optional**
- **Description:** OU path used when joining FSLogix storage resources to AD DS.

#### `netAppVolumesSubnetResourceId`

- **Type:** String (Azure NetApp Files only)
- **Optional**
- **Description:** Subnet resource ID delegated to `Microsoft.NetApp/volumes`.

### Monitoring

#### `monitoringResourceGroupName`

- **Type:** String
- **Description:** Resource group for Log Analytics workspace

#### `enableMonitoring`

- **Type:** Boolean
- **Default:** `true`
- **Description:** Deploy AVD Insights monitoring resources (Log Analytics workspace, AVD Insights DCR, Data Collection Endpoint) and associate session hosts with the DCR.

#### `logAnalyticsWorkspaceResourceId`

- **Type:** String
- **Description:** Existing Log Analytics workspace resource ID. When provided together with the existing DCR and DCE resource IDs, the deployment reuses these resources instead of creating new ones.

#### `existingAVDInsightsDataCollectionRuleResourceId`

- **Type:** String
- **Optional**
- **Description:** Resource ID of an existing AVD Insights Data Collection Rule. When provided along with `logAnalyticsWorkspaceResourceId` and `existingDataCollectionEndpointResourceId`, the deployment skips creating monitoring resources.

#### `existingDataCollectionEndpointResourceId`

- **Type:** String
- **Optional**
- **Description:** Resource ID of an existing Data Collection Endpoint associated with the existing monitoring workspace.

### Backup

#### `recoveryServices`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Enable Azure Backup. For pooled host pools this backs up the Azure Files share; for personal host pools this backs up the session host VM disks.

#### `recoveryServicesVaultStorageRedundancy`

- **Type:** String
- **Allowed:** `LocallyRedundant`, `ZoneRedundant`, `GeoRedundant`
- **Default:** `LocallyRedundant`
- **Description:** Storage redundancy for backup recovery points in the Recovery Services vault. Independent of storage account SKU. When set to `GeoRedundant`, Cross-Region Restore (CRR) is automatically enabled — no separate parameter is needed. GRS storage costs the same whether CRR is on or off; without CRR the geo-redundant copy provides passive data durability only with no recovery capability in the secondary region. See [bcdr.md](../../docs/bcdr.md#personal-host-pool-vm-backup) for CP-6/CP-7 mapping and the Azure Policy gap note.

#### `existingVmBackupVaultResourceId`

- **Type:** String
- **Optional**
- **Description:** Resource ID of an existing Recovery Services vault for personal host-pool VM backup.

#### `existingFilesBackupVaultResourceId`

- **Type:** String
- **Optional**
- **Description:** Resource ID of the shared Recovery Services vault for pooled FSLogix Azure Files backup. Use the `fslogixBackupVaultResourceId` output from AVD Shared Services. When empty and backup is selected, the entry orchestrator asks its Shared Services phase to create the shared vault and policy.

#### `existingFilesBackupPolicyName`

- **Type:** String
- **Default:** `filesharepolicy`
- **Description:** Name of the Azure Files snapshot backup policy already present in `existingFilesBackupVaultResourceId`. Use the `fslogixBackupPolicyName` output from AVD Shared Services. Host-pool deployments register their shares but do not modify an existing shared policy.

#### `backupRetentionDays`

- **Type:** Integer
- **Default:** `30`
- **Allowed:** `1` through `365`
- **Description:** Retention used when this host-pool deployment creates a VM backup policy or asks its Shared Services phase to create the FSLogix vault and policy. Ignored for an existing shared FSLogix vault because AVD Shared Services owns that policy.

### Networking

The standard and automated host-pool forms use separate **Enable PaaS Private DNS Zone
Integration** and **Enable AVD Private DNS Zone Integration** checkboxes. PaaS controls appear
only for resources this deployment creates. Azure Files DNS requires new pooled FSLogix Azure
Files storage. Key Vault DNS appears for a new credentials or encryption vault; adopting an
encryption vault does not hide DNS for a new credentials vault.

Backup and Queue DNS selectors require a new backup vault: either a Personal VM backup vault
or a pooled FSLogix backup vault for new Azure Files storage. Personal VM backup also creates
Disk Access, so its private-endpoint subnet and Blob DNS selector remain available even when
adopting an existing backup vault. Existing backup-vault endpoints are not reconfigured.

AVD DNS remains independent of PaaS DNS. **AVD Connection and Feed Private DNS Zone** serves remote
session connections and workspace feed downloads when selected. The global-feed DNS selector
appears only for `All` routes when no existing global-feed workspace is detected. Disabling DNS
integration emits no zone IDs for that endpoint group. Hidden inactive PaaS selections do not
submit endpoint flags, subnets, or DNS zone IDs.

#### `permittedIPs`

- **Type:** Array
- **Optional**
- **Description:** Public IP/CIDR allowlist for newly deployed Azure Files storage and Key Vaults.
  Rules are retained when public access is Disabled and do not enable it. Existing trusted-service
  exceptions remain configured.
- **Example:** `["203.0.113.10", "198.51.100.0/24"]`

#### `paasPublicNetworkAccess`

- **Default:** `Auto` derives public access from private endpoint selection and IP rules.
- **Explicit values:** `Disabled`, `EnabledWithRestrictions`, `Enabled`.
- **Scope:** One choice for newly deployed Azure Files storage and Key Vaults, independent of
  private endpoint creation. It does not configure adopted resources, backup vaults, monitoring or
  AVD access settings. Restricted mode denies unmatched traffic even with an empty IP list.
- **Portal:** Exposes the three explicit choices, initially Disabled with private endpoints and
  Enabled otherwise. IP rules can be staged in Disabled mode.
- **Exceptions:** Existing `AzureServices` bypass remains configured and can still apply when public
  access is Disabled; see the [shared access-mode contract](../../docs/parameters.md#paas-public-network-access).

### Security & Encryption

#### `deploySecretsKeyVault`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Ask the entry orchestrator's shared-capability phase to deploy a Secrets Key Vault (Standard SKU) for VM admin and domain-join credentials. Configured in the **Identity → Credentials** portal step when credentials source is set to Manual Entry. Leave `false` to provide `existingCredentialsKeyVaultResourceId` from an enterprise Shared Services deployment.

#### `secretsKeyVaultEnableSoftDelete`

- **Type:** Boolean
- **Default:** `true`
- **Description:** Enable soft delete on the Secrets Key Vault created by the orchestrator's Shared Services phase. Allows recovery of deleted objects within the retention period.

#### `secretsKeyVaultEnablePurgeProtection`

- **Type:** Boolean
- **Default:** `true`
- **Description:** Enable purge protection on the Secrets Key Vault created by the orchestrator's Shared Services phase. Prevents permanent deletion during the retention period.

#### `secretsKeyVaultRetentionInDays`

- **Type:** Integer (7–90)
- **Default:** `90`
- **Description:** Soft-delete retention period in days for the Secrets Key Vault created by the orchestrator's Shared Services phase.

#### `encryptionKeyVaultRetentionInDays`

- **Type:** Integer (7–90)
- **Default:** `90`
- **Description:** Soft-delete retention period in days for the Encryption Key Vault created by the orchestrator's Shared Services phase. Configured in **Zero Trust → Encryption Key Management** when CMK is enabled and no existing KV is provided.

#### `encryptionAtHost`

- **Type:** Boolean
- **Default:** `true`
- **Description:** Enable encryption at host for session host VMs.

#### `keyManagementDisks`

- **Type:** String
- **Default:** `PlatformManaged`
- **Description:** Session host disk key-management mode.

#### `securityType`

- **Type:** String
- **Allowed:** `Standard`, `TrustedLaunch`, `ConfidentialVM`
- **Default:** `TrustedLaunch`
- **Description:** VM security configuration

#### `existingEncryptionKeyVaultResourceId`

- **Type:** String
- **Optional**
- **Description:** Resource ID of an existing Encryption Key Vault containing customer-managed keys. Typically provided from the Key Vaults (Foundation) deployment. Leave empty to have a Key Vault created automatically when CMK is enabled. In the portal form, toggle **Use Existing Encryption Key Vault** in the **Zero Trust → Encryption Key Management** step.
- **Example:** `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{vault}`

### 📖 Complete Parameter Reference

For a complete list of all 150+ parameters with detailed descriptions, see:

- [Host Pool Deployment Guide](../../docs/hostpool-deployment.md)
- [Parameters Reference Index](../../docs/parameters.md)

## Usage Examples

### Example 1: Basic Pooled Desktop with Azure AD DS

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\hostpool.json" `
  -TemplateParameterFile "..\..\customer\parameters\hostpools\finance.parameters.json" `
  -identifier "finance" `
  -identitySolution "EntraDomainServices" `
  -domainName "contoso.com" `
  -virtualMachineSize "Standard_D4ads_v5" `
  -virtualMachineCount 5 `
  -subnetResourceId "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/snet-avd-hosts" `
  -Name "avd-hostpool-finance-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Example 2: Session Hosts Only (Add Capacity)

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\add-ons\sessionHosts\main.json" `
  -existingHostPoolResourceId "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.DesktopVirtualization/hostPools/hp-finance" `
  -virtualMachineCount 5 `
  -virtualMachineNamePrefix "avd-vm-fin-" `
  -virtualMachineSize  "Standard_D4ads_v5" `
  -subnetResourceId "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/snet-avd-hosts" `
  -Name "avd-add-hosts-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Example 3: Zero Trust with Private Endpoints

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\hostpool.json" `
  -TemplateParameterFile "..\..\customer\parameters\hostpools\secure.parameters.json" `
  -deployPrivateEndpoints $true `
  -hostPoolResourcesPrivateEndpointSubnetResourceId "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/snet-endpoints" `
  -operationsPrivateEndpointSubnetResourceId "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/snet-endpoints" `
  -Name "avd-hostpool-secure-$(Get-Date -Format 'yyyyMMddHHmm')"
```

## Examples — Parameter Files

Export the working first-deployment parameter file from the Template Spec UI into
`customer\parameters\hostpools\`. The sample files in `parameters\` and the annotated examples below
are references and a fallback when the Template Spec UI is unavailable.

### Minimal Pooled Desktop (Entra ID, Marketplace Image)

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "identitySolution": { "value": "EntraId" },
        "identifier": { "value": "dept1" },
        "virtualMachineAdminUserName": { "value": "avdAdmin" },
        "virtualMachineAdminPassword": { "value": "<REDACTED>" },
        "virtualMachineNamePrefix": { "value": "avd-dept1" },
        "virtualMachineSize": { "value": "Standard_D4ads_v5" },
        "virtualMachineCount": { "value": 2 },
        "virtualMachineSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-use2/providers/Microsoft.Network/virtualNetworks/vnet-avd-use2/subnets/hosts"
        }
    }
}
```

### Zero Trust with Private Endpoints

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "identitySolution": { "value": "ActiveDirectoryDomainServices" },
        "identifier": { "value": "finance" },
        "domainName": { "value": "contoso.com" },
        "domainJoinUserPrincipalName": { "value": "svc-avd-join@contoso.com" },
        "domainJoinUserPassword": { "value": "<REDACTED>" },
        "virtualMachineAdminUserName": { "value": "avdAdmin" },
        "virtualMachineAdminPassword": { "value": "<REDACTED>" },
        "virtualMachineNamePrefix": { "value": "avd-fin" },
        "virtualMachineSize": { "value": "Standard_D4ads_v5" },
        "virtualMachineCount": { "value": 5 },
        "virtualMachineSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-use2/providers/Microsoft.Network/virtualNetworks/vnet-avd-use2/subnets/hosts"
        },
        "deployPrivateEndpoints": { "value": true },
        "hostPoolResourcesPrivateEndpointSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-use2/providers/Microsoft.Network/virtualNetworks/vnet-avd-use2/subnets/privateEndpoints"
        },
        "operationsPrivateEndpointSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-use2/providers/Microsoft.Network/virtualNetworks/vnet-avd-use2/subnets/privateEndpoints"
        },
        "azureBlobPrivateDnsZoneResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-networking-use2/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
        },
        "azureFilesPrivateDnsZoneResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-networking-use2/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net"
        },
        "azureKeyVaultPrivateDnsZoneResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-networking-use2/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
        },
        "deployFSLogixStorage": { "value": true },
        "enableMonitoring": { "value": true }
    }
}
```

### Custom Image with Customer Managed Keys

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "identitySolution": { "value": "EntraId" },
        "identifier": { "value": "prod" },
        "virtualMachineAdminUserName": { "value": "avdAdmin" },
        "virtualMachineAdminPassword": { "value": "<REDACTED>" },
        "virtualMachineNamePrefix": { "value": "avd-prod" },
        "virtualMachineSize": { "value": "Standard_D4ads_v5" },
        "virtualMachineCount": { "value": 10 },
        "virtualMachineSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-use2/providers/Microsoft.Network/virtualNetworks/vnet-avd-use2/subnets/hosts"
        },
        "customImageResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-image-management-use2/providers/Microsoft.Compute/galleries/gal_avd_use2/images/win11-24h2-avd-m365/versions/latest"
        },
        "keyManagementDisks": { "value": "CustomerManaged" },
        "keyManagementStorage": { "value": "CustomerManaged" },
        "encryptionKeyVaultResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-operations-use2/providers/Microsoft.KeyVault/vaults/kv-avd-enc-use2-abc"
        },
        "deployFSLogixStorage": { "value": true },
        "enableMonitoring": { "value": true },
        "encryptionAtHost": { "value": true }
    }
}
```

### Example 4: Custom Image with GPU

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\hostpool.json" `
  -TemplateParameterFile "..\..\customer\parameters\hostpools\graphics.parameters.json" `
  -customImageResourceId "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gallery}/images/win11-graphics/versions/latest" `
  -virtualMachineSize "Standard_NV12ads_A10_v5" `
  -installNvidiaGpuDriver $true `
  -Name "avd-hostpool-graphics-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Example 5: Azure NetApp Files for Large Deployment

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\hostpool.json" `
  -TemplateParameterFile "..\..\customer\parameters\hostpools\enterprise.parameters.json" `
  -storageService "AzureNetAppFiles" `
  -netAppFilesAccountName "anf-avd-storage" `
  -netAppFilesCapacityPoolName "pool-premium" `
  -netAppFilesVolumeQuotaGB 4096 `
  -virtualMachineCount 100 `
  -Name "avd-hostpool-enterprise-$(Get-Date -Format 'yyyyMMddHHmm')"
```

## Outputs

### Control Plane

- `hostPoolResourceId` - Host pool resource ID
- `desktopApplicationGroupResourceId` - Desktop app group resource ID
- `workspaceResourceId` - Workspace resource ID

### Session Hosts

- `virtualMachineResourceIds` - Array of VM resource IDs
- `virtualMachineNames` - Array of VM names

### Storage

- `storageAccountResourceIds` - Array of storage account resource IDs
- `fileShareNames` - Array of file share names
- `netAppFilesVolumeResourceId` - ANF volume resource ID (if applicable)

### Monitoring

- `logAnalyticsWorkspaceResourceId` - Log Analytics workspace resource ID
- `dataCollectionRuleResourceIds` - Array of DCR resource IDs

## Troubleshooting

### Common Issues

**Session hosts fail to join domain**
- Verify domain join credentials are correct
- Check OU path format: `OU=AVD,OU=Computers,DC=contoso,DC=com`
- Ensure subnet has connectivity to domain controllers
- Review DSC extension logs on session hosts

**FSLogix profiles not loading**
- Verify storage account RBAC assignments (Entra ID scenarios)
- Check Kerberos configuration (Kerberos scenarios)
- Review FSLogix logs: `C:\ProgramData\FSLogix\Logs`
- Confirm storage private endpoint DNS resolution

**Session hosts not registering to host pool**
- Verify host pool registration token is valid
- Check session host can reach AVD service endpoints
- Review AVD agent logs: `C:\Program Files\Microsoft RDInfra\AgentInstall.txt`

**Zero Trust private endpoints not working**
- Confirm private DNS zones are linked to VNet
- Verify NSGs allow traffic from session hosts to private endpoints
- Test DNS resolution from session host

**VM deployment fails with quota error**
- Check subscription VM quota for the region
- Request quota increase through Azure Portal
- Consider using different VM size or region

## Cost Optimization

### Compute

- Use **D-series VMs** for general workloads (balanced cost/performance)
- Use **B-series VMs** for light workloads (burstable, lower cost)
- Enable **Autoscale** to scale down during off-hours
- Use **Azure Hybrid Benefit** for Windows licensing

### Storage

- Use **Standard storage** for most scenarios (ZRS for HA)
- Use **Premium** only for high-IOPS workloads (>5000 IOPS)
- Right-size file share quotas
- Enable **Storage Quota Automation** to avoid over-provisioning

### Networking

- Consolidate private endpoints where possible
- Use **VNet peering** instead of VPN for hub-spoke

## Additional Resources

- 📖 [Host Pool Deployment Guide](../../docs/hostpool-deployment.md) - Complete user guide
- 📖 [Parameters Reference](../../docs/parameters.md) - All parameters explained
- 📖 [Features Guide](../../docs/features.md) - Feature documentation
- 📖 [Troubleshooting Guide](../../docs/troubleshooting.md) - Common issues and solutions
- 🔧 [Azure Virtual Desktop Documentation](https://learn.microsoft.com/azure/virtual-desktop/)
- 🔧 [FSLogix Documentation](https://learn.microsoft.com/fslogix/)

## Support

For issues, questions, or contributions:

- **GitHub Issues:** [Azure/FederalAVD/issues](https://github.com/Azure/FederalAVD/issues)
- **Documentation:** [docs/](../../docs/)

## License

This project is licensed under the MIT License - see the [LICENSE](../../LICENSE) file for details.
