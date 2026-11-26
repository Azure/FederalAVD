BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
}

Describe 'Standalone storage external OSS controls' {
    BeforeAll {
        $formText = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\uiFormDefinition.json') -Raw
        $storageForm = $formText | ConvertFrom-Json
        $storageStep = $storageForm.view.properties.steps | Where-Object name -eq 'storage'
        $storageControls = @(Get-TestFormElement -Elements $storageStep.elements)
        $identityStep = $storageForm.view.properties.steps | Where-Object name -eq 'identity'
        $identityControls = @(Get-TestFormElement -Elements $identityStep.elements)

        function New-StorageFormSteps {
            param(
                [string]$Family = 'EntraID',
                [string]$Authentication = 'EntraKerberos-Hybrid',
                [string]$Sharding = 'ShardOSS',
                [string]$CloudSharding = 'ShardPerms',
                [string]$Credentials = 'manual',
                [bool]$LeastPrivilege = $false
            )
            @{
                identity = @{
                    machineIdentity = $Family
                    identitySolution = $Authentication
                    credentialSource = 'manual'
                    domainName = 'domain.fixture.invalid'
                    domainJoinUserPrincipalName = 'domain-lookup@fixture.invalid'
                    domainJoinUserPassword = 'domain-fixture-input'
                }
                storage = @{
                    storageService = 'AzureFiles'
                    shardOptions = $Sharding
                    shardOptionsCloudOnly = $CloudSharding
                    leastPrivilegedNtfs = $LeastPrivilege
                    hybridCredentialSource = $Credentials
                    hybridDomainName = 'hybrid.fixture.invalid'
                    hybridAdLookupUserPrincipalName = 'hybrid-lookup@fixture.invalid'
                    hybridAdLookupPassword = 'hybrid-fixture-input'
                    hybridCredentialsKeyVault = @{ id = 'fixture-vault-id' }
                    userGroupPickerBlade = @{
                        transformed = @{
                            groups = @(
                                @{ id = '11111111-1111-1111-1111-111111111111'; name = 'Shard A' }
                                @{ id = '22222222-2222-2222-2222-222222222222'; name = 'Shard B' }
                            )
                        }
                    }
                }
            }
        }
    }

    It 'selects storage authentication rather than claiming to join consumer hosts' {
        $family = $identityControls | Where-Object name -eq 'machineIdentity'
        $family.label | Should -Be 'Storage Authentication Family'
        $family.defaultValue | Should -Be 'Microsoft Entra Kerberos or storage account keys'
        $family.constraints.allowedValues.label | Should -Contain $family.defaultValue
        $family.constraints.allowedValues.value | Should -Be @('ActiveDirectoryDomainServices', 'EntraDomainServices', 'EntraID')
        $note = $storageControls | Where-Object name -eq 'hybridOssHostRequirements'
        $note.options.text | Should -Match 'Citrix'
        $note.options.text | Should -Match 'hybrid-Entra joined'
        $note.options.text | Should -Match 'Entra-only joined hosts remain unsupported'
        $note.options.text | Should -Not -Match '^\['
    }

    It 'exports the active sharding choice for <Family> / <Authentication>' -TestCases @(
        @{ Family = 'EntraID'; Authentication = 'EntraKerberos-Hybrid'; MainVisible = $true; CloudVisible = $false; Expected = 'ShardOSS' }
        @{ Family = 'EntraID'; Authentication = 'EntraKerberos-CloudOnly'; MainVisible = $false; CloudVisible = $true; Expected = 'ShardPerms' }
        @{ Family = 'EntraID'; Authentication = 'EntraId'; MainVisible = $false; CloudVisible = $false; Expected = 'None' }
        @{ Family = 'ActiveDirectoryDomainServices'; Authentication = 'EntraKerberos-CloudOnly'; MainVisible = $true; CloudVisible = $false; Expected = 'ShardOSS' }
        @{ Family = 'EntraDomainServices'; Authentication = 'EntraKerberos-Hybrid'; MainVisible = $true; CloudVisible = $false; Expected = 'ShardOSS' }
    ) {
        param($Family, $Authentication, $MainVisible, $CloudVisible, $Expected)
        $steps = New-StorageFormSteps -Family $Family -Authentication $Authentication
        $main = $storageControls | Where-Object name -eq 'shardOptions'
        $cloud = $storageControls | Where-Object name -eq 'shardOptionsCloudOnly'
        Invoke-TestNamingFormExpression -Expression $main.visible -Steps $steps | Should -Be $MainVisible
        Invoke-TestNamingFormExpression -Expression $cloud.visible -Steps $steps | Should -Be $CloudVisible
        Invoke-TestNamingFormExpression -Expression $storageForm.view.outputs.parameters.fslogixShardOptions -Steps $steps | Should -Be $Expected
        $expectedIdentity = if ($Family -eq 'EntraID') { $Authentication } else { $Family }
        Invoke-TestNamingFormExpression -Expression $storageForm.view.outputs.parameters.identitySolution -Steps $steps | Should -Be $expectedIdentity
    }

    It 'requires and exports manual AD lookup inputs for hybrid <Sharding> storage' -TestCases @(
        @{ Sharding = 'ShardOSS' }
        @{ Sharding = 'ShardPerms' }
    ) {
        param($Sharding)
        $steps = New-StorageFormSteps -Sharding $Sharding
        foreach ($name in @('hybridDomainName', 'hybridCredentialSource', 'hybridAdLookupUserPrincipalName', 'hybridAdLookupPassword', 'userGroupSelector')) {
            $control = $storageControls | Where-Object name -eq $name
            Invoke-TestNamingFormExpression -Expression $control.visible -Steps $steps | Should -BeTrue
            $control.constraints.required | Should -BeTrue
        }
        $outputs = $storageForm.view.outputs.parameters
        Invoke-TestNamingFormExpression -Expression $outputs.domainName -Steps $steps | Should -Be 'hybrid.fixture.invalid'
        Invoke-TestNamingFormExpression -Expression $outputs.domainJoinUserPrincipalName -Steps $steps | Should -Be 'hybrid-lookup@fixture.invalid'
        Invoke-TestNamingFormExpression -Expression $outputs.domainJoinUserPassword -Steps $steps | Should -Be 'hybrid-fixture-input'
        $groups = @(Invoke-TestNamingFormExpression -Expression $outputs.fslogixUserGroups -Steps $steps)
        $groups.name | Should -Be @('Shard A', 'Shard B')
    }

    It 'exports the lookup vault rather than manual credentials for hybrid OSS' {
        $steps = New-StorageFormSteps -Credentials 'keyVault'
        $vault = $storageControls | Where-Object name -eq 'hybridCredentialsKeyVault'
        Invoke-TestNamingFormExpression -Expression $vault.visible -Steps $steps | Should -BeTrue
        $outputs = $storageForm.view.outputs.parameters
        Invoke-TestNamingFormExpression -Expression $outputs.credentialsKeyVaultResourceId -Steps $steps | Should -Be 'fixture-vault-id'
        Invoke-TestNamingFormExpression -Expression $outputs.domainJoinUserPrincipalName -Steps $steps | Should -Be ''
        Invoke-TestNamingFormExpression -Expression $outputs.domainJoinUserPassword -Steps $steps | Should -Be ''
    }

    It 'preserves optional lookup behavior for unsharded hybrid storage with least privilege <LeastPrivilege>' -TestCases @(
        @{ LeastPrivilege = $false }
        @{ LeastPrivilege = $true }
    ) {
        param($LeastPrivilege)
        $steps = New-StorageFormSteps -Sharding 'None' -LeastPrivilege $LeastPrivilege
        $domain = $storageControls | Where-Object name -eq 'hybridDomainName'
        Invoke-TestNamingFormExpression -Expression $domain.visible -Steps $steps | Should -Be $LeastPrivilege
        $expected = if ($LeastPrivilege) { 'hybrid.fixture.invalid' } else { '' }
        Invoke-TestNamingFormExpression -Expression $storageForm.view.outputs.parameters.domainName -Steps $steps | Should -Be $expected
    }

    It 'ignores stale hybrid lookup inputs when a domain authentication family is selected' {
        $steps = New-StorageFormSteps -Family 'EntraDomainServices'
        $domain = $storageControls | Where-Object name -eq 'hybridDomainName'
        Invoke-TestNamingFormExpression -Expression $domain.visible -Steps $steps | Should -BeFalse
        Invoke-TestNamingFormExpression -Expression $storageForm.view.outputs.parameters.domainName -Steps $steps | Should -Be 'domain.fixture.invalid'
        $picker = $storageControls | Where-Object name -eq 'userGroupPickerBlade'
        Invoke-TestNamingFormExpression -Expression $picker.bladeReference.parameters.queries -Steps $steps | Should -Be 32
    }

    It 'retains literal options and uses the active selector in every dependent binding' {
        $main = $storageControls | Where-Object name -eq 'shardOptions'
        $cloud = $storageControls | Where-Object name -eq 'shardOptionsCloudOnly'
        $main.constraints.allowedValues.value | Should -Be @('None', 'ShardPerms', 'ShardOSS')
        $cloud.constraints.allowedValues.value | Should -Be @('None', 'ShardPerms')
        foreach ($control in @($main, $cloud)) {
            $control.constraints.allowedValues.GetType().IsArray | Should -BeTrue
            $control.defaultValue | Should -Be 'No Sharding'
        }
        $binding = "if(and(equals(steps('identity').machineIdentity, 'EntraID'), equals(steps('identity').identitySolution, 'EntraKerberos-CloudOnly')), steps('storage').shardOptionsCloudOnly, steps('storage').shardOptions)"
        $formText.Replace($binding, 'ACTIVE_SHARD_OPTIONS') | Should -Not -Match "steps\('storage'\)\.shardOptions"
    }
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

Describe 'Initializer OSS validation ownership in <RelativePath>' -ForEach @(
    @{ RelativePath = 'deployments\shared\scripts\Initialize-SessionHost.ps1' }
    @{ RelativePath = 'deployments\automatedHostPools\scripts\Initialize-SessionHost.ps1' }
) {
    BeforeAll {
        $scriptPath = Join-Path $repoRoot $RelativePath
        $source = Get-Content -LiteralPath $scriptPath -Raw
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
        if ($parseErrors) { throw ($parseErrors | Out-String) }
    }

    It 'leaves OSS eligibility and domain-join enforcement to deployment orchestration' {
        $source | Should -Not -Match 'Assert-FSLogixObjectSpecificSettings|PartOfDomain'
    }

    It 'preserves the fatal error path and ASCII-only source' {
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
