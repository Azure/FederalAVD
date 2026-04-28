[**Home**](../README.md) | [**Quick Start**](quickStart.md) | [**Host Pool Deployment**](hostpoolDeployment.md) | [**Image Build**](imageBuild.md) | [**Artifacts**](artifactsGuide.md) | [**Features**](features.md) | [**Parameters**](parameters.md)

# Storage Account Application Configuration - Split Implementation

## Problem Statement

When deploying Azure Files with private endpoints and Entra ID Kerberos authentication, the storage account enterprise application must have the privatelink FQDN added to its manifest **before** authentication can succeed through the private endpoint. The original single-step approach caused the NTFS permissions script to fail with 404 errors because:

1. Private endpoints were created
2. NTFS permissions script tried to authenticate via privatelink endpoint
3. Storage application manifest didn't include the privatelink FQDN yet
4. Authentication failed with 404 error

## Solution

Split the storage account application configuration into **two phases**:

### Phase 1: Update Application Manifest (BEFORE NTFS Permissions)

- **Purpose**: Update tags and identifier URIs to support privatelink FQDNs
- **Script**: `Update-StorageAccountApplicationManifest.ps1`
- **Bicep**: Inlined in `azureFiles.bicep` as `updateStorageApplicationsManifest` via `compute/runCommand.bicep`
- **What it does**:
  - Updates application tags with `kdc_enable_cloud_group_sids` (if cloud-only Kerberos)
  - Adds privatelink FQDN to application identifier URIs
  - Example: Adds `https://storageaccount.privatelink.file.core.windows.net/` alongside `https://storageaccount.file.core.windows.net/`

### Phase 2: Grant Admin Consent (AFTER NTFS Permissions)

- **Purpose**: Grant delegated permissions (admin consent) to storage account applications
- **Script**: `Grant-StorageAccountApplicationConsent.ps1`
- **Bicep**: Inlined in `azureFiles.bicep` as `grantStorageApplicationsConsent` via `compute/runCommand.bicep`
- **What it does**:
  - Creates or updates oauth2PermissionGrants for the storage account enterprise application
  - Grants `openid`, `profile`, and `User.Read` delegated permissions
  - Provides admin consent to the Microsoft Graph API

## Deployment Order

The correct deployment sequence is now:

1. **Create storage accounts**
2. **Create file shares** (`shares.bicep`)
3. **Create private endpoints** (if enabled)
4. **Configure Entra Kerberos authentication** (if applicable)
5. **✨ PHASE 1: Update application manifest** (`updateStorageApplicationsManifest` in `azureFiles.bicep`)
   - Adds privatelink FQDNs to identifier URIs
   - Updates tags for cloud group SID support
6. **Assign RBAC roles** to managed identity
7. **Set NTFS permissions** (`SetNTFSPermissions`)
   - Now works correctly because manifest includes privatelink FQDNs
8. **✨ PHASE 2: Grant admin consent** (`grantStorageApplicationsConsent` in `azureFiles.bicep`)
   - Grants delegated permissions after permissions are set

## Files Created

### PowerShell Scripts

- **`.common/scripts/Update-StorageAccountApplicationManifest.ps1`**
  - Extracted manifest update logic from original script
  - Updates tags and identifier URIs only
  - Logs to: `C:\Windows\Logs\Update-StorageAccountApplicationManifest-{timestamp}.log`

- **`.common/scripts/Grant-StorageAccountApplicationConsent.ps1`**
  - Extracted admin consent logic from original script
  - Grants oauth2PermissionGrants only
  - Logs to: `C:\Windows\Logs\Grant-StorageAccountApplicationConsent-{timestamp}.log`

### Bicep

Both phases are inlined directly in `deployments/hostpools/modules/fslogix/modules/azureFiles.bicep` as `updateStorageApplicationsManifest` and `grantStorageApplicationsConsent`, using the common `compute/runCommand.bicep` module with `loadTextContent()` for each script. No separate wrapper modules exist.
