BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'Direct centralized naming bundles' {
    BeforeAll {
        $testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-NamingBundles-' + [guid]::NewGuid().ToString('N'))
        $command = Get-Command bicep -ErrorAction SilentlyContinue
        $configRoot = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.azure' }
        $binaryName = if ($env:OS -eq 'Windows_NT') { 'bicep.exe' } else { 'bicep' }
        $bicep = if ($command) { $command.Source } else { Join-Path (Join-Path $configRoot 'bin') $binaryName }
        if (-not (Test-Path -LiteralPath $bicep)) { throw 'Bicep CLI is required to evaluate naming bundles.' }
        foreach ($relative in @(
            'deployments\shared\data\resourceAbbreviations.json'
            'deployments\shared\data\locations.json'
            'deployments\shared\modules\orchestration\naming\naming.bicep'
            'deployments\shared\modules\orchestration\naming\internal.bicep'
            'tests\fixtures\naming-bundles.bicep'
            'tests\fixtures\naming-bundles.bicepparam'
            'tests\fixtures\naming-bundles-cases.json'
        )) {
            $destination = Join-Path $testDirectory $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $destination
        }
        [IO.File]::WriteAllText((Join-Path $testDirectory 'bicepconfig.json'), '{"experimentalFeaturesEnabled":{"localDeploy":true}}')
        $fixture = Join-Path $testDirectory 'tests\fixtures\naming-bundles.bicep'
        [IO.File]::WriteAllText($fixture, "targetScope = 'local'`n" + (Get-Content -LiteralPath $fixture -Raw))
        $parametersPath = Join-Path $testDirectory 'tests\fixtures\naming-bundles.bicepparam'
        $raw = @(& $bicep local-deploy $parametersPath --format Json 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Local bundle evaluation failed: $($raw -join [Environment]::NewLine)" }
        $outputs = ($raw -join [Environment]::NewLine | ConvertFrom-Json).outputs
        $encoded = $outputs.encodedResults
        $actual = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
        $foundation = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($outputs.encodedFoundation)) | ConvertFrom-Json
        $profiles = Get-Content -LiteralPath (Join-Path $repoRoot 'tests\fixtures\naming-bundles-cases.json') -Raw | ConvertFrom-Json
    }

    AfterAll {
        if (Test-Path -LiteralPath $testDirectory) {
            Remove-Item -LiteralPath $testDirectory -Recurse -Force -ErrorAction Stop
        }
    }

    It 'evaluates every current naming scenario across all four clouds' {
        $actual.Count | Should -Be $profiles.Count
        @($profiles.context.cloud | Sort-Object -Unique).Count | Should -Be 4
        foreach ($scenario in $profiles) {
            $result = @($actual | Where-Object name -eq $scenario.name)
            $result.Count | Should -Be 1
            @($result[0].hostPool.PSObject.Properties).Count | Should -Be 47
        }
    }

    It 'returns only fifteen shared FSLogix properties and composes them unchanged into host-pool names' {
        foreach ($case in $actual) {
            @($case.fslogix.PSObject.Properties).Count | Should -Be 15
            foreach ($property in $case.fslogix.PSObject.Properties) {
                $case.hostPool.($property.Name) | Should -Be $property.Value
            }
            ($case.fslogix.PSObject.Properties.Name -join ',') | Should -Not -Match 'hostPoolName|workspaceName|sharedResourceGroupControlPlane'
        }
    }

    It 'retains raw SMB location separately from explicit naming abbreviation overrides' {
        $case = $actual | Where-Object name -eq 'abbreviation-overrides'
        $case.fslogix.vmsLocAbbr | Should -Be 'use'
        $case.fslogix.vmLocationAbbreviation | Should -Be 'vmx'
        $case.fslogix.resourceGroupStorage | Should -Match '-vmx$'
    }

    It 'honors adoption and explicit names while keeping location-sensitive uniqueness seeds' {
        $adopted = $actual | Where-Object name -eq 'adopted-workspace'
        $adopted.hostPool.resourceGroupControlPlane | Should -Be 'Existing-Feed-RG'
        $adopted.hostPool.workspaceName | Should -Be 'Existing-Feed'
        $explicit = $actual | Where-Object name -eq 'explicit-overrides'
        $explicit.hostPool.sharedKeyVaultNameSecrets | Should -Be 'kv-explicit-secrets'
        $explicit.hostPool.sharedKeyVaultNameEncryption | Should -Be 'kv-explicit-encryption'
        $east = $actual | Where-Object name -eq 'no-location-east'
        $west = $actual | Where-Object name -eq 'no-location-west'
        $east.fslogix.fslogixStorageAccountNamePrefix | Should -Not -Be $west.fslogix.fslogixStorageAccountNamePrefix
        $east.fslogix.encryptionKeyNameFSLogix | Should -Not -Be $west.fslogix.encryptionKeyNameFSLogix
    }

    It 'exposes no host-pool result property without a production consumer' {
        $consumers = @(
            'deployments\hostpools\hostpool.bicep'
            'deployments\automatedHostPools\automatedHostPool.bicep'
            'deployments\hostpoolPoc\hostpoolPoc.bicep'
            'deployments\add-ons\fslogixStorage\main.bicep'
        ) | ForEach-Object { Get-Content -LiteralPath (Join-Path $repoRoot $_) -Raw }
        $members = @([regex]::Matches(($consumers -join "`n"), '\bnaming\.(\w+)') | ForEach-Object { $_.Groups[1].Value })
        foreach ($property in $actual[0].hostPool.PSObject.Properties) {
            ($members -contains $property.Name) | Should -Be $true
        }
    }

    It 'uses the central Image Management names and storage formatting across all scenarios' {
        foreach ($case in $actual) {
            @($case.imageManagement.PSObject.Properties).Count | Should -Be 14
            foreach ($property in $case.expectedImageManagement.PSObject.Properties) {
                $case.imageManagement.($property.Name) | Should -Be $property.Value
            }
            $case.imageManagement.privateEndpointNameConv | Should -Be $case.fslogix.privateEndpointNameConv
            $case.imageManagement.privateEndpointNICNameConv | Should -Be $case.fslogix.privateEndpointNICNameConv
        }
    }

    It 'keeps Shared Services and host-pool parity with one scope hash across all four clouds' {
        foreach ($case in $actual) {
            @($case.sharedServices.PSObject.Properties).Count | Should -Be 13
            $case.sharedServices.privateEndpointNameConv | Should -Be $case.fslogix.privateEndpointNameConv
            $case.sharedServices.privateEndpointNICNameConv | Should -Be $case.fslogix.privateEndpointNICNameConv
            if ($case.name -ne 'explicit-overrides') {
                $case.sharedServices.secretsKeyVaultName | Should -Match $case.expectedVaultSeed
                $case.sharedServices.encryptionKeyVaultName | Should -Match $case.expectedVaultSeed
            }
            $sharedMapping = @{
                operationsResourceGroupName = 'sharedResourceGroupOperations'
                monitoringResourceGroupName = 'sharedResourceGroupMonitoring'
                secretsKeyVaultName = 'sharedKeyVaultNameSecrets'
                encryptionKeyVaultName = 'sharedKeyVaultNameEncryption'
                fslogixBackupVaultName = 'sharedRecoveryServicesVaultNameFSLogix'
                logAnalyticsWorkspaceName = 'sharedLogAnalyticsWorkspaceName'
                dataCollectionEndpointName = 'sharedDataCollectionEndpointName'
            }
            if ($case.name -notin @('abbreviation-overrides', 'shared-subscription')) {
                foreach ($name in $sharedMapping.Keys) {
                    $case.sharedServices.$name | Should -Be $case.hostPool.($sharedMapping[$name])
                }
                $case.hostPool.resourceGroupOperations | Should -Be $case.sharedServices.operationsResourceGroupName
            }
            if ($case.name -notin @('split-location', 'government', 'abbreviation-overrides', 'shared-subscription', 'no-location-west')) {
                $mapping = @{
                    operationsResourceGroupName = 'sharedResourceGroupOperations'
                    monitoringResourceGroupName = 'sharedResourceGroupMonitoring'
                    controlPlaneResourceGroupName = 'sharedResourceGroupControlPlane'
                    avdWorkspaceName = 'sharedWorkspaceName'
                    globalFeedWorkspaceName = 'globalFeedWorkspaceName'
                    secretsKeyVaultName = 'sharedKeyVaultNameSecrets'
                    encryptionKeyVaultName = 'sharedKeyVaultNameEncryption'
                    fslogixBackupVaultName = 'sharedRecoveryServicesVaultNameFSLogix'
                    logAnalyticsWorkspaceName = 'sharedLogAnalyticsWorkspaceName'
                    dataCollectionEndpointName = 'sharedDataCollectionEndpointName'
                }
                foreach ($name in $mapping.Keys | Where-Object { $_ -ne 'controlPlaneResourceGroupName' -or $case.name -ne 'adopted-workspace' }) {
                    $case.sharedServices.$name | Should -Be $case.hostPool.($mapping[$name])
                }
            }
        }
        $east = $actual | Where-Object name -eq 'no-location-east'
        $west = $actual | Where-Object name -eq 'no-location-west'
        $east.sharedServices.secretsKeyVaultName | Should -Not -Be $west.sharedServices.secretsKeyVaultName
        $east.imageManagement.artifactsStorageAccountName | Should -Not -Be $west.imageManagement.artifactsStorageAccountName
    }

    It 'keeps supporting resources shared by host region rather than control-plane region or persona' {
        $split = $actual | Where-Object name -eq 'split-location'
        $split.hostPool.sharedRecoveryServicesVaultNameFSLogix | Should -Be 'rsv-avd-files-use'
        $split.hostPool.resourceGroupOperations | Should -Be 'rg-avd-operations-use'
        $split.hostPool.sharedResourceGroupOperations | Should -Be 'rg-avd-operations-use'
        $split.hostPool.sharedResourceGroupMonitoring | Should -Be 'rg-avd-monitoring-use'
        $split.hostPool.sharedLogAnalyticsWorkspaceName | Should -Be 'law-avd-use'
        $split.hostPool.sharedDataCollectionEndpointName | Should -Be 'dce-avd-use'
        $split.hostPool.resourceGroupControlPlane | Should -Be 'rg-avd-control-plane-usw2'
        $split.hostPool.sharedRecoveryServicesVaultNameFSLogix | Should -Be $split.sharedServices.fslogixBackupVaultName
        $split.hostPool.resourceGroupOperations | Should -Be $split.sharedServices.operationsResourceGroupName
        $government = $actual | Where-Object name -eq 'government'
        $government.hostPool.sharedRecoveryServicesVaultNameFSLogix | Should -Be $government.sharedServices.fslogixBackupVaultName
        $government.hostPool.resourceGroupOperations | Should -Be $government.sharedServices.operationsResourceGroupName
        $default = $actual | Where-Object name -eq 'default'
        $foundation.alternateHostPool.sharedRecoveryServicesVaultNameFSLogix |
            Should -Be $default.hostPool.sharedRecoveryServicesVaultNameFSLogix
        $foundation.alternateHostPool.resourceGroupOperations | Should -Be $default.hostPool.resourceGroupOperations
        foreach ($name in @('sharedKeyVaultNameSecrets', 'sharedKeyVaultNameEncryption', 'sharedLogAnalyticsWorkspaceName', 'sharedDataCollectionEndpointName')) {
            $split.hostPool.$name | Should -Be $default.hostPool.$name
            $foundation.alternateHostPool.$name | Should -Be $default.hostPool.$name
        }
        $override = $actual | Where-Object name -eq 'abbreviation-overrides'
        $override.hostPool.sharedRecoveryServicesVaultNameFSLogix | Should -Match '-vmx$'
        $override.hostPool.sharedResourceGroupOperations | Should -Be $override.hostPool.resourceGroupOperations
        $override.hostPool.sharedLogAnalyticsWorkspaceName | Should -Match '-vmx$'
        $override.hostPool.sharedKeyVaultNameSecrets | Should -Match '-vmx$'
        $override.hostPool.sharedKeyVaultNameEncryption | Should -Match '-vmx$'
        $sharedSubscription = $actual | Where-Object name -eq 'shared-subscription'
        $sharedSubscription.hostPool.sharedKeyVaultNameSecrets |
            Should -Be "kv-avd-sec-$($foundation.scopeCases[1].hash)-use"
        $sharedSubscription.hostPool.sharedKeyVaultNameEncryption |
            Should -Be "kv-avd-enc-$($foundation.scopeCases[1].hash)-use"
    }

    It 'honors consolidated scope and explicit overrides before evaluating overlength defaults' {
        $foundation.explicitShared.operationsResourceGroupName | Should -Be 'Existing-Operations'
        $foundation.explicitShared.monitoringResourceGroupName | Should -Be 'Existing-Operations'
        $foundation.explicitShared.controlPlaneResourceGroupName | Should -Be 'Existing-Operations'
        $foundation.explicitShared.secretsKeyVaultName | Should -Be 'explicit-secrets'
        $foundation.explicitShared.encryptionKeyVaultName | Should -Be 'explicit-encryption'
        $foundation.explicitShared.avdWorkspaceName | Should -Be 'explicit-workspace'
        $foundation.explicitShared.globalFeedResourceGroupName | Should -Be 'explicit-feed-group'
        $foundation.explicitShared.globalFeedWorkspaceName | Should -Be 'explicit-feed'
        $foundation.consolidatedShared.secretsKeyVaultName | Should -Be "kv-avd-sec-$($foundation.consolidatedSeed)-use"
        $foundation.consolidatedShared.encryptionKeyVaultName | Should -Be "kv-avd-enc-$($foundation.consolidatedSeed)-use"
        ($actual | Where-Object name -eq 'explicit-overrides').sharedServices.secretsKeyVaultName | Should -Be 'kv-explicit-secrets'
    }

    It 'shares the image scope hash across purposes and prefix choices while retaining double-encryption selection' {
        $foundation.customImage.artifactsStorageAccountName | Should -Be "cont1imgassets$($foundation.customImageSeed)e1"
        $foundation.customImage.logsStorageAccountName | Should -Be "cont1imglogs$($foundation.customImageSeed)e1"
        $foundation.customImage.galleryDiskEncryptionSetName | Should -Be 'des-avd-image-management-platform-and-customer-keys-e1'
        $foundation.defaultImage.artifactsStorageAccountName | Should -Be "saimgassets$($foundation.customImageSeed)e1"
        $foundation.defaultImage.logsStorageAccountName | Should -Be "saimglogs$($foundation.customImageSeed)e1"
    }

    It 'places image storage uniqueness after purpose and before trailing location and resource type' {
        $foundation.lastImage.artifactsStorageAccountName | Should -Be "imgassets$($foundation.lastImageSeed)e1sa"
        $foundation.lastImage.logsStorageAccountName | Should -Be "imglogs$($foundation.lastImageSeed)e1sa"
        $foundation.imageAtLimit.artifacts | Should -Be "cont1imgassets$($foundation.customImageSeed)use2"
        $foundation.imageAtLimit.logs | Should -Be "cont1imglogs$($foundation.customImageSeed)use2"
        $foundation.imageAtLimit.artifacts.Length | Should -Be 24
        foreach ($name in @(
            $foundation.lastImage.artifactsStorageAccountName
            $foundation.lastImage.logsStorageAccountName
            $foundation.imageAtLimit.artifacts
            $foundation.imageAtLimit.logs
        )) {
            $name | Should -Match '^[a-z0-9]{3,24}$'
        }
    }

    It 'uses the same shared vault names for different host pools and the direct type API' {
        $default = $actual | Where-Object name -eq 'default'
        $foundation.alternateHostPool.hostPoolName | Should -Not -Be $default.hostPool.hostPoolName
        $foundation.alternateHostPool.sharedKeyVaultNameSecrets | Should -Be $foundation.shared.secretsKeyVaultName
        $foundation.alternateHostPool.sharedKeyVaultNameEncryption | Should -Be $foundation.shared.encryptionKeyVaultName
        $foundation.directVaults.secrets | Should -Be $foundation.shared.secretsKeyVaultName
        $foundation.directVaults.encryption | Should -Be $foundation.shared.encryptionKeyVaultName
        $foundation.caseOnlyVault | Should -Be $foundation.shared.secretsKeyVaultName
        $foundation.noLocationVault | Should -Be "kv-avd-sec-$($foundation.scopeCases[0].hash)"
    }

    It 'shares a suffix across vault purposes and changes it for subscription group or region but not cloud' {
        @($foundation.scopeCases.hash | Select-Object -Unique).Count | Should -Be 4
        $foundation.scopeCases[4].secrets | Should -Be $foundation.scopeCases[0].secrets
        $foundation.scopeCases[4].encryption | Should -Be $foundation.scopeCases[0].encryption
        foreach ($scope in $foundation.scopeCases) {
            $scope.secrets | Should -Be "kv-avd-sec-$($scope.hash)-e1"
            $scope.encryption | Should -Be "kv-avd-enc-$($scope.hash)-e1"
        }
    }

    It 'accepts full Key Vault names exactly at the 24-character boundary without shortening' {
        $foundation.sharedAtLimit.secretsKeyVaultName.Length | Should -Be 24
        $foundation.sharedAtLimit.secretsKeyVaultName | Should -Match '^kv-avdxxx-sec-[a-z0-9]{6}-use$'
        $foundation.sharedAtLimit.encryptionKeyVaultName.Length | Should -Be 24
    }

    It 'treats new custom tokens legacy freeform keys and mixed aliases identically in all deployment adapters' {
        $foundation.aliasBundles.Count | Should -Be 4
        $baseline = $foundation.aliasBundles[0] | ConvertTo-Json -Depth 20 -Compress
        foreach ($bundle in $foundation.aliasBundles) {
            ($bundle | ConvertTo-Json -Depth 20 -Compress) | Should -Be $baseline
            $bundle.directName | Should -Be 'org-fin-x-appi'
        }
    }

    It 'rejects overlength role and bundle names or invalid image prefixes explicitly: <Name>' -TestCases @(
        @{ Name = 'role vault'; Expression = "resourceName({ resourceTypeCodes: { keyVaults: 'abcdefghijklmnopqrstuvwxy' } }, 'secretsKeyVault', 'use', '', 'abc123')"; ExpectedError = 'Generated name exceeds the 24-character limit' }
        @{ Name = 'Shared Services vault'; Expression = "sharedServicesNames({ workload: 'avdxxxx' }, context, {})"; ExpectedError = 'Generated name exceeds the 24-character limit' }
        @{ Name = 'host-pool vault'; Expression = "hostPoolNames({ workload: 'avdxxxx' }, 'finance', { subscriptionId: context.subscriptionId, cloud: context.cloud, virtualMachinesLocation: context.location, controlPlaneLocation: context.location, globalFeedLocation: '', existingFeedWorkspaceResourceId: '', sharedServicesSubscriptionId: context.subscriptionId })"; ExpectedError = 'Generated name exceeds the 24-character limit' }
        @{ Name = 'image storage prefix'; Expression = "imageManagementNames({ imageManagementStoragePrefix: 'toolong' }, context, 'CustomerManaged')"; ExpectedError = 'imageManagementStoragePrefix must contain no more than 5' }
        @{ Name = 'image location budget'; Expression = "imageManagementNames({ imageManagementStoragePrefix: 'cont1', locationAbbreviation: 'toolong' }, context, 'CustomerManaged')"; ExpectedError = 'location abbreviation must contain no more than 4' }
        @{ Name = 'role unknown component'; Expression = "resourceName({ components: ['purpose', 'unknown'] }, 'hostPool', 'use', 'finance', '')"; ExpectedError = 'unsupported naming-convention component' }
        @{ Name = 'role delimiter'; Expression = "resourceName({ delimiter: '*' }, 'hostPool', 'use', 'finance', '')"; ExpectedError = 'Naming delimiter' }
        @{ Name = 'role static token'; Expression = "resourceName({ workload: 'my workload' }, 'hostPool', 'use', 'finance', '')"; ExpectedError = 'Selected naming-convention values' }
        @{ Name = 'role whitespace identifier'; Expression = "resourceName({}, 'hostPool', 'use', ' finance ', '')"; ExpectedError = 'Resource identifier must contain only ASCII' }
        @{ Name = 'role missing purpose'; Expression = "resourceName({ components: ['resourceType'] }, 'hostPool', 'use', 'finance', '')"; ExpectedError = 'exactly one purpose' }
        @{ Name = 'role empty components'; Expression = "resourceName({ components: [] }, 'networkNatGateway', 'use', '', '')"; ExpectedError = 'at least one non-none component' }
        @{ Name = 'role vault double hyphen'; Expression = "resourceName({ delimiter: '--', workload: 'x' }, 'secretsKeyVault', 'use', '', 'abc123')"; ExpectedError = 'does not allow consecutive hyphens' }
        @{ Name = 'role alias conflict'; Expression = "resourceName({ customToken1: 'new', freeform1: 'old' }, 'hostPool', 'use', 'finance', '')"; ExpectedError = 'aliases and must agree' }
    ) {
        param($Name, $Expression, $ExpectedError)

        $fixture = Join-Path $testDirectory 'tests\fixtures\rejected-bundle.bicep'
        $function = [regex]::Match($Expression, '^\w+').Value
        $library = if ($function -eq 'resourceName') { 'internal' } else { 'naming' }
        $outputType = if ($function -eq 'resourceName') { 'string' } else { 'object' }
        $lines = @(
            "targetScope = 'local'"
            "import { $function } from '../../deployments/shared/modules/orchestration/naming/$library.bicep'"
        )
        if ($Expression -match '\bcontext\b') {
            $lines += "var context = { subscriptionId: '00000000-1111-2222-3333-444444444444', cloud: 'AzureCloud', location: 'eastus' }"
        }
        $lines += "var rejectedName = $Expression"
        $lines += "output rejected $outputType = rejectedName"
        [IO.File]::WriteAllLines($fixture, $lines)
        $parameters = Join-Path $testDirectory 'tests\fixtures\rejected-bundle.bicepparam'
        [IO.File]::WriteAllText($parameters, "using './rejected-bundle.bicep'")
        $raw = @(& $bicep local-deploy $parameters --format Json 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        if (($raw -join [Environment]::NewLine).TrimStart() -notlike '{*') {
            throw "Local bundle rejection did not return JSON: $($raw -join [Environment]::NewLine)"
        }
        $failure = ($raw -join [Environment]::NewLine) | ConvertFrom-Json
        $failure.outputs | Should -BeNullOrEmpty
        ($failure.error -replace '\s+', ' ') | Should -Match ([regex]::Escape($ExpectedError))
    }

    It 'propagates changed central defaults and role policy through both actual bundle functions' {
        $policyPath = Join-Path $testDirectory 'deployments\shared\modules\orchestration\naming\internal.bicep'
        $policy = Get-Content -LiteralPath $policyPath -Raw
        $changedPolicy = $policy.Replace("workload: 'avd'", "workload: 'vdi'").Replace("purpose: ['operations']", "purpose: ['ops']")
        $changedPolicy | Should -Not -Be $policy
        [IO.File]::WriteAllText($policyPath, $changedPolicy)
        $raw = @(& $bicep local-deploy $parametersPath --format Json 2>&1)
        if ($LASTEXITCODE -ne 0) { throw 'Changed-policy bundle evaluation failed.' }
        $encoded = ($raw -join [Environment]::NewLine | ConvertFrom-Json).outputs.encodedResults
        $changed = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
        $default = $changed | Where-Object name -eq 'default'
        $default.hostPool.resourceGroupOperations | Should -Be 'rg-vdi-ops-use'
        $default.fslogix.resourceGroupStorage | Should -Be 'rg-vdi-finance-storage-use'
    }

    It 'rejects a workspace owned by another subscription without success-shaped outputs' {
        [IO.File]::WriteAllText($parametersPath, "using './naming-bundles.bicep'`nparam invalidCase = 'workspace-subscription'`n")
        $raw = @(& $bicep local-deploy $parametersPath --format Json 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        $result = $raw -join [Environment]::NewLine | ConvertFrom-Json
        $result.error | Should -Match 'existing\s+feed\s+workspace\s+subscription\s+must\s+match'
        $result.outputs | Should -BeNullOrEmpty
    }
}
