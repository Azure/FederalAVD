# AVD Custom Image Build Template

## Overview

This Azure template provides a comprehensive solution for building custom Windows images for Azure Virtual Desktop (AVD) using a zero-trust architecture approach. Unlike Azure VM Image Builder, this solution gives you complete control over the image build process while maintaining security best practices.

## Purpose

Create customized Windows images with:

- Automated software installation (FSLogix, Microsoft 365 Apps, OneDrive, Teams)
- Windows AppX package removal
- Windows Desktop Optimization Tool (WDOT) customizations
- Windows Update installation from multiple sources
- Custom scripts and applications
- STIG compliance support
- Zero-trust networking with private endpoints

The resulting image is stored in an Azure Compute Gallery for distribution to AVD session hosts.

## Key Features

### Zero Trust Architecture

- Private endpoint support for storage accounts
- User-assigned managed identity authentication
- Network isolation with service endpoints
- Secure artifact storage in Azure Blob Storage

### Flexible Image Sources

- Azure Marketplace images (Windows 10, Windows 11, Windows Server)
- Existing Compute Gallery images
- Support for both Gen1 and Gen2 VMs

### Comprehensive Customization

- **Built-in Installers:** FSLogix, M365 Apps, OneDrive, Teams, WDOT
- **AppX Removal:** Remove unwanted built-in Windows applications
- **Custom Software:** Deploy your own installers and scripts
- **VDI Customizations:** Install software that generates unique identifiers after restart
- **Windows Updates:** Install updates from Microsoft Update, Windows Update, WSUS, or other sources

### Advanced Image Features

- **Security Types:** Standard, Trusted Launch, Confidential VM
- **Storage:** NVMe disk controller support
- **Networking:** Accelerated Networking support
- **Compute:** Hibernation support (preview)

### Multi-Region Distribution

- Replicate images to multiple Azure regions
- Disaster recovery with remote compute gallery support
- Configurable replica counts per region
- Storage account type selection (Standard LRS/ZRS)

## Architecture

### Build Process Flow

1. **VM Deployment**
   - Deploy Orchestration VM (Windows Server 2019 Core)
   - Deploy Image VM (source OS from marketplace or gallery)

2. **Image Customization** (Orchestration VM manages Image VM)
   - Download artifacts from storage account
   - Execute pre-restart customizations
   - Install Microsoft content (FSLogix, Office, OneDrive, Teams)
   - Remove AppX packages
   - Apply WDOT optimizations
   - Run custom scripts and installers
   - Install Windows Updates
   - Execute VDI customizations (no restart)
   - Clean up desktop shortcuts

3. **Image Capture**
   - Stop and generalize VM (sysprep)
   - Capture image to Compute Gallery
   - Create image version with replication

4. **Cleanup**
   - Delete build VMs and associated resources
   - Retain customization logs (7 days)

## Prerequisites

### Required Azure Resources

1. **Azure Compute Gallery**
   - Existing gallery for image storage
   - Located in subscription where deployment occurs

2. **Virtual Network & Subnet**
   - Subnet for image build VM
   - Must allow outbound connectivity for updates/downloads
   - Service endpoint or private endpoint for storage (zero trust)

3. **Azure Blob Storage** (Zero Trust)
   - Storage account with blob container
   - Contains artifacts (scripts, installers, config files)
   - User-assigned managed identity with "Storage Blob Data Reader" role

4. **User-Assigned Managed Identity** (Zero Trust)
   - Assigned "Storage Blob Data Reader" on artifacts storage
   - Automatically assigned "Virtual Machine Contributor" and "Storage Blob Data Contributor" on build resource group

### Optional Resources

5. **Private DNS Zones** (Private Endpoints)

   - `privatelink.blob.core.windows.net` (Azure Commercial)
   - `privatelink.blob.core.usgovcloudapi.net` (Azure Government)

6. **Remote Compute Gallery** (Disaster Recovery)

   - Second gallery in different region
   - For multi-region image distribution

### Deploy Prerequisites

Use the included PowerShell script to automate prerequisite deployment:

```powershell
.\Deploy-ImageManagement.ps1 `
  -Location 'eastus' `
  -Environment 'prod' `
  -BlobStorageAccountNetworkAccess 'PrivateEndpoint' `
  -PrivateEndpointSubnetResourceId '/subscriptions/.../subnets/endpoints'
```

See [Deploy-ImageManagement-README.md](../../docs/Deploy-ImageManagement-README.md) for details.

## Parameters

### Deployment Basics

#### `location`

- **Type:** String
- **Description:** Azure region for deployment (image version default region)
- **Example:** `eastus`, `usgovvirginia`

#### `deploymentPrefix`

- **Type:** String (2-6 characters)
- **Description:** Prefix for deployment names
- **Example:** `imgbld`, `avd`

#### `nameConvResTypeAtEnd`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Reverse CAF naming (resource type at end)
- **Example:** `false` = `rg-image-build`, `true` = `image-build-rg`

### Resource Groups

#### `imageBuildResourceGroupId`

- **Type:** String
- **Description:** Existing resource group ID for build resources (leave empty to create new)
- **Example:** `/subscriptions/{sub-id}/resourceGroups/rg-image-build`

#### `customBuildResourceGroupName`

- **Type:** String
- **Description:** Custom name for new build resource group (only if not using existing)
- **Example:** `rg-avd-image-builds-prod`

### Prerequisites

#### `computeGalleryResourceId`

- **Type:** String (Required)
- **Description:** Resource ID of Azure Compute Gallery
- **Example:** `/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gallery}`

#### `artifactsContainerUri`

- **Type:** String
- **Description:** Full URI of artifacts blob container (with trailing slash)
- **Example:** `https://saimgassets.blob.core.windows.net/artifacts/`

#### `userAssignedIdentityResourceId`

- **Type:** String
- **Description:** Resource ID of managed identity with storage access
- **Example:** `/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{identity}`

#### `subnetResourceId`

- **Type:** String (Required)
- **Description:** Subnet for image build VM
- **Example:** `/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/{subnet}`

### Virtual Machine Properties

#### `vmSize`

- **Type:** String
- **Default:** `Standard_D4ads_v6`
- **Description:** VM size for both orchestration and image VMs
- **Recommended:** `Standard_D4ads_v6`, `Standard_D8ads_v6`, `Standard_D4ads_v5`

#### `encryptionAtHost`

- **Type:** Boolean
- **Default:** `true`
- **Description:** Enable encryption at host for VM disks

### Image Source

#### `customSourceImageResourceId`

- **Type:** String
- **Description:** Compute Gallery image resource ID (if using existing image)
- **Example:** `/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gallery}/images/{image-def}/versions/latest`

#### `mpPublisher`

- **Type:** String (Required if marketplace)
- **Default:** `MicrosoftWindowsDesktop`
- **Values:** `MicrosoftWindowsDesktop`, `MicrosoftWindowsServer`

#### `mpOffer`

- **Type:** String (Required if marketplace)
- **Default:** `windows-11`
- **Values:** `Windows-10`, `windows-11`, `office-365`, `WindowsServer`

#### `mpSku`

- **Type:** String (Required if marketplace)
- **Default:** `win11-24h2-avd`
- **Examples:** `win11-24h2-avd`, `win10-22h2-avd`, `2022-datacenter-g2`

### Image Customizations - Microsoft Content

#### `downloadLatestMicrosoftContent`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Download latest FSLogix, M365, OneDrive, Teams from web instead of storage

#### `installFsLogix`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Install FSLogix Apps agent

#### `office365AppsToInstall`

- **Type:** Array
- **Default:** `[]`
- **Allowed Values:** `Access`, `Excel`, `OneNote`, `Outlook`, `PowerPoint`, `Publisher`, `Word`, `Project`, `Visio`, `SkypeForBusiness`
- **Example:** `["Excel", "Outlook", "PowerPoint", "Word"]`

#### `installOneDrive`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Install OneDrive in per-machine mode (VDI)

#### `installTeams`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Install New Teams for VDI with media optimizations

#### `teamsCloudType`

- **Type:** String
- **Default:** `Commercial`
- **Allowed Values:** `Commercial`, `GCC`, `GCCH`, `DoD`, `GovSecret`, `GovTopSecret`, `Gallatin`

#### `applyWindowsDesktopOptimizations`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Apply Windows Desktop Optimization Tool customizations

### Image Customizations - AppX Removal

#### `appsToRemove`

- **Type:** Array
- **Default:** `[]`
- **Description:** List of AppX packages to remove
- **Example:** `["Microsoft.BingWeather", "Microsoft.XboxApp", "Microsoft.ZuneMusic"]`

### Image Customizations - Custom Software

#### `customizations`

- **Type:** Array of Objects
- **Description:** Custom scripts/software to install before sysprep (can survive restarts)
- **Object Properties:**
  - `name` (required): Customization name (alphanumeric, no spaces)
  - `blobNameOrUri` (required): Blob name or full URI
  - `arguments` (optional): Installation arguments
  - `restart` (optional): Introduce restart after execution

**Example:**

```json
[
  {
    "name": "VSCode",
    "blobNameOrUri": "VSCode.zip",
    "arguments": "/verysilent /mergetasks=!runcode",
    "restart": false
  },
  {
    "name": "CustomApp",
    "blobNameOrUri": "https://storage.blob.core.windows.net/artifacts/app.exe",
    "arguments": "/quiet /norestart"
  }
]
```

#### `vdiCustomizations`

- **Type:** Array of Objects
- **Description:** VDI-specific installations just before sysprep (no restart, generates IDs after reboot)
- **Object Properties:** Same as `customizations` except no `restart` property

**Example:**

```json
[
  {
    "name": "MonitoringAgent",
    "blobNameOrUri": "agent.msi",
    "arguments": "/quiet MODE=VDI"
  }
]
```

### Image Customizations - Other

#### `cleanupDesktop`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Remove all shortcuts from common desktop

### Windows Updates

#### `installUpdates`

- **Type:** Boolean
- **Default:** `true`
- **Description:** Install Windows updates during image build

#### `updateService`

- **Type:** String
- **Default:** `MU`
- **Allowed Values:** `MU` (Microsoft Update), `WU` (Windows Update), `WSUS`, `DCAT`, `STORE`, `OTHER`

#### `wsusServer`

- **Type:** String
- **Description:** WSUS server URL (required if updateService=WSUS)
- **Example:** `https://wsus.corp.contoso.com:8531`

### Logging

#### `collectCustomizationLogs`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Collect customization logs to storage account (retained 7 days)

#### `logStorageAccountNetworkAccess`

- **Type:** String
- **Default:** `PublicEndpoint`
- **Allowed Values:** `PrivateEndpoint`, `ServiceEndpoint`, `PublicEndpoint`

#### `blobPrivateDnsZoneResourceId`

- **Type:** String
- **Description:** Private DNS zone for blob storage (if using private endpoints)
- **Example:** `/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net`

#### `privateEndpointSubnetResourceId`

- **Type:** String
- **Description:** Subnet for storage private endpoint
- **Example:** `/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/{subnet}`

### Image Definition

#### `imageDefinitionResourceId`

- **Type:** String
- **Description:** Existing image definition resource ID (leave empty to create new)
- **Example:** `/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gallery}/images/{image-def}`

#### `customImageDefinitionName`

- **Type:** String (2-80 characters)
- **Description:** Custom image definition name (only if creating new, leave blank for auto-naming)
- **Example:** `vmid-avd-win11-24h2-prod`

#### `imageDefinitionPublisher`

- **Type:** String (2-128 characters)
- **Description:** Image definition publisher (required if creating new)
- **Example:** `MicrosoftWindowsDesktop`

#### `imageDefinitionOffer`

- **Type:** String (2-64 characters)
- **Description:** Image definition offer (required if creating new)
- **Example:** `windows-11`

#### `imageDefinitionSku`

- **Type:** String (2-64 characters)
- **Description:** Image definition SKU (required if creating new)
- **Example:** `win11-24h2-avd`

#### `imageDefinitionIsAcceleratedNetworkSupported`

- **Type:** Boolean
- **Default:** `true`
- **Description:** Enable Accelerated Networking on VMs from this image

#### `imageDefinitionIsHibernateSupported`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Enable hibernation support (preview)

#### `imageDefinitionIsHigherStoragePerformanceSupported`

- **Type:** Boolean
- **Default:** `true`
- **Description:** Enable NVMe disk controller support

#### `imageDefinitionSecurityType`

- **Type:** String
- **Default:** `TrustedLaunch`
- **Allowed Values:** `Standard`, `TrustedLaunch`, `TrustedLaunchSupported`, `ConfidentialVM`, `ConfidentialVMSupported`, `TrustedLaunchAndConfidentialVMSupported`

### Image Version

#### `imageMajorVersion`

- **Type:** Integer (-1 to 9999)
- **Default:** `-1` (auto-generate)
- **Description:** Major version number (requires all three version components)

#### `imageMinorVersion`

- **Type:** Integer (-1 to 9999)
- **Default:** `-1` (auto-generate)
- **Description:** Minor version number

#### `imagePatch`

- **Type:** Integer (-1 to 9999)
- **Default:** `-1` (auto-generate)
- **Description:** Patch version number

**Note:** If all version components are `-1`, version is auto-generated as `yyyy.MMdd.HHmm` from deployment timestamp.

#### `imageVersionEOLinDays`

- **Type:** Integer (0-730+)
- **Default:** `0`
- **Description:** Days from now until image version reaches end of life

#### `imageVersionExcludeFromLatest`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Exclude this version when using "latest" tag

#### `imageVersionDefaultReplicaCount`

- **Type:** Integer (1-100)
- **Default:** `1`
- **Description:** Number of replicas per region

#### `imageVersionDefaultStorageAccountType`

- **Type:** String
- **Default:** `Standard_LRS`
- **Allowed Values:** `Standard_LRS`, `Standard_ZRS`, `Premium_LRS`

#### `imageVersionTargetRegions`

- **Type:** Array of Objects
- **Description:** Additional replication regions (default region always included)
- **Object Properties:**
  - `name` (required): Region name
  - `storageAccountType`: Storage type for this region
  - `regionalReplicaCount`: Replica count for this region
  - `excludeFromLatest`: Exclude from latest in this region

**Example:**

```json
[
  {
    "name": "westus2",
    "storageAccountType": "Standard_ZRS",
    "regionalReplicaCount": 2,
    "excludeFromLatest": false
  },
  {
    "name": "centralus",
    "storageAccountType": "Standard_LRS",
    "regionalReplicaCount": 1
  }
]
```

### Disaster Recovery

#### `remoteComputeGalleryResourceId`

- **Type:** String
- **Description:** Remote compute gallery for DR (different region)
- **Example:** `/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gallery}`

#### `remoteImageVersionExcludeFromLatest`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Exclude remote image version from latest

#### `remoteImageVersionDefaultReplicaCount`

- **Type:** Integer (1-100)
- **Default:** `1`
- **Description:** Replica count for remote region

#### `remoteImageVersionStorageAccountType`

- **Type:** String
- **Default:** `Standard_LRS`
- **Allowed Values:** `Standard_LRS`, `Standard_ZRS`

### Tagging

#### `tags`

- **Type:** Object
- **Description:** Tags to apply to resources
- **Format:** Key-value pairs grouped by resource type

**Example:**

```json
{
  "Microsoft.Resources/resourceGroups": {
    "Environment": "Production",
    "CostCenter": "IT"
  },
  "Microsoft.Compute/virtualMachines": {
    "Purpose": "ImageBuild",
    "AutoShutdown": "No"
  }
}
```

## Usage Examples

### Example 1: Basic Marketplace Image

Create Windows 11 24H2 AVD image with FSLogix and Office 365:

```bicep
targetScope = 'subscription'

module imageBuild './imageBuild.bicep' = {
  name: 'imageBuild-${utcNow('yyyyMMddHHmmss')}'
  params: {
    location: 'eastus'
    computeGalleryResourceId: '/subscriptions/{sub}/resourceGroups/rg-gallery/providers/Microsoft.Compute/galleries/gal-avd'
    subnetResourceId: '/subscriptions/{sub}/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-image'
    
    // Marketplace image
    mpPublisher: 'MicrosoftWindowsDesktop'
    mpOffer: 'windows-11'
    mpSku: 'win11-24h2-avd'
    
    // Customizations
    downloadLatestMicrosoftContent: true
    installFsLogix: true
    office365AppsToInstall: ['Excel', 'Outlook', 'PowerPoint', 'Word']
    installOneDrive: true
    installTeams: true
    
    // New image definition
    imageDefinitionPublisher: 'Contoso'
    imageDefinitionOffer: 'Windows11'
    imageDefinitionSku: 'AVD-24H2'
    imageDefinitionSecurityType: 'TrustedLaunch'
  }
}
```

### Example 2: Zero Trust with Custom Software

Build image with zero trust networking and custom software:

```bicep
targetScope = 'subscription'

module imageBuild './imageBuild.bicep' = {
  name: 'imageBuild-${utcNow('yyyyMMddHHmmss')}'
  params: {
    location: 'usgovvirginia'
    deploymentPrefix: 'prod'
    
    // Prerequisites
    computeGalleryResourceId: '/subscriptions/{sub}/resourceGroups/rg-gallery/providers/Microsoft.Compute/galleries/gal-avd-prod'
    artifactsContainerUri: 'https://saimgassets.blob.core.usgovcloudapi.net/artifacts/'
    userAssignedIdentityResourceId: '/subscriptions/{sub}/resourceGroups/rg-identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-image-builder'
    subnetResourceId: '/subscriptions/{sub}/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-image'
    
    // Source image
    mpPublisher: 'MicrosoftWindowsDesktop'
    mpOffer: 'Windows-10'
    mpSku: 'win10-22h2-avd'
    
    // Microsoft content from storage
    downloadLatestMicrosoftContent: false
    installFsLogix: true
    applyWindowsDesktopOptimizations: true
    
    // Custom software
    customizations: [
      {
        name: 'AdobeReader'
        blobNameOrUri: 'AdobeAcrobatReaderDC.exe'
        arguments: '/sPB /rs /msi EULA_ACCEPT=YES'
      }
      {
        name: 'CompanyApp'
        blobNameOrUri: 'CompanyApp.zip'
      }
    ]
    
    // Remove bloatware
    appsToRemove: [
      'Microsoft.BingNews'
      'Microsoft.BingWeather'
      'Microsoft.XboxApp'
      'Microsoft.ZuneMusic'
      'Microsoft.ZuneVideo'
    ]
    
    // Updates
    installUpdates: true
    updateService: 'WSUS'
    wsusServer: 'https://wsus.corp.contoso.com:8531'
    
    // Logging with private endpoint
    collectCustomizationLogs: true
    logStorageAccountNetworkAccess: 'PrivateEndpoint'
    privateEndpointSubnetResourceId: '/subscriptions/{sub}/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-endpoints'
    blobPrivateDnsZoneResourceId: '/subscriptions/{sub}/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.usgovcloudapi.net'
    
    // Use existing image definition
    imageDefinitionResourceId: '/subscriptions/{sub}/resourceGroups/rg-gallery/providers/Microsoft.Compute/galleries/gal-avd-prod/images/vmid-win10-22h2-avd'
    
    // Custom version
    imageMajorVersion: 2024
    imageMinorVersion: 12
    imagePatch: 1
    imageVersionEOLinDays: 90
  }
}
```

### Example 3: Multi-Region with DR

Replicate image to multiple regions with disaster recovery:

```bicep
targetScope = 'subscription'

module imageBuild './imageBuild.bicep' = {
  name: 'imageBuild-${utcNow('yyyyMMddHHmmss')}'
  params: {
    location: 'eastus'
    computeGalleryResourceId: '/subscriptions/{sub}/resourceGroups/rg-gallery-east/providers/Microsoft.Compute/galleries/gal-avd-east'
    subnetResourceId: '/subscriptions/{sub}/resourceGroups/rg-network-east/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-image'
    
    // Source
    mpPublisher: 'MicrosoftWindowsDesktop'
    mpOffer: 'windows-11'
    mpSku: 'win11-24h2-avd'
    
    // Customizations
    downloadLatestMicrosoftContent: true
    installFsLogix: true
    installOneDrive: true
    installTeams: true
    
    // Existing definition
    imageDefinitionResourceId: '/subscriptions/{sub}/resourceGroups/rg-gallery-east/providers/Microsoft.Compute/galleries/gal-avd-east/images/vmid-win11-avd'
    
    // Multi-region replication
    imageVersionTargetRegions: [
      {
        name: 'eastus'
        storageAccountType: 'Standard_ZRS'
        regionalReplicaCount: 3
        excludeFromLatest: false
      }
      {
        name: 'centralus'
        storageAccountType: 'Standard_LRS'
        regionalReplicaCount: 2
      }
      {
        name: 'westus2'
        storageAccountType: 'Standard_LRS'
        regionalReplicaCount: 1
      }
    ]
    
    // Disaster recovery to west region
    remoteComputeGalleryResourceId: '/subscriptions/{sub}/resourceGroups/rg-gallery-west/providers/Microsoft.Compute/galleries/gal-avd-west'
    remoteImageVersionStorageAccountType: 'Standard_ZRS'
    remoteImageVersionDefaultReplicaCount: 2
    remoteImageVersionExcludeFromLatest: false
  }
}
```

### Example 4: VDI Software with Unique Identifiers

Install monitoring agents that generate unique IDs:

```bicep
targetScope = 'subscription'

module imageBuild './imageBuild.bicep' = {
  name: 'imageBuild-${utcNow('yyyyMMddHHmmss')}'
  params: {
    location: 'eastus'
    computeGalleryResourceId: '/subscriptions/{sub}/resourceGroups/rg-gallery/providers/Microsoft.Compute/galleries/gal-avd'
    artifactsContainerUri: 'https://saimgassets.blob.core.windows.net/artifacts/'
    userAssignedIdentityResourceId: '/subscriptions/{sub}/resourceGroups/rg-identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-builder'
    subnetResourceId: '/subscriptions/{sub}/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-image'
    
    // Source
    mpPublisher: 'MicrosoftWindowsDesktop'
    mpOffer: 'windows-11'
    mpSku: 'win11-24h2-avd'
    
    // Standard customizations
    downloadLatestMicrosoftContent: false
    installFsLogix: true
    customizations: [
      {
        name: 'CompanyApp'
        blobNameOrUri: 'CompanyApp.msi'
        arguments: '/quiet /norestart'
      }
    ]
    
    // VDI customizations (installed last, before sysprep)
    vdiCustomizations: [
      {
        name: 'MonitoringAgent'
        blobNameOrUri: 'MonitoringAgent.msi'
        arguments: '/quiet MODE=VDI REBOOT=ReallySuppress'
      }
      {
        name: 'SecurityAgent'
        blobNameOrUri: 'SecurityAgent.zip'
        arguments: '--mode vdi --no-reboot'
      }
    ]
    
    // Use existing definition
    imageDefinitionResourceId: '/subscriptions/{sub}/resourceGroups/rg-gallery/providers/Microsoft.Compute/galleries/gal-avd/images/vmid-win11-managed'
  }
}
```

## Artifact Requirements

### Supported File Types

The solution automatically detects and handles these file types:

| Extension | Execution Method | Notes |
|-----------|------------------|-------|
| **.exe** | Direct execution | Use silent install arguments |
| **.msi** | `msiexec /i` | Automatic MSI install |
| **.ps1** | PowerShell | Executed with parameters |
| **.bat** | Command prompt | Direct execution |
| **.zip** | Extract & execute | Finds first .ps1 in root and executes |

### Artifact Storage Structure

When using Zero Trust mode, organize artifacts in blob storage:

```
artifacts/                          (container)
├── FSLogix/
│   └── FSLogix.zip
├── Office365/
│   └── Configure-Office365.zip
├── OneDrive/
│   └── Configure-OneDrive.zip
├── LGPO/
│   └── LGPO.zip
└── Custom/
    ├── CompanyApp.msi
    ├── CompanyApp.zip
    └── AdobeReader.exe
```

### ZIP Archive Format

ZIP files must contain PowerShell script in root:

**Correct:**
```
CompanyApp.zip
├── Install-CompanyApp.ps1    ← Script in root
├── CompanyApp.exe
└── config.xml
```

**Incorrect:**
```
CompanyApp.zip
└── CompanyApp/
    ├── Install-CompanyApp.ps1    ← Script in subfolder (won't be found)
    ├── CompanyApp.exe
    └── config.xml
```

## Security Considerations

### Zero Trust Implementation

**Storage Account:**
- Private endpoint or service endpoint required
- Public access disabled
- User-assigned managed identity authentication
- RBAC: "Storage Blob Data Reader" role

**Networking:**
- VM deployed to secure subnet
- Private DNS resolution for storage endpoints
- Service endpoint pinning (if used)
- No direct internet access required (except downloads)

**Identity:**
- User-assigned managed identity for storage access
- Automatic role assignments to build resource group
- No access keys stored or transmitted

### Best Practices

1. **Network Isolation**
   - Deploy VM to subnet with NSG
   - Use private endpoints for storage
   - Implement forced tunneling if required

2. **Secret Management**
   - Never store secrets in artifacts
   - Use Azure Key Vault for sensitive data
   - Pass secrets via parameters (use `protectedSettings` in ARM)

3. **Image Scanning**
   - Scan images for vulnerabilities post-build
   - Implement Microsoft Defender for Endpoint
   - Use Azure Policy for compliance

4. **Access Control**
   - RBAC on compute gallery (limit image publishing)
   - RBAC on storage account (limit artifact access)
   - Conditional access for management operations

## Logging and Troubleshooting

### Customization Logs

When `collectCustomizationLogs` is enabled:

**Log Storage:**
- Storage account created: `sa<prefix>log<uniquestring>`
- Container: `image-customization-logs`
- Retention: 7 days (lifecycle management)

**Log Files:**
```
image-customization-logs/
├── orchestration-vm-<timestamp>.log
├── image-vm-<timestamp>.log
├── customization-<name>-stdout.log
├── customization-<name>-stderr.log
└── windows-update-<timestamp>.log
```

### Common Issues

#### Issue: VM Size Not Supported

**Symptoms:** Deployment fails with VM size not available
**Solution:**
- Check regional availability: [Azure VM Products by Region](https://azure.microsoft.com/global-infrastructure/services/?products=virtual-machines)
- Verify quota limits: Azure Portal > Subscriptions > Usage + quotas
- Use recommended sizes: `Standard_D4ads_v6` or `Standard_D4ads_v5`

#### Issue: NVMe Compatibility

**Symptoms:** VM fails to deploy with NVMe support
**Solution:**
- Use v6 VM series (Dadsv6, Dadsv6, Easv6, Eadsv6)
- Check [NVMe VM list](https://learn.microsoft.com/azure/virtual-machines/nvme-overview)
- Set `imageDefinitionIsHigherStoragePerformanceSupported: false` if not needed

#### Issue: Artifact Download Fails

**Symptoms:** Customization fails, logs show HTTP 403/404
**Solution:**
- Verify `artifactsContainerUri` ends with `/`
- Check blob name is correct (case-sensitive)
- Confirm managed identity has "Storage Blob Data Reader" role
- Test connectivity: `Test-NetConnection storage-account.blob.core.windows.net -Port 443`
- Check private endpoint DNS resolution

#### Issue: Windows Update Timeout

**Symptoms:** Build exceeds expected time, update installation hanging
**Solution:**
- Check WSUS server accessibility (if used)
- Verify VM has internet access (if using WU/MU)
- Review `updateService` parameter
- Consider disabling updates for troubleshooting: `installUpdates: false`

#### Issue: Sysprep Fails

**Symptoms:** Image capture fails, sysprep errors in logs
**Solution:**
- Review VDI customizations (must support sysprep)
- Check for running services (stop before sysprep)
- Avoid `/norestart` in final customizations
- Review sysprep logs: `C:\Windows\System32\Sysprep\Panther\`

### Monitoring Deployment

**Azure Portal:**
1. Navigate to Subscriptions > Deployments
2. Find deployment: `<prefix>-imageBuild-<timestamp>`
3. Review deployment status and output
4. Check nested deployments for details

**PowerShell:**
```powershell
# Get deployment status
Get-AzSubscriptionDeployment -Name "imageBuild-20241211120000"

# Get deployment operations
Get-AzSubscriptionDeploymentOperation -Name "imageBuild-20241211120000"

# Watch deployment
Get-AzSubscriptionDeployment -Name "imageBuild-20241211120000" | Select-Object -ExpandProperty ProvisioningState
```

**Azure CLI:**
```bash
# Get deployment status
az deployment sub show --name imageBuild-20241211120000

# Watch deployment
az deployment sub show --name imageBuild-20241211120000 --query properties.provisioningState
```

## Performance Optimization

### Build Time Expectations

Typical build times (D4ads_v6 VM):

| Configuration | Approximate Time |
|---------------|------------------|
| Base image only | 30-45 minutes |
| + FSLogix | 40-50 minutes |
| + Office 365 (5 apps) | 60-90 minutes |
| + Windows Updates | +30-60 minutes |
| + Custom software (3 apps) | +15-30 minutes |
| **Total (fully customized)** | **2-3 hours** |

### Optimization Tips

1. **VM Size**
   - Use v6 series for better performance
   - Consider D8ads_v6 for faster Office/Update installs
   - NVMe support reduces disk I/O time

2. **Storage**
   - Use Standard SSD or Premium SSD for VM disks
   - Place artifacts storage in same region
   - Consider Standard_ZRS for multi-zone resilience

3. **Updates**
   - Use WSUS in same region to reduce download time
   - Pre-download updates to artifacts storage
   - Disable updates for development builds

4. **Artifacts**
   - Package multiple files in ZIP to reduce HTTP requests
   - Pre-download Microsoft content to storage (zero trust)
   - Optimize PowerShell scripts (avoid unnecessary reboots)

5. **Parallelization**
   - Run multiple builds in parallel (separate resource groups)
   - Use separate subnets to avoid IP exhaustion

## Integration

### CI/CD Pipeline (Azure DevOps)

```yaml
trigger:
  branches:
    include:
      - main
  paths:
    include:
      - artifacts/*

variables:
  - group: avd-image-variables

stages:
  - stage: UploadArtifacts
    jobs:
      - job: Upload
        steps:
          - task: AzureCLI@2
            displayName: 'Upload artifacts to storage'
            inputs:
              azureSubscription: 'AVD-ServiceConnection'
              scriptType: 'pscore'
              scriptLocation: 'inlineScript'
              inlineScript: |
                az storage blob upload-batch `
                  --account-name $(storageAccountName) `
                  --destination artifacts `
                  --source $(Build.SourcesDirectory)/artifacts `
                  --auth-mode login

  - stage: BuildImage
    dependsOn: UploadArtifacts
    jobs:
      - job: Deploy
        steps:
          - task: AzureCLI@2
            displayName: 'Deploy image build'
            inputs:
              azureSubscription: 'AVD-ServiceConnection'
              scriptType: 'pscore'
              scriptLocation: 'inlineScript'
              inlineScript: |
                $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
                az deployment sub create `
                  --location $(location) `
                  --template-file deployments/imageManagement/imageBuild/imageBuild.bicep `
                  --parameters deployments/imageManagement/imageBuild/parameters/prod.bicepparam `
                  --name "imageBuild-$timestamp" `
                  --verbose
```

### GitHub Actions

```yaml
name: Build AVD Image

on:
  push:
    branches:
      - main
    paths:
      - 'artifacts/**'
  workflow_dispatch:

env:
  AZURE_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  LOCATION: eastus

jobs:
  upload-artifacts:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Azure Login
        uses: azure/login@v1
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}
      
      - name: Upload artifacts
        run: |
          az storage blob upload-batch \
            --account-name ${{ secrets.STORAGE_ACCOUNT_NAME }} \
            --destination artifacts \
            --source ./artifacts \
            --auth-mode login

  build-image:
    needs: upload-artifacts
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Azure Login
        uses: azure/login@v1
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}
      
      - name: Deploy image build
        run: |
          TIMESTAMP=$(date +%Y%m%d%H%M%S)
          az deployment sub create \
            --location ${{ env.LOCATION }} \
            --template-file deployments/imageManagement/imageBuild/imageBuild.bicep \
            --parameters deployments/imageManagement/imageBuild/parameters/prod.bicepparam \
            --name "imageBuild-$TIMESTAMP"
```

## Versioning Strategy

### Semantic Versioning

Recommended approach for production:

```
Major.Minor.Patch
  │     │     │
  │     │     └─ Hotfixes, security patches
  │     └─────── Feature updates, new software
  └───────────── Windows version changes
```

**Examples:**
- `2024.1.0` - Windows 11 24H2, initial release
- `2024.1.1` - Same base, security patches applied
- `2024.2.0` - Same base, added new application
- `2025.1.0` - Windows 11 25H2, new major version

### Auto-Generated Versioning

Default timestamp-based versioning:

```
yyyy.MMdd.HHmm
```

**Examples:**
- `2024.1211.1430` - Built on Dec 11, 2024 at 2:30 PM
- `2024.1215.0900` - Built on Dec 15, 2024 at 9:00 AM

### End of Life Management

Set `imageVersionEOLinDays` to mark image versions for replacement:

```bicep
params: {
  imageVersionEOLinDays: 90  // Replace in 90 days
}
```

This sets the `endOfLifeDate` property, visible in Azure Portal and queryable via API.

## Cost Optimization

### Build Resources

**During Build (2-3 hours):**
- 2x VMs: ~$0.50-1.50/hour (D4ads_v6)
- Storage transactions: ~$0.01
- Network egress: ~$0.05
- **Total per build:** ~$1.00-5.00

**Post Build (no cost):**
- Build resources automatically deleted
- Only image version storage remains

### Image Storage Costs

**Compute Gallery:**
- Image definitions: Free
- Image versions: ~$0.10/GB/month (Standard LRS)
- Replication: Additional cost per region/replica

**Example:**
- 40 GB image
- 3 regions
- 2 replicas per region
- Standard LRS

**Cost:** 40 GB × 3 regions × 2 replicas × $0.10 = **$24/month**

### Cost Reduction Tips

1. **Limit Replicas**
   - Use 1 replica for dev/test
   - Scale up replicas for production only

2. **Optimize Replication**
   - Only replicate to regions where deployed
   - Use Standard_LRS instead of Standard_ZRS

3. **Lifecycle Management**
   - Set EOL dates to deprecate old versions
   - Delete unused image versions regularly

4. **Build Optimization**
   - Use smaller VM sizes for simple builds
   - Build during off-peak hours
   - Batch multiple customizations in one build

## Additional Resources

### Documentation

- [Azure Compute Gallery Overview](https://learn.microsoft.com/azure/virtual-machines/azure-compute-gallery)
- [Azure Virtual Desktop Image Management](https://learn.microsoft.com/azure/virtual-desktop/set-up-customize-master-image)
- [FSLogix Documentation](https://learn.microsoft.com/fslogix/)
- [Windows Desktop Optimization Tool](https://github.com/The-Virtual-Desktop-Team/Windows-Desktop-Optimization-Tool)

### Related Templates

- [Deploy-ImageManagement.ps1](../../docs/Deploy-ImageManagement-README.md) - Deploy prerequisites
- [Invoke-ImageBuilds.ps1](../Invoke-ImageBuilds.ps1) - Batch build multiple images
- [New-TemplateSpecs.ps1](../New-TemplateSpecs.ps1) - Create template specs

### Community

- [FederalAVD GitHub](https://github.com/Azure/FederalAVD)
- [Report Issues](https://github.com/Azure/FederalAVD/issues)
- [Contribute](https://github.com/Azure/FederalAVD/blob/main/CONTRIBUTING.md)

## Support

For issues, questions, or feature requests:

1. Check [Troubleshooting](#logging-and-troubleshooting) section above
2. Review [GitHub Issues](https://github.com/Azure/FederalAVD/issues)
3. Create new issue with:
   - Deployment details (region, parameters)
   - Error messages and logs
   - Expected vs actual behavior

## License

This project is licensed under the MIT License. See [LICENSE](../../../LICENSE) for details.

## Authors

- FederalAVD Contributors

## Version History

- **1.0.0** - Initial release with zero trust support
- **1.1.0** - Added NVMe and hibernation support
- **1.2.0** - Multi-region replication and DR features
- **1.3.0** - VDI customizations and improved logging
