↩ **Back to:** [Quick Start](quickStart.md)

[**Home**](../README.md) | [**Quick Start**](quickStart.md) | [**Host Pool Deployment**](hostpoolDeployment.md) | [**Image Build**](imageBuild.md) | [**Artifacts**](artifactsGuide.md) | [**Features**](features.md) | [**Parameters**](parameters.md)

# Deploy-ImageManagement.ps1 Script Guide

## Overview

The `Deploy-ImageManagement.ps1` script is a comprehensive PowerShell automation tool designed to deploy and manage Azure Virtual Desktop (AVD) image management resources. This script handles the deployment of storage accounts, managed identities, and the automated download and upload of software artifacts required for custom image builds and session host deployments.

## What This Script Does

The Deploy-ImageManagement.ps1 script automates four main phases:

1. **Resource Deployment** - Deploys Azure resources including storage accounts, compute galleries, and managed identities
2. **Software Downloads** - Downloads latest versions of software from the internet using configurable parameters
3. **Artifact Packaging** - Compresses the subfolders in the artifacts into zip files
4. **Blob Upload** - Uploads all artifacts to Azure Blob Storage for use by the custom image build solution or host pool deployments.

## Script Architecture

```text
Deploy-ImageManagement.ps1
├── Phase 1: Deploy/Update Storage Account and gather variables
├── Phase 2: Download New Source Files into the artifacts Directory
├── Phase 3: Create Zip files for all subfolders inside ArtifactsDir
└── Phase 4: Upload all files to Storage Account blob container
```

## Prerequisites

Before running this script, ensure you have:

### Required Permissions

- **Contributor** role on the target Azure subscription
- **Storage Blob Data Contributor** role for image management operations (Microsoft Secure Future Initiative compliance)
- Role assignment permissions without conditions that prevent assigning 'Role-Based Access Control Administrator' role

### Required Tools

- PowerShell 5.1 or PowerShell 7+
- Azure PowerShell Az module installed
- Bicep CLI (recommended for template management)
- Active Azure subscription with Desktop Virtualization resource provider enabled

### Required Files

- Parameter files in `deployments/imageManagement/parameters/` directory:
  - `<customprefix>.imageManagement.parameters.json`
  - `<customprefix>.downloads.parameters.json`

## Parameter Sets

The script supports two distinct parameter sets for different deployment scenarios:

### Deploy Parameter Set

Used for initial deployment of image management resources.

```powershell
.\Deploy-ImageManagement.ps1 -DeployImageManagementResources -Location <Region> [additional parameters]
```

### UpdateOnly Parameter Set  

Used for updating existing storage account artifacts without deploying new resources.

```powershell
.\Deploy-ImageManagement.ps1 -StorageAccountResourceId <ResourceId> -ManagedIdentityResourceID <ResourceId> [additional parameters]
```

## Parameters Reference

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| **DeployImageManagementResources** | Switch | No | Deploys/redeploys storage account and related resources using Bicep templates |
| **Location** | String | Yes (Deploy set) | Azure region where AVD management resources will be deployed |
| **StorageAccountResourceId** | String | Yes (UpdateOnly set) | Full resource ID of existing storage account to update |
| **ManagedIdentityResourceID** | String | Yes (UpdateOnly set) | Resource ID of managed identity for storage access |
| **ParameterFilePrefix** | String | No | Custom prefix for parameter files (overrides environment-based defaults) |
| **TempDir** | String | No | Temporary directory for artifact preparation (defaults to $Env:Temp) |
| **DeleteExistingBlobs** | Switch | No | Removes existing blobs in storage account before uploading new ones |
| **SkipDownloadingNewSources** | Switch | No | Skips downloading new software sources from internet |
| **ArtifactsContainerName** | String | No | Name of blob container for artifacts (defaults to 'artifacts') |

## Usage Examples

### Example 1: Initial Deployment with Resource Creation

```powershell
# Connect to Azure
Connect-AzAccount -Environment AzureCloud
Set-AzContext -Subscription "your-subscription-id"

# Navigate to deployments directory
cd "C:\repos\FederalAVD\deployments"

# Deploy with custom parameter prefix
.\Deploy-ImageManagement.ps1 -DeployImageManagementResources -Location "USGov Virginia" -ParameterFilePrefix "contoso"
```

### Example 2: Update Existing Storage Account

```powershell
# Update existing storage account with new artifacts
.\Deploy-ImageManagement.ps1 `
    -StorageAccountResourceId "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-avd-shared-usgovvirginia/providers/Microsoft.Storage/storageAccounts/stavdsharedusgovva001" `
    -ManagedIdentityResourceID "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-avd-shared-usgovvirginia/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-avd-shared-usgovvirginia" `
    -DeleteExistingBlobs
```

### Example 3: Skip Internet Downloads (Air-Gapped Environment)

```powershell
# For air-gapped environments where internet access is restricted
.\Deploy-ImageManagement.ps1 `
    -DeployImageManagementResources `
    -Location "USGov Virginia" `
    -ParameterFilePrefix "airgapped" `
    -SkipDownloadingNewSources
```

### Example 4: Custom Temporary Directory

```powershell
# Use custom temporary directory for large artifact processing
.\Deploy-ImageManagement.ps1 `
    -DeployImageManagementResources `
    -Location "West US 2" `
    -TempDir "D:\AVD-Temp" `
    -ParameterFilePrefix "production"
```

## Environment Detection and Parameter File Selection

The script automatically detects the Azure environment and selects appropriate parameter files:

| Azure Environment | Default Prefix | Parameter File |
|-------------------|----------------|----------------|
| AzureUSGovernment | public | public.downloads.parameters.json |
| AzureUSGovernment (IL4/5) | public | public.downloads.parameters.json |
| Azure Secret (IL6) | secret | secret.downloads.parameters.json |
| Azure Top Secret (IL7) | topsecret | topsecret.downloads.parameters.json |

## Software Download Configuration

The script uses JSON configuration files to define software downloads:

```json
{
  "Microsoft365Apps": {
    "WebSiteUrl": "https://www.microsoft.com/en-us/download/confirmation.aspx?id=49117",
    "SearchString": "officedeploymenttool_",
    "DownloadUrl": "",
    "DestinationFileName": "officedeploymenttool.exe",
    "DestinationFolders": ["Microsoft365Apps"]
  },
  "MicrosoftEdge": {
    "APIUrl": "https://edgeupdates.microsoft.com/api/products",
    "DestinationFileName": "MicrosoftEdgePolicyTemplates.cab",
    "DestinationFolders": ["MicrosoftEdgePolicyTemplates"]
  }
}
```

### Supported Download Methods

1. **Direct URL** - Static download URLs
2. **Web Scraping** - Searches web pages for download links using search strings
3. **API Integration** - Retrieves latest versions from APIs (e.g., Microsoft Edge updates)
4. **GitHub Releases** - Fetches latest releases from GitHub repositories

## Deployed Azure Resources

When using the `-DeployImageManagementResources` switch, the script deploys:

### Core Resources

- **Azure Compute Gallery** - Stores custom VM images
- **Storage Account** - Hosts artifacts and scripts
- **Blob Container** - Contains packaged software artifacts
- **User Assigned Managed Identity** - Provides secure access to resources

### Security Resources

- **Role Assignments** - Grants necessary permissions to managed identity
- **Private Endpoints** - Enables private network access (optional)
- **Diagnostic Settings** - Logs storage account activities to Log Analytics (optional)

## Artifacts Directory Structure

The script processes the `.common/artifacts` directory:

```text
.common/artifacts/
├── uploadedFileVersionInfo.txt (generated)
├── CustomScript1/
│   ├── install.ps1
│   └── supporting-files.exe
├── VSCode/
│   ├── Install_VSCode.ps1
│   └── VSCodeSetup.exe
└── Configure-Office365Policy/
    ├── Configure-Office365.ps1
    └── office365.admx
```

Each subdirectory becomes a compressed zip file uploaded to blob storage.

**For comprehensive documentation on creating custom artifacts, script requirements, and best practices, see the [Artifacts and Image Management Guide](artifactsGuide.md).**

## File Version Tracking

The script automatically generates `uploadedFileVersionInfo.txt` containing:

```text
SoftwareName = Microsoft 365 Apps
DownloadUrl = https://download.microsoft.com/download/...
Download File = officedeploymenttool_16130-20218.exe
ProductVersion = 16.0.16130.20218
FileVersion = 16.0.16130.20218
Downloaded on = 10/31/2025 2:30:15 PM
--------------------------------------------------
```

## Output Information

Upon successful completion, the script outputs critical information for subsequent deployments:

```text
The 'ArtifactsLocation' = 'https://stavdsharedusgovva001.blob.core.usgovcloudapi.net/artifacts/'
The 'ArtifactsUserAssignedIdentityResourceId' = '/subscriptions/.../resourceGroups/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-avd-shared-usgovvirginia'
```

These values are required for:

- Custom image builds
- Session host deployments with custom software
- Post-deployment script execution

## Zero Trust Compliance

The script supports Zero Trust principles through:

- **Managed Identity Authentication** - Eliminates storage account key usage
- **Private Endpoint Support** - Restricts network access to private networks
- **Role-Based Access Control** - Grants minimum required permissions
- **Secure Artifact Delivery** - Encrypts artifacts in transit and at rest

## Error Handling and Logging

The script includes comprehensive error handling:

- **Azure Authentication Validation** - Verifies user is logged into Azure
- **Parameter Validation** - Ensures required parameters are provided
- **Download Retry Logic** - Attempts multiple download methods for software
- **File System Cleanup** - Removes temporary files on completion or error
- **Verbose Logging** - Provides detailed progress information when `-Verbose` is used

## Integration with Image Builds

The deployed artifacts are consumed by:

1. **The Custom Image Build Solution** - Downloads and installs software during image creation
2. **Host Pool Deployment** - Accesses artifacts for session host customization

## Best Practices

### Parameter File Management

- Use descriptive prefixes for parameter files (e.g., "production", "development")
- Store parameter files in version control
- Validate JSON syntax before deployment

### Security Considerations

- Use the latest PowerShell and Az module versions
- Implement least-privilege access principles
- Enable storage account logging and monitoring

### Performance Optimization

- Use `-DeleteExistingBlobs` only when necessary to avoid unnecessary uploads
- Leverage custom temporary directories on high-performance storage
- Consider parallel processing for large artifact collections

### Maintenance

- Regularly update download configuration files with latest software versions
- Monitor script execution logs for download failures
- Test parameter files in non-production environments first

## Troubleshooting

### Common Issues

**Authentication Errors**

Solution: Ensure you're logged into Azure with Connect-AzAccount and have proper permissions

**Parameter File Not Found**

Solution: Verify parameter file exists and uses correct naming convention

**Download Failures**

Solution: Check internet connectivity and update URLs in downloads parameter file

**Storage Access Denied**

Solution: Verify Storage Blob Data Contributor role assignment and managed identity configuration

### Diagnostic Commands

```powershell
# Check Azure context
Get-AzContext

# Verify parameter file existence
Test-Path ".\imageManagement\parameters\custom.imageManagement.parameters.json"

# Test storage account access
Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccountName
```

## Related Resources

- [Quick Start Guide](quickStart.md) - Complete deployment walkthrough
- [Parameters Documentation](parameters.md) - Detailed parameter reference
- [Air-Gapped Cloud Guide](airGappedClouds.md) - Special considerations for air-gapped environments
- [Troubleshooting](troubleshooting.md) - Common issues and solutions

## Support

For additional support or questions:

1. Review the [troubleshooting guide](troubleshooting.md)
2. Check existing [GitHub issues](https://github.com/Azure/FederalAVD/issues)
3. Create a new issue with detailed error information and deployment context