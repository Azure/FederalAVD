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
- **Bicep Module**: `updateEntraIdStorageKerbAppsManifest.bicep`
- **What it does**:
  - Updates application tags with `kdc_enable_cloud_group_sids` (if cloud-only Kerberos)
  - Adds privatelink FQDN to application identifier URIs
  - Example: Adds `https://storageaccount.privatelink.file.core.windows.net/` alongside `https://storageaccount.file.core.windows.net/`

### Phase 2: Grant Admin Consent (AFTER NTFS Permissions)
- **Purpose**: Grant delegated permissions (admin consent) to storage account applications
- **Script**: `Grant-StorageAccountApplicationConsent.ps1`
- **Bicep Module**: `grantEntraIdStorageKerbAppsConsent.bicep`
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
5. **✨ PHASE 1: Update application manifest** (`updateEntraIdStorageKerbAppsManifest.bicep`)
   - Adds privatelink FQDNs to identifier URIs
   - Updates tags for cloud group SID support
6. **Assign RBAC roles** to managed identity
7. **Set NTFS permissions** (`SetNTFSPermissions`)
   - Now works correctly because manifest includes privatelink FQDNs
8. **✨ PHASE 2: Grant admin consent** (`grantEntraIdStorageKerbAppsConsent.bicep`)
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

### Bicep Modules
- **`deployments/hostpools/modules/fslogix/modules/updateEntraIdStorageKerbAppsManifest.bicep`**
  - Invokes manifest update script
  - Parameters: `appDisplayNamePrefix`, `enableCloudGroupSids`, `privateEndpoint`, `userAssignedIdentityResourceId`, `virtualMachineName`

- **`deployments/hostpools/modules/fslogix/modules/grantEntraIdStorageKerbAppsConsent.bicep`**
  - Invokes admin consent script
  - Parameters: `appDisplayNamePrefix`, `userAssignedIdentityResourceId`, `virtualMachineName`

## Modified Files

### `deployments/hostpools/modules/fslogix/modules/azureFiles.bicep`

**Changes:**
1. Removed old `updateStorageApplications` module (single-step approach)
2. Added `updateStorageApplicationsManifest` module with dependency on `shares` and `privateEndpoints`
3. Updated `SetNTFSPermissions` module to depend on `updateStorageApplicationsManifest`
4. Added `grantStorageApplicationsConsent` module with dependency on `SetNTFSPermissions`

**Before:**
```bicep
module SetNTFSPermissions ... {
  dependsOn: [
    privateEndpoints
    shares
    configureEntraKerberosWithDomainInfo
    configureEntraKerberosWithoutDomainInfo
    configureADDSAuth
  ]
}

module updateStorageApplications ... {
  dependsOn: [
    SetNTFSPermissions  // Wrong order - consent happens first
  ]
}
```

**After:**
```bicep
// PHASE 1: Update manifest FIRST
module updateStorageApplicationsManifest ... {
  dependsOn: [
    privateEndpoints
    shares
    configureEntraKerberosWithDomainInfo
    configureEntraKerberosWithoutDomainInfo
  ]
}

// Set NTFS permissions AFTER manifest is updated
module SetNTFSPermissions ... {
  dependsOn: [
    privateEndpoints
    shares
    configureEntraKerberosWithDomainInfo
    configureEntraKerberosWithoutDomainInfo
    configureADDSAuth
    updateStorageApplicationsManifest  // NEW dependency
  ]
}

// PHASE 2: Grant consent LAST
module grantStorageApplicationsConsent ... {
  dependsOn: [
    SetNTFSPermissions  // Correct order - consent after permissions
  ]
}
```

## Benefits

1. **Eliminates 404 errors**: Privatelink FQDN is in the manifest before authentication attempts
2. **Logical ordering**: Manifest configuration happens before it's used
3. **Better debugging**: Separate scripts with distinct logging for each phase
4. **Clearer dependencies**: Explicit Bicep dependency chain shows the required sequence
5. **Maintains backward compatibility**: Non-private-endpoint scenarios work unchanged

## Testing

To verify the fix:

1. Deploy with private endpoints enabled
2. Check logs in `C:\Windows\Logs\` for both phases
3. Verify Phase 1 log shows privatelink URI added to manifest
4. Verify NTFS permissions script succeeds without 404 errors
5. Verify Phase 2 log shows admin consent granted successfully

## Rollback

If issues occur, the original combined script remains at:
- `.common/scripts/Update-StorageAccountApplications.ps1`
- `deployments/hostpools/modules/fslogix/modules/updateEntraIdStorageKerbApps.bicep`

These files are not deleted but are no longer referenced by `azureFiles.bicep`.
