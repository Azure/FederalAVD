BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
}

Describe 'Existing Key Vault reuse in <Entry>' -ForEach @(
    @{
        Entry = 'hostpools\hostpool'
        CredentialsParameter = 'existingCredentialsKeyVaultResourceId'
    }
    @{
        Entry = 'add-ons\fslogixStorage\main'
        CredentialsParameter = 'credentialsKeyVaultResourceId'
    }
) {
    BeforeAll {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Entry.bicep") -Raw
        $template = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Entry.json") -Raw | ConvertFrom-Json
        $idsExpression = [regex]::Match($source, '(?ms)^var existingKeyVaultResourceIds = (union\(.*?^\))').Groups[1].Value
        if (!$idsExpression) {
            throw "Missing deduplicated Key Vault resource IDs in $Entry."
        }
        $vault = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/operations/providers/Microsoft.KeyVault/vaults/kv-shared'
        $otherVault = $vault.Replace('kv-shared', 'kv-encryption')
        $otherScope = $vault.Replace('/operations/', '/other-operations/')
        $otherSubscription = $vault.Replace('000000000001', '000000000002')
        $fixture = @"
targetScope = 'local'
func references($CredentialsParameter string, existingEncryptionKeyVaultResourceId string, deployStorageCmk bool) array => $idsExpression
output encodedResults string = base64(string({
  neither: references('', '', true)
  credentialsOnly: references('$vault', '', true)
  encryptionOnly: references('', '$vault', true)
  shared: references('$vault', '$vault', true)
  caseInsensitive: references('$vault', '$($vault.ToUpperInvariant())', true)
  distinct: references('$vault', '$otherVault', true)
  differentScope: references('$vault', '$otherScope', true)
  differentSubscription: references('$vault', '$otherSubscription', true)
  cmkDisabled: references('$vault', '$otherVault', false)
}))
"@
        $fixturePath = Join-Path $TestDrive 'KeyVaultReferences.bicep'
        [IO.File]::WriteAllText($fixturePath, $fixture, [Text.Encoding]::ASCII)
        $results = Invoke-TestNamingVectors -TemplateFile $fixturePath
    }

    It 'declares unique vault identities in the correct role order for <Case>' -TestCases @(
        @{ Case = 'neither'; Count = 0 }
        @{ Case = 'credentialsOnly'; Count = 1 }
        @{ Case = 'encryptionOnly'; Count = 1 }
        @{ Case = 'shared'; Count = 1 }
        @{ Case = 'caseInsensitive'; Count = 1 }
        @{ Case = 'distinct'; Count = 2 }
        @{ Case = 'differentScope'; Count = 2 }
        @{ Case = 'differentSubscription'; Count = 2 }
        @{ Case = 'cmkDisabled'; Count = 1 }
    ) {
        param($Case, $Count)
        $ids = $results.$Case.value
        $expectedCount = if ($Case -eq 'cmkDisabled' -and $Entry -eq 'hostpools\hostpool') { 2 } else { $Count }
        $ids.Count | Should -Be $expectedCount
        @($ids | Sort-Object -Unique).Count | Should -Be $expectedCount
        if ($expectedCount -gt 0) {
            $ids[0] | Should -Be $vault.ToLowerInvariant()
            $expectedLast = switch ($Case) {
                'distinct' { $otherVault }
                'differentScope' { $otherScope }
                'differentSubscription' { $otherSubscription }
                'cmkDisabled' { if ($expectedCount -eq 2) { $otherVault } else { $vault } }
                default { $vault }
            }
            $ids[-1] | Should -Be $expectedLast.ToLowerInvariant()
        }
    }

    It 'uses one emitted vault collection with credentials first and encryption last' {
        $source | Should -Match 'existingKeyVaults\[0\]\.getSecret\('
        $source | Should -Match 'existingKeyVaults\[length\(existingKeyVaultResourceIds\) - 1\]\.properties\.vaultUri'
        $vaults = @($template.resources.PSObject.Properties.Value | Where-Object { $_.type -eq 'Microsoft.KeyVault/vaults' -and $_.existing })
        $vaults.Count | Should -Be 1
        $template.resources.existingKeyVaults.copy.count | Should -Be "[length(variables('existingKeyVaultResourceIds'))]"
        $template.resources.existingKeyVaults.name | Should -Match "variables\('existingKeyVaultResourceIds'\)\[copyIndex\(\)\]"
        $template.resources.existingKeyVaults.subscriptionId | Should -Not -Match 'reference\('
        $template.resources.existingKeyVaults.resourceGroup | Should -Not -Match 'reference\('
    }
}

Describe 'Automated host-pool existing Key Vault reuse' {
    BeforeAll {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.bicep') -Raw
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.json') -Raw | ConvertFrom-Json
    }

    It 'does not declare duplicate existing vaults in the entry template' {
        [regex]::Matches($source, "resource \w+ 'Microsoft.KeyVault/vaults@[^']+' existing").Count |
            Should -Be 1
        $vaults = @($template.resources.PSObject.Properties.Value | Where-Object { $_.type -eq 'Microsoft.KeyVault/vaults' -and $_.existing })
        $vaults.Count | Should -BeLessOrEqual 1
    }

    It 'passes the encryption vault ID into separately scoped CMK modules' {
        $template.resources.fslogixStorageCmk.properties.parameters.keyVaultResourceId |
            Should -Match "parameters\('fslogixEncryptionKeyVaultResourceId'\)"
        $template.resources.virtualMachinesDiskCmk.properties.parameters.keyVaultResourceId |
            Should -Match "parameters\('encryptionKeyVaultResourceId'\)"
    }
}
