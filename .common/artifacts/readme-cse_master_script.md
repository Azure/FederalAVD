# cse_master_script.ps1

## Overview

This PowerShell script is the master orchestration script for Azure Custom Script Extension (CSE) execution on Azure Virtual Desktop session hosts. It automatically discovers and executes PowerShell scripts and ZIP archives in the current directory, passing parameters dynamically to child scripts.

## Purpose

- Orchestrate multiple scripts during Custom Script Extension execution
- Automatically discover and execute artifacts in directory
- Support ZIP archives with embedded PowerShell scripts
- Pass parameters dynamically to child scripts via hashtable
- Provide centralized logging for customization process
- Enable reusable script deployment without hardcoded paths

## Parameters

### `DynParameters`
- **Type:** Hashtable
- **Default:** `@{}`
- **Description:** Dynamic parameters to pass to all child scripts
- **Usage:** Key-value pairs of parameter names and values

## Usage Examples

### Basic Usage (No Parameters)
```powershell
.\cse_master_script.ps1
```

### With Parameters
```powershell
$params = @{
    TenantId = "12345678-1234-1234-1234-123456789012"
    CloudOnly = "True"
    Upgrade = "True"
}
.\cse_master_script.ps1 -DynParameters $params
```

### Azure CSE Extension JSON
```json
{
  "fileUris": [
    "https://storage.blob.core.windows.net/artifacts/cse_master_script.ps1",
    "https://storage.blob.core.windows.net/artifacts/Configure-Office365.zip",
    "https://storage.blob.core.windows.net/artifacts/Configure-OneDrive.zip",
    "https://storage.blob.core.windows.net/artifacts/STIGs.zip"
  ],
  "commandToExecute": "powershell -ExecutionPolicy Unrestricted -File cse_master_script.ps1 -DynParameters @{TenantId='tenant-id';CloudOnly='True'}"
}
```

## What the Script Does

### Execution Flow

1. **Initialize Logging**
   - Starts PowerShell transcript
   - Logs to `C:\Windows\Logs\cse_master_script.log`
   - Records PowerShell version

2. **Set Execution Policy**
   - Sets execution policy to Unrestricted for current process
   - Allows unsigned scripts to run

3. **Discover Artifacts**
   
   **Find ZIP Files:**
   - Searches current directory for `*.zip` files
   - Excludes `cse_master_script.ps1` itself
   - Sorts alphabetically for consistent ordering
   
   **Find PowerShell Scripts:**
   - Searches current directory for `*.ps1` files
   - Excludes `cse_master_script.ps1` itself
   - Sorts alphabetically

4. **Process ZIP Archives**
   
   For each ZIP file:
   
   **a. Create Temp Directory**
   - Creates folder in `$env:TEMP\<ZipFileName>`
   
   **b. Extract Archive**
   - Expands ZIP to temp directory
   - Logs extraction path
   
   **c. Find PowerShell Scripts**
   - Searches extracted content for `*.ps1` files
   - Includes subdirectories
   
   **d. Execute Scripts**
   - For each .ps1 found, execute with DynParameters
   - Splatting hashtable as script parameters
   - Wait for each script to complete
   
   **e. Cleanup**
   - Removes temp directory after execution

5. **Process Standalone PowerShell Scripts**
   
   For each .ps1 file in current directory:
   - Execute with DynParameters
   - Splatting hashtable as script parameters
   - Wait for completion

6. **Stop Transcript**
   - Finalizes logging

## Artifact Discovery Logic

### Supported Structures

**Structure 1: ZIP with script in root**
```
Configure-Office365.zip
  ├── Configure-Office365.ps1
  ├── Config.txt
  └── Policy.xml
```

**Structure 2: ZIP with script in subfolder**
```
STIGs.zip
  ├── STIGs\
  │   ├── Apply-STIGsAVD.ps1
  │   ├── LGPO.exe
  │   └── Policies\
```

**Structure 3: ZIP with multiple scripts**
```
Tools.zip
  ├── Install-Tool1.ps1
  ├── Install-Tool2.ps1
  └── Configure-Settings.ps1
```

**Structure 4: Standalone scripts**
```
Directory\
  ├── cse_master_script.ps1
  ├── Configure-Background.ps1
  └── Set-Registry.ps1
```

### Execution Order

1. **ZIP files first** (alphabetical)
2. **Standalone .ps1 files second** (alphabetical)
3. **Within ZIPs:** All discovered .ps1 files (alphabetical)

Example execution order:
```
1. FSLogix.zip
   → Install-FSLogix.ps1
2. Office365.zip
   → Configure-Office365.ps1
3. STIGs.zip
   → Apply-STIGsAVD.ps1
4. Configure-Background.ps1
5. Set-Registry.ps1
```

## Parameter Passing (DynParameters)

### Hashtable Splatting

The master script uses PowerShell splatting to pass parameters:

```powershell
# Master script receives
$DynParameters = @{
    TenantId = "12345678-1234-1234-1234-123456789012"
    CloudOnly = "True"
    Upgrade = "True"
}

# Child script called with
& $script.FullName @DynParameters

# Equivalent to
& $script.FullName -TenantId "12345678-1234-1234-1234-123456789012" -CloudOnly "True" -Upgrade "True"
```

### Child Script Requirements

Child scripts must declare parameters:

```powershell
# Configure-OneDrive.ps1
param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId,
    
    [Parameter(Mandatory = $false)]
    [string]$CloudOnly = 'False'
)

# Script logic here
```

**Important:** Child scripts should use `[Parameter(Mandatory = $false)]` for all parameters to avoid prompts if not provided.

## Example Scenarios

### Scenario 1: AVD Image Customization

**Artifacts:**
- `FSLogix.zip` (installs FSLogix Apps)
- `Office365.zip` (configures Office 365 policies)
- `OneDrive.zip` (configures OneDrive KFM)
- `STIGs.zip` (applies DISA STIGs)

**Parameters:**
```powershell
$params = @{
    TenantId = "tenant-id"
    CloudOnly = "True"
    Upgrade = "True"
}
.\cse_master_script.ps1 -DynParameters $params
```

**Result:** All ZIP files extracted and their PowerShell scripts executed with tenant configuration.

### Scenario 2: Application Installation

**Artifacts:**
- `Install-AzCLI.ps1`
- `Install-Git.ps1`
- `Install-VSCode.ps1`

**Parameters:**
```powershell
.\cse_master_script.ps1
```

**Result:** All standalone scripts executed sequentially with no parameters.

### Scenario 3: Mixed Deployment

**Artifacts:**
- `Tools.zip` (contains Install-Tools.ps1)
- `Policies.zip` (contains Configure-Policies.ps1)
- `Cleanup.ps1` (standalone script)

**Parameters:**
```powershell
$params = @{
    Environment = "Production"
}
.\cse_master_script.ps1 -DynParameters $params
```

**Result:** ZIP files processed first, then standalone script, all receiving Environment parameter.

## Azure Custom Script Extension Integration

### ARM Template Example

```json
{
  "type": "Microsoft.Compute/virtualMachines/extensions",
  "apiVersion": "2023-03-01",
  "name": "[concat(parameters('vmName'), '/CustomScriptExtension')]",
  "location": "[resourceGroup().location]",
  "properties": {
    "publisher": "Microsoft.Compute",
    "type": "CustomScriptExtension",
    "typeHandlerVersion": "1.10",
    "autoUpgradeMinorVersion": true,
    "settings": {
      "fileUris": [
        "https://storage.blob.core.windows.net/artifacts/cse_master_script.ps1",
        "https://storage.blob.core.windows.net/artifacts/FSLogix.zip",
        "https://storage.blob.core.windows.net/artifacts/Office365.zip"
      ]
    },
    "protectedSettings": {
      "commandToExecute": "powershell -ExecutionPolicy Unrestricted -File cse_master_script.ps1 -DynParameters @{TenantId='tenant-id'}"
    }
  }
}
```

### Bicep Example

```bicep
resource customScriptExtension 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = {
  name: 'CustomScriptExtension'
  parent: virtualMachine
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        'https://storage.blob.core.windows.net/artifacts/cse_master_script.ps1'
        'https://storage.blob.core.windows.net/artifacts/FSLogix.zip'
        'https://storage.blob.core.windows.net/artifacts/Office365.zip'
      ]
    }
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File cse_master_script.ps1 -DynParameters @{TenantId=\'${tenantId}\'}'
    }
  }
}
```

## Logging

Logs are created at:
```
C:\Windows\Logs\cse_master_script.log
```

Log entries include:
- Script start/end timestamps
- PowerShell version
- Current execution policy
- Current working directory
- Each ZIP file being processed
- Extraction paths
- Each script being executed
- Parameters being passed (DynParameters hashtable)
- Success/failure status

## Best Practices

1. **Naming Convention:** Use descriptive names for ZIP files (they execute alphabetically)
2. **Parameter Consistency:** Use consistent parameter names across child scripts
3. **Optional Parameters:** Make all child script parameters optional to avoid prompts
4. **Script Root:** Place primary .ps1 in ZIP root for easy discovery
5. **Dependencies:** Order artifacts via naming (e.g., `01-LGPO.zip`, `02-Policies.zip`)
6. **Testing:** Test child scripts independently before adding to master script
7. **Logging:** Enable transcript in child scripts for comprehensive logging
8. **Error Handling:** Implement try/catch in child scripts
9. **Idempotency:** Ensure scripts can run multiple times safely

## Troubleshooting

### Common Issues

**Issue:** Script not found in ZIP
- **Solution:** Check ZIP structure; ensure .ps1 is present; verify extraction

**Issue:** Parameters not passed
- **Solution:** Verify DynParameters syntax; check child script parameter declarations

**Issue:** Script execution blocked
- **Solution:** Check execution policy; verify CSE runs with appropriate permissions

**Issue:** ZIP extraction fails
- **Solution:** Verify ZIP file integrity; check disk space in TEMP directory

### Verification

Check execution logs:
```powershell
# View transcript log
Get-Content "C:\Windows\Logs\cse_master_script.log"

# Check for errors
Select-String -Path "C:\Windows\Logs\cse_master_script.log" -Pattern "error","fail","exception"

# View last 50 lines
Get-Content "C:\Windows\Logs\cse_master_script.log" -Tail 50
```

Check extracted files (during execution):
```powershell
# List temp directories
Get-ChildItem $env:TEMP -Directory | Where-Object {$_.Name -like "*.zip"}
```

## Differences from aib_master_script.ps1

| Feature | aib_master_script.ps1 | cse_master_script.ps1 |
|---------|----------------------|----------------------|
| **Artifact Discovery** | Explicit (JSON array) | Automatic (directory scan) |
| **Download** | Yes (from storage) | No (CSE downloads) |
| **Authentication** | Managed Identity | Not needed |
| **Execution Context** | Azure Image Builder | Custom Script Extension |
| **Parameter Passing** | Via Arguments property | Via DynParameters hashtable |
| **Customizer List** | Must be defined | Auto-discovered |
| **Use Case** | Image build | VM customization |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Context:** Azure VM with Custom Script Extension
- **Permissions:** SYSTEM or Administrator
- **PowerShell:** 5.1 or higher
- **Artifacts:** Present in same directory as master script

## References

- [Azure Custom Script Extension](https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/custom-script-windows)
- [PowerShell Splatting](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_splatting)
- [PowerShell Transcript](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.host/start-transcript)
- [AVD Session Host Configuration](https://learn.microsoft.com/en-us/azure/virtual-desktop/set-up-customize-master-image)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
