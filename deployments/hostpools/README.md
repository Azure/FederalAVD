# AVD Host Pool Deployment Template

> **📖 User Guide:** For deployment instructions and step-by-step guidance, see the [Host Pool Deployment Guide](../../docs/hostpool-deployment.md)

## Overview

This comprehensive Azure Bicep template deploys a complete Azure Virtual Desktop (AVD) environment including host pools, session hosts, storage, monitoring, security, and operational automation. It supports multiple identity scenarios, Zero Trust architecture, and air-gapped cloud environments.

## Purpose

Deploy production-ready AVD environments with:

- **Control Plane** - Host pools, application groups, workspaces
- **Session Hosts** - Virtual machines with AVD agents and customizations
- **Storage** - FSLogix profile storage with RBAC or Kerberos authentication
- **Monitoring** - Log Analytics, Azure Monitor, AVD Insights, diagnostic settings
- **Security** - Private endpoints, managed identities, encryption, Key Vault integration
- **Automation** - Auto-increase premium file share quota, session host lifecycle management
- **Networking** - Virtual network integration, private endpoints, NSG configurations

## Architecture



### Resource Deployments

The template deploys resources across multiple resource groups:

```
Subscription
├── Control Plane Resource Group
│   ├── Host Pool
│   ├── Desktop Application Group
│   ├── Workspace
│   ├── Scaling Plan (optional)
│   └── Private Endpoint (Workspace and/or Host Pool, optional)
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
│   ├── Recovery Services Vault (optional, Pooled host pool Azure Files backup)
│   ├── File Share Backup Policy (optional, Pooled host pool Azure Files backup)
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
|----------|-------------|-------------|---------------|
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

#### `nameConvResTypeAtEnd`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Reverse CAF naming convention

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
- **Required:** Yes
- **Description:** Location for control plane resources
- **Example:** `eastus2`, `usgovvirginia`

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
- **Description:** Subnet resource ID for session hosts

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
- **Description:** Redundancy for newly created Azure Files storage accounts used by FSLogix. This is configured independently from session host availability zone settings.

#### `keyManagementStorage`
- **Type:** String
- **Allowed:** `PlatformManaged`, `CustomerManaged`, `CustomerManagedHSM`
- **Default:** `PlatformManaged`
- **Description:** Key management mode for Azure Files (FSLogix) storage account encryption.

#### `keyManagementRecoveryServicesVault`
- **Type:** String
- **Allowed:** `PlatformManaged`, `CustomerManaged`, `CustomerManagedHSM`
- **Default:** `PlatformManaged`
- **Description:** Key management mode for Recovery Services Vault encryption. When `CustomerManaged` is combined with `deployPrivateEndpoints=true`, see `encryptionKeyVaultForcePublicAccess` below — Azure Backup has no AzureServices trusted service bypass for Key Vault.

#### `encryptionKeyVaultForcePublicAccess`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Controls the trade-off between two mutually exclusive controls when `deployPrivateEndpoints = true` and `keyManagementRecoveryServicesVault = CustomerManaged`. Azure Backup has no `AzureServices` trusted service bypass for Key Vault, making simultaneous satisfaction of both SC-28 (CMK on RSV) and SC-7 (private-only KV) impossible.
  - **`true`** — RSV uses customer-managed keys (SC-28 satisfied). The encryption Key Vault’s `publicNetworkAccess` is set to Enabled and all IP-based firewall rules are cleared — the Key Vault becomes reachable by any authenticated principal on Azure’s public network (SC-7 weakened).
  - **`false`** (default) — The Key Vault remains private-only (SC-7 maintained). RSV silently falls back to platform-managed keys rather than failing the deployment (SC-28 not satisfied for RSV).
- **This is a compliance risk decision for your ISSO and AO**, not a solution default or recommendation. Document the selected option and accepted control gap in your SSP.

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

#### `existingRecoveryServicesVaultResourceId`
- **Type:** String
- **Optional**
- **Description:** Resource ID of an existing Recovery Services vault. Required when `recoveryServices` is `true` and **Use Existing Recovery Services Vault** is selected (or `existingRecoveryServicesVaultResourceId` is provided in a parameter file).

### Networking

#### `permittedIPs`
- **Type:** Array
- **Optional**
- **Description:** IP addresses or CIDR blocks permitted on the firewall of all PaaS resources (storage accounts, Key Vaults). Behavior depends on `deployPrivateEndpoints`:
  - **Private endpoints ON, no IPs:** public access **disabled** — all traffic must use the private endpoint.
  - **Private endpoints ON, IPs specified:** public access **enabled but restricted** to those ranges — the private endpoint handles internal traffic and the IP allowlist covers management access from known external addresses.
  - **Private endpoints OFF:** public access enabled; if IPs are specified only those ranges are permitted, otherwise the resource is open to all traffic.
- **Example:** `["203.0.113.10", "198.51.100.0/24"]`

### Security & Encryption

#### `deploySecretsKeyVault`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Deploy an inline Secrets Key Vault (Standard SKU) to store VM admin and domain-join credentials. Configured in the **Identity → Credentials** portal step when credentials source is set to Manual Entry. Leave `false` to provide `existingCredentialsKeyVaultResourceId` from a pre-deployed Key Vaults foundation deployment.

#### `secretsKeyVaultEnableSoftDelete`
- **Type:** Boolean
- **Default:** `true`
- **Description:** Enable soft delete on the inline Secrets Key Vault. Allows recovery of deleted objects within the retention period.

#### `secretsKeyVaultEnablePurgeProtection`
- **Type:** Boolean
- **Default:** `true`
- **Description:** Enable purge protection on the inline Secrets Key Vault. Prevents permanent deletion during the retention period.

#### `secretsKeyVaultRetentionInDays`
- **Type:** Integer (7–90)
- **Default:** `90`
- **Description:** Soft-delete retention period in days for the inline Secrets Key Vault.

#### `encryptionKeyVaultRetentionInDays`
- **Type:** Integer (7–90)
- **Default:** `90`
- **Description:** Soft-delete retention period in days for the inline Encryption Key Vault. Configured in **Zero Trust → Encryption Key Management** when CMK is enabled and no existing KV is provided.

#### `encryptionAtHost`
- **Type:** Boolean
- **Default:** `true`
- **Description:** Enable encryption at host for session host VMs.

#### `keyManagementDisks`
- **Type:** String
- **Default:** `PlatformManaged`
- **Description:** Session host disk key-management mode.

#### `existingDiskEncryptionSetResourceId`
- **Type:** String
- **Optional**
- **Description:** Disk Encryption Set for customer-managed keys

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

Ready-to-use sample parameter files are in `parameters\`. Copy and rename one into `customer\parameters\hostpools\` for your environment. The following annotated examples show the key patterns.

### Minimal Pooled Desktop (Entra ID, Marketplace Image)

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "identitySolution": { "value": "EntraId" },
        "identifier": { "value": "poc" },
        "virtualMachineAdminUserName": { "value": "avdAdmin" },
        "virtualMachineAdminPassword": { "value": "<REDACTED>" },
        "virtualMachineNamePrefix": { "value": "avd-poc" },
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
