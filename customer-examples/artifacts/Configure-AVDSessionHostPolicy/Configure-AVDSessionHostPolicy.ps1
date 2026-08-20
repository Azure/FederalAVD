<#
.SYNOPSIS
    Configures Azure Virtual Desktop session-host settings through Local Group Policy.

.DESCRIPTION
    Installs the Azure Virtual Desktop administrative template and writes AVD security,
    graphics, RDP Shortpath, and directional clipboard settings directly to Registry.pol.
    Settings left as NotConfigured are removed from the local policy.

.EXAMPLE
    .\Configure-AVDSessionHostPolicy.ps1 -ClipboardRedirection Allow `
        -ServerToClientClipboard PlainText -ClientToServerClipboard PlainText

.NOTES
    Domain Group Policy and Intune can override Local Group Policy. Host-pool RDP and
    networking settings must also permit clipboard redirection and RDP Shortpath.
#>
[CmdletBinding()]
param (
    [bool]$InstallAdministrativeTemplate = $true,

    [ValidateSet('NotConfigured', 'Allow', 'Block')]
    [string]$ClipboardRedirection = 'NotConfigured',

    [ValidateSet('NotConfigured', 'Disabled', 'PlainText', 'PlainTextAndImages', 'PlainTextImagesAndRtf', 'PlainTextImagesRtfAndHtml')]
    [string]$ServerToClientClipboard = 'NotConfigured',

    [ValidateSet('NotConfigured', 'Disabled', 'PlainText', 'PlainTextAndImages', 'PlainTextImagesAndRtf', 'PlainTextImagesRtfAndHtml')]
    [string]$ClientToServerClipboard = 'NotConfigured',

    [ValidateSet('NotConfigured', 'Disabled', 'ClientOnly', 'ClientAndServer')]
    [string]$ScreenCaptureProtection = 'NotConfigured',

    [ValidateSet('NotConfigured', 'Enabled', 'Disabled')]
    [string]$Watermarking = 'NotConfigured',

    [ValidateRange(1, 10)]
    [int]$WatermarkingQrScale = 4,

    [ValidateRange(100, 9999)]
    [int]$WatermarkingOpacity = 2000,

    [ValidateRange(100, 1000)]
    [int]$WatermarkingWidthFactor = 320,

    [ValidateRange(100, 1000)]
    [int]$WatermarkingHeightFactor = 180,

    [ValidateSet('ConnectionId', 'DeviceId')]
    [string]$WatermarkingContent = 'ConnectionId',

    [ValidateSet('NotConfigured', 'Enabled', 'Disabled')]
    [string]$HevcHardwareEncoding = 'NotConfigured',

    [ValidateSet('NotConfigured', 'Enabled', 'Disabled')]
    [string]$GraphicsDataLogging = 'NotConfigured',

    [ValidateSet('NotConfigured', 'Enabled', 'Disabled')]
    [string]$ManagedShortpathListener = 'NotConfigured',

    [ValidateRange(1024, 65535)]
    [int]$ManagedShortpathPort = 3390,

    [ValidateSet('NotConfigured', 'Enabled', 'Disabled')]
    [string]$ShortpathClientPortRange = 'NotConfigured',

    [ValidateRange(1024, 49151)]
    [int]$ShortpathClientPortBase = 38300,

    [ValidateRange(100, 64512)]
    [int]$ShortpathClientPortCount = 1000,

    [ValidateSet('NotConfigured', 'Enabled', 'Disabled')]
    [string]$ShortpathDirect = 'NotConfigured',

    [ValidateSet('NotConfigured', 'Enabled', 'Disabled')]
    [string]$ShortpathPublic = 'NotConfigured',

    [ValidateSet('NotConfigured', 'Enabled', 'Disabled')]
    [string]$ShortpathRelay = 'NotConfigured',

    [Parameter(DontShow = $true)]
    [string]$GroupPolicyRoot = "$env:SystemRoot\System32\GroupPolicy",

    [Parameter(DontShow = $true)]
    [string]$PolicyDefinitionsRoot = "$env:SystemRoot\PolicyDefinitions"
)

$ErrorActionPreference = 'Stop'
$Script:Name = 'Configure-AVDSessionHostPolicy'
$PolicyKey = 'Software\Policies\Microsoft\Windows NT\Terminal Services'
$TemplateDownloadUrl = 'https://aka.ms/avdgpo'
$TemplateCabName = 'AVDGPTemplate.cab'
$Utf16 = [System.Text.Encoding]::Unicode

function Write-Log {
    param (
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Category = 'Info',

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if (-not $env:SUPPRESS_FILELOG) {
        Add-Content -LiteralPath $Script:Log -Value $content -ErrorAction SilentlyContinue
    }

    switch ($Category) {
        'Info' { Write-Host $content }
        'Warning' { Write-Warning $content }
        'Error' { Write-Error $content -ErrorAction Continue }
    }
}

function New-Log {
    $logRoot = Join-Path $env:SystemRoot 'Logs'
    if ($env:SUPPRESS_FILELOG -eq '1') {
        return
    }

    if (-not (Test-Path -LiteralPath $logRoot)) {
        $null = New-Item -Path $logRoot -ItemType Directory -Force
    }

    $date = Get-Date -UFormat '%Y-%m-%d %H-%M-%S'
    $Script:Log = Join-Path $logRoot "$Script:Name-$date.log"
    Add-Content -LiteralPath $Script:Log -Value "Date`t`t`tCategory`t`tDetails"
}

function Install-AvdAdministrativeTemplate {
    $cabPath = Join-Path $PSScriptRoot $TemplateCabName
    if (-not (Test-Path -LiteralPath $cabPath -PathType Leaf)) {
        $cabPath = Join-Path $env:TEMP $TemplateCabName
        Write-Log -Message "Downloading the Azure Virtual Desktop administrative template from '$TemplateDownloadUrl'."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $TemplateDownloadUrl -OutFile $cabPath -UseBasicParsing
    }
    else {
        Write-Log -Message "Using pre-staged administrative template '$cabPath'."
    }

    $signature = [System.IO.File]::ReadAllBytes($cabPath)[0..3]
    if ([System.Text.Encoding]::ASCII.GetString($signature) -ne 'MSCF') {
        throw "The administrative template payload '$cabPath' is not a valid CAB file."
    }

    $workRoot = Join-Path $env:TEMP "$Script:Name-$([guid]::NewGuid().ToString('N'))"
    $zipPath = Join-Path $workRoot 'AVDGPTemplate.zip'
    $extractPath = Join-Path $workRoot 'Template'
    try {
        $null = New-Item -Path $workRoot -ItemType Directory -Force
        & expand.exe $cabPath $zipPath | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
            throw "Failed to extract AVDGPTemplate.zip from '$cabPath'."
        }

        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
        $admxSource = Join-Path $extractPath 'terminalserver-avd.admx'
        if (-not (Test-Path -LiteralPath $admxSource -PathType Leaf)) {
            throw "The archive '$cabPath' does not contain terminalserver-avd.admx."
        }

        $null = New-Item -Path $PolicyDefinitionsRoot -ItemType Directory -Force
        Copy-Item -LiteralPath $admxSource -Destination (Join-Path $PolicyDefinitionsRoot 'terminalserver-avd.admx') -Force

        foreach ($languageFolder in Get-ChildItem -LiteralPath $extractPath -Directory) {
            $admlSource = Join-Path $languageFolder.FullName 'terminalserver-avd.adml'
            if (-not (Test-Path -LiteralPath $admlSource -PathType Leaf)) {
                continue
            }

            $languageDestination = Join-Path $PolicyDefinitionsRoot $languageFolder.Name
            $null = New-Item -Path $languageDestination -ItemType Directory -Force
            Copy-Item -LiteralPath $admlSource -Destination (Join-Path $languageDestination 'terminalserver-avd.adml') -Force
        }
    }
    finally {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log -Message 'Installed the Azure Virtual Desktop administrative template.'
}

function Read-PolicyEntries {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    if (-not (Test-Path -LiteralPath $Path)) {
        return , $entries
    }

    $raw = [System.IO.File]::ReadAllBytes($Path)
    if ($raw.Length -lt 8 -or [System.Text.Encoding]::ASCII.GetString($raw, 0, 4) -ne 'PReg') {
        throw "Invalid Registry.pol header: $Path"
    }

    $position = 8
    while ($position -lt $raw.Length) {
        if ($position + 1 -ge $raw.Length) { break }
        if ($raw[$position] -ne 0x5B -or $raw[$position + 1] -ne 0x00) {
            $position++
            continue
        }

        $position += 2
        $start = $position
        while ($position + 1 -lt $raw.Length -and -not ($raw[$position] -eq 0 -and $raw[$position + 1] -eq 0)) { $position += 2 }
        $key = $Utf16.GetString($raw, $start, $position - $start)
        $position += 4
        $start = $position
        while ($position + 1 -lt $raw.Length -and -not ($raw[$position] -eq 0 -and $raw[$position + 1] -eq 0)) { $position += 2 }
        $name = $Utf16.GetString($raw, $start, $position - $start)
        $position += 4
        $type = [BitConverter]::ToUInt32($raw, $position)
        $position += 6
        $size = [BitConverter]::ToUInt32($raw, $position)
        $position += 6
        $data = if ($size -gt 0) { [byte[]]$raw[$position..($position + $size - 1)] } else { [byte[]]@() }
        $position += $size + 2
        $entries.Add(@{ Key = $key; Name = $name; Type = $type; Data = $data })
    }

    return , $entries
}

function Set-PolicyDwordEntry {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[hashtable]]$Entries,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [AllowNull()]
        [Nullable[uint32]]$Value
    )

    $deleteName = "**Del.$Name"
    @($Entries | Where-Object { $_.Key -ieq $PolicyKey -and ($_.Name -ieq $Name -or $_.Name -ieq $deleteName) }) |
        ForEach-Object { $Entries.Remove($_) | Out-Null }

    if ($null -eq $Value) {
        $deleteData = $Utf16.GetBytes(' ' + [char]0)
        $Entries.Add(@{ Key = $PolicyKey; Name = $deleteName; Type = [uint32]1; Data = $deleteData })
        Write-Log -Message "Local Group Policy: $Name = Not Configured"
        return
    }

    $Entries.Add(@{ Key = $PolicyKey; Name = $Name; Type = [uint32]4; Data = [BitConverter]::GetBytes([uint32]$Value) })
    Write-Log -Message "Local Group Policy: $Name = $Value"
}

function Write-PolicyEntries {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[hashtable]]$Entries,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('PReg'))
        $writer.Write([uint32]1)
        foreach ($entry in $Entries) {
            $writer.Write([byte[]](0x5B, 0x00))
            $writer.Write($Utf16.GetBytes($entry.Key))
            $writer.Write([byte[]](0x00, 0x00, 0x3B, 0x00))
            $writer.Write($Utf16.GetBytes($entry.Name))
            $writer.Write([byte[]](0x00, 0x00, 0x3B, 0x00))
            $writer.Write([uint32]$entry.Type)
            $writer.Write([byte[]](0x3B, 0x00))
            $writer.Write([uint32]$entry.Data.Length)
            $writer.Write([byte[]](0x3B, 0x00))
            if ($entry.Data.Length -gt 0) { $writer.Write([byte[]]$entry.Data) }
            $writer.Write([byte[]](0x5D, 0x00))
        }
        $writer.Flush()
        $bytes = $stream.ToArray()
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    $directory = Split-Path -Path $Path -Parent
    $null = New-Item -Path $directory -ItemType Directory -Force
    $temporaryPath = "$Path.tmp"
    [System.IO.File]::WriteAllBytes($temporaryPath, $bytes)
    if ((Get-Item -LiteralPath $temporaryPath).Length -ne $bytes.Length) {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        throw "Registry.pol verification failed: $temporaryPath"
    }
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Update-GptIni {
    $gptPath = Join-Path $GroupPolicyRoot 'gpt.ini'
    $existing = if (Test-Path -LiteralPath $gptPath) { Get-Content -LiteralPath $gptPath -Raw } else { '' }
    $machineVersion = [uint16]1
    $userVersion = [uint16]0
    if ($existing -match 'Version\s*=\s*(\d+)') {
        $currentVersion = [uint32]$Matches[1]
        $machineVersion = [uint16]($currentVersion -band 0xFFFF)
        $userVersion = [uint16](($currentVersion -shr 16) -band 0xFFFF)
    }
    $machineVersion++
    $version = ([uint32]$userVersion -shl 16) -bor [uint32]$machineVersion
    $registryCse = '{35378EAC-683F-11D2-A89A-00C04FBBCFA2}'
    $machineAdministrativeTemplates = '{D02B1F72-3407-48AE-BA88-E8213C6761F1}'
    $machineExtensions = if ($existing -match 'gPCMachineExtensionNames\s*=\s*(.+)') { $Matches[1].Trim() } else { '' }
    if ($machineExtensions -notlike "*$registryCse*") { $machineExtensions += "[$registryCse$machineAdministrativeTemplates]" }
    $userExtensions = if ($existing -match 'gPCUserExtensionNames\s*=\s*(.+)') { $Matches[1].Trim() } else { '' }
    $content = "[General]`r`n"
    if ($machineExtensions) { $content += "gPCMachineExtensionNames=$machineExtensions`r`n" }
    if ($userExtensions) { $content += "gPCUserExtensionNames=$userExtensions`r`n" }
    $content += "Version=$version`r`n"
    [System.IO.File]::WriteAllText($gptPath, $content, [System.Text.Encoding]::ASCII)
}

function Get-TriStateValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$State,

        [uint32]$EnabledValue = 1,

        [uint32]$DisabledValue = 0
    )

    switch ($State) {
        'Enabled' { return [Nullable[uint32]]$EnabledValue }
        'Disabled' { return [Nullable[uint32]]$DisabledValue }
        default { return $null }
    }
}

function Get-ClipboardLevel {
    param (
        [Parameter(Mandatory = $true)]
        [string]$State
    )

    switch ($State) {
        'Disabled' { return [Nullable[uint32]]0 }
        'PlainText' { return [Nullable[uint32]]1 }
        'PlainTextAndImages' { return [Nullable[uint32]]2 }
        'PlainTextImagesAndRtf' { return [Nullable[uint32]]3 }
        'PlainTextImagesRtfAndHtml' { return [Nullable[uint32]]4 }
        default { return $null }
    }
}

New-Log
Write-Log -Message "Starting '$PSCommandPath'."

if ($InstallAdministrativeTemplate) {
    Install-AvdAdministrativeTemplate
}

if ($ClipboardRedirection -eq 'Block' -and
    ($ServerToClientClipboard -ne 'NotConfigured' -or $ClientToServerClipboard -ne 'NotConfigured')) {
    throw 'Directional clipboard settings cannot be combined with ClipboardRedirection = Block.'
}

$policyPath = Join-Path $GroupPolicyRoot 'Machine\Registry.pol'
$entries = Read-PolicyEntries -Path $policyPath

$directionalClipboardConfigured = $ServerToClientClipboard -ne 'NotConfigured' -or $ClientToServerClipboard -ne 'NotConfigured'
$clipboardValue = switch ($ClipboardRedirection) {
    'Allow' { [Nullable[uint32]]0 }
    'Block' { [Nullable[uint32]]1 }
    default { if ($directionalClipboardConfigured) { [Nullable[uint32]]0 } else { $null } }
}
Set-PolicyDwordEntry -Entries $entries -Name 'fDisableClip' -Value $clipboardValue
Set-PolicyDwordEntry -Entries $entries -Name 'SCClipLevel' -Value (Get-ClipboardLevel -State $ServerToClientClipboard)
Set-PolicyDwordEntry -Entries $entries -Name 'CSClipLevel' -Value (Get-ClipboardLevel -State $ClientToServerClipboard)

$screenCaptureValue = switch ($ScreenCaptureProtection) {
    'Disabled' { [Nullable[uint32]]0 }
    'ClientOnly' { [Nullable[uint32]]1 }
    'ClientAndServer' { [Nullable[uint32]]2 }
    default { $null }
}
Set-PolicyDwordEntry -Entries $entries -Name 'fEnableScreenCaptureProtect' -Value $screenCaptureValue

Set-PolicyDwordEntry -Entries $entries -Name 'fEnableWatermarking' -Value (Get-TriStateValue -State $Watermarking)
if ($Watermarking -eq 'Enabled') {
    Set-PolicyDwordEntry -Entries $entries -Name 'WatermarkingQrScale' -Value ([uint32]$WatermarkingQrScale)
    Set-PolicyDwordEntry -Entries $entries -Name 'WatermarkingOpacity' -Value ([uint32]$WatermarkingOpacity)
    Set-PolicyDwordEntry -Entries $entries -Name 'WatermarkingWidthFactor' -Value ([uint32]$WatermarkingWidthFactor)
    Set-PolicyDwordEntry -Entries $entries -Name 'WatermarkingHeightFactor' -Value ([uint32]$WatermarkingHeightFactor)
    Set-PolicyDwordEntry -Entries $entries -Name 'WatermarkingContent' -Value ([uint32]($WatermarkingContent -eq 'DeviceId'))
}
else {
    foreach ($name in 'WatermarkingQrScale', 'WatermarkingOpacity', 'WatermarkingWidthFactor', 'WatermarkingHeightFactor', 'WatermarkingContent') {
        Set-PolicyDwordEntry -Entries $entries -Name $name -Value $null
    }
}

Set-PolicyDwordEntry -Entries $entries -Name 'HEVCHardwareEncodePreferred' -Value (Get-TriStateValue -State $HevcHardwareEncoding)
Set-PolicyDwordEntry -Entries $entries -Name 'fEnableConnectionIntervalGraphicsData' -Value (Get-TriStateValue -State $GraphicsDataLogging)

Set-PolicyDwordEntry -Entries $entries -Name 'fUseUdpPortRedirector' -Value (Get-TriStateValue -State $ManagedShortpathListener)
if ($ManagedShortpathListener -eq 'Enabled') {
    Set-PolicyDwordEntry -Entries $entries -Name 'UdpRedirectorPort' -Value ([uint32]$ManagedShortpathPort)
}
else {
    Set-PolicyDwordEntry -Entries $entries -Name 'UdpRedirectorPort' -Value $null
}

Set-PolicyDwordEntry -Entries $entries -Name 'ICEEnableClientPortRange' -Value (Get-TriStateValue -State $ShortpathClientPortRange)
if ($ShortpathClientPortRange -eq 'Enabled') {
    if ($ShortpathClientPortBase + $ShortpathClientPortCount - 1 -gt 65535) {
        throw 'ShortpathClientPortBase plus ShortpathClientPortCount exceeds port 65535.'
    }
    Set-PolicyDwordEntry -Entries $entries -Name 'ICEClientPortBase' -Value ([uint32]$ShortpathClientPortBase)
    Set-PolicyDwordEntry -Entries $entries -Name 'ICEClientPortRange' -Value ([uint32]$ShortpathClientPortCount)
}
else {
    Set-PolicyDwordEntry -Entries $entries -Name 'ICEClientPortBase' -Value $null
    Set-PolicyDwordEntry -Entries $entries -Name 'ICEClientPortRange' -Value $null
}

Set-PolicyDwordEntry -Entries $entries -Name 'directUDP' -Value (Get-TriStateValue -State $ShortpathDirect -DisabledValue 2)
Set-PolicyDwordEntry -Entries $entries -Name 'publicUDP' -Value (Get-TriStateValue -State $ShortpathPublic -DisabledValue 2)
Set-PolicyDwordEntry -Entries $entries -Name 'relayUDP' -Value (Get-TriStateValue -State $ShortpathRelay -DisabledValue 2)

Write-PolicyEntries -Entries $entries -Path $policyPath
Update-GptIni
Write-Log -Message 'Completed Azure Virtual Desktop session host policy configuration.'