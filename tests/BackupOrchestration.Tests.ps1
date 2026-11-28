BeforeDiscovery {
    $networkCases = @(
        foreach ($publicAccess in @('Enabled', 'Disabled')) {
            foreach ($private in @($false, $true)) {
                foreach ($create in @($false, $true)) {
                    @{
                        PublicAccess = $publicAccess
                        Private = $private
                        Create = $create
                    }
                }
            }
        }
    )
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')

    function Invoke-BackupParameterExpression {
        param([string]$Expression, [hashtable]$Parameters)

        $translated = [regex]::Replace($Expression, "parameters\('([A-Za-z0-9_]+)'\)", {
            param($match)
            "steps('parameters').$($match.Groups[1].Value)"
        })
        Invoke-TestNamingFormExpression -Expression $translated -Steps @{ parameters = $Parameters }
    }
}

Describe 'Backup composer networking contracts' {
    Context '<Name>' -ForEach @(
        @{
            Name = 'shared FSLogix Backup'
            Source = 'deployments\shared\modules\orchestration\recoveryServices\fslogixBackupVault.bicep'
            VaultModules = @('recoveryServicesVault')
        }
        @{
            Name = 'personal VM Backup'
            Source = 'deployments\hostpools\modules\hosts\modules\recoveryServices.bicep'
            VaultModules = @('recoveryServicesVaultInit', 'recoveryServicesVaultCmk', 'recoveryServicesVault')
        }
    ) {
        BeforeAll {
            $compiled = Join-Path $TestDrive (($Name -replace ' ', '-') + '.json')
            $diagnostics = @(& az bicep build --file (Join-Path $repoRoot $Source) --outfile $compiled 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "Backup composer compilation failed: $Source`n$($diagnostics -join [Environment]::NewLine)"
            }
            $template = Get-Content -LiteralPath $compiled -Raw | ConvertFrom-Json -Depth 100
        }

        It 'requires an explicit supported public-access choice independent of the endpoint flag' {
            $template.parameters.publicNetworkAccess.type | Should -Be 'string'
            @($template.parameters.publicNetworkAccess.allowedValues).Count | Should -Be 2
            $template.parameters.publicNetworkAccess.allowedValues | Should -Contain 'Enabled'
            $template.parameters.publicNetworkAccess.allowedValues | Should -Contain 'Disabled'
            $template.parameters.publicNetworkAccess.PSObject.Properties.Name | Should -Not -Contain 'defaultValue'
            $template.parameters.privateEndpoint.type | Should -Be 'bool'
            $template.parameters.PSObject.Properties.Name | Should -Not -Contain 'networkAcls'
            $template.resources.vaultPrivateEndpoint.condition | Should -Not -Match 'publicNetworkAccess'
        }

        It 'preserves the existing vault API and forwards public access through every vault/CMK stage' {
            foreach ($moduleName in $VaultModules) {
                $module = $template.resources.$moduleName
                $module.properties.parameters.publicNetworkAccess.value |
                    Should -Be "[parameters('publicNetworkAccess')]"
                $module.condition | Should -Match "parameters\('createVault'\)"
                $vault = $module.properties.template.resources.recoveryServicesVault
                $vault.type | Should -Be 'Microsoft.RecoveryServices/vaults'
                $vault.apiVersion | Should -Be '2023-04-01'
                $vault.properties.publicNetworkAccess | Should -Match "parameters\('publicNetworkAccess'\)"
                $vault.properties.publicNetworkAccess | Should -Not -Match 'privateEndpoint'
            }
            $template.resources.vaultPrivateEndpoint.properties.parameters.groupId.value |
                Should -Be 'AzureBackup'
        }

        It 'resolves PublicAccess=<PublicAccess>, Private=<Private>, Create=<Create> independently' -TestCases $networkCases {
            param($PublicAccess, $Private, $Create)

            $parameters = @{
                publicNetworkAccess = $PublicAccess
                privateEndpoint = $Private
                createVault = $Create
                privateEndpointSubnetResourceId = '/subscriptions/test/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/vnet/subnets/endpoints'
                backupPrivateDnsZoneResourceId = '/subscriptions/test/resourceGroups/dns/providers/Microsoft.Network/privateDnsZones/privatelink.eus.backup.windowsazure.com'
            }
            foreach ($moduleName in $VaultModules) {
                Invoke-BackupParameterExpression `
                    -Expression $template.resources.$moduleName.properties.parameters.publicNetworkAccess.value `
                    -Parameters $parameters | Should -Be $PublicAccess
            }
            Invoke-BackupParameterExpression -Expression $template.resources.vaultPrivateEndpoint.condition `
                -Parameters $parameters | Should -Be ($Create -and $Private)
        }

        It 'preserves endpoint prerequisite gating when <Missing> is absent' -TestCases @(
            @{ Missing = 'privateEndpointSubnetResourceId' }
            @{ Missing = 'backupPrivateDnsZoneResourceId' }
        ) {
            param($Missing)

            $parameters = @{
                publicNetworkAccess = 'Enabled'
                privateEndpoint = $true
                createVault = $true
                privateEndpointSubnetResourceId = '/subnet'
                backupPrivateDnsZoneResourceId = '/dns'
            }
            $parameters[$Missing] = ''
            Invoke-BackupParameterExpression -Expression $template.resources.vaultPrivateEndpoint.condition `
                -Parameters $parameters | Should -Be $false
        }
    }
}

Describe 'Backup orchestration callers and relocation' {
    It 'keeps vault and policy resource modules while removing the misplaced composer' {
        Test-Path -LiteralPath (Join-Path $repoRoot 'deployments\shared\modules\resourceModules\recoveryServices\fslogixBackupVault.bicep') |
            Should -Be $false
        foreach ($path in @(
            'deployments\shared\modules\orchestration\recoveryServices\fslogixBackupVault.bicep'
            'deployments\shared\modules\resourceModules\recoveryServices\vaults\deploy.bicep'
            'deployments\shared\modules\resourceModules\recoveryServices\vaults\backupPolicies\deploy.bicep'
        )) {
            Test-Path -LiteralPath (Join-Path $repoRoot $path) | Should -Be $true
        }
    }

    It 'honors the selected public/endpoint contract in <Path>' -TestCases @(
        @{ Path = 'deployments\hostpools\hostpool.json'; Module = 'sharedFilesBackup'; Vm = $false }
        @{ Path = 'deployments\automatedHostPools\automatedHostPool.json'; Module = 'sharedFilesBackup'; Vm = $false }
        @{ Path = 'deployments\sharedServices\sharedServices.json'; Module = 'fslogixBackupVault'; Vm = $false }
        @{ Path = 'deployments\add-ons\fslogixStorage\main.json'; Module = 'fslogixBackupVault'; Vm = $false }
        @{ Path = 'deployments\hostpools\hostpool.json'; Module = 'recoveryServicesModule'; Vm = $true }
        @{ Path = 'deployments\hostpoolPoc\hostpoolPoc.json'; Module = 'recoveryServicesModule'; Vm = $true }
    ) {
        param($Path, $Module, $Vm)

        $entry = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw | ConvertFrom-Json -Depth 100
        $parent = if ($Vm) { $entry.resources.sessionHosts.properties.template } else { $entry }
        $parameters = $parent.resources.$Module.properties.parameters
        if ($Vm) {
            $parameters.publicNetworkAccess.value | Should -Be "[parameters('vaultPublicNetworkAccess')]"
            $parent.parameters.vaultPublicNetworkAccess.defaultValue |
                Should -Be "[if(parameters('deployBackupPrivateEndpoints'), 'Disabled', 'Enabled')]"
        }
        elseif ($Path -eq 'deployments\hostpools\hostpool.json') {
            $parameters.publicNetworkAccess.value | Should -Be "[variables('backupPublicNetworkAccess')]"
            $parameters.privateEndpoint.value | Should -Be "[variables('sharedPrivateEndpoint')]"
        }
        elseif ($Path -eq 'deployments\automatedHostPools\automatedHostPool.json') {
            $parameters.publicNetworkAccess.value | Should -Be "[variables('networking').backup.publicNetworkAccess]"
            $parameters.privateEndpoint.value | Should -Be "[variables('backupPrivateEndpoint')]"
        }
        elseif ($Path -eq 'deployments\sharedServices\sharedServices.json') {
            $parameters.publicNetworkAccess.value | Should -Be "[variables('backupPublicNetworkAccess')]"
            $parameters.privateEndpoint.value | Should -Be "[variables('deployBackupPrivateEndpoints')]"
        }
        elseif ($parameters.privateEndpoint.value -is [bool]) {
            $parameters.privateEndpoint.value | Should -Be $false
            $parameters.publicNetworkAccess.value | Should -Be 'Enabled'
        }
        else {
            $privateExpression = $parameters.privateEndpoint.value
            $condition = $privateExpression.Substring(1, $privateExpression.Length - 2)
            $parameters.publicNetworkAccess |
                Should -Be "[if($condition, createObject('value', 'Disabled'), createObject('value', 'Enabled'))]"
        }
        $parent.resources.$Module.properties.template.parameters.publicNetworkAccess.allowedValues |
            Should -Not -Contain 'EnabledWithRestrictions'
    }
}
