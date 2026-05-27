# Install_VSCode.ps1

## Overview

This PowerShell script automates the installation of Visual Studio Code (VS Code) on Windows systems. It performs a silent installation without user interaction, making it ideal for Azure Virtual Desktop image customization and automated deployments.

## Purpose

- Install Visual Studio Code automatically
- Silent installation for automation scenarios
- Support developer workstation configurations
- Integrate with AVD image building processes
- Pre-configure development environments

## Parameters

### `DynParameters`

- **Type:** Hashtable
- **Default:** Not used
- **Description:** Optional dynamic parameters (reserved for future use)

## Usage

### Basic Usage

```powershell
.\Install_VSCode.ps1
```

## What the Script Does

### Installation Process

1. **Locate Installer**
   - Searches script directory for VS Code EXE installer
   - Expects `.exe` file to be present

2. **Execute Installation**
   - Runs VS Code installer with silent parameters
   - Parameters: `/VERYSILENT /NORESTART /MERGETASKS=!runcode`
   - Waits for installation to complete

3. **Registry Configuration**
   - Uses Set-RegistryValue function for additional configurations
   - Supports post-installation customization

4. **Capture Exit Code**
   - Logs installation result
   - Returns exit code for automation workflows

## Installation Details

### Installation Parameters

```
/VERYSILENT          - Completely silent installation (no UI)
/NORESTART           - Do not restart after installation
/MERGETASKS=!runcode - Do NOT launch VS Code after installation
```

### Download Source

**Official Website:** https://code.visualstudio.com/  
**Direct Download:** https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-user  
**File Type:** EXE (Inno Setup Installer)  
**Architecture:** x64  
**Size:** ~80-100 MB  

### Installation Location

```
C:\Users\<username>\AppData\Local\Programs\Microsoft VS Code\
```

### Components Installed

- Visual Studio Code application
- Code CLI (command-line interface)
- Shell integration (optional, based on installer options)
- File associations for common code file types

## Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| **0** | Success |
| **1** | Installation failure |
| **Other** | Error occurred (see logs for details) |

## Installation Types

Visual Studio Code offers two installation types:

### User Installer (Recommended)

- Installs for current user only
- No Administrator rights required
- Installs to user profile
- Auto-updates work for non-admin users

### System Installer

- Installs for all users
- Requires Administrator rights
- Installs to Program Files
- Centralized installation

This script supports either type depending on the EXE file used.

## Command-Line Access

After installation, VS Code is accessible via:

```powershell
# Launch VS Code
code

# Open specific file
code C:\path\to\file.txt

# Open folder
code C:\path\to\folder

# Install extension
code --install-extension ms-python.python

# List installed extensions
code --list-extensions
```

## Use Cases

### Developer Workstations

- Provide VS Code for software development
- Pre-install for development teams in AVD
- Support remote development scenarios

### Image Customization

- Include VS Code in AVD developer images
- Pre-configure with extensions and settings
- Support DevOps workflows

### Administrative Tools

- Provide lightweight editor for script development
- Enable JSON/YAML file editing
- Support infrastructure-as-code

## Common VS Code Extensions

After installation, consider installing popular extensions:

```powershell
# Azure extensions
code --install-extension ms-vscode.azure-account
code --install-extension ms-azuretools.vscode-azurefunctions
code --install-extension ms-azuretools.vscode-docker

# Language support
code --install-extension ms-python.python
code --install-extension ms-vscode.powershell
code --install-extension ms-dotnettools.csharp

# Productivity
code --install-extension eamodio.gitlens
code --install-extension ms-vscode-remote.remote-ssh
```

## Offline Usage

To use this script in air-gapped environments:

1. **Download VS Code Installer:**
   - System: https://code.visualstudio.com/sha/download?build=stable&os=win32-x64
   - User: https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-user

2. **Place in Script Directory:**

   ```
   Install_VSCode.ps1
   VSCodeSetup-x64-<version>.exe
   ```

3. **Run Script:**

   ```powershell
   .\Install_VSCode.ps1
   ```

## Logging

Logs are created in:

```
C:\Windows\Logs\Install_VSCode-<timestamp>.log
```

Log entries include:

- Installer file location
- Installation command execution
- Exit codes
- Success/failure status

## Functions

| Function | Description |
|----------|-------------|
| `New-Log` | Initializes logging infrastructure |
| `Set-RegistryValue` | Creates or updates registry values |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM (for system-wide install)
- **PowerShell:** 5.1 or higher
- **Disk Space:** ~200-300 MB (application + extensions)

## Post-Installation Configuration

### Settings Sync

Enable Settings Sync to roam configuration across devices:

```powershell
# Settings are stored in:
# C:\Users\<username>\AppData\Roaming\Code\User\settings.json
```

### User Settings (settings.json)

```json
{
    "editor.fontSize": 14,
    "editor.tabSize": 4,
    "files.autoSave": "afterDelay",
    "telemetry.telemetryLevel": "off",
    "update.mode": "manual"
}
```

### Pre-Install Extensions

```powershell
# Create extension installation script
$extensions = @(
    "ms-python.python",
    "ms-vscode.powershell",
    "ms-azuretools.vscode-docker",
    "eamodio.gitlens"
)

foreach ($ext in $extensions) {
    code --install-extension $ext --force
}
```

## Troubleshooting

### Common Issues

**Issue:** 'code' command not found

- **Solution:** Restart PowerShell session; verify PATH environment variable

**Issue:** Installation fails silently

- **Solution:** Check logs; run installer manually to see error messages

**Issue:** Extensions fail to install

- **Solution:** Check internet connectivity; verify extension marketplace access

**Issue:** VS Code doesn't launch

- **Solution:** Check installation directory; verify file permissions; reinstall

### Verification

Check if VS Code is installed:

```powershell
# Check command availability
Get-Command code -ErrorAction SilentlyContinue

# Check version
code --version

# Check installation directory (User install)
Test-Path "$env:LOCALAPPDATA\Programs\Microsoft VS Code"

# Check installation directory (System install)
Test-Path "${env:ProgramFiles}\Microsoft VS Code"

# List installed extensions
code --list-extensions
```

## Enterprise Deployment

### Group Policy Integration

VS Code supports Group Policy for enterprise configuration:

**Policy ADMX Location:** Available from Microsoft  
**Settings Managed:** Update behavior, telemetry, extensions, etc.

### Deployment Methods

1. **Silent Installation:** This script
2. **Microsoft Intune:** Deploy as Win32 app
3. **SCCM/ConfigMgr:** Package and deploy
4. **Group Policy Software Installation:** Deploy via GPO

## Security Considerations

1. **Official Source:** Download only from code.visualstudio.com
2. **Verify Signature:** Verify digital signature of installer
3. **Extension Security:** Review extensions before installation
4. **Telemetry:** Disable telemetry in enterprise environments
5. **Auto-Update:** Control update behavior via Group Policy

## Best Practices

1. **Extension Management:** Pre-install common extensions in master image
2. **Settings Sync:** Enable for consistent user experience
3. **Update Control:** Configure update behavior appropriately
4. **Documentation:** Document pre-installed extensions and settings
5. **Testing:** Test VS Code launch after installation

## VS Code vs Visual Studio

### Visual Studio Code

- Lightweight code editor
- Cross-platform (Windows, Mac, Linux)
- Free and open source
- Extension-based features
- Fast startup

### Visual Studio (Full IDE)

- Full-featured IDE
- Windows only (primarily)
- Commercial/Community editions
- Integrated features out-of-box
- Larger resource footprint

## References

- [Visual Studio Code](https://code.visualstudio.com/)
- [VS Code Documentation](https://code.visualstudio.com/docs)
- [VS Code Extensions Marketplace](https://marketplace.visualstudio.com/vscode)
- [Command Line Interface](https://code.visualstudio.com/docs/editor/command-line)
- [Enterprise Support](https://code.visualstudio.com/docs/supporting/faq#_what-is-the-difference-between-the-user-and-system-installers)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
