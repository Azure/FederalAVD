[**Home**](../README.md) | [**Quick Start**](quickStart.md) | [**Host Pool Deployment**](hostpoolDeployment.md) | [**Image Build**](imageBuild.md) | [**Artifacts**](artifactsGuide.md) | [**Features**](features.md) | [**Parameters**](parameters.md)

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

**📦 [Image Management Prerequisites](artifactsGuide.md)**

**Required for:**

- Custom image builds with pre-installed software
- Session host post-deployment customizations
- Air-gapped cloud deployments

**Not required for:**

- Using marketplace images without customizations
- Basic host pool deployments

#### Custom Images

If building custom images with pre-installed software:

**🎨 [Image Build Guide](imageBuild.md)**

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

# Deploy host pool using parameter file name as deployment name
$paramFile = "demo.hostpool.parameters.json"
$deploymentName = [System.IO.Path]::GetFileNameWithoutExtension($paramFile)

New-AzSubscriptionDeployment `
    -Location "usgovvirginia" `
    -TemplateFile ".\hostpools\hostpool.bicep" `
    -TemplateParameterFile ".\hostpools\parameters\$paramFile" `
    -Name $deploymentName
```

#### Azure CLI Example:

```bash
# Login to Azure
az cloud set --name AzureUSGovernment
az login
az account set --subscription "your-subscription-id"

# Deploy host pool using parameter file name as deployment name
PARAM_FILE="demo.hostpool.parameters.json"
DEPLOYMENT_NAME="${PARAM_FILE%.json}"

az deployment sub create \
    --location usgovvirginia \
    --template-file ./hostpools/hostpool.bicep \
    --parameters @./hostpools/parameters/$PARAM_FILE \
    --name $DEPLOYMENT_NAME
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

**⚠️ Requires Image Management resources** - See [Artifacts Guide](artifactsGuide.md)

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
$paramFile = "mycompany.hostpool.parameters.json"
$deploymentName = [System.IO.Path]::GetFileNameWithoutExtension($paramFile)

New-AzSubscriptionDeployment `
    -Location "East US 2" `
    -TemplateFile ".\hostpools\hostpool.bicep" `
    -TemplateParameterFile ".\hostpools\parameters\$paramFile" `
    -Name $deploymentName
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
   # Update sessionHostCount in parameter file, then redeploy
   $paramFile = "mycompany.hostpool.parameters.json"
   $deploymentName = [System.IO.Path]::GetFileNameWithoutExtension($paramFile)
   
   New-AzSubscriptionDeployment `
       -Location "East US 2" `
       -TemplateFile ".\hostpools\hostpool.bicep" `
       -TemplateParameterFile ".\hostpools\parameters\$paramFile" `
       -Name $deploymentName
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

- **[Image Build Guide](imageBuild.md)** - Build custom images for faster deployments
- **[Artifacts Guide](artifactsGuide.md)** - Create custom software packages
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

---

## Appendix: Detailed Setup & Prerequisites

This section contains comprehensive setup instructions for all prerequisite components.

### A. Installing Tools

#### PowerShell Az Module

Install the Azure PowerShell module for deployment automation:

**For all users (requires administrator):**

```powershell
Install-Module -Name Az -AllowClobber -Force
```

**For current user only:**

```powershell
Install-Module -Name Az -AllowClobber -Force -Scope CurrentUser
```

**Verify installation:**

```powershell
Get-Module -Name Az -ListAvailable
```

📖 [Official Installation Guide](https://learn.microsoft.com/powershell/azure/install-azure-powershell)

#### Bicep CLI

Install Bicep for working with infrastructure-as-code templates:

```powershell
## Create the install folder
$installPath = "$env:USERPROFILE\.bicep"
$installDir = New-Item -ItemType Directory -Path $installPath -Force
$installDir.Attributes += 'Hidden'

## Fetch the latest Bicep CLI binary
(New-Object Net.WebClient).DownloadFile("https://github.com/Azure/bicep/releases/latest/download/bicep-win-x64.exe", "$installPath\bicep.exe")

## Add bicep to your PATH
$currentPath = (Get-Item -path "HKCU:\Environment").GetValue('Path', '', 'DoNotExpandEnvironmentNames')
if (-not $currentPath.Contains("%USERPROFILE%\.bicep")) { 
    setx PATH ($currentPath + ";%USERPROFILE%\.bicep") 
}
if (-not $env:path.Contains($installPath)) { 
    $env:path += ";$installPath" 
}

## Verify installation
bicep --help
```

📖 [Official Bicep Installation Guide](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install)

### B. Template Spec Creation

Template Specs store ARM templates in Azure for controlled deployment with custom portal UI forms.

**When to use Template Specs:**
- **Air-gapped clouds (Secret/Top Secret)** - Recommended for UI-guided deployments (Blue Buttons not available)
- **All clouds** - When you want guided form experience with built-in validation
- **Parameter file generation** - Use UI once to create parameter files for future PowerShell deployments

**Benefits:**
- Store templates in Azure for reuse
- Control access with Azure RBAC
- Custom portal UI forms with validation
- Generate parameter files easily
- Deploy without write access to templates

**Create Template Specs:**

```powershell
# Connect to Azure
Connect-AzAccount -Environment AzureCloud  # or AzureUSGovernment

# Set subscription
Set-AzContext -Subscription "<subscription-id>"

# Create template specs
cd C:\repos\FederalAVD\deployments
.\New-TemplateSpecs.ps1 -Location "eastus2"
```

This creates template specs for:
- Azure Virtual Desktop Host Pool
- Azure Virtual Desktop Custom Image Build
- Azure Virtual Desktop Networking
- Add-ons (Session Host Replacer, Storage Quota Manager, etc.)

#### 💡 Best Practice: Generate Parameter Files from Template Spec UI

The easiest way to create parameter files for PowerShell/CLI deployments:

1. **Deploy once using Template Spec UI:**
   - Navigate to **Template Specs** in Azure Portal
   - Select the desired template spec
   - Click **Deploy**
   - Fill out all parameters in the form

2. **Download the parameter file:**
   - Before clicking **Create**, go to **Review + Create**
   - Click **Download template and parameters**
   - Save the `parameters.json` file

3. **Prepare for PowerShell use:**
   - Open the parameters file
   - **Remove the `timeStamp` parameter** (if present)
     ```json
     // REMOVE THIS PARAMETER:
     "timeStamp": {
       "value": "20260210143522"
     }
     ```
     **Why remove it?**
     - The `timeStamp` parameter is auto-generated on each deployment using `utcNow()`
     - Provides automatic uniqueness for deployment names and nested resource deployments
     - For image builds, generates automatic version numbers (e.g., `2026.0210.1435`)
     - If included in parameter files, it would reuse the old timestamp, defeating uniqueness
     - Each new deployment should generate a fresh timestamp
   - Save the file

4. **Use for future deployments:**
   ```powershell
   # Option 1: Use descriptive name based on environment/identifier
   $identifier = "prod"  # or extract from parameter file name
   New-AzDeployment `
       -Location "eastus2" `
       -TemplateFile ".\deployments\hostpools\hostpool.bicep" `
       -TemplateParameterFile ".\my-saved-parameters.json" `
       -Name "avd-$identifier-hostpool"
   
   # Option 2: Use parameter file name (most consistent)
   $paramFile = "prod.hostpool.parameters.json"
   $deploymentName = [System.IO.Path]::GetFileNameWithoutExtension($paramFile)
   New-AzDeployment `
       -Location "eastus2" `
       -TemplateFile ".\deployments\hostpools\hostpool.bicep" `
       -TemplateParameterFile ".\deployments\hostpools\parameters\$paramFile" `
       -Name $deploymentName
   
   # Option 3: Combine identifier with date (if uniqueness needed)
   New-AzDeployment `
       -Location "eastus2" `
       -TemplateFile ".\deployments\hostpools\hostpool.bicep" `
       -TemplateParameterFile ".\my-saved-parameters.json" `
       -Name "avd-prod-hostpool-$(Get-Date -Format 'yyyyMMdd')"
   ```

**💡 Deployment Naming Best Practices:**

- **Use descriptive names:** Include environment (prod/dev/test) and component type
- **Be consistent:** Use the same naming pattern across all deployments
- **Avoid timestamps in the name parameter:** Azure tracks deployment history automatically
- **Use parameter file names:** Makes it easy to correlate deployments with configurations
- **Keep it simple:** Deployment names are just labels for tracking in Azure Portal

**Example naming patterns:**
```powershell
# Based on parameter file
"prod-hostpool-001"           # From prod-hostpool-001.parameters.json
"finance-pool-general"        # From finance-pool-general.parameters.json

# Based on environment + component
"avd-prod-eastus2"
"avd-dev-centralus"

# For updates/revisions (manual increment)
"avd-prod-hostpool-v2"
"avd-prod-hostpool-v3"
```

**Note:** You can use PowerShell/CLI deployments in air-gapped clouds without creating Template Specs if you manually create or already have parameter files.

📖 [Template Specs Documentation](https://learn.microsoft.com/azure/azure-resource-manager/templates/template-specs)

### C. DNS Requirements

#### Private DNS Zones for Zero Trust

When using private endpoints, these private DNS zones must be created and linked to your virtual networks:

| Purpose | Azure Commercial | Azure Government |
|---------|-----------------|------------------|
| **AVD Global Feed** | `privatelink-global.wvd.microsoft.com` | `privatelink-global.wvd.usgovcloudapi.net` |
| **AVD Workspace Feed** | `privatelink.wvd.microsoft.com` | `privatelink.wvd.usgovcloudapi.net` |
| **Azure Backup** | `privatelink.<geo>.backup.windowsazure.com` | `privatelink.<geo>.backup.windowsazure.us` |
| **Azure Blob Storage** | `privatelink.blob.core.windows.net` | `privatelink.blob.core.usgovcloudapi.net` |
| **Azure Files** | `privatelink.file.core.windows.net` | `privatelink.file.core.usgovcloudapi.net` |
| **Azure Key Vault** | `privatelink.vaultcore.azure.net` | `privatelink.vaultcore.usgovcloudapi.net` |
| **Azure Queue Storage** | `privatelink.queue.core.windows.net` | `privatelink.queue.core.usgovcloudapi.net` |
| **Azure Table Storage** | `privatelink.table.core.windows.net` | `privatelink.table.core.usgovcloudapi.net` |
| **Azure Web Sites** | `privatelink.azurewebsites.net` | `privatelink.azurewebsites.us` |

**For Azure Secret:** [Private DNS Zone Values](https://review.learn.microsoft.com/microsoft-government-secret/azure/azure-government-secret/services/networking/private-link/private-endpoint-dns)

**For Azure Top Secret:** [Private DNS Zone Values](https://review.learn.microsoft.com/microsoft-government-topsecret/azure/azure-government-top-secret/services/networking/private-link/private-endpoint-dns)

#### Domain DNS Configuration

For hybrid identity scenarios (AD DS or Entra Kerberos), configure custom DNS on your virtual network to point to domain controllers or DNS resolvers that can resolve domain SRV records.

### D. Domain Permissions Setup

#### Active Directory Domain Services

Create a service account with permissions to domain join VMs:

1. Open **Active Directory Users and Computers**
2. Navigate to your service accounts OU
3. Right-click and select **New > User**
4. Create the service account with a strong password and **Password never expires**
5. Enable **View > Advanced Features** from the menu bar
6. Create an OU for AVD computers (if not present)
7. Right-click the AVD computer OU and select **Properties**
8. Select the **Security** tab
9. Click the **Advanced** button
10. Click **Add** to add the first permission entry:
    - Click **Select a principal**
    - Search for the service account and click **Check Names**
    - Click **OK**
    - Set **Applies to:** "This object and all descendant objects"
    - Check **Create Computer Objects** and **Delete Computer Objects**
    - Click **OK**
11. Click **Add** again for the second permission entry:
    - Select the same service principal
    - Set **Applies to:** "Descendant Computer objects"
    - Check the following permissions:
      - Read all properties
      - Write all properties
      - Read permissions
      - Modify permissions
      - Change password
      - Reset password
      - Validated write to DNS host name
      - Validated write to service principal name
    - Click **OK**
12. Click **OK** to close all dialogs

#### Entra ID Domain Services

Ensure the principal is a member of the **AAD DC Administrators** group in Entra ID.

### E. Azure Permissions

#### Required Permissions

**For deploying the solution:**
- **Owner** role on the subscription, OR
- **Contributor** + **User Access Administrator** roles

**Important:** Ensure your role assignment doesn't have conditions preventing you from assigning the **Role Based Access Control Administrator** role, as the deployment uses this for automated role assignments.

#### Storage Management Permissions

**For Image Management (custom images/artifacts):**
- **Storage Blob Data Contributor** role on subscription or image management resource group

**For FSLogix Storage:**
- **Storage File Data Privileged Contributor** role on subscription or storage resource groups

#### Key Vault Permissions

**For secret management:**
- **Key Vault Administrator** role on subscription or key vault resource groups

### F. Marketplace Image Selection

To find available marketplace images for session hosts:

```powershell
# Set your region
$Location = 'eastus2'

# List publishers
(Get-AzVMImagePublisher -Location $Location).PublisherName

# List offers (common publisher: MicrosoftWindowsDesktop)
$Publisher = 'MicrosoftWindowsDesktop'
(Get-AzVMImageOffer -Location $Location -PublisherName $Publisher).Offer

# List SKUs (common offers: Windows-10, office-365)
$Offer = 'office-365'
(Get-AzVMImageSku -Location $Location -PublisherName $Publisher -Offer $Offer).Skus

# List image versions
$Sku = 'win11-23h2-avd-m365'
Get-AzVMImage -Location $Location -PublisherName $Publisher -Offer $Offer -Skus $Sku | 
    Select-Object * | Format-List
```

**Common marketplace images:**
- `win11-23h2-avd-m365` - Windows 11 multi-session with Microsoft 365 Apps
- `win11-23h2-avd` - Windows 11 multi-session
- `win10-22h2-avd-m365` - Windows 10 multi-session with Microsoft 365 Apps

### G. Feature Enablement

#### Enable Desktop Virtualization Resource Provider

```powershell
Register-AzResourceProvider -ProviderNamespace Microsoft.DesktopVirtualization

# Verify registration
Get-AzResourceProvider -ProviderNamespace Microsoft.DesktopVirtualization
```

📖 [Enable Resource Provider](https://learn.microsoft.com/azure/virtual-desktop/prerequisites?tabs=portal)

#### Enable Encryption at Host

Required for Zero Trust compliance:

```powershell
Register-AzProviderFeature -FeatureName "EncryptionAtHost" -ProviderNamespace "Microsoft.Compute"

# Check registration status
Get-AzProviderFeature -FeatureName "EncryptionAtHost" -ProviderNamespace "Microsoft.Compute"
```

📖 [Enable Encryption at Host](https://learn.microsoft.com/azure/virtual-machines/disks-enable-host-based-encryption-portal)

#### Enable AVD Private Link

Optional feature for enhanced security:

```powershell
Register-AzProviderFeature -FeatureName "EnablePrivateLink" -ProviderNamespace "Microsoft.DesktopVirtualization"

# Check registration status
Get-AzProviderFeature -FeatureName "EnablePrivateLink" -ProviderNamespace "Microsoft.DesktopVirtualization"
```

📖 [AVD Private Link Setup](https://learn.microsoft.com/azure/virtual-desktop/private-link-setup)

#### Enable Confidential VM with Customer-Managed Keys

Create the Confidential VM Orchestrator service principal:

```powershell
# Install Microsoft Graph module
Install-Module -Name Microsoft.Graph -Scope CurrentUser

# Connect to Graph
Connect-Graph -Tenant "<tenant-id>" -Scopes Application.ReadWrite.All

# Create service principal
New-MgServicePrincipal -AppId bf7b6499-ff71-4aa2-97a4-f372087be7f0 -DisplayName "Confidential VM Orchestrator"

# Get the object ID (needed for deployment parameter)
Get-MgServicePrincipal -Filter "displayName eq 'Confidential VM Orchestrator'" | 
    Select-Object Id, DisplayName
```

Use the returned `Id` value for the `confidentialVMOrchestratorObjectId` parameter.

### H. Azure NetApp Files Setup

If using Azure NetApp Files for FSLogix storage:

#### Register Resource Provider

```powershell
Register-AzResourceProvider -ProviderNamespace Microsoft.NetApp

# Verify registration
Get-AzResourceProvider -ProviderNamespace Microsoft.NetApp
```

📖 [Register NetApp Resource Provider](https://learn.microsoft.com/azure/azure-netapp-files/azure-netapp-files-register)

#### Enable Shared AD Feature

Required if deploying multiple domain-joined NetApp accounts in the same subscription and region:

```powershell
Register-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFSharedAD

# Check registration status
Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFSharedAD
```

📖 [Enable Shared AD Feature](https://learn.microsoft.com/azure/azure-netapp-files/create-active-directory-connections#shared_ad)

### I. Entra Kerberos Setup

For Entra Kerberos authentication to Azure Files, see the dedicated guides:

- **[Entra Kerberos for Azure Files (Hybrid Identity)](entraKerberosHybrid.md)** - With on-premises AD sync
- **[Entra Kerberos for Azure Files (Cloud-Only)](entraKerberosCloudOnly.md)** - Pure cloud identities

Both require creating a User Assigned Managed Identity with Microsoft Graph permissions to automate storage account configuration.

### J. Networking Setup

The solution includes an automated networking deployment for creating spoke VNets, subnets, and private DNS zones.

**Deploy networking infrastructure:**

**Option 1: Azure Portal**

[![Deploy Networking](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fnetworking%2Fnetworking.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fnetworking%2FuiFormDefinition.json)
[![Deploy to Azure Gov](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fnetworking%2Fnetworking.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2Fnetworking%2FuiFormDefinition.json)

**Option 2: Template Spec**
1. Navigate to **Template Specs** in Azure Portal
2. Select **Azure Virtual Desktop Networking**
3. Click **Deploy**
4. Configure:
   - Virtual network address space
   - Subnet configurations
   - Hub VNet for peering (optional)
   - Private DNS zones to create
5. Deploy

**What gets deployed:**
- Virtual network with configurable address space
- Subnets (session hosts, private endpoints, etc.)
- VNet peering to hub (optional)
- Route tables (optional)
- NAT Gateway (optional)
- Private DNS zones (optional)

Save the subnet resource IDs for use in host pool deployment parameters.
