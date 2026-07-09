<#
.SYNOPSIS
    Configures a custom desktop background for Azure Virtual Desktop session hosts.

.DESCRIPTION
    Copies the background image included in this artifact package to
    C:\Windows\Web\Wallpaper\Custom\ and writes three User-scope Group Policy
    registry values directly to the local GPO Registry.pol file (no LGPO.exe,
    no COM objects, no internet access required):

      Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop
        NoChangingWallPaper = 1  (prevents users from changing the wallpaper)

      Software\Microsoft\Windows\CurrentVersion\Policies\System
        Wallpaper      = <path>  (path to the background image)
        WallpaperStyle = 4       (stretch / fill style; 4 = Stretch)

    The Registry.pol writer conforms to MS-GPREG (Group Policy: Registry Extension
    Encoding). gpt.ini is updated so the Group Policy client on deployed session hosts
    applies the entries at logon.

    WallpaperStyle values:
      0 = Center   1 = Tile    2 = Stretch   3 = No change
      4 = Stretch  6 = Fit     10 = Fill     22 = Span

    The script is designed to be used during Azure Virtual Desktop image customization or
    session host deployment.

.NOTES
    IMPORTANT: Custom Desktop Background Configuration

    Before using this artifact, replace the default 'sunrise.jpg' file in this directory
    with your custom desktop background image.

    Desktop Background Requirements:
    - File format: JPG (JPEG)
    - Resolution: High resolution (4K recommended - 3840x2560 pixels)
    - Aspect ratio: 3:2 (width:height)
    - File name: Must be named with the .jpg extension
    - File size: Consider file size for deployment efficiency
    
    For detailed guidance on desktop background configuration in enterprise environments,
    refer to the official Microsoft Learn documentation:
    https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/wallpaper-and-themes-windows-11
    
    Additional Considerations:
    - Ensure the image is appropriate for your organization's environment
    - Test the background across different monitor resolutions and aspect ratios
    - Consider accessibility and readability of desktop icons over the background
    - Verify compliance with your organization's branding guidelines

.EXAMPLE
    PS C:\> .\Set-DesktopBackground.ps1
    
    Configures the desktop background using the 'sunrise.jpg' file in the script directory.

.LINK
    https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/wallpaper-and-themes-windows-11
#>

#region Functions

function New-Log {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path
    )
    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    $date = Get-Date -UFormat '%Y-%m-%d %H-%M-%S'
    Set-Variable logFile -Scope Script
    $script:logFile = "$Script:Name-$date.log"
    if (-not (Test-Path $Path)) { $null = New-Item -Path $Path -ItemType Directory }
    $script:Log = Join-Path $Path $script:logFile
    Add-Content $script:Log "Date`t`t`tCategory`t`tDetails"
}

function Write-Log {
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('Info', 'Warning', 'Error')]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )
    $Content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if (-not $env:SUPPRESS_FILELOG) {
        Add-Content $script:Log $Content -ErrorAction SilentlyContinue
    }
    switch ($Category) {
        'Info'    { Write-Host $Content }
        'Error'   { Write-Error $Content -ErrorAction Continue }
        'Warning' { Write-Warning $Content }
    }
}

#endregion Functions

#region RegistryPol -- PReg direct writer (no LGPO.exe required)
<#
    Registry.pol (PReg) direct writer  -  no LGPO.exe, no COM objects required.
    Conforms to MS-GPREG v30.0.
    MS-GPREG spec: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpreg/

    PReg binary format:
        Header : "PReg" (4 ASCII bytes) + version 1 (uint32 LE) = 8 bytes
        Entry  : [<KeyPath>\0;<ValueName>\0;<Type4B>;<Size4B>;<Data>]
                 '[', ']', ';' are UTF-16LE single characters.
        Types  : 1=REG_SZ  4=REG_DWORD
        HKLM / HKCU MUST NOT appear in KeyPath per spec.

    Registry.pol locations:
        Machine : %SystemRoot%\System32\GroupPolicy\Machine\Registry.pol
        User    : %SystemRoot%\System32\GroupPolicy\User\Registry.pol
#>

$script:_PRegEnc = [System.Text.Encoding]::Unicode  # UTF-16LE

function Read-PRegFile {
    param ([string]$Path)
    $list = [System.Collections.Generic.List[hashtable]]::new()
    if (-not (Test-Path -LiteralPath $Path)) { return ,$list }
    $raw = [IO.File]::ReadAllBytes($Path)
    if ($raw.Length -lt 8) { return ,$list }
    $sig = [System.Text.Encoding]::ASCII.GetString($raw, 0, 4)
    $ver = [BitConverter]::ToUInt32($raw, 4)
    if ($sig -ne 'PReg' -or $ver -ne 1) {
        Write-Warning "RegistryPol: '$Path' has unexpected header (sig='$sig' ver=$ver). Existing entries discarded."
        return ,$list
    }
    $pos = 8
    while ($pos -lt $raw.Length) {
        if ($pos + 1 -ge $raw.Length) { break }
        if ($raw[$pos] -ne 0x5B -or $raw[$pos + 1] -ne 0x00) { $pos++; continue }
        $pos += 2
        $start = $pos
        while ($pos + 1 -lt $raw.Length -and -not ($raw[$pos] -eq 0 -and $raw[$pos + 1] -eq 0)) { $pos += 2 }
        $key = $script:_PRegEnc.GetString($raw, $start, $pos - $start); $pos += 2; $pos += 2
        $start = $pos
        while ($pos + 1 -lt $raw.Length -and -not ($raw[$pos] -eq 0 -and $raw[$pos + 1] -eq 0)) { $pos += 2 }
        $name = $script:_PRegEnc.GetString($raw, $start, $pos - $start); $pos += 2; $pos += 2
        $type = [BitConverter]::ToUInt32($raw, $pos); $pos += 4; $pos += 2
        $size = [BitConverter]::ToUInt32($raw, $pos); $pos += 4; $pos += 2
        $data = if ($size -gt 0) { $raw[$pos..($pos + $size - 1)] } else { [byte[]]@() }
        $pos += [int]$size; $pos += 2
        $list.Add(@{ Key = $key; Name = $name; Type = $type; Size = $size; Data = $data })
    }
    return ,$list
}

function Write-PRegFile {
    param (
        [string]$Path,
        [System.Collections.Generic.List[hashtable]]$Entries
    )
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $ms = [IO.MemoryStream]::new()
    $w  = [IO.BinaryWriter]::new($ms)
    $w.Write([System.Text.Encoding]::ASCII.GetBytes('PReg'))
    $w.Write([uint32]1)
    $bo = [byte[]](0x5B, 0x00); $bc = [byte[]](0x5D, 0x00)
    $sc = [byte[]](0x3B, 0x00); $nt = [byte[]](0x00, 0x00)
    foreach ($e in $Entries) {
        $w.Write($bo)
        $w.Write($script:_PRegEnc.GetBytes($e.Key));   $w.Write($nt); $w.Write($sc)
        $w.Write($script:_PRegEnc.GetBytes($e.Name));  $w.Write($nt); $w.Write($sc)
        $w.Write([uint32]$e.Type); $w.Write($sc)
        $w.Write([uint32]$e.Size); $w.Write($sc)
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
    param (
        [System.Collections.Generic.List[hashtable]]$Entries,
        [string]$Key, [string]$Name, [uint32]$Type, [byte[]]$Data
    )
    $old = @($Entries | Where-Object { $_.Key -ieq $Key -and $_.Name -ieq $Name })
    foreach ($e in $old) { $Entries.Remove($e) | Out-Null }
    $Entries.Add(@{ Key = $Key; Name = $Name; Type = $Type; Size = [uint32]$Data.Length; Data = $Data })
}

function ConvertTo-PRegDWord { param ([uint32]$Value); [BitConverter]::GetBytes($Value) }
function ConvertTo-PRegSZ    { param ([string]$Value);  $script:_PRegEnc.GetBytes($Value + [char]0) }

function Get-RelativePolicyKeyPath {
    param ([string]$Path)
    foreach ($prefix in @(
        'HKEY_LOCAL_MACHINE:\','HKEY_CURRENT_USER:\',
        'HKEY_LOCAL_MACHINE:','HKEY_CURRENT_USER:',
        'HKLM:\','HKCU:\','HKLM:','HKCU:'
    )) {
        if ($Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $Path.Substring($prefix.Length).TrimStart('\')
        }
    }
    return $Path
}

$script:_PolQueue = [System.Collections.Generic.List[hashtable]]::new()

function Set-PolicyRegistryValue {
    param (
        [Parameter(Mandatory)][ValidateSet('Computer','User')][string]$Scope,
        [Parameter(Mandatory)][string]$RegistryKeyPath,
        [Parameter(Mandatory)][string]$RegistryValue,
        [Parameter(Mandatory)][ValidateSet('DWORD','String','SZ')][string]$RegistryType,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RegistryData
    )
    $relPath   = Get-RelativePolicyKeyPath $RegistryKeyPath
    $typeCode  = if ($RegistryType -eq 'DWORD') { [uint32]4 } else { [uint32]1 }
    $dataBytes = if ($typeCode -eq 4) { ConvertTo-PRegDWord ([uint32]$RegistryData) } else { ConvertTo-PRegSZ $RegistryData }
    $script:_PolQueue.Add(@{ Scope=$Scope; Key=$relPath; Name=$RegistryValue; Type=$typeCode; Size=[uint32]$dataBytes.Length; Data=$dataBytes })
    Write-Log -Category Info -Message "RegistryPol: Queued [$Scope] $relPath\$RegistryValue ($RegistryType = $RegistryData)"
}

function Invoke-PolicyUpdate {
    if ($script:_PolQueue.Count -eq 0) { Write-Log -Category Info -Message 'RegistryPol: Queue is empty.'; return }

    $gpBase         = "$env:SystemRoot\System32\GroupPolicy"
    $machineQ       = @($script:_PolQueue | Where-Object { $_.Scope -eq 'Computer' })
    $userQ          = @($script:_PolQueue | Where-Object { $_.Scope -eq 'User' })
    $machineUpdated = $false
    $userUpdated    = $false

    foreach ($scope in @(
        @{ Queue=$machineQ; PolPath="$gpBase\Machine\Registry.pol"; IsUser=$false },
        @{ Queue=$userQ;    PolPath="$gpBase\User\Registry.pol";    IsUser=$true  }
    )) {
        if ($scope.Queue.Count -eq 0) { continue }
        $entries = Read-PRegFile -Path $scope.PolPath
        foreach ($q in $scope.Queue) {
            Set-PRegEntry -Entries $entries -Key $q.Key -Name $q.Name -Type $q.Type -Data $q.Data
        }
        Write-PRegFile -Path $scope.PolPath -Entries $entries
        Write-Log -Category Info -Message "RegistryPol: Wrote $($entries.Count) entries to '$($scope.PolPath)'."
        if ($scope.IsUser) { $userUpdated = $true } else { $machineUpdated = $true }
    }

    $script:_PolQueue.Clear()

    try {
        $gptPath   = "$gpBase\gpt.ini"
        $regCse    = '{35378EAC-683F-11D2-A89A-00C04FBBCFA2}'
        $machineAT = '{D02B1F72-3407-48AE-BA88-E8213C6761F1}'
        $userAT    = '{D02B1F73-3407-48AE-BA88-E8213C6761F1}'
        $existing  = if (Test-Path -LiteralPath $gptPath) { Get-Content $gptPath -Raw } else { '' }

        $machineVer = [uint16]1; $userVer = [uint16]1
        if ($existing -match 'Version\s*=\s*(\d+)') {
            $cur        = [uint32]$matches[1]
            $machineVer = [uint16]($cur -band 0xFFFF)
            $userVer    = [uint16](($cur -shr 16) -band 0xFFFF)
        }
        if ($machineUpdated) { $machineVer++ }
        if ($userUpdated)    { $userVer++ }
        $version = ([uint32]$userVer -shl 16) -bor [uint32]$machineVer

        $finalMachineExt = if ($machineUpdated) {
            $newExt = "[$regCse$machineAT]"
            if ($existing -match 'gPCMachineExtensionNames\s*=\s*(.+)') { $ev = $matches[1].Trim(); if ($ev -notlike "*$regCse*") { $ev + $newExt } else { $ev } } else { $newExt }
        } elseif ($existing -match 'gPCMachineExtensionNames\s*=\s*(.+)') { $matches[1].Trim() } else { '' }

        $finalUserExt = if ($userUpdated) {
            $newExt = "[$regCse$userAT]"
            if ($existing -match 'gPCUserExtensionNames\s*=\s*(.+)') { $ev = $matches[1].Trim(); if ($ev -notlike "*$regCse*") { $ev + $newExt } else { $ev } } else { $newExt }
        } elseif ($existing -match 'gPCUserExtensionNames\s*=\s*(.+)') { $matches[1].Trim() } else { '' }

        $gptContent = "[General]`r`n"
        if ($finalMachineExt) { $gptContent += "gPCMachineExtensionNames=$finalMachineExt`r`n" }
        if ($finalUserExt)    { $gptContent += "gPCUserExtensionNames=$finalUserExt`r`n" }
        $gptContent += "Version=$version`r`n"
        [IO.File]::WriteAllText($gptPath, $gptContent, [System.Text.Encoding]::ASCII)
        Write-Log -Category Info -Message "RegistryPol: gpt.ini written (Version=$version machine=$machineVer user=$userVer)."
    }
    catch {
        Write-Warning "RegistryPol: gpt.ini write failed: $_"
    }
}

#endregion RegistryPol

#region Main

[string]$Script:Name = 'Configure-DesktopWallpaper'
New-Log -Path (Join-Path -Path "$env:SystemRoot\Logs" -ChildPath 'Configuration')
$ErrorActionPreference = 'Stop'

Write-Log -Category Info -Message "Starting '$PSCommandPath'."

# Locate the background image bundled with this artifact
$BackgroundSourceImage = Get-ChildItem -Path $PSScriptRoot -Filter '*.jpg' | Select-Object -First 1
if (-not $BackgroundSourceImage) {
    Write-Log -Category Error -Message "No .jpg background image found in '$PSScriptRoot'. Add your image file and re-run."
    Exit 1
}
Write-Log -Category Info -Message "Found background image: '$($BackgroundSourceImage.Name)'."

# Copy to the permanent destination inside the Windows directory
$CustomWallpaperDirectory = "$env:SystemRoot\Web\Wallpaper\Custom"
if (-not (Test-Path -Path $CustomWallpaperDirectory)) {
    Write-Log -Category Info -Message "Creating wallpaper directory at '$CustomWallpaperDirectory'."
    New-Item -Path $CustomWallpaperDirectory -ItemType Directory -Force | Out-Null
}
$BackgroundImagePath = Join-Path -Path $CustomWallpaperDirectory -ChildPath $BackgroundSourceImage.Name
Write-Log -Category Info -Message "Copying image to '$BackgroundImagePath'."
Copy-Item -Path $BackgroundSourceImage.FullName -Destination $CustomWallpaperDirectory -Force

# Queue the three User-scope policy values and flush to Registry.pol
Write-Log -Category Info -Message 'Queuing desktop background Group Policy values.'

# Prevents users from changing the wallpaper via Settings / Personalization
Set-PolicyRegistryValue -Scope User `
    -RegistryKeyPath 'Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop' `
    -RegistryValue 'NoChangingWallPaper' -RegistryType DWORD -RegistryData 1

# Path to the background image
Set-PolicyRegistryValue -Scope User `
    -RegistryKeyPath 'Software\Microsoft\Windows\CurrentVersion\Policies\System' `
    -RegistryValue 'Wallpaper' -RegistryType String -RegistryData $BackgroundImagePath

# WallpaperStyle: 4 = Stretch
Set-PolicyRegistryValue -Scope User `
    -RegistryKeyPath 'Software\Microsoft\Windows\CurrentVersion\Policies\System' `
    -RegistryValue 'WallpaperStyle' -RegistryType String -RegistryData '4'

Invoke-PolicyUpdate

Write-Log -Category Info -Message 'Desktop background policy configuration complete.'

#endregion Main
