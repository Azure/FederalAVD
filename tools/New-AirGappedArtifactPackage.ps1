#requires -Version 7.2
<#
.SYNOPSIS
Builds one connected-side transfer bundle of offline artifact prerequisites.
.DESCRIPTION
Reuses the WinGet and built-in UWP builders, then adds Microsoft-signed WebView2
and Visual C++ installers. WebRTC is included by default for the current air-gapped
Teams path while Windows App support awaits product-group confirmation. No Azure resources are
accessed and no installer is executed. Extract the outer ZIP before staging on high.
Downloading packages does not grant redistribution or deployment rights.
.PARAMETER OutputPath
Destination ZIP. Existing output is preserved unless Force is specified.
.PARAMETER SourceRevision
Repository release tag or commit used to build the package.
.PARAMETER WinGetReleaseTag
Optional exact stable microsoft/winget-cli tag. Empty selects latest stable.
.PARAMETER IncludeWebRtc
Includes the WebRTC MSI by default. Use -IncludeWebRtc:$false only for an approved
alternative; omission does not migrate the built-in Teams installation.
.PARAMETER AppStoreIds
Optional subset of the existing built-in UWP app selection. Empty uses its defaults.
.PARAMETER ReleasePartSizeBytes
Maximum size of each release part (default 1.5 GiB). Larger ZIPs are also split
for publication; the complete local ZIP and all runtime dependencies are retained.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceRevision,

    [ValidatePattern('^v[0-9]+(?:\.[0-9]+){1,3}(?:-[A-Za-z0-9.-]+)?$')]
    [string]$WinGetReleaseTag,

    [ValidateSet('9WZDNCRFHVN5', '9PCFS5B6T72H', '9MZ95KL8MR0L', '9MSMLRH6LZF3',
        '9P1J8S7CCWWT', '9WZDNCRFJBH4', '9NBLGGH4QGHW', '9N0DX20HK701',
        '9N4D0MSMP0PT', '9N5TDP8VCMHS', '9PG2DK419DRG', '9MVZQVXJBQ9V',
        '9N95Q1ZZPMH4', '9PMMSR1CGPWG')]
    [string[]]$AppStoreIds,

    [ValidateRange(1, 2147483647)]
    [long]$ReleasePartSizeBytes = 1536MB,

    [switch]$IncludeWebRtc = $true,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Build this package on a connected Windows workstation.' }
if ([string]::IsNullOrWhiteSpace($SourceRevision)) { throw 'SourceRevision must identify the source checkout.' }
if ($AppStoreIds -and $AppStoreIds.Count -ne @($AppStoreIds | Sort-Object -Unique).Count) {
    throw 'AppStoreIds contains duplicate values.'
}
$outputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ([IO.Path]::GetExtension($outputFile) -ne '.zip') { throw 'OutputPath must be a .zip file.' }
foreach ($path in @($outputFile, "$outputFile.sha256", "$outputFile.parts.json")) {
    if ((Test-Path -LiteralPath $path) -and
        (-not $Force -or (Test-Path -LiteralPath $path -PathType Container))) {
        throw "Output already exists: $path. Use -Force to replace a file."
    }
}
if (-not $IncludeWebRtc) {
    Write-Warning 'WebRTC was explicitly omitted. The current air-gapped Teams path requires this MSI; omission does not migrate it to Windows App or another optimization stack.'
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$examples = Join-Path $repoRoot 'customer-examples\artifacts'
$winGetBuilder = Join-Path $examples 'Microsoft-WinGet\_build\Build-MicrosoftWinGet.ps1'
$uwpBuilder = Join-Path $examples 'BuiltIn-UWP-Apps\_build\Build-BuiltinUwpApps.ps1'
$sources = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\data\public.downloads.parameters.json') -Raw |
    ConvertFrom-Json

function Read-ArtifactInventory {
    param([string]$Path, [string]$Installer)

    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if (-not $archive.GetEntry($Installer)) { throw "Artifact is missing $Installer`: $Path" }
        $entry = $archive.GetEntry('transfer-manifest.json')
        if (-not $entry) { throw "Artifact is missing transfer-manifest.json: $Path" }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { return $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
}

function Get-InstallerVersion {
    param([string]$Path)

    if ([IO.Path]::GetExtension($Path) -eq '.exe') {
        $version = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
    } else {
        $installer = $null
        $database = $null
        $view = $null
        $record = $null
        try {
            $installer = New-Object -ComObject WindowsInstaller.Installer
            $database = $installer.OpenDatabase($Path, 0)
            $view = $database.OpenView("SELECT Value FROM Property WHERE Property='ProductVersion'")
            $view.Execute()
            $record = $view.Fetch()
            $version = $record.StringData(1)
        } finally {
            if ($view) { $view.Close() }
            foreach ($value in @($record, $view, $database, $installer)) {
                if ($value -and [Runtime.InteropServices.Marshal]::IsComObject($value)) {
                    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($value)
                }
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($version)) { throw "Installer has no version metadata: $Path" }
    return $version.Trim()
}

$workingDirectory = Join-Path ([IO.Path]::GetTempPath()) "federalavd-airgap-$([guid]::NewGuid().ToString('N'))"
$stagedZip = $null
$stagedChecksum = $null
try {
    $packageRoot = Join-Path $workingDirectory 'package'
    $artifacts = Join-Path $packageRoot 'artifacts'
    [IO.Directory]::CreateDirectory($artifacts) | Out-Null
    $winGetZip = Join-Path $artifacts 'Microsoft-WinGet.zip'
    $arguments = @{ OutputPath = $winGetZip }
    if ($WinGetReleaseTag) { $arguments.ReleaseTag = $WinGetReleaseTag }
    & $winGetBuilder @arguments | Out-Host
    $winGetInventory = Read-ArtifactInventory -Path $winGetZip -Installer 'Install-MicrosoftWinGet.ps1'
    if (-not $winGetInventory.releaseTag -or @($winGetInventory.assets).Count -ne 4) {
        throw 'WinGet artifact inventory must identify one release and its four assets.'
    }
    $uwpZip = Join-Path $artifacts 'BuiltIn-UWP-Apps.zip'
    $arguments = @{ OutputPath = $uwpZip }
    if ($AppStoreIds) { $arguments.AppStoreIds = $AppStoreIds }
    & $uwpBuilder @arguments | Out-Host
    $uwpInventory = Read-ArtifactInventory -Path $uwpZip -Installer 'Install-BuiltinUwpApps.ps1'
    if (@($uwpInventory.apps).Count -eq 0 -or
        @($uwpInventory.apps | Where-Object { $_.storeId -in @('9N4WGH0Z6VHQ', '9NMZLZ57R3T7') }).Count) {
        throw 'UWP inventory must contain apps and must not include separately licensed HEVC.'
    }

    $entries = [Collections.Generic.List[object]]::new()
    foreach ($artifact in @(
        @{ Path = $winGetZip; Source = 'https://github.com/microsoft/winget-cli'; Versions = $winGetInventory },
        @{ Path = $uwpZip; Source = 'Microsoft Store via winget download'; Versions = $uwpInventory }
    )) {
        $file = Get-Item -LiteralPath $artifact.Path
        $entries.Add([ordered]@{
            fileName = $file.Name
            sizeBytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            source = $artifact.Source
            destination = "customer/artifacts/$($file.Name)"
            consumer = 'Image-build customization'
            inventory = $artifact.Versions
        })
    }
    $fileNames = @{
        WebView2Runtime = 'WebView2.exe'
        VisualStudioRedistributables = 'vc_redist.x64.exe'
        RemoteDesktopWebRTCRedirectorService = 'MsRdcWebRTCSvc.msi'
    }
    $downloadNames = @('WebView2Runtime', 'VisualStudioRedistributables')
    if ($IncludeWebRtc) { $downloadNames += 'RemoteDesktopWebRTCRedirectorService' }
    foreach ($name in $downloadNames) {
        $source = $sources.$name
        if (-not $source -or $source.DownloadUrl -notmatch '^https://' -or
            $source.DestinationFileName -ne $fileNames[$name]) {
            throw "Missing HTTPS download definition or unexpected destination filename for $name."
        }
        $path = Join-Path $artifacts $source.DestinationFileName
        Invoke-WebRequest -Uri $source.DownloadUrl -OutFile $path
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -ne 'Valid' -or
            $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
            throw "Installer is not validly signed by Microsoft: $($source.DestinationFileName)"
        }
        $file = Get-Item -LiteralPath $path
        $entries.Add([ordered]@{
            fileName = $file.Name
            sizeBytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            source = $source.DownloadUrl
            version = Get-InstallerVersion -Path $path
            signatureStatus = [string]$signature.Status
            publisher = $signature.SignerCertificate.Subject
            destination = "customer/artifacts/$($file.Name)"
            consumer = if ($name -eq 'RemoteDesktopWebRTCRedirectorService') {
                'Current air-gapped Teams WebRTC optimization; Windows App support awaits product-group confirmation'
            } else { 'Built-in Teams image installation' }
        })
    }
    [ordered]@{
        schemaVersion = 1
        createdUtc = [DateTimeOffset]::UtcNow.ToString('o')
        sourceRevision = $SourceRevision
        architecture = 'x64'
        disposition = 'Manually staged through approved low-to-high transfer'
        redistributionApprovalRequired = $true
        licenseScope = 'Repository LICENSE covers repository code only; vendor payload terms remain applicable'
        includeWebRtc = $IncludeWebRtc.IsPresent
        artifacts = $entries
        obtainWithinHigh = @('MSTeams-x64.msix', 'teamsbootstrapper.exe', 'Office365DeploymentTool.exe', 'OneDriveSetup.exe')
        unresolved = @('Redistribution and deployment approval', 'Product-group confirmation of Windows App support in air-gapped clouds; target-cloud Teams service connectivity')
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath (Join-Path $packageRoot 'transfer-manifest.json') -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $packageRoot

    $temporaryZip = Join-Path $workingDirectory 'FederalAVD-AirGapPrerequisites.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($packageRoot, $temporaryZip)
    $zipSize = (Get-Item -LiteralPath $temporaryZip).Length
    $hash = (Get-FileHash -LiteralPath $temporaryZip -Algorithm SHA256).Hash
    $zipName = [IO.Path]::GetFileName($outputFile)
    $parts = [Collections.Generic.List[object]]::new()
    $partFiles = [Collections.Generic.List[string]]::new()
    if ($zipSize -gt $ReleasePartSizeBytes) {
        if ([math]::Ceiling($zipSize / $ReleasePartSizeBytes) -gt 9999) {
            throw 'Release would exceed 9999 parts. Increase ReleasePartSizeBytes.'
        }
        $inputStream = [IO.File]::OpenRead($temporaryZip)
        try {
            $buffer = [byte[]]::new(1MB)
            while ($inputStream.Position -lt $inputStream.Length) {
                $partName = '{0}.part{1:D3}' -f $zipName, ($parts.Count + 1)
                $partPath = Join-Path $workingDirectory $partName
                $partStream = [IO.File]::Open($partPath, [IO.FileMode]::CreateNew)
                try {
                    $remaining = [math]::Min($ReleasePartSizeBytes, $inputStream.Length - $inputStream.Position)
                    while ($remaining -gt 0) {
                        $read = $inputStream.Read($buffer, 0, [int][math]::Min($buffer.Length, $remaining))
                        if ($read -eq 0) { throw 'Unexpected end of transfer ZIP while splitting.' }
                        $partStream.Write($buffer, 0, $read)
                        $remaining -= $read
                    }
                } finally { $partStream.Dispose() }
                $parts.Add([ordered]@{
                    fileName = $partName
                    sizeBytes = (Get-Item -LiteralPath $partPath).Length
                    sha256 = (Get-FileHash -LiteralPath $partPath -Algorithm SHA256).Hash
                })
                $partFiles.Add($partPath)
            }
        } finally { $inputStream.Dispose() }
        [ordered]@{
            schemaVersion = 1
            zipFileName = $zipName
            zipSizeBytes = $zipSize
            zipSHA256 = $hash
            partSizeBytes = $ReleasePartSizeBytes
            parts = $parts
        } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $workingDirectory "$zipName.parts.json") -Encoding utf8
    }
    $outputDirectory = Split-Path -Parent $outputFile
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    $releaseFiles = @("$outputFile.sha256")
    $extraFiles = @($partFiles)
    if ($parts.Count) {
        $extraFiles += Join-Path $workingDirectory "$zipName.parts.json"
        foreach ($sourceFile in $extraFiles) {
            $target = Join-Path $outputDirectory ([IO.Path]::GetFileName($sourceFile))
            if ((Test-Path -LiteralPath $target) -and
                (-not $Force -or (Test-Path -LiteralPath $target -PathType Container))) {
                throw "Output already exists: $target. Use -Force to replace a file."
            }
            $releaseFiles += $target
        }
    } else { $releaseFiles += $outputFile }
    $stagedZip = Join-Path $outputDirectory "airgap-$([guid]::NewGuid().ToString('N')).tmp"
    $stagedChecksum = "$stagedZip.sha256"
    Copy-Item -LiteralPath $temporaryZip -Destination $stagedZip
    "$hash  $zipName" | Set-Content -LiteralPath $stagedChecksum -Encoding ascii
    [IO.File]::Move($stagedZip, $outputFile, $Force.IsPresent)
    [IO.File]::Move($stagedChecksum, "$outputFile.sha256", $Force.IsPresent)
    foreach ($sourceFile in $extraFiles) {
        $target = Join-Path $outputDirectory ([IO.Path]::GetFileName($sourceFile))
        $stagedPart = "$stagedZip.part"
        try {
            Copy-Item -LiteralPath $sourceFile -Destination $stagedPart
            [IO.File]::Move($stagedPart, $target, $Force.IsPresent)
        } finally {
            if (Test-Path -LiteralPath $stagedPart) { Remove-Item -LiteralPath $stagedPart -Force }
        }
    }
    [pscustomobject]@{
        OutputPath = $outputFile
        SHA256 = $hash
        ArtifactCount = $entries.Count
        IncludeWebRtc = $IncludeWebRtc.IsPresent
        ReleaseFiles = $releaseFiles
        PartCount = $parts.Count
    }
} finally {
    foreach ($path in @($stagedZip, $stagedChecksum, $workingDirectory)) {
        if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
}
