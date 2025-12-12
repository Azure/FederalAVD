# Install-VisualC++Redistributables.ps1

## Overview

This PowerShell script automates the installation of Microsoft Visual C++ Redistributable packages on Windows systems. These runtime libraries are required by many applications and are essential for proper software functionality in Azure Virtual Desktop environments.

## Purpose

- Install Visual C++ Redistributable packages
- Support application dependencies
- Enable proper functioning of C++ applications
- Integrate with AVD image customization
- Prevent application launch failures due to missing dependencies

## Parameters

None - This script runs with default settings.

## Usage

### Basic Usage

```powershell
.\Install-VisualC++Redistributables.ps1
```

## What the Script Does

### Installation Process

1. **Locate Installer**
   - Searches script directory for VC++ redistributable EXE file
   - Expects .exe file to be present in same directory

2. **Execute Installation**
   - Runs installer with silent parameters
   - Parameters: `/install /quiet /norestart`
   - Waits for installation to complete

3. **Capture Exit Code**
   - Logs installation result
   - Returns exit code for automation workflows

## Installation Details

### Installation Parameters

```
/install    - Perform installation
/quiet      - Silent installation (no UI)
/norestart  - Do not restart after installation
```

### Common Visual C++ Versions

Different applications require different versions:

| Version | Year | Applications |
|---------|------|--------------|
| **VC++ 2005 (8.0)** | 2005 | Legacy applications |
| **VC++ 2008 (9.0)** | 2008 | Older commercial software |
| **VC++ 2010 (10.0)** | 2010 | Common dependencies |
| **VC++ 2012 (11.0)** | 2012 | Mid-range applications |
| **VC++ 2013 (12.0)** | 2013 | Many modern applications |
| **VC++ 2015-2022 (14.x)** | 2015-2022 | Latest applications |

**Note:** VC++ 2015, 2017, 2019, and 2022 share the same redistributable.

### Installation Locations

```
C:\Windows\System32\      (64-bit DLLs on x64 systems)
C:\Windows\SysWOW64\      (32-bit DLLs on x64 systems)
```

### Registry Locations

```
HKLM:\SOFTWARE\Microsoft\VisualStudio\<version>\VC\Runtimes\x64
HKLM:\SOFTWARE\Microsoft\VisualStudio\<version>\VC\Runtimes\x86
```

## Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| **0** | Success |
| **3010** | Success - Reboot required |
| **1638** | Already installed (same version) |
| **5100** | System does not meet requirements |
| **Other** | Error occurred (see logs for details) |

## What are Visual C++ Redistributables?

Visual C++ Redistributables are runtime components required by applications built with Microsoft Visual C++:

### Components Included

- **CRT (C Runtime Library):** Standard C library functions
- **STL (Standard Template Library):** C++ template library
- **MFC (Microsoft Foundation Classes):** C++ GUI framework
- **ATL (Active Template Library):** COM component framework

### Why Required?

- Applications link to these libraries dynamically
- Developers don't include them to reduce application size
- Multiple applications can share the same runtime

## Use Cases

### Application Support

- Ensure applications launch successfully
- Prevent "VCRUNTIME140.dll not found" errors
- Support legacy and modern applications

### Image Preparation

- Pre-install common VC++ versions in AVD master image
- Reduce time-to-desktop for users
- Prevent application installation failures

### Software Deployment

- Prerequisite for many enterprise applications
- Required by Adobe products, autodesk software, games, etc.

## Common Applications Requiring VC++ Redistributables

### Enterprise Applications

- Microsoft Office (certain features)
- Adobe Creative Cloud applications
- Autodesk products (AutoCAD, Revit)
- SQL Server Management Studio

### Development Tools

- Visual Studio
- Git for Windows (certain features)
- Python (if built with Visual Studio)

### Common Software

- Web browsers (Chrome, Firefox - certain features)
- Media players
- Many games and utilities

## Offline Usage

To use this script in air-gapped environments:

1. **Download VC++ Redistributable:**
   - **Latest (2015-2022):** https://aka.ms/vs/17/release/vc_redist.x64.exe
   - **Specific versions:** https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist

2. **Place in Script Directory:**

   ```
   Install-VisualC++Redistributables.ps1
   vc_redist.x64.exe
   ```

3. **Run Script:**
4. 
   ```powershell
   .\Install-VisualC++Redistributables.ps1
   ```

## Logging

Logs are created in:
```
C:\Windows\Logs\Install-VisualC++Redistributables-<timestamp>.log
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
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **EXE File:** VC++ redistributable installer must be in script directory

## Troubleshooting

### Common Issues

**Issue:** "VCRUNTIME140.dll not found" error persists
- **Solution:** Install latest VC++ 2015-2022 redistributable; restart application

**Issue:** Installation fails with 1638
- **Solution:** Same or newer version already installed; no action needed

**Issue:** Multiple versions required
- **Solution:** Install each version separately; they coexist without conflicts

**Issue:** Application still doesn't run
- **Solution:** Verify correct architecture (x86 vs x64); install both if unsure

### Verification

Check if VC++ Redistributables are installed:
```powershell
# Check installed applications
Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*Visual C++*" }

# Check via registry (faster method)
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes"
Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes"

# Check for specific DLL
Test-Path "C:\Windows\System32\vcruntime140.dll"
Test-Path "C:\Windows\SysWOW64\vcruntime140.dll"

# List all installed VC++ versions
Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | 
    Where-Object { $_.DisplayName -like "*Visual C++*" } |
    Select-Object DisplayName, DisplayVersion
```

## Installing Multiple Versions

To install multiple VC++ versions, run the script multiple times with different EXE files:

```powershell
# Copy this script to multiple folders
# Each folder contains different VC++ version

# Folder 1: VC++ 2013
.\Install-VisualC++Redistributables.ps1  # with vc_redist_2013.x64.exe

# Folder 2: VC++ 2015-2022
.\Install-VisualC++Redistributables.ps1  # with vc_redist.x64.exe
```

## x86 vs x64

### 64-bit Systems
- Install **both** x64 and x86 (32-bit) versions
- 64-bit apps need x64 redistributables
- 32-bit apps need x86 redistributables

### Download Both
```
vc_redist.x64.exe   (64-bit)
vc_redist.x86.exe   (32-bit)
```

## Best Practices

1. **Install Multiple Versions:** Include VC++ 2013, 2015-2022 (both x86 and x64)
2. **Image Preparation:** Pre-install in AVD master images
3. **Keep Updated:** Use latest versions for security and bug fixes
4. **Test Applications:** Verify applications launch after installation
5. **Document Requirements:** Document which applications require which versions

## Automation Example

```powershell
# Install multiple VC++ versions
$vcVersions = @(
    "vc_redist_2013.x64.exe",
    "vc_redist_2013.x86.exe",
    "vc_redist.x64.exe",  # 2015-2022
    "vc_redist.x86.exe"   # 2015-2022
)

foreach ($vcExe in $vcVersions) {
    if (Test-Path $vcExe) {
        Start-Process -FilePath $vcExe -ArgumentList "/install /quiet /norestart" -Wait
    }
}
```

## Security Considerations

1. **Official Source:** Download only from Microsoft official links
2. **Verify Signature:** Verify digital signature of installer
3. **Regular Updates:** Keep redistributables updated for security patches
4. **Controlled Deployment:** Test before deploying to production

## References

- [Latest Supported Visual C++ Downloads](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist)
- [Visual C++ Redistributable Packages](https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads)
- [VC++ Runtime Download (Latest)](https://aka.ms/vs/17/release/vc_redist.x64.exe)
- [Troubleshooting VC++ Issues](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
