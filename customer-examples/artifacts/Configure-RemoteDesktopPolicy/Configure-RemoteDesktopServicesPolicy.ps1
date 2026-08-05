[CmdletBinding(SupportsShouldProcess = $true)]
param (
    # Maximum idle time before session action (milliseconds). Default: 10800000 = 3 hours.
    # When EndSessionOnLimit = 0 (default), expiry disconnects the session.
    # When EndSessionOnLimit = 1, expiry logs off the session.
    [string]$MaxIdleTime = '10800000',

    # Maximum time a disconnected session persists before being logged off (milliseconds).
    # Default: 10800000 = 3 hours. Always results in logoff regardless of EndSessionOnLimit.
    [string]$MaxDisconnectionTime = '10800000',

    # Controls whether idle/active timeout disconnects or ends (logs off) the session.
    # 0 - Disconnect on idle timeout; logoff only when MaxDisconnectionTime fires.
    # 1 - Log off immediately when MaxIdleTime expires.
    # Leave unset (default) to not write this value; OS default is 0 (disconnect on timeout).
    # Maps to GP: "End session when time limits are reached" (registry: fResetBroken).
    [ValidateSet('0', '1')]
    [string]$EndSessionOnLimit,

    # Controls whether locking the remote session disconnects the RDP client or shows the
    # remote lock screen. Only applies when Entra ID SSO is enabled on the host pool.
    # '1' = disconnect on lock (default when Not Configured -- recommended for Entra ID SSO)
    # '0' = show remote lock screen on lock (both MaxIdleTime and MaxDisconnectionTime apply)
    # Leave unset (default) to not write this value and preserve the OS / existing policy default.
    # Maps to GP: "Disconnect remote session on lock for Microsoft identity platform authentication"
    # Registry: fDisconnectOnLockMicrosoftIdentity
    # Reference: https://learn.microsoft.com/azure/virtual-desktop/configure-session-lock-behavior
    [ValidateSet('0', '1')]
    [string]$DisconnectOnLockMsIdentity,

    [switch]$EnableRemoteApp
)

#region Functions

Function Write-Log {
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet("Info", "Warning", "Error")]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )
    
    $Content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if (-not $env:SUPPRESS_FILELOG) {
        Add-Content $Script:Log $Content -ErrorAction SilentlyContinue
    }
    Switch ($Category) {
        'Info' { Write-Host $Content }
        'Error' { Write-Error $Content -ErrorAction Continue }
        'Warning' { Write-Warning $Content }
    }
}

function New-Log {
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path
    )

    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    $date = Get-Date -UFormat "%Y-%m-%d %H-%M-%S"
    Set-Variable logFile -Scope Script
    $script:logFile = "$Script:Name-$date.log"

    if ((Test-Path $path ) -eq $false) {
        $null = New-Item -Path $path -type directory
    }

    $script:Log = Join-Path $path $logfile

    Add-Content $script:Log "Date`t`t`tCategory`t`tDetails"
}

#endregion Functions

#region RegistryPol -- PReg direct writer (no LGPO.exe required)
<#
.SYNOPSIS
    Registry.pol (PReg) direct writer  -  no LGPO.exe, no COM objects required.

.DESCRIPTION
    Provides a queue-based interface for writing registry-based group policy values
    directly into the local machine Registry.pol files (Machine and/or User scope).
    Conforms to MS-GPREG (Group Policy: Registry Extension Encoding) v30.0.

    Dot-source this file in your artifact script, queue entries with
    Set-PolicyRegistryValue / Remove-PolicyRegistryValue / Clear-PolicyRegistryKeyValues,
    then call Invoke-PolicyUpdate to flush the queue to Registry.pol and run gpupdate.

    Usage:
        . "$PSScriptRoot\..\RegistryPol\RegistryPol.ps1"

        Set-PolicyRegistryValue -Scope Computer `
            -RegistryKeyPath 'Software\Policies\MyApp' `
            -RegistryValue 'EnableFeature' -RegistryType DWORD -RegistryData 1

        Remove-PolicyRegistryValue -Scope Computer `
            -RegistryKeyPath 'Software\Policies\MyApp' `
            -RegistryValue 'ObsoleteValue'

        Clear-PolicyRegistryKeyValues -Scope Computer `
            -RegistryKeyPath 'Software\Policies\MyApp\List'

        Invoke-PolicyUpdate

.NOTES
    MS-GPREG binary format:
        Header  : "PReg" (4 ASCII bytes) + version 1 (uint32 LE) = 8 bytes
        Entry   : [<KeyPath>\0;<ValueName>\0;<Type4B>;<Size4B>;<Data>]
                  '[', ']', ';' are UTF-16LE single characters.
                  KeyPath and ValueName are UTF-16LE null-terminated strings.
        Types   : 1=REG_SZ  2=REG_EXPAND_SZ  4=REG_DWORD  7=REG_MULTI_SZ
        HKLM / HKCU MUST NOT appear in KeyPath per spec.

    Special value names understood by the Windows GP client:
        **Del.<valuename>   -  removes one named value from the live registry key
        **DelVals.          -  removes all values from the live registry key

    Registry.pol locations:
        Machine : %SystemRoot%\System32\GroupPolicy\Machine\Registry.pol
        User    : %SystemRoot%\System32\GroupPolicy\User\Registry.pol
#>

#region PReg engine (internal)

$script:_PRegEnc = [System.Text.Encoding]::Unicode  # UTF-16LE throughout

function Read-PRegFile {
    <#  Internal. Reads a Registry.pol file; returns List[hashtable] of entries.  #>
    param ([string]$Path)

    $list = [System.Collections.Generic.List[hashtable]]::new()
    if (-not (Test-Path -LiteralPath $Path)) { return , $list }

    $raw = [IO.File]::ReadAllBytes($Path)
    if ($raw.Length -lt 8) { return , $list }

    $sig = [System.Text.Encoding]::ASCII.GetString($raw, 0, 4)
    $ver = [BitConverter]::ToUInt32($raw, 4)
    if ($sig -ne 'PReg' -or $ver -ne 1) {
        Write-Warning "RegistryPol: '$Path' has unexpected header (sig='$sig' ver=$ver). Existing entries discarded."
        return , $list
    }

    $pos = 8
    while ($pos -lt $raw.Length) {
        if ($pos + 1 -ge $raw.Length) { break }
        # Opening '[' in UTF-16LE = 0x5B 0x00
        if ($raw[$pos] -ne 0x5B -or $raw[$pos + 1] -ne 0x00) { $pos++; continue }
        $pos += 2

        # Key path (null-terminated UTF-16LE)
        $start = $pos
        while ($pos + 1 -lt $raw.Length -and -not ($raw[$pos] -eq 0 -and $raw[$pos + 1] -eq 0)) { $pos += 2 }
        $key = $script:_PRegEnc.GetString($raw, $start, $pos - $start)
        $pos += 2   # skip null terminator
        $pos += 2   # skip ';'

        # Value name (null-terminated UTF-16LE)
        $start = $pos
        while ($pos + 1 -lt $raw.Length -and -not ($raw[$pos] -eq 0 -and $raw[$pos + 1] -eq 0)) { $pos += 2 }
        $name = $script:_PRegEnc.GetString($raw, $start, $pos - $start)
        $pos += 2   # skip null terminator
        $pos += 2   # skip ';'

        # Type (uint32 LE) + ';'
        $type = [BitConverter]::ToUInt32($raw, $pos); $pos += 4; $pos += 2

        # Size (uint32 LE) + ';'
        $size = [BitConverter]::ToUInt32($raw, $pos); $pos += 4; $pos += 2

        # Data bytes  -  guard: PS a..b with a>b gives a DESCENDING slice, not empty
        $data = if ($size -gt 0) { $raw[$pos..($pos + $size - 1)] } else { [byte[]]@() }
        $pos += [int]$size
        $pos += 2   # skip ']'

        $list.Add(@{ Key = $key; Name = $name; Type = $type; Size = $size; Data = $data })
    }
    return , $list
}

function Write-PRegFile {
    <#  Internal. Writes a Registry.pol using safe tmp -> verify -> bak -> promote.  #>
    param (
        [string]$Path,
        [System.Collections.Generic.List[hashtable]]$Entries
    )

    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

    $ms = [IO.MemoryStream]::new()
    $w = [IO.BinaryWriter]::new($ms)

    $w.Write([System.Text.Encoding]::ASCII.GetBytes('PReg'))  # Signature
    $w.Write([uint32]1)                                         # Version

    $bo = [byte[]](0x5B, 0x00)   # '['
    $bc = [byte[]](0x5D, 0x00)   # ']'
    $sc = [byte[]](0x3B, 0x00)   # ';'
    $nt = [byte[]](0x00, 0x00)   # null terminator

    foreach ($e in $Entries) {
        $w.Write($bo)
        $w.Write($script:_PRegEnc.GetBytes($e.Key)); $w.Write($nt); $w.Write($sc)
        $w.Write($script:_PRegEnc.GetBytes($e.Name)); $w.Write($nt); $w.Write($sc)
        $w.Write([uint32]$e.Type); $w.Write($sc)
        $w.Write([uint32]$e.Size); $w.Write($sc)
        # Guard: BinaryWriter.Write([byte[]]@()) resolves to the wrong overload and throws
        if ($null -ne $e.Data -and $e.Data.Length -gt 0) { $w.Write([byte[]]$e.Data) }
        $w.Write($bc)
    }
    $w.Flush()
    $bytes = $ms.ToArray()
    $w.Dispose(); $ms.Dispose()

    $tmp = "$Path.tmp"
    [IO.File]::WriteAllBytes($tmp, $bytes)
    $written = (Get-Item -LiteralPath $tmp).Length
    if ($written -ne $bytes.Length) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "RegistryPol: write verification failed for '$Path' (expected $($bytes.Length) bytes, got $written)."
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Set-PRegEntry {
    <#  Internal. Upserts one entry in a List[hashtable] by key+name (case-insensitive).  #>
    param (
        [System.Collections.Generic.List[hashtable]]$Entries,
        [string]$Key,
        [string]$Name,
        [uint32]$Type,
        [byte[]]$Data
    )
    $old = @($Entries | Where-Object { $_.Key -ieq $Key -and $_.Name -ieq $Name })
    foreach ($e in $old) { $Entries.Remove($e) | Out-Null }
    $Entries.Add(@{ Key = $Key; Name = $Name; Type = $Type; Size = [uint32]$Data.Length; Data = $Data })
}

#endregion

#region Data conversion helpers (internal)

function ConvertTo-PRegDWord {
    param ([uint32]$Value)
    [BitConverter]::GetBytes($Value)
}

function ConvertTo-PRegSZ {
    param ([string]$Value)
    # REG_SZ: UTF-16LE with null terminator
    $script:_PRegEnc.GetBytes($Value + [char]0)
}

function ConvertTo-PRegMultiSZ {
    param ([string[]]$Values)
    # REG_MULTI_SZ: null-separated strings + double-null terminator
    if ($null -eq $Values -or $Values.Length -eq 0) { return [byte[]](0x00, 0x00) }
    $script:_PRegEnc.GetBytes(($Values -join [char]0) + [char]0 + [char]0)
}

#endregion

#region Public API

# Queue is initialized on dot-source; idempotent if dot-sourced more than once
if (-not (Get-Variable -Name '_PolQueue' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:_PolQueue = [System.Collections.Generic.List[hashtable]]::new()
}

function Set-PolicyRegistryValue {
    <#
    .SYNOPSIS
        Queues a registry value to be written to the local machine's Registry.pol file.

    .DESCRIPTION
        Accumulates entries in an internal queue. Call Invoke-PolicyUpdate to flush the
        queue to Registry.pol and apply the settings via gpupdate.

    .PARAMETER Scope
        Computer  -  writes to Machine\Registry.pol (applied at system startup/refresh).
        User     -  writes to User\Registry.pol (applied at user logon/refresh).

    .PARAMETER RegistryKeyPath
        Registry key path relative to the hive root. HKLM:\, HKCU:\,
        HKEY_LOCAL_MACHINE:\, and HKEY_CURRENT_USER:\ prefixes are stripped automatically.

    .PARAMETER RegistryValue
        Registry value name.

    .PARAMETER RegistryType
        DWORD, String (alias SZ), ExpandString (alias ExpandSZ), MultiString (alias MultiSZ).

    .PARAMETER RegistryData
        Value data as a string. DWORD values are parsed as [uint32].
        MultiString values use pipe '|' as the separator between strings.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Computer', 'User')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$RegistryKeyPath,

        [Parameter(Mandatory)]
        [string]$RegistryValue,

        [Parameter(Mandatory)]
        [ValidateSet('DWORD', 'String', 'SZ', 'ExpandString', 'ExpandSZ', 'MultiString', 'MultiSZ')]
        [string]$RegistryType,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$RegistryData
    )

    $relPath = Get-RelativePolicyKeyPath $RegistryKeyPath

    $typeCode = switch ($RegistryType.ToUpper()) {
        'DWORD' { 4 }
        'STRING' { 1 }
        'SZ' { 1 }
        'EXPANDSTRING' { 2 }
        'EXPANDSZ' { 2 }
        'MULTISTRING' { 7 }
        'MULTISZ' { 7 }
        default { 1 }
    }

    $dataBytes = switch ($typeCode) {
        4 { ConvertTo-PRegDWord ([uint32]$RegistryData) }
        7 { ConvertTo-PRegMultiSZ ($RegistryData -split '\|') }
        default { ConvertTo-PRegSZ $RegistryData }
    }

    $script:_PolQueue.Add(@{
            Scope = $Scope
            Key   = $relPath
            Name  = $RegistryValue
            Type  = [uint32]$typeCode
            Size  = [uint32]$dataBytes.Length
            Data  = $dataBytes
        })
    Write-Verbose "RegistryPol: Queued SET [$Scope] $relPath\$RegistryValue ($RegistryType = $RegistryData)"
}

function Remove-PolicyRegistryValue {
    <#
    .SYNOPSIS
        Queues deletion of a specific registry value from policy.

    .DESCRIPTION
        Writes a **Del.<valuename> marker entry to Registry.pol. When the Windows Group
        Policy client processes the pol file, it removes that value from the live registry.

    .PARAMETER Scope
        Computer or User.

    .PARAMETER RegistryKeyPath
        Registry key path (HIVE: prefix stripped automatically).

    .PARAMETER RegistryValue
        Name of the registry value to delete.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Computer', 'User')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$RegistryKeyPath,

        [Parameter(Mandatory)]
        [string]$RegistryValue
    )

    $relPath = Get-RelativePolicyKeyPath $RegistryKeyPath
    $delBytes = ConvertTo-PRegSZ ' '   # MS-GPREG: **Del. value data is a single space
    $script:_PolQueue.Add(@{
            Scope = $Scope
            Key   = $relPath
            Name  = "**Del.$RegistryValue"
            Type  = [uint32]1
            Size  = [uint32]$delBytes.Length
            Data  = $delBytes
        })
    Write-Verbose "RegistryPol: Queued REMOVE [$Scope] $relPath\$RegistryValue"
}

function Clear-PolicyRegistryKeyValues {
    <#
    .SYNOPSIS
        Queues deletion of all registry values in a key (equivalent to LGPO's DELETEALLVALUES).

    .DESCRIPTION
        Writes a **DelVals. marker entry to Registry.pol. When the Windows Group Policy client
        processes the pol file, it removes every value from the live registry key.

    .PARAMETER Scope
        Computer or User.

    .PARAMETER RegistryKeyPath
        Registry key path (HIVE: prefix stripped automatically).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Computer', 'User')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$RegistryKeyPath
    )

    $relPath = Get-RelativePolicyKeyPath $RegistryKeyPath
    $delBytes = ConvertTo-PRegSZ ' '
    $script:_PolQueue.Add(@{
            Scope = $Scope
            Key   = $relPath
            Name  = '**DelVals.'
            Type  = [uint32]1
            Size  = [uint32]$delBytes.Length
            Data  = $delBytes
        })
    Write-Verbose "RegistryPol: Queued CLEAR ALL VALUES [$Scope] $relPath"
}

function Invoke-PolicyUpdate {
    <#
    .SYNOPSIS
        Flushes the policy queue to Registry.pol and updates gpt.ini.

    .DESCRIPTION
        For each scope that has queued entries: reads the existing Registry.pol,
        merges all queued changes (later entries overwrite earlier ones for the same
        key\valueName), and writes the result using a safe tmp->verify->promote pattern.
        Updates gpt.ini so the Group Policy client on deployed machines knows to
        invoke the Registry CSE. Both scope extension-name lines are preserved on
        every call  -  a call that only updates one scope will not drop the other
        scope's line from a prior call.
        gpupdate is intentionally not called: these scripts run during image build
        where policy does not need to be live in the build OS. On deployed machines
        the GP client processes Registry.pol automatically at startup/logon.
    #>
    [CmdletBinding()]
    param ()

    if ($script:_PolQueue.Count -eq 0) {
        Write-Verbose 'RegistryPol: Queue is empty  -  nothing to apply.'
        return
    }

    $gpBase = "$env:SystemRoot\System32\GroupPolicy"
    $machineQ = @($script:_PolQueue | Where-Object { $_.Scope -eq 'Computer' })
    $userQ = @($script:_PolQueue | Where-Object { $_.Scope -eq 'User' })
    $machineUpdated = $false
    $userUpdated = $false

    foreach ($scope in @(
            @{ Queue = $machineQ; PolPath = "$gpBase\Machine\Registry.pol"; IsUser = $false },
            @{ Queue = $userQ; PolPath = "$gpBase\User\Registry.pol"; IsUser = $true }
        )) {
        if ($scope.Queue.Count -eq 0) { continue }

        $polPath = $scope.PolPath
        Write-Verbose "RegistryPol: Loading '$polPath'."
        $existing = Read-PRegFile -Path $polPath

        foreach ($q in $scope.Queue) {
            Set-PRegEntry -Entries $existing -Key $q.Key -Name $q.Name -Type $q.Type -Data $q.Data
        }

        Write-Verbose "RegistryPol: Writing $($existing.Count) entries to '$polPath'."
        Write-PRegFile -Path $polPath -Entries $existing
        if ($scope.IsUser) { $userUpdated = $true } else { $machineUpdated = $true }
    }

    $script:_PolQueue.Clear()

    # Update gpt.ini so the GP client on deployed machines knows the local GPO has content.
    # Both scope lines are preserved on every call: if only one scope was updated here,
    # the other scope's existing line is read back and re-written unchanged.
    try {
        $gptPath = "$gpBase\gpt.ini"
        $regCse = '{35378EAC-683F-11D2-A89A-00C04FBBCFA2}'
        $machineAT = '{D02B1F72-3407-48AE-BA88-E8213C6761F1}'
        $userAT = '{D02B1F73-3407-48AE-BA88-E8213C6761F1}'

        $existing_ini = if (Test-Path -LiteralPath $gptPath) { Get-Content $gptPath -Raw } else { '' }

        $machineVer = [uint16]1
        $userVer = [uint16]1
        if ($existing_ini -match 'Version\s*=\s*(\d+)') {
            $cur = [uint32]$matches[1]
            $machineVer = [uint16]($cur -band 0xFFFF)
            $userVer = [uint16](($cur -shr 16) -band 0xFFFF)
        }
        if ($machineUpdated) { $machineVer++ }
        if ($userUpdated) { $userVer++ }
        $version = ([uint32]$userVer -shl 16) -bor [uint32]$machineVer

        $machineExt = "[$regCse$machineAT]"
        $userExt = "[$regCse$userAT]"

        $finalMachineExt = if ($machineUpdated) {
            if ($existing_ini -match 'gPCMachineExtensionNames\s*=\s*(.+)') {
                $ev = $matches[1].Trim()
                if ($ev -notlike "*$regCse*") { $ev + $machineExt } else { $ev }
            }
            else { $machineExt }
        }
        elseif ($existing_ini -match 'gPCMachineExtensionNames\s*=\s*(.+)') {
            $matches[1].Trim()
        }
        else { '' }
  
        $finalUserExt = if ($userUpdated) {
            if ($existing_ini -match 'gPCUserExtensionNames\s*=\s*(.+)') {
                $ev = $matches[1].Trim()
                if ($ev -notlike "*$regCse*") { $ev + $userExt } else { $ev }
            }
            else { $userExt }
        }
        elseif ($existing_ini -match 'gPCUserExtensionNames\s*=\s*(.+)') {
            $matches[1].Trim()
        }
        else { '' }

        $gptContent = "[General]`r`n"
        if ($finalMachineExt) { $gptContent += "gPCMachineExtensionNames=$finalMachineExt`r`n" }
        if ($finalUserExt) { $gptContent += "gPCUserExtensionNames=$finalUserExt`r`n" }
        $gptContent += "Version=$version`r`n"
        [IO.File]::WriteAllText($gptPath, $gptContent, [System.Text.Encoding]::ASCII)
        Write-Verbose "RegistryPol: gpt.ini written (Version=$version machine=$machineVer user=$userVer)"
    }
    catch {
        Write-Warning "RegistryPol: gpt.ini write failed: $_"
    }
}

#endregion

#region Internal helpers

function Get-RelativePolicyKeyPath {
    <#  Internal. Strips any HIVE: prefix so KeyPath is relative as required by MS-GPREG.  #>
    param ([string]$Path)
    foreach ($prefix in @(
            'HKEY_LOCAL_MACHINE:\', 'HKEY_CURRENT_USER:\',
            'HKEY_LOCAL_MACHINE:', 'HKEY_CURRENT_USER:',
            'HKLM:\', 'HKCU:\',
            'HKLM:', 'HKCU:'
        )) {
        if ($Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $Path.Substring($prefix.Length).TrimStart('\')
        }
    }
    return $Path
}

#endregion

#endregion RegistryPol

#region Initialization
[int]$MaxIdleTime = $MaxIdleTime
[int]$MaxDisconnectionTime = $MaxDisconnectionTime
[string]$Script:Name = "Configure-RemoteDesktopServicesPolicy"
New-Log -Path (Join-Path -Path "$env:SystemRoot\Logs" -ChildPath 'Configuration')
$ErrorActionPreference = 'Stop'
Write-Log -category Info -message "Starting '$PSCommandPath'."
Write-Log -Category Info -Message "Parameters: MaxIdleTime='$MaxIdleTime', MaxDisconnectionTime='$MaxDisconnectionTime', EndSessionOnLimit='$EndSessionOnLimit', DisconnectOnLockMsIdentity='$DisconnectOnLockMsIdentity', EnableRemoteApp='$EnableRemoteApp'."
#endregion

# =============================================================================
# Remote Desktop Services Session Timeout Policy
# =============================================================================
# References:
#   GP path : Computer Configuration -> Administrative Templates -> Windows Components
#             -> Remote Desktop Services -> Remote Desktop Session Host -> Session Time Limits
#   MS docs : https://learn.microsoft.com/windows/client-management/mdm/policy-csp-remotedesktopservices
#   ADMX    : https://admx.help/?Category=Windows_10_2016&Policy=Microsoft.Policies.TerminalServer::TS_SESSIONS_Idle_Limit_1
#
# Registry key: HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services
#
# MaxIdleTime (DWORD, milliseconds)
#   GP name : "Set time limit for active but idle Remote Desktop Services sessions"
#   Effect  : When an active session is idle for this duration, the action depends on
#             fResetBroken (EndSessionOnLimit). 0 = no limit.
#
# MaxDisconnectionTime (DWORD, milliseconds)
#   GP name : "Set time limit for disconnected sessions"
#   Effect  : When a session has been in the Disconnected state for this duration, it is
#             ALWAYS ended (logged off), regardless of fResetBroken. 0 = no limit.
#
# fResetBroken (DWORD, 0 or 1) -- controlled by EndSessionOnLimit parameter
#   GP name : "End session when time limits are reached"
#   Values  :
#     0 (default) - When MaxIdleTime expires, the session is DISCONNECTED. The FSLogix
#                   profile VHD stays mounted. Compaction does NOT run until
#                   MaxDisconnectionTime expires and the session is fully logged off.
#     1           - When MaxIdleTime expires, the session is ENDED (logged off). The
#                   FSLogix profile VHD is dismounted and compaction runs at logoff.
#
# Session lifecycle with defaults (EndSessionOnLimit = 0, both timeouts = 3 hours):
#
#   Active idle  -> MaxIdleTime (3h)         -> Disconnect  [VHD mounted, compaction: NO ]
#   Disconnected -> MaxDisconnectionTime (3h) -> Logoff     [VHD dismounted, compaction: YES]
#   Total worst-case time before compaction = 6 hours
#
# Session lifecycle with EndSessionOnLimit = 1 (both timeouts = 3 hours):
#
#   Active idle  -> MaxIdleTime (3h)         -> Logoff      [VHD dismounted, compaction: YES]
#   Disconnected -> MaxDisconnectionTime (3h) -> Logoff     [VHD dismounted, compaction: YES]
#   Total worst-case time before compaction = 3 hours (whichever fires first)
#
# =============================================================================
# Entra ID SSO and MachineInactivityTimeout interaction
# =============================================================================
# References:
#   Session lock behavior : https://learn.microsoft.com/azure/virtual-desktop/configure-session-lock-behavior
#   SSO overview          : https://learn.microsoft.com/azure/virtual-desktop/configure-single-sign-on
#
# When Entra ID SSO (Microsoft identity platform authentication) is enabled on the host
# pool, a separate timeout mechanism -- the Windows security policy "Interactive logon:
# Machine inactivity limit" (MachineInactivityTimeout) -- can BYPASS MaxIdleTime entirely.
#
#   Registry : HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\InactivityTimeoutSecs
#   GP path  : Computer Configuration -> Windows Settings -> Security Settings ->
#              Local Policies -> Security Options ->
#              "Interactive logon: Machine inactivity limit"
#   Common value in STIG / CIS baselines: 900 seconds (15 minutes)
#
# MachineInactivityTimeout locks the Windows session after N seconds of no
# keyboard/mouse input. What happens next depends on the session lock behavior:
#
# -----------------------------------------------------------------------------
# DEFAULT: disconnect on lock (Entra ID SSO)
# GP: "Disconnect remote session on lock for Microsoft identity platform authentication"
# Registry: SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\fDisconnectOnLockMicrosoftIdentity
# Default / Not Configured = 1 (Enabled = disconnect on lock)
# -----------------------------------------------------------------------------
# When the session locks (via MachineInactivityTimeout or manually), the Entra ID SSO
# client DISCONNECTS the RDP session instead of showing a remote lock screen.
# The session immediately enters the Disconnected state and MaxDisconnectionTime starts.
# MaxIdleTime never fires because the session was already disconnected.
#
# Effective flow (Entra ID SSO, disconnect on lock, MachineInactivityTimeout = 15 min):
#
#   Active idle  -> MachineInactivityTimeout (15 min) -> Disconnect [VHD mounted, compaction: NO]
#   Disconnected -> MaxDisconnectionTime (3h)         -> Logoff     [VHD dismounted, compaction: YES]
#   Total time before compaction = MachineInactivityTimeout + MaxDisconnectionTime (~3h 15min)
#
# In this scenario MaxIdleTime is irrelevant -- the session disconnects via screen lock
# before MaxIdleTime (3h) would ever fire. Only MaxDisconnectionTime governs when the
# session is logged off and compaction runs.
#
# -----------------------------------------------------------------------------
# ALTERNATE: show remote lock screen instead of disconnect
# Set fDisconnectOnLockMicrosoftIdentity = 0 (Disabled)
# GP: Disable "Disconnect remote session on lock for Microsoft identity platform authentication"
# -----------------------------------------------------------------------------
# In this mode, MachineInactivityTimeout locks the screen but keeps the session Connected.
# The RDS idle timer (MaxIdleTime) continues accumulating from the last user input.
# All three parameters in this script now interact:
#
#   Active idle  -> MachineInactivityTimeout (15 min) -> Screen locks (still Connected)
#   Locked/idle  -> MaxIdleTime (3h from last input)  -> Disconnect or Logoff per fResetBroken
#   Disconnected -> MaxDisconnectionTime (3h)         -> Logoff [VHD dismounted, compaction: YES]
#
# Note: MaxIdleTime counts from last user INPUT, not from when the screen locked. A user
# who returns within 3h resets the idle clock; MachineInactivityTimeout re-locks again
# after the next 15 min of inactivity. MaxDisconnectionTime only starts once the session
# is Disconnected (by MaxIdleTime expiry or the user closing the RDP client window).
# =============================================================================

Write-Log -Category Info -Message "Now Configuring Remote Desktop Services Timeout Settings."
$rdKey = 'Software\Policies\Microsoft\Windows NT\Terminal Services'
Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $rdKey -RegistryValue 'MaxDisconnectionTime' -RegistryType 'DWORD' -RegistryData $MaxDisconnectionTime
Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $rdKey -RegistryValue 'MaxIdleTime' -RegistryType 'DWORD' -RegistryData $MaxIdleTime
If ($PSBoundParameters.ContainsKey('EndSessionOnLimit')) {
    Write-Log -Category Info -Message "Configuring fResetBroken = $EndSessionOnLimit."
    Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $rdKey -RegistryValue 'fResetBroken' -RegistryType 'DWORD' -RegistryData $EndSessionOnLimit
}
If ($PSBoundParameters.ContainsKey('DisconnectOnLockMsIdentity')) {
    Write-Log -Category Info -Message "Configuring fDisconnectOnLockMicrosoftIdentity = $DisconnectOnLockMsIdentity."
    Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $rdKey -RegistryValue 'fDisconnectOnLockMicrosoftIdentity' -RegistryType 'DWORD' -RegistryData $DisconnectOnLockMsIdentity
}
Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $rdKey -RegistryValue 'fEnableTimeZoneRedirection' -RegistryType 'DWORD' -RegistryData 1
If ($EnableRemoteApp) {
    Write-Log -Category Info -Message "Enabling enhanced shell experience for RemoteApp."
    Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $rdKey -RegistryValue 'EnableEnhancedShellExperienceForRemoteApp' -RegistryType 'DWORD' -RegistryData 1
}
Invoke-PolicyUpdate
Write-Log -Category Info -Message "Remote Desktop Services Timeout Settings Configured."
