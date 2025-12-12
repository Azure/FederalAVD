# Configure-Office365.ps1

## Overview

This PowerShell script configures Microsoft Office 365 (Microsoft 365) policies for Azure Virtual Desktop environments using the Local Group Policy Object (LGPO) tool. It optimizes Outlook performance and behavior for AVD session hosts.

## Purpose

- Configure Office 365/Microsoft 365 policies via Local Group Policy
- Disable automatic Office updates (for controlled image management)
- Optimize Outlook email cache duration
- Configure Outlook calendar synchronization settings
- Improve Outlook performance in AVD environments

## Parameters

### `DisableUpdates`

- **Type:** Boolean
- **Default:** Not set (optional parameter)
- **Description:** When `$true`, disables automatic Office 365 updates
- **Recommendation:** Set to `$true` in AVD environments for controlled update management

### `EmailCacheTime`

- **Type:** String
- **Default:** `"1 month"`
- **Options:** 
  - `"Not Configured"`
  - `"3 days"`
  - `"1 week"`
  - `"2 weeks"`
  - `"1 month"` *(Recommended)*
  - `"3 months"`
  - `"6 months"`
  - `"12 months"`
  - `"24 months"`
  - `"36 months"`
  - `"60 months"`
  - `"All"`
- **Description:** Amount of email to cache locally in Outlook
- **Recommendation:** `"1 month"` for AVD (balances performance and cache size)

### `CalendarSync`

- **Type:** String
- **Default:** `"Primary Calendar Only"`
- **Options:**
  - `"Not Configured"`
  - `"Inactive"` - Disable calendar sync
  - `"Primary Calendar Only"` *(Recommended)*
  - `"All Calendar Folders"`
- **Description:** Controls which calendars are synchronized in Cached Exchange Mode
- **Recommendation:** `"Primary Calendar Only"` for optimal performance ([Microsoft Support Article](https://support.microsoft.com/en-us/help/2768656))

### `CalendarSyncMonths`

- **Type:** String
- **Default:** `"1"`
- **Options:** `"Not Configured"`, `"1"`, `"3"`, `"6"`, `"12"`
- **Description:** Number of months of calendar data to synchronize
- **Recommendation:** `"1"` month for optimal performance ([Microsoft Support Article](https://support.microsoft.com/en-us/help/2768656))

## Usage Examples

### Basic Usage (Recommended Settings)

```powershell
.\Configure-Office365.ps1
```

### Disable Office Updates

```powershell
.\Configure-Office365.ps1 -DisableUpdates $true
```

### Custom Email Cache (3 Months)

```powershell
.\Configure-Office365.ps1 -EmailCacheTime "3 months"
```

### All Calendar Folders with 3 Months Sync

```powershell
.\Configure-Office365.ps1 -CalendarSync "All Calendar Folders" -CalendarSyncMonths "3"
```

### Complete Custom Configuration

```powershell
.\Configure-Office365.ps1 `
    -DisableUpdates $true `
    -EmailCacheTime "2 weeks" `
    -CalendarSync "Primary Calendar Only" `
    -CalendarSyncMonths "1"
```

## What the Script Does

### 1. LGPO Tool Setup

- Downloads LGPO.exe if not present
- Copies to `C:\Windows\System32`

### 2. Office Administrative Templates

- Downloads latest Office Administrative Template files (ADMX/ADML)
- Extracts and copies to `C:\Windows\PolicyDefinitions`
- Ensures Group Policy can manage Office 365 settings

### 3. Policy Configuration

#### Update Management

- Disables automatic Office updates (if specified)
- Allows controlled update management through image versioning

#### Email Cache Optimization

- Configures Outlook to cache specified duration of email
- Reduces OST file size
- Improves login times in AVD

#### Calendar Synchronization

- Limits calendar sync to primary calendar only
- Reduces sync time and cache size
- Prevents performance issues with large calendars

### 4. Registry Configuration

- Sets Outlook registry values directly for policies without ADMX support
- Configures Exchange account settings

### 5. Policy Application

- Applies settings using LGPO.exe
- Runs `gpupdate /force` to apply changes immediately

## Policy Settings Applied

```
Computer Configuration
└── Administrative Templates
    └── Microsoft Office 2016 (Machine)
        └── Updates
            └── Enable Automatic Updates: [Disabled] (if DisableUpdates = $true)

User Configuration
└── Administrative Templates
    └── Microsoft Outlook 2016
        └── Account Settings
            └── Exchange
                ├── Cached Exchange Mode
                │   ├── Use Cached Exchange Mode: [Enabled]
                │   ├── Download email for the past: [Configured]
                │   ├── Calendar sync mode: [Configured]
                │   └── Calendar sync slider: [Configured]
```

## Registry Locations

### Office Updates

```
HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate
  EnableAutomaticUpdates: 0 (Disabled) or 1 (Enabled)
```

### Outlook Cache Settings

```
HKCU:\SOFTWARE\Policies\Microsoft\Office\16.0\Outlook\Cached Mode
  SyncWindowSetting: [Value based on EmailCacheTime]
  CalendarSyncWindowSetting: [Value based on CalendarSync]
  CalendarSyncWindowSettingMonths: [Value based on CalendarSyncMonths]
```

## Email Cache Time Values

| Setting | Registry Value | Description |
|---------|----------------|-------------|
| 3 days | 3 | Cache last 3 days |
| 1 week | 7 | Cache last week |
| 2 weeks | 14 | Cache last 2 weeks |
| 1 month | 1 | Cache last month |
| 3 months | 3 | Cache last 3 months |
| 6 months | 6 | Cache last 6 months |
| 12 months | 12 | Cache last year |
| 24 months | 24 | Cache last 2 years |
| 36 months | 36 | Cache last 3 years |
| 60 months | 60 | Cache last 5 years |
| All | 0 | Cache all email |

## Performance Recommendations

### AVD Session Host Optimization

**Email Cache:**

- **Small profiles (< 5GB):** `"1 month"` or `"2 weeks"`
- **Medium profiles (5-10GB):** `"2 weeks"` or `"1 week"`
- **Large profiles (> 10GB):** `"1 week"` or `"3 days"`

**Calendar Sync:**

- **Always use:** `"Primary Calendar Only"` with `"1"` month
- Syncing all calendar folders can cause performance issues

### Why These Settings Matter

**Cached Exchange Mode:**

- Stores a copy of mailbox data locally
- Improves Outlook responsiveness
- But increases profile size and login times in AVD

**Reduced Cache Duration:**

- Smaller OST files
- Faster profile loads with FSLogix
- Better user experience in non-persistent desktops

## Logging

Logs are created in:

```
C:\Windows\Logs\Configuration\Configure-Office365-<timestamp>.log
```

Log entries include:

- LGPO tool download and setup
- ADMX/ADML file deployment
- Policy application details
- Registry value creation
- gpupdate execution results

## Functions

| Function | Description |
|----------|-------------|
| `Get-InternetFile` | Downloads files from URLs |
| `Get-InternetUrl` | Extracts download URLs from web pages |
| `Invoke-LGPO` | Applies Group Policy settings using LGPO.exe |
| `New-Log` | Initializes logging infrastructure |
| `Set-RegistryValue` | Creates or updates registry values |
| `Update-LocalGPOTextFile` | Creates LGPO text files for policy settings |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Microsoft 365:** Office 2016, 2019, 2021, or Microsoft 365 Apps
- **Network Access:** Required for downloading LGPO and Office ADMX files

## Offline Usage

To use this script in air-gapped environments:

1. **Pre-download Required Files:**
   - LGPO.zip: https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip
   - Office Administrative Templates: https://www.microsoft.com/en-us/download/details.aspx?id=49030

2. **Place Files in Script Directory**

3. **Run Script:**

   ```powershell
   .\Configure-Office365.ps1
   ```

## Troubleshooting

### Common Issues

**Issue:** Outlook still downloads all email

- **Solution:** Verify registry values; delete and recreate Outlook profile

**Issue:** Calendar sync settings not applied

- **Solution:** Check User Configuration policies with `gpresult /h report.html`

**Issue:** Office still updates automatically

- **Solution:** Verify Computer Configuration policy; check Task Scheduler for Office Update tasks

**Issue:** ADMX files not found

- **Solution:** Ensure Office Administrative Templates are in `C:\Windows\PolicyDefinitions`

### Verification

Check if policies were applied:

```powershell
# Check Office Update setting (Computer)
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate" -Name EnableAutomaticUpdates

# Check Outlook cache settings (User - run as user)
Get-ItemProperty "HKCU:\SOFTWARE\Policies\Microsoft\Office\16.0\Outlook\Cached Mode"

# Generate Group Policy report
gpresult /h C:\Temp\gpresult.html
```

## Best Practices

1. **Test First:** Test settings with pilot users before broad deployment
2. **Profile Size:** Monitor FSLogix profile sizes after changing cache settings
3. **Update Control:** Use DisableUpdates in image-based deployments
4. **Documentation:** Document cache settings for troubleshooting
5. **Regular Review:** Review settings quarterly based on user feedback

## References

- [Microsoft Outlook Performance Best Practices](https://support.microsoft.com/en-us/help/2768656)
- [Office Administrative Template Files](https://www.microsoft.com/en-us/download/details.aspx?id=49030)
- [Configure Outlook Cached Exchange Mode](https://learn.microsoft.com/en-us/outlook/troubleshoot/performance/performance-issues-if-too-many-items-or-folders)
- [LGPO Tool Documentation](https://techcommunity.microsoft.com/t5/microsoft-security-baselines/lgpo-exe-local-group-policy-object-utility-v1-0/ba-p/701045)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
