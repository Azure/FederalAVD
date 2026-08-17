[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false)]
    [bool]$AllowDeveloperTools = $true,

    # https://chromeenterprise.google/policies/?policy=SafeBrowsingAllowlistDomains
    [Parameter(Mandatory = $false)]
    [string[]]$SafeBrowsingAllowlistDomains = @('portal.azure.com','core.windows.net','portal.azure.us','usgovcloudapi.net'),

    # https://chromeenterprise.google/policies/?policy=PopupsAllowedForUrls
    [Parameter(Mandatory = $false)]
    [string[]]$PopupsAllowedForUrls = @('[*.]mil','[*.]gov','[*.]portal.azure.us','[*.]usgovcloudapi.net','[*.]azure.com','[*.]azure.net'),

    # https://chromeenterprise.google/policies/?policy=DefaultSearchProviderEnabled
    # $null (default) leaves this policy unconfigured - address-bar search stays on and the
    # user can still pick their own provider unless the DefaultSearchProviderSearchURL fields below force one.
    [Parameter(Mandatory = $false)]
    [Nullable[bool]]$DefaultSearchProviderEnabled = $null,

    # Chrome has no multi-engine equivalent to Edge's ManagedSearchEngines - only a single
    # enforced default provider. Leave DefaultSearchProviderSearchURL empty to skip enforcing
    # a specific provider and let DefaultSearchProviderEnabled control search-from-address-bar only.
    # https://chromeenterprise.google/policies/?policy=DefaultSearchProviderName
    [Parameter(Mandatory = $false)]
    [string]$DefaultSearchProviderName = '',

    # https://chromeenterprise.google/policies/?policy=DefaultSearchProviderKeyword
    [Parameter(Mandatory = $false)]
    [string]$DefaultSearchProviderKeyword = '',

    # https://chromeenterprise.google/policies/?policy=DefaultSearchProviderSearchURL
    [Parameter(Mandatory = $false)]
    [string]$DefaultSearchProviderSearchURL = '',

    # https://chromeenterprise.google/policies/?policy=DefaultSearchProviderSuggestURL
    [Parameter(Mandatory = $false)]
    [string]$DefaultSearchProviderSuggestURL = ''
)

# ============================================================
# Functions
# ============================================================

Function Get-InternetFile {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [uri]$Url,
        [Parameter(Mandatory = $true, Position = 1)]
        [string]$OutputDirectory,
        [Parameter(Mandatory = $false, Position = 2)]
        [string]$OutputFileName
    )

    Begin {
        $ProgressPreference = 'SilentlyContinue'
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        Write-Log -Message "Starting ${CmdletName} with the following parameters: $PSBoundParameters"
    }
    Process {
        $start_time = Get-Date
        If (!$OutputFileName) {
            Write-Log -Message "${CmdletName}: No OutputFileName specified. Trying to get file name from URL."
            If ((split-path -path $Url -leaf).Contains('.')) {
                $OutputFileName = split-path -path $url -leaf
                Write-Log -Message "${CmdletName}: Url contains file name - '$OutputFileName'."
            }
            Else {
                Write-Log -Message "${CmdletName}: Url does not contain file name. Trying 'Location' Response Header."
                $request = [System.Net.WebRequest]::Create($url)
                $request.AllowAutoRedirect = $false
                $response = $request.GetResponse()
                $Location = $response.GetResponseHeader("Location")
                If ($Location) {
                    $OutputFileName = [System.IO.Path]::GetFileName($Location)
                    Write-Log -Message "${CmdletName}: File Name from 'Location' Response Header is '$OutputFileName'."
                }
                Else {
                    Write-Log -Message "${CmdletName}: No 'Location' Response Header returned. Trying 'Content-Disposition' Response Header."
                    $result = Invoke-WebRequest -Method GET -Uri $Url -UseBasicParsing
                    $contentDisposition = $result.Headers.'Content-Disposition'
                    If ($contentDisposition) {
                        $OutputFileName = $contentDisposition.Split("=")[1].Replace("`"", "")
                        Write-Log -Message "${CmdletName}: File Name from 'Content-Disposition' Response Header is '$OutputFileName'."
                    }
                }
            }
        }
        If ($OutputFileName) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            $OutputFile = Join-Path $OutputDirectory -ChildPath $OutputFileName
            Write-Log -Message "${CmdletName}: Downloading file at '$url' to '$OutputFile'."
            Try {
                $wc.DownloadFile($url, $OutputFile)
                $time = (Get-Date).Subtract($start_time).Seconds

                Write-Log -Message "${CmdletName}: Time taken: '$time' seconds."
                if (Test-Path -Path $outputfile) {
                    $totalSize = (Get-Item $outputfile).Length / 1MB
                    Write-Log -Message "${CmdletName}: Download was successful. Final file size: '$totalsize' mb"
                    Return $OutputFile
                }
            }
            Catch {
                Write-Log -Category Error -Message "${CmdletName}: Error downloading file. Please check url."
                Return $Null
            }
        }
        Else {
            Write-Log -Category Error -Message "${CmdletName}: No OutputFileName specified. Unable to download file."
            Return $Null
        }
    }
    End {
        Write-Log -Message "Ending ${CmdletName}"
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
        'Info'    { Write-Host $Content }
        'Error'   { Write-Error $Content -ErrorAction Continue }
        'Warning' { Write-Warning $Content }
    }
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

    Queue entries with Set-PolicyRegistryValue / Remove-PolicyRegistryValue /
    Clear-PolicyRegistryKeyValues, then call Invoke-PolicyUpdate to flush the queue to
    Registry.pol.

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
    return ,$list
}

function Write-PRegFile {
    <#  Internal. Writes a Registry.pol using safe tmp -> verify -> promote.  #>
    param (
        [string]$Path,
        [System.Collections.Generic.List[hashtable]]$Entries
    )

    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

    $ms = [IO.MemoryStream]::new()
    $w  = [IO.BinaryWriter]::new($ms)

    $w.Write([System.Text.Encoding]::ASCII.GetBytes('PReg'))  # Signature
    $w.Write([uint32]1)                                         # Version

    $bo = [byte[]](0x5B, 0x00)   # '['
    $bc = [byte[]](0x5D, 0x00)   # ']'
    $sc = [byte[]](0x3B, 0x00)   # ';'
    $nt = [byte[]](0x00, 0x00)   # null terminator

    foreach ($e in $Entries) {
        $w.Write($bo)
        $w.Write($script:_PRegEnc.GetBytes($e.Key));   $w.Write($nt); $w.Write($sc)
        $w.Write($script:_PRegEnc.GetBytes($e.Name));  $w.Write($nt); $w.Write($sc)
        $w.Write([uint32]$e.Type);  $w.Write($sc)
        $w.Write([uint32]$e.Size);  $w.Write($sc)
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
        'DWORD'        { 4 }
        'STRING'       { 1 }
        'SZ'           { 1 }
        'EXPANDSTRING' { 2 }
        'EXPANDSZ'     { 2 }
        'MULTISTRING'  { 7 }
        'MULTISZ'      { 7 }
        default        { 1 }
    }

    $dataBytes = switch ($typeCode) {
        4       { ConvertTo-PRegDWord ([uint32]$RegistryData) }
        7       { ConvertTo-PRegMultiSZ ($RegistryData -split '\|') }
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

    $relPath  = Get-RelativePolicyKeyPath $RegistryKeyPath
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

    $relPath  = Get-RelativePolicyKeyPath $RegistryKeyPath
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
        Updates gpt.ini so the Group Policy client on deployed session hosts knows to
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

    $gpBase   = "$env:SystemRoot\System32\GroupPolicy"
    $machineQ = @($script:_PolQueue | Where-Object { $_.Scope -eq 'Computer' })
    $userQ    = @($script:_PolQueue | Where-Object { $_.Scope -eq 'User' })
    $machineUpdated = $false
    $userUpdated    = $false

    foreach ($scope in @(
        @{ Queue = $machineQ; PolPath = "$gpBase\Machine\Registry.pol"; IsUser = $false },
        @{ Queue = $userQ;    PolPath = "$gpBase\User\Registry.pol";    IsUser = $true }
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
        $gptPath   = "$gpBase\gpt.ini"
        $regCse    = '{35378EAC-683F-11D2-A89A-00C04FBBCFA2}'
        $machineAT = '{D02B1F72-3407-48AE-BA88-E8213C6761F1}'
        $userAT    = '{D02B1F73-3407-48AE-BA88-E8213C6761F1}'

        $existing_ini = if (Test-Path -LiteralPath $gptPath) { Get-Content $gptPath -Raw } else { '' }

        $machineVer = [uint16]1
        $userVer    = [uint16]1
        if ($existing_ini -match 'Version\s*=\s*(\d+)') {
            $cur = [uint32]$matches[1]
            $machineVer = [uint16]($cur -band 0xFFFF)
            $userVer    = [uint16](($cur -shr 16) -band 0xFFFF)
        }
        if ($machineUpdated) { $machineVer++ }
        if ($userUpdated)    { $userVer++ }
        $version = ([uint32]$userVer -shl 16) -bor [uint32]$machineVer

        $machineExt = "[$regCse$machineAT]"
        $userExt    = "[$regCse$userAT]"

        $finalMachineExt = if ($machineUpdated) {
            if ($existing_ini -match 'gPCMachineExtensionNames\s*=\s*(.+)') {
                $ev = $matches[1].Trim()
                if ($ev -notlike "*$regCse*") { $ev + $machineExt } else { $ev }
            } else { $machineExt }
        } elseif ($existing_ini -match 'gPCMachineExtensionNames\s*=\s*(.+)') {
            $matches[1].Trim()
        } else { '' }

        $finalUserExt = if ($userUpdated) {
            if ($existing_ini -match 'gPCUserExtensionNames\s*=\s*(.+)') {
                $ev = $matches[1].Trim()
                if ($ev -notlike "*$regCse*") { $ev + $userExt } else { $ev }
            } else { $userExt }
        } elseif ($existing_ini -match 'gPCUserExtensionNames\s*=\s*(.+)') {
            $matches[1].Trim()
        } else { '' }

        $gptContent = "[General]`r`n"
        if ($finalMachineExt) { $gptContent += "gPCMachineExtensionNames=$finalMachineExt`r`n" }
        if ($finalUserExt)    { $gptContent += "gPCUserExtensionNames=$finalUserExt`r`n" }
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
        'HKEY_LOCAL_MACHINE:',  'HKEY_CURRENT_USER:',
        'HKLM:\', 'HKCU:\',
        'HKLM:',  'HKCU:'
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
[string]$Script:Name = "Configure-ChromePolicy"
[string]$Script:TempDir = Join-Path -Path $env:Temp -ChildPath $Script:Name

New-Log -Path (Join-Path -Path "$env:SystemRoot\Logs" -ChildPath 'Configuration')
$ErrorActionPreference = 'Stop'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."
#endregion

Write-Log -Category Info -Message "Running Script to Configure Google Chrome Policies."
$Script:ChromeAdmx = "$env:WINDIR\PolicyDefinitions\chrome.admx"
# Google publishes a single zip (not a cab) containing ADMX/ADML for all platforms.
# https://support.google.com/chrome/a/answer/187202
$Script:ChromeTemplatesUrl = 'https://dl.google.com/dl/edgedl/chrome/policy/policy_templates.zip'
# Lookup order: 1) bundled next to this script (staged via downloads.json), 2) already
# installed in PolicyDefinitions, 3) download from Google. If none are available, policies
# fall back to direct registry writes further below.
$chromeZips = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.zip' | Sort-Object LastWriteTime -Descending)
If ($chromeZips.Count -gt 1) {
    Write-Log -Category Warning -Message "Multiple ZIP files found in '$PSScriptRoot'. Using newest: '$($chromeZips[0].Name)'. Remove older files to avoid ambiguity."
}
$ChromeTemplatesZip = ($chromeZips | Select-Object -First 1).FullName
If ($null -ne $ChromeTemplatesZip) {
    Write-Log -Category Info -Message "Bundled Chrome policy template ZIP found: '$ChromeTemplatesZip'."
} ElseIf (Test-Path $Script:ChromeAdmx) {
    Write-Log -Category Info -Message "'chrome.admx' already present in PolicyDefinitions and no bundled ZIP to apply. Skipping template download."
} Else {
    Write-Log -Category Info -Message "'chrome.admx' not found in PolicyDefinitions and no bundled ZIP present in '$PSScriptRoot'. Attempting to download Chrome policy templates from '$Script:ChromeTemplatesUrl'."
    try {
        $ChromeTemplatesZip = Get-InternetFile -Url $Script:ChromeTemplatesUrl -OutputDirectory $Script:TempDir -OutputFileName 'policy_templates.zip' -Verbose
    } catch {
        Write-Log -Category Warning -Message "Failed to download Chrome policy templates: $_. Continuing without ADMX."
    }
}
If ($null -ne $ChromeTemplatesZip) {
    $TemplatesDir = Join-Path -Path $Script:TempDir -ChildPath 'Templates'
    New-Item -Path $TemplatesDir -ItemType Directory -Force | Out-Null
    Write-Log -Category Info -Message "Expanding `"$ChromeTemplatesZip`" into `"$TemplatesDir`"."
    Expand-Archive -Path $ChromeTemplatesZip -DestinationPath $TemplatesDir -Force
    $admxSourceDir = Get-ChildItem -Path $TemplatesDir -Directory -Recurse -Filter 'admx' | Select-Object -First 1
    If ($null -eq $admxSourceDir) {
        Write-Log -Category Warning -Message "No 'admx' folder found under '$TemplatesDir' after extracting '$ChromeTemplatesZip'. Chrome policy templates will not be installed."
    } Else {
        Write-Log -Category Info -Message "Copy ADMX and ADML files to PolicyDefinition Folders."
        $null = Get-ChildItem -Path $admxSourceDir.FullName -File -Filter '*.admx' | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\" -Force }
        $null = Get-ChildItem -Path $admxSourceDir.FullName -Directory | Where-Object { $_.Name -eq 'en-US' } | Get-ChildItem -File -Filter '*.adml' | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\en-US\" -Force }
    }
}
$Script:AdmxImported = Test-Path $Script:ChromeAdmx

Write-Log -Category Info -Message "Now Configuring Chrome Group Policy."
$chromeKeyPath = 'Software\Policies\Google\Chrome'
If ($Script:AdmxImported) {
    if ($AllowDeveloperTools) {
        # https://chromeenterprise.google/policies/?policy=DeveloperToolsAvailability
        Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $chromeKeyPath -RegistryValue 'DeveloperToolsAvailability' -RegistryType 'DWORD' -RegistryData 1
    }
    # https://chromeenterprise.google/policies/?policy=DownloadRestrictions
    Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $chromeKeyPath -RegistryValue 'DownloadRestrictions' -RegistryType 'DWORD' -RegistryData 4
    if ($null -ne $SafeBrowsingAllowlistDomains -and $SafeBrowsingAllowlistDomains.Count -gt 0) {
        Clear-PolicyRegistryKeyValues -Scope 'Computer' -RegistryKeyPath "$chromeKeyPath\SafeBrowsingAllowlistDomains"
        $i = 1
        ForEach ($domain in $SafeBrowsingAllowlistDomains) {
            Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath "$chromeKeyPath\SafeBrowsingAllowlistDomains" -RegistryValue $i -RegistryType 'STRING' -RegistryData $domain
            $i++
        }
    }
    if ($null -ne $PopupsAllowedForUrls -and $PopupsAllowedForUrls.Count -gt 0) {
        Clear-PolicyRegistryKeyValues -Scope 'Computer' -RegistryKeyPath "$chromeKeyPath\PopupsAllowedForUrls"
        $i = 1
        ForEach ($url in $PopupsAllowedForUrls) {
            Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath "$chromeKeyPath\PopupsAllowedForUrls" -RegistryValue $i -RegistryType 'STRING' -RegistryData $url
            $i++
        }
    }
    # https://chromeenterprise.google/policies/?policy=DefaultSearchProviderEnabled
    if ($null -ne $DefaultSearchProviderEnabled) {
        Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $chromeKeyPath -RegistryValue 'DefaultSearchProviderEnabled' -RegistryType 'DWORD' -RegistryData ([int]$DefaultSearchProviderEnabled)
    }
    if (-not [string]::IsNullOrWhiteSpace($DefaultSearchProviderSearchURL)) {
        # Chrome has no ManagedSearchEngines equivalent - only a single enforced default provider.
        # https://chromeenterprise.google/policies/?policy=DefaultSearchProviderSearchURL
        Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $chromeKeyPath -RegistryValue 'DefaultSearchProviderSearchURL' -RegistryType 'STRING' -RegistryData $DefaultSearchProviderSearchURL
        if (-not [string]::IsNullOrWhiteSpace($DefaultSearchProviderName)) {
            Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $chromeKeyPath -RegistryValue 'DefaultSearchProviderName' -RegistryType 'STRING' -RegistryData $DefaultSearchProviderName
        }
        if (-not [string]::IsNullOrWhiteSpace($DefaultSearchProviderKeyword)) {
            Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $chromeKeyPath -RegistryValue 'DefaultSearchProviderKeyword' -RegistryType 'STRING' -RegistryData $DefaultSearchProviderKeyword
        }
        if (-not [string]::IsNullOrWhiteSpace($DefaultSearchProviderSuggestURL)) {
            Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $chromeKeyPath -RegistryValue 'DefaultSearchProviderSuggestURL' -RegistryType 'STRING' -RegistryData $DefaultSearchProviderSuggestURL
        }
    }
    Invoke-PolicyUpdate
} Else {
    Write-Log -Category Warning -Message "Chrome ADMX templates were not imported. Writing settings directly to registry."
    $chromeKey = "HKLM:\$chromeKeyPath"
    If (-not (Test-Path $chromeKey)) { New-Item -Path $chromeKey -Force | Out-Null }
    if ($AllowDeveloperTools) {
        # https://chromeenterprise.google/policies/?policy=DeveloperToolsAvailability
        Set-ItemProperty -Path $chromeKey -Name 'DeveloperToolsAvailability' -Value 1 -Type DWord -Force
    }
    # https://chromeenterprise.google/policies/?policy=DownloadRestrictions
    Set-ItemProperty -Path $chromeKey -Name 'DownloadRestrictions' -Value 4 -Type DWord -Force
    if ($null -ne $SafeBrowsingAllowlistDomains -and $SafeBrowsingAllowlistDomains.Count -gt 0) {
        Remove-Item -Path "$chromeKey\SafeBrowsingAllowlistDomains" -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path "$chromeKey\SafeBrowsingAllowlistDomains" -Force | Out-Null
        $i = 1
        ForEach ($domain in $SafeBrowsingAllowlistDomains) {
            Set-ItemProperty -Path "$chromeKey\SafeBrowsingAllowlistDomains" -Name $i -Value $domain -Type String -Force
            $i++
        }
    }
    if ($null -ne $PopupsAllowedForUrls -and $PopupsAllowedForUrls.Count -gt 0) {
        Remove-Item -Path "$chromeKey\PopupsAllowedForUrls" -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path "$chromeKey\PopupsAllowedForUrls" -Force | Out-Null
        $i = 1
        ForEach ($url in $PopupsAllowedForUrls) {
            Set-ItemProperty -Path "$chromeKey\PopupsAllowedForUrls" -Name $i -Value $url -Type String -Force
            $i++
        }
    }
    # https://chromeenterprise.google/policies/?policy=DefaultSearchProviderEnabled
    if ($null -ne $DefaultSearchProviderEnabled) {
        Set-ItemProperty -Path $chromeKey -Name 'DefaultSearchProviderEnabled' -Value ([int]$DefaultSearchProviderEnabled) -Type DWord -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($DefaultSearchProviderSearchURL)) {
        Set-ItemProperty -Path $chromeKey -Name 'DefaultSearchProviderSearchURL' -Value $DefaultSearchProviderSearchURL -Type String -Force
        if (-not [string]::IsNullOrWhiteSpace($DefaultSearchProviderName)) {
            Set-ItemProperty -Path $chromeKey -Name 'DefaultSearchProviderName' -Value $DefaultSearchProviderName -Type String -Force
        }
        if (-not [string]::IsNullOrWhiteSpace($DefaultSearchProviderKeyword)) {
            Set-ItemProperty -Path $chromeKey -Name 'DefaultSearchProviderKeyword' -Value $DefaultSearchProviderKeyword -Type String -Force
        }
        if (-not [string]::IsNullOrWhiteSpace($DefaultSearchProviderSuggestURL)) {
            Set-ItemProperty -Path $chromeKey -Name 'DefaultSearchProviderSuggestURL' -Value $DefaultSearchProviderSuggestURL -Type String -Force
        }
    }
}
Write-Log -Category Info -Message "Chrome Group Policy Configuration Complete."
Remove-Item -Path $Script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
