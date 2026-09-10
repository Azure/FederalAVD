<#
.SYNOPSIS
    Builds an offline Microsoft-WinGet artifact zip from an official winget-cli release.

.DESCRIPTION
    Resolves one stable microsoft/winget-cli GitHub release, downloads its App Installer bundle,
    dependency archive, dependency metadata, and offline license, verifies published SHA256 digests
    when available, and creates Microsoft-WinGet.zip for transfer.

    The build script lives below the artifact root so Invoke-Customization.ps1 cannot select it as
    the artifact entry script. The generated zip contains only the runtime installer and payload.

.PARAMETER OutputPath
    Output zip path or a directory in which Microsoft-WinGet.zip will be created.

.PARAMETER ReleaseTag
    Optional exact GitHub release tag, such as v1.29.290. When omitted, the latest stable release is
    used. Prerelease and draft releases are rejected.

.PARAMETER WorkingDirectory
    Temporary working directory used for downloads and staging.

.PARAMETER KeepWorkingDirectory
    Retains the working directory after the package is created.

.EXAMPLE
    .\Build-MicrosoftWinGet.ps1 -OutputPath 'C:\AirGapTransfer\Microsoft-WinGet.zip'

.EXAMPLE
    .\Build-MicrosoftWinGet.ps1 `
        -ReleaseTag 'v1.29.290' `
        -OutputPath 'C:\AirGapTransfer'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [ValidatePattern('^v[0-9]+(?:\.[0-9]+){1,3}(?:-[A-Za-z0-9.-]+)?$')]
    [string]$ReleaseTag,

    [string]$WorkingDirectory = (Join-Path $env:TEMP "Microsoft-WinGet-$([guid]::NewGuid().ToString('N'))"),

    [switch]$KeepWorkingDirectory
)

$ErrorActionPreference = 'Stop'
$Repository = 'microsoft/winget-cli'
$ArtifactRoot = Split-Path -Path $PSScriptRoot -Parent
$RuntimeInstaller = Join-Path $ArtifactRoot 'Install-MicrosoftWinGet.ps1'
$DownloadRoot = Join-Path $WorkingDirectory 'downloads'
$StageRoot = Join-Path $WorkingDirectory 'Microsoft-WinGet'
$RequiredAssetPatterns = [ordered]@{
    Bundle = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    DependenciesArchive = 'DesktopAppInstaller_Dependencies.zip'
    DependenciesMetadata = 'DesktopAppInstaller_Dependencies.json'
    License = '*_License1.xml'
}

function Get-ReleaseMetadata {
    $releaseUri = if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
        "https://api.github.com/repos/$Repository/releases/latest"
    }
    else {
        "https://api.github.com/repos/$Repository/releases/tags/$ReleaseTag"
    }

    Write-Verbose "Resolving winget-cli release from '$releaseUri'..."
    $headers = @{
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'FederalAVD-Microsoft-WinGet-Builder'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        $headers.Authorization = "Bearer $($env:GH_TOKEN)"
    }

    $release = Invoke-RestMethod -Method Get -Uri $releaseUri -Headers $headers
    if ($release.draft -or $release.prerelease) {
        throw "Release '$($release.tag_name)' is not a stable published release."
    }
    return $release
}

function Get-RequiredReleaseAssets {
    param([Parameter(Mandatory)]$Release)

    $resolvedAssets = [ordered]@{}
    foreach ($assetName in $RequiredAssetPatterns.Keys) {
        $pattern = $RequiredAssetPatterns[$assetName]
        $matchingAssets = @($Release.assets | Where-Object { $_.name -like $pattern })
        if ($matchingAssets.Count -ne 1) {
            throw "Expected exactly one asset matching '$pattern' in release '$($Release.tag_name)'; found $($matchingAssets.Count)."
        }
        $resolvedAssets[$assetName] = $matchingAssets[0]
    }
    return $resolvedAssets
}

function Save-ReleaseAsset {
    param(
        [Parameter(Mandatory)]$Asset,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )

    $destinationPath = Join-Path $DestinationDirectory ([string]$Asset.name)
    Write-Verbose "Downloading '$($Asset.name)'..."
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $destinationPath -UseBasicParsing

    if (-not [string]::IsNullOrWhiteSpace([string]$Asset.digest)) {
        if ([string]$Asset.digest -notmatch '^sha256:([0-9A-Fa-f]{64})$') {
            throw "Unsupported digest '$($Asset.digest)' for '$($Asset.name)'."
        }
        $expectedHash = $Matches[1].ToUpperInvariant()
        $actualHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
        if ($actualHash -ne $expectedHash) {
            throw "SHA256 mismatch for '$($Asset.name)'. Expected '$expectedHash'; received '$actualHash'."
        }
        Write-Verbose "Verified SHA256 for '$($Asset.name)'."
    }
    else {
        Write-Warning "Release asset '$($Asset.name)' does not publish a digest; source and transport were validated but no hash comparison was available."
    }

    return Get-Item -LiteralPath $destinationPath
}

if (-not (Test-Path -LiteralPath $RuntimeInstaller -PathType Leaf)) {
    throw "Runtime installer not found: $RuntimeInstaller"
}

$resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ([System.IO.Path]::GetExtension($resolvedOutputPath) -ne '.zip') {
    $resolvedOutputPath = Join-Path $resolvedOutputPath 'Microsoft-WinGet.zip'
}
$outputDirectory = Split-Path $resolvedOutputPath -Parent

try {
    New-Item -Path $DownloadRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $StageRoot -ItemType Directory -Force | Out-Null

    $release = Get-ReleaseMetadata
    $assets = Get-RequiredReleaseAssets -Release $release
    Write-Output "Selected stable release '$($release.tag_name)' published $($release.published_at)."

    $downloadedAssets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($asset in $assets.Values) {
        Write-Output "Downloading and validating '$($asset.name)'..."
        $downloadedAssets.Add((Save-ReleaseAsset -Asset $asset -DestinationDirectory $DownloadRoot))
    }

    Copy-Item -LiteralPath $RuntimeInstaller -Destination $StageRoot -Force
    foreach ($downloadedAsset in $downloadedAssets) {
        Copy-Item -LiteralPath $downloadedAsset.FullName -Destination $StageRoot -Force
    }

    [ordered]@{
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        repository = $Repository
        releaseTag = [string]$release.tag_name
        releasePublishedUtc = ([DateTimeOffset]$release.published_at).ToUniversalTime().ToString('o')
        assets = @($downloadedAssets | ForEach-Object {
            [ordered]@{
                name = $_.Name
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                sizeBytes = $_.Length
            }
        })
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $StageRoot 'transfer-manifest.json') -Encoding UTF8

    if ($PSCmdlet.ShouldProcess($resolvedOutputPath, "Create offline Microsoft WinGet artifact from release '$($release.tag_name)'")) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
        Remove-Item -LiteralPath $resolvedOutputPath -Force -ErrorAction SilentlyContinue
        Compress-Archive -Path (Join-Path $StageRoot '*') -DestinationPath $resolvedOutputPath -CompressionLevel Optimal

        $zip = Get-Item -LiteralPath $resolvedOutputPath
        Write-Output "Created '$($zip.FullName)' ($([math]::Round($zip.Length / 1MB, 1)) MB)."
        Write-Output "Release: $($release.tag_name); assets: $($downloadedAssets.Count)."
    }
}
finally {
    if (-not $KeepWorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory)) {
        Remove-Item -LiteralPath $WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif ($KeepWorkingDirectory) {
        Write-Output "Working directory retained at '$WorkingDirectory'."
    }
}
