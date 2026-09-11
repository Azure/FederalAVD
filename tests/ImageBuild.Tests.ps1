$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$optimizerPath = Join-Path -Path $repoRoot -ChildPath 'deployments\imageBuild\scripts\Optimize-AVDImage.ps1'
$optimizerReadmePath = Join-Path -Path $repoRoot -ChildPath 'deployments\imageBuild\scripts\README.md'
$imageBuildReadmePath = Join-Path -Path $repoRoot -ChildPath 'deployments\imageBuild\README.md'
$imageBuildGuidePath = Join-Path -Path $repoRoot -ChildPath 'docs\image-build.md'
$oneDriveArtifactPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\artifacts\Configure-OneDrivePolicy'
$oneDriveScriptPath = Join-Path -Path $oneDriveArtifactPath -ChildPath 'Configure-OneDrivePolicy.ps1'
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
    '[Nullable[int]]$WarningMinDiskSpaceLimitInMB',
    '[Nullable[int]]$MinDiskSpaceLimitInMB',
    '$null -ne $MinDiskSpaceLimitInMB',
    '$null -ne $WarningMinDiskSpaceLimitInMB',
    '$MinDiskSpaceLimitInMB -gt $WarningMinDiskSpaceLimitInMB',
    "'SilentAccountConfig' -RegistryType DWORD -RegistryData 1",
    "'FilesOnDemandEnabled' -RegistryType DWORD -RegistryData 1",
    "'KFMSilentOptIn' -RegistryType String -RegistryData `$TenantID",
    "'KFMBlockOptOut' -RegistryType DWORD -RegistryData 1",
    "'WarningMinDiskSpaceLimitInMB' -RegistryType DWORD -RegistryData `$WarningMinDiskSpaceLimitInMB",
    "'MinDiskSpaceLimitInMB' -RegistryType DWORD -RegistryData `$MinDiskSpaceLimitInMB",
    "-Name 'WarningMinDiskSpaceLimitInMB' -Value `$WarningMinDiskSpaceLimitInMB -Type DWord",
    "-Name 'MinDiskSpaceLimitInMB' -Value `$MinDiskSpaceLimitInMB -Type DWord",
    "'EnableEnhancedShellExperienceForRemoteApp' -RegistryType DWORD -RegistryData 1"
)
foreach ($expectedText in $oneDriveExpectations) {
    if (-not $oneDriveText.Contains($expectedText)) {
        throw "Configure-OneDrivePolicy.ps1 is missing required behavior: $expectedText"
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
foreach ($expectedText in @('Microsoft Entra', 'Files On-Demand', 'FSLogix VHD disk compaction', 'Unsynchronized local', 'WarningMinDiskSpaceLimitInMB', 'MinDiskSpaceLimitInMB')) {
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

$repoRoot = Split-Path -Parent $PSScriptRoot
$bicepPath = Join-Path $repoRoot 'deployments\imageBuild\imageBuild.bicep'
$armPath = Join-Path $repoRoot 'deployments\imageBuild\imageBuild.json'
$formPath = Join-Path $repoRoot 'deployments\imageBuild\uiFormDefinition.json'

Describe 'Image Build regional replication behavior' {
    It 'limits the primary Compute Gallery to the deployment subscription and region' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $prereqs = $form.view.properties.steps | Where-Object { $_.name -eq 'prereqs' }
        $gallerySection = $prereqs.elements | Where-Object { $_.name -eq 'gallery' }
        $gallerySelector = $gallerySection.elements | Where-Object { $_.name -eq 'gallery' }

        $gallerySelector.options.filter.subscription | Should Be 'onBasics'
        $gallerySelector.options.filter.location | Should Be 'onBasics'
    }

    It 'does not persistently add a remote-gallery region to primary-gallery targets' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $bicep | Should Not Match 'var imageVersionReplicationRegions = empty\(remoteComputeGalleryResourceId\)'
        $bicep | Should Match 'imageVersionReplicationRegions: localImageVersionTargetRegionsWithEncryption'
        $bicep | Should Not Match 'initialLocalImageVersionTargetRegions'
    }

    It 'keeps the generated capture target-regions expression below the ARM limit' {
        $arm = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json
        $expression = $arm.resources.captureImage.properties.parameters.imageVersionReplicationRegions

        $expression.Length | Should BeLessThan 81920
    }

    It 'captures the remote gallery version from the build source with source and remote targets' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $bicep | Should Match "module remoteImageVersion[\s\S]*?location: computeLocation"
        $bicep | Should Match 'var remoteImageVersionTargetRegions = map\(defaultRemoteImageVersionTargetRegions'
        $bicep | Should Match 'var defaultRemoteImageVersionTargetRegions = \[[\s\S]*?name: computeLocation[\s\S]*?name: remoteLocation'
    }

    It 'does not use an encrypted gallery image version as the remote source' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $bicep | Should Not Match 'sourceId: captureImage\.outputs\.imageVersionId'
        $bicep | Should Not Match 'removeRemoteSourceBridgeReplica'
        $bicep | Should Match "sourceId: contains\(effectiveGalleryImageDefinitionSecurityType, 'Supported'\) \? captureImage\.outputs\.managedImageId : ''"
        $bicep | Should Match "virtualMachineId: !contains\(effectiveGalleryImageDefinitionSecurityType, 'Supported'\) \? imageVm\.outputs\.resourceId : ''"
    }

    It 'supports regional standard and Confidential VM DES values' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $bicep | Should Match 'diskEncryptionSetResourceId: string\?'
        $bicep | Should Match 'confidentialVMDiskEncryptionSetResourceId: string\?'
        $bicep | Should Match 'region\.\?diskEncryptionSetResourceId'
        $bicep | Should Match 'region\.\?confidentialVMDiskEncryptionSetResourceId'
    }

    It 'collects regional DES selections in the replication grid' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $imageDest = $form.view.properties.steps | Where-Object { $_.name -eq 'imageDest' }
        $imageVersion = $imageDest.elements | Where-Object { $_.name -eq 'imageVersion' }
        $disasterRecovery = $imageDest.elements | Where-Object { $_.name -eq 'disasterRecovery' }
        $additionalRegionsChoice = $imageVersion.elements | Where-Object { $_.name -eq 'specifyAdditionalReplicaRegions' }
        $additionalReplicaRegions = $imageVersion.elements | Where-Object { $_.name -eq 'additionalReplicaRegions' }
        $remoteGalleryInfo = $disasterRecovery.elements | Where-Object { $_.name -eq 'infoDisasterRecovery' }
        $remoteGalleryChoice = $disasterRecovery.elements | Where-Object { $_.name -eq 'specifyRemoteGallery' }
        $columns = $additionalReplicaRegions.constraints.columns

        $additionalRegionsChoice.type | Should Be 'Microsoft.Common.OptionsGroup'
        $additionalRegionsChoice.defaultValue | Should Be 'No'
        @($additionalRegionsChoice.constraints.allowedValues).Count | Should Be 2
        @($additionalRegionsChoice.constraints.allowedValues.value) -contains $true | Should Be $true
        @($additionalRegionsChoice.constraints.allowedValues.value) -contains $false | Should Be $true
        $additionalRegionsChoice.label | Should Match 'primary Compute Gallery'
        $additionalReplicaRegions.label | Should Be 'Additional Replica Regions'
        $replicaWarning = $imageVersion.elements | Where-Object { $_.name -eq 'repRegionsText' }
        $replicaWarning.type | Should Be 'Microsoft.Common.InfoBox'
        $replicaWarning.options.style | Should Be 'Warning'
        $replicaWarning.options.text | Should Match 'cannot enforce'
        $replicaWarning.options.text | Should Match 'region-to-DES mismatch'
        $remoteGalleryInfo.options.text | Should Match 'primary Compute Gallery'
        $remoteGalleryInfo.options.text | Should Match 'separate Compute Gallery'
        $remoteGalleryChoice.label | Should Match 'separate Compute Gallery'

        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.type |
            Should Be 'Microsoft.Common.DropDown'
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.type |
            Should Be 'Microsoft.Common.DropDown'
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.multiLine |
            Should Be $true
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.multiLine |
            Should Be $true
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.constraints.required |
            Should Match 'galleryImageVersionEncryptionType'
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.constraints.required |
            Should Not Match '\$rowIndex|additionalReplicaRegions'
        (($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.PSObject.Properties.Name -contains 'visible') |
            Should Be $false
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Match 'diskEncryptionSetsApi\.transformed\.(customerManaged|doubleEncryption)'
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Match 'NotApplicable'
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Not Match '\$rowIndex|additionalReplicaRegions'
        ($columns | Where-Object { $_.id -eq 'diskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Match 'Region:'
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.constraints.required |
            Should Match 'EncryptedWithCmk'
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.constraints.required |
            Should Not Match '\$rowIndex|replicationRegions'
        (($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.PSObject.Properties.Name -contains 'visible') |
            Should Be $false
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Match 'NotApplicable'
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Not Match '\$rowIndex|additionalReplicaRegions'
        ($columns | Where-Object { $_.id -eq 'confidentialVMDiskEncryptionSetResourceId' }).element.constraints.allowedValues |
            Should Match 'Region:'
        ($columns | Where-Object { $_.id -eq 'name' }).element.constraints.allowedValues |
            Should Match "not\(equals\(toLower\(replace\(item, ' ', ''\)\), toLower\(steps\('basics'\)\.scope\.location\.name\)\)\)"
    }

    It 'places all encryption controls in active image version and disaster recovery sections' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $imageDest = $form.view.properties.steps | Where-Object { $_.name -eq 'imageDest' }
        $imageVersion = $imageDest.elements | Where-Object { $_.name -eq 'imageVersion' }
        $disasterRecovery = $imageDest.elements | Where-Object { $_.name -eq 'disasterRecovery' }

        @($imageDest.elements | Where-Object { $_.name -eq 'encryption' }).Count | Should Be 0
        @($imageVersion.elements | Where-Object { $_.name -eq 'confidentialVMEncryptionType' }).Count | Should Be 1
        @($imageVersion.elements | Where-Object { $_.name -eq 'existingConfidentialVMDiskEncryptionSetResourceId' }).Count | Should Be 1
        @($disasterRecovery.elements | Where-Object { $_.name -eq 'existingRemoteConfidentialVMDiskEncryptionSetResourceId' }).Count | Should Be 1
    }

    It 'selects one encryption type and filters primary and remote DES choices exactly' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $imageDest = $form.view.properties.steps | Where-Object { $_.name -eq 'imageDest' }
        $imageVersion = $imageDest.elements | Where-Object { $_.name -eq 'imageVersion' }
        $disasterRecovery = $imageDest.elements | Where-Object { $_.name -eq 'disasterRecovery' }
        $encryptionType = $imageVersion.elements | Where-Object { $_.name -eq 'galleryImageVersionEncryptionType' }
        $desApi = $imageVersion.elements | Where-Object { $_.name -eq 'diskEncryptionSetsApi' }
        $primaryDes = $imageVersion.elements | Where-Object { $_.name -eq 'existingDiskEncryptionSetResourceId' }
        $remoteDes = $disasterRecovery.elements | Where-Object { $_.name -eq 'existingRemoteDiskEncryptionSetResourceId' }

        $encryptionType.defaultValue | Should Be 'Platform-managed key'
        @($encryptionType.constraints.allowedValues.value) | Should Be @(
            'PlatformManaged'
            'EncryptionAtRestWithCustomerKey'
            'EncryptionAtRestWithPlatformAndCustomerKeys'
        )
        $desApi.condition | Should Match "not\(empty\(steps\('basics'\)\.scope\.subscription\)\)"
        $desApi.request.path | Should Match 'api-version=2024-03-02'
        $desApi.request.transforms.customerManaged | Should Match "properties\.encryptionType == 'EncryptionAtRestWithCustomerKey'"
        $desApi.request.transforms.doubleEncryption | Should Match "properties\.encryptionType == 'EncryptionAtRestWithPlatformAndCustomerKeys'"
        $desApi.request.transforms.confidentialVm | Should Match "properties\.encryptionType == 'ConfidentialVmEncryptedWithCustomerKey'"
        $desApi.request.transforms.customerManaged | Should Match 'sort_by\([\s\S]*?, &location\)'
        $desApi.request.transforms.doubleEncryption | Should Match 'sort_by\([\s\S]*?, &location\)'
        $desApi.request.transforms.confidentialVm | Should Match 'sort_by\([\s\S]*?, &location\)'
        $primaryDes.constraints.allowedValues | Should Match 'imageVersion\.diskEncryptionSetsApi\.transformed\.customerManaged'
        $primaryDes.constraints.allowedValues | Should Match 'imageVersion\.diskEncryptionSetsApi\.transformed\.doubleEncryption'
        $remoteDes.constraints.allowedValues | Should Match 'imageVersion\.diskEncryptionSetsApi\.transformed\.customerManaged'
        $remoteDes.constraints.allowedValues | Should Match 'imageVersion\.diskEncryptionSetsApi\.transformed\.doubleEncryption'
        $primaryDes.constraints.allowedValues | Should Not Match "not\(equals\(des\.properties\.encryptionType"
        $remoteDes.constraints.allowedValues | Should Not Match "not\(equals\(des\.properties\.encryptionType"
        $primaryDes.constraints.allowedValues | Should Not Match "steps\('prereqs'\)\.gallery\.gallery\.id"
    }

    It 'emits source and additional-region DES IDs through their respective inputs' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $outputs = $form.view.outputs.parameters
        $outputs.diskEncryptionSetResourceId | Should Match 'existingDiskEncryptionSetResourceId'
        $outputs.confidentialVMDiskEncryptionSetResourceId | Should Match 'existingConfidentialVMDiskEncryptionSetResourceId'
        $outputs.imageVersionTargetRegions | Should Match 'diskEncryptionSetResourceId'
        $outputs.imageVersionTargetRegions | Should Match 'confidentialVMDiskEncryptionSetResourceId'
        $outputs.imageVersionTargetRegions | Should Match "galleryImageVersionEncryptionType, 'PlatformManaged'"
        $outputs.imageVersionTargetRegions | Should Match "confidentialVMEncryptionType, 'EncryptedWithCmk'"
        $outputs.remoteConfidentialVMDiskEncryptionSetResourceId |
            Should Match "contains\([\s\S]*?'Confidential'\), equals\(steps\('imageDest'\)\.imageVersion\.confidentialVMEncryptionType, 'EncryptedWithCmk'\)"
    }

    It 'emits top-level defaults and only optional grid rows through target regions' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $outputs = $form.view.outputs.parameters
        $targetRegionsOutput = $outputs.imageVersionTargetRegions

        $targetRegionsOutput | Should Match "if\(equals\(steps\('imageDest'\)\.imageVersion\.specifyAdditionalReplicaRegions, true\), map"
        $targetRegionsOutput | Should Not Match "steps\('basics'\)\.scope\.location\.name"
        $targetRegionsOutput | Should Match "steps\('imageDest'\)\.imageVersion\.replicaCount"
        $targetRegionsOutput | Should Match "steps\('imageDest'\)\.imageVersion\.storageAccountType"
        @($outputs.PSObject.Properties.Name) -contains 'imageVersionDefaultReplicaCount' | Should Be $true
        @($outputs.PSObject.Properties.Name) -contains 'imageVersionDefaultStorageAccountType' | Should Be $true
        @($outputs.PSObject.Properties.Name) -contains 'imageVersionExcludeFromLatest' | Should Be $true
        @($outputs.PSObject.Properties.Name) -contains 'diskEncryptionSetResourceId' | Should Be $true
        @($outputs.PSObject.Properties.Name) -contains 'confidentialVMDiskEncryptionSetResourceId' | Should Be $true
    }

    It 'maps every form output to an ARM input and emits every required input' {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $arm = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json
        $formParameterNames = @($form.view.outputs.parameters.PSObject.Properties.Name)
        $armParameterNames = @($arm.parameters.PSObject.Properties.Name)
        $requiredArmParameterNames = @(
            $arm.parameters.PSObject.Properties |
                Where-Object { -not ($_.Value.PSObject.Properties.Name -contains 'defaultValue') } |
                Select-Object -ExpandProperty Name
        )

        @($formParameterNames | Where-Object { $_ -notin $armParameterNames }).Count | Should Be 0
        @($requiredArmParameterNames | Where-Object { $_ -notin $formParameterNames }).Count | Should Be 0
        @($armParameterNames | Where-Object { $_ -notin $formParameterNames } | Sort-Object) |
            Should Be @(
                'deploymentPrefix'
                'timeStamp'
            )
    }

    It 'keeps existing regional objects compatible and normalizes form sentinels' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $targetRegionsOutput = $form.view.outputs.parameters.imageVersionTargetRegions

        $bicep | Should Match 'diskEncryptionSetResourceId: string\?'
        $bicep | Should Match 'confidentialVMDiskEncryptionSetResourceId: string\?'
        $bicep | Should Match "region\.\?diskEncryptionSetResourceId \?\? \(toLower\(region\.name\) == toLower\(computeLocation\) \? diskEncryptionSetResourceId : ''\)"
        $bicep | Should Match "region\.\?confidentialVMDiskEncryptionSetResourceId \?\? \(toLower\(region\.name\) == toLower\(computeLocation\)"
        $bicep | Should Match 'imageVersionDefaultReplicaCount: imageVersionDefaultReplicaCount'
        $bicep | Should Match 'imageVersionDefaultStorageAccountType: imageVersionDefaultStorageAccountType'
        $bicep | Should Match 'imageVersionExcludeFromLatest: imageVersionExcludeFromLatest'
        $bicep | Should Match 'diskEncryptionSetId: diskEncryptionSetResourceId'
        $bicep | Should Match "fail\('imageVersionTargetRegions must contain each region only once\.'\)"
        $bicep | Should Match 'name: toLower\(region\.name\) == toLower\(computeLocation\) \? computeLocation : region\.name'
        $bicep | Should Match '!empty\(region\.diskEncryptionSetResourceId\) \|\| !empty\(galleryImageVersionConfidentialVMEncryptionType\)'
        $targetRegionsOutput | Should Match "equals\(coalesce\(region\.diskEncryptionSetResourceId, ''\), 'NotApplicable'\)"
        $targetRegionsOutput | Should Match "not\(equals\(coalesce\(region\.confidentialVMDiskEncryptionSetResourceId, ''\), 'NotApplicable'\)\)"
    }

    It 'matches the source region case-insensitively in the shared image-version module' {
        $modulePath = Join-Path $repoRoot 'deployments\shared\modules\resourceModules\compute\galleries\images\versions\deploy.bicep'
        $module = Get-Content -LiteralPath $modulePath -Raw

        $module | Should Match 'toLower\(region\.name\) == toLower\(location\)'
    }

    It 'uses canonical enum spellings downstream' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw

        $bicep | Should Match "'DoD'"
        $bicep | Should Not Match "(?-i)'DOD'"
        $bicep | Should Match "'TrustedLaunchAndConfidentialVmSupported'[\s\S]*?'TrustedLaunchAndConfidentialVMSupported'"
        $bicep | Should Match "imageDefinitionSecurityType == 'TrustedLaunchAndConfidentialVMSupported'[\s\S]*?'TrustedLaunchAndConfidentialVmSupported'"
        $bicep | Should Match 'teamsCloudType: teamsCloudType'
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$cleanupScriptPath = Join-Path $repoRoot 'deployments\imageBuild\scripts\Remove-ImageBuildResources.ps1'

Describe 'Image Build resource cleanup' {
    BeforeEach {
        $global:ImageBuildCleanupDeletedUris = @()
        $global:ImageBuildCleanupSleepSeconds = @()

        Mock Start-Sleep {
            param($Seconds)
            $global:ImageBuildCleanupSleepSeconds += $Seconds
        }
        Mock Invoke-RestMethod {
            param($Headers, $Method, $Uri)

            if ($Uri -like 'http://169.254.169.254/*') {
                return [pscustomobject]@{ access_token = 'test-token' }
            }
            if ($Method -eq 'DELETE') {
                $global:ImageBuildCleanupDeletedUris += $Uri
                return
            }

            throw "Unexpected REST request: $Method $Uri"
        }
    }

    AfterEach {
        Remove-Variable -Name ImageBuildCleanupDeletedUris -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ImageBuildCleanupSleepSeconds -Scope Global -ErrorAction SilentlyContinue
    }

    It 'waits before deleting a deployment-created resource group' {
        & $cleanupScriptPath `
            -ResourceManagerUri 'https://management.azure.com/' `
            -ImageVmResourceId '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/image-vm' `
            -ManagementVmResourceId '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/management-vm' `
            -ResourceGroupId '/subscriptions/test/resourceGroups/test'

        $global:ImageBuildCleanupDeletedUris.Count | Should Be 1
        $global:ImageBuildCleanupDeletedUris[0] | Should Match '/subscriptions/test/resourceGroups/test\?api-version=2021-04-01$'
        $global:ImageBuildCleanupSleepSeconds.Count | Should Be 1
        $global:ImageBuildCleanupSleepSeconds[0] | Should BeGreaterThan 29
        $global:ImageBuildCleanupSleepSeconds[0] | Should BeLessThan 31
    }

    It 'waits before deleting the management VM when reusing a resource group' {
        & $cleanupScriptPath `
            -ResourceManagerUri 'https://management.azure.com/' `
            -UserAssignedIdentityClientId '00000000-0000-0000-0000-000000000000' `
            -ImageVmResourceId '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/image-vm' `
            -ManagementVmResourceId '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/management-vm' `
            -ImageResourceId '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/images/image'

        $global:ImageBuildCleanupDeletedUris.Count | Should Be 3
        ($global:ImageBuildCleanupDeletedUris -join "`n") | Should Match '/virtualMachines/image-vm\?api-version=2024-03-01'
        ($global:ImageBuildCleanupDeletedUris -join "`n") | Should Match '/images/image\?api-version=2024-03-01'
        ($global:ImageBuildCleanupDeletedUris -join "`n") | Should Match '/virtualMachines/management-vm\?forceDeletion=true&api-version=2024-03-01'
        $global:ImageBuildCleanupSleepSeconds.Count | Should Be 1
        $global:ImageBuildCleanupSleepSeconds[0] | Should BeGreaterThan 29
        $global:ImageBuildCleanupSleepSeconds[0] | Should BeLessThan 31
    }

    It 'keeps deletion idempotent and removes obsolete cleanup mechanisms' {
        $content = Get-Content -LiteralPath $cleanupScriptPath -Raw

        $content | Should Match '\$StatusCode -ne 404'
        $content | Should Not Match 'Register-ScheduledTask|DeferredConfigPath|\$RunCommandUri|\$ArmConfirmed'
    }

    It 'remains ASCII-only for ARM script embedding' {
        $characters = [System.IO.File]::ReadAllText($cleanupScriptPath).ToCharArray()
        @($characters | Where-Object { [int]$_ -gt 127 }).Count | Should Be 0
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$restartScriptPath = Join-Path $repoRoot 'deployments\imageBuild\scripts\Restart-Vm.ps1'
$customizeModulePath = Join-Path $repoRoot 'deployments\imageBuild\modules\customizeImage.bicep'

function New-TestVmInstanceView {
    param (
        [string]$PowerState,
        [string]$AgentState
    )

    [pscustomobject]@{
        statuses = @(
            [pscustomobject]@{ code = $PowerState }
        )
        vmAgent = [pscustomobject]@{
            statuses = @(
                [pscustomobject]@{ code = $AgentState }
            )
        }
    }
}

Describe 'Image Build restart stability' {
    BeforeEach {
        $global:RestartStabilityNow = [datetime]'2026-01-01T00:00:00Z'
        $global:RestartStabilityGetCount = 0
        $global:RestartStabilityPostCount = 0
        $global:RestartStabilityStates = @(
            (New-TestVmInstanceView -PowerState 'PowerState/running' -AgentState 'ProvisioningState/succeeded')
            (New-TestVmInstanceView -PowerState 'PowerState/stopped' -AgentState 'ProvisioningState/unavailable')
            (New-TestVmInstanceView -PowerState 'PowerState/running' -AgentState 'ProvisioningState/succeeded')
            (New-TestVmInstanceView -PowerState 'PowerState/running' -AgentState 'ProvisioningState/succeeded')
            (New-TestVmInstanceView -PowerState 'PowerState/running' -AgentState 'ProvisioningState/succeeded')
            (New-TestVmInstanceView -PowerState 'PowerState/running' -AgentState 'ProvisioningState/succeeded')
        )

        Mock Get-Date {
            $global:RestartStabilityNow = $global:RestartStabilityNow.AddSeconds(60)
            $global:RestartStabilityNow
        }
        Mock Start-Sleep {}
        Mock Invoke-RestMethod {
            param($Headers, $Method, $Uri)

            if ($Uri -like 'http://169.254.169.254/*') {
                return [pscustomobject]@{ access_token = 'test-token' }
            }
            if ($Method -eq 'Post' -and $Uri -match '/restart\?') {
                $global:RestartStabilityPostCount++
                return
            }
            if ($Method -eq 'Get' -and $Uri -match '/instanceView\?') {
                $index = [Math]::Min($global:RestartStabilityGetCount, $global:RestartStabilityStates.Count - 1)
                $global:RestartStabilityGetCount++
                return $global:RestartStabilityStates[$index]
            }

            throw "Unexpected REST request: $Method $Uri"
        }
    }

    AfterEach {
        Remove-Variable -Name RestartStabilityNow -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name RestartStabilityGetCount -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name RestartStabilityPostCount -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name RestartStabilityStates -Scope Global -ErrorAction SilentlyContinue
    }

    It 'resets the stability timer when a follow-up reboot interrupts readiness' {
        $output = & $restartScriptPath `
            -ResourceManagerUri 'https://management.azure.com/' `
            -UserAssignedIdentityClientId '00000000-0000-0000-0000-000000000000' `
            -VmResourceId '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/image-vm' `
            -StableSeconds 180 `
            -ReadyTimeoutSeconds 900 `
            -PollIntervalSeconds 5

        $global:RestartStabilityPostCount | Should Be 1
        $global:RestartStabilityGetCount | Should Be 6
        ($output -join "`n") | Should Match 'Resetting stability timer'
        ($output -join "`n") | Should Match 'remained ready for 180 seconds'
    }

    It 'configures extended stabilization only for the post-update restart' {
        $content = Get-Content -LiteralPath $customizeModulePath -Raw
        $postUpdatesBlock = [regex]::Match(
            $content,
            "resource restartUpdates[\s\S]*?module conditionalRestartPostUpdates"
        ).Value

        $postUpdatesBlock | Should Match "name: 'StableSeconds'[\s\S]*?value: '180'"
        $postUpdatesBlock | Should Match "name: 'ReadyTimeoutSeconds'[\s\S]*?value: '1800'"
        $postUpdatesBlock | Should Match 'timeoutInSeconds: 2100'
        $content | Should Match "resource restartMicrosoftSoftware[\s\S]*?parameters: restartVMParameters"
        $content | Should Match "resource restartCustomizations[\s\S]*?parameters: restartVMParameters"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$cleanupScriptPath = Join-Path $repoRoot 'deployments\imageBuild\scripts\Remove-ImageBuildRunCommands.ps1'
$batchModulePath = Join-Path $repoRoot 'deployments\imageBuild\modules\applyCustomizationsBatch.bicep'
$customizeModulePath = Join-Path $repoRoot 'deployments\imageBuild\modules\customizeImage.bicep'

Describe 'Image Build Run Command capacity protection' {
    AfterEach {
        Remove-Variable -Name ImageBuildTestImageRunCommands -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ImageBuildTestOrchestrationRunCommands -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ImageBuildTestDeletedUris -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ImageBuildTestImageGetCount -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ImageBuildTestOrchestrationGetCount -Scope Global -ErrorAction SilentlyContinue
    }

    It 'waits for image commands but only queues orchestration command deletions' {
        $global:ImageBuildTestImageRunCommands = @(
            [pscustomobject]@{ name = 'customization-one' }
            [pscustomobject]@{ name = 'customization-two' }
        )
        $global:ImageBuildTestOrchestrationRunCommands = @(
            [pscustomobject]@{ name = 'previous-restart' }
            [pscustomobject]@{ name = 'current-cleanup' }
        )
        $global:ImageBuildTestDeletedUris = @()
        $global:ImageBuildTestImageGetCount = 0
        $global:ImageBuildTestOrchestrationGetCount = 0

        Mock Invoke-RestMethod {
            param($Headers, $Method, $Uri)

            if ($Uri -like 'http://169.254.169.254/*') {
                return [pscustomobject]@{ access_token = 'test-token' }
            }

            if ($Method -eq 'GET' -and $Uri -match '/virtualMachines/image-vm/runCommands') {
                $global:ImageBuildTestImageGetCount++
                return [pscustomobject]@{ value = @($global:ImageBuildTestImageRunCommands) }
            }
            if ($Method -eq 'GET' -and $Uri -match '/virtualMachines/orchestration-vm/runCommands') {
                $global:ImageBuildTestOrchestrationGetCount++
                return [pscustomobject]@{ value = @($global:ImageBuildTestOrchestrationRunCommands) }
            }
            if ($Method -eq 'DELETE') {
                $global:ImageBuildTestDeletedUris += $Uri
                if ($Uri -match '/virtualMachines/image-vm/runCommands/([^?]+)') {
                    $name = $Matches[1]
                    $global:ImageBuildTestImageRunCommands = @($global:ImageBuildTestImageRunCommands | Where-Object { $_.name -ne $name })
                }
                return
            }

            throw "Unexpected REST request: $Method $Uri"
        }

        & $cleanupScriptPath `
            -ResourceManagerUri 'https://management.azure.com/' `
            -SubscriptionId '00000000-0000-0000-0000-000000000000' `
            -ImageBuildResourceGroup 'image-build-rg' `
            -ImageVmName 'image-vm' `
            -OrchestrationVmName 'orchestration-vm' `
            -CurrentRunCommandName 'current-cleanup'

        $global:ImageBuildTestDeletedUris.Count | Should Be 3
        ($global:ImageBuildTestDeletedUris -join "`n") | Should Match '/virtualMachines/image-vm/runCommands/customization-one\?'
        ($global:ImageBuildTestDeletedUris -join "`n") | Should Match '/virtualMachines/image-vm/runCommands/customization-two\?'
        ($global:ImageBuildTestDeletedUris -join "`n") | Should Match '/virtualMachines/orchestration-vm/runCommands/previous-restart\?'
        ($global:ImageBuildTestDeletedUris -join "`n") | Should Not Match '/runCommands/current-cleanup\?'
        @($global:ImageBuildTestImageRunCommands).Count | Should Be 0
        @($global:ImageBuildTestOrchestrationRunCommands).Count | Should Be 2
        $global:ImageBuildTestImageGetCount | Should Be 2
        $global:ImageBuildTestOrchestrationGetCount | Should Be 1
    }

    It 'passes the active cleanup command name from every Bicep call site' {
        $batchModule = Get-Content -LiteralPath $batchModulePath -Raw
        $customizeModule = Get-Content -LiteralPath $customizeModulePath -Raw

        $batchModule | Should Match "name: 'CurrentRunCommandName'[\s\S]*?value: removeRunCommandName"
        $customizeModule | Should Match "name: 'CurrentRunCommandName'[\s\S]*?value: removeMicrosoftSoftwareRunCommandName"
    }

    It 'keeps customization batches below the Managed Run Command limit' {
        $customizeModule = Get-Content -LiteralPath $customizeModulePath -Raw
        $customizeModule | Should Match 'var customizationBatchSize = 20'
    }

    It 'names each customization deployment after its customizer type without truncation collisions' {
        $batchModule = Get-Content -LiteralPath $batchModulePath -Raw
        $batchModule | Should Match "batchContext == 'vdi' \? 'vdiCustomizer' : 'customizer'"
        $batchModule.Contains("'`${customization.name}-`${customizationDeploymentSuffix}'") | Should Be $true
        $batchModule | Should Match 'uniqueString\(customization\.name\)'
        $batchModule | Should Not Match "name: 'apply-\`\$\{batchContext\}"
    }
}
