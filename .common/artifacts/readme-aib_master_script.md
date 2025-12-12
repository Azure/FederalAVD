# aib_master_script.ps1

## Overview

This PowerShell script is the master orchestration script for Azure VM Image Builder (AIB) customization phases. It downloads and executes multiple customizers from Azure Storage accounts, significantly improving image build performance by having the VM directly download artifacts instead of AIB service routing them.

## Purpose

- Orchestrate multiple customizers during Azure Image Builder execution
- Download artifacts directly from Azure Storage for performance
- Support authenticated and unauthenticated downloads
- Execute various file types (EXE, MSI, PS1, BAT, ZIP)
- Provide centralized logging for image customization process

## Parameters

### `APIVersion`
- **Type:** String
- **Default:** `'2018-02-01'`
- **Description:** API version for Azure VM Instance Metadata Service (IMDS)

### `BlobStorageSuffix`
- **Type:** String
- **Default:** Empty (must be provided)
- **Values:** 
  - `'core.windows.net'` (Azure Commercial)
  - `'core.usgovcloudapi.net'` (Azure Government)
- **Description:** Azure Storage blob endpoint suffix for the environment

### `Customizers`
- **Type:** String (JSON array)
- **Default:** `'[]'`
- **Format:** JSON array of customizer objects
- **Description:** List of customizers to download and execute

### `UserAssignedIdentityClientId`
- **Type:** String
- **Default:** Empty (optional)
- **Description:** Client ID of user-assigned managed identity for authenticated storage access

## Customizer Object Format

Each customizer in the JSON array has the following structure:

```json
{
  "name": "CustomizerName",
  "Uri": "https://storageaccount.blob.core.windows.net/container/artifact.zip",
  "Arguments": "optional arguments"
}
```

### Properties

| Property | Required | Description |
|----------|----------|-------------|
| **name** | Yes | Friendly name for logging and temp folder creation |
| **Uri** | Yes | Full URL to the artifact file |
| **Arguments** | No | Command-line arguments for EXE/MSI or script parameters |

## Usage Examples

### Basic Usage (Single Customizer)
```json
$Customizers = '[{"name":"FSLogix","Uri":"https://storage.blob.core.windows.net/artifacts/FSLogix.zip"}]'
.\aib_master_script.ps1 -BlobStorageSuffix "core.windows.net" -Customizers $Customizers
```

### Multiple Customizers
```json
$Customizers = @'
[
  {"name":"LGPO","Uri":"https://storage.blob.core.windows.net/artifacts/LGPO.zip"},
  {"name":"FSLogix","Uri":"https://storage.blob.core.windows.net/artifacts/FSLogix.zip"},
  {"name":"Office365","Uri":"https://storage.blob.core.windows.net/artifacts/Configure-Office365.zip"}
]
'@
.\aib_master_script.ps1 -BlobStorageSuffix "core.windows.net" -Customizers $Customizers
```

### With Managed Identity (Private Storage)
```json
$Customizers = '[{"name":"App","Uri":"https://private.blob.core.windows.net/artifacts/app.zip"}]'
.\aib_master_script.ps1 `
  -BlobStorageSuffix "core.windows.net" `
  -Customizers $Customizers `
  -UserAssignedIdentityClientId "12345678-1234-1234-1234-123456789012"
```

### With Arguments
```json
$Customizers = '[{"name":"Installer","Uri":"https://storage.blob.core.windows.net/artifacts/app.exe","Arguments":"/S /D=C:\\App"}]'
.\aib_master_script.ps1 -BlobStorageSuffix "core.windows.net" -Customizers $Customizers
```

## What the Script Does

### Execution Flow

1. **Initialize Logging**
   - Starts PowerShell transcript
   - Logs to `C:\Windows\Logs\aib_master_script.log`

2. **Parse Customizers**
   - Converts JSON string to PowerShell objects
   - Validates customizer structure

3. **For Each Customizer:**
   
   **a. Create Temp Directory**
   - Creates folder in `$env:TEMP\<CustomizerName>`
   
   **b. Authenticate (if needed)**
   - If URI matches BlobStorageSuffix AND UserAssignedIdentityClientId provided
   - Retrieves OAuth token from Azure IMDS
   - Adds authorization header to download request
   
   **c. Download Artifact**
   - Downloads file from URI to temp directory
   - Logs download progress
   
   **d. Execute Based on File Type**
   - **EXE:** Execute with arguments
   - **MSI:** Run via msiexec.exe
   - **PS1:** Call PowerShell script
   - **BAT:** Execute batch file
   - **ZIP:** Extract and execute first .ps1 found in root
   
   **e. Cleanup**
   - Removes temp directory after execution

4. **Stop Transcript**
   - Finalizes logging

## Supported File Types

### Executable (.exe)
```powershell
Start-Process -FilePath $file -ArgumentList $Arguments -Wait
```

### MSI Installer (.msi)
```powershell
Start-Process msiexec.exe -ArgumentList "/i $file $Arguments" -Wait
```

### PowerShell Script (.ps1)
```powershell
& $file $Arguments
```

### Batch File (.bat)
```powershell
Start-Process cmd.exe -ArgumentList "$file $Arguments" -Wait
```

### ZIP Archive (.zip)
```powershell
# Extract ZIP
Expand-Archive -Path $file -DestinationPath $extractPath

# Find first .ps1 in root
$script = Get-ChildItem -Path $extractPath -Filter '*.ps1' | Select-Object -First 1

# Execute script
& $script.FullName $Arguments
```

## Azure Image Builder Integration

### Template Customizer Example

In your AIB template JSON:

```json
{
  "type": "PowerShell",
  "name": "ExecuteCustomizers",
  "runElevated": true,
  "scriptUri": "https://raw.githubusercontent.com/Azure/FederalAVD/main/.common/artifacts/aib_master_script.ps1",
  "runAsSystem": true,
  "inline": [
    "$customizers = '[{\"name\":\"FSLogix\",\"Uri\":\"https://storage.blob.core.windows.net/artifacts/FSLogix.zip\"}]'",
    ".\\aib_master_script.ps1 -BlobStorageSuffix 'core.windows.net' -Customizers $customizers"
  ]
}
```

## Authentication Methods

### Public Storage (No Auth)
- **Scenario:** Artifacts in public container
- **Configuration:** Omit UserAssignedIdentityClientId parameter
- **Access:** Anonymous HTTP download

### Private Storage (Managed Identity)
- **Scenario:** Artifacts in private container
- **Configuration:** Provide UserAssignedIdentityClientId
- **Access:** OAuth token from IMDS, added as Bearer token
- **Requirements:** User-assigned identity must have Storage Blob Data Reader role

## Logging

Logs are created at:
```
C:\Windows\Logs\aib_master_script.log
```

Log entries include:
- Script start/end timestamps
- Current working directory
- Each customizer being processed
- Download progress
- File extraction details
- Execution commands
- Success/failure status

## Performance Benefits

### vs. Individual AIB Customizers

**Traditional Approach:**
1. AIB service downloads artifact
2. AIB uploads to VM
3. VM executes
4. Repeat for each customizer

**Master Script Approach:**
1. Single PowerShell customizer downloads master script
2. Master script downloads all artifacts directly from storage
3. Sequential execution on VM

**Benefits:**
- **Faster:** VM downloads directly (higher bandwidth)
- **Simpler:** One AIB customizer instead of many
- **Flexible:** Easy to add/remove customizers without template changes
- **Reliable:** Fewer AIB API calls, less chance of failures

## Best Practices

1. **Artifact Organization:** Store all artifacts in same storage account/container
2. **ZIP Packaging:** Package PowerShell scripts in ZIP files for portability
3. **Script Root:** Ensure .ps1 scripts are in ZIP root, not subfolders
4. **Arguments:** Pass configuration via Arguments property
5. **Testing:** Test customizers individually before adding to master script
6. **Ordering:** Order customizers based on dependencies (e.g., LGPO before policies)
7. **Managed Identity:** Use managed identity for private storage
8. **Logging:** Check transcript log for troubleshooting

## Troubleshooting

### Common Issues

**Issue:** Download fails
- **Solution:** Check URI is correct; verify storage account access; check firewall

**Issue:** Authentication fails
- **Solution:** Verify UserAssignedIdentityClientId; check managed identity has Storage Blob Data Reader role

**Issue:** Script not found in ZIP
- **Solution:** Ensure .ps1 is in root of ZIP, not subfolder

**Issue:** Execution fails
- **Solution:** Check artifact logs; verify arguments syntax; test artifact independently

### Verification

Check execution logs:
```powershell
# View transcript log
Get-Content "C:\Windows\Logs\aib_master_script.log"

# Check for errors
Select-String -Path "C:\Windows\Logs\aib_master_script.log" -Pattern "error","fail"
```

## Example Customizers JSON

### Complete Example

```json
[
  {
    "name": "LGPO",
    "Uri": "https://saimageassets.blob.core.windows.net/artifacts/LGPO.zip"
  },
  {
    "name": "FSLogix",
    "Uri": "https://saimageassets.blob.core.windows.net/artifacts/FSLogix.zip"
  },
  {
    "name": "Office365",
    "Uri": "https://saimageassets.blob.core.windows.net/artifacts/Configure-Office365.zip"
  },
  {
    "name": "STIGs",
    "Uri": "https://saimageassets.blob.core.windows.net/artifacts/STIGs.zip",
    "Arguments": "-CloudOnly 'True' -Upgrade 'True'"
  },
  {
    "name": "DesktopBackground",
    "Uri": "https://saimageassets.blob.core.windows.net/artifacts/Configure-DesktopBackground.zip"
  }
]
```

## Requirements

- **OS:** Windows 10 or Windows 11
- **Context:** Azure VM with Instance Metadata Service access
- **Permissions:** SYSTEM (when run by AIB)
- **PowerShell:** 5.1 or higher
- **Network:** Access to Azure Storage

## References

- [Azure Image Builder](https://learn.microsoft.com/en-us/azure/virtual-machines/image-builder-overview)
- [AIB Customizers](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-json)
- [Azure IMDS](https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service)
- [Managed Identities](https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/overview)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
