BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
    $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\main.json') -Raw |
        ConvertFrom-Json -Depth 100
    $form = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\uiFormDefinition.json') -Raw |
        ConvertFrom-Json -Depth 100
    $operations = (($form.view.properties.steps | Where-Object name -eq 'zeroTrust').elements |
        Where-Object name -eq 'operations').elements
    $outputs = $form.view.outputs.parameters
}

Describe 'FSLogix Storage backup vault ownership' {
    It 'preserves opt-in creation and existing-vault precedence' {
        $template.parameters.deployFSLogixBackupVault.defaultValue | Should -Be $false
        $template.parameters.backupVaultScope.defaultValue | Should -Be 'Shared'
        $template.parameters.backupVaultScope.allowedValues | Should -Be @('Shared', 'Dedicated')
        $template.variables.createFSLogixBackupVault | Should -Be "[and(and(equals(variables('storageSolution'), 'AzureFiles'), parameters('deployFSLogixBackupVault')), empty(parameters('recoveryServicesVaultResourceId')))]"
        $template.resources.fslogixBackupVault.condition | Should -Be "[variables('createFSLogixBackupVault')]"
        $template.outputs.fslogixBackupVaultResourceId.value | Should -Match "reference\('fslogixBackupVault'\).outputs.recoveryServicesVaultResourceId.value"
        $template.outputs.fslogixBackupVaultResourceId.value | Should -Match "parameters\('recoveryServicesVaultResourceId'\)"
    }

    It 'separates shared operations and dedicated storage resource groups' {
        $template.resources.backupResourceGroup.condition | Should -Be "[and(variables('createFSLogixBackupVault'), equals(parameters('backupVaultScope'), 'Shared'))]"
        $template.variables.effectiveBackupResourceGroupName | Should -Match "variables\('effectiveStorageResourceGroupName'\)"
        $template.variables.effectiveBackupResourceGroupName | Should -Match "variables\('backupNaming'\).operationsResourceGroupName"
        $template.variables.effectiveBackupVaultName | Should -Match 'resourceNameForType'
        $template.resources.fslogixBackupVault.dependsOn | Should -Contain 'backupResourceGroup'
        $template.resources.fslogixBackupVault.dependsOn | Should -Contain 'storageResourceGroup'
    }

    It 'reuses the shared snapshot vault module and wires policy settings' {
        $vault = $template.resources.fslogixBackupVault.properties
        $vault.template.metadata.name | Should -Be 'FSLogix Azure Files backup vault'
        $vault.parameters.createVault.value | Should -Be $true
        $vault.parameters.manageBackupPolicy.value | Should -Be $true
        $vault.parameters.privateEndpoint.value | Should -Be $false
        $vault.parameters.timeZone.value | Should -Be "[parameters('fslogixBackupTimeZone')]"
        $vault.parameters.backupRetentionDays.value | Should -Be "[parameters('fslogixBackupRetentionDays')]"
        $vault.parameters.fileSharePolicyName.value | Should -Be "[parameters('fileSharePolicyName')]"
        $template.parameters.fslogixBackupRetentionDays.minValue | Should -Be 1
        $template.parameters.fslogixBackupRetentionDays.maxValue | Should -Be 200
        $template.resources.fslogix.properties.parameters.recoveryServicesVaultResourceId |
            Should -Be "[if(variables('createFSLogixBackupVault'), createObject('value', reference('fslogixBackupVault').outputs.recoveryServicesVaultResourceId.value), createObject('value', parameters('recoveryServicesVaultResourceId')))]"
        $template.resources.fslogix.dependsOn | Should -Contain 'fslogixBackupVault'
    }

    It 'guards unsupported storage and temporary cleanup resource groups' {
        $template.variables.backupConfigurationIsValid | Should -Match "equals\(variables\('storageSolution'\), 'AzureFiles'\)"
        $template.variables.backupConfigurationIsValid | Should -Match 'fail\('
        $template.variables.backupResourceGroupNamesAreDistinct | Should -Match "variables\('effectiveDeploymentResourceGroupName'\)"
        $template.variables.backupResourceGroupNamesAreDistinct | Should -Match 'fail\('
        $template.resources.fslogix.properties.parameters.fileSharePolicyName |
            Should -Match "variables\('backupResourceGroupNamesAreDistinct'\)"
    }

    It 'exports the selected vault and policy for reuse by later deployments' {
        $template.outputs.fslogixBackupVaultResourceId.value | Should -Be "[if(variables('createFSLogixBackupVault'), reference('fslogixBackupVault').outputs.recoveryServicesVaultResourceId.value, parameters('recoveryServicesVaultResourceId'))]"
        $template.outputs.fslogixBackupPolicyName.value | Should -Match '^\[if\(empty\('
        $template.outputs.fslogixBackupPolicyResourceId.value | Should -Match '/backupPolicies/'
    }
}

Describe 'FSLogix Storage evaluated backup vault naming' {
    BeforeAll {
        $testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-BackupNaming-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testDirectory -ErrorAction Stop | Out-Null
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\main.bicep') -Raw
        $namingPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\naming\naming.bicep'
        $relativeNaming = [IO.Path]::GetRelativePath($testDirectory, $namingPath).Replace('\', '/')
        $lines = @(
            "targetScope = 'local'"
            "import { fslogixNames, sharedServicesNames, resourceNameForType } from '$relativeNaming'"
            'var namingConvention = {}'
            "var identifier = 'finance'"
            "var location = 'usgovvirginia'"
            "var storageResourceGroupName = 'rg-storage'"
        )
        $expressions = @{}
        foreach ($name in @('naming', 'backupNaming', 'effectiveStorageResourceGroupName', 'effectiveBackupVaultName')) {
            $match = [regex]::Match($source, "(?ms)^var $name = (.*?)(?=^var |^resource )")
            if (-not $match.Success) { throw "Missing production naming expression: $name" }
            $expression = $match.Groups[1].Value.Trim().
                Replace('subscription().subscriptionId', "'00000000-1111-2222-3333-444444444444'").
                Replace('environment().name', "'AzureUSGovernment'")
            $expressions[$name] = $expression
            if ($name -ne 'effectiveBackupVaultName') { $lines += "var $name = $expression" }
        }
        $cases = @(
            @{ Name = 'shared'; Scope = 'Shared'; Override = ''; Expected = 'rsv-avd-files-va' }
            @{ Name = 'dedicated'; Scope = 'Dedicated'; Override = ''; Expected = 'rsv-avd-finance-backup-va' }
            @{ Name = 'sharedOverride'; Scope = 'Shared'; Override = 'existing-shared-name'; Expected = 'existing-shared-name' }
            @{ Name = 'dedicatedOverride'; Scope = 'Dedicated'; Override = 'existing-dedicated-name'; Expected = 'existing-dedicated-name' }
            @{ Name = 'customDedicated'; Scope = 'Dedicated'; Override = ''; Expected = 'finance-backup-rsv-va'; Convention = "{ components: ['purpose', 'resourceType', 'location'], delimiter: '-', workload: 'avd' }" }
        )
        foreach ($case in $cases) {
            $expression = $expressions.effectiveBackupVaultName -replace '\bbackupVaultScope\b', "'$($case.Scope)'" -replace '\bbackupVaultName\b', "'$($case.Override)'"
            if ($case.Convention) { $expression = $expression -replace '\bnamingConvention\b', $case.Convention }
            $lines += "var $($case.Name) = $expression"
        }
        $properties = ($cases | ForEach-Object { "$($_.Name): $($_.Name)" }) -join ', '
        $lines += "output encodedResults string = base64(string({ $properties }))"
        $fixture = Join-Path $testDirectory 'backup-naming.bicep'
        [IO.File]::WriteAllLines($fixture, $lines)
        $names = Invoke-TestNamingVectors -TemplateFile $fixture
    }

    AfterAll {
        if ($testDirectory -and (Test-Path -LiteralPath $testDirectory)) {
            Remove-Item -LiteralPath $testDirectory -Recurse -Force -ErrorAction Stop
        }
    }

    It 'evaluates the production shared and dedicated expressions, overrides, and custom convention' {
        foreach ($case in $cases) {
            $names.($case.Name).value | Should -Be $case.Expected
        }
    }
}

Describe 'FSLogix Storage backup Portal choices' {
    It 'offers disabled, existing, shared, and dedicated choices with a label-valued default' {
        $mode = $operations | Where-Object name -eq 'backupMode'
        $mode.constraints.allowedValues.value | Should -Be @('None', 'Existing', 'Shared', 'Dedicated')
        $mode.defaultValue | Should -Be 'No backup'
        $mode.defaultValue | Should -BeIn $mode.constraints.allowedValues.label
        ($operations | Where-Object name -eq 'recoveryServicesVault').constraints.required | Should -Be $true
    }

    It 'emits and clears backup parameters for <Service> and <Mode>' -TestCases @(
        @{ Service = 'AzureFiles Standard'; Mode = 'None' }
        @{ Service = 'AzureFiles Standard'; Mode = 'Existing' }
        @{ Service = 'AzureFiles Standard'; Mode = 'Shared' }
        @{ Service = 'AzureFiles Standard'; Mode = 'Dedicated' }
        @{ Service = 'AzureNetAppFiles Standard'; Mode = 'None' }
        @{ Service = 'AzureNetAppFiles Standard'; Mode = 'Existing' }
        @{ Service = 'AzureNetAppFiles Standard'; Mode = 'Shared' }
        @{ Service = 'AzureNetAppFiles Standard'; Mode = 'Dedicated' }
    ) {
        param($Service, $Mode)
        $steps = @{
            storage = @{ storageService = $Service }
            zeroTrust = @{
                operations = @{
                    backupMode = $Mode
                    recoveryServicesVault = @{ id = 'existing-vault' }
                    fileSharePolicyName = 'custom-policy'
                    backupVaultName = 'new-vault'
                    backupResourceGroupName = 'custom-operations'
                    backupRetentionDays = '45'
                    backupTimeZone = 'Eastern Standard Time'
                }
            }
        }
        $azureFiles = $Service.StartsWith('AzureFiles')
        $create = $azureFiles -and $Mode -in @('Shared', 'Dedicated')
        Invoke-TestNamingFormExpression $outputs.deployFSLogixBackupVault $steps | Should -Be $create
        Invoke-TestNamingFormExpression $outputs.backupVaultScope $steps |
            Should -Be $(if ($azureFiles -and $Mode -eq 'Dedicated') { 'Dedicated' } else { 'Shared' })
        Invoke-TestNamingFormExpression $outputs.recoveryServicesVaultResourceId $steps |
            Should -Be $(if ($azureFiles -and $Mode -eq 'Existing') { 'existing-vault' } else { '' })
        Invoke-TestNamingFormExpression $outputs.fileSharePolicyName $steps |
            Should -Be $(if ($azureFiles -and $Mode -ne 'None') { 'custom-policy' } else { 'filesharepolicy' })
        Invoke-TestNamingFormExpression $outputs.backupVaultName $steps |
            Should -Be $(if ($create) { 'new-vault' } else { '' })
        Invoke-TestNamingFormExpression $outputs.backupResourceGroupName $steps |
            Should -Be $(if ($azureFiles -and $Mode -eq 'Shared') { 'custom-operations' } else { '' })
        Invoke-TestNamingFormExpression $outputs.fslogixBackupRetentionDays $steps |
            Should -Be $(if ($create) { 45 } else { 30 })
        Invoke-TestNamingFormExpression $outputs.fslogixBackupTimeZone $steps |
            Should -Be $(if ($create) { 'Eastern Standard Time' } else { 'UTC' })
        foreach ($name in @('backupVaultName', 'backupRetentionDays', 'backupTimeZone')) {
            $control = $operations | Where-Object name -eq $name
            Invoke-TestNamingFormExpression $control.visible $steps | Should -Be $create
        }
        $existing = $operations | Where-Object name -eq 'recoveryServicesVault'
        Invoke-TestNamingFormExpression $existing.visible $steps | Should -Be ($azureFiles -and $Mode -eq 'Existing')
    }

    It 'enforces the same retention bounds in the form and template' {
        $control = $operations | Where-Object name -eq 'backupRetentionDays'
        foreach ($days in @(1, 30, 99, 100, 199, 200)) { "$days" | Should -Match $control.constraints.regex }
        foreach ($days in @(0, 201, -1, 1.5)) { "$days" | Should -Not -Match $control.constraints.regex }
    }

    It 'maps every form output to a template parameter' {
        foreach ($name in $outputs.PSObject.Properties.Name) {
            $name | Should -BeIn $template.parameters.PSObject.Properties.Name
        }
    }
}

Describe 'FSLogix profile-only expanded backup enrollment' {
    BeforeAll {
        $testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-FSLogixBackup-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testDirectory -ErrorAction Stop | Out-Null
        $fixture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\fslogix-backup.bicep') -Raw
        $modulePath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\fslogixBackupItems.bicep'
        $relativeModule = [IO.Path]::GetRelativePath($testDirectory, $modulePath).Replace('\', '/')
        $fixture = $fixture.Replace('../../deployments/shared/modules/orchestration/fslogix/modules/fslogixBackupItems.bicep', $relativeModule)
        [IO.File]::WriteAllText((Join-Path $testDirectory 'fslogix-backup.bicep'), $fixture)
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\fslogix-backup.bicepparam') -Destination $testDirectory
        $bicep = Join-Path $HOME ('.azure\bin\bicep' + $(if ($IsWindows) { '.exe' } else { '' }))
        if (-not (Test-Path -LiteralPath $bicep)) { throw "Bicep CLI not found: $bicep" }
        & $bicep snapshot (Join-Path $testDirectory 'fslogix-backup.bicepparam') --mode Overwrite `
            --subscription-id 00000000-1111-2222-3333-444444444444 `
            --tenant-id 11111111-2222-3333-4444-555555555555 `
            --location eastus --deployment-name backup-tests
        if ($LASTEXITCODE -ne 0) { throw 'FSLogix backup expansion failed.' }
        $snapshots = @(Get-ChildItem -LiteralPath $testDirectory -Filter '*.snapshot.json' -File)
        if ($snapshots.Count -ne 1) { throw 'Expected one FSLogix backup snapshot.' }
        $snapshot = Get-Content -LiteralPath $snapshots[0].FullName -Raw | ConvertFrom-Json -Depth 100
        $items = @($snapshot.predictedResources | Where-Object type -eq 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems')
        $containers = @($snapshot.predictedResources | Where-Object type -eq 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers')
    }

    Describe 'FSLogix Office exclusion in generated consumers' {
        It 'embeds the common exclusion in <Entry>' -TestCases @(
            @{ Entry = 'deployments\add-ons\fslogixStorage\main.json'; Module = 'fslogix' }
            @{ Entry = 'deployments\hostpools\hostpool.json'; Module = 'fslogix' }
            @{ Entry = 'deployments\automatedHostPools\automatedHostPool.json'; Module = 'fslogixStorage' }
            @{ Entry = 'deployments\hostpoolPoc\hostpoolPoc.json'; Module = 'fslogix' }
        ) {
            param($Entry, $Module)
            $entryTemplate = Get-Content -LiteralPath (Join-Path $repoRoot $Entry) -Raw | ConvertFrom-Json -Depth 100
            $registration = $entryTemplate.resources.$Module.properties.template.resources.backupRegistration.properties.template
            $registration.metadata.name | Should -Be 'FSLogix file share backup registration'
            $registration.variables.backupFileShares |
                Should -Be "[filter(parameters('fileShares'), lambda('shareName', not(equals(toLower(lambdaVariables('shareName')), 'office-containers'))))]"
            $registration.variables.combos | Should -Match "map\(variables\('backupFileShares'\)"
        }
    }

    AfterAll {
        if ($testDirectory -and (Test-Path -LiteralPath $testDirectory)) {
            Get-ChildItem -LiteralPath $testDirectory -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction Stop }
            Remove-Item -LiteralPath $testDirectory -ErrorAction Stop
        }
    }

    It 'protects exactly one profile share per account for <Vault>' -TestCases @(
        @{ Vault = 'unsharded'; Count = 1; Policy = 'filesharepolicy' }
        @{ Vault = 'sharded'; Count = 3; Policy = 'profile-snapshots' }
        @{ Vault = 'profiles-only'; Count = 3; Policy = 'filesharepolicy' }
    ) {
        param($Vault, $Count, $Policy)
        $selected = @($items | Where-Object { $_.name.StartsWith("$Vault/") })
        $selected.Count | Should -Be $Count
        foreach ($item in $selected) {
            $item.name | Should -Match '/AzureFileShare;profile-containers$'
            $item.properties.policyId | Should -Be "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/backup-tests/providers/Microsoft.RecoveryServices/vaults/$Vault/backupPolicies/$Policy"
        }
    }

    It 'never enrolls Office shares, including case variations and Office-only requests' {
        @($items | Where-Object name -Match 'office-containers').Count | Should -Be 0
        @($containers | Where-Object { $_.name.StartsWith('office-only/') }).Count | Should -Be 0
        $items.Count | Should -Be 7
    }
}
