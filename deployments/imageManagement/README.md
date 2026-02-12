# AVD Image Management Infrastructure Template

> **📖 User Guides:**
> - [Artifacts & Image Management Guide](../../docs/artifactsGuide.md) - Getting started with artifacts
> - [Image Build Guide](../../docs/imageBuild.md) - Building custom images
> - [Deploy-ImageManagement Script](../../docs/imageManagementScript.md) - Automated deployment script

## Overview

This Azure Bicep template deploys the prerequisite infrastructure required for AVD custom image builds and artifact management. It creates a centralized storage location for build artifacts (scripts, installers) and Azure Compute Galleries for storing custom images.

## Purpose

Provide foundational resources for AVD image management:

- **Azure Compute Gallery** - Store and distribute custom AVD images
- **Storage Account** - Host build artifacts (scripts, installers, packages)
- **Managed Identity** - Authenticate to storage without credentials
- **Remote Gallery (Optional)** - Disaster recovery in secondary region
- **Private Endpoint (Optional)** - Zero Trust network isolation

## Architecture

### Deployed Resources

```
Subscription
├── Image Management Resource Group (Primary Region)
│   ├── Azure Compute Gallery
│   │   └── Image Definitions (created during image builds)
│   ├── Storage Account
│  │   └── Artifacts Blob Container
│   ├── User-Assigned Managed Identity
│   │   └── RBAC: Storage Blob Data Reader (on storage account)
│   └── Private Endpoint (optional)
│       └── Network Interface
└── Remote Resource Group (Secondary Region, optional)
    └── Azure Compute Gallery (for regional replication)
```

### Identity & Access

The managed identity is automatically assigned:
- **Storage Blob Data Reader** role on the artifacts storage account
- Used by image build VMs to download artifacts without storage account keys

## Prerequisites

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

#### `customIdentifier`
- **Type:** String (3-63 chars)
- **Optional**
- **Default:** `image-management`
- **Description:** Custom workload identifier for naming
- **Example:** `img-core`, `avd-images-prod`

#### `nameConvResTypeAtEnd`
- **Type:** Boolean
- **Default:** `false`
- **Description:** Reverse CAF naming convention
  - `false` - `rg-avd-image-management-use2`
  - `true` - `avd-image-management-use2-rg`

### Storage Configuration

#### `artifactsContainerName`
- **Type:** String (3-63 chars)
- **Default:** `artifacts`
- **Description:** Blob container name for artifacts
- **Constraints:** Must start with letter, lowercase letters/numbers/hyphens only

#### `storageSkuName`
- **Type:** String
- **Default:** `Standard_LRS`
- **Allowed Values:**
  - `Standard_LRS` - Locally redundant (lowest cost)
  - `Standard_ZRS` - Zone redundant (HA in single region)
  - `Standard_GRS` - Geo-redundant (cross-region replication)
  - `Standard_RAGRS` - Read-access geo-redundant
  - `Premium_LRS` - Premium locally redundant (SSD-backed)
  - `Premium_ZRS` - Premium zone redundant
  - `Standard_GZRS` - Geo-zone redundant
  - `Standard_RAGZRS` - Read-access geo-zone redundant

#### `storageAccessTier`
- **Type:** String
- **Default:** `Hot`
- **Allowed Values:** `Premium`, `Hot`, `Cool`
- **Description:** Blob access tier for cost optimization

#### `storageAllowSharedKeyAccess`
- **Type:** Boolean
- **Default:** `true`
- **Description:** Allow storage account key access (disable for Zero Trust)

#### `storageSASExpirationPeriod`
- **Type:** String
- **Default:** `180.00:00:00` (180 days)
- **Format:** `DD.HH:MM:SS`
- **Description:** SAS token expiration period

### Networking & Security

#### `storagePublicNetworkAccess`
- **Type:** String
- **Default:** `Enabled`
- **Allowed Values:** `Enabled`, `Disabled`
- **Description:** Public network access to storage account
- **Note:** Use `Disabled` with private endpoint for Zero Trust

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

#### `remoteLocation`
- **Type:** String
- **Optional**
- **Description:** Secondary Azure region for remote gallery
- **Example:** `usgovarizona` (if primary is `usgovvirginia`)
- **Use when:** Multi-region image replication needed

### Monitoring & Tagging

#### `logAnalyticsWorkspaceResourceId`
- **Type:** String
- **Optional**
- **Description:** Log Analytics workspace for storage diagnostic logs
- **Example:** `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{workspace}`

#### `tags`
- **Type:** Object
- **Optional**
- **Description:** Tags to apply to resources
- **Example:**
  ```json
  {
    "Microsoft.Compute/galleries": {
      "Environment": "Production",
      "Purpose": "AVD Image Management"
    },
    "Microsoft.Storage/storageAccounts": {
      "Environment": "Production",
      "DataClassification": "Internal"
    }
  }
  ```

#### `timeStamp`
- **Type:** String
- **Default:** `utcNow('yyyyMMddhhmm')`
- **Description:** Timestamp for deployment uniqueness (DO NOT MODIFY)

## Usage Examples

### Example 1: Basic Deployment

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\imageManagement.bicep" `
  -artifactsContainerName "artifacts" `
  -storageSkuName "Standard_ZRS" `
  -Name "avd-image-mgmt-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Example 2: Zero Trust with Private Endpoint

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\imageManagement.bicep" `
  -artifactsContainerName "artifacts" `
  -storageSkuName "Standard_ZRS" `
  -storagePublicNetworkAccess "Disabled" `
  -privateEndpointSubnetResourceId "/subscriptions/{sub}/resourceGroups/rg-avd-networking-usgv/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-endpoints" `
  -azureBlobPrivateDnsZoneResourceId "/subscriptions/{sub}/resourceGroups/rg-avd-privatedns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.usgovcloudapi.net" `
-  storageAllowSharedKeyAccess $false `
  -Name "avd-image-mgmt-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Example 3: Multi-Region with Remote Gallery

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\imageManagement.bicep" `
  -artifactsContainerName "artifacts" `
  -storageSkuName "Standard_GRS" `
  -remoteLocation "usgovarizona" `
  -Name "avd-image-mgmt-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Example 4: Service Endpoint Access (Hybrid)

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\imageManagement.bicep" `
  -artifactsContainerName "artifacts" `
  -storageSkuName "Standard_ZRS" `
  -storageServiceEndpointSubnetResourceIds @(
    "/subscriptions/{sub}/resourceGroups/rg-avd-networking/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-imagebuilds",
    "/subscriptions/{sub}/resourceGroups/rg-avd-networking/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-hosts"
  ) `
  -Name "avd-image-mgmt-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Example 5: Using Parameter File

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile ".\imageManagement.bicep" `
  -TemplateParameterFile ".\parameters\production.imageManagement.parameters.json" `
  -Name "avd-image-mgmt-$(Get-Date -Format 'yyyyMMddHHmm')"
```

### Example 6: Using Deploy-ImageManagement Helper Script

```powershell
.\Deploy-ImageManagement.ps1 `
  -Location "usgovvirginia" `
  -Environment "prod" `
  -BlobStorageAccountNetworkAccess "PrivateEndpoint" `
  -PrivateEndpointSubnetResourceId "/subscriptions/{sub}/resourceGroups/rg-networking/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-endpoints"
```

> See [Deploy-ImageManagement Script](../../docs/imageManagementScript.md) for details

### Azure CLI

```bash
az deployment sub create \
  --location usgovvirginia \
  --template-file ./imageManagement.bicep \
  --parameters \
    artifactsContainerName="artifacts" \
    storageSkuName="Standard_ZRS" \
  --name avd-image-mgmt-$(date +%Y%m%d%H%M)
```

## Outputs

### `computeGalleryResourceId`
- **Type:** String
- **Description:** Resource ID of the Azure Compute Gallery
- **Example:** `/subscriptions/{sub}/resourceGroups/rg-avd-image-management-use2/providers/Microsoft.Compute/galleries/gal_avd_image_management_use2`
- **Used by:** Image build deployments

### `storageAccountResourceId`
- **Type:** String
- **Description:** Resource ID of the artifacts storage account
- **Example:** `/subscriptions/{sub}/resourceGroups/rg-avd-image-management-use2/providers/Microsoft.Storage/storageAccounts/saimgassetsuse2abc123`

### `artifactsContainerUri`
- **Type:** String
- **Description:** URI of the artifacts blob container
- **Example:** `https://saimgassetsuse2abc123.blob.core.usgovcloudapi.net/artifacts/`
- **Used by:** Image build deployments to download artifacts

### `userAssignedIdentityResourceId`
- **Type:** String
- **Description:** Resource ID of the managed identity
- **Example:** `/subscriptions/{sub}/resourceGroups/rg-avd-image-management-use2/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-avd-image-management-use2`
- **Used by:** Image build VMs to authenticate to storage

### `remoteComputeGalleryResourceId`
- **Type:** String
- **Description:** Resource ID of the remote gallery (if deployed)
- **Example:** `/subscriptions/{sub}/resourceGroups/rg-avd-image-management-usa2/providers/Microsoft.Compute/galleries/gal_avd_image_management_usa2`

## Post-Deployment Steps

### 1. Upload Artifacts to Storage

After deployment, upload your artifacts (scripts, installers) to the blob container:

```powershell
# Get storage account name from outputs
$storageAccountName = "saimgassetsuse2abc123"

# Upload artifacts folder
az storage blob upload-batch `
  --account-name $storageAccountName `
  --destination artifacts `
  --source ./artifacts `
  --auth-mode login
```

> See [Artifacts Guide](../../docs/artifactsGuide.md) for artifact package structure

### 2. Note Output Values

Save the following output values for image build deployments:
- `computeGalleryResourceId`
- `artifactsContainerUri`
- `userAssignedIdentityResourceId`

### 3. Deploy Image Builds

Use these resources to build custom images:

```powershell
New-AzSubscriptionDeployment `
  -Location "usgovvirginia" `
  -TemplateFile "..\imageBuild\imageBuild.bicep" `
  -computeGalleryResourceId $computeGalleryResourceId `
  -artifactsContainerUri $artifactsContainerUri `
  -userAssignedIdentityResourceId $userAssignedIdentityResourceId `
  -Name "avd-image-build-$(Get-Date -Format 'yyyyMMddHHmm')"
```

> See [Image Build Guide](../../docs/imageBuild.md) for details

## Security Considerations

### Storage Account Security

**Public Access (Default)**
- Use `storagePermittedIPs` to restrict access to known IPs
- Use `storageServiceEndpointSubnetResourceIds` to allow specific subnets
- Enable `storageAllowSharedKeyAccess` for compatibility

**Zero Trust (Private Endpoint)**
- Set `storagePublicNetworkAccess` to `Disabled`
- Deploy private endpoint with `privateEndpointSubnetResourceId`
- Link private DNS zone with `azureBlobPrivateDnsZoneResourceId`
- Disable shared key access: `storageAllowSharedKeyAccess = false`

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

- 📖 [Artifacts & Image Management Guide](../../docs/artifactsGuide.md) - Comprehensive artifact guide
- 📖 [Image Build Guide](../../docs/imageBuild.md) - Building custom images
- 📖 [Deploy-ImageManagement Script](../../docs/imageManagementScript.md) - Helper script documentation
- 🔧 [Azure Compute Gallery Documentation](https://learn.microsoft.com/azure/virtual-machines/azure-compute-gallery)
- 🔧 [Azure Storage Security](https://learn.microsoft.com/azure/storage/common/storage-security-guide)
- 🔧 [Managed Identities Documentation](https://learn.microsoft.com/azure/active-directory/managed-identities-azure-resources/)

## Support

For issues, questions, or contributions:
- **GitHub Issues:** [Azure/FederalAVD/issues](https://github.com/Azure/FederalAVD/issues)
- **Documentation:** [docs/](../../docs/)

## License

This project is licensed under the MIT License - see the [LICENSE](../../LICENSE) file for details.
