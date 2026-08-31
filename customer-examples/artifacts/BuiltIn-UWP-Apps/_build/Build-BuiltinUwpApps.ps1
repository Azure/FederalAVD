<#
.SYNOPSIS
    Builds an offline BuiltIn-UWP-Apps artifact zip from Microsoft Store product IDs.

.DESCRIPTION
    Downloads Store packages with winget on a connected Windows workstation, keeps the best
    package variant for x64 AVD hosts, removes Arm dependencies, consolidates duplicate framework
    packages into SharedDependencies, and creates BuiltIn-UWP-Apps.zip for transfer.

    The build script lives below the artifact root so Invoke-Customization.ps1 cannot select it as
    the artifact entry script. The generated zip contains only the runtime installer and payload.

.EXAMPLE
    .\Build-BuiltinUwpApps.ps1 `
        -AppStoreIds @('9WZDNCRFHVN5', '9PCFS5B6T72H', '9MZ95KL8MR0L') `
        -OutputPath 'C:\AirGapTransfer\BuiltIn-UWP-Apps.zip'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$AppStoreIds,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [hashtable]$AppFolderNames = @{},

    [string[]]$NeutralArchitectureIds = @('9P1J8S7CCWWT'),

    [string]$WorkingDirectory = (Join-Path $env:TEMP "BuiltIn-UWP-Apps-$([guid]::NewGuid().ToString('N'))"),

    [switch]$KeepWorkingDirectory
)

$ErrorActionPreference = 'Stop'
$PackageExtensions = @('.msixbundle', '.appxbundle', '.msix', '.appx')
$ArtifactRoot = Split-Path -Path $PSScriptRoot -Parent
$RuntimeInstaller = Join-Path $ArtifactRoot 'Install-BuiltinUwpApps.ps1'
$DownloadRoot = Join-Path $WorkingDirectory 'downloads'
$StageRoot = Join-Path $WorkingDirectory 'BuiltIn-UWP-Apps'

$DefaultFolderNames = @{
    '9WZDNCRFHVN5' = 'Calculator'
    '9PCFS5B6T72H' = 'Paint'
    '9MZ95KL8MR0L' = 'SnippingTool'
    '9MSMLRH6LZF3' = 'Notepad'
    '9P1J8S7CCWWT' = 'Clipchamp'
    '9WZDNCRFJBH4' = 'Photos'
    '9NBLGGH4QGHW' = 'StickyNotes'
    '9N0DX20HK701' = 'Terminal'
    '9N4D0MSMP0PT' = 'VP9VideoExtensions'
    '9N5TDP8VCMHS' = 'WebMediaExtensions'
    '9PG2DK419DRG' = 'WebpImageExtension'
    '9MVZQVXJBQ9V' = 'AV1VideoExtension'
    '9N95Q1ZZPMH4' = 'MPEG2VideoExtension'
    '9PMMSR1CGPWG' = 'HEIFImageExtension'
}

function Get-PackageVersion {
    param([System.IO.FileInfo]$File)

    if ($File.Name -match '_([0-9]+(?:\.[0-9]+){1,3})[_.]') {
        try { return [Version]$Matches[1] } catch { return [Version]'0.0.0.0' }
    }
    return [Version]'0.0.0.0'
}

function Select-BestMainPackage {
    param([System.IO.FileInfo[]]$Candidates)

    return $Candidates |
        Sort-Object @{ Expression = { Get-PackageVersion $_ }; Descending = $true },
                    @{ Expression = {
                        if ($_.Name -match '(?i)[_.]x64[_.]' -and $_.Name -notmatch '(?i)[_.]arm') { return 0 }
                        if ($_.Name -match '(?i)[_.](neutral|universal)[_.]' -or $_.Name -match '(?i)[_.]x64\.arm') { return 1 }
                        return 2
                    } },
                    @{ Expression = {
                        switch ($_.Extension.ToLowerInvariant()) {
                            '.msixbundle' { return 0 }
                            '.appxbundle' { return 1 }
                            '.msix' { return 2 }
                            '.appx' { return 3 }
                            default { return 4 }
                        }
                    } },
                    @{ Expression = { $_.Length }; Descending = $true } |
        Select-Object -First 1
}

function Optimize-SharedDependencies {
    param([string]$ParentDirectory)

    $dependencies = @(Get-ChildItem -Path $ParentDirectory -Directory |
        Where-Object { $_.Name -ne 'SharedDependencies' } |
        ForEach-Object {
            Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Extension.ToLowerInvariant() -in $PackageExtensions -and
                    $_.FullName -match '(?i)\\dependencies\\' -and
                    $_.Name -match '(?i)_(x86|x64|neutral)[._]'
                }
        })

    $sharedDirectory = Join-Path $ParentDirectory 'SharedDependencies'
    New-Item -Path $sharedDirectory -ItemType Directory -Force | Out-Null

    foreach ($group in ($dependencies | Group-Object { $_.Name -replace '_[0-9]+(?:\.[0-9]+){1,3}(?=_)', '' })) {
        $best = $group.Group |
            Sort-Object { Get-PackageVersion $_ } -Descending |
            Select-Object -First 1
        Copy-Item -Path $best.FullName -Destination (Join-Path $sharedDirectory $best.Name) -Force
    }

    Get-ChildItem -Path $ParentDirectory -Directory |
        Where-Object { $_.Name -ne 'SharedDependencies' } |
        ForEach-Object {
            $dependencyDirectory = Join-Path $_.FullName 'Dependencies'
            if (Test-Path $dependencyDirectory) {
                Remove-Item -Path $dependencyDirectory -Recurse -Force
            }
        }

    return $dependencies.Count
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget is required. Install or update App Installer on the connected workstation.'
}
if (-not (Test-Path $RuntimeInstaller -PathType Leaf)) {
    throw "Runtime installer not found: $RuntimeInstaller"
}
if ($AppStoreIds.Count -ne (@($AppStoreIds | Sort-Object -Unique)).Count) {
    throw 'AppStoreIds contains duplicate values.'
}
foreach ($storeId in $AppStoreIds) {
    if ($storeId -notmatch '^[A-Za-z0-9]{10,14}$') {
        throw "Invalid Microsoft Store product ID '$storeId'. Use the alphanumeric product ID shown by winget."
    }
}

$resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ([System.IO.Path]::GetExtension($resolvedOutputPath) -ne '.zip') {
    $resolvedOutputPath = Join-Path $resolvedOutputPath 'BuiltIn-UWP-Apps.zip'
}
$outputDirectory = Split-Path $resolvedOutputPath -Parent

try {
    New-Item -Path $DownloadRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $StageRoot -ItemType Directory -Force | Out-Null
    Copy-Item -Path $RuntimeInstaller -Destination $StageRoot -Force

    $manifestEntries = [System.Collections.Generic.List[object]]::new()

    foreach ($storeId in $AppStoreIds) {
        $folderName = if ($AppFolderNames.ContainsKey($storeId)) {
            [string]$AppFolderNames[$storeId]
        } elseif ($DefaultFolderNames.ContainsKey($storeId)) {
            [string]$DefaultFolderNames[$storeId]
        } else {
            $storeId
        }
        if ($folderName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
            throw "App folder name '$folderName' for '$storeId' is invalid."
        }

        $appDownloadDirectory = Join-Path $DownloadRoot $storeId
        New-Item -Path $appDownloadDirectory -ItemType Directory -Force | Out-Null
        $wingetArguments = @(
            'download', '--id', $storeId, '--source', 'msstore',
            '--download-directory', $appDownloadDirectory,
            '--skip-license', '--accept-source-agreements', '--accept-package-agreements',
            '--disable-interactivity'
        )
        if ($storeId -notin $NeutralArchitectureIds) {
            $wingetArguments += @('--architecture', 'x64')
        }

        Write-Output "[$storeId] Downloading Microsoft Store package into '$folderName'..."
        & winget @wingetArguments
        if ($LASTEXITCODE -ne 0) {
            throw "winget download failed for '$storeId' with exit code $LASTEXITCODE."
        }

        $mainCandidates = @(Get-ChildItem -Path $appDownloadDirectory -File |
            Where-Object { $_.Extension.ToLowerInvariant() -in $PackageExtensions })
        if ($mainCandidates.Count -eq 0) {
            throw "No MSIX or APPX package was downloaded for '$storeId'."
        }
        $bestMain = Select-BestMainPackage -Candidates $mainCandidates
        $mainCandidates | Where-Object FullName -ne $bestMain.FullName | Remove-Item -Force

        Get-ChildItem -Path $appDownloadDirectory -Recurse -File |
            Where-Object {
                $_.Extension.ToLowerInvariant() -in $PackageExtensions -and
                $_.FullName -match '(?i)\\dependencies\\' -and
                $_.Name -notmatch '(?i)_(x86|x64|neutral)[._]'
            } | Remove-Item -Force

        $appStageDirectory = Join-Path $StageRoot $folderName
        New-Item -Path $appStageDirectory -ItemType Directory -Force | Out-Null
        Copy-Item -Path (Join-Path $appDownloadDirectory '*') -Destination $appStageDirectory -Recurse -Force

        $manifestEntries.Add([ordered]@{
            storeId = $storeId
            folder = $folderName
            package = $bestMain.Name
            version = (Get-PackageVersion $bestMain).ToString()
        })
    }

    $dependencyCount = Optimize-SharedDependencies -ParentDirectory $StageRoot
    [ordered]@{
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        architecture = 'x64'
        apps = $manifestEntries
        dependencyFilesBeforeDeduplication = $dependencyCount
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $StageRoot 'transfer-manifest.json') -Encoding utf8

    if ($PSCmdlet.ShouldProcess($resolvedOutputPath, 'Create offline UWP artifact zip')) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
        Remove-Item -Path $resolvedOutputPath -Force -ErrorAction SilentlyContinue
        Compress-Archive -Path (Join-Path $StageRoot '*') -DestinationPath $resolvedOutputPath -CompressionLevel Optimal
    }

    $zip = Get-Item $resolvedOutputPath
    Write-Output "Created '$($zip.FullName)' ($([math]::Round($zip.Length / 1MB, 1)) MB)."
    Write-Output "Apps: $($manifestEntries.Count); dependency files before deduplication: $dependencyCount."
}
finally {
    if (-not $KeepWorkingDirectory -and (Test-Path $WorkingDirectory)) {
        Remove-Item -Path $WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($KeepWorkingDirectory) {
        Write-Output "Working directory retained at '$WorkingDirectory'."
    }
}