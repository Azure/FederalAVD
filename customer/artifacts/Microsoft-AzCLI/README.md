# Install-AzCLI.ps1

## Overview

This PowerShell script automates the installation or uninstallation of the Azure Command-Line Interface (Azure CLI) on Windows systems. It's designed for use in Azure Virtual Desktop environments during image customization or session host deployment.

## Purpose

- Install or uninstall Azure CLI on Windows
- Support both online and offline installations
- Handle existing installations gracefully
- Provide detailed logging for troubleshooting
- Integrate with AVD image building processes

## Parameters

### `DeploymentType`
- **Type:** String
- **Default:** `'Install'`
- **Options:** `'Install'` or `'Uninstall'`
- **Description:** Specifies whether to install or uninstall Azure CLI

## Usage Examples

### Install Azure CLI (Default)
```powershell
.\Install-AzCLI.ps1
```

### Explicit Installation
```powershell
.\Install-AzCLI.ps1 -DeploymentType 'Install'
```

### Uninstall Azure CLI
```powershell
.\Install-AzCLI.ps1 -DeploymentType 'Uninstall'
```

## What the Script Does

### Installation Process

1. **Check Existing Installation**
   - Searches registry for installed Azure CLI
   - Determines current version if installed
   - Logs existing installation details

2. **Download Azure CLI (if needed)**
   - Checks for local MSI file in script directory
   - If not found, downloads from Microsoft servers
   - Uses latest available version

3. **Install Azure CLI**
   - Runs MSI installer with silent parameters
   - Parameters: `/i <msi file> /qn /norestart`
   - Waits for installation to complete
   - Captures and logs exit code

4. **Verification**
   - Checks installation success via exit code
   - Logs installation completion
   - Returns exit code for automation workflows

### Uninstallation Process

1. **Find Existing Installation**
   - Searches registry for Azure CLI
   - Retrieves uninstall string

2. **Uninstall Azure CLI**
   - Executes uninstall command
   - Uses silent parameters
   - Logs uninstallation process

## Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| **0** | Success |
| **3010** | Success - Reboot required |
| **Other** | Error occurred (see logs for details) |

## Installation Details

### Azure CLI Download

**Download URL:** Automatically detected from Microsoft servers  
**File Type:** MSI (Microsoft Installer)  
**Architecture:** x64  
**Size:** ~100-150 MB  

### Installation Location

```
C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\
```

### Command-Line Access

After installation, Azure CLI is accessible via:
```powershell
az --version
az login
az account list
```

## Offline Usage

To use this script in air-gapped environments:

1. **Download Azure CLI MSI:**
   - URL: https://aka.ms/installazurecliwindows
   - Or direct: https://azcliprod.blob.core.windows.net/msi/azure-cli-latest.msi

2. **Place MSI in Script Directory:**
   ```
   Install-AzCLI.ps1
   azure-cli-<version>.msi
   ```

3. **Run Script:**
   ```powershell
   .\Install-AzCLI.ps1
   ```

## Use Cases

### Image Customization
- Install Azure CLI in AVD master images
- Enable administrators to manage Azure resources from session hosts
- Support automation and scripting scenarios

### Developer Workstations
- Provide Azure CLI for development and testing
- Enable CI/CD pipeline integration
- Support infrastructure-as-code workflows

### Administrative Tools
- Install on jump boxes or management VMs
- Enable Azure resource management
- Support troubleshooting and diagnostics

## Logging

Logs are created in:
```
C:\Windows\Logs\Install-AzCLI-<timestamp>.log
```

Log entries include:
- Existing installation detection
- Download progress
- Installation execution
- Exit codes
- Error messages

## Functions

| Function | Description |
|----------|-------------|
| `Get-InstalledApplication` | Queries registry for installed applications |
| `Get-InternetFile` | Downloads files from URLs with progress tracking |
| `New-Log` | Initializes logging infrastructure |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **.NET Framework:** .NET Framework 4.7.2 or higher
- **Network Access:** Required for online installation

## Troubleshooting

### Common Issues

**Issue:** Installation fails with error
- **Solution:** Check logs; ensure administrator privileges; verify .NET Framework version

**Issue:** Download fails
- **Solution:** Check internet connectivity; verify firewall allows downloads from Microsoft domains

**Issue:** 'az' command not found after installation
- **Solution:** Restart PowerShell session; verify PATH environment variable

**Issue:** Installation hangs
- **Solution:** Check for pending Windows updates; ensure no other installers running

### Verification

Check if Azure CLI is installed:
```powershell
# Check installed applications
Get-Command az -ErrorAction SilentlyContinue

# Check version
az --version

# Test Azure CLI
az account list

# Check installation directory
Test-Path "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
```

## Post-Installation

### Initial Configuration

```powershell
# Login to Azure
az login

# Set default subscription
az account set --subscription "<subscription-id>"

# Configure defaults
az configure --defaults group=<resource-group> location=<location>

# Enable CLI extensions
az extension add --name <extension-name>
```

### Common Azure CLI Commands

```powershell
# List resources
az resource list

# List VMs
az vm list --output table

# List AVD host pools
az desktopvirtualization hostpool list --output table

# Get resource group
az group show --name <resource-group>
```

## Security Considerations

1. **Authentication:** Azure CLI uses Azure AD authentication
2. **Credentials:** Never store credentials in scripts
3. **Service Principals:** Use managed identities or service principals for automation
4. **Access Control:** Limit Azure CLI installation to authorized users
5. **Audit Logging:** Enable Azure activity logging for CLI operations

## Best Practices

1. **Version Management:** Keep Azure CLI updated to latest version
2. **Automation:** Use Azure CLI in CI/CD pipelines for infrastructure automation
3. **Scripting:** Leverage PowerShell with Azure CLI for complex operations
4. **Testing:** Test CLI scripts in non-production environments first
5. **Documentation:** Document CLI usage patterns for team consistency

## Azure CLI vs PowerShell

### When to Use Azure CLI

- Cross-platform scripting (Linux, macOS, Windows)
- Simple, straightforward commands
- Quick interactive operations
- CI/CD pipeline integration

### When to Use Az PowerShell Module

- Windows-native automation
- Complex object manipulation
- Integration with existing PowerShell scripts
- Advanced error handling

## References

- [Azure CLI Documentation](https://learn.microsoft.com/en-us/cli/azure/)
- [Install Azure CLI on Windows](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows)
- [Azure CLI Release Notes](https://learn.microsoft.com/en-us/cli/azure/release-notes-azure-cli)
- [Get Started with Azure CLI](https://learn.microsoft.com/en-us/cli/azure/get-started-with-azure-cli)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
