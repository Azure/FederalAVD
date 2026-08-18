# Configure-Office365.ps1

## Overview

This PowerShell script configures Microsoft Office 365 (Microsoft 365) policies for Azure Virtual Desktop environments using a built-in Registry.pol (PReg format) direct writer — no LGPO.exe required. It optimizes Outlook performance and behavior for AVD session hosts.

## Purpose

- Configure Office 365/Microsoft 365 policies via Local Group Policy
- Disable automatic Office updates (for controlled image management)
- Optimize Outlook email cache duration
- Configure Outlook calendar synchronization settings
- Improve Outlook performance in AVD environments

## Where to get the Office Administrative Templates

Microsoft publishes the Office ADMX/ADML templates as a self-extracting EXE:

- Download page: [Administrative Template files (ADMX/ADML) for Microsoft 365 Apps](https://www.microsoft.com/en-us/download/details.aspx?id=49030)
- Current x64 package used by this repository: `https://download.microsoft.com/download/2/e/e/2eeec938-c014-419d-bb4b-d184871450f1/admintemplates_x64_5486-1000_en-us.exe`
- Maintained download definition: the `Office365AdministrativeTemplates` entry in
  [downloads.json](../../parameters/imageManagement/downloads.json)

For connected environments, copy the example `downloads.json` to
`customer/parameters/imageManagement/downloads.json` and run `Update-ImageArtifacts.ps1`.
The script downloads the package as `AdminTemplates_x64.exe` and adds it to the
`Configure-Office365Policy` artifact automatically.

To prepare the package manually on an internet-connected Windows system, open PowerShell in
the folder containing this README and `Configure-Office365.ps1`, then run:

```powershell
$url = 'https://download.microsoft.com/download/2/e/e/2eeec938-c014-419d-bb4b-d184871450f1/admintemplates_x64_5486-1000_en-us.exe'
Invoke-WebRequest -Uri $url -OutFile '.\AdminTemplates_x64.exe'
```

The `-OutFile` value writes `AdminTemplates_x64.exe` into the current folder. Keep that
filename and location: the policy script searches its own folder for
`admintemplates_x64*.exe`, and the example `downloads.json` uses the same destination filename.

Microsoft can replace the version-specific package URL. If the direct URL no longer works,
use the download page and update the `Office365AdministrativeTemplates` manifest entry.

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

### 1. Office Administrative Templates

Locates Office ADMX/ADML templates using the following priority order:

1. A bundled `admintemplates_x64*.exe` installer in the script directory (air-gapped friendly)
2. Already-present `office16.admx` / `outlk16.admx` in `C:\Windows\PolicyDefinitions` (no-op)
3. Download from Microsoft if the ADMX files are missing and no bundled installer is found

Once resolved, extracts and copies templates to `C:\Windows\PolicyDefinitions`.

### 2. Policy Configuration

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

### 3. Registry Configuration

- Calendar sync settings (`CalendarSyncWindowSetting`, `CalendarSyncWindowSettingMonths`) are written directly to the Default User hive because they are **not ADMX-backed** — Outlook reads them from a non-policy registry path
- All other policy values are written via Registry.pol (PReg) when ADMX templates are available

### 4. Policy Application

- Writes settings directly to `Registry.pol` in MS-GPREG (PReg) binary format — no LGPO.exe or internet access required for the policy write step
- Updates `gpt.ini` so the Group Policy client on deployed session hosts knows to process the Registry CSE
- `gpupdate` is intentionally not called during image build; the GP client processes `Registry.pol` automatically at startup/logon on deployed machines

## Policy Settings Applied

```text
Computer Configuration
└── Administrative Templates
    └── Microsoft Office 2016 (Machine)
        └── Updates
            ├── Hide Update Notifications: [Enabled]          (always)
            ├── Hide Enable/Disable Updates: [Enabled]        (always)
            └── Enable Automatic Updates: [Disabled]          (if -DisableUpdates $true)

User Configuration
└── Administrative Templates
    └── Microsoft Office 2016
        ├── Miscellaneous
        │   └── Insider Slab Behavior: [2 = do not show insider prompts]  (always)
        └── Microsoft Outlook 2016
            └── Account Settings > Exchange > Cached Exchange Mode
                ├── Use Cached Exchange Mode: [Enabled]
                └── Download email for the past: [Per -EmailCacheTime]

Default User hive  (not ADMX-backed; written directly to Default\NTUSER.dat)
└── Software\Microsoft\Office\16.0\Outlook\Cached Mode
    ├── CalendarSyncWindowSetting: [Per -CalendarSync]
    └── CalendarSyncWindowSettingMonths: [Per -CalendarSyncMonths]
```

## Registry Locations

### Office Updates (Computer — policy path)

```text
HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate
  HideUpdateNotifications:  1  (always)
  HideEnableDisableUpdates: 1  (always)
  EnableAutomaticUpdates:   0  (only when -DisableUpdates $true)
```

### Insider prompts (User — policy path, written to User Registry.pol)

```text
HKCU:\Software\Policies\Microsoft\Office\16.0\Common
  InsiderSlabBehavior: 2  (always)
```

### Outlook email cache (User — policy path, written to User Registry.pol)

```text
HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode
  Enable:                1  (when any cache setting is configured)
  SyncWindowSetting:     [Value based on -EmailCacheTime]
  SyncWindowSettingDays: [Set only for sub-month values: 3, 7, or 14 days]
```

### Outlook calendar sync (NOT policy path — written to Default User hive)

```text
HKCU:\Software\Microsoft\Office\16.0\Outlook\Cached Mode
  CalendarSyncWindowSetting:       [Value based on -CalendarSync]
  CalendarSyncWindowSettingMonths: [Value based on -CalendarSyncMonths]
```

> **Note:** CalendarSyncWindowSetting and CalendarSyncWindowSettingMonths are read by
> Outlook from the non-policy registry path (`Microsoft\Office`, not `Policies\Microsoft\Office`).
> The script writes them to the Default User hive (`C:\Users\Default\NTUSER.dat`) during
> image build so every new user profile inherits the values at first logon.

## Email Cache Time Values

| Setting | Registry Value | Description |
| --- | :---: | --- |
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

```text
C:\Windows\Logs\Configuration\Configure-Office365-<timestamp>.log
```

Log entries include:

- ADMX/ADML file deployment
- Policy application details
- Registry value creation

## Functions

| Function | Description |
| --- | --- |
| `Get-InternetFile` | Downloads files from URLs |
| `Get-InternetUrl` | Extracts download URLs from web pages |
| `New-Log` | Initializes logging infrastructure |
| `Set-PolicyRegistryValue` | Queues a registry value for writing to Registry.pol |
| `Remove-PolicyRegistryValue` | Queues a registry value deletion in Registry.pol |
| `Clear-PolicyRegistryKeyValues` | Queues removal of all values under a registry key in Registry.pol |
| `Invoke-PolicyUpdate` | Flushes the queue to Registry.pol and updates gpt.ini |
| `Set-RegistryValue` | Creates or updates registry values outside Group Policy |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Microsoft 365:** Office 2016, 2019, 2021, or Microsoft 365 Apps
- **Network Access:** Required for downloading Office ADMX files (or pre-stage them offline)

## Offline Usage

The Registry.pol write step requires no internet access.

For air-gapped environments, one of the following is sufficient to avoid download attempts:

**Option A — Bundled installer (recommended):** Download the Office Administrative Templates
package on a connected machine using the instructions in
[Where to get the Office Administrative Templates](#where-to-get-the-office-administrative-templates).
Transfer `AdminTemplates_x64.exe` to the air-gapped network, place it in
`customer/artifacts/Configure-Office365Policy/`, and run
`Update-ImageArtifacts.ps1 -SkipDownloadingNewSources`. The policy script detects and extracts
the bundled installer during the image build.

- Expected filename: `AdminTemplates_x64.exe` (the script accepts `admintemplates_x64*.exe`)

**Option B — Pre-staged ADMX files:** Copy `office16.admx`, `outlk16.admx`, and their
corresponding `.adml` files into `C:\Windows\PolicyDefinitions` (and `en-us\` subdirectory)
before running the script. The script detects the files and skips the download.

**Option C — No ADMX available:** If neither option is feasible, the script falls back to
writing all settings directly to the registry (User-scope values go to the Default User hive).

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

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
