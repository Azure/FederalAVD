# install-lgpo.ps1

## Overview

This PowerShell script automates the installation of the Local Group Policy Object (LGPO) tool from Microsoft. LGPO.exe is a command-line utility that enables administrators to automate management of Local Group Policy, which is essential for configuring system settings in AVD environments.

## Purpose

- Install LGPO.exe utility on Windows systems
- Enable automated Group Policy configuration
- Support policy deployment scripts
- Integrate with AVD image customization workflows
- Provide foundation for other configuration scripts

## Parameters

None - This script runs with default settings.

## Usage

### Basic Usage

```powershell
.\install-lgpo.ps1
```

## What the Script Does

### Installation Process

1. **Check for Existing Installation**
   - Verifies if lgpo.exe exists in `C:\Windows\System32`
   - Checks for LGPO.zip in script directory

2. **Download LGPO (if needed)**
   - Downloads LGPO.zip from Microsoft servers
   - URL: https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip
   - Saves to temporary directory

3. **Extract Archive**
   - Unzips LGPO.zip
   - Locates lgpo.exe

4. **Copy to System Directory**
   - Copies lgpo.exe to `C:\Windows\System32`
   - Makes tool available system-wide

5. **Verification**
   - Confirms lgpo.exe is accessible
   - Logs installation completion

## Installation Details

### Download Source

**URL:** https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip  
**File Type:** ZIP archive containing LGPO.exe  
**Size:** ~1-2 MB  

### Installation Location

```
C:\Windows\System32\lgpo.exe
```

### What is LGPO?

LGPO (Local Group Policy Object) is a command-line tool that:

- **Applies Registry-Based Policy:** Sets registry values via Group Policy
- **Imports GPO Backups:** Imports backed-up Group Policy Objects
- **Applies Security Templates:** Configures security settings via .INF files
- **Processes Audit Policy:** Applies advanced audit policy from .CSV files
- **Automates Policy Management:** Enables scripted Group Policy configuration

## LGPO Command-Line Syntax

```powershell
# Apply registry policy from text file
lgpo.exe /t "C:\path\to\registry.txt"

# Import GPO backup
lgpo.exe /g "C:\path\to\GPO\folder"

# Apply security template
lgpo.exe /s "C:\path\to\security.inf"

# Apply audit policy
lgpo.exe /ac "C:\path\to\audit.csv"

# Parse GPO backup to registry format
lgpo.exe /parse /m "C:\path\to\GPO"
```

## Use Cases

### AVD Image Customization

- Configure Group Policy settings during image build
- Apply security baselines
- Configure application policies (Edge, Office, OneDrive)

### Automation Scripts

- Prerequisite for other configuration scripts in this repository
- Enable scripted policy deployment
- Support infrastructure-as-code approaches

### Security Configuration

- Apply security baselines (DISA STIGs, CIS Benchmarks)
- Configure security policies programmatically
- Ensure consistent security posture

## Related Scripts

Many scripts in this artifacts folder depend on LGPO:

- Configure-DesktopBackground.ps1
- Configure-EdgePolicy.ps1
- Configure-Office365.ps1
- Configure-OneDrive.ps1
- Configure-RemoteDesktopServicesPolicy.ps1
- Configure-WindowsUpdatePolicy.ps1
- STIGs/Apply-STIGsAVD.ps1

## Logging

Logs are created in:

```
C:\Windows\Logs\install-lgpo-<timestamp>.log
```

Log entries include:

- Existing file checks
- Download progress
- Extraction process
- File copy operations
- Verification results

## Functions

| Function | Description |
|----------|-------------|
| `Get-InternetFile` | Downloads files from URLs with progress tracking |
| `New-Log` | Initializes logging infrastructure |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Network Access:** Required for online installation

## Troubleshooting

### Common Issues

**Issue:** Download fails

- **Solution:** Check internet connectivity; verify firewall allows Microsoft downloads

**Issue:** lgpo.exe not found after installation

- **Solution:** Verify C:\Windows\System32\lgpo.exe exists; check file permissions

**Issue:** Access denied copying to System32

- **Solution:** Ensure script runs with Administrator privileges

**Issue:** LGPO commands fail

- **Solution:** Check LGPO syntax; review input file format; enable verbose logging

### Verification

Check if LGPO is installed:

```powershell
# Check if lgpo.exe exists
Test-Path "C:\Windows\System32\lgpo.exe"

# Check LGPO version
& lgpo.exe /?

# Test LGPO execution
lgpo.exe /? 2>&1

# Verify in PATH
Get-Command lgpo.exe -ErrorAction SilentlyContinue
```

## LGPO Text File Format

Registry policy text files use this format:

```
Computer
SOFTWARE\Policies\Microsoft\Edge
SmartScreenEnabled
DWORD:1

User
SOFTWARE\Policies\Microsoft\Office\16.0\Outlook\Cached Mode
SyncWindowSetting
DWORD:1

```

**Format Rules:**

- First line: `Computer` or `User` (scope)
- Second line: Registry key path (without HKLM:\ or HKCU:\)
- Third line: Value name
- Fourth line: Type:Data (e.g., `DWORD:1`, `SZ:value`)
- Blank line separates entries

## Offline Usage

To use this script in air-gapped environments:

1. **Download LGPO.zip:**
   - URL: https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip

2. **Place in Script Directory:**

   ```
   install-lgpo.ps1
   LGPO.zip
   ```

3. **Run Script:**

   ```powershell
   .\install-lgpo.ps1
   ```

## Advanced LGPO Usage

### Creating Registry Text Files

```powershell
# Example: Disable Windows Update
$registryText = @"
Computer
SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU
NoAutoUpdate
DWORD:1
"@

$registryText | Out-File -FilePath "C:\Temp\DisableWU.txt" -Encoding ASCII
lgpo.exe /t "C:\Temp\DisableWU.txt"
```

### Backing Up Current GPO

```powershell
# Export current local GPO to folder
lgpo.exe /b "C:\Backup\GPO" /n "Backup"
```

### Parsing GPO for Review

```powershell
# Convert GPO to human-readable format
lgpo.exe /parse /m "C:\Backup\GPO"
```

## Best Practices

1. **Always Install First:** Ensure LGPO is installed before running policy configuration scripts
2. **Verify Syntax:** Validate LGPO text file format before applying
3. **Test in Non-Prod:** Test policy changes in development environments first
4. **Backup Policies:** Backup current GPO before making changes
5. **Documentation:** Document all policy changes made via LGPO

## Security Considerations

1. **Administrator Rights:** LGPO requires Administrator privileges
2. **Policy Impact:** Policies applied via LGPO affect all users
3. **Validation:** Validate policy files from trusted sources only
4. **Audit Trail:** Maintain logs of policy changes
5. **Testing:** Test policies thoroughly before production deployment

## References

- [LGPO Documentation](https://techcommunity.microsoft.com/t5/microsoft-security-baselines/lgpo-exe-local-group-policy-object-utility-v1-0/ba-p/701045)
- [LGPO Download](https://www.microsoft.com/en-us/download/details.aspx?id=55319)
- [Group Policy Overview](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/hh831791(v=ws.11))
- [Security Baselines](https://learn.microsoft.com/en-us/windows/security/threat-protection/windows-security-configuration-framework/windows-security-baselines)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
