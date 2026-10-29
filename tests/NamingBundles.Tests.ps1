$repoRoot = Split-Path -Parent $PSScriptRoot

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
            'tests\fixtures\naming-bundles.bicep'
            'tests\fixtures\naming-bundles.bicepparam'
            'tests\fixtures\naming-bundles-legacy.json'
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
        $encoded = ($raw -join [Environment]::NewLine | ConvertFrom-Json).outputs.encodedResults
        $actual = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
        $legacy = Get-Content -LiteralPath (Join-Path $repoRoot 'tests\fixtures\naming-bundles-legacy.json') -Raw | ConvertFrom-Json
    }

    AfterAll {
        if (Test-Path -LiteralPath $testDirectory) {
            Remove-Item -LiteralPath $testDirectory -Recurse -Force -ErrorAction Stop
        }
    }

    It 'preserves 799 retained values against the unchanged 969-value legacy baseline across all four clouds' {
        $actual.Count | Should Be 17
        $legacy.Count | Should Be 17
        $retired = @(
            'uniqueStringStorage', 'resourceGroupMonitoring', 'uniqueStringOperations',
            'keyVaultNameSecrets', 'keyVaultNameEncryption', 'dataCollectionEndpointName',
            'logAnalyticsWorkspaceName', 'recoveryServicesVaultNameFSLogix',
            'azureMonitorAgentIdentityName', 'diskEncryptionSetNameConv'
        )
        foreach ($profile in $legacy) {
            $result = @($actual | Where-Object name -eq $profile.name)
            $result.Count | Should Be 1
            @($profile.expected.PSObject.Properties).Count | Should Be 57
            @($result[0].hostPool.PSObject.Properties).Count | Should Be 47
            $expected = @($profile.expected.PSObject.Properties | Where-Object { $_.Name -notin $retired })
            ($result[0].hostPool.PSObject.Properties.Name | Sort-Object) -join ',' | Should Be (($expected.Name | Sort-Object) -join ',')
            foreach ($property in $expected) {
                $result[0].hostPool.($property.Name) | Should Be $property.Value
            }
        }
    }

    It 'returns only fifteen shared FSLogix properties and composes them unchanged into host-pool names' {
        foreach ($case in $actual) {
            @($case.fslogix.PSObject.Properties).Count | Should Be 15
            foreach ($property in $case.fslogix.PSObject.Properties) {
                $case.hostPool.($property.Name) | Should Be $property.Value
            }
            ($case.fslogix.PSObject.Properties.Name -join ',') | Should Not Match 'hostPoolName|workspaceName|sharedResourceGroupControlPlane'
        }
    }

    It 'retains raw SMB location separately from explicit naming abbreviation overrides' {
        $case = $actual | Where-Object name -eq 'abbreviation-overrides'
        $case.fslogix.vmsLocAbbr | Should Be 'use'
        $case.fslogix.vmLocationAbbreviation | Should Be 'vmx'
        $case.fslogix.resourceGroupStorage | Should Match '-vmx$'
    }

    It 'honors adoption and explicit names while keeping location-sensitive uniqueness seeds' {
        $adopted = $actual | Where-Object name -eq 'adopted-workspace'
        $adopted.hostPool.resourceGroupControlPlane | Should Be 'Existing-Feed-RG'
        $adopted.hostPool.workspaceName | Should Be 'Existing-Feed'
        $explicit = $actual | Where-Object name -eq 'explicit-overrides'
        $explicit.hostPool.sharedKeyVaultNameSecrets | Should Be 'kv-explicit-secrets'
        $explicit.hostPool.sharedKeyVaultNameEncryption | Should Be 'kv-explicit-encryption'
        $east = $actual | Where-Object name -eq 'no-location-east'
        $west = $actual | Where-Object name -eq 'no-location-west'
        $east.fslogix.fslogixStorageAccountNamePrefix | Should Not Be $west.fslogix.fslogixStorageAccountNamePrefix
        $east.fslogix.encryptionKeyNameFSLogix | Should Not Be $west.fslogix.encryptionKeyNameFSLogix
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
            ($members -contains $property.Name) | Should Be $true
        }
    }

    It 'propagates changed central defaults and role policy through both actual bundle functions' {
        $policyPath = Join-Path $testDirectory 'deployments\shared\modules\orchestration\naming\naming.bicep'
        $policy = Get-Content -LiteralPath $policyPath -Raw
        $changedPolicy = $policy.Replace("workload: 'avd'", "workload: 'desktop'").Replace("purpose: ['operations']", "purpose: ['ops']")
        $changedPolicy | Should Not Be $policy
        [IO.File]::WriteAllText($policyPath, $changedPolicy)
        $raw = @(& $bicep local-deploy $parametersPath --format Json 2>&1)
        if ($LASTEXITCODE -ne 0) { throw 'Changed-policy bundle evaluation failed.' }
        $encoded = ($raw -join [Environment]::NewLine | ConvertFrom-Json).outputs.encodedResults
        $changed = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
        $default = $changed | Where-Object name -eq 'default'
        $default.hostPool.resourceGroupOperations | Should Be 'rg-desktop-ops-use'
        $default.fslogix.resourceGroupStorage | Should Be 'rg-desktop-finance-storage-use'
    }

    It 'rejects a workspace owned by another subscription without success-shaped outputs' {
        [IO.File]::WriteAllText($parametersPath, "using './naming-bundles.bicep'`nparam invalidCase = 'workspace-subscription'`n")
        $raw = @(& $bicep local-deploy $parametersPath --format Json 2>&1)
        $LASTEXITCODE | Should Not Be 0
        $result = $raw -join [Environment]::NewLine | ConvertFrom-Json
        $result.error | Should Match 'existing\s+feed\s+workspace\s+subscription\s+must\s+match'
        $result.outputs | Should BeNullOrEmpty
    }
}
