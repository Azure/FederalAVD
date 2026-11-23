BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
}

Describe 'Lifecycle preferred Profile inputs' {
    It 'exports only preferred Profile names and retains legacy defaults in <Consumer>' -TestCases @(
        @{ Consumer = 'sessionHosts' }
        @{ Consumer = 'sessionHostReplacer' }
    ) {
        param($Consumer)
        $directory = Join-Path $repoRoot "deployments\add-ons\$Consumer"
        $form = Get-Content -LiteralPath (Join-Path $directory 'uiFormDefinition.json') -Raw | ConvertFrom-Json
        $template = Get-Content -LiteralPath (Join-Path $directory 'main.json') -Raw | ConvertFrom-Json -Depth 100
        foreach ($location in @('Local', 'Remote')) {
            $preferred = "fslogix${location}ProfileStorageAccountResourceIds"
            $legacy = "fslogix${location}StorageAccountResourceIds"
            @($template.parameters.$legacy.defaultValue).Count | Should -Be 0
            $template.parameters.$preferred.nullable | Should -BeTrue
            $form.view.outputs.parameters.$preferred | Should -Not -BeNullOrEmpty
            $form.view.outputs.parameters.PSObject.Properties.Name | Should -Not -Contain $legacy
        }
    }

    It 'evaluates production SHR aliases with omitted, preferred and explicit empty inputs' {
        $directory = Join-Path $TestDrive 'profile-aliases'
        New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.bicep') -Raw
        $expressions = @()
        foreach ($location in @('Local', 'Remote')) {
            $match = [regex]::Match($source, "(?m)^var effective${location}ProfileStorageAccountResourceIds = (.+)$")
            if (-not $match.Success) { throw "Production $location alias expression not found." }
            $expressions += $match.Groups[1].Value.Trim()
        }
        $cases = @(
            @{ name = 'legacy'; preferred = 'null'; expected = @('pc02', 'pc01') }
            @{ name = 'preferred'; preferred = "['new02', 'new01']"; expected = @('new02', 'new01') }
            @{ name = 'empty'; preferred = '[]'; expected = @() }
        )
        foreach ($case in $cases) {
            $fixture = Join-Path $directory "$($case.name).bicep"
            $lines = @("targetScope = 'local'")
            foreach ($location in @('Local', 'Remote')) {
                $lines += "var fslogix${location}StorageAccountResourceIds = ['pc02', 'pc01']"
                $lines += if ($case.preferred -eq 'null') {
                    "param fslogix${location}ProfileStorageAccountResourceIds string[]?"
                }
                else {
                    "param fslogix${location}ProfileStorageAccountResourceIds string[] = $($case.preferred)"
                }
            }
            $lines += "var result = { local: $($expressions[0]), remote: $($expressions[1]) }"
            $lines += 'output encodedResults string = base64(string({ resolved: result }))'
            [IO.File]::WriteAllLines($fixture, $lines)
            $actual = (Invoke-TestNamingVectors -TemplateFile $fixture).resolved.value
            @($actual.local).Count | Should -Be $case.expected.Count
            @($actual.remote).Count | Should -Be $case.expected.Count
            if ($case.expected.Count) {
                $actual.local | Should -Be $case.expected
                $actual.remote | Should -Be $case.expected
            }
        }
    }

    It 'keeps normalized legacy serialized keys compatible with old session-host Template Specs' {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.bicep') -Raw
        foreach ($location in @('Local', 'Remote')) {
            $source | Should -Match "fslogix${location}StorageAccountResourceIds: effective${location}ProfileStorageAccountResourceIds"
        }
    }
}

Describe 'PoC storage defaults' {
    It 'preserves omitted parameter-file behavior while the portal selects SSD v2' {
        $directory = Join-Path $repoRoot 'deployments\hostpoolPoc'
        $template = Get-Content -LiteralPath (Join-Path $directory 'hostpoolPoc.json') -Raw | ConvertFrom-Json -Depth 100
        $form = Get-Content -LiteralPath (Join-Path $directory 'uiFormDefinition.json') -Raw | ConvertFrom-Json
        $template.parameters.fslogixProfileStorageTier.defaultValue | Should -Be 'Standard'
        $template.parameters.fslogixProfileStorageBillingModel.defaultValue | Should -Be 'Legacy'
        $options = $form.view.properties.steps | Where-Object name -EQ 'options'
        ($options.elements | Where-Object name -EQ 'profileStorageTier').defaultValue | Should -Be 'SSD (Premium)'
        ($options.elements | Where-Object name -EQ 'profileStorageBillingModel').defaultValue | Should -Be 'Provisioned v2 (recommended)'
        $template.resources.fslogix.properties.parameters.profileStorageBillingModel.value | Should -Be "[parameters('fslogixProfileStorageBillingModel')]"
    }
}
