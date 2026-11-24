BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'Canonical FSLogix producer account contracts' {
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
