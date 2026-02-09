[**Home**](../README.md) | [**Quick Start**](quickStart.md) | [**Host Pool Deployment**](HOSTPOOL-DEPLOYMENT.md) | [**Artifacts Guide**](artifacts-guide.md)

# 🎨 Custom Image Build Guide

## Overview

The Federal AVD solution includes an automated custom image building capability. This Zero Trust-compliant solution creates custom Windows images with pre-installed software, configurations, and optimizations for Azure Virtual Desktop deployments without requiring Azure Image Builder service.

### Why Build Custom Images?

**Benefits:**

- ⚡ **Faster Deployments** - Pre-installed software reduces session host deployment time
- 🎯 **Consistency** - Ensures all session hosts start with identical configurations
- 🔒 **Security** - Bake security hardening and policies into the base image
- 💰 **Cost Savings** - Reduces compute time for customizations during VM deployment
- 🚀 **Scale** - Deploy hundreds of session hosts from a known-good image

**When to Use Custom Images:**

- Deploying standardized desktop environments
- Installing large or complex software packages
- Applying Windows Updates and OS optimizations
- Implementing security baselines and compliance requirements
- Supporting air-gapped or restricted network environments

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Understanding the Build Process](#understanding-the-build-process)
- [Deployment Methods](#deployment-methods)
  - [Method 1: Deploy Button (Recommended)](#method-1-deploy-button-recommended)
  - [Method 2: PowerShell Helper Script](#method-2-using-the-powershell-helper-script)
  - [Method 3: Azure CLI](#method-3-azure-cli)
- [Parameter Configuration](#parameter-configuration)
- [Build Process Monitoring](#build-process-monitoring)
- [Using the Custom Image](#using-the-custom-image)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)
- [Next Steps](#next-steps)

---

## Prerequisites

### Required - Image Management Resources

Custom image building **requires** the Image Management resources to be deployed first. These resources provide the storage and infrastructure needed for artifacts and image distribution.

**📦 [Deploy Image Management Resources](artifacts-guide.md#deploying-image-management-resources)**

The Image Management deployment creates:

- Storage Account with artifacts blob container
- Managed Identity with RBAC permissions
- Azure Compute Gallery for image storage
- Private endpoints (optional, for Zero Trust)

### Required - Artifacts

Custom images are built by executing **artifacts** during the image build process. Artifacts are packages containing PowerShell scripts and installers stored in Azure Blob Storage.

**📚 [Understanding Artifacts](artifacts-guide.md)**

**Example artifacts included:**

- Windows Updates and optimizations
- FSLogix installation
- Microsoft 365 Apps installation
- Microsoft Teams installation
- OneDrive installation
- Custom software packages

**📝 [Creating Custom Artifacts](artifacts-guide.md#creating-custom-artifact-packages)**

### Required - Parameter Files

Image build configurations are defined in parameter files located in `deployments/imageManagement/parameters/`:

**Two parameter files are required:**

1. **`<prefix>.imageBuild.parameters.json`** - Defines the image build configuration
2. **`<prefix>.imageManagement.parameters.json`** - References the Image Management resources

**Example structure:**

```
deployments/imageManagement/parameters/
├── demo.imageBuild.parameters.json
├── demo.imageManagement.parameters.json
├── prod.imageBuild.parameters.json
└── prod.imageManagement.parameters.json
```

---

## Image Build Architecture

### How Image Building Works

```mermaid
graph TD
    A[Parameter Files] --> B[Invoke-ImageBuilds.ps1]
    B --> C[Create Bicep Deployment]
    C --> D[Provision Build VM]
    D --> E[Download Artifacts from Blob Storage]
    E --> F[Execute Each Artifact via Run Commands]
    F --> G[Run Windows Updates]
    G --> H[Sysprep and Capture]
    H --> I[Store in Compute Gallery]
    I --> J[Replicate to Regions]
    J --> K[Ready for Host Pool Deployment]
```

### Build Process Steps

1. **Provision Build VM** - Bicep creates a temporary VM in your subscription
2. **Download Artifacts** - Each artifact is downloaded from blob storage
3. **Execute Customizations** - PowerShell scripts run sequentially via VM Run Commands using `Invoke-Customization.ps1`
4. **Apply Updates** - Windows Updates are installed (optional)
5. **Sysprep** - Image is generalized for deployment
6. **Capture** - VM is captured as an image version
7. **Distribute** - Image is stored in Compute Gallery and replicated to target regions

### Customizations Array

The `customizations` parameter array defines which artifacts to run during image build:

```json
{
  "customizations": [
    {
      "name": "InstallFsLogix",
      "blobName": "FSLogixInstallation.zip",
      "arguments": ""
    },
    {
      "name": "InstallMicrosoft365",
      "blobName": "Office365Install.zip",
      "arguments": ""
    }
  ]
}
```

**Each customization runs as a separate VM Run Command**, executing `Invoke-Customization.ps1` with the specified artifact.

---

## Parameter Configuration

### Image Build Parameters

Key parameters in `<prefix>.imageBuild.parameters.json`:

| Parameter | Description | Example |
|-----------|-------------|---------|
| **customizations** | Array of artifacts to run during build | See customizations array above |
| **imageDefinitionName** | Name for the image in Compute Gallery | `avd-win11-23h2` |
| **sourceImagePublisher** | Base image publisher (marketplace) | `MicrosoftWindowsDesktop` |
| **sourceImageOffer** | Base image offer | `office-365` |
| **sourceImageSku** | Base image SKU | `win11-23h2-avd-m365` |
| **imageVersionName** | Version number for the image | `1.0.0` (auto-incremented) |
| **excludeFromLatest** | Exclude this version from 'latest' | `false` |
| **replicaCount** | Number of replicas per region | `1` |
| **replicationRegions** | Regions to replicate image to | `["eastus2", "westus2"]` |
| **runWindowsUpdate** | Install Windows Updates during build | `true` |
| **windowsUpdateCategories** | Categories of updates to install | `Critical, Security, UpdateRollup` |

### Image Management Parameters

Reference parameters in `<prefix>.imageManagement.parameters.json`:

| Parameter | Description |
|-----------|-------------|
| **artifactsContainerName** | Blob container name for artifacts |
| **artifactsStorageAccountResourceId** | Resource ID of storage account |
| **artifactsUserAssignedIdentityResourceId** | Managed identity for blob access |
| **computeGalleryResourceId** | Compute Gallery resource ID |

---

## Building Custom Images

### Method 1: Azure Portal (Deploy Button)

**Best for:** Quick deployments without local tooling

Click the button for your target cloud to open the deployment UI in Azure Portal:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FimageManagement%2FimageBuild%2FimageBuild.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FimageManagement%2FimageBuild%2FuiFormDefinition.json) [![Deploy to Azure Gov](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FimageManagement%2FimageBuild%2FimageBuild.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FimageManagement%2FimageBuild%2FuiFormDefinition.json)

**⚠️ Note:** For Air-Gapped clouds (Secret/Top Secret), create Template Specs using [`New-TemplateSpecs.ps1`](../deployments/New-TemplateSpecs.ps1) or use PowerShell deployment methods below.

### Method 2: Using the PowerShell Helper Script

**Best for:** Automation and building multiple images

The `Invoke-ImageBuilds.ps1` script automates the image build deployment process.

#### Basic Usage

```powershell
# Navigate to deployments directory
cd C:\repos\FederalAVD\deployments

# Connect to Azure
Connect-AzAccount -Environment AzureUSGovernment
Set-AzContext -Subscription "your-subscription-id"

# Build image using demo parameter files
.\Invoke-ImageBuilds.ps1 -Location "usgovvirginia" -ParameterFilePrefixes @('demo')
```

#### Multiple Builds

Build multiple images simultaneously:

```powershell
.\Invoke-ImageBuilds.ps1 -Location "usgovvirginia" -ParameterFilePrefixes @('dev', 'test', 'prod')
```

#### Script Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| **Location** | String | Yes | Azure region where build will execute |
| **ParameterFilePrefixes** | Array | Yes | List of parameter file prefixes to process |
| **SubscriptionId** | String | No | Target subscription (uses current context if not specified) |

### Method 3: Manual Deployment with Azure CLI or PowerShell

**Best for:** CI/CD pipelines and advanced automation

Deploy using Azure CLI or PowerShell directly:

#### Azure PowerShell

```powershell
New-AzSubscriptionDeployment `
    -Location "usgovvirginia" `
    -TemplateFile ".\imageManagement\imageBuild\imageBuild.bicep" `
    -TemplateParameterFile ".\imageManagement\parameters\demo.imageBuild.parameters.json" `
    -Name "avd-image-build-$(Get-Date -Format 'yyyyMMddHHmm')"
```

#### Azure CLI

```bash
az deployment sub create \
    --location usgovvirginia \
    --template-file ./imageManagement/imageBuild/imageBuild.bicep \
    --parameters @./imageManagement/parameters/demo.imageBuild.parameters.json \
    --name avd-image-build-$(date +%Y%m%d%H%M)
```

---

## Monitoring Image Builds

### Deployment Status

Monitor the deployment in Azure Portal:

1. Navigate to **Subscriptions** > **Deployments**
2. Find your deployment (e.g., `avd-image-build-202602091530`)
3. Check deployment status and any errors

### Image Builder Status

Check the Image Builder resource:

1. Navigate to Resource Group (e.g., `rg-image-management-usgovvirginia`)
2. Find the Image Template resource (e.g., `it-avd-win11-23h2`)
3. View **Run History** to see build progress
4. Check **Customization Log** for detailed artifact execution logs

### Build Timeline

Typical build duration: **45-90 minutes** depending on:

- Number of customizations
- Software installation complexity
- Windows Update installation (if enabled)
- Network speed for downloads

---

## Troubleshooting

### Common Issues

#### Issue: Build Fails During Artifact Execution

**Symptoms**: Build fails with error during customization step

**Solutions**:

- Check artifact PowerShell script for errors
- Verify blob storage access (managed identity permissions)
- Review customization logs in Image Builder
- Test artifact locally on a test VM first

#### Issue: Windows Updates Timeout

**Symptoms**: Build fails during Windows Update phase

**Solutions**:

- Increase build timeout in Bicep template
- Reduce Windows Update categories
- Use a more recent base image (fewer updates needed)
- Set `runWindowsUpdate = false` and manage updates separately

#### Issue: Image Not Available in Target Region

**Symptoms**: Image build succeeds but not visible in host pool region

**Solutions**:

- Check `replicationRegions` parameter includes target region
- Wait for replication to complete (check Compute Gallery)
- Verify replica count is sufficient

#### Issue: Access Denied to Artifacts

**Symptoms**: Build fails with 403/401 errors downloading artifacts

**Solutions**:

- Verify managed identity has **Storage Blob Data Reader** role
- Check storage account firewall rules allow Azure services
- Ensure artifact container name matches parameter

### Getting Detailed Logs

**Build VM Run Command Logs:**

```powershell
# View Run Commands on the build VM
$buildRg = "rg-avd-imagebuild-use2"
$buildVm = Get-AzVM -ResourceGroupName $buildRg | Where-Object {$_.Name -like "*-build"}

# Get Run Command execution results
Get-AzVMRunCommand -ResourceGroupName $buildRg -VMName $buildVm.Name
```

**Storage Account Logs:**

- Enable diagnostic logs on storage account
- Check for blob download activity
- Verify managed identity access attempts

---

## Best Practices

### Image Management

1. **Version Control** - Use semantic versioning (e.g., 1.0.0, 1.1.0, 2.0.0)
2. **Testing** - Test new images in dev/test before production
3. **Documentation** - Document changes in each image version
4. **Retention** - Keep previous image versions for rollback capability
5. **Automation** - Use CI/CD pipelines to automate builds on artifact changes

### Artifact Organization

1. **Modular Artifacts** - Keep artifacts focused on single tasks
2. **Idempotency** - Ensure artifacts can run multiple times safely
3. **Error Handling** - Include proper error handling in PowerShell scripts
4. **Logging** - Write detailed logs for troubleshooting
5. **Dependencies** - Document artifact dependencies and execution order

### Security

1. **Managed Identities** - Use managed identities instead of storage account keys
2. **Private Endpoints** - Enable private endpoints for storage accounts
3. **Least Privilege** - Grant minimal RBAC permissions required
4. **Secure Artifacts** - Store software installers securely in blob storage
5. **Compliance** - Bake compliance requirements into base image

### Performance

1. **Base Image Selection** - Choose the most recent base image to minimize updates
2. **Parallel Builds** - Build multiple images simultaneously if needed
3. **Regional Proximity** - Build in the same region as artifact storage
4. **Artifact Size** - Minimize artifact package sizes for faster downloads
5. **Update Strategy** - Balance update frequency with build time

---

## Using Custom Images

### In Host Pool Deployments

Once the image build completes and replicates to your target region, reference it in host pool deployments:

**In `<prefix>.hostpool.parameters.json`:**

```json
{
  "imageReference": {
    "id": "/subscriptions/xxx/resourceGroups/rg-image-management-usgovvirginia/providers/Microsoft.Compute/galleries/gal_imagemgt_usgovvirginia/images/avd-win11-23h2/versions/latest"
  }
}
```

**Or use a specific version:**

```json
{
  "imageReference": {
    "id": "/subscriptions/xxx/resourceGroups/rg-image-management-usgovvirginia/providers/Microsoft.Compute/galleries/gal_imagemgt_usgovvirginia/images/avd-win11-23h2/versions/1.0.0"
  }
}
```

### With Session Host Replacer

The Session Host Replacer add-on automatically detects new image versions and replaces session hosts with zero downtime.

**[Session Host Replacer Documentation](../deployments/add-ons/SessionHostReplacer/readme.md)**

---

## Next Steps

- **[Deploy Host Pool](HOSTPOOL-DEPLOYMENT.md)** - Deploy AVD host pool using your custom image
- **[Create Custom Artifacts](artifacts-guide.md#creating-custom-artifact-packages)** - Build your own software packages
- **[Session Host Replacer](../deployments/add-ons/SessionHostReplacer/readme.md)** - Automate host replacements on image updates

---

## Related Documentation

- 📦 [Artifacts & Image Management Guide](artifacts-guide.md)
- 🔧 [Deploy-ImageManagement Script](Deploy-ImageManagement-README.md)
- 🏢 [Host Pool Deployment Guide](HOSTPOOL-DEPLOYMENT.md)
- 📖 [Quick Start Guide](quickStart.md)
- ⚙️ [Parameters Reference](parameters.md)
