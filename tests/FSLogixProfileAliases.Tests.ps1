BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
}

Describe 'Lifecycle canonical FSLogix inputs' {
    It 'exports only canonical Profile arrays in <Consumer>' -TestCases @(
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
            $template.parameters.PSObject.Properties.Name | Should -Not -Contain $legacy
            @($template.parameters.$preferred.defaultValue).Count | Should -Be 0
            $template.parameters.$preferred.nullable | Should -Not -BeTrue
            $form.view.outputs.parameters.$preferred | Should -Not -BeNullOrEmpty
            $form.view.outputs.parameters.PSObject.Properties.Name | Should -Not -Contain $legacy
        }
    }

    It 'evaluates production SHR forwarding without aliases or redundant conditionals' {
        $directory = Join-Path $TestDrive 'consumer-contract'
        New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.bicep') -Raw
        $validation = [regex]::Match($source, '(?ms)^var validatedOfficeStorageAccounts = .*?(?=^// Use the same consumer contract)')
        $configuration = [regex]::Match($source, '(?ms)^var fslogixParameters = .*?(?=^// Session Host Parameters)')
        if (-not $validation.Success -or -not $configuration.Success) { throw 'Production FSLogix forwarding not found' }
        $module = Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\fslogix.bicep'
        $relativeModule = [Uri]::UnescapeDataString(([Uri]("$directory\")).MakeRelativeUri([Uri]$module).ToString())
        $fixture = Join-Path $directory 'forwarding.bicep'
        $lines = @(
            "targetScope = 'local'"
            "import { validateOfficeStorageAccounts } from '$relativeModule'"
        )
        $lines += [regex]::Matches($source, '(?m)^param fslogix\w+ [^\r\n]+') | ForEach-Object Value
        $lines += $validation.Value, $configuration.Value
        $lines += 'output encodedResults string = base64(string({ resolved: fslogixParameters }))'
        $cases = @(
            @{ enabled = $false; type = 'ProfileContainer'; local = @(); office = @(); remote = @(); remoteOffice = @(); service = 'AzureFiles' }
            @{ enabled = $true; type = 'ProfileContainer'; local = @(); office = @(); remote = @(); remoteOffice = @(); service = 'AzureFiles' }
            @{ enabled = $true; type = 'ProfileContainer'; local = @('pc02', 'pc01'); office = @(); remote = @(); remoteOffice = @(); service = 'AzureFiles' }
            @{ enabled = $true; type = 'ProfileOfficeContainer'; local = @('pc02', 'pc01'); office = @('oc02', 'oc01'); remote = @(); remoteOffice = @(); service = 'AzureFiles' }
            @{ enabled = $true; type = 'CloudCacheProfileContainer'; local = @('pc02', 'pc01'); office = @(); remote = @('remote-pc02', 'remote-pc01'); remoteOffice = @(); service = 'AzureFiles' }
            @{ enabled = $true; type = 'CloudCacheProfileOfficeContainer'; local = @('pc02', 'pc01'); office = @('oc02', 'oc01'); remote = @('remote-pc02', 'remote-pc01'); remoteOffice = @('remote-oc02', 'remote-oc01'); service = 'AzureFiles' }
            @{ enabled = $true; type = 'CloudCacheProfileOfficeContainer'; local = @(); office = @(); remote = @(); remoteOffice = @(); service = 'AzureNetAppFiles' }
        )
        foreach ($case in $cases) {
            $parameters = @{
                fslogixConfigureSessionHosts = $case.enabled
                fslogixContainerType = $case.type
                fslogixStorageService = $case.service
                fslogixLocalProfileStorageAccountResourceIds = $case.local
                fslogixLocalOfficeStorageAccountResourceIds = $case.office
                fslogixRemoteProfileStorageAccountResourceIds = $case.remote
                fslogixRemoteOfficeStorageAccountResourceIds = $case.remoteOffice
                fslogixLocalNetAppVolumeResourceIds = @('profile-volume', 'office-volume')
                fslogixRemoteNetAppVolumeResourceIds = @('remote-profile-volume', 'remote-office-volume')
            }
            $caseLines = foreach ($line in $lines) {
                $match = [regex]::Match($line, '^param (?<name>fslogix\w+) (?<type>[^=]+)=')
                if (-not $match.Success -or -not $parameters.ContainsKey($match.Groups['name'].Value)) {
                    $line
                    continue
                }
                $name = $match.Groups['name'].Value
                $value = $parameters[$name]
                $literal = if ($value -is [array]) {
                    '[' + (($value | ForEach-Object { "'$_'" }) -join ', ') + ']'
                }
                elseif ($value -is [bool]) { $value.ToString().ToLowerInvariant() }
                else { "'$value'" }
                "param $name $($match.Groups['type'].Value.Trim()) = $literal"
            }
            [IO.File]::WriteAllLines($fixture, $caseLines)
            $actual = (Invoke-TestNamingVectors -TemplateFile $fixture).resolved.value
            if (-not $case.enabled) {
                @($actual.PSObject.Properties).Count | Should -Be 0
                continue
            }
            $actual.fslogixContainerType | Should -Be $case.type
            $actual.fslogixStorageService | Should -Be $case.service
            $actual.fslogixSizeInMBs | Should -Be 30000
            foreach ($role in @('LocalProfile', 'LocalOffice', 'RemoteProfile', 'RemoteOffice')) {
                $key = "fslogix${role}StorageAccountResourceIds"
                @($actual.$key) | Should -Be @($parameters[$key])
            }
            $actual.fslogixLocalNetAppVolumeResourceIds | Should -Be $parameters.fslogixLocalNetAppVolumeResourceIds
            $actual.fslogixRemoteNetAppVolumeResourceIds | Should -Be $parameters.fslogixRemoteNetAppVolumeResourceIds
            $actual.PSObject.Properties.Name | Should -Not -Contain 'fslogixLocalStorageAccountResourceIds'
            $actual.PSObject.Properties.Name | Should -Not -Contain 'fslogixRemoteStorageAccountResourceIds'
        }
    }

    It 'maps saved canonical tags to dropdown labels in <Consumer>' -TestCases @(
        @{ Consumer = 'sessionHosts' }
        @{ Consumer = 'sessionHostReplacer' }
    ) {
        param($Consumer)
        $form = Get-Content (Join-Path $repoRoot "deployments\add-ons\$Consumer\uiFormDefinition.json") -Raw | ConvertFrom-Json
        $control = ($form.view.properties.steps | Where-Object name -EQ 'userProfiles').elements | Where-Object name -EQ 'fslogixContainerType'
        foreach ($choice in $control.constraints.allowedValues) {
            Invoke-TestNamingFormExpression $control.defaultValue @{ basics = @{ hostsRGProps = @{ tags = @{ fslContainerType = $choice.value } } } } | Should -Be $choice.label
        }
        Invoke-TestNamingFormExpression $control.defaultValue @{ basics = @{ hostsRGProps = @{ tags = @{} } } } | Should -Be 'Profile Container'
        Invoke-TestNamingFormExpression $control.defaultValue @{ basics = @{ hostsRGProps = @{ tags = @{ fslContainerType = 'Unknown' } } } } | Should -Be 'Unknown'
    }

    It 'adapts published policy parameters to canonical remediation inputs' {
        $source = Get-Content (Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\modules\configureSessionHost.policyDefinition.bicep') -Raw
        foreach ($location in @('Local', 'Remote')) {
            $value = [regex]::Escape("'[parameters(\'fslogix${location}StorageAccountResourceIds\')]'")
            $source | Should -Match "fslogix${location}ProfileStorageAccountResourceIds:\s+\{\s+value: $value"
        }
    }
}

Describe 'Initializer canonical Profile inputs' {
    It 'binds explicit Profile and Office arguments without legacy aliases in <Script>' -TestCases @(
        @{ Script = 'deployments\shared\scripts\Initialize-SessionHost.ps1' }
        @{ Script = 'deployments\automatedHostPools\scripts\Initialize-SessionHost.ps1' }
    ) {
        param($Script)
        $source = Get-Content (Join-Path $repoRoot $Script) -Raw
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
        $declared = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        $source | Should -Not -Match '\b(Local|Remote)StorageAccount(Names|Keys)'
        $inputs = @{ TimeZone = 'UTC' }
        foreach ($location in @('Local', 'Remote')) {
            foreach ($role in @('Profile', 'Office')) {
                foreach ($kind in @('Names', 'Keys')) {
                    $name = "${location}${role}StorageAccount${kind}"
                    $declared | Should -Contain $name
                    $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $name }
                    $parameter.StaticType | Should -Be ([string])
                    $parameter.DefaultValue.Extent.Text | Should -Be "'[]'"
                    $parameter.Attributes.TypeName.Name | Should -Not -Contain 'Alias'
                    $inputs[$name] = '["/first==","second"]'
                }
            }
        }
        $binder = [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`nreturn `$PSBoundParameters")
        $bound = & $binder @inputs
        foreach ($name in $inputs.Keys) { $bound[$name] | Should -BeExactly $inputs[$name] }
    }

    It 'matches compiled Run Command arguments to the embedded <Script> contract' -TestCases @(
        @{ Script = 'deployments\shared\scripts\Initialize-SessionHost.ps1'; Template = 'deployments\add-ons\sessionHosts\main.json' }
        @{ Script = 'deployments\automatedHostPools\scripts\Initialize-SessionHost.ps1'; Template = 'deployments\shared\modules\orchestration\sessionHostPolicy\modules\templates\RunCommand\ConfigureSessionHost.json' }
    ) {
        param($Script, $Template)
        function Get-InitializerRunCommands {
            param($Node)
            $resources = if ($Node.resources -is [array]) { $Node.resources } else { $Node.resources.PSObject.Properties.Value }
            foreach ($resource in $resources) {
                if ($resource.type -eq 'Microsoft.Compute/virtualMachines/runCommands') {
                    $embeddedScript = [string]$resource.properties.source.script
                    $reference = [regex]::Match($embeddedScript, "^\[variables\('(?<name>[^']+)'\)\]$")
                    if ($reference.Success) {
                        $variableName = $reference.Groups['name'].Value
                        $embeddedScript = $Node.variables.$variableName
                    }
                    if ($embeddedScript -like "*`$Script:Name = 'Initialize-SessionHost'*") {
                        [pscustomobject]@{ Command = $resource; Script = $embeddedScript }
                    }
                }
                if ($resource.properties.template) { Get-InitializerRunCommands $resource.properties.template }
            }
        }
        $templateObject = Get-Content (Join-Path $repoRoot $Template) -Raw | ConvertFrom-Json -Depth 100
        $commands = @(Get-InitializerRunCommands $templateObject)
        $commands.Count | Should -Be 1
        $command = $commands[0].Command
        $source = Get-Content (Join-Path $repoRoot $Script) -Raw
        $commands[0].Script | Should -BeExactly $source
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        $declared = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        foreach ($argument in $command.properties.parameters.name) { $declared | Should -Contain $argument }
        $protected = $command.properties.protectedParameters | ConvertTo-Json -Depth 100 -Compress
        foreach ($location in @('Local', 'Remote')) {
            foreach ($role in @('Profile', 'Office')) {
                $name = "${location}${role}StorageAccountNames"
                @($command.properties.parameters | Where-Object name -EQ $name).Count | Should -Be 1
                $key = "${location}${role}StorageAccountKeys"
                $protected | Should -Match ([regex]::Escape($key))
                $command.properties.parameters.name | Should -Not -Contain $key
            }
        }
        $protected | Should -Not -Match '\b(Local|Remote)StorageAccountKeys'
    }
}

Describe 'Session host consumer defaults' {
    It 'evaluates Boolean form literals without changing quoted text' {
        Invoke-TestNamingFormExpression '[false]' @{} | Should -BeFalse
        Invoke-TestNamingFormExpression "[concat('false', if(true, 'T', 'F'))]" @{} | Should -Be 'falseT'
        Invoke-TestNamingFormExpression '[if($true, $false, $true)]' @{} | Should -BeFalse
    }

    It 'uses 30000 MB in Bicep and Portal outputs for <Kind>' -TestCases @(
        @{ Kind = 'Standard'; Directory = 'hostpools'; Template = 'hostpool.json'; Parameter = 'fslogixSizeInMBs' }
        @{ Kind = 'Automated'; Directory = 'automatedHostPools'; Template = 'automatedHostPool.json'; Parameter = 'fslogixProfileSizeInMBs' }
        @{ Kind = 'Additional'; Directory = 'add-ons\sessionHosts'; Template = 'main.json'; Parameter = 'fslogixSizeInMBs' }
        @{ Kind = 'SHR'; Directory = 'add-ons\sessionHostReplacer'; Template = 'main.json'; Parameter = 'fslogixSizeInMBs' }
    ) {
        param($Kind, $Directory, $Template, $Parameter)
        $directoryPath = Join-Path $repoRoot "deployments\$Directory"
        $arm = Get-Content (Join-Path $directoryPath $Template) -Raw | ConvertFrom-Json -Depth 100
        $arm.parameters.$Parameter.defaultValue | Should -Be 30000
        $form = Get-Content (Join-Path $directoryPath 'uiFormDefinition.json') -Raw | ConvertFrom-Json
        $control = if ($Kind -eq 'Automated') {
            (($form.view.properties.steps | Where-Object name -EQ profiles).elements |
                Where-Object name -EQ storage).elements | Where-Object name -EQ profileSizeInMBs
        }
        else {
            ($form.view.properties.steps | Where-Object name -EQ userProfiles).elements |
                Where-Object name -EQ sizeInMBs
        }
        $steps = @{
            basics = @{ hostsRGProps = @{ tags = @{} } }
            userProfiles = @{ configureSessionHosts = $false; profileSolution = 'FSLogix'; sizeInMBs = 49152 }
            profiles = @{ configureSessionHosts = $false; storage = @{ profileSizeInMBs = 49152 } }
        }
        if ($control.defaultValue -is [string]) {
            Invoke-TestNamingFormExpression $control.defaultValue $steps | Should -Be 30000
            $steps.basics.hostsRGProps.tags.fslContainerSizeInMBs = '30720'
            Invoke-TestNamingFormExpression $control.defaultValue $steps | Should -Be 30720
        }
        else { $control.defaultValue | Should -Be 30000 }
        Invoke-TestNamingFormExpression $form.view.outputs.parameters.$Parameter $steps | Should -Be 30000
        $steps.userProfiles.configureSessionHosts = $true
        $steps.profiles.configureSessionHosts = $true
        Invoke-TestNamingFormExpression $form.view.outputs.parameters.$Parameter $steps | Should -Be 49152
    }

    It 'enables integrity monitoring by default and preserves Portal opt-outs in <Directory>' -TestCases @(
        @{ Directory = 'hostpools'; Template = 'hostpool.json' }
        @{ Directory = 'automatedHostPools'; Template = 'automatedHostPool.json' }
        @{ Directory = 'add-ons\sessionHosts'; Template = 'main.json' }
        @{ Directory = 'add-ons\sessionHostReplacer'; Template = 'main.json' }
    ) {
        param($Directory, $Template)
        $directoryPath = Join-Path $repoRoot "deployments\$Directory"
        $arm = Get-Content (Join-Path $directoryPath $Template) -Raw | ConvertFrom-Json -Depth 100
        $arm.parameters.integrityMonitoring.defaultValue | Should -BeTrue
        $form = Get-Content (Join-Path $directoryPath 'uiFormDefinition.json') -Raw | ConvertFrom-Json
        foreach ($case in @(
            @{ securityType = 'TrustedLaunch'; selected = $true; expected = $true }
            @{ securityType = 'TrustedLaunch'; selected = $false; expected = $false }
            @{ securityType = 'Standard'; selected = $true; expected = $false }
        )) {
            $steps = @{ hosts = @{ security = @{ securityType = $case.securityType; integrityMonitoring = $case.selected } } }
            Invoke-TestNamingFormExpression $form.view.outputs.parameters.integrityMonitoring $steps | Should -Be $case.expected
        }
    }

    It 'forwards explicit false integrity monitoring rather than inheriting the enabled child default' {
        $source = Get-Content (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.bicep') -Raw
        $base = [regex]::Match($source, '(?ms)^var sessionHostParameters = union\(\s+\{(?<base>.*?)\n\s+\},').Groups['base'].Value
        $expression = [regex]::Match($base, '(?m)^\s+integrityMonitoring: (?<expression>[^\r\n]+)').Groups['expression'].Value
        if ([string]::IsNullOrWhiteSpace($expression)) { throw 'SHR integrity-monitoring forwarding not found' }
        $source | Should -Not -Match 'paramIntegrityMonitoring'
        foreach ($enabled in @($true, $false)) {
            $fixture = Join-Path $TestDrive 'integrity-forwarding.bicep'
            [IO.File]::WriteAllLines($fixture, @(
                "targetScope = 'local'"
                "param integrityMonitoring bool = $($enabled.ToString().ToLowerInvariant())"
                "output encodedResults string = base64(string({ integrity: $expression }))"
            ))
            (Invoke-TestNamingVectors -TemplateFile $fixture).integrity.value | Should -Be $enabled
        }
    }

    It 'restricts SHR disks to the session-host contract and keeps Portal choices supported' {
        $expected = @(0, 32, 64, 128, 256, 512, 1024, 2048)
        foreach ($directory in @('add-ons\sessionHosts', 'add-ons\sessionHostReplacer')) {
            $directoryPath = Join-Path $repoRoot "deployments\$directory"
            $arm = Get-Content (Join-Path $directoryPath 'main.json') -Raw | ConvertFrom-Json -Depth 100
            $arm.parameters.diskSizeGB.allowedValues | Should -Be $expected
            $arm.parameters.diskSizeGB.defaultValue | Should -Be 0
            foreach ($invalid in @(-1, 16, 63, 100, 4096)) {
                $arm.parameters.diskSizeGB.allowedValues | Should -Not -Contain $invalid
            }
            $form = Get-Content (Join-Path $directoryPath 'uiFormDefinition.json') -Raw | ConvertFrom-Json
            $control = (($form.view.properties.steps | Where-Object name -EQ hosts).elements |
                Where-Object name -EQ specs).elements | Where-Object name -EQ diskSizeGB
            foreach ($option in $control.constraints.allowedValues) { $expected | Should -Contain $option.value }
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
