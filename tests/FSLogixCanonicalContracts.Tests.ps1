BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'Canonical FSLogix producer account contracts' {
    It 'uses the same backend and explicit tuning contract in <Directory>' -TestCases @(
        @{ Directory = 'hostpools'; Template = 'hostpool.json'; Tier = 'Standard' }
        @{ Directory = 'automatedHostPools'; Template = 'automatedHostPool.json'; Tier = 'Premium' }
        @{ Directory = 'add-ons\fslogixStorage'; Template = 'main.json'; Tier = 'Standard' }
    ) {
        param($Directory, $Template, $Tier)
        $arm = Get-Content (Join-Path $repoRoot "deployments\$Directory\$Template") -Raw | ConvertFrom-Json -Depth 100
        $parameters = $arm.parameters
        foreach ($obsolete in @('fslogixStorageRedundancy', 'fslogixShareSizeInGB', 'shareSizeInGB')) {
            $parameters.PSObject.Properties.Name | Should -Not -Contain $obsolete
        }
        @($parameters.fslogixStorageService.allowedValues | Sort-Object) | Should -Be @('AzureFiles', 'AzureNetAppFiles')
        $parameters.fslogixStorageService.defaultValue | Should -BeExactly 'AzureFiles'
        $parameters.fslogixNetAppServiceLevel.allowedValues | Should -Be @('Standard', 'Premium')
        $parameters.fslogixNetAppServiceLevel.defaultValue | Should -BeExactly 'Premium'
        $parameters.fslogixProfileStorageTier.allowedValues | Should -Be @('Standard', 'Premium')
        $parameters.fslogixProfileStorageTier.defaultValue | Should -BeExactly $Tier
        $parameters.fslogixProfileStorageRedundancy.defaultValue | Should -BeExactly 'LocallyRedundant'
        $parameters.fslogixProfileShareSizeInGB.defaultValue | Should -Be 100
        $parameters.fslogixProfileShareSizeInGB.type | Should -BeExactly 'int'
        $parameters.fslogixProfileShareSizeInGB.minValue | Should -Be 1
        $parameters.fslogixProfileStorageAccountNamePrefix.defaultValue | Should -BeExactly ''
        foreach ($name in @('fslogixStorageService', 'fslogixNetAppServiceLevel', 'fslogixProfileStorageTier',
            'fslogixProfileStorageRedundancy', 'fslogixProfileShareSizeInGB', 'fslogixProfileStorageAccountNamePrefix')) {
            $parameters.$name.nullable | Should -Not -BeTrue
        }
        $form = Get-Content (Join-Path $repoRoot "deployments\$Directory\uiFormDefinition.json") -Raw | ConvertFrom-Json -Depth 100
        foreach ($binding in $form.view.outputs.parameters.PSObject.Properties) {
            $parameters.PSObject.Properties.Name | Should -Contain $binding.Name
        }
        $form.view.outputs.parameters.fslogixStorageService | Should -Not -Match 'AzureFiles |AzureNetAppFiles |concat|split'
        foreach ($name in @('fslogixProfileStorageTier', 'fslogixNetAppServiceLevel', 'fslogixProfileStorageAccountNamePrefix')) {
            $form.view.outputs.parameters.$name | Should -Not -Match "parse\('null'\)"
        }
    }

    It 'keeps existing NetApp pool selection filtered by the independent service level' {
        $form = Get-Content (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\uiFormDefinition.json') -Raw
        $form | Should -Match "pool.properties.serviceLevel, steps\('storage'\).netAppServiceLevel"
        $form | Should -Not -Match "last\(split\(steps\('storage'\).storageService"
        $root = Get-Content (Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\fslogix.bicep') -Raw
        $root | Should -Match 'serviceLevel: netAppServiceLevel'
        $root | Should -Match 'shareSizeInGB: profileShareSizeInGB'
    }

    It 'collects canonical Profile redundancy for compliance evidence' {
        $path = Join-Path $TestDrive 'profile-parameters.json'
        @{ parameters = @{ fslogixProfileStorageRedundancy = @{ value = 'ZoneRedundant' } } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
        $csv = Join-Path $TestDrive 'profile-evidence.csv'
        & (Join-Path $repoRoot '.github\skills\federalavd-compliance-review\scripts\Get-ComplianceParameterEvidence.ps1') `
            -ParameterPath $path -CsvPath $csv | Out-Null
        $evidence = @(Import-Csv -LiteralPath $csv)
        $evidence.Count | Should -Be 1
        $evidence[0].Parameter | Should -BeExactly 'fslogixProfileStorageRedundancy'
        $evidence[0].Value | Should -BeExactly 'ZoneRedundant'
    }

    It 'uses only explicit existing Profile inputs and local/remote outputs in <Directory>' -TestCases @(
        @{ Directory = 'hostpools'; Template = 'hostpool.json' }
        @{ Directory = 'automatedHostPools'; Template = 'automatedHostPool.json' }
    ) {
        param($Directory, $Template)
        $arm = Get-Content (Join-Path $repoRoot "deployments\$Directory\$Template") -Raw | ConvertFrom-Json -Depth 100
        foreach ($location in @('Local', 'Remote')) {
            $input = "fslogixExisting${location}ProfileStorageAccountResourceIds"
            $arm.parameters.PSObject.Properties.Name | Should -Not -Contain "fslogixExisting${location}StorageAccountResourceIds"
            $arm.parameters.PSObject.Properties.Name | Should -Contain $input
            $arm.parameters.$input.type | Should -BeExactly 'array'
            @($arm.parameters.$input.defaultValue).Count | Should -Be 0
            $arm.parameters.$input.nullable | Should -Not -BeTrue
            $arm.outputs.PSObject.Properties.Name | Should -Contain "fslogix${location}ProfileStorageAccountResourceIds"
            $arm.outputs.PSObject.Properties.Name | Should -Contain "fslogix${location}OfficeStorageAccountResourceIds"
            $arm.outputs.PSObject.Properties.Name | Should -Not -Contain "fslogix${location}StorageAccountResourceIds"
        }
    }

    It 'removes the storage add-on prefix alias and exposes explicit Profile output fields' {
        $arm = Get-Content (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\main.json') -Raw | ConvertFrom-Json -Depth 100
        $arm.parameters.PSObject.Properties.Name | Should -Not -Contain 'storageAccountNamePrefix'
        $arm.parameters.fslogixProfileStorageAccountNamePrefix.defaultValue | Should -BeExactly ''
        $arm.parameters.PSObject.Properties.Name | Should -Contain 'remoteProfileStorageAccountResourceIds'
        $arm.outputs.PSObject.Properties.Name | Should -Contain 'profileStorageAccountResourceIds'
        $arm.outputs.PSObject.Properties.Name | Should -Not -Contain 'storageAccountResourceIds'
        $configuration = $arm.outputs.fslogixConfiguration.value
        $configuration.PSObject.Properties.Name | Should -Contain 'localProfileStorageAccountResourceIds'
        $configuration.PSObject.Properties.Name | Should -Contain 'remoteProfileStorageAccountResourceIds'
        $configuration.PSObject.Properties.Name | Should -Not -Contain 'fileShareNames'
    }
}

Describe 'Canonical FSLogix lifecycle tags' {
    It 'has no obsolete Profile tag references in any deployment form' {
        $forms = Get-ChildItem (Join-Path $repoRoot 'deployments') -Filter 'uiFormDefinition.json' -File -Recurse
        $forms.Count | Should -BeGreaterThan 0
        foreach ($form in $forms) {
            $text = Get-Content $form.FullName -Raw
            $text | ConvertFrom-Json -Depth 100 | Should -Not -BeNullOrEmpty
            $text | Should -Not -Match 'fslLocalStorageAccountNames|fslRemoteStorageAccountNames' -Because $form.FullName
        }
    }

    It 'merges lifecycle metadata directly in <Source>' -TestCases @(
        @{ Source = 'deployments\hostpools\hostpool.bicep' }
        @{ Source = 'deployments\hostpoolPoc\hostpoolPoc.bicep' }
        @{ Source = 'deployments\automatedHostPools\policy\main.bicep' }
    ) {
        param($Source)
        Get-Content (Join-Path $repoRoot $Source) -Raw | Should -Match 'tags: union\('
    }

    It 'discovers only canonical Profile tags in <Consumer>' -TestCases @(
        @{ Consumer = 'sessionHosts' }
        @{ Consumer = 'sessionHostReplacer' }
    ) {
        param($Consumer)
        $form = Get-Content (Join-Path $repoRoot "deployments\add-ons\$Consumer\uiFormDefinition.json") -Raw
        $form | Should -Match 'fslLocalProfileStorageAccountNames'
        $form | Should -Match 'fslRemoteProfileStorageAccountNames'
        $form | Should -Not -Match 'fslLocalStorageAccountNames|fslRemoteStorageAccountNames'
        $form | Should -Match 'fslLocalOfficeStorageAccountNames'
    }
}

Describe 'Canonical session host policy contract migration' {
    BeforeAll {
        $source = Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\modules\configureSessionHost.policyDefinition.bicep'
        $compiled = Join-Path $TestDrive 'canonical-policy.json'
        az bicep build --file $source --outfile $compiled
        if ($LASTEXITCODE -ne 0) { throw 'Canonical policy compilation failed' }
        $arm = Get-Content $compiled -Raw | ConvertFrom-Json -Depth 100
        $definition = $arm.resources | Where-Object type -EQ 'Microsoft.Authorization/policyDefinitions'
    }

    It 'uses a new definition and assignment identity without forcing a new Run Command' {
        $arm.parameters.policyDefinitionName.defaultValue | Should -BeExactly 'avdSessionHostConfiguration-ProfileAccounts-DeployIfNotExists'
        $definition.properties.metadata.version | Should -BeExactly '2.0.0'
        $definition.properties.parameters.runCommandName.defaultValue | Should -BeExactly 'ConfigureSessionHost'
        $definition.properties.policyRule.then.details.existenceCondition.equals | Should -BeExactly 'Succeeded'
        $adapter = Get-Content (Join-Path $repoRoot 'deployments\automatedHostPools\policy\main.bicep') -Raw
        $adapter | Should -Match "name: 'avd-sh-config-profile'"
        $adapter | Should -Not -Match "name: 'avd-sh-config'"
    }

    It 'uses the same explicit Profile names in definition, assignment, and remediation' {
        $adapter = Get-Content (Join-Path $repoRoot 'deployments\automatedHostPools\policy\main.bicep') -Raw
        $parameters = $definition.properties.parameters
        $mapping = $definition.properties.policyRule.then.details.deployment.properties.parameters
        $parameters.PSObject.Properties.Name | Should -Not -Contain 'fslogixFileShareNames'
        foreach ($location in @('Local', 'Remote')) {
            $name = "fslogix${location}ProfileStorageAccountResourceIds"
            $parameters.PSObject.Properties.Name | Should -Contain $name
            $parameters.PSObject.Properties.Name | Should -Not -Contain "fslogix${location}StorageAccountResourceIds"
            $mapping.$name.value | Should -BeExactly "[[parameters('$name')]"
            $adapter | Should -Match "$name`: \{"
        }
    }
}
