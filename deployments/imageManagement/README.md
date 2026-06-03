# AVD Image Management Infrastructure Template

> **📖 User Guides:**
>
> - [Artifacts & Image Management Guide](../../docs/artifacts-guide.md) - Getting started with artifacts
> - [Image Build Guide](../../docs/image-build.md) - Building custom images
> - [Update-ImageArtifacts Script](../../docs/update-image-artifacts.md) - Uploading artifacts to storage

## Overview

This Azure Bicep template deploys the prerequisite infrastructure required for AVD custom image builds and artifact management. It creates a centralized storage location for build artifacts (scripts, installers) and Azure Compute Galleries for storing custom images.

## Purpose

Provide foundational resources for AVD image management:

- **Azure Compute Gallery** - Store and distribute custom AVD images (always deployed)
- **Storage Account** - Host build artifacts (scripts, installers, packages) (optional, default on)
- **Build Logs Storage Account** - Persist image customization logs from image builds (optional, default off)
- **Managed Identity** - Authenticate to storage without credentials (deployed when either storage account is enabled)
- **Image Build Resource Group** - Pre-created persistent RG for image build operators who lack subscription-level RG creation rights (optional, default on)
- **Remote Gallery (Optional)** - Disaster recovery in secondary region
- **Private Endpoint (Optional)** - Zero Trust network isolation

## Architecture

### Deployed Resources

```
Subscription
├── Image Management Resource Group (Primary Region)
│   ├── Azure Compute Gallery (always deployed)
│   │   └── Image Definitions (created during image builds)
│   ├── Storage Account (deployArtifactsStorageAccount = true, default)
│   │   └── Artifacts Blob Container
│   ├── Build Logs Storage Account (deployBuildLogsStorageAccount = true)
│   │   ├── image-customization-logs Blob Container
│   │   └── Lifecycle Policy (auto-delete blobs after 7 days)
│   ├── User-Assigned Managed Identity (deployArtifactsStorageAccount = true OR deployBuildLogsStorageAccount = true)
│   │   ├── RBAC: Storage Blob Data Reader on artifacts storage account
│   │   └── RBAC: Storage Blob Data Contributor on build logs storage account
│   ├── CMK Encryption Identity (keyManagementStorageAccounts != PlatformManaged)
│   │   └── RBAC: Key Vault Crypto Service Encryption User on storage encryption keys
│   ├── Gallery Disk Encryption Set (keyManagementGalleryImageVersions != PlatformManaged)
│   ├── Gallery Confidential VM Disk Encryption Set (createConfidentialVmGalleryDes = true)
│   └── Private Endpoint(s) (optional, one per storage account)
│       └── Network Interface
├── Image Build Resource Group (deployImageBuildResourceGroup = true)
│   └── RBAC: Managed Identity → Contributor
```

### Identity & Access

The managed identity is automatically assigned:

- **Storage Blob Data Reader** on the artifacts storage account (when `deployArtifactsStorageAccount = true`)
- **Storage Blob Data Contributor** on the build logs storage account (when `deployBuildLogsStorageAccount = true`)
- Used by image build VMs to download artifacts and write customization logs without storage account keys

## Prerequisites

### Required Deployer Permissions

The Azure identity running this deployment needs:

| Role | Scope | Why |
|---|---|---|
| Owner **or** Contributor + User Access Administrator | Subscription | Creates resource groups; assigns Contributor to the managed identity on the image build RG, Storage Blob Data Reader on the artifacts storage account, and Storage Blob Data Contributor on the build logs storage account |

### Required Information

- **Subscription ID** - Where to deploy resources
- **Location** - Primary Azure region (e.g., `usgovvirginia`, `eastus2`)

### Optional Prerequisites

- **Private Endpoint Subnet** - For Zero Trust deployments
- **Azure Blob Private DNS Zone** - For private endpoint DNS resolution
- **Log Analytics Workspace** - For storage account diagnostic logs
- **Remote Location** - Secondary region for disaster recovery gallery

## Parameters

### Core Settings

#### `location`

- **Type:** String
- **Default:** `deployment().location`
- **Description:** Azure region for primary resources

#### `nameConvResTypeAtEnd`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Reverse CAF naming convention
  - `false` - `rg-avd-image-management-use2`
  - `true` - `avd-image-management-use2-rg`

### Storage Configuration

#### `deployArtifactsStorageAccount`

- **Type:** Boolean
- **Default:** `true`
- **Description:** Deploy the artifacts storage account, blob container, and managed identity. Set to `false` when only the gallery is needed.

#### `keyManagementStorageAccounts`

- **Type:** String
- **Default:** `PlatformManaged`
- **Allowed Values:** `PlatformManaged`, `CustomerManaged`, `CustomerManagedHSM`
- **Description:** Encryption key management for the storage accounts in this deployment. When `CustomerManaged` or `CustomerManagedHSM`, a shared encryption UAI and per-account keys are created in the specified Key Vault.

#### `keyManagementGalleryImageVersions`

- **Type:** String
- **Default:** `PlatformManaged`
- **Allowed Values:** `PlatformManaged`, `CustomerManaged`, `CustomerManagedHSM`, `PlatformManagedAndCustomerManaged`, `PlatformManagedAndCustomerManagedHSM`
- **Description:** Encryption key management for gallery image versions. When any customer-managed option is selected, a standard Disk Encryption Set (DES) is always created. `PlatformManagedAndCustomerManaged*` variants add a second platform-key layer for double encryption at rest. Pass the `diskEncryptionSetResourceId` output to each imageBuild deployment as `diskEncryptionSetResourceId`.

#### `createConfidentialVmGalleryDes`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Deploy a second DES of type `ConfidentialVmEncryptedWithCustomerKey` for gallery image versions intended for ConfidentialVM session host deployments. Requires a Premium Key Vault and the CVM Orchestrator enterprise application to be registered in the tenant. The CVM DES always uses an RSA-HSM key regardless of the `keyManagementGalleryImageVersions` selection. A standard gallery DES is always created alongside it. **WARNING:** The Confidential VM key release policy is immutable once set — re-deploying with this option enabled will fail if the key already exists. Enable only on the first deployment per region.

#### `confidentialVMOrchestratorObjectId`

- **Type:** String
- **Optional**
- **Description:** Object ID of the Confidential VM Orchestrator enterprise application in the tenant (app ID: `bf7b6499-ff71-4aa2-97a4-f372087be7f0`). Required when `createConfidentialVmGalleryDes = true`. Retrieve with: `Get-AzADServicePrincipal -ApplicationId 'bf7b6499-ff71-4aa2-97a4-f372087be7f0' | Select-Object -ExpandProperty Id`

### Networking & Security

#### `storageNetworkAccess`

- **Type:** String
- **Default:** `PublicEndpoint`
- **Allowed Values:** `PublicEndpoint`, `PrivateEndpoint`, `ServiceEndpoint`
- **Description:** Network access mode for both storage accounts.
  - `PublicEndpoint` — public access open to all (or restricted to `storagePermittedIPs` if provided)
  - `PrivateEndpoint` — private endpoint deployed; public access disabled unless `storagePermittedIPs` is also provided
  - `ServiceEndpoint` — storage ACL updated to allow specified subnets only; template does **not** deploy service endpoints to the subnets

#### `privateEndpointSubnetResourceId`

- **Type:** String
- **Optional**
- **Description:** Subnet resource ID for private endpoint
- **Example:** `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/snet-endpoints`
- **Use when:** Zero Trust architecture with private endpoints

#### `azureBlobPrivateDnsZoneResourceId`

- **Type:** String
- **Optional**
- **Description:** Private DNS zone resource ID for blob storage
- **Example:** `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.usgovcloudapi.net`
- **Required when:** Using private endpoint

#### `storagePermittedIPs`

- **Type:** Array
- **Optional**
- **Description:** Allowed IP addresses or CIDR blocks for public endpoint access
- **Example:** `["203.0.113.0/24", "198.51.100.10"]`

#### `storageServiceEndpointSubnetResourceIds`

- **Type:** Array
- **Optional**
- **Description:** Subnet resource IDs for service endpoint access
- **Example:** `["/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/snet-build"]`

### Disaster Recovery

Image version replication to a remote region is configured per imageBuild deployment via the `remoteComputeGalleryResourceId` parameter. No remote gallery is deployed by imageManagement.

### Monitoring & Tagging

#### `tags`

- **Type:** Object
- **Optional**
- **Description:** Tags to apply to resources

### Encryption (Customer-Managed Keys)

#### `encryptionKeyVaultResourceId`

- **Type:** String
- **Optional**
- **Description:** Resource ID of the Key Vault used for CMK encryption. Required when `keyManagement` is not `PlatformManaged`. Vault must have soft delete and purge protection enabled. The same vault is used for both storage accounts and gallery image version encryption.
- **Example:** `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{vault}`

#### `keyExpirationInDays`

- **Type:** Integer
- **Default:** `180`
- **Description:** Days before the CMK key version is automatically rotated. Applies to all encrypted resources.

### Build Logs Storage Account

#### `deployBuildLogsStorageAccount`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Deploy a dedicated storage account for persisting image build customization logs. When enabled, pass the `buildLogsStorageAccountResourceId` output to imageBuild deployments as `logStorageAccountResourceId`. The managed identity is automatically granted **Storage Blob Data Contributor** on this account.

### Image Build Resource Group

#### `deployImageBuildResourceGroup`

- **Type:** Boolean
- **Default:** `true`
- **Description:** Pre-creates a persistent resource group dedicated to image builds and grants the imageManagement managed identity **Contributor** on it. The primary purpose is **delegation**: image build operators who do not have subscription-level permissions to create resource groups can run image builds by pointing imageBuild to this pre-created resource group via the `imageBuildResourceGroupId` parameter. Disable only if all image build operators have sufficient permissions to create resource groups at the subscription level. Pass the `imageBuildResourceGroupResourceId` output directly to imageBuild as `imageBuildResourceGroupId`.

#### `customImageBuildResourceGroupName`

- **Type:** String
- **Optional**
- **Description:** Override the auto-generated image build resource group name. Leave empty to use the standard naming convention. Pass the `imageBuildResourceGroupResourceId` output directly to imageBuild as `imageBuildResourceGroupId`.
- **Example:** `rg-avd-image-builds-use2`

## Parameter Files

Example parameter files are provided in the `parameters\` directory. Copy and rename one to match your environment, then fill in the placeholder values (`<...>`).

| File | Description |
| :--- | :---------- |
| `sample-basic.imageManagement.parameters.json` | Artifacts storage only, public endpoint |
| `sample-privateEndpoint.imageManagement.parameters.json` | Artifacts + logs storage, private endpoints, fully private |
| `sample-serviceEndpoint.imageManagement.parameters.json` | Artifacts + logs storage, service endpoint subnet access |
| `sample-production.imageManagement.parameters.json` | Full production: CMK, remote gallery, IP restrictions, tags |

Naming convention for custom files: `<prefix>.imageManagement.parameters.json`

## Deployment

### Azure Portal (Blue Button)

Commercial and Government clouds only:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FimageManagement%2FimageManagement.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FimageManagement%2FuiFormDefinition.json)
[![Deploy to Azure Gov](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FimageManagement%2FimageManagement.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FimageManagement%2FuiFormDefinition.json)

> **Air-gapped clouds (Azure Secret/Top Secret):** Use the PowerShell script below.

### Deploy-ImageManagement.ps1 (Recommended)

Use the provided `Deploy-ImageManagement.ps1` script in the `deployments\` folder. It prefers customer-owned parameter files in `customer\parameters\imageManagement\<Prefix>.imageManagement.parameters.json` and falls back to the repo examples in `imageManagement\parameters\<Prefix>.imageManagement.parameters.json`.

If you keep customer overrides outside the extracted repo zip, pass `-CustomerRootPath <path>` so the script reads parameters from your external customer folder.

```powershell
cd deployments

# Basic deployment
.\Deploy-ImageManagement.ps1 -Location usgovvirginia -ParameterFilePrefix basic

# Use an external customer folder
.\Deploy-ImageManagement.ps1 -Location usgovvirginia -ParameterFilePrefix basic -CustomerRootPath D:\FederalAVD\customer

# Private endpoint deployment
.\Deploy-ImageManagement.ps1 -Location usgovvirginia -ParameterFilePrefix privateEndpoint

# Production deployment
.\Deploy-ImageManagement.ps1 -Location usgovvirginia -ParameterFilePrefix production

# Deploy infrastructure AND immediately upload artifacts in one step
.\Deploy-ImageManagement.ps1 -Location usgovvirginia -ParameterFilePrefix basic -UpdateArtifacts
```

The script prints all deployment outputs. Use `-UpdateArtifacts` to automatically invoke `Update-ImageArtifacts.ps1` immediately after deployment using the storage account resource ID from the deployment outputs — useful for first-time setup when you want everything ready in one command.

### PowerShell (Direct)

```powershell
New-AzDeployment `
  -Location 'usgovvirginia' `
  -TemplateFile '.\imageManagement\imageManagement.json' `
    -TemplateParameterFile '..\customer\parameters\imageManagement\basic.imageManagement.parameters.json' `
  -Name "ImageManagement-$(Get-Date -Format 'yyyyMMddHHmmss')"
```

### Azure CLI

```bash
az deployment sub create \
  --location usgovvirginia \
  --template-file ./imageManagement/imageManagement.json \
    --parameters @../customer/parameters/imageManagement/basic.imageManagement.parameters.json \
  --name "ImageManagement-$(date +%Y%m%d%H%M%S)"
```

## Outputs

### `computeGalleryResourceId`

- **Type:** String
- **Description:** Resource ID of the Azure Compute Gallery
- **Example:** `/subscriptions/{sub}/resourceGroups/rg-avd-image-management-use2/providers/Microsoft.Compute/galleries/gal_avd_image_management_use2`
- **Used by:** Image build deployments

### `artifactsStorageAccountResourceId`

- **Type:** String
- **Description:** Resource ID of the artifacts storage account. Empty string when `deployArtifactsStorageAccount = false`.
- **Example:** `/subscriptions/{sub}/resourceGroups/rg-avd-image-management-use2/providers/Microsoft.Storage/storageAccounts/saimgassetsuse2abc123`

### `artifactsBlobContainerUrl`

- **Type:** String
- **Description:** Full URL of the artifacts blob container. Empty string when `deployArtifactsStorageAccount = false`.
- **Example:** `https://saimgassetsuse2abc123.blob.core.usgovcloudapi.net/artifacts/`
- **Used by:** Image build deployments to download artifacts

### `managedIdentityResourceId`

- **Type:** String
- **Description:** Resource ID of the managed identity. Empty string when both `deployArtifactsStorageAccount` and `deployBuildLogsStorageAccount` are `false`.
- **Example:** `/subscriptions/{sub}/resourceGroups/rg-avd-image-management-use2/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-avd-image-management-use2`
- **Used by:** Image build VMs to authenticate to storage

### `buildLogsStorageAccountResourceId`

- **Type:** String
- **Description:** Resource ID of the build logs storage account (empty string if `deployBuildLogsStorageAccount = false`)
- **Used by:** Pass as `logStorageAccountResourceId` in imageBuild deployments
- **Example:** `/subscriptions/{sub}/resourceGroups/rg-avd-image-management-use2/providers/Microsoft.Storage/storageAccounts/stbuildlogsuse2abc123`

### `buildLogsContainerUri`

- **Type:** String
- **Description:** Full URI of the build logs blob container (empty string if `deployBuildLogsStorageAccount = false`)
- **Example:** `https://stbuildlogsuse2abc123.blob.core.usgovcloudapi.net/image-customization-logs`

### `diskEncryptionSetResourceId`

- **Type:** String
- **Description:** Resource ID of the standard Disk Encryption Set used for gallery image version encryption and build VM OS disks. Empty string when `keyManagementGalleryImageVersions = PlatformManaged`.
- **Example:** `/subscriptions/{sub}/resourceGroups/rg-avd-image-management-use2/providers/Microsoft.Compute/diskEncryptionSets/des-image-management-gallery-customer-keys-use2`
- **Used by:** Pass as `diskEncryptionSetResourceId` in every imageBuild deployment when CMK is enabled.

### `confidentialVmDiskEncryptionSetResourceId`

- **Type:** String
- **Description:** Resource ID of the Confidential VM Disk Encryption Set (`ConfidentialVmEncryptedWithCustomerKey`). Empty string when `createConfidentialVmGalleryDes = false`.
- **Example:** `/subscriptions/{sub}/resourceGroups/rg-avd-image-management-use2/providers/Microsoft.Compute/diskEncryptionSets/des-image-management-gallery-confidential-vm-keys-use2`
- **Used by:** Pass as `confidentialVMDiskEncryptionSetResourceId` in imageBuild deployments targeting ConfidentialVM image definitions.

### `imageBuildResourceGroupResourceId`

- **Type:** String
- **Description:** Full resource ID of the pre-created image build resource group. Empty string when `deployImageBuildResourceGroup = false`.
- **Example:** `/subscriptions/{sub}/resourceGroups/rg-avd-image-builds-use2`
- **Used by:** Pass directly to imageBuild as `imageBuildResourceGroupId`.

### 1. Upload Artifacts to Storage

After deployment, use the `Update-ImageArtifacts.ps1` script to download, package, and upload artifacts:

```powershell
cd deployments
.\Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId "<artifactsStorageAccountResourceId from deployment output>"
```

> See [Update-ImageArtifacts Script](../../docs/update-image-artifacts.md) for all options and air-gapped usage

### 2. Note Output Values

Save the following output values for image build deployments:

- **Note:** When `deployArtifactsStorageAccount = false`, outputs `artifactsStorageAccountResourceId`, `artifactsBlobContainerName`, `artifactsBlobContainerUrl`, and `managedIdentityResourceId` return empty strings.

### 3. Deploy Image Builds

Use these resources to build custom images:

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile "..\imageBuild\imageBuild.json" `
  -computeGalleryResourceId $computeGalleryResourceId `
  -artifactsContainerUri $artifactsContainerUri `
  -userAssignedIdentityResourceId $managedIdentityResourceId `
  -Name "avd-image-build-$(Get-Date -Format 'yyyyMMddHHmm')"
```

> See [Image Build Guide](../../docs/image-build.md) for details

## Examples

### Minimal — Gallery + Artifacts Storage (Public Endpoint)

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {}
}
```

All defaults: gallery + artifacts storage account, public endpoint. Suitable for PoC or air-gapped environments where a private endpoint is not required.

### Private Endpoint (Zero Trust)

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "storageNetworkAccess": { "value": "PrivateEndpoint" },
        "privateEndpointSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-use2/providers/Microsoft.Network/virtualNetworks/vnet-avd-use2/subnets/privateEndpoints"
        },
        "azureBlobPrivateDnsZoneResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-networking-use2/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
        },
        "deployBuildLogsStorageAccount": { "value": true }
    }
}
```

### Service Endpoint (Semi-Private)

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "storageNetworkAccess": { "value": "ServiceEndpoint" },
        "storageServiceEndpointSubnetResourceIds": {
            "value": [
                "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-use2/providers/Microsoft.Network/virtualNetworks/vnet-avd-use2/subnets/hosts"
            ]
        },
        "storagePermittedIPs": { "value": ["203.0.113.0/24"] }
    }
}
```

### Production — CMK, Build Logs, Remote Gallery, Tags

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "storageNetworkAccess": { "value": "PrivateEndpoint" },
        "privateEndpointSubnetResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-networking-use2/providers/Microsoft.Network/virtualNetworks/vnet-avd-use2/subnets/privateEndpoints"
        },
        "azureBlobPrivateDnsZoneResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-networking-use2/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
        },
        "deployBuildLogsStorageAccount": { "value": true },
        "keyManagementStorageAccounts": { "value": "CustomerManaged" },
        "keyManagementGalleryImageVersions": { "value": "CustomerManaged" },
        "encryptionKeyVaultResourceId": {
            "value": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-avd-operations-use2/providers/Microsoft.KeyVault/vaults/kv-avd-enc-use2-abc"
        },
        "tags": {
            "value": {
                "Microsoft.Storage/storageAccounts": { "environment": "Production", "team": "ImageManagement" },
                "Microsoft.Compute/galleries": { "environment": "Production", "team": "ImageManagement" }
            }
        }
    }
}
```

## Security Considerations

### Storage Account Security

**Public Access (Default)**

- Use `storagePermittedIPs` to restrict access to known IPs or CIDR ranges
- Use `storageServiceEndpointSubnetResourceIds` with `storageNetworkAccess = ServiceEndpoint` to allow specific subnets
- Shared key access is disabled by default (`storageAllowSharedKeyAccess = false`)

**Private Endpoint**

- Set `storageNetworkAccess = PrivateEndpoint` — public access is fully disabled unless `storagePermittedIPs` is also provided
- Deploy private endpoint with `privateEndpointSubnetResourceId`
- Link private DNS zone with `azureBlobPrivateDnsZoneResourceId`

**Private Endpoint + Public IP Allow-list**

- Set `storageNetworkAccess = PrivateEndpoint` and populate `storagePermittedIPs`
- Internal traffic uses the private endpoint; specified IPs are allowed over the public endpoint

### Identity-Based Access

- Managed identity uses **RBAC** (Role-Based Access Control)
- No storage account keys stored or transmitted
- Audit access through Azure Activity logs
- Principle of least privilege (Storage Blob Data Reader only)

### Artifact Security

- Store sensitive installers/scripts in secured blob container
- Use managed identity for access (no credentials in code)
- Enable blob versioning for artifact change tracking
- Consider blob encryption with customer-managed keys (CMK)

## Cost Optimization

### Storage Costs

| SKU | Use Case | Cost |
|-----|----------|------|
| **Standard_LRS** | Development, non-critical | Lowest |
| **Standard_ZRS** | Production, single region HA | Low |
| **Standard_GRS** | Multi-region replication | Medium |
| **Premium_LRS** | High-IOPS (rarely needed for artifacts) | High |

### Recommendations

- Use **Standard_ZRS** for production (balance cost/reliability)
- Use **Hot** access tier (artifacts accessed frequently during builds)
- Set `storageSASExpirationPeriod` appropriately (default 180 days)
- Delete old artifact versions periodically
- Use **remote gallery** only if multi-region replication needed

### Compute Gallery Costs

- **No cost** for gallery itself
- **Image storage** charged per region (GB/month)
- **Replication** charged per GB transferred
- Optimize by limiting `replicationRegions` in image builds

## Troubleshooting

### Storage Account Access Issues

**"403 Forbidden" when accessing storage**
- Verify managed identity has **Storage Blob Data Reader** role
- Check firewall rules allow source IP or subnet
- Confirm private endpoint DNS resolution (if using private endpoint)

**Private endpoint not resolving**
- Verify private DNS zone is linked to VNet
- Check DNS resolution: `nslookup {storage-account}.blob.core.usgovcloudapi.net`
- Should resolve to private IP (10.x.x.x)

**Service endpoint not working**
- Verify subnet has service endpoint enabled: `Microsoft.Storage`
- Check storage firewall includes subnet resource ID
- NSG must allow outbound to Storage service tag

### Compute Gallery Issues

**Image definition creation fails**
- Gallery must be created first (by this template)
- Image definitions created by image build deployments
- Verify gallery resource ID is correct

**Remote gallery replication fails**
- Check `remoteLocation` is valid Azure region
- Verify subscription has quota in remote region
- Remote gallery created automatically by this template

## Additional Resources

- 📖 [Artifacts & Image Management Guide](../../docs/artifacts-guide.md) - Comprehensive artifact guide
- 📖 [Image Build Guide](../../docs/image-build.md) - Building custom images
- 📖 [Update-ImageArtifacts Script](../../docs/update-image-artifacts.md) - Script documentation
- 📖 [Deploy-ImageManagement Script](Deploy-ImageManagement.ps1) - Deployment script
- 🔧 [Azure Compute Gallery Documentation](https://learn.microsoft.com/azure/virtual-machines/azure-compute-gallery)
- 🔧 [Azure Storage Security](https://learn.microsoft.com/azure/storage/common/storage-security-guide)
- 🔧 [Managed Identities Documentation](https://learn.microsoft.com/azure/active-directory/managed-identities-azure-resources/)

## Support

For issues, questions, or contributions:
- **GitHub Issues:** [Azure/FederalAVD/issues](https://github.com/Azure/FederalAVD/issues)
- **Documentation:** [docs/](../../docs/)

## License

This project is licensed under the MIT License - see the [LICENSE](../../LICENSE) file for details.
