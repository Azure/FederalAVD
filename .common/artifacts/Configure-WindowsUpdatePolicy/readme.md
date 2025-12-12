# Configure-WindowsUpdatePolicy.ps1

## Overview

This PowerShell script configures Windows Update policies for Azure Virtual Desktop environments using the Local Group Policy Object (LGPO) tool. It manages update behavior, defer periods, and installation schedules to optimize patching in AVD host pools.

## Purpose

- Configure Windows Update policies via Local Group Policy
- Control automatic update installation
- Defer quality updates for testing
- Schedule update installation times
- Optimize update management for AVD environments

## Parameters

### `DisableUpdates`

- **Type:** String (Boolean)
- **Default:** `"False"`
- **Values:** `"True"` or `"False"`
- **Description:** Disables automatic Windows Updates completely
- **Recommendation:** `"True"` for image-based AVD deployments; `"False"` for persistent desktops

### `DeferQualityUpdatesPeriodInDays`

- **Type:** String
- **Default:** `"0"`
- **Range:** `"0"` to `"30"` days
- **Description:** Number of days to defer quality updates (security and bug fixes) after release
- **Recommendation:** `"7"` to `"14"` days for testing before deployment

### `ScheduledInstallDay`

- **Type:** String
- **Default:** `"EveryDay"`
- **Options:** 
  - `"EveryDay"`
  - `"Sunday"`, `"Monday"`, `"Tuesday"`, `"Wednesday"`, `"Thursday"`, `"Friday"`, `"Saturday"`
- **Description:** Day of the week to install updates
- **Recommendation:** Choose a day with lower user activity

### `ScheduledInstallTime`

- **Type:** String
- **Default:** `"Automatic"`
- **Options:** `"Automatic"`, `"0"` through `"23"` (hours in 24-hour format)
- **Description:** Hour of the day to install updates
- **Recommendation:** Schedule during maintenance windows or off-peak hours

## Usage Examples

### Basic Usage (Default Settings)

```powershell
.\Configure-WindowsUpdatePolicy.ps1
```

### Disable Updates Completely

```powershell
.\Configure-WindowsUpdatePolicy.ps1 -DisableUpdates "True"
```

### Defer Updates 7 Days, Install on Sunday at 3 AM

```powershell
.\Configure-WindowsUpdatePolicy.ps1 `
    -DeferQualityUpdatesPeriodInDays "7" `
    -ScheduledInstallDay "Sunday" `
    -ScheduledInstallTime "3"
```

### Maintenance Window Configuration

```powershell
.\Configure-WindowsUpdatePolicy.ps1 `
    -DisableUpdates "False" `
    -DeferQualityUpdatesPeriodInDays "14" `
    -ScheduledInstallDay "Saturday" `
    -ScheduledInstallTime "2"
```

### Image-Based Deployment

```powershell
.\Configure-WindowsUpdatePolicy.ps1 -DisableUpdates "True"
```

## What the Script Does

### 1. LGPO Tool Setup

- Downloads LGPO.exe if not present
- Copies to `C:\Windows\System32`

### 2. Windows Update Configuration

#### Disable Updates (if DisableUpdates = "True")

- Disables Windows Update service
- Prevents automatic update downloads and installations
- Stops Windows Update system service

#### Update Deferral

- Defers quality updates by specified number of days
- Allows time for testing before deployment
- Does not affect feature updates

#### Installation Schedule

- Configures automatic installation day
- Sets installation time
- Schedules system restarts if required

### 3. Policy Application

- Creates LGPO text files with Windows Update registry settings
- Applies policies using LGPO.exe
- Runs `gpupdate /force` to apply changes immediately

## Policy Settings Applied

```
Computer Configuration
└── Administrative Templates
    └── Windows Components
        └── Windows Update
            └── Manage end user experience
                ├── Configure Automatic Updates: [Configured]
                │   ├── Scheduled install day: [Configured]
                │   └── Scheduled install time: [Configured]
                ├── Specify deadline before auto-restart for update installation
                └── Defer Quality Updates: [Configured]
                    └── Defer period: [0-30 days]
```

## Registry Locations

```
HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU
  NoAutoUpdate: 1 (Updates disabled) or 0 (Updates enabled)
  AUOptions: 4 (Auto download and schedule install)
  ScheduledInstallDay: [0-7] (0=Every day, 1=Sunday, 2=Monday, etc.)
  ScheduledInstallTime: [0-23] (Hour in 24-hour format)

HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate
  DeferQualityUpdates: 1 (Enabled)
  DeferQualityUpdatesPeriodInDays: [0-30]
```

## Update Types

### Quality Updates

- **Description:** Security updates, bug fixes, monthly cumulative updates
- **Frequency:** Monthly (Patch Tuesday)
- **Deferrable:** Yes (up to 30 days)
- **Impact:** Security and stability improvements

### Feature Updates

- **Description:** Major Windows version updates (e.g., Windows 11 22H2 → 23H2)
- **Frequency:** Annually
- **Deferrable:** Yes (up to 365 days, configured separately)
- **Impact:** New features and significant changes

## Recommendations by Deployment Type

### Image-Based (Non-Persistent) Desktops

**Settings:**

```powershell
-DisableUpdates "True"
```

**Reason:** Updates applied to master image, not individual session hosts

### Persistent Desktops (Personal)

**Settings:**

```powershell
-DisableUpdates "False"
-DeferQualityUpdatesPeriodInDays "7"
-ScheduledInstallDay "Sunday"
-ScheduledInstallTime "3"
```

**Reason:** Regular updates needed; schedule during off-hours

### Production Environment

**Settings:**

```powershell
-DisableUpdates "False"
-DeferQualityUpdatesPeriodInDays "14"
-ScheduledInstallDay "Saturday"
-ScheduledInstallTime "2"
```

**Reason:** 2-week testing period; weekend installation minimizes disruption

### Development/Test Environment

**Settings:**

```powershell
-DisableUpdates "False"
-DeferQualityUpdatesPeriodInDays "0"
-ScheduledInstallDay "EveryDay"
-ScheduledInstallTime "3"
```

**Reason:** Test updates immediately; early warning for issues

## Best Practices

1. **Image Management:** Disable updates in non-persistent desktops; update master image instead
2. **Testing Window:** Defer updates 7-14 days for production environments
3. **Maintenance Windows:** Schedule installations during off-peak hours
4. **User Communication:** Inform users of scheduled maintenance windows
5. **Monitoring:** Track update compliance in Azure Update Management or Microsoft Endpoint Manager
6. **Restart Management:** Configure restart policies to minimize user disruption

## Impact on AVD Session Hosts

### With Updates Disabled

**Pros:**

- Consistent user experience across all hosts
- No unexpected restarts
- Controlled update deployment via image updates
- Simplified host management

**Cons:**

- Security updates delayed until next image refresh
- Manual image update process required
- Potential security exposure between image updates

### With Updates Enabled

**Pros:**

- Hosts receive security updates promptly
- Less dependency on image refresh cycle
- Better security posture

**Cons:**

- Potential host drift (different patch levels)
- Scheduled restarts may impact users
- Bandwidth consumption for updates

## Logging

Logs are created in:

```
C:\Windows\Logs\Configuration\Configure-WindowsUpdatePolicy-<timestamp>.log
```

Log entries include:

- LGPO tool download status
- Policy application details
- Registry value creation
- Windows Update service status changes
- gpupdate execution results

## Functions

| Function | Description |
|----------|-------------|
| `Get-InternetFile` | Downloads files from URLs with progress tracking |
| `Invoke-LGPO` | Applies Group Policy settings using LGPO.exe |
| `New-Log` | Initializes logging infrastructure |
| `Remove-RegistryValue` | Deletes registry values |
| `Set-RegistryValue` | Creates or updates registry values |
| `Update-LocalGPOTextFile` | Creates LGPO text files for policy settings |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Network Access:** Required for downloading LGPO (unless using offline mode)

## Troubleshooting

### Common Issues

**Issue:** Updates still installing despite DisableUpdates = "True"

- **Solution:** Verify Windows Update service is stopped; check registry values

**Issue:** Updates not deferring

- **Solution:** Check DeferQualityUpdates registry value; ensure Group Policy applied

**Issue:** Scheduled installation time not working

- **Solution:** Verify ScheduledInstallTime registry value; check Task Scheduler

**Issue:** Hosts restarting unexpectedly

- **Solution:** Review Windows Update logs; adjust restart policies

### Verification

Check if policies were applied:

```powershell
# Check Windows Update registry values
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"

# Check Windows Update service status
Get-Service wuauserv

# View pending updates
Get-WindowsUpdate -List

# Generate Group Policy report
gpresult /h C:\Temp\gpresult.html

# Check Windows Update logs
Get-WindowsUpdateLog
```

## References

- [Windows Update for Business](https://learn.microsoft.com/en-us/windows/deployment/update/waas-manage-updates-wufb)
- [Configure Windows Update Policies](https://learn.microsoft.com/en-us/windows/deployment/update/waas-wu-settings)
- [AVD Update Management](https://learn.microsoft.com/en-us/azure/virtual-desktop/configure-automatic-updates)
- [LGPO Tool Documentation](https://techcommunity.microsoft.com/t5/microsoft-security-baselines/lgpo-exe-local-group-policy-object-utility-v1-0/ba-p/701045)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
