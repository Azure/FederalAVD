BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
}

Describe 'Evaluated FSLogix OSS identity eligibility' {
    BeforeAll {
        $fixtureDirectory = Join-Path $TestDrive 'oss'
        New-Item -ItemType Directory -Path $fixtureDirectory -ErrorAction Stop | Out-Null
        $modulePath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\fslogix.bicep'
        $relativeModule = [IO.Path]::GetRelativePath($fixtureDirectory, $modulePath).Replace('\', '/')
        function Invoke-OSSEligibility {
            param([string]$Identity, [bool]$Requested)
            $fixture = Join-Path $fixtureDirectory 'eligibility.bicep'
            $literal = $Requested.ToString().ToLowerInvariant()
            [IO.File]::WriteAllLines($fixture, @(
                "targetScope = 'local'"
                "import { validateObjectSpecificSettings } from '$relativeModule'"
                "output encodedResults string = base64(string({ valid: validateObjectSpecificSettings('$Identity', $literal) }))"
            ))
            (Invoke-TestNamingVectors -TemplateFile $fixture).valid.value
        }
    }

    It 'allows OSS for <Identity>' -TestCases @(
        @{ Identity = 'ActiveDirectoryDomainServices' }
        @{ Identity = 'EntraDomainServices' }
    ) {
        param($Identity)
        Invoke-OSSEligibility -Identity $Identity -Requested $true | Should -BeTrue
    }

    It 'rejects requested OSS for <Identity>' -TestCases @(
        @{ Identity = 'EntraKerberos-Hybrid' }
        @{ Identity = 'EntraKerberos-CloudOnly' }
        @{ Identity = 'EntraId' }
    ) {
        param($Identity)
        { Invoke-OSSEligibility -Identity $Identity -Requested $true } |
            Should -Throw '*Local naming vectors failed*'
    }

    It 'preserves configurations without OSS for <Identity>' -TestCases @(
        @{ Identity = 'ActiveDirectoryDomainServices' }
        @{ Identity = 'EntraDomainServices' }
        @{ Identity = 'EntraKerberos-Hybrid' }
        @{ Identity = 'EntraKerberos-CloudOnly' }
        @{ Identity = 'EntraId' }
    ) {
        param($Identity)
        Invoke-OSSEligibility -Identity $Identity -Requested $false | Should -BeTrue
    }
}

Describe 'Runtime OSS admission in <RelativePath>' -ForEach @(
    @{ RelativePath = 'deployments\shared\scripts\Initialize-SessionHost.ps1' }
    @{ RelativePath = 'deployments\automatedHostPools\scripts\Initialize-SessionHost.ps1' }
) {
    BeforeAll {
        $scriptPath = Join-Path $repoRoot $RelativePath
        $source = Get-Content -LiteralPath $scriptPath -Raw
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
        if ($parseErrors) { throw ($parseErrors | Out-String) }
        $guard = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Assert-FSLogixObjectSpecificSettings'
        }, $true)
        Invoke-Expression $guard.Extent.Text
    }

    It 'rejects <Identity> before querying domain status' -TestCases @(
        @{ Identity = 'EntraKerberos-Hybrid' }
        @{ Identity = 'EntraKerberos-CloudOnly' }
        @{ Identity = 'EntraId' }
    ) {
        param($Identity)
        Mock Get-CimInstance { throw 'Must not query the machine for an unsupported identity mode.' }
        { Assert-FSLogixObjectSpecificSettings -Enabled $true -GroupsJson '["AVD Users"]' -Identity $Identity } |
            Should -Throw '*FSLogix Object Specific Settings require AD-domain-joined session hosts*'
        Should -Invoke Get-CimInstance -Times 0 -Exactly
    }

    It 'allows a domain-joined <Identity> machine' -TestCases @(
        @{ Identity = 'ActiveDirectoryDomainServices' }
        @{ Identity = 'EntraDomainServices' }
    ) {
        param($Identity)
        Mock Get-CimInstance { [pscustomobject]@{ PartOfDomain = $true } }
        { Assert-FSLogixObjectSpecificSettings -Enabled $true -GroupsJson '["AVD Users"]' -Identity $Identity } | Should -Not -Throw
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter {
            $ClassName -eq 'Win32_ComputerSystem' -and $ErrorAction -eq 'Stop'
        }
    }

    It 'rejects a workgroup machine even when parameters claim AD DS' {
        Mock Get-CimInstance { [pscustomobject]@{ PartOfDomain = $false } }
        { Assert-FSLogixObjectSpecificSettings -Enabled $true -GroupsJson '["AVD Users"]' -Identity 'ActiveDirectoryDomainServices' } |
            Should -Throw '*this session host is not AD-domain joined*'
    }

    It 'propagates a failed domain-status query' {
        Mock Get-CimInstance { throw 'Domain-status query failed.' }
        { Assert-FSLogixObjectSpecificSettings -Enabled $true -GroupsJson '["AVD Users"]' -Identity 'ActiveDirectoryDomainServices' } |
            Should -Throw '*Domain-status query failed*'
    }

    It 'preserves disabled FSLogix and no-OSS configurations without querying AD' {
        Mock Get-CimInstance { throw 'No domain query expected.' }
        { Assert-FSLogixObjectSpecificSettings -Enabled $false -GroupsJson 'invalid ignored input' -Identity 'EntraId' } | Should -Not -Throw
        { Assert-FSLogixObjectSpecificSettings -Enabled $true -GroupsJson '[]' -Identity 'EntraKerberos-Hybrid' } | Should -Not -Throw
        Should -Invoke Get-CimInstance -Times 0 -Exactly
    }

    It 'surfaces malformed enabled OSS input' {
        { Assert-FSLogixObjectSpecificSettings -Enabled $true -GroupsJson '[invalid' -Identity 'ActiveDirectoryDomainServices' } | Should -Throw
    }

    It 'checks eligibility before changing time zone or registry settings and uses the fatal error path' {
        $source.IndexOf('Assert-FSLogixObjectSpecificSettings -Enabled') | Should -BeGreaterThan 0
        $source.IndexOf('Assert-FSLogixObjectSpecificSettings -Enabled') | Should -BeLessThan $source.IndexOf('Set-TimeZone -Id')
        $source | Should -Match '(?s)catch \{[^}]*Write-Log.*?-Category Error.*?exit 1'
        $source | Should -Not -Match '[^\x00-\x7F]'
    }
}

Describe 'OSS deployment and Portal boundaries' {
    It 'consumes the shared sharding guard in <Entry>' -TestCases @(
        @{ Entry = 'hostpools\hostpool' }
        @{ Entry = 'automatedHostPools\automatedHostPool' }
    ) {
        param($Entry)
        $source = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Entry.bicep") -Raw
        $source | Should -Match 'validateObjectSpecificSettings\(identitySolution, \(deployFSLogixStorage \|\| fslogixConfigureSessionHosts\) && fslogixShardOptions == ''ShardOSS''\)'
        $json = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Entry.json") -Raw
        $json | Should -Match 'variables\(''fslogixShardingConfigurationIsValid''\)'
        $json | Should -Match 'validateObjectSpecificSettings\(parameters\(''identitySolution''\)'
        $json | Should -Match 'FSLogix Object Specific Settings require AD-domain-joined session hosts'
    }

    It 'guards every emitted initialization command in <Template>' -TestCases @(
        @{ Template = 'hostpools\hostpool.json' }
        @{ Template = 'hostpoolPoc\hostpoolPoc.json' }
        @{ Template = 'automatedHostPools\automatedHostPool.json' }
        @{ Template = 'add-ons\sessionHosts\main.json' }
        @{ Template = 'add-ons\sessionHostReplacer\main.json' }
        @{ Template = 'shared\modules\orchestration\sessionHostPolicy\modules\templates\RunCommand\ConfigureSessionHost.json' }
    ) {
        param($Template)
        $json = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Template") -Raw
        $commands = [regex]::Matches($json, '"name": "ConfigureFSLogix",\s*"value": "(?<Expression>[^"]+)"')
        $commands.Count | Should -BeGreaterThan 0
        foreach ($command in $commands) {
            $command.Groups['Expression'].Value | Should -Match 'variables\(''objectSpecificSettingsAreValid''\)'
        }
    }

    It 'guards direct and deferred session-host configurations in <Source>' -TestCases @(
        @{ Source = 'add-ons\sessionHosts\main.bicep'; Consumer = 'fslogixConfigureSessionHosts: objectSpecificSettingsAreValid && fslogixConfigureSessionHosts' }
        @{ Source = 'add-ons\sessionHostReplacer\main.bicep'; Consumer = 'var fslogixParameters = objectSpecificSettingsAreValid && fslogixConfigureSessionHosts' }
        @{ Source = 'automatedHostPools\policy\main.bicep'; Consumer = 'value: objectSpecificSettingsAreValid && pairedStorageAccountsAreValid && storageKeyConfigurationIsValid && configureFSLogix' }
    ) {
        param($Source, $Consumer)
        $text = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Source") -Raw
        $text | Should -Match 'validateObjectSpecificSettings\(.*?(?:fslogixConfigureSessionHosts|configureFSLogix) && !empty\('
        $text | Should -Match ([regex]::Escape($Consumer))
    }

    It 'does not impose host eligibility on standalone storage provisioning' {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\main.bicep') -Raw
        $source | Should -Not -Match 'validateObjectSpecificSettings\('
    }

    It 'keeps the standard restriction without dropping permissions sharding' {
        $entry = 'hostpools'
            $form = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$entry\uiFormDefinition.json") -Raw | ConvertFrom-Json
            $step = $form.view.properties.steps | Where-Object name -in @('profiles', 'userProfiles')
            $controls = @($step.elements | ForEach-Object { $_.elements })
            $selector = $controls | Where-Object name -in @('shardingOption', 'shardOptions')
            $selector.constraints.allowedValues | Should -BeOfType [string]
            $selector.constraints.allowedValues | Should -Match "if\(.*?(?:EntraID|EntraKerberos)"
            $branches = [regex]::Matches($selector.constraints.allowedValues, "parse\('([^']+)'\)")
            $restricted = $branches[0].Groups[1].Value | ConvertFrom-Json
            $restricted.value | Should -Be @('None', 'ShardPerms')
            $supported = $branches[1].Groups[1].Value | ConvertFrom-Json
            $supported.value | Should -Contain 'ShardOSS'
            $explanation = $controls | Where-Object name -eq 'objectSpecificSettingsIdentity'
            $explanation.options.text | Should -Match 'Hybrid identities are synchronized users, not hybrid-joined machines'
            $explanation.options.text | Should -Not -Match '^\['
    }

    It 'offers schema-valid automated options separately and selects the active value in every binding' {
        $text = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json') -Raw
        $form = $text | ConvertFrom-Json
        $step = $form.view.properties.steps | Where-Object name -eq 'profiles'
        $controls = ($step.elements | Where-Object name -eq 'storage').elements
        $domain = $controls | Where-Object name -eq 'shardOptions'
        $entra = $controls | Where-Object name -eq 'shardOptionsEntra'
        $domain.visible | Should -Match 'DomainServices'
        $domain.constraints.allowedValues.value | Should -Be @('None', 'ShardPerms', 'ShardOSS')
        $entra.visible | Should -Match 'EntraID'
        $entra.constraints.allowedValues.value | Should -Be @('None', 'ShardPerms')
        $domain.defaultValue | Should -Be 'No Sharding'
        $entra.defaultValue | Should -Be 'No Sharding'
        $binding = "if(equals(steps('hosts').identity.machineIdentity, 'EntraID'), steps('profiles').storage.shardOptionsEntra, steps('profiles').storage.shardOptions)"
        $form.view.outputs.parameters.fslogixShardOptions | Should -Match ([regex]::Escape($binding))
        $text.Replace($binding, 'ACTIVE_SHARD_OPTIONS') | Should -Not -Match "steps\('profiles'\)\.storage\.shardOptions"
        $explanation = $controls | Where-Object name -eq 'objectSpecificSettingsIdentity'
        $explanation.options.text | Should -Match 'not hybrid-joined machines'
        $explanation.options.text | Should -Not -Match '^\['
    }
}
