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
    $shareModule = @($template.resources.shares.properties.template.resources |
        Where-Object type -EQ 'Microsoft.Resources/deployments')[0].properties
    $share = @($shareModule.template.resources |
        Where-Object type -EQ 'Microsoft.Storage/storageAccounts/fileServices/shares')[0]
    $source = Get-Content -LiteralPath $sourcePath -Raw
}

Describe 'Provisioned-v2 resource contracts' {
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
        $shareModule.parameters.provisionedIops.value | Should -Be "[parameters('provisionedIops')]"
        $shareModule.parameters.provisionedThroughputMiBps.value | Should -Be "[parameters('provisionedThroughputMiBps')]"
        $template.resources.storageAccounts.properties.parameters.kind.value | Should -Match 'configuration.kind'
        $template.resources.storageAccounts.properties.parameters.skuName.value | Should -Match 'configuration.skuName'
        $template.resources.storageAccounts.properties.parameters.largeFileSharesState.value | Should -Match 'configuration.largeFileSharesState'
    }

    It 'keeps SSD multichannel, SMB protocol and authentication independent of billing' {
        $source | Should -Match "multichannel: account.sku != 'Standard'"
        $source | Should -Match "identitySolution == 'ActiveDirectoryDomainServices'"
        $share.properties.enabledProtocols | Should -Match "parameters\('enabledProtocol'\)"
        $shareModule.template.parameters.enabledProtocol.defaultValue | Should -Be 'SMB'
    }
}
