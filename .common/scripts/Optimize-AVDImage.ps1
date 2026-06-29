#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Applies VDI performance and resource optimizations to a Windows image for AVD deployment.
    Variant: writes group policy values directly to Registry.pol (no LGPO.exe, no COM required).

.DESCRIPTION
    Optimizes a Windows image for AVD based on the selected optimization profile.
    Writes group policy values directly to Registry.pol (MS-GPREG/PReg format) with no
    LGPO.exe dependency. See .common/scripts/README.md for full details, references,
    and deliberate deviations from the VDI optimization article.

    Optimization profiles (-OptimizationProfile):
      None                      - No optimization; only -AirGapped takes effect.
      NonPersistent-UpdatesOnly - Lock down update channels only (OS, M365, Teams,
                                  OneDrive, Edge, WebView2, Store).
      NonPersistent-Full        - Full optimization for pooled AVD host pools.
      Persistent                - Full optimization minus update-channel lockdown.

    Air-gapped / restricted network (-AirGapped):
      Disables Windows components that make outbound calls to Microsoft services,
      causing timeouts in environments with no internet access (Section 7).
      Applies independently of -OptimizationProfile, including None.

.PARAMETER OptimizationProfile
    The optimization profile to apply. See the .DESCRIPTION for full details.

      None                     - No optimization; only -AirGapped takes effect.
      NonPersistent-UpdatesOnly - Lock down update channels only (OS, M365, Teams,
                                 OneDrive, Edge, WebView2, Store).
      NonPersistent-Full       - Full optimization for pooled AVD host pools.
      Persistent               - Full optimization minus update-channel lockdown.

.PARAMETER AirGapped
    When true, applies settings for air-gapped or internet-restricted environments:
    disables SmartScreen cloud lookups, online font providers, Teredo IPv6, WER
    uploads, and DiagTrack telemetry (Section 7). Applies to all profiles, including
    None. Default is false.

.EXAMPLE
    .\Optimize-AVDImage.ps1 -OptimizationProfile NonPersistent-Full
    Full optimization for a pooled AVD image. Internet traffic not restricted.

.EXAMPLE
    .\Optimize-AVDImage.ps1 -OptimizationProfile NonPersistent-Full -AirGapped $true
    Full optimization for a pooled image in an air-gapped or restricted environment.

.EXAMPLE
    .\Optimize-AVDImage.ps1 -OptimizationProfile NonPersistent-UpdatesOnly
    Lock down update channels only. Combine with your own optimization tooling.

.EXAMPLE
    .\Optimize-AVDImage.ps1 -OptimizationProfile Persistent -AirGapped $true
    Personal host pool in a restricted network environment.

.EXAMPLE
    .\Optimize-AVDImage.ps1 -OptimizationProfile None -AirGapped $true
    Apply air-gapped settings only; skip all other optimization.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('None', 'NonPersistent-UpdatesOnly', 'NonPersistent-Full', 'Persistent')]
    [string]$OptimizationProfile,

    # Accepts bool or string ('true'/'false'/'1'/'0') - Azure RunCommand passes all
    # parameters as strings, so [bool] would reject 'false' with a type error.
    [Parameter(Mandatory = $false)]
    [string]$AirGapped = 'false'
)

$ErrorActionPreference = 'Stop'

$LogFile = "$env:SystemRoot\Logs\Optimize-AVDImage.log"
$AirGappedBool = $AirGapped -in @('true', '1', 'yes')
$RunFullOptimization = $OptimizationProfile -in @('NonPersistent-Full', 'Persistent')
$RunNonPersistentSections = $OptimizationProfile -in @('NonPersistent-UpdatesOnly', 'NonPersistent-Full')

# Registry.pol write queue. Entries committed by Invoke-ApplyPolicyQueue.
$script:PolQueue = [System.Collections.Generic.List[hashtable]]@()

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(ValueFromPipeline = $true, Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Message
    )
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

function Disable-VdiService {
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$DisplayName
    )
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) { Write-Log "  [SKIP] Service not found: $Name"; return }
    try {
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        Write-Log "  [OK]   Disabled service: $DisplayName ($Name)"
    }
    catch {
        Write-Log "  [WARN] Set-Service failed for $Name ($_ ) - attempting registry fallback"
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" `
                -Name 'Start' -Value 4 -Type DWord -Force -ErrorAction Stop
            Write-Log "  [OK]   Disabled service via registry fallback: $DisplayName ($Name)"
        }
        catch { Write-Log "  [WARN] Registry fallback also failed for $Name - $_" }
    }
}

function Disable-VdiTask {
    param(
        [Parameter(Mandatory = $true)] [string]$TaskPath,
        [Parameter(Mandatory = $true)] [string]$TaskName
    )
    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) { Write-Log "  [SKIP] Scheduled task not found: $TaskPath$TaskName"; return }
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-Log "  [OK]   Disabled task: $TaskPath$TaskName"
    }
    catch { Write-Log "  [WARN] Could not disable task $TaskPath$TaskName - $_" }
}

function Set-PolicyValue {
    # Routes HKLM:\SOFTWARE\Policies\... and legacy CurrentVersion\Policies\... through
    # Registry.pol queue (Computer section). TempDefaultUser policy paths go to User section.
    # All other paths write directly to the registry.
    param(
        [Parameter(Mandatory = $true)]  [string]$Path,
        [Parameter(Mandatory = $true)]  [string]$Name,
        [Parameter(Mandatory = $true)]  $Value,
        [Parameter(Mandatory = $false)] [Microsoft.Win32.RegistryValueKind]$Type = [Microsoft.Win32.RegistryValueKind]::DWord
    )
    # Route policy paths through the Registry.pol queue.
    $polSection = $null
    $polRelPath = $null
    if ($Path -like 'HKLM:\SOFTWARE\Policies\*' -or
        $Path -like 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\*') {
        $polSection = 'Computer'
        $polRelPath = $Path -replace '^HKLM:\\', ''
    }
    elseif ($Path -like 'HKLM:\TempDefaultUser\Software\Policies\*' -or
        $Path -like 'HKLM:\TempDefaultUser\Software\Microsoft\Windows\CurrentVersion\Policies\*') {
        $polSection = 'User'
        $polRelPath = $Path -replace '^HKLM:\\TempDefaultUser\\', ''
    }
    if ($null -ne $polSection) {
        $null = $script:PolQueue.Add(@{ Section = $polSection; RelPath = $polRelPath; Name = $Name; Value = $Value; Kind = $Type })
        Write-Log "  [POL/$polSection] Queued: $Path\$Name = $Value"
        return
    }
    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
        Write-Log "  [OK]   Registry: $Path\$Name = $Value"
    }
    catch {
        Write-Log "  [WARN] Could not set $Path\$Name - $_"
    }
}

function Disable-VdiAutologger {
    param([Parameter(Mandatory = $true)] [string]$Name)
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$Name"
    if (Test-Path $regPath) {
        Set-PolicyValue -Path $regPath -Name 'Start' -Value 0
        Write-Log "  [OK]   Disabled autologger: $Name"
    }
    else { Write-Log "  [SKIP] Autologger not found: $Name" }
}

function Invoke-ApplyPolicyQueue {
    # Commits queued policy entries to Registry.pol (MS-GPREG/PReg binary format) and
    # writes gpt.ini. Falls back to direct registry if the file write fails. No-op if empty.
    if ($script:PolQueue.Count -eq 0) { return }
    $entryCount = $script:PolQueue.Count

    $utf16      = [System.Text.Encoding]::Unicode
    $pRegSig    = [System.Text.Encoding]::ASCII.GetBytes('PReg')
    $pRegVer    = [BitConverter]::GetBytes([uint32]1)
    $bracketOpen  = [byte[]](0x5B, 0x00)
    $bracketClose = [byte[]](0x5D, 0x00)
    $semicolon    = [byte[]](0x3B, 0x00)
    $nullterm     = [byte[]](0x00, 0x00)

    function Read-PRegFile([string]$Path) {
        $list = [System.Collections.Generic.List[hashtable]]::new()
        if (-not (Test-Path $Path)) { return ,$list }
        $raw = [IO.File]::ReadAllBytes($Path)
        if ($raw.Length -lt 8) { return ,$list }
        $sig = [System.Text.Encoding]::ASCII.GetString($raw, 0, 4)
        if ($sig -ne 'PReg') { throw "Invalid Registry.pol header: $Path" }
        $pos = 8
        while ($pos -lt $raw.Length) {
            if ($pos + 1 -ge $raw.Length) { break }
            if ($raw[$pos] -ne 0x5B -or $raw[$pos+1] -ne 0x00) { $pos++; continue }
            $pos += 2
            # Read key string
            $start = $pos
            while ($pos + 1 -lt $raw.Length -and -not ($raw[$pos] -eq 0 -and $raw[$pos+1] -eq 0)) { $pos += 2 }
            $key = $utf16.GetString($raw, $start, $pos - $start); $pos += 2  # skip null
            $pos += 2  # skip ;
            # Read value name string
            $start = $pos
            while ($pos + 1 -lt $raw.Length -and -not ($raw[$pos] -eq 0 -and $raw[$pos+1] -eq 0)) { $pos += 2 }
            $vname = $utf16.GetString($raw, $start, $pos - $start); $pos += 2  # skip null
            $pos += 2  # skip ;
            # Type, size, data
            $vtype = [BitConverter]::ToUInt32($raw, $pos); $pos += 4; $pos += 2  # skip ;
            $vsize = [BitConverter]::ToUInt32($raw, $pos); $pos += 4; $pos += 2  # skip ;
            # Guard: PowerShell a..b with a>b produces a descending slice, not empty
            $vdata = if ($vsize -gt 0) { $raw[$pos..($pos + $vsize - 1)] } else { [byte[]]@() }
            $pos += $vsize
            $pos += 2  # skip ]
            $list.Add(@{ Key=$key; Name=$vname; Type=$vtype; Size=$vsize; Data=$vdata })
        }
        return ,$list
    }

    function Merge-PRegEntry($entries, [string]$key, [string]$name, [uint32]$type, [byte[]]$data) {
        $existing = @($entries | Where-Object { $_.Key -eq $key -and $_.Name -eq $name })
        foreach ($e in $existing) { $entries.Remove($e) | Out-Null }
        $entries.Add(@{ Key=$key; Name=$name; Type=$type; Size=[uint32]$data.Length; Data=$data })
    }

    function Write-PRegFile([string]$Path, $entries) {
        $stream = [IO.MemoryStream]::new()
        $w = [IO.BinaryWriter]::new($stream)
        $w.Write($pRegSig); $w.Write($pRegVer)
        foreach ($e in $entries) {
            $w.Write($bracketOpen)
            $w.Write($utf16.GetBytes($e.Key));   $w.Write($nullterm); $w.Write($semicolon)
            $w.Write($utf16.GetBytes($e.Name));  $w.Write($nullterm); $w.Write($semicolon)
            $w.Write([uint32]$e.Type);           $w.Write($semicolon)
            $w.Write([uint32]$e.Size);           $w.Write($semicolon)
            if ($null -ne $e.Data -and $e.Data.Length -gt 0) { $w.Write([byte[]]$e.Data) }
            $w.Write($bracketClose)
        }
        $w.Flush()
        $bytes    = $stream.ToArray()
        $expected = $bytes.Length

        $dir = Split-Path $Path
        if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }

        # Write to a temp file first so the original is never partially overwritten
        $tmp = "$Path.tmp"
        [IO.File]::WriteAllBytes($tmp, $bytes)

        # Verify the temp file is complete before committing
        $actual = (Get-Item $tmp).Length
        if ($actual -ne $expected) {
            Remove-Item $tmp -Force -EA SilentlyContinue
            throw "Registry.pol temp write verification failed: expected $expected bytes, file has $actual bytes"
        }

        # Atomic promotion: replace the live file with the verified temp
        Move-Item $tmp $Path -Force
    }

    # Build per-file entry lists from the queue
    $machineEntries = Read-PRegFile "$env:SystemRoot\System32\GroupPolicy\Machine\Registry.pol"
    $userEntries    = Read-PRegFile "$env:SystemRoot\System32\GroupPolicy\User\Registry.pol"
    $machineUpdated = $false
    $userUpdated    = $false

    foreach ($e in $script:PolQueue) {
        try {
            switch ($e.Kind) {
                ([Microsoft.Win32.RegistryValueKind]::DWord) {
                    $data = [BitConverter]::GetBytes([uint32]$e.Value)
                    $type = [uint32]4  # REG_DWORD
                }
                ([Microsoft.Win32.RegistryValueKind]::String) {
                    # REG_SZ: UTF-16LE with null terminator
                    $data = $utf16.GetBytes([string]$e.Value + [char]0)
                    $type = [uint32]1  # REG_SZ
                }
                ([Microsoft.Win32.RegistryValueKind]::MultiString) {
                    # REG_MULTI_SZ: each string UTF-16LE null-terminated, final extra null
                    $arr = if ($e.Value -is [array]) { [string[]]$e.Value } else { [string[]]@($e.Value) }
                    $data = $utf16.GetBytes(($arr -join [char]0) + [char]0 + [char]0)
                    $type = [uint32]7  # REG_MULTI_SZ
                }
                default {
                    Write-Log "  [WARN] PReg: unsupported type $($e.Kind) for $($e.RelPath)\$($e.Name) - skipping"
                    continue
                }
            }
            if ($e.Section -eq 'Computer') {
                Merge-PRegEntry $machineEntries $e.RelPath $e.Name $type $data
                $machineUpdated = $true
            }
            else {
                Merge-PRegEntry $userEntries $e.RelPath $e.Name $type $data
                $userUpdated = $true
            }
            Write-Log "  [POL] Written to Registry.pol: [$($e.Section)] $($e.RelPath)\$($e.Name) = $($e.Value)"
        }
        catch {
            Write-Log "  [WARN] PReg merge failed for $($e.RelPath)\$($e.Name): $_"
        }
    }

    if ($machineUpdated) {
        try {
            Write-PRegFile "$env:SystemRoot\System32\GroupPolicy\Machine\Registry.pol" $machineEntries
            Write-Log "  [OK]   Machine Registry.pol written ($($machineEntries.Count) entries)"
        }
        catch {
            Write-Log "  [WARN] Machine Registry.pol write failed ($_) - applying queued computer entries via direct registry fallback"
            foreach ($e in @($script:PolQueue | Where-Object { $_.Section -eq 'Computer' })) {
                $regPath = "HKLM:\$($e.RelPath)"
                try {
                    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force -EA Stop | Out-Null }
                    Set-ItemProperty -Path $regPath -Name $e.Name -Value $e.Value -Type $e.Kind -Force -EA Stop
                    Write-Log "  [FB]   Direct registry: $regPath\$($e.Name) = $($e.Value)"
                }
                catch { Write-Log "  [WARN] Direct registry fallback failed for $regPath\$($e.Name): $_" }
            }
        }
    }
    if ($userUpdated) {
        try {
            Write-PRegFile "$env:SystemRoot\System32\GroupPolicy\User\Registry.pol" $userEntries
            Write-Log "  [OK]   User Registry.pol written ($($userEntries.Count) entries)"
        }
        catch {
            Write-Log "  [WARN] User Registry.pol write failed ($_) - applying queued user entries via direct registry fallback"
            foreach ($e in @($script:PolQueue | Where-Object { $_.Section -eq 'User' })) {
                # User policy path is relative to Software\...; write to the loaded default user hive
                $regPath = "HKLM:\TempDefaultUser\$($e.RelPath)"
                try {
                    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force -EA Stop | Out-Null }
                    Set-ItemProperty -Path $regPath -Name $e.Name -Value $e.Value -Type $e.Kind -Force -EA Stop
                    Write-Log "  [FB]   Direct registry (default user hive): $regPath\$($e.Name) = $($e.Value)"
                }
                catch { Write-Log "  [WARN] Direct registry fallback failed for $regPath\$($e.Name): $_" }
            }
        }
    }
    Write-Log "  [OK]   Registry.pol direct write applied $entryCount policy values total"

    # Write gpt.ini so the GP Client on deployed VMs knows Registry.pol has content.
    try {
        $gptPath  = "$env:SystemRoot\System32\GroupPolicy\gpt.ini"
        $regCse   = '{35378EAC-683F-11D2-A89A-00C04FBBCFA2}'
        $machineAT = '{D02B1F72-3407-48AE-BA88-E8213C6761F1}'
        $userAT    = '{D02B1F73-3407-48AE-BA88-E8213C6761F1}'

        # Read existing version so we increment rather than reset.
        $machineVer = [uint16]1
        $userVer    = [uint16]1
        if (Test-Path $gptPath) {
            $existing = Get-Content $gptPath -Raw
            if ($existing -match 'Version\s*=\s*(\d+)') {
                $cur = [uint32]$matches[1]
                $machineVer = [uint16]($cur -band 0xFFFF)
                $userVer    = [uint16](($cur -shr 16) -band 0xFFFF)
            }
        }
        if ($machineUpdated) { $machineVer++ }
        if ($userUpdated)    { $userVer++ }
        $version = ([uint32]$userVer -shl 16) -bor [uint32]$machineVer

        # Build final extension name strings for each scope.
        # Always preserve lines from the prior file, even when a scope was not updated
        # in this call. Without this, a call that only updates one scope (e.g. Section 8
        # writes only user entries) would silently drop the other scope's extension name
        # from gpt.ini, causing the GP client on deployed VMs to skip that CSE entirely.
        $machineExt = "[$regCse$machineAT]"
        $userExt    = "[$regCse$userAT]"

        $finalMachineExt = if ($machineUpdated) {
            if ($existing -match 'gPCMachineExtensionNames\s*=\s*(.+)') {
                $ev = $matches[1].Trim()
                # Use CSE GUID presence (any snap-in) to detect duplicates. LGPO uses its
                # own tool GUID {DF3DC19F...} rather than the standard AT snap-in GUID, so
                # an exact-pair check would add a second Registry CSE entry alongside it.
                # The GP client processes registry.pol based on the CSE GUID alone.
                if ($ev -notlike "*$regCse*") { $ev + $machineExt } else { $ev }
            } else { $machineExt }
        } elseif ($existing -match 'gPCMachineExtensionNames\s*=\s*(.+)') {
            $matches[1].Trim()
        } else { '' }

        $finalUserExt = if ($userUpdated) {
            if ($existing -match 'gPCUserExtensionNames\s*=\s*(.+)') {
                $ev = $matches[1].Trim()
                if ($ev -notlike "*$regCse*") { $ev + $userExt } else { $ev }
            } else { $userExt }
        } elseif ($existing -match 'gPCUserExtensionNames\s*=\s*(.+)') {
            $matches[1].Trim()
        } else { '' }

        $gptContent = "[General]`r`n"
        if ($finalMachineExt) { $gptContent += "gPCMachineExtensionNames=$finalMachineExt`r`n" }
        if ($finalUserExt)    { $gptContent += "gPCUserExtensionNames=$finalUserExt`r`n" }
        $gptContent += "Version=$version`r`n"

        [IO.File]::WriteAllText($gptPath, $gptContent, [System.Text.Encoding]::ASCII)
        Write-Log "  [OK]   gpt.ini written (Version=$version machine=$machineVer user=$userVer)"
    }
    catch {
        Write-Log "  [WARN] gpt.ini write failed: $_"
    }

    $script:PolQueue.Clear()
}
# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-Log ""
    Write-Log "============================================================"
    Write-Log "  Optimize-AVDImage"
    Write-Log "============================================================"
    Write-Log "  Profile         : $OptimizationProfile"
    Write-Log "  AirGapped       : $AirGappedBool"
    Write-Log "  OS              : $([System.Environment]::OSVersion.VersionString)"
    Write-Log "  Timestamp       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log "============================================================"
    Write-Log ""

        # Registry.pol availability check
        Write-Log "--- Registry.pol Direct-Write Check ---"
        $machinePolDir = "$env:SystemRoot\System32\GroupPolicy\Machine"
        if (Test-Path $machinePolDir) {
            Write-Log "  [OK]   GroupPolicy\Machine directory present"
        } else {
            Write-Log "  [INFO] GroupPolicy\Machine directory not found - will be created on first write"
        }
        Write-Log ""

    # -----------------------------------------------------------------------
    # PRE-STEP - Power Plan: High Performance
    # -----------------------------------------------------------------------
    Write-Log "--- Pre-step: Power Plan ---"
    try {
        & powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>&1 | Out-Null
        Write-Log "  [OK]   Power plan set to High Performance"
    }
    catch {
        Write-Log "  [WARN] Could not set power plan via powercfg - $_"
    }
    Write-Log ""

    # -----------------------------------------------------------------------
    # SECTION 1 - System Services: All VDI
    # These services provide no benefit in any VDI deployment model.
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 1: System Services (All VDI) ---"

        # Cellular Time - no cellular adapter in VMs
        Disable-VdiService -Name 'autotimesvc' -DisplayName 'Cellular Time'
        # GameDVR and Broadcast user service (per-user template) - no game workloads
        Disable-VdiService -Name 'BcastDVRUserService' -DisplayName 'GameDVR and Broadcast User Service'
        # CaptureService - required by Windows.Graphics.Capture API (Teams, Snipping Tool)
        # Connected Devices Platform - cross-device scenarios irrelevant in VDI
        Disable-VdiService -Name 'CDPSvc' -DisplayName 'Connected Devices Platform Service'
        # CDP User Service (per-user template)
        Disable-VdiService -Name 'CDPUserSvc' -DisplayName 'CDP User Service'
        # DPS / DiagSvc / WdiSystemHost - not disabled; see README for rationale
        # Device Setup Manager - VDI environments control device software centrally
        Disable-VdiService -Name 'DsmSvc' -DisplayName 'Device Setup Manager'
        # Data Usage Service - no metered network management needed
        Disable-VdiService -Name 'DusmSvc' -DisplayName 'Data Usage Service'
        # Windows Mobile Hotspot Service - no mobile adapter in VMs
        Disable-VdiService -Name 'icssvc' -DisplayName 'Windows Mobile Hotspot Service'
        # Geolocation Service
        Disable-VdiService -Name 'lfsvc' -DisplayName 'Geolocation Service'
        # Downloaded Maps Manager
        Disable-VdiService -Name 'MapsBroker' -DisplayName 'Downloaded Maps Manager'
        # MessagingService (per-user template) - SMS/MMS not used in enterprise VDI
        Disable-VdiService -Name 'MessagingService' -DisplayName 'Messaging Service'
        # OneSyncSvc - not disabled; re-syncs Exchange mail/contacts/calendar (see README)
        # Contact Data (per-user template)
        Disable-VdiService -Name 'PimIndexMaintenanceSvc' -DisplayName 'Contact Data'
        # Power - not disabled; required by powercfg.exe and RDP session management
        # Payments and NFC/SE Manager - no NFC hardware in VMs
        Disable-VdiService -Name 'SEMgrSvc' -DisplayName 'Payments and NFC/SE Manager'
        # SMS Router Service - no SMS infrastructure in enterprise VDI
        Disable-VdiService -Name 'SmsRouter' -DisplayName 'Microsoft Windows SMS Router Service'
        # Xbox Live Auth Manager
        Disable-VdiService -Name 'XblAuthManager' -DisplayName 'Xbox Live Auth Manager'
        # Xbox Live Game Save
        Disable-VdiService -Name 'XblGameSave' -DisplayName 'Xbox Live Game Save'
        # Xbox Accessory Management Service
        Disable-VdiService -Name 'XboxGipSvc' -DisplayName 'Xbox Accessory Management Service'
        # Xbox Live Networking Service
        Disable-VdiService -Name 'XboxNetApiSvc' -DisplayName 'Xbox Live Networking Service'

        # WSearch - not disabled; see README for rationale
        # Disable-VdiService -Name 'WSearch' -DisplayName 'Windows Search'

        Write-Log ""
    } # end if RunFullOptimization - Section 1

    # -----------------------------------------------------------------------
    # SECTION 2 - System Services: NonPersistent Only
    # These services either provide no carry-over value in an image-managed
    # deployment, or are superseded by image-level servicing processes.
    # -----------------------------------------------------------------------
    if ($RunNonPersistentSections) {
        Write-Log "--- Section 2: System Services (NonPersistent Only) ---"

        # SysMain - SSD-backed managed disks gain little from prefetching
        Disable-VdiService -Name 'SysMain' -DisplayName 'Superfetch (SysMain)'
        # defragsvc - OS disk rebuilt at image refresh; retrim has no carry-over value on NonPersistent
        Disable-VdiService -Name 'defragsvc' -DisplayName 'Optimize Drives'
        # InstallService - not disabled; see README for rationale
        # UsoSvc - OS updates via image replacement, not per-VM Windows Update
        Disable-VdiService -Name 'UsoSvc' -DisplayName 'Update Orchestrator Service'
        # VSS - user data in FSLogix containers backed up at the storage layer
        Disable-VdiService -Name 'VSS' -DisplayName 'Volume Shadow Copy'
        # wuauserv - disabled NonPersistent; SCCM/Intune manages on Persistent
        Disable-VdiService -Name 'wuauserv' -DisplayName 'Windows Update'
        # WaaSMedicSvc - re-enables wuauserv if disabled; Set-Service falls back to registry
        Disable-VdiService -Name 'WaaSMedicSvc' -DisplayName 'Windows Update Medic Service'
        # WerSvc - transient VMs discard crash data at recycle
        Disable-VdiService -Name 'WerSvc' -DisplayName 'Windows Error Reporting'
        # DPS/DiagSvc/WdiSystemHost - scoped to NonPersistent; see README
        Disable-VdiService -Name 'DPS' -DisplayName 'Diagnostic Policy Service'
        Disable-VdiService -Name 'DiagSvc' -DisplayName 'Diagnostic Execution Service'
        Disable-VdiService -Name 'WdiSystemHost' -DisplayName 'Diagnostic System Host'
        # DiagTrack - transient VMs have no per-VM Endpoint Analytics value
        Disable-VdiService -Name 'DiagTrack' -DisplayName 'Connected User Experiences and Telemetry'
        # Edge update services - updated via image on NonPersistent
        Disable-VdiService -Name 'edgeupdate' -DisplayName 'Microsoft Edge Update Service'
        Disable-VdiService -Name 'edgeupdatem' -DisplayName 'Microsoft Edge Update Service (Manual Trigger)'

        Write-Log ""
    }

    # -----------------------------------------------------------------------
    # SECTION 3 - Scheduled Tasks: All VDI
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 3: Scheduled Tasks (All VDI) ---"

        $allVdiTasks = @(
            # Application Experience - telemetry data collection
            @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' },
            # Autochk - SQM data upload for CEIP
            @{ Path = '\Microsoft\Windows\Autochk\'; Name = 'Proxy' },
            # Customer Experience Improvement Program
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'KernelCeipTask' },
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
            # Diagnosis - scheduled maintenance diagnostics
            @{ Path = '\Microsoft\Windows\Diagnosis\'; Name = 'Scheduled' },
            # Disk Diagnostic - reports disk/system info to Microsoft
            @{ Path = '\Microsoft\Windows\DiskDiagnostic\'; Name = 'Microsoft-Windows-DiskDiagnosticDataCollector' },
            # DiskFootprint - storage I/O diagnostic collection
            @{ Path = '\Microsoft\Windows\DiskFootprint\'; Name = 'Diagnostics' },
            # Error Details
            @{ Path = '\Microsoft\Windows\ErrorDetails\'; Name = 'EnableErrorDetailsUpdate' },
            @{ Path = '\Microsoft\Windows\ErrorDetails\'; Name = 'ErrorDetailsUpdate' },
            # Feedback / SIUF - satisfaction survey prompts
            @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClient' },
            @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClientOnScenarioDownload' },
            # File History
            @{ Path = '\Microsoft\Windows\FileHistory\'; Name = 'File History (maintenance mode)' },
            # Location notification balloon
            @{ Path = '\Microsoft\Windows\Location\'; Name = 'WindowsActionDialog' },
            # Maps toast and map data updates
            @{ Path = '\Microsoft\Windows\Maps\'; Name = 'MapsToastTask' },
            @{ Path = '\Microsoft\Windows\Maps\'; Name = 'MapsUpdateTask' },
            # Mobile PC
            @{ Path = '\Microsoft\Windows\MobilePC\'; Name = 'HotStart' },
            # Platform Instrumentation - TPM/Secure Boot telemetry
            @{ Path = '\Microsoft\Windows\PI\'; Name = 'Sqm-Tasks' },
            # Power Efficiency Diagnostics
            @{ Path = '\Microsoft\Windows\Power Efficiency Diagnostics\'; Name = 'AnalyzeSystem' },
            # Push To Install
            @{ Path = '\Microsoft\Windows\PushToInstall\'; Name = 'LoginCheck' },
            @{ Path = '\Microsoft\Windows\PushToInstall\'; Name = 'Registration' },
            # Family Safety monitoring
            @{ Path = '\Microsoft\Windows\Shell\'; Name = 'FamilySafetyMonitor' },
            @{ Path = '\Microsoft\Windows\Shell\'; Name = 'FamilySafetyRefreshTask' },
            # Storage Spaces
            @{ Path = '\Microsoft\Windows\SpacePort\'; Name = 'SpaceAgentTask' },
            @{ Path = '\Microsoft\Windows\SpacePort\'; Name = 'SpaceManagerTask' },
            # Speech model download
            @{ Path = '\Microsoft\Windows\Speech\'; Name = 'SpeechModelDownloadTask' },
            # Update Orchestrator reporting
            @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Report policies' },
            # Startup app notification
            @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'StartupAppTask' },
            # Diagnostics - WDI resolution host
            @{ Path = '\Microsoft\Windows\WDI\'; Name = 'ResolutionHost' },
            # Windows Error Reporting queued reports
            @{ Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting' },
            # Windows Update scheduled trigger
            @{ Path = '\Microsoft\Windows\WindowsUpdate\'; Name = 'Scheduled Start' },
            # WLAN CDSSynchronization
            @{ Path = '\Microsoft\Windows\WlanSvc\'; Name = 'CDSSync' },
            # WOF hash management
            @{ Path = '\Microsoft\Windows\WOF\'; Name = 'WIM-Hash-Management' },
            @{ Path = '\Microsoft\Windows\WOF\'; Name = 'WIM-Hash-Validation' },
            # Xbox Game Save
            @{ Path = '\Microsoft\XblGameSave\'; Name = 'XblGameSaveTask' },
            @{ Path = '\Microsoft\XblGameSave\'; Name = 'XblGameSaveTaskLogon' }
        )

        foreach ($task in $allVdiTasks) {
            Disable-VdiTask -TaskPath $task.Path -TaskName $task.Name
        }

        # RegIdleBackup / SilentCleanup - not disabled; see README
        # Disable-VdiTask -TaskPath '\Microsoft\Windows\Registry\' -TaskName 'RegIdleBackup'
        # Disable-VdiTask -TaskPath '\Microsoft\Windows\DiskCleanup\' -TaskName 'SilentCleanup'

        Write-Log ""
    } # end if RunFullOptimization - Section 3

    # -----------------------------------------------------------------------
    # SECTION 4 - Scheduled Tasks: NonPersistent Only
    # These tasks serve no purpose in an image-managed deployment, or their
    # function is better handled at the image-build stage.
    # -----------------------------------------------------------------------
    if ($RunNonPersistentSections) {
        Write-Log "--- Section 4: Scheduled Tasks (NonPersistent Only) ---"

        $nonPersistentTasks = @(
            # ScheduledDefrag - OS disk rebuilt at image refresh; retrim has no carry-over value
            @{ Path = '\Microsoft\Windows\Defrag\'; Name = 'ScheduledDefrag' },
            # WinSAT - scores on Azure VMs are not representative
            @{ Path = '\Microsoft\Windows\Maintenance\'; Name = 'WinSAT' },
            # Memory diagnostics - hardware managed at hypervisor/platform layer
            @{ Path = '\Microsoft\Windows\MemoryDiagnostic\'; Name = 'ProcessMemoryDiagnosticEvents' },
            @{ Path = '\Microsoft\Windows\MemoryDiagnostic\'; Name = 'RunFullMemoryDiagnostic' },
            # StartComponentCleanup - run at image build time, not on production VMs
            @{ Path = '\Microsoft\Windows\Servicing\'; Name = 'StartComponentCleanup' },
            # SR - already disabled via policy in Section 5
            @{ Path = '\Microsoft\Windows\SystemRestore\'; Name = 'SR' },
            # Windows Update scans - OS updates via image replacement
            @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Schedule Scan' },
            @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Schedule Scan Static Task' },
            @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'USO_UxBroker' }
        )

        foreach ($task in $nonPersistentTasks) {
            Disable-VdiTask -TaskPath $task.Path -TaskName $task.Name
        }

        # Update channel tasks: task paths vary by install location or include per-user SIDs.
        Write-Log "  Disabling update channel scheduled tasks (NonPersistent)..."

        # Microsoft 365 / Office Click-to-Run automatic updates
        $officeUpdateTask = Get-ScheduledTask -TaskName 'Office Automatic Updates 2.0' `
            -ErrorAction SilentlyContinue
        if ($officeUpdateTask) {
            Disable-ScheduledTask -TaskPath $officeUpdateTask.TaskPath `
                -TaskName $officeUpdateTask.TaskName `
                -ErrorAction SilentlyContinue | Out-Null
            Write-Log "  [OK]   Disabled task: $($officeUpdateTask.TaskPath)$($officeUpdateTask.TaskName)"
        }
        else { Write-Log '  [SKIP] Task not found: Office Automatic Updates 2.0' }

        # OneDrive: task names include per-user SIDs; matched by wildcard
        foreach ($pattern in @('OneDrive Reporting Task-S-*', 'OneDrive Standalone Update Task-S-*')) {
            Get-ScheduledTask -TaskName $pattern -ErrorAction SilentlyContinue | ForEach-Object {
                Disable-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName `
                    -ErrorAction SilentlyContinue | Out-Null
                Write-Log "  [OK]   Disabled task: $($_.TaskPath)$($_.TaskName)"
            }
        }

        # Edge / WebView2 update tasks
        foreach ($edgeTaskName in @('MicrosoftEdgeUpdateTaskMachineCore', 'MicrosoftEdgeUpdateTaskMachineUA')) {
            $edgeUpdateTask = Get-ScheduledTask -TaskName $edgeTaskName -ErrorAction SilentlyContinue
            if ($edgeUpdateTask) {
                Disable-ScheduledTask -TaskPath $edgeUpdateTask.TaskPath `
                    -TaskName $edgeUpdateTask.TaskName `
                    -ErrorAction SilentlyContinue | Out-Null
                Write-Log "  [OK]   Disabled task: $($edgeUpdateTask.TaskPath)$($edgeUpdateTask.TaskName)"
            }
            else { Write-Log "  [SKIP] Task not found: $edgeTaskName" }
        }

        # Microsoft Store / InstallService update tasks
        $storeUpdateTasks = @(
            @{ Path = '\Microsoft\Windows\InstallService\'; Name = 'ScanForUpdates' },
            @{ Path = '\Microsoft\Windows\InstallService\'; Name = 'ScanForUpdatesAsUser' },
            @{ Path = '\Microsoft\Windows\InstallService\'; Name = 'SmartRetry' }
        )
        foreach ($entry in $storeUpdateTasks) {
            Disable-VdiTask -TaskPath $entry.Path -TaskName $entry.Name
        }

        Write-Log ""
    }

    # -----------------------------------------------------------------------
    # SECTION 5 - Registry / Policy Settings: All VDI
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 5: Registry / Policy Settings (All VDI) ---"

        # -- Telemetry (DataCollection.admx) --
        # AllowTelemetry=1 (Basic): minimum for Endpoint Analytics and Update Compliance.
        # NonPersistent VMs override to 0 in Section 6.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' `
            -Name 'AllowTelemetry' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' `
            -Name 'DoNotShowFeedbackNotifications' -Value 1

        # -- Privacy / Consumer Experiences (CloudContent.admx) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
            -Name 'DisableWindowsConsumerFeatures' -Value 1
        # DisableSoftLanding = Windows Tips. DisableWindowsTips has no ADMX definition.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
            -Name 'DisableSoftLanding' -Value 1
        # NOTE: DisableThirdPartySuggestions and DisableWindowsSpotlightFeatures are User
        # Configuration only (HKCU). Applied in Section 8 via the default user hive.
        # AT: Computer Configuration > System > OS Policies
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'EnableCdp' -Value 0

        # -- Advertising ID (AT: Computer Configuration > System > User Profiles) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' `
            -Name 'DisabledByGroupPolicy' -Value 1

        # -- App Privacy (AT: Computer Configuration > Windows Components > App Privacy) --
        # Values: 0 = User in control, 1 = Force allow, 2 = Force deny
        $appPrivacyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsGetDiagnosticInfo' -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsGetDiagnosticInfo_UserInControlOfTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsGetDiagnosticInfo_ForceAllowTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsGetDiagnosticInfo_ForceDenyTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessLocation' -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessLocation_UserInControlOfTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessLocation_ForceAllowTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessLocation_ForceDenyTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessMotion' -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessMotion_UserInControlOfTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessMotion_ForceAllowTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessMotion_ForceDenyTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessNotifications' -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessNotifications_UserInControlOfTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessNotifications_ForceAllowTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessNotifications_ForceDenyTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsActivateWithVoice' -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsActivateWithVoiceAboveLock' -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessRadios' -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessRadios_UserInControlOfTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessRadios_ForceAllowTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessRadios_ForceDenyTheseApps' -Value @() -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)

        # -- Input Personalization / Typing (Globalization.admx, TextInput.admx) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' `
            -Name 'AllowInputPersonalization' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' `
            -Name 'RestrictImplicitTextCollection' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' `
            -Name 'RestrictImplicitInkCollection' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\TextInput' `
            -Name 'AllowLinguisticDataCollection' -Value 0

        # -- Location and Sensors (AT: Computer Configuration > Windows Components > Location and Sensors) --
        $locationPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
        Set-PolicyValue -Path $locationPath -Name 'DisableLocation' -Value 1
        Set-PolicyValue -Path $locationPath -Name 'DisableSensors' -Value 1
        Set-PolicyValue -Path $locationPath -Name 'DisableWindowsLocationProvider' -Value 1

        # -- Search and Cortana (Search.admx) --
        $searchPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
        Set-PolicyValue -Path $searchPath -Name 'AllowCortana' -Value 0
        Set-PolicyValue -Path $searchPath -Name 'AllowCortanaAboveLock' -Value 0
        Set-PolicyValue -Path $searchPath -Name 'AllowSearchToUseLocation' -Value 0
        Set-PolicyValue -Path $searchPath -Name 'DisableWebSearch' -Value 1
        Set-PolicyValue -Path $searchPath -Name 'ConnectedSearchUseWeb' -Value 0
        Set-PolicyValue -Path $searchPath -Name 'ConnectedSearchPrivacy' -Value 3  # 3=AnonymousInfoOnly (most restrictive)
        Set-PolicyValue -Path $searchPath -Name 'PreventIndexingOfflineFiles' -Value 1
        Set-PolicyValue -Path $searchPath -Name 'PreventIndexingUncachedExchangeFolders' -Value 1
        Set-PolicyValue -Path $searchPath -Name 'RichAttachmentPreviews' -Value '.docx;.xlsx;.txt;.xls' `
            -Type ([Microsoft.Win32.RegistryValueKind]::String)

        # -- BITS peer caching (AT: Computer Configuration > Network > Background Intelligent Transfer Service (BITS)) --
        $bitsPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\BITS'
        Set-PolicyValue -Path $bitsPath -Name 'EnablePeercaching' -Value 0
        Set-PolicyValue -Path $bitsPath -Name 'DisableBranchCache' -Value 1
        Set-PolicyValue -Path $bitsPath -Name 'DisablePeerCachingClient' -Value 1
        Set-PolicyValue -Path $bitsPath -Name 'DisablePeerCachingServer' -Value 1

        # -- BranchCache service-level disable (AT: Computer Configuration > Network > BranchCache) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\PeerDist\Service' `
            -Name 'Enable' -Value 0

        # -- Delivery Optimization (AT: Computer Configuration > Windows Components > Delivery Optimization) --
        # 99 = Simple download mode; no contact with Delivery Optimization cloud services
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' `
            -Name 'DODownloadMode' -Value 99

        # -- Maps (WinMaps.admx) --
        # TurnOffAutoUpdate: enabledValue=0; DisallowUntriggeredNetworkOnSettingsPage: enabledValue=0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps' `
            -Name 'AutoDownloadAndUpdateMapData' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps' `
            -Name 'AllowUntriggeredNetworkTrafficOnSettingsPage' -Value 0

        # -- Messaging (AT: Computer Configuration > Windows Components > Messaging) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Messaging' `
            -Name 'AllowMessageSync' -Value 0

        # -- Offline Files (AT: Computer Configuration > Network > Offline Files) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache' `
            -Name 'Enabled' -Value 0

        # -- Network List Manager (no ADMX backing - written directly to registry) --
        # CategoryReadOnly=1 prevents users from changing the network location type.
        $nlmPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\NetworkList\Signatures\EveryNetwork'
        if (-not (Test-Path $nlmPath)) { New-Item -Path $nlmPath -Force | Out-Null }
        Set-ItemProperty -Path $nlmPath -Name 'CategoryReadOnly' -Value 1 -Type DWord -Force

        # -- Hotspot Authentication (AT: Computer Configuration > Network > Hotspot Authentication) --
        # Prevents Windows from automatically authenticating to Wi-Fi hotspots.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\HotspotAuthentication' `
            -Name 'Enabled' -Value 0

        # -- Wi-Fi Sense (wcmsvc key - no Wi-Fi hardware in VMs) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\wcmsvc\wifinetworkmanager\config' `
            -Name 'AutoConnectAllowedOEM' -Value 0

        # -- Cellular Data Access (WwanSvc.admx) - LetAppsAccessCellularData: 2=Force Deny --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WwanSvc\CellularDataAccess' `
            -Name 'LetAppsAccessCellularData' -Value 2
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WwanSvc\CellularDataAccess' `
            -Name 'LetAppsAccessCellularData_UserInControlOfTheseApps' -Value ([string[]]@()) `
            -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WwanSvc\CellularDataAccess' `
            -Name 'LetAppsAccessCellularData_ForceAllowTheseApps' -Value ([string[]]@()) `
            -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WwanSvc\CellularDataAccess' `
            -Name 'LetAppsAccessCellularData_ForceDenyTheseApps' -Value ([string[]]@()) `
            -Type ([Microsoft.Win32.RegistryValueKind]::MultiString)

        # -- Desktop Window Manager (DWM.admx) --
        # NOTE: WiFiSenseCredShared/WiFiSenseOpen removed (deprecated W10 1803).
        # NOTE: UseSolidColorForStart removed (no ADMX definition in DWM.admx).
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DWM' `
            -Name 'DisallowAnimations' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DWM' `
            -Name 'DisableAccentGradient' -Value 1

        # -- Microsoft Edge: suppress preloading / hide first-run (msedge.admx) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'StartupBoostEnabled' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'BackgroundModeEnabled' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'HideFirstRunExperience' -Value 1

        # -- OneDrive: PreventNetworkTrafficPreUserSignIn - SKIP (breaks KFM silent sign-in) --
        # Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'PreventNetworkTrafficPreUserSignIn' -Value 1

        # -- Windows Ink Workspace (AT: Computer Configuration > Windows Components > Windows Ink Workspace) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace' `
            -Name 'AllowWindowsInkWorkspace' -Value 0

        # -- Windows Game DVR / Recording (AT: Computer Configuration > Windows Components > Windows Game Recording and Broadcasting) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' `
            -Name 'AllowGameDVR' -Value 0

        # -- Speech model auto-update (AT: Computer Configuration > Windows Components > Speech) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Speech' `
            -Name 'AllowSpeechModelUpdate' -Value 0

        # -- Microsoft Store: suppress OS upgrade offers (AT: Computer Configuration > Windows Components > Store) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' `
            -Name 'DisableOSUpgrade' -Value 1

        # -- OOBE: skip privacy settings experience at first logon (AT: Computer Configuration > Windows Components > OOBE) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' `
            -Name 'DisablePrivacyExperience' -Value 1

        # -- Logon screen (Logon.admx, WinLogon.admx) --
        # NoWelcomeScreen=1: suppresses Getting Started screen at logon
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
            -Name 'NoWelcomeScreen' -Value 1
        # EnableFirstLogonAnimation=0: suppresses welcome animation and MSA opt-in on first logon
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
            -Name 'EnableFirstLogonAnimation' -Value 0
        # DisableAcrylicBackgroundOnLogon=1: removes acrylic blur on logon background
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'DisableAcrylicBackgroundOnLogon' -Value 1

        # -- Search index low-disk threshold (Search.admx) --
        # valueName=PreventIndexingLowDiskSpaceMB (not StopIndexingOnLimitedHardDriveSpace)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' `
            -Name 'PreventIndexingLowDiskSpaceMB' -Value 5000

        # -- NTFS: disable short (8.3) file name creation on all volumes --
        Set-PolicyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
            -Name 'NtfsDisable8dot3NameCreation' -Value 1

        # -- AutoPlay --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
            -Name 'NoDriveTypeAutoRun' -Value 255
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
            -Name 'NoAutorun' -Value 1

        # -- Application Compatibility: Inventory Collector (AT: Computer Configuration > Windows Components > Application Compatibility) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' `
            -Name 'DisableInventory' -Value 1

        # -- File Explorer (WindowsExplorer.admx) --
        # NOTE: DisableThumbsDBOnNetworkFolders removed from W11 WindowsExplorer.admx - no ADMX backing.

        # -- File History (AT: Computer Configuration > Windows Components > File History) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\FileHistory' `
            -Name 'Disabled' -Value 1

        # -- Find My Device (AT: Computer Configuration > Windows Components > Find My Device) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice' `
            -Name 'AllowFindMyDevice' -Value 0

        # -- HomeGroup (AT: Computer Configuration > Windows Components > HomeGroup) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\HomeGroup' `
            -Name 'DisableHomeGroup' -Value 1

        # -- RSS Feeds: disable background sync (AT: Computer Configuration > Windows Components > RSS Feeds) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\Feeds' `
            -Name 'BackgroundSyncStatus' -Value 0

        # -- Storage Health (AT: Computer Configuration > System > Storage Health) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageHealth' `
            -Name 'AllowDiskHealthModelUpdates' -Value 0

        # -- Power: disable desktop background slideshow on AC (Power.admx) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\309dce9b-bef4-4119-9921-a851fb12f0f4' `
            -Name 'ACSettingIndex' -Value 0

        # -- Storage Sense (StorageSense.admx) - enabled intentionally; see README --
        $ssPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'
        Set-PolicyValue -Path $ssPolicyPath -Name 'AllowStorageSenseGlobal' -Value 1
        Set-PolicyValue -Path $ssPolicyPath -Name 'ConfigStorageSenseGlobalCadence' -Value 30
        Set-PolicyValue -Path $ssPolicyPath -Name 'AllowStorageSenseTemporaryFilesCleanup' -Value 1
        Set-PolicyValue -Path $ssPolicyPath -Name 'ConfigStorageSenseRecycleBinCleanupThreshold' -Value 0
        Set-PolicyValue -Path $ssPolicyPath -Name 'ConfigStorageSenseDownloadsCleanupThreshold' -Value 0
        Set-PolicyValue -Path $ssPolicyPath -Name 'ConfigStorageSenseCloudContentDehydrationThreshold' -Value 30

        # -- System Restore (AT: Computer Configuration > System > System Restore) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' `
            -Name 'DisableSR' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' `
            -Name 'DisableConfig' -Value 1

        # -- Windows Recovery Environment (ReAgent.admx) --
        # Prevents users from using WinRE to reset/reinstall the OS on a managed image.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRE' `
            -Name 'DisableSetup' -Value 1

        # -- Toast / push notifications (AT: Computer Configuration > Windows Components > Push Notifications) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' `
            -Name 'NoCloudApplicationNotification' -Value 1

        # -- Windows Mobility Center (AT: Computer Configuration > Windows Components > Windows Mobility Center) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\MobilityCenter' `
            -Name 'NoMobilityCenter' -Value 1

        # -- Windows Installer (AT: Computer Configuration > Windows Components > Windows Installer) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' `
            -Name 'MaxPatchCacheSize' -Value 5
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' `
            -Name 'LimitSystemRestoreCheckpointing' -Value 1

        # -- Windows Reliability Analysis (AT: Computer Configuration > System > Troubleshooting and Diagnostics > Windows Performance) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Reliability Analysis\WMI' `
            -Name 'WMIEnable' -Value 0

        # -- Windows Security: suppress non-critical notifications (AT: Computer Configuration > Windows Components > Windows Security > Notifications) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' `
            -Name 'DisableEnhancedNotifications' -Value 1

        # -- Windows Update - NOTE: ManagePreviewBuilds removed (no valid ADMX state; see README) --

        # -- Software Protection Platform (AVSValidationGP.admx) --
        # NoAcquireGT: prevents contacting Microsoft activation servers for a grace ticket.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform' `
            -Name 'NoGenTicket' -Value 1

        # -- Help and Support: disable active help links (HelpAndSupport.admx) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Assistance\Client\1.0' `
            -Name 'NoActiveHelp' -Value 1

        # -- IIS: prevent installation (IIS.admx) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\IIS' `
            -Name 'PreventIISInstall' -Value 1

        # -- IE: disable feed discovery (inetres.admx) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\Feed Discovery' `
            -Name 'Enabled' -Value 0

        # -- Control Panel: disable online tips --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
            -Name 'AllowOnlineTips' -Value 0

        # -- Device Installation (DeviceSetup.admx, DeviceManager.admx) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings' `
            -Name 'DisableSendGenericDriverNotFoundToWER' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings' `
            -Name 'DisableSystemRestore' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings' `
            -Name 'DisableBalloonTips' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' `
            -Name 'PreventDeviceMetadataFromNetwork' -Value 1
        # DontSearchWindowsUpdate: drivers must come from the image or enterprise management
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' `
            -Name 'DontSearchWindowsUpdate' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' `
            -Name 'SearchOrderConfig' -Value 0

        # -- Edge UI (AT: Computer Configuration > Windows Components > Edge UI) --
        # Ref: Article local policy table - Edge UI
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI' `
            -Name 'AllowEdgeSwipe' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI' `
            -Name 'DisableHelpSticker' -Value 1

        # -- File Explorer: suppress "new application installed" association balloon (AT: Computer Configuration > Windows Components > File Explorer) --
        # Ref: Article local policy table - File Explorer
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' `
            -Name 'NoNewAppAlert' -Value 1

        # -- Internet Communication Management (ICM.admx) --
        $legacyExplorer = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
        Set-PolicyValue -Path $legacyExplorer -Name 'NoPublishingWizard' -Value 1
        Set-PolicyValue -Path $legacyExplorer -Name 'NoWebServices' -Value 1
        Set-PolicyValue -Path $legacyExplorer -Name 'NoInternetOpenWith' -Value 1
        Set-PolicyValue -Path $legacyExplorer -Name 'NoOnlinePrintsWizard' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Registration Wizard Control' `
            -Name 'NoRegistration' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Internet Connection Wizard' `
            -Name 'ExitOnMSICW' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\SearchCompanion' `
            -Name 'DisableContentFileUpdates' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\PCHealth\HelpSvc' `
            -Name 'MicrosoftKBSearch' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\PCHealth\ErrorReporting' `
            -Name 'DoReport' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' `
            -Name 'CEIPEnable' -Value 0

        # -- Logon settings (Logon.admx) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'DontEnumerateConnectedUsers' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'EnumerateLocalUsers' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'DisableLockScreenAppNotifications' -Value 1

        # -- Peer-to-Peer / Online Assistance - NOTE: no ADMX backing on W11; omitted. --

        # -- Troubleshooting and Diagnostics (sdiageng.admx, PerformanceDiagnostics.admx, etc.) --
        # Disable Scheduled Maintenance troubleshooting
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\ScheduledDiagnostics' `
            -Name 'EnabledExecution' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\ScriptedDiagnostics' `
            -Name 'EnableDiagnostics' -Value 0
        # BetterWhenConnected (sdiageng.admx): stops fetching troubleshooting content from Microsoft
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\ScriptedDiagnosticsProvider\Policy' `
            -Name 'EnableQueryRemoteServer' -Value 0
        # WDI per-scenario diagnostics (PerformanceDiagnostics.admx, Radar.admx, LeakDiagnostic.admx)
        $wdiBase = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WDI'
        Set-PolicyValue -Path "$wdiBase\{67144949-5132-4859-8036-a737b43825d8}" -Name 'ScenarioExecutionEnabled' -Value 0
        Set-PolicyValue -Path "$wdiBase\{86432a0b-3c7d-4ddf-a89c-172faa90485d}" -Name 'ScenarioExecutionEnabled' -Value 0
        Set-PolicyValue -Path "$wdiBase\{2698178D-FDAD-40AE-9D3C-1371703ADC5B}" -Name 'ScenarioExecutionEnabled' -Value 0
        Set-PolicyValue -Path "$wdiBase\{ffc42108-4920-4acf-a4fc-8abdcc68ada4}" -Name 'ScenarioExecutionEnabled' -Value 0
        Set-PolicyValue -Path "$wdiBase\{a7a5847a-7511-4e4e-90b1-45ad2a002f51}" -Name 'ScenarioExecutionEnabled' -Value 0
        Set-PolicyValue -Path "$wdiBase\{186f47ef-626c-4670-800a-4a30756babad}" -Name 'ScenarioExecutionEnabled' -Value 0
        Set-PolicyValue -Path "$wdiBase\{ecfb03d1-58ee-4cc7-a1b5-9bc6febcb915}" -Name 'ScenarioExecutionEnabled' -Value 0
        Set-PolicyValue -Path "$wdiBase\{3af8b24a-c441-4fa4-8c5c-bed591bfa867}" -Name 'ScenarioExecutionEnabled' -Value 0
        # LeakDiagnostic.admx: disabledList also sets EnabledScenarioExecutionLevel=1
        Set-PolicyValue -Path "$wdiBase\{eb73b633-3f4e-4ba0-8f60-8f3c6f53168f}" -Name 'ScenarioExecutionEnabled' -Value 0
        Set-PolicyValue -Path "$wdiBase\{eb73b633-3f4e-4ba0-8f60-8f3c6f53168f}" -Name 'EnabledScenarioExecutionLevel' -Value 1

        Invoke-ApplyPolicyQueue
        Write-Log ""
    } # end if RunFullOptimization - Section 5

    # -----------------------------------------------------------------------
    # SECTION 6 - Registry / Policy Settings: NonPersistent Only
    # -----------------------------------------------------------------------
    if ($RunNonPersistentSections) {
        Write-Log "--- Section 6: Registry / Policy Settings (NonPersistent Only) ---"

        # -- ADMX Templates: install from internet or version folder (non-fatal) --
        # Classifies Registry.pol entries as Administrative Templates (not Extra Registry Settings)
        # in gpresult on deployed VMs. Each sub-step is try/catch-wrapped; failures are non-fatal.
        Write-Log "  [ADMX] Installing ADMX templates for Edge, Office 365, and OneDrive..."

        # Edge ADMX - download policy CAB from the Edge updates API
        if (-not (Test-Path "$env:SystemRoot\PolicyDefinitions\msedge.admx")) {
            try {
                Write-Log "  [ADMX] msedge.admx not found - attempting download from Edge updates API..."
                $admxTmp = Join-Path $env:TEMP 'EdgeADMX'
                New-Item -Path $admxTmp -ItemType Directory -Force | Out-Null
                $apiContent = (Invoke-WebRequest -Uri 'https://edgeupdates.microsoft.com/api/products?view=enterprise' -UseBasicParsing).Content |
                    ConvertFrom-Json
                $stableRel = ($apiContent | Where-Object { $_.Product -eq 'Stable' }).releases |
                    Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq 'x64' } |
                    Sort-Object ProductVersion | Select-Object -Last 1
                $policyRel = ($apiContent | Where-Object { $_.Product -eq 'Policy' }).releases |
                    Where-Object { $_.ProductVersion -eq $stableRel.ProductVersion }
                if (-not $policyRel) {
                    $policyRel = ($apiContent | Where-Object { $_.Product -eq 'Policy' }).releases |
                        Sort-Object ProductVersion | Select-Object -Last 1
                }
                $cabUrl = $policyRel.artifacts.Location
                $cabPath = Join-Path $admxTmp 'MicrosoftEdgePolicyTemplates.cab'
                (New-Object System.Net.WebClient).DownloadFile($cabUrl, $cabPath)
                $templatesDir = Join-Path $admxTmp 'Templates'
                New-Item -Path $templatesDir -ItemType Directory -Force | Out-Null
                & cmd /c extrac32 /Y /E "$cabPath" /L "$templatesDir" | Out-Null
                $edgeZip = Get-ChildItem -Path $templatesDir -Filter '*.zip' -Recurse |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($edgeZip) {
                    Expand-Archive -Path $edgeZip.FullName -DestinationPath $templatesDir -Force
                    Get-ChildItem -Path $templatesDir -File -Recurse -Filter '*.admx' |
                        ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:SystemRoot\PolicyDefinitions\" -Force }
                    Get-ChildItem -Path $templatesDir -Directory -Recurse |
                        Where-Object { $_.Name -eq 'en-us' } |
                        Get-ChildItem -File -Recurse -Filter '*.adml' |
                        ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:SystemRoot\PolicyDefinitions\en-us\" -Force }
                    Write-Log "  [ADMX] [OK] Edge policy templates installed (msedge.admx)."
                } else {
                    Write-Log "  [ADMX] [WARN] No ZIP found in expanded Edge policy CAB - templates not installed."
                }
                Remove-Item -Path $admxTmp -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Log "  [ADMX] [WARN] Edge ADMX download/install failed: $_ (non-fatal)"
            }
        } else {
            Write-Log "  [ADMX] msedge.admx already present - skipping Edge download."
        }

        # Office 365 ADMX - download administrative templates EXE from Microsoft
        $officeAdmxPaths = @(
            "$env:SystemRoot\PolicyDefinitions\office16.admx",
            "$env:SystemRoot\PolicyDefinitions\outlk16.admx"
        )
        $officeAdmxMissing = $officeAdmxPaths | Where-Object { -not (Test-Path $_) }
        if ($officeAdmxMissing) {
            try {
                Write-Log "  [ADMX] Office ADMX missing ($($officeAdmxMissing | Split-Path -Leaf)) - attempting download..."
                $admxTmp = Join-Path $env:TEMP 'OfficeADMX'
                New-Item -Path $admxTmp -ItemType Directory -Force | Out-Null
                $dlPage = (Invoke-WebRequest -Uri 'https://www.microsoft.com/en-us/download/details.aspx?id=49030' -UseBasicParsing).Content
                $exeUrl = ([regex]::Matches($dlPage, 'https://[^"''>\s]+admintemplates_x64[^"''>\s]+\.exe')).Value |
                    Select-Object -First 1
                if ($exeUrl) {
                    $exePath = Join-Path $admxTmp 'admintemplates_x64.exe'
                    (New-Object System.Net.WebClient).DownloadFile($exeUrl, $exePath)
                    $templatesDir = Join-Path $admxTmp 'Templates'
                    New-Item -Path $templatesDir -ItemType Directory -Force | Out-Null
                    Start-Process -FilePath $exePath -ArgumentList "/extract:$templatesDir /quiet" -Wait
                    Get-ChildItem -Path $templatesDir -File -Recurse -Filter '*.admx' |
                        ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:SystemRoot\PolicyDefinitions\" -Force }
                    Get-ChildItem -Path $templatesDir -Directory -Recurse |
                        Where-Object { $_.Name -eq 'en-us' } |
                        Get-ChildItem -File -Recurse -Filter '*.adml' |
                        ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:SystemRoot\PolicyDefinitions\en-us\" -Force }
                    Write-Log "  [ADMX] [OK] Office 365 policy templates installed."
                } else {
                    Write-Log "  [ADMX] [WARN] Could not resolve Office 365 ADMX download URL (non-fatal)."
                }
                Remove-Item -Path $admxTmp -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Log "  [ADMX] [WARN] Office ADMX download/install failed: $_ (non-fatal)"
            }
        } else {
            Write-Log "  [ADMX] Office ADMX already present - skipping Office download."
        }

        # OneDrive ADMX - copy from the installed OneDrive version folder (no download needed)
        # Check specifically for GPOSetUpdateRing in the ADMX rather than just file presence:
        # Windows 11 ships an inbox OneDrive.admx that does NOT contain GPOSetUpdateRing.
        # The standalone OneDrive ADMX (from the OneDrive install directory) does contain it.
        $odAdmxPath = "$env:SystemRoot\PolicyDefinitions\OneDrive.admx"
        $odAdmxHasUpdateRing = (Test-Path $odAdmxPath) -and ((Get-Content $odAdmxPath -Raw) -like '*GPOSetUpdateRing*')
        if (-not $odAdmxHasUpdateRing) {
            try {
                # Machine-wide install: C:\Program Files\Microsoft OneDrive\<ver>\adm\
                # Per-user install:    C:\Program Files (x86)\Microsoft OneDrive\<ver>\
                $odInstallDir = if (Test-Path "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe") {
                    "$env:ProgramFiles\Microsoft OneDrive"
                } else {
                    "${env:ProgramFiles(x86)}\Microsoft OneDrive"
                }
                $odExe = Join-Path $odInstallDir 'OneDrive.exe'
                if (Test-Path $odExe) {
                    $odVersion    = (Get-ItemProperty $odExe).VersionInfo.ProductVersion
                    $odVersionDir = Join-Path $odInstallDir $odVersion
                    $odSearchDir  = if (Test-Path $odVersionDir) { $odVersionDir } else { $odInstallDir }
                    $odAdmxFiles  = Get-ChildItem -Path $odSearchDir -File -Recurse -Filter '*.admx' -ErrorAction SilentlyContinue
                    if ($odAdmxFiles) {
                        $odAdmxFiles | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:SystemRoot\PolicyDefinitions\" -Force }
                        $admlFiles = Get-ChildItem -Path $odSearchDir -File -Recurse -Filter '*.adml' -ErrorAction SilentlyContinue |
                            Where-Object { $_.Directory.Name -eq 'en-us' -or $_.Directory.Name -eq 'en' -or (Get-ChildItem -Path $_.DirectoryName -Filter '*.admx' -ErrorAction SilentlyContinue) }
                        if ($admlFiles) {
                            $admlFiles | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:SystemRoot\PolicyDefinitions\en-us\" -Force }
                        }
                        Write-Log "  [ADMX] [OK] OneDrive ADMX copied from '$odSearchDir' (version $odVersion)."
                    } else {
                        Write-Log "  [ADMX] [WARN] No ADMX files found under '$odSearchDir' (non-fatal)."
                    }
                } else {
                    Write-Log "  [ADMX] [SKIP] OneDrive not installed at '$odInstallDir'."
                }
            } catch {
                Write-Log "  [ADMX] [WARN] OneDrive ADMX copy failed: $_ (non-fatal)"
            }
        } else {
            Write-Log "  [ADMX] OneDrive.admx already present with GPOSetUpdateRing - skipping OneDrive copy."
        }

        Write-Log ""

        # Override telemetry to 0 for NonPersistent VMs (transient; no per-VM diagnostic value).
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' `
            -Name 'AllowTelemetry' -Value 0

        # -- WER - disabled NonPersistent only; transient VMs discard crash data at recycle --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' `
            -Name 'Disabled' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' `
            -Name 'DontSendAdditionalData' -Value 1

        # -- Windows Update: disabled NonPersistent; OS updates via image replacement --
        # NoAutoUpdate=1: AutoUpdateCfg policy Disabled state (WindowsUpdate.admx)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
            -Name 'NoAutoUpdate' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
            -Name 'SetDisableUXWUAccess' -Value 1

        # -- Update channel lockdown (NonPersistent only; Persistent managed by SCCM/Intune) --

        # M365 / Office Click-to-Run
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' `
            -Name 'enableautomaticupdates' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' `
            -Name 'hideupdatenotifications' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' `
            -Name 'hideenabledisableupdates' -Value 1

        # Teams: disableAutoUpdate=1 prevents MSIX bootstrapper self-update (non-ADMX vendor key).
        # Note: TMA must be deployed separately when this key is present (see README).
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Teams' `
            -Name 'disableAutoUpdate' -Value 1

        # OneDrive: Enterprise ring (0) = slowest channel, ~60 day lag (OneDrive.admx).
        # Note: GPOSetUpdateRing is not in inbox OneDrive.admx; requires standalone ADMX (see ADMX pre-step).
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' `
            -Name 'GPOSetUpdateRing' -Value 0

        # Edge / WebView2: UpdateDefault=0 blocks all updates via EdgeUpdate service
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' `
            -Name 'UpdateDefault' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' `
            -Name 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' `
            -Name 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -Value 0

        # Store: AutoDownload=2 disables automatic app download/update
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' `
            -Name 'AutoDownload' -Value 2

        # NOTE: OptimalLayout.admx removed from W11 PolicyDefinitions - EnableAutoLayout omitted.
        # SysMain disabled in Section 2 disables the layout optimizer it depends on.

        # Prefetcher / Superfetch - SSD-backed disks + pooled mixed workloads reduce prefetch value
        $prefetchPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'
        Set-PolicyValue -Path $prefetchPath -Name 'EnablePrefetcher' -Value 0
        Set-PolicyValue -Path $prefetchPath -Name 'EnableSuperfetch' -Value 0

        Invoke-ApplyPolicyQueue
        Write-Log ""
    }

    # -----------------------------------------------------------------------
    # SECTION 7 - Air-Gapped / Restricted Network Settings
    # Applied when -AirGapped is true. Disables Windows components that make
    # outbound calls to Microsoft cloud services, causing timeouts and latency
    # in environments with no internet access. Applies to all profiles,
    # including None.
    # Ref: [2] Windows Restricted Traffic Baseline
    # -----------------------------------------------------------------------
    if ($AirGappedBool) {
        Write-Log "--- Section 7: Air-Gapped / Restricted Network Settings ---"

        # NCSI passive polling disabled - SKIP (breaks network awareness APIs; see README)
        # Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator' -Name 'DisablePassivePolling' -Value 1

        # Font providers (ICM.admx - System key)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'EnableFontProviders' -Value 0

        # Teredo (TCPIP.admx)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TCPIP\v6Transition' `
            -Name 'Teredo_State' -Value 'Disabled' `
            -Type ([Microsoft.Win32.RegistryValueKind]::String)

        # SmartScreen - Explorer (SmartScreen.admx) and Edge (Edge.admx)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'EnableSmartScreen' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' `
            -Name 'SmartScreenEnabled' -Value 0

        # Defender MAPS / cloud lookups (WindowsDefender.admx - Spynet)
        # SpynetReporting: 0=Disabled; SubmitSamplesConsent: 2=Never Send; BAFS: 1=Disable
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' `
            -Name 'SpynetReporting' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' `
            -Name 'SubmitSamplesConsent' -Value 2
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' `
            -Name 'DisableBlockAtFirstSeen' -Value 1

        # WER Watson uploads (WindowsErrorReporting.admx); NonPersistent: WerSvc off (S2)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' `
            -Name 'Disabled' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' `
            -Name 'DontSendAdditionalData' -Value 1

        # DiagTrack service - NonPersistent: disabled in Section 2
        Disable-VdiService -Name 'DiagTrack' -DisplayName 'Connected User Experiences and Telemetry'

        # OneSettings - prevents DiagTrack pulling dynamic config (DataCollection.admx)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' `
            -Name 'DisableOneSettingsDownloads' -Value 1

        # Cross-device clipboard sync (OSPolicy.admx)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'AllowCrossDeviceClipboard' -Value 0

        # Widgets / News and Interests (NewsAndInterests.admx)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' `
            -Name 'AllowNewsAndInterests' -Value 0

        # Settings sync across devices (SettingSync.admx); enabledValue=2 disables sync
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync' `
            -Name 'DisableSettingSync' -Value 2
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync' `
            -Name 'DisableSettingSyncUserOverride' -Value 1

        # Activity Feed upload (OSPolicy.admx) - stops cloud send; local feed kept intact
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'UploadUserActivities' -Value 0

        # Connected Devices Platform / Continue Experiences (GroupPolicy.admx)
        # Disables CDP cross-device handoff, Near Share, and Phone Link cloud coordination
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'EnableCdp' -Value 0

        Invoke-ApplyPolicyQueue
        Write-Log ""
    } # end if AirGapped - Section 7

    # -----------------------------------------------------------------------
    # SECTION 8 - Default User Profile Settings
    # Applied to C:\Users\Default\NTUSER.DAT so that every new user session
    # created from this image inherits the performance and privacy settings.
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 8: Default User Profile Settings ---"

        $defaultHivePath = 'C:\Users\Default\NTUSER.DAT'
        $hiveMounted = $false

        if (Test-Path $defaultHivePath) {
            try {
                # Load the default user hive under a temporary HKLM key
                $loadResult = & reg.exe load 'HKLM\TempDefaultUser' $defaultHivePath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "reg.exe load returned exit code $LASTEXITCODE - $loadResult"
                }
                $hiveMounted = $true
                Write-Log "  Default user hive mounted at HKLM:\TempDefaultUser"

                $du = 'HKLM:\TempDefaultUser'

                # -- Visual effects: Custom (performance-oriented) --
                # VisualFXSetting 3 = Custom; specific items controlled via Advanced keys
                Set-PolicyValue -Path "$du\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" `
                    -Name 'VisualFXSetting' -Value 3

                # ShellState binary - suppress animations in Explorer shell
                $shellState = [byte[]](0x24, 0x00, 0x00, 0x00, 0x3C, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
                Set-ItemProperty -Path "$du\Software\Microsoft\Windows\CurrentVersion\Explorer" `
                    -Name 'ShellState' -Value $shellState -Type Binary -Force -ErrorAction SilentlyContinue
                Write-Log "  [OK]   Registry: ShellState (Binary)"

                # UserPreferencesMask - control visual effect checkboxes
                # 0x9032078010000000: shadows under mouse, smooth fonts; disable most animations
                $prefMask = [byte[]](0x90, 0x32, 0x07, 0x80, 0x10, 0x00, 0x00, 0x00)
                Set-ItemProperty -Path "$du\Control Panel\Desktop" `
                    -Name 'UserPreferencesMask' -Value $prefMask -Type Binary -Force -ErrorAction SilentlyContinue
                Write-Log "  [OK]   Registry: UserPreferencesMask (Binary)"

                # Explorer Advanced display options
                $explorerAdv = "$du\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
                Set-PolicyValue -Path $explorerAdv -Name 'IconsOnly' -Value 1
                Set-PolicyValue -Path $explorerAdv -Name 'ListviewAlphaSelect' -Value 0
                Set-PolicyValue -Path $explorerAdv -Name 'ListviewShadow' -Value 0
                Set-PolicyValue -Path $explorerAdv -Name 'ShowCompColor' -Value 1
                Set-PolicyValue -Path $explorerAdv -Name 'ShowInfoTip' -Value 1
                Set-PolicyValue -Path $explorerAdv -Name 'TaskbarAnimations' -Value 0

                # Desktop - window drag, font smoothing, animation
                Set-PolicyValue -Path "$du\Control Panel\Desktop" `
                    -Name 'DragFullWindows' -Value '0' `
                    -Type ([Microsoft.Win32.RegistryValueKind]::String)
                Set-PolicyValue -Path "$du\Control Panel\Desktop" `
                    -Name 'FontSmoothing' -Value '2' `
                    -Type ([Microsoft.Win32.RegistryValueKind]::String)
                Set-PolicyValue -Path "$du\Control Panel\Desktop\WindowMetrics" `
                    -Name 'MinAnimate' -Value '0' `
                    -Type ([Microsoft.Win32.RegistryValueKind]::String)

                # DWM - disable Aero Peek and thumbnail caching
                Set-PolicyValue -Path "$du\Software\Microsoft\Windows\DWM" `
                    -Name 'EnableAeroPeek' -Value 0
                Set-PolicyValue -Path "$du\Software\Microsoft\Windows\DWM" `
                    -Name 'AlwaysHiberNateThumbnails' -Value 0

                # Content Delivery Manager - disable suggested / pre-installed apps and tips
                $cdmPath = "$du\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
                Set-PolicyValue -Path $cdmPath -Name 'ContentDeliveryAllowed' -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'OemPreInstalledAppsEnabled' -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'PreInstalledAppsEnabled' -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SilentInstalledAppsEnabled' -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SubscribedContentEnabled' -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SoftLandingEnabled' -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SystemPaneSuggestionsEnabled' -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SubscribedContent-338393Enabled' -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SubscribedContent-353694Enabled' -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SubscribedContent-353696Enabled' -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SubscribedContent-338388Enabled' -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SubscribedContent-338389Enabled' -Value 0

                # Privacy - opt out of language-based content and settings suggestions
                Set-PolicyValue -Path "$du\Control Panel\International\User Profile" `
                    -Name 'HttpAcceptLanguageOptOut' -Value 1

                # User Profile Engagement - suppress SCOOBE (Settings welcome experience)
                Set-PolicyValue -Path "$du\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" `
                    -Name 'ScoobeSystemSettingEnabled' -Value 0

        # == User Configuration policies (default user hive) ==
        # Mirrors "Local Computer Policy > User Configuration" from the VDI article.
        # Two Cloud Content policies have no machine equivalent:
        #   ConfigureWindowsSpotlight and DisableTailoredExperiencesWithDiagnosticData.

                # -- Cloud Content (User Configuration - CloudContent.admx) --
                $duCloudContent = "$du\Software\Policies\Microsoft\Windows\CloudContent"
                Set-PolicyValue -Path $duCloudContent -Name 'DisableWindowsSpotlightFeatures' -Value 1
                Set-PolicyValue -Path $duCloudContent -Name 'DisableThirdPartySuggestions' -Value 1
                # DisableTailoredExperiencesWithDiagnosticData: User Config only - no machine equivalent
                Set-PolicyValue -Path $duCloudContent -Name 'DisableTailoredExperiencesWithDiagnosticData' -Value 1
                # ConfigureWindowsSpotlight: User Config only; 2=Disabled
                Set-PolicyValue -Path $duCloudContent -Name 'ConfigureWindowsSpotlight' -Value 2
                Set-PolicyValue -Path $duCloudContent -Name 'IncludeEnterpriseSpotlight' -Value 0

                # -- Start Menu / Taskbar (User Configuration) --
                $duLegacyExplorer = "$du\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
                Set-PolicyValue -Path $duLegacyExplorer -Name 'NoInstrumentation' -Value 1
                Set-PolicyValue -Path $duLegacyExplorer -Name 'NoRecentDocsNetHood' -Value 1
                Set-PolicyValue -Path $duLegacyExplorer -Name 'NoSearchInternetInStartMenu' -Value 1
                Set-PolicyValue -Path $duLegacyExplorer -Name 'NoResolveSearch' -Value 1
                Set-PolicyValue -Path $duLegacyExplorer -Name 'TurnOffSPIAnimations' -Value 1

                $duExplorer = "$du\Software\Policies\Microsoft\Windows\Explorer"
                Set-PolicyValue -Path $duExplorer -Name 'NoRemoteDestinations' -Value 1
                Set-PolicyValue -Path $duExplorer -Name 'NoWindowMinimizingShortcuts' -Value 1
                Set-PolicyValue -Path $duLegacyExplorer -Name 'TaskbarNoNotification' -Value 1
                Set-PolicyValue -Path $duExplorer -Name 'NoBalloonFeatureAdvertisements' -Value 1

                $duPushNotify = "$du\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"
                Set-PolicyValue -Path $duPushNotify -Name 'NoToastApplicationNotification' -Value 1
                Set-PolicyValue -Path $duPushNotify -Name 'NoToastApplicationNotificationOnLockScreen' -Value 1

                # -- Desktop (User Configuration) --
                # QueryLimit=1500: limits AD query results to avoid long-running LDAP searches
                Set-PolicyValue -Path "$du\Software\Policies\Microsoft\Windows\Directory UI" `
                    -Name 'QueryLimit' -Value 1500

                # -- Edge UI (User Configuration) --
                Set-PolicyValue -Path "$du\Software\Policies\Microsoft\Windows\EdgeUI" `
                    -Name 'DisableMFUTracking' -Value 1

                # -- Control Panel (User Configuration - Globalization.admx) --
                Set-PolicyValue -Path "$du\Software\Policies\Microsoft\Control Panel\International" `
                    -Name 'TurnOffOfferTextPredictions' -Value 1

                # -- File Explorer (User Configuration) --
                # NOTE: DisableThumbsDBOnNetworkFolders removed from W11 WindowsExplorer.admx
                Set-PolicyValue -Path $duLegacyExplorer -Name 'DisableThumbnails' -Value 1
                Set-PolicyValue -Path $duLegacyExplorer -Name 'NoThumbnailCache' -Value 1
                Set-PolicyValue -Path $duExplorer -Name 'DisableSearchBoxSuggestions' -Value 1

                Invoke-ApplyPolicyQueue
                Write-Log "  Default user profile settings applied"
            }
            catch {
                Write-Log "  [WARN] Error applying default user profile settings - $_"
            }
            finally {
                if ($hiveMounted) {
                    # Force garbage collection to release any PowerShell handles before unloading
                    [System.GC]::Collect()
                    [System.GC]::WaitForPendingFinalizers()
                    Start-Sleep -Seconds 2
                    $unloadResult = & reg.exe unload 'HKLM\TempDefaultUser' 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "  Default user hive unloaded successfully"
                    }
                    else {
                        Write-Log "  [WARN] Could not unload default user hive (may leave a stale mount): $unloadResult"
                    }
                }
            }
        }
        else {
            Write-Log "  [SKIP] Default user hive not found at $defaultHivePath"
        }

        Write-Log ""
    } # end if RunFullOptimization - Section 8

    # -----------------------------------------------------------------------
    # SECTION 9 - Network Performance Tuning (LanManWorkstation / SMB client)
    # Improves SMB client performance for profile share and application data
    # access across the network in VDI environments.
    # Reference: https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 9: Network Performance Tuning (LanManWorkstation) ---"

        # LanMan/SMB client tuning
        $lanman = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
        Set-PolicyValue -Path $lanman -Name 'DisableBandwidthThrottling' -Value 1
        Set-PolicyValue -Path $lanman -Name 'FileInfoCacheEntriesMax' -Value 1024
        Set-PolicyValue -Path $lanman -Name 'DirectoryCacheEntriesMax' -Value 1024
        Set-PolicyValue -Path $lanman -Name 'FileNotFoundCacheEntriesMax' -Value 2048
        Set-PolicyValue -Path $lanman -Name 'DormantFileLimit' -Value 256

        Write-Log ""
    } # end if RunFullOptimization - Section 9

    # -----------------------------------------------------------------------
    # SECTION 10 - Autologgers (Windows Startup Event Trace Sessions)
    # Disable diagnostic traces that serve no purpose in a managed VDI image.
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 10: Autologgers ---"

        $autologgers = [System.Collections.Generic.List[string]]@(
            'Cellcore',                 # Cellular architecture trace
            'CloudExperienceHostOOBE',  # OOBE cloud experience trace
            'DiagLog',                  # Diagnostic Policy Service log
            'RadioMgr',                 # NFC/radio manager trace
            'ReadyBoot',                # Boot prefetch analysis
            'WDIContextLog',            # WDI miniport driver trace
            'WiFiDriverIHVSession',     # WLAN IHV diagnostic session
            'WiFiSession',              # WLAN diagnostic log - no Wi-Fi hardware in VMs
            'WinPhoneCritical'          # Phone diagnostic log - no phone hardware in VMs
        )

        foreach ($logger in $autologgers) {
            Disable-VdiAutologger -Name $logger
        }

        Write-Log ""
    } # end if RunFullOptimization - Section 10

    # -----------------------------------------------------------------------
    # SECTION 11 - Optional Windows Features
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 11: Optional Windows Features ---"

        $featuresToDisable = @(
            @{ Name = 'WindowsMediaPlayer'; Label = 'Windows Media Player' },
            @{ Name = 'WorkFolders-Client'; Label = 'Work Folders Client' },
            @{ Name = 'Printing-XPSServices-Features'; Label = 'XPS Viewer / Services' }
        )

        foreach ($feature in $featuresToDisable) {
            $featureState = Get-WindowsOptionalFeature -Online -FeatureName $feature.Name `
                -ErrorAction SilentlyContinue
            if ($null -eq $featureState) {
                Write-Log "  [SKIP] Optional feature not found: $($feature.Label) ($($feature.Name))"
                continue
            }
            if ($featureState.State -ne 'Enabled') {
                Write-Log "  [SKIP] Optional feature already disabled: $($feature.Label)"
                continue
            }
            try {
                Disable-WindowsOptionalFeature -Online -FeatureName $feature.Name `
                    -NoRestart -ErrorAction Stop | Out-Null
                Write-Log "  [OK]   Disabled optional feature: $($feature.Label)"
            }
            catch {
                Write-Log "  [WARN] Could not disable $($feature.Label) - $_"
            }
        }

        Write-Log ""
    } # end if RunFullOptimization - Section 11

    Write-Log "============================================================"
    Write-Log "  Optimize-AVDImage Complete"
    Write-Log "  Profile: $OptimizationProfile | AirGapped: $AirGappedBool"
    Write-Log "  Log: $LogFile"
    Write-Log "============================================================"
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    throw
}
