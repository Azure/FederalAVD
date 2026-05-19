# AVD Host Pool Deployment Template

> **📖 User Guide:** For deployment instructions and step-by-step guidance, see the [Host Pool Deployment Guide](../../docs/hostpoolDeployment.md)

## Overview

This comprehensive Azure Bicep template deploys a complete Azure Virtual Desktop (AVD) environment including host pools, session hosts, storage, monitoring, security, and operational automation. It supports multiple identity scenarios, Zero Trust architecture, and air-gapped cloud environments.

## Purpose

Deploy production-ready AVD environments with:

- **Control Plane** - Host pools, application groups, workspaces
- **Session Hosts** - Virtual machines with AVD agents and customizations
- **Storage** - FSLogix profile storage with RBAC or Kerberos authentication
- **Monitoring** - Log Analytics, Azure Monitor, VM Insights, diagnostic settings
- **Security** - Private endpoints, managed identities, encryption, Key Vault integration
- **Automation** - Auto-increase premium file share quota, session host lifecycle management
- **Networking** - Virtual network integration, private endpoints, NSG configurations

## Architecture

### Deployment Types

| Type | Description | Use Case |
|------|-------------|----------|
| **Complete** | Deploy everything (control plane + session hosts + supporting resources) | New AVD environment |
| **HostpoolOnly** | Deploy control plane + session hosts (use existing storage/monitoring) | Additional host pool in existing environment |
| **SessionHostsOnly** | Deploy only session hosts to existing host pool | Add capacity to existing pool |

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
│   └── Disk Encryption Set (optional)
├── Operations Resource Group
│   ├── Key Vaults
│   ├── Recovery Services Vault (optional, when backup enabled)
│   ├── Backup Policies (file share policy for pooled, VM policy for personal)
│   └── Private Endpoints (Key Vaults, Recovery Services Vault)
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
    ├── Data Collection Rules (VM Insights, session host logs)
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

- **Azure Monitor** - VM Insights, performance counters, Windows Event logs
- **Data Collection Rules** - Centralized log collection configuration
- **Storage Quota Automation** - Auto-increase Azure Files quota when threshold reached
- **Session Host Replacer** - Automated session host lifecycle management (add-on)

### Security Features

- **Private Endpoints** - Storage, Key Vault, Workspace, Automation Account
- **Customer-Managed Keys** - Disk encryption, storage encryption
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

#### `deploymentType`
- **Type:** String
- **Allowed:** `Complete`, `HostpoolOnly`, `SessionHostsOnly`
- **Default:** `Complete`
- **Description:** Type of deployment to perform

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
- **Required when:** `deploymentType` is `Complete` or `HostpoolOnly`
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

#### `subnetResourceId`
- **Type:** String
- **Required:** Yes
- **Description:** Subnet resource ID for session hosts

### Storage

#### `storageService`
- **Type:** String
- **Allowed:** `AzureFiles`, `AzureNetAppFiles`, `None`
- **Default:** `AzureFiles`
- **Description:** Storage solution for FSLogix profiles

#### `storageAccountSku`
- **Type:** String (Azure Files only)
- **Allowed:** `Standard_LRS`, `Standard_ZRS`, `Premium_LRS`, `Premium_ZRS`
- **Default:** `Standard_LRS`
- **Description:** Storage account SKU

#### `fileShareQuotaInGB`
- **Type:** Integer
- **Default:** `100`
- **Description:** Azure Files share quota in GB

#### `netAppFilesAccountName`
- **Type:** String (Azure NetApp Files only)
- **Description:** Existing ANF account name

#### `netAppFilesCapacityPoolName`
- **Type:** String (Azure NetApp Files only)
- **Description:** Existing ANF capacity pool name

#### `netAppFilesVolumeQuotaGB`
- **Type:** Integer
- **Default:** `1024`
- **Description:** ANF volume quota in GB

### Monitoring

#### `monitoringResourceGroupName`
- **Type:** String
- **Description:** Resource group for Log Analytics workspace

#### `logAnalyticsWorkspaceResourceId`
- **Type:** String
- **Description:** Existing Log Analytics workspace resource ID

#### `deployVMInsights`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Deploy Azure Monitor VM Insights

#### `deploySessionHostInsights`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Collect AVD-specific performance counters and logs

### Backup

#### `recoveryServices`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Enable Azure Backup. For pooled host pools this backs up the Azure Files share; for personal host pools this backs up the session host VM disks.

#### `recoveryServicesVaultStorageRedundancy`
- **Type:** String
- **Allowed:** `LocallyRedundant`, `ZoneRedundant`, `GeoRedundant`
- **Default:** `LocallyRedundant`
- **Description:** Storage redundancy for backup recovery points in the Recovery Services vault. Independent of storage account SKU.

#### `existingRecoveryServicesVaultResourceId`
- **Type:** String
- **Optional**
- **Description:** Resource ID of an existing Recovery Services vault. Required when `deploymentType` is `HostPoolOnly` or `SessionHostsOnly` and `recoveryServices` is `true`.

### Networking

#### `permittedIPs`
- **Type:** Array
- **Optional**
- **Description:** IP addresses or CIDR blocks permitted through the firewall of all PaaS resources (storage accounts, Key Vaults). Use when managing deployments from a trusted workstation outside the Azure network boundary.
- **Example:** `["203.0.113.10", "198.51.100.0/24"]`

### Security & Encryption

#### `diskEncryption`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Enable disk encryption with platform-managed keys

#### `diskEncryptionSetResourceId`
- **Type:** String
- **Optional**
- **Description:** Disk Encryption Set for customer-managed keys

#### `securityType`
- **Type:** String
- **Allowed:** `Standard`, `TrustedLaunch`, `ConfidentialVM`
- **Default:** `Standard`
- **Description:** VM security configuration

#### `encryptionKeyVaultResourceId`
- **Type:** String
- **Optional**
- **Description:** Resource ID of an existing Encryption Key Vault containing customer-managed keys. Typically provided from the Key Vaults (Foundation) deployment. Leave empty to have a Key Vault created automatically when CMK is enabled and `deploymentType` is `Complete`.
- **Example:** `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{vault}`

### 📖 Complete Parameter Reference

For a complete list of all 150+ parameters with detailed descriptions, see:
- [Host Pool Deployment Guide](../../docs/hostpoolDeployment.md)
- [Parameters Reference Index](../../docs/parameters.md)

## Usage Examples

### Example 1: Basic Pooled Desktop with Azure AD DS

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\hostpool.json" `
  -TemplateParameterFile ".\parameters\finance.parameters.json" `
  -deploymentType "Complete" `
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
  -TemplateFile ".\hostpool.json" `
  -deploymentType "SessionHostsOnly" `
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
  -TemplateParameterFile ".\parameters\secure.parameters.json" `
  -deployPrivateEndpointStorage $true `
  -deployPrivateEndpointKeyVault $true `
  -deployPrivateEndpointWorkspace $true `
  -privateEndpointSubnetResourceId "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/snet-endpoints" `
  -Name "avd-hostpool-secure-$(Get-Date -Format 'yyyyMMddHHmm')"
```

## Examples — Parameter Files

Ready-to-use parameter files are in `parameters\`. Copy and rename one for your environment. The following annotated examples show the key patterns.

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
        "keyManagementStorageAccounts": { "value": "CustomerManaged" },
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
  -TemplateParameterFile ".\parameters\graphics.parameters.json" `
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
  -TemplateParameterFile ".\parameters\enterprise.parameters.json" `
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

- 📖 [Host Pool Deployment Guide](../../docs/hostpoolDeployment.md) - Complete user guide
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
