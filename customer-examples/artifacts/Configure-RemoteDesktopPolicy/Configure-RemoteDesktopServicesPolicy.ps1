[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [string]$MaxIdleTime = '21600000',
    [string]$MaxDisconnectionionTime = '21600000',
    [switch]$EnableRemoteApp
)

#region Functions

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
        ## Get the name of this function and write header
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
            $OutputFile = Join-Path $OutputDirectory $OutputFileName
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

Function Update-LocalGPOTextFile {
    [CmdletBinding(DefaultParameterSetName = 'Set')]
    Param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Delete')]
        [Parameter(Mandatory = $true, ParameterSetName = 'DeleteAllValues')]
        [ValidateSet('Computer', 'User')]
        [string]$Scope,
        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Delete')]
        [Parameter(Mandatory = $true, ParameterSetName = 'DeleteAllValues')]
        [string]$RegistryKeyPath,
        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Delete')]
        [Parameter(Mandatory = $true, ParameterSetName = 'DeleteAllValues')]
        [string]$RegistryValue,
        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [AllowEmptyString()]
        [string]$RegistryData,
        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [ValidateSet('DWORD', 'String')]
        [string]$RegistryType,
        [Parameter(Mandatory = $false, ParameterSetName = 'Delete')]
        [switch]$Delete,
        [Parameter(Mandatory = $false, ParameterSetName = 'DeleteAllValues')]
        [switch]$DeleteAllValues,
        [string]$outputDir = $Script:LGPOTempDir
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    }
    Process {
        # Convert $RegistryType to UpperCase to prevent LGPO errors.
        $ValueType = $RegistryType.ToUpper()
        # Change String type to SZ for text file
        If ($ValueType -eq 'STRING') { $ValueType = 'SZ' }
        # Replace any incorrect registry entries for the format needed by text file.
        $modified = $false
        $SearchStrings = 'HKLM:\', 'HKCU:\', 'HKEY_CURRENT_USER:\', 'HKEY_LOCAL_MACHINE:\'
        ForEach ($String in $SearchStrings) {
            If ($RegistryKeyPath.StartsWith("$String") -and $modified -ne $true) {
                $index = $String.Length
                $RegistryKeyPath = $RegistryKeyPath.Substring($index, $RegistryKeyPath.Length - $index)
                $modified = $true
            }
        }        
        #Create the output file if needed.
        $OutFile = Join-Path -Path $OutputDir -ChildPath "$Scope.txt"
        If (-not (Test-Path -LiteralPath $Outfile)) {
            If (-not (Test-Path -LiteralPath $OutputDir -PathType 'Container')) {
                $null = New-Item -Path $OutputDir -Type 'Directory' -Force -ErrorAction 'Stop'
            }
            $null = New-Item -Path $OutFile -ItemType File -ErrorAction Stop
        }

        Write-Log -Message "${CmdletName}: Adding registry information to '$outfile' for LGPO.exe"
        # Update file with information
        Add-Content -Path $Outfile -Value $Scope
        Add-Content -Path $Outfile -Value $RegistryKeyPath
        Add-Content -Path $Outfile -Value $RegistryValue
        If ($Delete) {
            Add-Content -Path $Outfile -Value 'DELETE'
        }
        ElseIf ($DeleteAllValues) {
            Add-Content -Path $Outfile -Value 'DELETEALLVALUES'
        }
        Else {
            Add-Content -Path $Outfile -Value "$($ValueType):$RegistryData"
        }
        Add-Content -Path $Outfile -Value ""
    }
    End {        
    }
}

Function Invoke-LGPO {
    [CmdletBinding()]
    Param (
        [string]$InputDir = $Script:LGPOTempDir
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    }
    Process {
        Write-Log -Message "${CmdletName}: Gathering Registry text files for LGPO from '$InputDir'"
        $RegFiles = Get-ChildItem -Path $InputDir -Filter '*.txt'
        ForEach ($RegistryFile in $RegFiles) {
            $TxtFilePath = $RegistryFile.FullName
            Write-Log -Message "${CmdletName}: Now applying settings from '$txtFilePath' to Local Group Policy via LGPO.exe."
            $lgporesult = Start-Process -FilePath 'lgpo.exe' -ArgumentList "/t `"$TxtFilePath`"" -Wait -PassThru
            Write-Log -Message "${CmdletName}: LGPO exitcode: '$($lgporesult.exitcode)'"
        }
        Write-Log -Message "${CmdletName}: Gathering Security Templates files for LGPO from '$InputDir'"
        $ConfigFile = Get-ChildItem -Path $InputDir -Filter '*.inf'
        If ($ConfigFile) {
            $ConfigFile = $ConfigFile.FullName
            Write-Log -Message "${CmdletName}: Now applying security settings from '$ConfigFile' to Local Security Policy via LGPO.exe."
            $lgporesult = Start-Process -FilePath 'lgpo.exe' -ArgumentList "/s `"$ConfigFile`"" -Wait -PassThru
            Write-Log -Message "${CmdletName}: LGPO exitcode: '$($lgporesult.exitcode)'"
        }
        Write-Log -Message "${CmdletName}: Finding Audit CSV file for LGPO from '$InputDir'"
        $AuditFile = Get-ChildItem -Path $InputDir -Filter '*.csv'
        If ($AuditFile) {
            $AuditFile = $AuditFile.FullName
            Write-Log -Message "${CmdletName}: Now applying advanced audit settings from '$AuditFile' to Local policy via LGPO.exe."
            $lgporesult = Start-Process -FilePath 'lgpo.exe' -ArgumentList "/ac `"$AuditFile`"" -Wait -PassThru
            Write-Log -Message "${CmdletName}: LGPO exitcode: '$($lgporesult.exitcode)'"
        }
    }
    End {
    }
}

Function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Name,
        [Parameter()]
        [string]
        $Path,
        [Parameter()]
        [string]$PropertyType,
        [Parameter()]
        $Value
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    }
    Process {
        Write-Log -Message "${CmdletName}: Setting Registry Value $Path\$Name"
        # Create the registry Key(s) if necessary.
        If (!(Test-Path -Path $Path)) {
            Write-Log -Message "${CmdletName}: Creating Registry Key: $Path"
            New-Item -Path $Path -Force | Out-Null
        }
        # Check for existing registry setting
        $RemoteValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        If ($RemoteValue) {
            # Get current Value
            $CurrentValue = Get-ItemPropertyValue -Path $Path -Name $Name
            Write-Log -Message "${CmdletName}: Current Value of $($Path)\$($Name) : $CurrentValue"
            If ($Value -ne $CurrentValue) {
                Write-Log -Message "${CmdletName}: Setting Value of $($Path)\$($Name) : $Value"
                Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
            }
            Else {
                Write-Log -Message "${CmdletName}: Value of $($Path)\$($Name) is already set to $Value"
            }           
        }
        Else {
            Write-Log -Message "${CmdletName}: Setting Value of $($Path)\$($Name) : $Value"
            New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
        }
        Start-Sleep -Milliseconds 500
    }
    End {
        Write-Log -Message "Ending ${CmdletName}"
    }
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
    <#  Internal. Writes a Registry.pol using safe tmp -> verify -> bak -> promote.  #>
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
          $userExt   = "[$regCse$userAT]"

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
[int]$MaxIdleTime = $MaxIdleTime
[int]$MaxDisconnectionTime = $MaxDisconnectionionTime
[string]$Script:Name = "Configure-RemoteDesktopServicesPolicy"
New-Log -Path (Join-Path -Path "$env:SystemRoot\Logs" -ChildPath 'Configuration')
$ErrorActionPreference = 'Stop'
Write-Log -category Info -message "Starting '$PSCommandPath'."
Write-Log -Category Info -Message "Parameters: MaxIdleTime='$MaxIdleTime', MaxDisconnectionTime='$MaxDisconnectionTime', EnableRemoteApp='$EnableRemoteApp'."
#endregion

Write-Log -Category Info -Message "Now Configuring Remote Desktop Services Timeout Settings."
$rdKey = 'Software\Policies\Microsoft\Windows NT\Terminal Services'
Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $rdKey -RegistryValue 'MaxDisconnectionTime' -RegistryType 'DWORD' -RegistryData $MaxDisconnectionTime
Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $rdKey -RegistryValue 'MaxIdleTime' -RegistryType 'DWORD' -RegistryData $MaxIdleTime
Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $rdKey -RegistryValue 'fEnableTimeZoneRedirection' -RegistryType 'DWORD' -RegistryData 1
If ($EnableRemoteApp) {
    Write-Log -Category Info -Message "Enabling enhanced shell experience for RemoteApp."
    Set-PolicyRegistryValue -Scope 'Computer' -RegistryKeyPath $rdKey -RegistryValue 'EnableEnhancedShellExperienceForRemoteApp' -RegistryType 'DWORD' -RegistryData 1
}
Invoke-PolicyUpdate
Write-Log -Category Info -Message "Remote Desktop Services Timeout Settings Configured."
