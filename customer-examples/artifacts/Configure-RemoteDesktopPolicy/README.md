# Configure-RemoteDesktopServicesPolicy.ps1

## Overview

This PowerShell script configures Remote Desktop Services session timeout policies for Azure Virtual Desktop environments using a built-in Registry.pol (PReg format) direct writer — no LGPO.exe required. It manages idle and disconnected session timeouts to optimize resource utilization and user experience.

## Purpose

- Configure Remote Desktop Services session timeouts via Local Group Policy
- Set maximum idle time before session disconnect
- Set maximum disconnection time before session termination
- Optimize resource utilization in AVD host pools
- Balance user convenience with resource management

## Parameters

### `MaxIdleTime`

- **Type:** String (ADMX label)
- **Default:** `'3 Hours'`
- **Values:** See [Common Timeout Values](#common-timeout-values) table below
- **Description:** Maximum time an active session can remain idle before the action defined by `EndSessionOnLimit` is taken (disconnect or logoff). The script converts the label to the corresponding millisecond DWORD value before writing to `Registry.pol`.

### `MaxDisconnectionTime`

- **Type:** String (ADMX label)
- **Default:** `'3 Hours'`
- **Values:** See [Common Timeout Values](#common-timeout-values) table below
- **Description:** Maximum time a disconnected session can remain before being logged off. Always results in logoff regardless of `EndSessionOnLimit`. The script converts the label to the corresponding millisecond DWORD value before writing to `Registry.pol`.

### `EndSessionOnLimit`

- **Type:** String
- **Default:** *(not set — OS default of `0` applies)*
- **Values:** `0` or `1`
- **Description:** Controls whether session time limit expiry disconnects or ends (logs off) the session. Maps to the Group Policy setting **"End session when time limits are reached"** (registry value `fResetBroken`). When not passed, this value is not written and the OS default (`0`) is preserved.
  - `0` — Idle timeout **disconnects** the session. The FSLogix profile VHD stays mounted. Compaction does not run until `MaxDisconnectionTime` subsequently expires and forces a logoff.
  - `1` — Idle timeout **logs off** the session immediately. The FSLogix profile VHD is dismounted and compaction runs at logoff.

### `DisconnectOnLockMsIdentity`

- **Type:** String
- **Default:** *(not set — OS default applies)*
- **Values:** `0` or `1`
- **Description:** Controls whether locking the remote session disconnects the RDP client or shows the remote lock screen. Only relevant when **Entra ID SSO** is enabled on the host pool. Maps to the Group Policy setting **"Disconnect remote session on lock for Microsoft identity platform authentication"** (registry value `fDisconnectOnLockMicrosoftIdentity`). When not passed, this value is not written.
  - `1` — Session **disconnects** when locked (OS default for Entra ID SSO). `MaxDisconnectionTime` starts immediately. `MaxIdleTime` is bypassed if `MachineInactivityTimeout` fires first.
  - `0` — Remote **lock screen** is shown instead of disconnecting. Both `MaxIdleTime` and `MaxDisconnectionTime` apply as normal.

### `EnableRemoteApp`

- **Type:** Switch
- **Default:** Not set (disabled)
- **Description:** When specified, enables the enhanced shell experience for RemoteApp sessions (registry value `EnableEnhancedShellExperienceForRemoteApp`). This supports default file associations, Run/RunOnce registry keys, and other shell features in published RemoteApp programs. Has no effect on standard Remote Desktop sessions.

## Common Timeout Values

These are the exact labels accepted by `-MaxIdleTime` and `-MaxDisconnectionTime`. They match the
ADMX enum detents for these policies. The script converts each label to the corresponding
millisecond DWORD value before writing to `Registry.pol`.

| Label (pass as parameter) | Milliseconds | Notes |
| :-----------------------: | :----------: | :---- |
| `'Never'` | `0` | No timeout — not recommended for pooled hosts |
| `'1 Minute'` | `60000` | |
| `'5 Minutes'` | `300000` | |
| `'10 Minutes'` | `600000` | |
| `'15 Minutes'` | `900000` | |
| `'30 Minutes'` | `1800000` | |
| `'1 Hour'` | `3600000` | |
| `'2 Hours'` | `7200000` | |
| `'3 Hours'` | `10800000` | **Default** for both timeouts in this script |
| `'6 Hours'` | `21600000` | |
| `'8 Hours'` | `28800000` | |
| `'12 Hours'` | `43200000` | |
| `'16 Hours'` | `57600000` | |
| `'18 Hours'` | `64800000` | |
| `'1 Day'` | `86400000` | |
| `'2 Days'` | `172800000` | |
| `'3 Days'` | `259200000` | |
| `'4 Days'` | `345600000` | |
| `'5 Days'` | `432000000` | Maximum recommended |

## Usage Examples

### Basic Usage (Default: 3-hour idle + 3-hour disconnected, disconnect on timeout)

```powershell
.\Configure-RemoteDesktopServicesPolicy.ps1
```

### Logoff on Idle Timeout (compaction runs at idle timeout)

```powershell
.\Configure-RemoteDesktopServicesPolicy.ps1 -EndSessionOnLimit '1'
```

### 1-Hour Idle, 12-Hour Disconnection, Logoff on Limit

```powershell
.\Configure-RemoteDesktopServicesPolicy.ps1 -MaxIdleTime '1 Hour' -MaxDisconnectionTime '12 Hours' -EndSessionOnLimit '1'
```

### Full Work Day (8 Hours)

```powershell
.\Configure-RemoteDesktopServicesPolicy.ps1 -MaxIdleTime '8 Hours' -MaxDisconnectionTime '8 Hours'
```

### Aggressive Resource Reclamation (30 Minutes, logoff immediately)

```powershell
.\Configure-RemoteDesktopServicesPolicy.ps1 -MaxIdleTime '30 Minutes' -MaxDisconnectionTime '30 Minutes' -EndSessionOnLimit '1'
```

## What the Script Does

### 1. Session Timeout Configuration

#### Max Idle Time

- **Policy:** Set time limit for active but idle Remote Desktop Services sessions
- **Effect:** After this duration of inactivity, session is automatically disconnected
- **User Experience:** User sees "Your session has been disconnected" message
- **Reconnection:** User can reconnect immediately and resume session

#### Max Disconnection Time

- **Policy:** Set time limit for disconnected sessions
- **Effect:** After this duration, disconnected session is logged off and terminated
- **User Experience:** Session is completely ended; all applications closed
- **Reconnection:** User must start a new session

### 2. Policy Application

- Writes settings directly to `Registry.pol` in MS-GPREG (PReg) binary format — no LGPO.exe or internet access required
- Updates `gpt.ini` so the Group Policy client on deployed session hosts knows to process the Registry CSE
- `gpupdate` is intentionally not called during image build; the GP client processes `Registry.pol` automatically at startup/logon on deployed machines

## Policy Settings Applied

```text
Computer Configuration
└── Administrative Templates
    └── Windows Components
        └── Remote Desktop Services
            └── Remote Desktop Session Host
                ├── Session Time Limits
                │   ├── Set time limit for active but idle Remote Desktop Services sessions: [Enabled]
                │   │   └── Idle session limit: [MaxIdleTime value]
                │   ├── Set time limit for disconnected sessions: [Enabled]
                │   │   └── Disconnected session limit: [MaxDisconnectionTime value]
                │   └── End session when time limits are reached: [Enabled if EndSessionOnLimit = 1]
                └── Security
                    └── Disconnect remote session on lock for Microsoft identity platform
                        authentication: [Enabled/Disabled if DisconnectOnLockMsIdentity is set]
```

## Registry Locations

```text
HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services
  MaxIdleTime:                       [Value in milliseconds]  -- idle timeout
  MaxDisconnectionTime:              [Value in milliseconds]  -- disconnected session timeout
  fResetBroken:                      0 or 1                   -- written only if EndSessionOnLimit is passed
  fDisconnectOnLockMicrosoftIdentity: 0 or 1                  -- written only if DisconnectOnLockMsIdentity is passed
  fEnableTimeZoneRedirection:        1                        -- always written
  EnableEnhancedShellExperienceForRemoteApp: 1               -- written only if -EnableRemoteApp is passed
```

## Session State Diagram

The behavior when `MaxIdleTime` expires depends on `EndSessionOnLimit` (`fResetBroken`):

```text
Active Session (user working)
       |
       | (no input for MaxIdleTime)
       |
       +-- EndSessionOnLimit = 0 (default) --> Disconnected
       |                                          |  VHD still mounted, compaction: NO
       |                                          |
       |                                          | (disconnected for MaxDisconnectionTime)
       |                                          |
       |                                        Logged Off
       |                                          |  VHD dismounted, compaction: YES
       |
       +-- EndSessionOnLimit = 1 ------------> Logged Off
                                                  |  VHD dismounted, compaction: YES

Disconnected Session (user closed RDP client)
       |
       | (disconnected for MaxDisconnectionTime, regardless of EndSessionOnLimit)
       |
     Logged Off
       |  VHD dismounted, compaction: YES
```

## Recommendations by Environment

### Pooled (Non-Persistent) Desktops

**Aggressive Timeouts:**

- **MaxIdleTime:** `'30 Minutes'` to `'1 Hour'`
- **MaxDisconnectionTime:** `'30 Minutes'` to `'1 Hour'`
- **Reason:** Free up resources quickly; users don't expect session persistence

### Personal (Persistent) Desktops

**Moderate Timeouts:**

- **MaxIdleTime:** `'2 Hours'` to `'6 Hours'`
- **MaxDisconnectionTime:** `'6 Hours'` to `'8 Hours'`
- **Reason:** Users expect session persistence; less pressure to free resources

### Task Workers (Call Centers, Data Entry)

**Balanced Timeouts:**

- **MaxIdleTime:** `'1 Hour'` to `'2 Hours'`
- **MaxDisconnectionTime:** `'2 Hours'` to `'6 Hours'`
- **Reason:** Regular breaks expected; sessions should persist during lunch

### Knowledge Workers (Development, Design)

**Generous Timeouts:**

- **MaxIdleTime:** `'6 Hours'` to `'8 Hours'`
- **MaxDisconnectionTime:** `'8 Hours'` to `'12 Hours'`
- **Reason:** Long meetings and research sessions; expensive to restart applications

## Impact on User Experience

### Idle Timeout Effects

**Positive:**

- Prevents accidental lockouts
- Maintains security by disconnecting idle sessions
- Frees up host resources

**Negative:**

- Can disconnect during long meetings
- May interrupt long-running reports
- Users must reconnect after breaks

### Disconnection Timeout Effects

**Positive:**

- Allows quick reconnection after network issues
- Preserves session state during brief disconnections
- Apps continue running while disconnected

**Negative:**

- Long-running processes may fail if session ends
- Unsaved work lost if timeout expires
- Confusion if session silently terminates

## Best Practices

1. **Align with Business Hours:** Set disconnection timeout to match work shift length
2. **Communicate Changes:** Inform users of timeout policies
3. **Monitor Usage:** Review session logs to optimize timeout values
4. **Test First:** Pilot timeout settings with small user group
5. **Document Policy:** Clearly document timeout rationale
6. **Consider Use Cases:** Different user groups may need different timeouts
7. **Balance Resources:** Shorter timeouts free resources but may frustrate users

## Logging

Logs are created in:

```text
C:\Windows\Logs\Configuration\Configure-RemoteDesktopServicesPolicy-<timestamp>.log
```

Log entries include:

- Policy application details
- Registry value creation

## Functions

| Function | Description |
| --- | --- |
| `Write-Log` | Writes formatted log entries |
| `New-Log` | Initializes logging infrastructure |
| `Set-PolicyRegistryValue` | Queues a registry value for writing to Registry.pol |
| `Remove-PolicyRegistryValue` | Queues a registry value deletion in Registry.pol |
| `Clear-PolicyRegistryKeyValues` | Queues deletion of all values in a Registry.pol key |
| `Invoke-PolicyUpdate` | Flushes the queue to Registry.pol and updates gpt.ini |

## Requirements

- **OS:** Windows 10 or Windows 11 (with RDS role)
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Network Access:** Not required — policies are written directly to Registry.pol

## Troubleshooting

### Common Issues

**Issue:** Timeouts not enforced

- **Solution:** Verify registry values; ensure gpupdate ran successfully

**Issue:** Sessions disconnect too quickly

- **Solution:** Increase MaxIdleTime value

**Issue:** Sessions persist too long

- **Solution:** Decrease MaxDisconnectionTime value

**Issue:** Users complain about disconnections

- **Solution:** Review and adjust timeout values; communicate expectations

### Verification

Check if policies were applied:

```powershell
# Check timeout registry values
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"

# Generate Group Policy report
gpresult /h C:\Temp\gpresult.html

# Check current RDS sessions
qwinsta

# View session timeouts for active sessions
query session
```

## References

- [RDS Session Time Limits](https://learn.microsoft.com/en-us/troubleshoot/windows-server/remote/remote-desktop-disconnected-user-logs-back)
- [AVD Session Management](https://learn.microsoft.com/en-us/azure/virtual-desktop/set-up-customize-master-image)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
