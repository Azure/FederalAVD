# Install-FSLogix.ps1

## Overview

This PowerShell script automates the installation of FSLogix Apps on Windows systems. FSLogix is a profile management solution that enhances user experience in non-persistent VDI and RDSH environments, particularly in Azure Virtual Desktop.

## Purpose

- Install FSLogix Apps automatically
- Support both online and offline installations
- Enable profile containerization for AVD
- Support Office container and Cloud Cache features
- Integrate with AVD image building processes

## Parameters

None - This script runs with default settings.

## Usage

### Basic Usage

```powershell
.\Install-FSLogix.ps1
```

## What the Script Does

### Installation Process

1. **Check for Existing Installer**
   - Searches script directory for FSLogix ZIP file
   - Uses local file if available (offline scenario)

2. **Download FSLogix (if needed)**
   - Downloads from Microsoft servers if no local ZIP found
   - URL: https://aka.ms/fslogix_download
   - Saves to temporary directory

3. **Extract Archive**
   - Unzips FSLogix package
   - Locates x64 installer

4. **Install FSLogix**
   - Executes FSLogixAppsSetup.exe (x64 version)
   - Parameters: `/install /quiet /norestart`
   - Waits for installation to complete
   - Captures and logs exit code

5. **Verification**
   - Checks installation success via exit code
   - Logs installation completion

## Installation Details

### Download Source

**URL:** https://aka.ms/fslogix_download  
**File Type:** ZIP archive containing MSI installers  
**Size:** ~10-15 MB  

### Installation Location

```
C:\Program Files\FSLogix\Apps\
```

### Components Installed

- **FSLogix Apps Agent:** Core profile management service
- **FSLogix Apps RuleEditor:** Application masking rules tool
- **Frx.exe:** Command-line management tool

### Installation Parameters

```
/install  - Perform installation
/quiet    - Silent installation (no UI)
/norestart - Do not restart after installation
```

## What is FSLogix?

FSLogix is a profile containerization solution that:

- **Profile Containers:** Stores entire user profile in VHD/VHDX file
- **Office Containers:** Separates Outlook and OneDrive cache into dedicated container
- **Cloud Cache:** Provides redundancy and local caching for profile containers
- **Application Masking:** Controls application visibility per user/group

## Benefits for AVD

### Performance

- Faster login times compared to traditional roaming profiles
- Improved Outlook and OneDrive performance
- Reduced profile bloat

### User Experience

- Seamless roaming across session hosts
- Full fidelity (all settings and applications)
- Works with both pooled and personal desktops

### Management

- Centralized profile storage (Azure Files, NetApp, etc.)
- Simplified backup and disaster recovery
- Reduced profile corruption

## Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| **0** | Success |
| **3010** | Success - Reboot required |
| **Other** | Error occurred (see logs for details) |

## Post-Installation Configuration

After installation, FSLogix must be configured via registry or Group Policy:

### Enable Profile Container

```powershell
# Enable Profile Container
New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "Enabled" -Value 1 -PropertyType DWORD -Force

# Set VHD Location
New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "VHDLocations" -Value "\\server\share\profiles" -PropertyType MultiString -Force

# Set VHD Size (in MB)
New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "SizeInMBs" -Value 30000 -PropertyType DWORD -Force

# Set VHD Type (0=Dynamic, 1=Fixed)
New-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" -Name "IsDynamic" -Value 1 -PropertyType DWORD -Force
```

### Enable Office Container

```powershell
# Enable Office Container
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\FSLogix\ODFC" -Name "Enabled" -Value 1 -PropertyType DWORD -Force

# Set VHD Location
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\FSLogix\ODFC" -Name "VHDLocations" -Value "\\server\share\office" -PropertyType MultiString -Force
```

## Logging

Logs are created in:

```
C:\Windows\Logs\Install-FSLogix-<timestamp>.log
```

FSLogix also creates its own logs:

```
C:\ProgramData\FSLogix\Logs\
```

## Functions

| Function | Description |
|----------|-------------|
| `Get-InternetFile` | Downloads files from URLs with progress tracking |
| `New-Log` | Initializes logging infrastructure |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11, Windows Server 2016+
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Storage:** SMB share or Azure Files for profile storage (post-installation)
- **Network Access:** Required for online installation

## Offline Usage

To use this script in air-gapped environments:

1. **Download FSLogix ZIP:**
   - URL: https://aka.ms/fslogix_download
   - File: FSLogix_Apps_<version>.zip

2. **Place in Script Directory:**

   ```
   Install-FSLogix.ps1
   FSLogix_Apps_2.9.8884.27471.zip
   ```

3. **Run Script:**

   ```powershell
   .\Install-FSLogix.ps1
   ```

## Troubleshooting

### Common Issues

**Issue:** Installation fails

- **Solution:** Check logs; ensure administrator privileges; verify no conflicting profile solutions

**Issue:** Download fails

- **Solution:** Check internet connectivity; verify firewall allows Microsoft downloads

**Issue:** Profile not redirecting after installation

- **Solution:** FSLogix must be configured after installation; check registry settings

**Issue:** Service not starting

- **Solution:** Check FSLogix services in Services.msc; review FSLogix logs

### Verification

Check if FSLogix is installed:

```powershell
# Check installed application
Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*FSLogix*" }

# Check FSLogix service
Get-Service -Name "FSLogix Apps Services"

# Check installation directory
Test-Path "C:\Program Files\FSLogix\Apps"

# View FSLogix version
& "C:\Program Files\FSLogix\Apps\frx.exe" version
```

## FSLogix Services

After installation, the following services are created:

| Service | Description | Startup Type |
|---------|-------------|--------------|
| **FSLogix Apps Services** | Main FSLogix service | Automatic |

## Storage Requirements

### Azure Files (Recommended for Azure)

- **Protocol:** SMB 3.0+
- **Permissions:** NTFS + Share permissions
- **Authentication:** Azure AD Kerberos or Storage Account Key

### On-Premises File Server

- **Protocol:** SMB 3.0+
- **Permissions:** NTFS + Share permissions
- **Authentication:** Domain credentials

### Azure NetApp Files

- **Protocol:** NFS or SMB
- **Performance:** Premium tier recommended
- **Capacity:** Based on user count and profile size

## Best Practices

1. **VHD Size:** Set appropriate size (30GB default, adjust based on needs)
2. **Dynamic VHDs:** Use dynamic VHDs to save space
3. **Cloud Cache:** Enable for redundancy in production
4. **Antivirus Exclusions:** Exclude FSLogix VHD files and directories
5. **Regular Testing:** Test profile creation and roaming
6. **Monitoring:** Monitor profile storage usage and performance

## References

- [FSLogix Documentation](https://learn.microsoft.com/en-us/fslogix/)
- [FSLogix Download](https://aka.ms/fslogix_download)
- [FSLogix in Azure Virtual Desktop](https://learn.microsoft.com/en-us/azure/virtual-desktop/fslogix-profile-containers)
- [FSLogix Best Practices](https://learn.microsoft.com/en-us/fslogix/overview-prerequisites)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
