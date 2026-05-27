# Configure-OneDrive.ps1

## Overview

This PowerShell script configures OneDrive Known Folder Move (KFM) policies for Azure Virtual Desktop environments using the Local Group Policy Object (LGPO) tool. It enables automatic redirection of Windows known folders (Desktop, Documents, and Pictures) to OneDrive for Business.

## Purpose

- Enable OneDrive Known Folder Move (KFM) via Local Group Policy
- Automatically redirect Desktop, Documents, and Pictures folders to OneDrive
- Configure silent OneDrive folder redirection
- Optimize OneDrive settings for AVD environments
- Provide data backup and roaming capabilities

## Parameters

### `TenantId`

- **Type:** String
- **Required:** Yes
- **Description:** The Azure Active Directory (Azure AD) Tenant ID for your organization
- **Format:** GUID (e.g., `12345678-1234-1234-1234-123456789012`)
- **Purpose:** Associates OneDrive KFM with your specific Microsoft 365 tenant

## Usage Examples

### Basic Usage

```powershell
.\Configure-OneDrive.ps1 -TenantId "12345678-1234-1234-1234-123456789012"
```

### With Variable

```powershell
$tenantId = "12345678-1234-1234-1234-123456789012"
.\Configure-OneDrive.ps1 -TenantId $tenantId
```

### Finding Your Tenant ID

```powershell
# Method 1: Azure Portal
# Navigate to: Azure Active Directory > Properties > Tenant ID

# Method 2: PowerShell (Azure AD module)
Connect-AzureAD
(Get-AzureADTenantDetail).ObjectId

# Method 3: PowerShell (Az module)
Connect-AzAccount
(Get-AzContext).Tenant.Id
```

## What the Script Does

### 1. LGPO Tool Setup

- Downloads LGPO.exe if not present in `C:\Windows\System32`
- Extracts and copies to system directory

### 2. OneDrive KFM Configuration

The script configures the following Known Folder Move policies:

#### Silent Known Folder Move

- **Policy:** `KFMSilentOptIn`
- **Value:** Your Tenant ID
- **Effect:** Automatically moves known folders to OneDrive without user prompts
- **Folders Affected:** Desktop, Documents, Pictures

#### Block Opt-Out

- **Policy:** `KFMBlockOptOut`
- **Value:** `1` (Enabled)
- **Effect:** Prevents users from stopping known folder redirection
- **Purpose:** Ensures data is backed up to OneDrive

### 3. Policy Application

- Creates LGPO text file with OneDrive registry settings
- Applies policies using LGPO.exe
- Runs `gpupdate /force` to apply changes immediately

### 4. Registry Configuration

- Sets registry values for OneDrive KFM
- Applies to all users via Computer Configuration

## Policy Settings Applied

```
Computer Configuration
└── Administrative Templates
    └── OneDrive
        ├── Silently move Windows known folders to OneDrive: [Enabled]
        │   └── Tenant ID: [Your Tenant ID]
        └── Prevent users from redirecting their Windows known folders to their PC: [Enabled]
```

## Registry Locations

```
HKLM:\SOFTWARE\Policies\Microsoft\OneDrive
  KFMSilentOptIn: [Your Tenant ID]
  KFMBlockOptOut: 1
```

## Known Folders

The following Windows known folders are automatically redirected to OneDrive:

| Folder | Default Path | OneDrive Path |
|--------|-------------|---------------|
| **Desktop** | `C:\Users\<username>\Desktop` | `C:\Users\<username>\OneDrive - <Organization>\Desktop` |
| **Documents** | `C:\Users\<username>\Documents` | `C:\Users\<username>\OneDrive - <Organization>\Documents` |
| **Pictures** | `C:\Users\<username>\Pictures` | `C:\Users\<username>\OneDrive - <Organization>\Pictures` |

## How KFM Works

### Initial Sync Process

1. **OneDrive Detection:** OneDrive client detects KFM policy on user login
2. **Folder Check:** Checks if Desktop, Documents, Pictures exist locally
3. **Silent Move:** Moves folder contents to OneDrive without user interaction
4. **Symbolic Link:** Creates folder redirection using Windows reparse points
5. **Sync:** OneDrive syncs content to the cloud

### User Experience

- **Transparent:** Users continue accessing folders normally
- **No Prompts:** Silent configuration (no user dialogs)
- **Automatic:** Happens on next OneDrive client startup
- **Seamless:** Files appear in both local path and OneDrive

## Benefits for AVD

### Data Protection

- **Backup:** All user files automatically backed up to OneDrive
- **Disaster Recovery:** Files safe if session host fails
- **Version History:** OneDrive maintains file version history

### User Roaming

- **Multi-Device:** Files accessible from any device
- **Session Portability:** Users get same files on any AVD host
- **Personal/Pooled:** Works with both persistent and non-persistent hosts

### Profile Optimization

- **Reduced Profile Size:** Files stored in OneDrive, not in FSLogix profile
- **Faster Login:** Smaller profiles = faster FSLogix mount times
- **On-Demand Files:** OneDrive Files On-Demand reduces local storage

## Requirements

### Prerequisites

- **OS:** Windows 10 or Windows 11
- **OneDrive Client:** OneDrive sync client installed
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Licensing:** Microsoft 365 subscription with OneDrive for Business
- **Network:** Internet connectivity to OneDrive

### Tenant Configuration

- **Azure AD:** Users must have Azure AD identities
- **OneDrive:** OneDrive for Business enabled for users
- **Licenses:** Users must have OneDrive licenses assigned

## Logging

Logs are created in:

```
C:\Windows\Logs\Configuration\Configure-OneDrive-<timestamp>.log
```

Log entries include:

- LGPO tool download status
- Policy application details
- Registry value creation
- gpupdate execution results

## Functions

| Function | Description |
|----------|-------------|
| `Get-InternetFile` | Downloads files from URLs with progress tracking |
| `Invoke-LGPO` | Applies Group Policy settings using LGPO.exe |
| `New-Log` | Initializes logging infrastructure |
| `Set-RegistryValue` | Creates or updates registry values |
| `Update-LocalGPOTextFile` | Creates LGPO text files for policy settings |
| `Write-Log` | Writes formatted log entries |

## Offline Usage

To use this script in air-gapped environments:

1. **Download LGPO Tool:**
   - URL: https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip
   - Place in script directory

2. **Ensure OneDrive Client Installed:**
   - Windows 10/11 have OneDrive pre-installed
   - Or download: https://www.microsoft.com/en-us/microsoft-365/onedrive/download

3. **Run Script:**

   ```powershell
   .\Configure-OneDrive.ps1 -TenantId "your-tenant-id"
   ```

## Troubleshooting

### Common Issues

**Issue:** Known folders not moving to OneDrive

- **Solution:** Ensure OneDrive client is signed in; check Tenant ID is correct

**Issue:** Users see prompts to move folders

- **Solution:** Verify `KFMSilentOptIn` registry value; restart OneDrive client

**Issue:** Some files not syncing

- **Solution:** Check OneDrive sync status; verify file names are valid

**Issue:** Folders redirected to wrong tenant

- **Solution:** Verify Tenant ID; check user is signed into correct OneDrive account

### Verification

Check if policies were applied:

```powershell
# Check KFM registry values
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\OneDrive"

# Check OneDrive status (run as user)
$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe /status

# Generate Group Policy report
gpresult /h C:\Temp\gpresult.html

# Check folder redirection
Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
```

## Best Practices

1. **Pilot Testing:** Test KFM with pilot user group first
2. **Storage Planning:** Ensure users have sufficient OneDrive storage
3. **Network Bandwidth:** Plan for initial sync network usage
4. **User Communication:** Inform users about folder redirection
5. **Exclude Large Files:** Use selective sync to exclude large file types
6. **Monitor Sync:** Monitor OneDrive admin center for sync issues

## Known Limitations

### File/Folder Restrictions

OneDrive has limitations on what can be synced:

- **File Names:** Cannot contain: `< > : " | ? * /  \`
- **File Size:** Maximum 250 GB per file
- **Path Length:** Maximum 400 characters
- **Special Folders:** Cannot sync system folders
- **Unsupported Types:** Some file types may be blocked (e.g., PST files)

### Performance Considerations

- **Initial Sync:** Large folders take time to upload
- **Network Usage:** OneDrive uses bandwidth for syncing
- **CPU Usage:** Sync process uses CPU resources
- **Battery Impact:** Increased battery usage on mobile devices

## Advanced Configuration

### Additional OneDrive Policies

You can extend this script with additional policies:

```powershell
# Configure Files On-Demand
Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\OneDrive' `
    -RegistryValue 'FilesOnDemandEnabled' -RegistryData '1' -RegistryType 'DWORD'

# Set disk space warning threshold
Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\OneDrive' `
    -RegistryValue 'DiskSpaceCheckThresholdMB' -RegistryData '500' -RegistryType 'DWORD'
```

## References

- [OneDrive Known Folder Move](https://learn.microsoft.com/en-us/onedrive/redirect-known-folders)
- [OneDrive Group Policy Settings](https://learn.microsoft.com/en-us/onedrive/use-group-policy)
- [OneDrive Administrative Templates](https://learn.microsoft.com/en-us/onedrive/administrative-settings)
- [AVD with OneDrive](https://learn.microsoft.com/en-us/azure/virtual-desktop/teams-on-avd)
- [LGPO Tool Documentation](https://techcommunity.microsoft.com/t5/microsoft-security-baselines/lgpo-exe-local-group-policy-object-utility-v1-0/ba-p/701045)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
