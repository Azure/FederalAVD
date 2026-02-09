[**Home**](../README.md) | [**Quick Start**](quickStart.md) | [**Image Build Guide**](IMAGE-BUILD.md) | [**Artifacts Guide**](artifacts-guide.md)

# 🏢 Host Pool Deployment Guide

## Overview

This guide covers deploying complete Azure Virtual Desktop (AVD) host pool environments including session hosts, storage, networking, monitoring, and security resources. The solution supports both pooled and personal host pools with enterprise-grade features and Zero Trust security controls.

### What Gets Deployed

A complete host pool deployment includes:

| Component | Resources Created |
|-----------|------------------|
| **🖥️ AVD Control Plane** | Host pool, workspace, application groups, session hosts |
| **💾 Storage** | FSLogix profile storage (Azure Files or NetApp Files) |
| **🔐 Security** | Key Vault for secrets, managed identities, RBAC assignments |
| **📊 Monitoring** | Log Analytics workspace, diagnostic settings, Application Insights |
| **🌐 Networking** | Private endpoints, network security (Zero Trust option) |
| **💿 Backup** | Recovery Services Vault for VM backups (optional) |

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Deployment Methods](#deployment-methods)
  - [Method 1: Template Specs (Recommended)](#method-1-template-specs-recommended)
  - [Method 2: Deploy Button](#method-2-deploy-button)
  - [Method 3: PowerShell/CLI](#method-3-powershellcli)
- [Parameter Configuration](#parameter-configuration)
  - [Basic Parameters](#basic-parameters)
  - [Identity & Networking](#identity--networking)
  - [Storage Configuration](#storage-configuration)
  - [Advanced Options](#advanced-options)
- [Post-Deployment Tasks](#post-deployment-tasks)
- [Scaling Configuration](#scaling-configuration)
- [Monitoring & Alerts](#monitoring--alerts)
- [Add-Ons](#add-ons)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)
- [Next Steps](#next-steps)

---

## Prerequisites

### Required Prerequisites

Before deploying a host pool, ensure you have completed these prerequisites from the [Quick Start Guide](quickStart.md#prerequisites):

✅ **Azure Subscription** - Owner or Contributor + User Access Administrator role  
✅ **Virtual Network** - Subnet for session hosts with appropriate connectivity  
✅ **Identity Solution** - Microsoft Entra ID or Active Directory Domain Services  
✅ **Security Group** - Group containing AVD users  
✅ **Desktop Virtualization Provider** - Enabled in subscription

### Optional Prerequisites

#### Image Management (For Custom Software)

If you plan to use custom images or run post-deployment customizations, deploy Image Management resources first:

**📦 [Image Management Prerequisites](artifacts-guide.md)**

**Required for:**

- Custom image builds with pre-installed software
- Session host post-deployment customizations
- Air-gapped cloud deployments

**Not required for:**

- Using marketplace images without customizations
- Basic host pool deployments

#### Custom Images

If building custom images with pre-installed software:

**🎨 [Image Build Guide](IMAGE-BUILD.md)**

---

## Deployment Methods

Choose the deployment method that best fits your workflow:

### Method 1: Azure Portal (Template Specs)

**Best for:** GUI-based deployments with built-in validation

#### Steps:

1. **Create Template Spec** (one-time setup):

   ```powershell
   cd C:\repos\FederalAVD\deployments
   .\New-TemplateSpecs.ps1 -Location "East US 2"
   ```

2. **Deploy from Azure Portal**:
   - Navigate to **Template Specs** in Azure Portal
   - Find `ts-avd-hostpool-<region>`
   - Click **Deploy**
   - Fill out the deployment form
   - Click **Review + Create**

**Benefits:**

- Interactive UI form with parameter descriptions
- Built-in parameter validation
- Visual deployment progress
- No local tooling required

### Method 2: PowerShell/Azure CLI

**Best for:** Automation, CI/CD pipelines, repeatable deployments

#### PowerShell Example:

```powershell
# Connect to Azure
Connect-AzAccount -Environment AzureUSGovernment
Set-AzContext -Subscription "your-subscription-id"

# Deploy host pool
New-AzSubscriptionDeployment `
    -Location "usgovvirginia" `
    -TemplateFile ".\hostpools\hostpool.bicep" `
    -TemplateParameterFile ".\hostpools\parameters\demo.hostpool.parameters.json" `
    -Name "avd-hostpool-deploy-$(Get-Date -Format 'yyyyMMddHHmm')"
```

#### Azure CLI Example:

```bash
# Login to Azure
az cloud set --name AzureUSGovernment
az login
az account set --subscription "your-subscription-id"

# Deploy host pool
az deployment sub create \
    --location usgovvirginia \
    --template-file ./hostpools/hostpool.bicep \
    --parameters @./hostpools/parameters/demo.hostpool.parameters.json \
    --name avd-hostpool-deploy-$(date +%Y%m%d%H%M)
```

### Method 3: GitHub Deploy Button

**Best for:** Quick testing and demos

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fhostpools%2Fhostpool.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fhostpools%2FuiFormDefinition.json)
[![Deploy to Azure Gov](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fhostpools%2Fhostpool.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fhostpools%2FuiFormDefinition.json)

**⚠️ Note:** Not available for Air-Gapped clouds

---

## Parameter Configuration

### Parameter Files

Host pool configurations are defined in parameter files located in `deployments/hostpools/parameters/`:

```
deployments/hostpools/parameters/
├── demo.hostpool.parameters.json
├── prod.hostpool.parameters.json
└── test.hostpool.parameters.json
```

### Key Parameters

#### Basic Configuration

| Parameter | Description | Example |
|-----------|-------------|---------|
| **identifier** | Host pool persona identifier (max 9 chars) | `general`, `finance`, `dev` |
| **index** | Host pool index for sharding (0-99) | `0`, `1`, `-1` (no index) |
| **hostPoolType** | Pooled or Personal | `Pooled` |
| **sessionHostCount** | Number of session hosts to deploy | `3` |
| **sessionHostIndex** | Starting index for VM names | `1` |

#### Identity Configuration

| Parameter | Description | Options |
|-----------|-------------|---------|
| **identitySolution** | Identity and authentication method | `ActiveDirectoryDomainServices`<br>`EntraDomainServices`<br>`EntraKerberos-Hybrid`<br>`EntraKerberos-CloudOnly`<br>`EntraId` |
| **domainName** | AD domain name (if applicable) | `contoso.com` |
| **domainJoinUserName** | Domain join account UPN | `djoin@contoso.com` |

**[Identity Solutions Details](features.md#identity-solutions)**

#### Image Configuration

**Using Marketplace Image:**

```json
{
  "imageReference": {
    "publisher": "MicrosoftWindowsDesktop",
    "offer": "office-365",
    "sku": "win11-23h2-avd-m365",
    "version": "latest"
  }
}
```

**Using Custom Image:**

```json
{
  "imageReference": {
    "id": "/subscriptions/xxx/resourceGroups/rg-image-management-usgovvirginia/providers/Microsoft.Compute/galleries/gal_imagemgt_usgovvirginia/images/avd-win11-23h2/versions/latest"
  }
}
```

#### Session Host Customizations

Run post-deployment scripts on session hosts using the `sessionHostCustomizations` array:

```json
{
  "sessionHostCustomizations": [
    {
      "name": "ConfigureTimeZone",
      "blobName": "TimeZoneConfiguration.zip",
      "arguments": "-TimeZone 'Eastern Standard Time'"
    },
    {
      "name": "InstallCustomApp",
      "blobName": "CustomAppInstall.zip",
      "arguments": ""
    }
  ]
}
```

**⚠️ Requires Image Management resources** - See [Artifacts Guide](artifacts-guide.md)

#### Storage Configuration

**Azure Files (Recommended for most scenarios):**

```json
{
  "fslogixStorage": "AzureFiles",
  "storageService": "AzureFiles Premium",
  "storageRedundancy": "ZoneRedundant"
}
```

**Azure NetApp Files (For high-performance requirements):**

```json
{
  "fslogixStorage": "AzureNetAppFiles",
  "storageService": "Premium",
  "activeDirectorySolution": "ActiveDirectoryDomainServices"
}
```

#### Monitoring Configuration

```json
{
  "deploymentInsights": true,
  "enableMonitoringAgent": true,
  "logAnalyticsWorkspaceResourceId": "/subscriptions/xxx/resourceGroups/rg-monitoring/providers/Microsoft.OperationalInsights/workspaces/law-monitoring"
}
```

#### Zero Trust / Security Configuration

```json
{
  "enablePrivateEndpoint": true,
  "privateEndpointSubnetResourceId": "/subscriptions/xxx/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-privateendpoints",
  "keyManagementDisks": "CustomerManaged",
  "encryptionAtHost": true,
  "secureBootEnabled": true,
  "vTpmEnabled": true
}
```

---

## Deployment Process

### Step-by-Step Deployment

#### 1. Prepare Parameter File

Copy and customize a parameter file:

```powershell
# Copy example parameter file
Copy-Item `
    -Path ".\hostpools\parameters\demo.hostpool.parameters.json" `
    -Destination ".\hostpools\parameters\mycompany.hostpool.parameters.json"

# Edit with your values
code ".\hostpools\parameters\mycompany.hostpool.parameters.json"
```

#### 2. Update Secrets in Key Vault

Store required secrets in Azure Key Vault (referenced by parameter file):

**Required secrets:**

- `VirtualMachineAdminPassword` - Local admin password for VMs
- `VirtualMachineAdminUserName` - Local admin username for VMs

**Additional secrets (depending on identity solution):**

- `DomainJoinUserPassword` - Domain join account password (AD/Entra DS)
- `DomainJoinUserPrincipalName` - Domain join account UPN (AD/Entra DS)

```powershell
# Example: Set secrets in Key Vault
$keyVaultName = "kv-avd-secrets-eastus2"

Set-AzKeyVaultSecret -VaultName $keyVaultName `
    -Name "VirtualMachineAdminPassword" `
    -SecretValue (ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force)

Set-AzKeyVaultSecret -VaultName $keyVaultName `
    -Name "VirtualMachineAdminUserName" `
    -SecretValue (ConvertTo-SecureString "avdadmin" -AsPlainText -Force)
```

#### 3. Deploy Host Pool

Using PowerShell:

```powershell
New-AzSubscriptionDeployment `
    -Location "East US 2" `
    -TemplateFile ".\hostpools\hostpool.bicep" `
    -TemplateParameterFile ".\hostpools\parameters\mycompany.hostpool.parameters.json" `
    -Name "avd-mycompany-deploy-$(Get-Date -Format 'yyyyMMddHHmm')"
```

#### 4. Monitor Deployment

**PowerShell:**

```powershell
# Get deployment status
Get-AzSubscriptionDeployment -Name "avd-mycompany-deploy-202602091530"

# Watch deployment progress
Get-AzSubscriptionDeployment -Name "avd-mycompany-deploy-202602091530" | Select-Object -ExpandProperty Properties
```

**Azure Portal:**

1. Navigate to **Subscriptions** > **Deployments**
2. Find your deployment
3. Monitor resource creation progress
4. Check for any errors or warnings

#### 5. Assign Users

After deployment completes, assign users to the desktop application group:

**PowerShell:**

```powershell
$resourceGroup = "rg-avd-general-prod-eastus2"
$appGroupName = "dag-avd-general-prod-eastus2"
$userGroupObjectId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

New-AzRoleAssignment `
    -ObjectId $userGroupObjectId `
    -RoleDefinitionName "Desktop Virtualization User" `
    -ResourceName $appGroupName `
    -ResourceGroupName $resourceGroup `
    -ResourceType "Microsoft.DesktopVirtualization/applicationGroups"
```

---

## Post-Deployment Tasks

### Configure User Profile Management

FSLogix is automatically configured during deployment. Verify configuration:

1. Check FSLogix registry settings on session hosts
2. Test user profile creation and roaming
3. Verify storage account permissions

### Configure Session Timeouts

Adjust session timeout settings based on your requirements:

**PowerShell:**

```powershell
Update-AzWvdHostPool -ResourceGroupName $resourceGroup -Name $hostPoolName `
    -MaxSessionLimit 10 `
    -LoadBalancerType 'BreadthFirst'
```

### Enable Monitoring

Verify monitoring is working:

1. Check Log Analytics workspace for session host data
2. Review diagnostic logs in storage account
3. Configure alerts for critical metrics

### Configure Backup (Optional)

If backup was enabled, verify backup policies:

```powershell
Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $vaultId
Get-AzRecoveryServicesBackupItem -WorkloadType AzureVM -VaultId $vaultId
```

---

## Scaling and Management

### Adding Session Hosts

To add more session hosts to an existing pool:

1. **Update parameter file** - Increase `sessionHostCount`
2. **Set deployment type** - Use `SessionHostsOnly` deployment type
3. **Redeploy**:

   ```powershell
   New-AzSubscriptionDeployment `
       -Location "East US 2" `
       -TemplateFile ".\hostpools\hostpool.bicep" `
       -TemplateParameterFile ".\hostpools\parameters\mycompany.hostpool.parameters.json" `
       -Name "avd-add-hosts-$(Get-Date -Format 'yyyyMMddHHmm')"
   ```

### Removing Session Hosts

To remove session hosts:

1. Drain sessions from target hosts
2. Delete VMs from Azure Portal or PowerShell
3. Remove from host pool using Azure Portal or PowerShell

### Updating Host Pool Configuration

To modify host pool settings without redeploying session hosts:

1. **Update parameter file** with new settings
2. **Set deployment type** - Use `HostpoolOnly` deployment type
3. **Redeploy** - This updates only the control plane resources

---

## Troubleshooting

### Common Issues

#### Issue: Session Hosts Not Joining Domain

**Symptoms**: VMs deploy but don't appear in AVD host pool

**Solutions**:

- Verify domain join credentials in Key Vault
- Check DNS settings on virtual network
- Ensure network connectivity to domain controllers
- Review domain join extension logs on VMs

#### Issue: FSLogix Profiles Not Working

**Symptoms**: User profiles not roaming or creating correctly

**Solutions**:

- Verify storage account permissions
- Check FSLogix registry settings on session hosts
- Ensure identity solution supports FSLogix (Kerberos required)
- Review FSLogix event logs

#### Issue: Users Can't Connect

**Symptoms**: Users receive connection errors

**Solutions**:

- Verify user assignment to application group
- Check session host registration status
- Ensure users have "Desktop Virtualization User" role
- Verify network connectivity and firewall rules

#### Issue: Private Endpoint Resolution

**Symptoms**: Session hosts can't resolve private endpoint addresses

**Solutions**:

- Verify private DNS zone configuration
- Check virtual network DNS settings
- Ensure private DNS zone linked to VNet
- Test name resolution from session host

### Getting Logs

**Session Host Logs:**

```powershell
# Get extension logs
Get-AzVMExtension -ResourceGroupName $resourceGroup -VMName $vmName

# Download custom script extension logs
Invoke-AzVMRunCommand -ResourceGroupName $resourceGroup -VMName $vmName `
    -CommandId 'RunPowerShellScript' `
    -ScriptString 'Get-Content C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\*\Status\*.status'
```

**AVD Diagnostics:**

```powershell
# Get session host diagnostics
Get-AzWvdSessionHost -ResourceGroupName $resourceGroup -HostPoolName $hostPoolName

# Get user session information
Get-AzWvdUserSession -ResourceGroupName $resourceGroup -HostPoolName $hostPoolName
```

---

## Add-Ons and Automation

### Session Host Replacer

Automate the replacement of session hosts when new images become available:

**🔄 [Session Host Replacer](../deployments/add-ons/SessionHostReplacer/readme.md)**

**Features:**

- Zero-downtime rolling updates
- Automatic image version detection
- Delete-First or Side-by-Side replacement modes
- Progressive scale-up for large deployments

### Storage Quota Manager

Automatically monitor and increase Azure Files Premium quotas:

**📊 [Storage Quota Manager](../deployments/add-ons/StorageQuotaManager/readme.md)**

### Other Add-Ons

- **[Update Storage Keys](../deployments/add-ons/UpdateStorageAccountKeyOnSessionHosts/readme.md)** - Rotate storage keys for Entra ID deployments
- **[Run Commands on VMs](../deployments/add-ons/RunCommandsOnVms/readme.md)** - Execute scripts across session hosts

---

## Best Practices

### Security
- ✅ Enable private endpoints for all PaaS resources
- ✅ Use managed identities instead of service principals
- ✅ Implement customer-managed encryption keys
- ✅ Disable session host public IPs
- ✅ Apply Azure Policy for compliance

### Performance
- ✅ Use proximity placement groups for latency-sensitive workloads
- ✅ Enable accelerated networking on session hosts
- ✅ Right-size VM SKUs based on workload requirements
- ✅ Use Premium SSD disks for OS disks
- ✅ Configure appropriate session timeouts

### Cost Optimization
- ✅ Implement auto-scaling based on usage patterns
- ✅ Use B-series or Dsv5 VMs for cost savings
- ✅ Enable start VM on connect for personal host pools
- ✅ Configure appropriate session limits
- ✅ Review and optimize storage costs regularly

### Operational Excellence
- ✅ Use custom images with pre-installed software
- ✅ Implement backup and disaster recovery
- ✅ Configure comprehensive monitoring and alerting
- ✅ Document deployment configurations
- ✅ Automate deployments with CI/CD pipelines

---

## Next Steps

- **[Image Build Guide](IMAGE-BUILD.md)** - Build custom images for faster deployments
- **[Artifacts Guide](artifacts-guide.md)** - Create custom software packages
- **[Session Host Replacer](../deployments/add-ons/SessionHostReplacer/readme.md)** - Automate host updates
- **[Features](features.md)** - Explore advanced features
- **[Troubleshooting](troubleshooting.md)** - Resolve common issues

---

## Related Documentation

- 📖 [Quick Start Guide](quickStart.md)
- 🏗️ [Design](design.md)
- ⚙️ [Parameters Reference](parameters.md)
- ✨ [Features](features.md)
- 🚫 [Limitations](limitations.md)
