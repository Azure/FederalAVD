BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $directory = Join-Path $TestDrive 'files-v2'
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    $armPath = Join-Path $directory 'files.json'
    $sourcePath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\azureFiles.bicep'
    $diagnostics = @(& az bicep build --file $sourcePath --outfile $armPath 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Azure Files compilation failed: $($diagnostics -join [Environment]::NewLine)" }
    $template = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json -Depth 100
    $account = $template.resources.storageAccounts.properties.template.resources.storageAccount
    $shareModule = $template.resources.shares.properties
    $share = @($shareModule.template.resources |
        Where-Object type -EQ 'Microsoft.Storage/storageAccounts/fileServices/shares')[0]
    $source = Get-Content -LiteralPath $sourcePath -Raw
    $rootPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\fslogix.bicep'
    $rootArmPath = Join-Path $directory 'fslogix.json'
    az bicep build --file $rootPath --outfile $rootArmPath --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'FSLogix parent compilation failed.' }
    $rootTemplate = Get-Content -LiteralPath $rootArmPath -Raw | ConvertFrom-Json -Depth 100
}

Describe 'Provisioned-v2 resource contracts' {
    It 'exports sizing from the account deployment module without changing account defaults' {
        $accountTemplate = $template.resources.storageAccounts.properties.template
        @($accountTemplate.functions | Where-Object {
            $_.members.PSObject.Properties.Name -contains 'resolveFilesConfiguration'
        }).Count | Should -Be 1
        $accountTemplate.parameters.kind.defaultValue | Should -Be 'StorageV2'
        $accountTemplate.parameters.skuName.defaultValue | Should -Be 'Standard_GRS'
        $source | Should -Match "import \{ resolveFilesConfiguration \} from '.*/storageAccounts/deploy\.bicep'"
    }

    It 'derives ordered share names in the FSLogix parent and passes them to both storage backends' {
        $rootTemplate.variables.fileShareNames | Should -Match "fslogixShareNames\(parameters\('fslogixContainerType'\)\)"
        foreach ($backend in @('azureFiles', 'azureNetAppFiles')) {
            $module = $rootTemplate.resources.$backend
            $module.properties.parameters.fileShares.value | Should -Be "[variables('fileShareNames')]"
            $module.properties.template.parameters.fileShares.type | Should -Be 'array'
            $module.properties.template.parameters.fileShares.minLength | Should -Be 1
            $module.properties.template.parameters.fileShares.maxLength | Should -Be 2
        }
        $template.parameters.PSObject.Properties.Name | Should -Not -Contain 'containerType'
    }

    It 'uses a stable API with v2 account SKUs and share provisioning fields' {
        $account.apiVersion | Should -Be '2024-01-01'
        $share.apiVersion | Should -Be '2024-01-01'
        $share.properties.provisionedIops | Should -Match "parameters\('provisionedIops'\)"
        $share.properties.provisionedBandwidthMibps | Should -Match "parameters\('provisionedThroughputMiBps'\)"
    }

    It 'omits legacy share tiers and performance properties when not requested' {
        $share.properties.accessTier | Should -Match "if\(not\(empty\(parameters\('accessTier'\)\)\)"
        $share.properties.accessTier | Should -Match ', null\(\)\)\]$'
        foreach ($property in @('provisionedIops', 'provisionedBandwidthMibps')) {
            $share.properties.$property | Should -Match ', null\(\)\)\]$'
        }
    }

    It 'forwards both role performance quantities through orchestration to the resource' {
        $template.resources.shares.properties.parameters.provisionedIops.value | Should -Match 'configuration.provisionedIops'
        $template.resources.shares.properties.parameters.provisionedThroughputMiBps.value | Should -Match 'configuration.provisionedThroughputMiBps'
        $template.resources.storageAccounts.properties.parameters.kind.value | Should -Match 'configuration.kind'
        $template.resources.storageAccounts.properties.parameters.skuName.value | Should -Match 'configuration.skuName'
        $template.resources.storageAccounts.properties.parameters.largeFileSharesState.value | Should -Match 'configuration.largeFileSharesState'
    }

    It 'deploys one share directly without an intermediate orchestration deployment' {
        @($shareModule.template.resources).Count | Should -Be 1
        @($shareModule.template.resources | Where-Object type -EQ 'Microsoft.Resources/deployments').Count |
            Should -Be 0
        $share.type | Should -Be 'Microsoft.Storage/storageAccounts/fileServices/shares'
        $share.name | Should -Match "parameters\('storageAccountName'\)"
        $share.name | Should -Match "parameters\('name'\)"
        $share.properties.shareQuota | Should -Be "[parameters('shareQuota')]"
        $template.resources.shares.dependsOn | Should -Contain 'storageAccounts'
        $template.resources.shares.dependsOn | Should -Contain 'fileServices'
    }

    It 'keeps SSD multichannel, SMB protocol and authentication independent of billing' {
        $source | Should -Match "multichannel: account.sku != 'Standard'"
        $source | Should -Match "identitySolution == 'ActiveDirectoryDomainServices'"
        $share.properties.enabledProtocols | Should -Match "parameters\('enabledProtocol'\)"
        $shareModule.template.parameters.enabledProtocol.defaultValue | Should -Be 'SMB'
    }
}
