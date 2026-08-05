# SmartCard-Lock-Monitor

## Overview

Monitors smart card state via PC/SC redirection and locks the AVD session host
workstation when the smart card is removed from the remote client.

Intended for environments using **Entra ID SSO** (`enablerdsaadauth:i:1`) where the
Windows built-in Smart Card Removal Policy (`SCRemoveOption`) does not fire —
because Windows on the session host sees an Entra ID token, not a smart card
logon — and therefore cannot lock the screen on card removal without this
artifact.

## How It Works

```text
Client PC                           Session Host (AVD)
----------                          ------------------
Smart card reader                   PC/SC service (SCardSvr)
  |                                   |
  | RDP TSSCARD virtual channel       |
  +---------------------------------> Watch-SmartCardRemoval.ps1
                                        | SCardGetStatusChange()
                                        | detects SCARD_STATE_EMPTY
                                        v
                                      rundll32 user32.dll,LockWorkStation
```

The installer (`Install-SmartCardLockMonitor.ps1`) runs during image build and
registers a **hidden scheduled task** that starts the monitor script at user
logon. No console window ever appears.

## Prerequisites

| Requirement | Details |
| --- | --- |
| Smart card redirection | Host pool RDP property must include `redirect smartcards:i:1` |
| AVD client | Windows App or Remote Desktop Client — must allow smart card redirection |
| Session host OS | Windows 10/11 or Windows Server 2019/2022 |
| PowerShell | 5.1 or higher |
| Entra ID SSO | Optional — this artifact is designed for SSO environments but works without it |

> **Note:** Smart card **redirection** (`redirect smartcards:i:1`) and Entra ID
> **SSO** (`enablerdsaadauth:i:1`) are independent RDP properties. Both can be active
> simultaneously. SSO handles authentication to the session host; redirection
> makes the physical card available inside the session and to this monitor script.

## Files

| File | Description |
| --- | --- |
| `Install-SmartCardLockMonitor.ps1` | Run during image build as SYSTEM. Copies the monitor script and VBScript launcher, creates the event log source, and registers the scheduled task. |
| `Watch-SmartCardRemoval.ps1` | Monitor script. Runs hidden at user logon via scheduled task. Exits cleanly if no readers are redirected. |
| `Watch-SmartCardRemoval.vbs` | VBScript launcher. Invokes the PS1 via `wscript.exe` with window style `0` so no console window or taskbar entry ever appears. |

## Usage

### Image Build (via Invoke-Customization.ps1)

```powershell
.\Install-SmartCardLockMonitor.ps1
```

No parameters required. Reads `Watch-SmartCardRemoval.ps1` from the same
directory (`$PSScriptRoot`) and copies it to
`C:\ProgramData\FederalAVD\SmartCardLock\`.

### Manual Installation

```powershell
# Run as Administrator or SYSTEM
Set-Location "C:\path\to\SmartCard-Lock-Monitor"
.\Install-SmartCardLockMonitor.ps1
```

## Scheduled Task Details

| Property | Value |
| --- | --- |
| Task name | `SmartCard-Lock-Monitor` |
| Trigger | At logon (any user) |
| Principal | `BUILTIN\Users`, RunLevel Limited |
| Execute | `wscript.exe` |
| Argument | `"C:\ProgramData\FederalAVD\SmartCardLock\Watch-SmartCardRemoval.vbs"` |
| Window | None — `wscript.exe` with style `0` suppresses all window creation |
| Execution time limit | None (runs for the duration of the session) |
| Multiple instances | Ignore New (prevents duplicate instances on reconnect) |

The task runs as the logged-on user (not SYSTEM), which is required because
`LockWorkStation` must be called in the user's session context.

## Runtime Behavior

### Startup

The monitor attempts to establish a PC/SC context and enumerate redirected
readers via `SCardListReaders`. If no readers are found (redirection not active
or no card reader on the client), it logs Event ID 1001 and exits cleanly.

### Card Removal Detection

`SCardGetStatusChange` blocks with a 10-second poll timeout, waking only on
state changes or to verify the session is still active. When it detects
`SCARD_STATE_CHANGED` with the previous state `SCARD_STATE_PRESENT` and the new
state `SCARD_STATE_EMPTY`, it calls:

```text
rundll32.exe user32.dll,LockWorkStation
```

### Hot-Plug Readers

The PnP pseudo-reader (`\\?PnP?\Notification`) is included in the monitoring
array so the script detects new readers added after logon (e.g., if redirection
establishes after a brief delay).

### Session End

When the user logs off, the session host terminates all user processes including
the monitoring script. No explicit cleanup is required.

## Logging

All events are written to the Windows Application event log under source
`SmartCardLockMonitor`.

| Event ID | Description |
| --- | --- |
| 1000 | Script started, readers found |
| 1001 | Script started, no readers found (exiting) |
| 1010 | New reader detected via hot-plug |
| 1020 | Smart card inserted |
| 1030 | Smart card removed - lock initiated |
| 1031 | Lock command sent |
| 1090 | Script exiting (session end or PC/SC error) |
| 1099 | Unhandled error |

```powershell
# View recent events
Get-WinEvent -ProviderName SmartCardLockMonitor -MaxEvents 20 |
    Select-Object TimeCreated, Id, Message | Format-List
```

## Troubleshooting

**Monitor script not starting at logon**

```powershell
Get-ScheduledTask -TaskName 'SmartCard-Lock-Monitor' | Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName 'SmartCard-Lock-Monitor' | Select-Object LastRunTime, LastTaskResult
```

**Lock not firing on card removal**

```powershell
# Confirm redirection is active - should list at least one reader
$ctx = [IntPtr]::Zero; Add-Type -TypeDefinition (Get-Content "$env:ProgramData\FederalAVD\SmartCardLock\Watch-SmartCardRemoval.ps1" -Raw | Select-String -Pattern '(?s)Add-Type @''(.+?)''@' | ForEach-Object { $_.Matches[0].Groups[1].Value })
```

Or simply open **Device Manager** on the session host and look under **Smart card
readers** — a redirected reader should appear there when the client has a card
reader connected.

**Event log source missing**

```powershell
[System.Diagnostics.EventLog]::CreateEventSource('SmartCardLockMonitor', 'Application')
```

**Verify smart card redirection is enabled**

In Azure Portal: Host Pool > Properties > RDP Properties > Device redirection.
Confirm `redirect smartcards:i:1` is present, or add it to the Custom RDP
Properties field.

## Removal

```powershell
Unregister-ScheduledTask -TaskName 'SmartCard-Lock-Monitor' -Confirm:$false
Remove-Item -Path 'C:\ProgramData\FederalAVD\SmartCardLock' -Recurse -Force
[System.Diagnostics.EventLog]::Delete('Application')  # Only if removing all sources
```

## Functions (Watch-SmartCardRemoval.ps1)

| Function | Description |
| --- | --- |
| `Write-SCardEvent` | Writes an event to the Application log under SmartCardLockMonitor source |
| `Get-SCardReaderList` | Calls `SCardListReaders` and parses the multi-string result |
| `New-ReaderState` | Creates a `WinSCard+SCARD_READERSTATE` struct for use with `SCardGetStatusChange` |

## References

- [RDP Smart Card Redirection](https://learn.microsoft.com/en-us/azure/virtual-desktop/redirection-configure-smart-cards)
- [Entra ID SSO for AVD](https://learn.microsoft.com/en-us/azure/virtual-desktop/configure-single-sign-on)
- [SCardGetStatusChange API](https://learn.microsoft.com/en-us/windows/win32/api/winscard/nf-winscard-scardgetstatuschangew)
- [Smart Card Removal Policy (SCRemoveOption)](https://learn.microsoft.com/en-us/windows/security/identity-protection/smart-cards/smart-card-group-policy-and-registry-settings#interactive-logon-smart-card-removal-behavior)
