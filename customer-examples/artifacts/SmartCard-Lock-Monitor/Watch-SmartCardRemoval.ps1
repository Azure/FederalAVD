#Requires -Version 5.1
<#
.SYNOPSIS
    Monitors smart card state via PC/SC redirection and locks the workstation when
    the card is removed from the remote client.

.DESCRIPTION
    This script runs at user logon (via scheduled task) and uses the WinSCard
    (PC/SC) API to monitor redirected smart card state. When a smart card is
    removed on the client PC, the PC/SC virtual channel (TSSCARD) propagates the
    state change to this session host process, which then locks the workstation.

    Prerequisites:
      - Smart card redirection must be enabled on the host pool
        (RDP property: redirect smartcards:i:1)
      - The AVD client must allow smart card redirection
      - The user must have a physical smart card inserted at logon time

    If no smart card readers are available (e.g., redirection is not configured or
    no card reader is connected on the client), the script exits cleanly without
    any action or error.

    This script is intended to run HIDDEN via scheduled task and must not be run
    interactively during an image build.

.NOTES
    Deployed by: Install-SmartCardLockMonitor.ps1
    Event source: SmartCardLockMonitor
    Event log:    Application
    Event IDs:
      1000 - Script started, readers found
      1001 - Script started, no readers found (exiting)
      1010 - Smart card reader added (hot-plug)
      1020 - Smart card inserted
      1030 - Smart card removed - locking workstation
      1031 - Lock command sent
      1090 - Script exiting (session ending or SCard error)
      1099 - Unhandled error
#>

#region P/Invoke -- WinSCard API
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class WinSCard {

    // Scope constants
    public const uint SCARD_SCOPE_USER   = 0;
    public const uint SCARD_SCOPE_SYSTEM = 2;

    // State flag constants
    public const uint SCARD_STATE_UNAWARE     = 0x0000;
    public const uint SCARD_STATE_IGNORE      = 0x0001;
    public const uint SCARD_STATE_CHANGED     = 0x0002;
    public const uint SCARD_STATE_UNKNOWN     = 0x0004;
    public const uint SCARD_STATE_UNAVAILABLE = 0x0008;
    public const uint SCARD_STATE_EMPTY       = 0x0010;
    public const uint SCARD_STATE_PRESENT     = 0x0020;
    public const uint SCARD_STATE_ATRMATCH    = 0x0040;
    public const uint SCARD_STATE_EXCLUSIVE   = 0x0080;
    public const uint SCARD_STATE_INUSE       = 0x0100;
    public const uint SCARD_STATE_MUTE        = 0x0200;
    public const uint SCARD_STATE_UNPOWERED   = 0x0400;

    // Return codes
    public const int  SCARD_S_SUCCESS         = 0x00000000;
    public const uint SCARD_E_NO_READERS_AVAILABLE = 0x8010002E;
    public const uint SCARD_E_TIMEOUT         = 0x8010000A;
    public const uint SCARD_E_SERVICE_STOPPED = 0x8010001E;
    public const uint SCARD_E_NO_SERVICE      = 0x8010001D;

    // Timeout: 10 seconds between poll cycles so the loop wakes periodically
    public const uint POLL_TIMEOUT_MS = 10000;

    // Pseudo-reader that notifies on reader add/remove
    public const string PNP_READER = @"\\?PnP?\Notification";

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SCARD_READERSTATE {
        [MarshalAs(UnmanagedType.LPWStr)]
        public string  szReader;
        public IntPtr  pvUserData;
        public uint    dwCurrentState;
        public uint    dwEventState;
        public uint    cbAtr;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 36)]
        public byte[]  rgbAtr;
    }

    [DllImport("winscard.dll", CharSet = CharSet.Unicode)]
    public static extern int SCardEstablishContext(
        uint    dwScope,
        IntPtr  pvReserved1,
        IntPtr  pvReserved2,
        out IntPtr phContext);

    [DllImport("winscard.dll", CharSet = CharSet.Unicode)]
    public static extern int SCardReleaseContext(IntPtr hContext);

    [DllImport("winscard.dll", CharSet = CharSet.Unicode)]
    public static extern int SCardListReaders(
        IntPtr  hContext,
        string  mszGroups,
        IntPtr  mszReaders,
        ref uint pcchReaders);

    [DllImport("winscard.dll", CharSet = CharSet.Unicode)]
    public static extern int SCardGetStatusChange(
        IntPtr hContext,
        uint   dwTimeout,
        [In, Out] SCARD_READERSTATE[] rgReaderStates,
        uint   cReaders);
}
'@
#endregion

#region Constants and helpers
$EventSource = 'SmartCardLockMonitor'
$EventLog    = 'Application'

Function Write-SCardEvent {
    Param(
        [int]    $EventId,
        [string] $Message,
        [System.Diagnostics.EventLogEntryType] $EntryType = [System.Diagnostics.EventLogEntryType]::Information
    )
    try {
        Write-EventLog -LogName $EventLog -Source $EventSource `
            -EventId $EventId -EntryType $EntryType -Message $Message `
            -ErrorAction SilentlyContinue
    } catch {}
}

Function Get-SCardReaderList {
    Param([IntPtr]$Context)
    $len = [uint32]0
    $null = [WinSCard]::SCardListReaders($Context, $null, [IntPtr]::Zero, [ref]$len)
    if ($len -le 2) { return @() }  # empty multi-string is just two null chars
    $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($len * 2)
    try {
        $ret = [WinSCard]::SCardListReaders($Context, $null, $buf, [ref]$len)
        if ($ret -ne [WinSCard]::SCARD_S_SUCCESS) { return @() }
        $raw = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($buf, $len)
        # Multi-string is null-delimited; split and filter empties
        return ($raw.Split([char]0) | Where-Object { $_ -ne '' })
    } finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
    }
}

Function New-ReaderState {
    Param([string]$ReaderName, [uint32]$CurrentState = [WinSCard]::SCARD_STATE_UNAWARE)
    $s = New-Object WinSCard+SCARD_READERSTATE
    $s.szReader      = $ReaderName
    $s.dwCurrentState = $CurrentState
    $s.dwEventState  = 0
    $s.rgbAtr        = New-Object byte[] 36
    return $s
}
#endregion

#region Main monitor loop
$ctx = [IntPtr]::Zero
try {
    # Establish PC/SC context in user scope (follows the current user session)
    $ret = [WinSCard]::SCardEstablishContext(
        [WinSCard]::SCARD_SCOPE_USER, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$ctx)

    if ($ret -ne [WinSCard]::SCARD_S_SUCCESS) {
        Write-SCardEvent -EventId 1090 -EntryType Warning `
            -Message ("SCardEstablishContext failed (0x{0:X8}). Smart card service may not be running. Exiting." -f [uint32]$ret)
        exit 0
    }

    # Enumerate currently redirected readers
    $readers = Get-SCardReaderList -Context $ctx

    if ($readers.Count -eq 0) {
        Write-SCardEvent -EventId 1001 `
            -Message ("No smart card readers found via PC/SC redirection. " +
                      "Ensure 'redirect smartcards:i:1' is set on the host pool and " +
                      "the AVD client has a smart card reader available. Exiting.")
        exit 0
    }

    Write-SCardEvent -EventId 1000 `
        -Message ("Smart card lock monitor started. Monitoring readers: " + ($readers -join ', '))

    # Build state array -- include the PnP pseudo-reader to detect new readers being added
    $states = [System.Collections.Generic.List[WinSCard+SCARD_READERSTATE]]::new()
    foreach ($r in $readers) { $states.Add((New-ReaderState -ReaderName $r)) }
    $states.Add((New-ReaderState -ReaderName ([WinSCard]::PNP_READER)))  # hot-plug watcher

    while ($true) {
        $stateArray = $states.ToArray()
        $ret = [WinSCard]::SCardGetStatusChange($ctx, [WinSCard]::POLL_TIMEOUT_MS, $stateArray, $stateArray.Count)

        # Service stopped or context invalid - session is ending
        if ($ret -eq [int][WinSCard]::SCARD_E_SERVICE_STOPPED -or
            $ret -eq [int][WinSCard]::SCARD_E_NO_SERVICE) {
            Write-SCardEvent -EventId 1090 -Message 'PC/SC service stopped. Session ending. Exiting.'
            break
        }

        # Timeout is normal - just loop again for liveness
        if ($ret -eq [int][WinSCard]::SCARD_E_TIMEOUT) { continue }

        if ($ret -ne [WinSCard]::SCARD_S_SUCCESS) {
            Write-SCardEvent -EventId 1090 -EntryType Warning `
                -Message ("SCardGetStatusChange returned 0x{0:X8}. Exiting." -f [uint32]$ret)
            break
        }

        # Process each reader state change
        $needRebuild = $false
        for ($i = 0; $i -lt $stateArray.Count; $i++) {
            $s = $stateArray[$i]
            if (-not ($s.dwEventState -band [WinSCard]::SCARD_STATE_CHANGED)) { continue }

            # ---- PnP reader: a new reader was added ----
            if ($s.szReader -eq [WinSCard]::PNP_READER) {
                $newReaders = Get-SCardReaderList -Context $ctx
                $current    = $states | Where-Object { $_.szReader -ne [WinSCard]::PNP_READER } |
                              Select-Object -ExpandProperty szReader
                $added = $newReaders | Where-Object { $_ -notin $current }
                if ($added) {
                    Write-SCardEvent -EventId 1010 -Message ("New reader(s) detected via redirection: " + ($added -join ', '))
                    foreach ($a in $added) { $states.Add((New-ReaderState -ReaderName $a)) }
                }
                $needRebuild = $true
            } else {
                $wasPresent = $s.dwCurrentState -band [WinSCard]::SCARD_STATE_PRESENT
                $nowPresent = $s.dwEventState   -band [WinSCard]::SCARD_STATE_PRESENT
                $nowEmpty   = $s.dwEventState   -band [WinSCard]::SCARD_STATE_EMPTY

                if (-not $wasPresent -and $nowPresent) {
                    Write-SCardEvent -EventId 1020 `
                        -Message ("Smart card inserted in reader: $($s.szReader)")
                }

                if ($wasPresent -and $nowEmpty) {
                    Write-SCardEvent -EventId 1030 `
                        -Message ("Smart card removed from reader: $($s.szReader). Locking workstation.")
                    # Lock using rundll32 user32.dll LockWorkStation - works in user session context
                    $null = Start-Process -FilePath 'rundll32.exe' `
                        -ArgumentList 'user32.dll,LockWorkStation' -WindowStyle Hidden
                    Write-SCardEvent -EventId 1031 -Message 'Lock command sent.'
                }
            }

            # Acknowledge the event by moving EventState -> CurrentState (low 16 bits only)
            $updated = New-ReaderState -ReaderName $s.szReader -CurrentState ($s.dwEventState -band 0xFFFF)
            $states[$i] = $updated
        }

        if ($needRebuild) {
            # Re-sync PnP entry current state
            $pnpIdx = ($states | Select-Object -ExpandProperty szReader).IndexOf([WinSCard]::PNP_READER)
            if ($pnpIdx -ge 0) {
                $pnpUpdated = New-ReaderState -ReaderName ([WinSCard]::PNP_READER) `
                    -CurrentState ($stateArray[$pnpIdx].dwEventState -band 0xFFFF)
                $states[$pnpIdx] = $pnpUpdated
            }
        }
    }
} catch {
    Write-SCardEvent -EventId 1099 -EntryType Error `
        -Message ("Unhandled error in Watch-SmartCardRemoval.ps1: $($_.Exception.Message)")
} finally {
    if ($ctx -ne [IntPtr]::Zero) {
        $null = [WinSCard]::SCardReleaseContext($ctx)
    }
}
#endregion
