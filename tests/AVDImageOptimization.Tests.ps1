$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$optimizerPath = Join-Path -Path $repoRoot -ChildPath 'deployments\imageBuild\scripts\Optimize-AVDImage.ps1'
$optimizerReadmePath = Join-Path -Path $repoRoot -ChildPath 'deployments\imageBuild\scripts\README.md'
$imageBuildReadmePath = Join-Path -Path $repoRoot -ChildPath 'deployments\imageBuild\README.md'
$imageBuildGuidePath = Join-Path -Path $repoRoot -ChildPath 'docs\image-build.md'
$oneDriveArtifactPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\artifacts\Configure-OneDriveKFMPolicy'
$oneDriveScriptPath = Join-Path -Path $oneDriveArtifactPath -ChildPath 'Configure-OneDrive.ps1'
$oneDriveReadmePath = Join-Path -Path $oneDriveArtifactPath -ChildPath 'README.md'

foreach ($scriptPath in @($optimizerPath, $oneDriveScriptPath)) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -gt 0) {
        throw "$(Split-Path -Path $scriptPath -Leaf) has $($parseErrors.Count) PowerShell parse error(s)."
    }
    if (Get-Content -LiteralPath $scriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) {
        throw "$(Split-Path -Path $scriptPath -Leaf) contains non-ASCII content."
    }
}

$optimizerText = Get-Content -LiteralPath $optimizerPath -Raw
$optimizerExpectations = @(
    "[ValidateSet('None', 'NonPersistent-UpdatesOnly', 'NonPersistent-Full', 'Persistent')]",
    "`$RunFullOptimization = `$OptimizationProfile -in @('NonPersistent-Full', 'Persistent')",
    "`$RunNonPersistentSections = `$OptimizationProfile -in @('NonPersistent-UpdatesOnly', 'NonPersistent-Full')",
    "Set-Service -Name 'defragsvc' -StartupType Manual",
    "`$ssCadence = if (`$OptimizationProfile -eq 'Persistent') { 30 } else { 1 }",
    "Set-PolicyValue -Path `$ssPolicyPath -Name 'AllowStorageSenseGlobal' -Value 1",
    "Set-PolicyValue -Path `$ssPolicyPath -Name 'AllowStorageSenseTemporaryFilesCleanup' -Value 1",
    "Set-PolicyValue -Path `$ssPolicyPath -Name 'ConfigStorageSenseRecycleBinCleanupThreshold' -Value 30",
    "Set-PolicyValue -Path `$ssPolicyPath -Name 'ConfigStorageSenseDownloadsCleanupThreshold' -Value 0",
    "Set-PolicyValue -Path `$ssPolicyPath -Name 'ConfigStorageSenseCloudContentDehydrationThreshold' -Value 30"
)
foreach ($expectedText in $optimizerExpectations) {
    if (-not $optimizerText.Contains($expectedText)) {
        throw "Optimize-AVDImage.ps1 is missing required behavior: $expectedText"
    }
}
if ($optimizerText -match "(?m)^\s*Set-PolicyValue .*PreventNetworkTrafficPreUserSignIn") {
    throw 'Optimize-AVDImage.ps1 enables PreventNetworkTrafficPreUserSignIn, which conflicts with silent OneDrive configuration.'
}

$oneDriveText = Get-Content -LiteralPath $oneDriveScriptPath -Raw
$oneDriveExpectations = @(
    "'SilentAccountConfig' -RegistryType DWORD -RegistryData 1",
    "'FilesOnDemandEnabled' -RegistryType DWORD -RegistryData 1",
    "'KFMSilentOptIn' -RegistryType String -RegistryData `$TenantID",
    "'KFMBlockOptOut' -RegistryType DWORD -RegistryData 1",
    "'EnableEnhancedShellExperienceForRemoteApp' -RegistryType DWORD -RegistryData 1"
)
foreach ($expectedText in $oneDriveExpectations) {
    if (-not $oneDriveText.Contains($expectedText)) {
        throw "Configure-OneDrive.ps1 is missing required behavior: $expectedText"
    }
}

$optimizerReadme = Get-Content -LiteralPath $optimizerReadmePath -Raw
foreach ($expectedText in @('Cadence', 'Daily (`1`)', 'Monthly (`30`)', 'defragsvc', 'physical size of the VHDX')) {
    if (-not $optimizerReadme.Contains($expectedText)) {
        throw "The optimizer README is missing required guidance: $expectedText"
    }
}

$imageBuildReadme = Get-Content -LiteralPath $imageBuildReadmePath -Raw
if (-not $imageBuildReadme.Contains('Sets Optimize Drives (`defragsvc`) to Manual')) {
    throw 'The imageBuild README does not document the Optimize Drives Manual startup type.'
}
if ($imageBuildReadme.Contains('Disables Superfetch/SysMain, Optimize Drives')) {
    throw 'The imageBuild README still claims that Optimize Drives is disabled.'
}

$imageBuildGuide = Get-Content -LiteralPath $imageBuildGuidePath -Raw
foreach ($expectedText in @('### OneDrive, FSLogix, and Storage Sense', '#### How Profile Space Is Reclaimed', '#### KFM Rollout Checklist')) {
    if (-not $imageBuildGuide.Contains($expectedText)) {
        throw "The image-build guide is missing required guidance: $expectedText"
    }
}

$oneDriveReadme = Get-Content -LiteralPath $oneDriveReadmePath -Raw
foreach ($expectedText in @('Microsoft Entra', 'Files On-Demand', 'FSLogix VHD disk compaction', 'Unsynchronized local')) {
    if (-not $oneDriveReadme.Contains($expectedText)) {
        throw "The OneDrive KFM README is missing required guidance: $expectedText"
    }
}
foreach ($staleText in @('Connect-AzureAD', 'Update-LocalGPOTextFile', 'teams-on-avd', 'Files stored in OneDrive, not in FSLogix profile')) {
    if ($oneDriveReadme.Contains($staleText)) {
        throw "The OneDrive KFM README contains stale or inaccurate guidance: $staleText"
    }
}

Write-Output 'AVD image optimization tests passed.'
