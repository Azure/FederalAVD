BeforeDiscovery {
    $producerCases = @(
        @{ Name = 'standard host pool'; Entry = 'deployments\hostpools\hostpool.bicep'; LegacyTier = 'Standard'; Kind = 'Standard' }
        @{ Name = 'automated host pool'; Entry = 'deployments\automatedHostPools\automatedHostPool.bicep'; LegacyTier = 'Premium'; Kind = 'Automated' }
        @{ Name = 'standalone storage'; Entry = 'deployments\add-ons\fslogixStorage\main.bicep'; LegacyTier = 'Standard'; Kind = 'Addon' }
    )
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
    $fixtureDirectory = Join-Path $repoRoot ('.fslogix-v2-producers-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixtureDirectory -ErrorAction Stop | Out-Null

    function Get-ProducerSourceBlock {
        param([string]$Source, [string]$Declaration, [string]$Name)

        $pattern = '(?ms)^' + [regex]::Escape($Declaration) + ' ' + [regex]::Escape($Name) + '\b.*?^\}'
        $match = [regex]::Match($Source, $pattern)
        if (-not $match.Success) { throw "Missing production block $Declaration $Name" }
        $match.Value
    }

    function Invoke-ProducerExpressions {
        param([string]$Source, [string]$Kind, [hashtable]$Overrides = @{}, [switch]$UseProductionNaming)

        $isAddon = $Kind -eq 'Addon'
        $prefix = if ($isAddon) { 'effective' } else { 'effectiveFslogix' }
        $tierVariable = if ($isAddon) { 'effectiveProfileStorageTier' } else { 'effectiveFslogixProfileStorageTier' }
        $officeTierVariable = switch ($Kind) {
            'Addon' { 'effectiveOfficeStorageTier' }
            default { 'effectiveFslogixOfficeStorageTier' }
        }
        $variables = @(
            $(if ($isAddon) { 'storageSolution' } elseif ($Kind -eq 'Automated') { 'fslogixStorageSolution' })
            $tierVariable
            "${prefix}OfficeStorageBillingModel"
            $officeTierVariable
            "${prefix}OfficeStorageRedundancy"
            "${prefix}OfficeShareSizeInGB"
        ) | Where-Object { $_ }
        $outputs = [ordered]@{
            tier = $tierVariable
            redundancy = 'fslogixProfileStorageRedundancy'
            quota = 'fslogixProfileShareSizeInGB'
            backend = 'fslogixStorageService'
            netAppLevel = 'fslogixNetAppServiceLevel'
            officeTier = $officeTierVariable
            officeRedundancy = "${prefix}OfficeStorageRedundancy"
            officeQuota = "${prefix}OfficeShareSizeInGB"
            profileBilling = 'fslogixProfileStorageBillingModel'
            officeBilling = "${prefix}OfficeStorageBillingModel"
            profileIops = 'fslogixProfileProvisionedIops'
            profileThroughput = 'fslogixProfileProvisionedThroughputMiBps'
            officeIops = 'fslogixOfficeProvisionedIops'
            officeThroughput = 'fslogixOfficeProvisionedThroughputMiBps'
            namingPrefix = 'naming.fslogixProfileStorageAccountNamePrefix'
        }
        if ($isAddon) {
            $variables += 'effectiveProfileStorageAccountNamePrefix'
            $outputs.prefix = 'effectiveProfileStorageAccountNamePrefix'
        }
        else {
            $variables += 'effectiveFslogixProfileStorageAccountNamePrefix'
            $outputs.prefix = 'effectiveFslogixProfileStorageAccountNamePrefix'
            if ($Kind -eq 'Standard') {
                $variables += 'effectiveFslogixExistingLocalProfileStorageAccountResourceIds',
                    'effectiveFslogixExistingRemoteProfileStorageAccountResourceIds'
                $outputs.local = 'effectiveFslogixExistingLocalProfileStorageAccountResourceIds'
                $outputs.remote = 'effectiveFslogixExistingRemoteProfileStorageAccountResourceIds'
            }
            else {
                $outputs.local = 'fslogixExistingLocalProfileStorageAccountResourceIds'
                $outputs.remote = 'fslogixExistingRemoteProfileStorageAccountResourceIds'
            }
        }

        function ConvertTo-BicepLiteral($Value) {
            if ($null -eq $Value) { return 'null' }
            if ($Value -is [System.Collections.IDictionary]) {
                return '{' + (($Value.GetEnumerator() | ForEach-Object {
                    "$($_.Key): $(ConvertTo-BicepLiteral $_.Value)"
                }) -join ', ') + '}'
            }
            if ($Value -is [array]) { return '[' + (($Value | ForEach-Object { ConvertTo-BicepLiteral $_ }) -join ', ') + ']' }
            if ($Value -is [string]) { return "'" + $Value.Replace("'", "\'") + "'" }
            return [string]$Value
        }

        $lines = @("targetScope = 'local'", "var naming = { fslogixProfileStorageAccountNamePrefix: 'legacyprefix' }")
        if ($UseProductionNaming) {
            $namingModule = Join-Path $repoRoot 'deployments\shared\modules\orchestration\naming\naming.bicep'
            $relativeNamingModule = [IO.Path]::GetRelativePath($fixtureDirectory, $namingModule).Replace('\', '/')
            $function = if ($isAddon) { 'fslogixNames' } else { 'hostPoolNames' }
            $convention = if ($Overrides.ContainsKey('namingConvention')) { $Overrides.namingConvention } else { @{} }
            $lines = @(
                "targetScope = 'local'"
                "import { $function } from '$relativeNamingModule'"
                "var $(if ($isAddon) { 'namingConvention' } else { 'effectiveNamingConvention' }) = $(ConvertTo-BicepLiteral $convention)"
            )
            if ($Kind -eq 'Standard') {
                $lines += "var hpBaseName = 'fixture'", "var virtualMachinesLocation = 'eastus2'",
                    "var effectiveControlPlaneSubscription = '00000000-0000-0000-0000-000000000001'"
            }
            else {
                $lines += "var identifier = 'fixture'", "var location = 'eastus2'"
            }
            if (-not $isAddon) {
                $lines += "var controlPlaneLocation = 'eastus2'", "var avdPrivateLinkPrivateRoutes = 'None'",
                    "var existingFeedWorkspaceResourceId = ''"
            }
            $namingExpression = [regex]::Match($Source, '(?ms)^var naming = .*?^\}\)')
            if (-not $namingExpression.Success) { throw 'Missing production naming expression' }
            $lines += $namingExpression.Value.Replace('subscription().subscriptionId', "'00000000-0000-0000-0000-000000000001'").Replace('environment().name', "'AzureCloud'")
        }
        $inputNames = @(
            'fslogixStorageService', 'fslogixNetAppServiceLevel', 'fslogixProfileStorageTier',
            'fslogixProfileStorageRedundancy', 'fslogixProfileShareSizeInGB', 'fslogixProfileStorageAccountNamePrefix',
            'fslogixOfficeStorageTier', 'fslogixOfficeStorageRedundancy', 'fslogixOfficeShareSizeInGB',
            'fslogixProfileStorageBillingModel', 'fslogixOfficeStorageBillingModel',
            'fslogixProfileProvisionedIops', 'fslogixProfileProvisionedThroughputMiBps',
            'fslogixOfficeProvisionedIops', 'fslogixOfficeProvisionedThroughputMiBps'
        )
        if (-not $isAddon) {
            $inputNames += 'fslogixExistingLocalProfileStorageAccountResourceIds',
                'fslogixExistingRemoteProfileStorageAccountResourceIds'
            if ($Kind -eq 'Standard') {
                $identity = if ($Overrides.ContainsKey('identitySolution')) { $Overrides.identitySolution } else { 'ActiveDirectoryDomainServices' }
                $lines += "var identitySolution = '$identity'"
            }
        }
        foreach ($name in $inputNames) {
            $declaration = [regex]::Match($Source, "(?m)^param $name (?:string\[\]\??|string\??|int\??)(?: = (?<default>[^\r\n]+))?\r?$")
            if (-not $declaration.Success) { throw "Missing production parameter $name" }
            $literal = if ($Overrides.ContainsKey($name)) { ConvertTo-BicepLiteral $Overrides[$name] }
                elseif ($declaration.Groups['default'].Success) { $declaration.Groups['default'].Value }
                else { 'null' }
            $lines += if ($literal -eq 'null') { $declaration.Value.TrimEnd() } else { "var $name = $literal" }
        }
        foreach ($name in $variables) {
            $match = [regex]::Match($Source, "(?m)^var $name\b[^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)*")
            if (-not $match.Success) { throw "Missing production variable $name" }
            $lines += $match.Value
        }
        $lines += 'output encodedResults string = base64(string({'
        foreach ($item in $outputs.GetEnumerator()) { $lines += "  $($item.Key): $($item.Value)" }
        $lines += '}))'
        $path = Join-Path $fixtureDirectory "$Kind.bicep"
        [IO.File]::WriteAllLines($path, $lines)
        Invoke-TestNamingVectors -TemplateFile $path
    }
}

AfterAll {
    if (Test-Path -LiteralPath $fixtureDirectory) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
}

Describe 'FSLogix producer v2 inputs' {
    Context '<Name>' -ForEach $producerCases {
        BeforeAll {
            $source = (Get-Content (Join-Path $repoRoot $Entry) -Raw).Replace("`r`n", "`n")
            $formPath = Join-Path (Split-Path (Join-Path $repoRoot $Entry)) 'uiFormDefinition.json'
            $form = Get-Content $formPath -Raw | ConvertFrom-Json
            $elements = @($form.view.properties.steps | ForEach-Object { Get-TestFormElement $_.elements })
            $bindings = $form.view.outputs.parameters
        }

        It 'evaluates unchanged legacy omission defaults' {
            $result = Invoke-ProducerExpressions $source $Kind
            $result.tier.value | Should -Be $LegacyTier
            $result.profileBilling.value | Should -Be 'Legacy'
            $result.officeBilling.value | Should -Be 'Legacy'
            $result.redundancy.value | Should -Be 'LocallyRedundant'
            $result.quota.value | Should -Be 100
            $result.officeQuota.value | Should -Be 100
            $result.prefix.value | Should -Be 'legacyprefix'
        }

        It 'evaluates canonical Profile inputs and keeps performance independent' {
            $overrides = @{
                fslogixProfileShareSizeInGB = 8192
                fslogixProfileStorageTier = 'Premium'
                fslogixStorageService = 'AzureFiles'
                fslogixNetAppServiceLevel = 'Standard'
                fslogixProfileStorageRedundancy = 'ZoneRedundant'
                fslogixProfileStorageAccountNamePrefix = 'newprefix'
                fslogixProfileStorageBillingModel = 'ProvisionedV2'
                fslogixProfileProvisionedIops = 10000
                fslogixProfileProvisionedThroughputMiBps = 500
                fslogixOfficeShareSizeInGB = 1024
            }
            $result = Invoke-ProducerExpressions $source $Kind $overrides
            $result.tier.value | Should -Be 'Premium'
            $result.backend.value | Should -Be 'AzureFiles'
            $result.quota.value | Should -Be 8192
            $result.redundancy.value | Should -Be 'ZoneRedundant'
            $result.prefix.value | Should -Be 'newprefix'
            $result.officeTier.value | Should -Be 'Premium'
            $result.officeQuota.value | Should -Be 1024
            $result.officeRedundancy.value | Should -Be 'ZoneRedundant'
            $result.officeBilling.value | Should -Be 'ProvisionedV2'
            $result.profileIops.value | Should -Be 10000
            $result.profileThroughput.value | Should -Be 500
            $result.officeIops.value | Should -Be 0
            $result.officeThroughput.value | Should -Be 0
        }

        It 'evaluates an independent Office tier and billing override' {
            $result = Invoke-ProducerExpressions $source $Kind @{
                fslogixProfileStorageBillingModel = 'ProvisionedV2'
                fslogixOfficeStorageBillingModel = 'Legacy'
                fslogixOfficeStorageTier = 'Standard'
                fslogixOfficeStorageRedundancy = 'LocallyRedundant'
                fslogixProfileStorageRedundancy = 'ZoneRedundant'
            }
            $result.officeBilling.value | Should -Be 'Legacy'
            $result.officeTier.value | Should -Be 'Standard'
            $result.officeRedundancy.value | Should -Be 'LocallyRedundant'
        }

        It 'evaluates canonical Profile prefix overrides using production naming' {
            $overrides = if ($Kind -eq 'Addon') {
                @{ fslogixProfileStorageAccountNamePrefix = 'oldprefix' }
            }
            else {
                @{ namingConvention = @{ fslogixProfileStoragePrefix = 'oldprefix' } }
            }
            $legacy = Invoke-ProducerExpressions $source $Kind $overrides -UseProductionNaming
            $legacy.prefix.value | Should -Be 'oldprefix'
            $overrides.fslogixProfileStorageAccountNamePrefix = 'newprefix'
            $preferred = Invoke-ProducerExpressions $source $Kind $overrides -UseProductionNaming
            $preferred.prefix.value | Should -Be 'newprefix'
            if ($Kind -ne 'Addon') { $preferred.namingPrefix.value | Should -Be 'oldprefix' }
        }

        It 'selects ANF service level independently of Azure Files media and rejects incompatible tuning' {
            $result = Invoke-ProducerExpressions $source $Kind @{
                fslogixStorageService = 'AzureNetAppFiles'
                fslogixNetAppServiceLevel = 'Standard'
                fslogixProfileStorageTier = 'Premium'
                fslogixProfileShareSizeInGB = 2048
            }
            $result.backend.value | Should -Be 'AzureNetAppFiles'
            $result.netAppLevel.value | Should -Be 'Standard'
            $result.quota.value | Should -Be 2048
            { Invoke-ProducerExpressions $source $Kind @{
                fslogixStorageService = 'AzureNetAppFiles'
                fslogixProfileStorageBillingModel = 'ProvisionedV2'
            } } | Should -Throw '*cannot be used*'
        }

        It 'passes all v2 and effective Profile values to the shared producer contract' {
            foreach ($name in @('profileProvisionedIops', 'profileProvisionedThroughputMiBps', 'officeProvisionedIops', 'officeProvisionedThroughputMiBps')) {
                $publicName = 'fslogix' + $name.Substring(0, 1).ToUpperInvariant() + $name.Substring(1)
                $source | Should -Match ("(?m)^\s+$name`: $publicName`$")
                $source | Should -Match ("(?m)^param $publicName int = 0$")
            }
            $source | Should -Match '(?m)^\s+profileStorageBillingModel: fslogixProfileStorageBillingModel$'
            $source | Should -Match '(?m)^\s+officeStorageBillingModel: effective(?:Fslogix)?OfficeStorageBillingModel$'
            $source | Should -Match '(?m)^\s+profileShareSizeInGB: fslogixProfileShareSizeInGB$'
            $source | Should -Match '(?m)^\s+profileStorageRedundancy: fslogixProfileStorageRedundancy$'
            $source | Should -Not -Match '(?m)^param fslogixProfile\w+ (?:string|int)\? = null'
        }

        It 'wires resolved values into the actual storage producer and local/remote host configuration' {
            $producerCalls = [regex]::Matches($source, "(?ms)^module \w+ '[^']*/orchestration/fslogix/fslogix\.bicep' =.*?^\}")
            $producerCalls.Count | Should -Be 1
            $producer = $producerCalls[0].Value
            $effectivePrefix = if ($Kind -eq 'Addon') { 'effective' } else { 'effectiveFslogix' }
            $expected = @{
                profileShareSizeInGB = 'fslogixProfileShareSizeInGB'
                profileStorageRedundancy = 'fslogixProfileStorageRedundancy'
                profileStorageTier = $(if ($Kind -eq 'Addon') { 'effectiveProfileStorageTier' } else { 'effectiveFslogixProfileStorageTier' })
                netAppServiceLevel = 'fslogixNetAppServiceLevel'
                officeStorageTier = "${effectivePrefix}OfficeStorageTier"
                profileStorageAccountNamePrefix = $(if ($Kind -eq 'Addon') { 'effectiveProfileStorageAccountNamePrefix' } else { 'effectiveFslogixProfileStorageAccountNamePrefix' })
                profileStorageBillingModel = 'fslogixProfileStorageBillingModel'
                officeStorageBillingModel = "${effectivePrefix}OfficeStorageBillingModel"
                profileProvisionedIops = 'fslogixProfileProvisionedIops'
                profileProvisionedThroughputMiBps = 'fslogixProfileProvisionedThroughputMiBps'
                officeProvisionedIops = 'fslogixOfficeProvisionedIops'
                officeProvisionedThroughputMiBps = 'fslogixOfficeProvisionedThroughputMiBps'
                officeShareSizeInGB = "${effectivePrefix}OfficeShareSizeInGB"
                officeStorageRedundancy = "${effectivePrefix}OfficeStorageRedundancy"
            }
            foreach ($binding in $expected.GetEnumerator()) {
                $producer | Should -Match ('(?m)^\s+' + [regex]::Escape($binding.Key) + ': ' + [regex]::Escape($binding.Value) + '$')
            }

            if ($Kind -eq 'Standard') {
                $hosts = Get-ProducerSourceBlock $source 'module' 'sessionHosts'
                $hosts | Should -Match 'fslogixLocalProfileStorageAccountResourceIds: deployFSLogixStorage\s+\? fslogix!\.outputs\.profileStorageAccountResourceIds\s+: effectiveFslogixExistingLocalProfileStorageAccountResourceIds'
                $hosts | Should -Match '(?m)^\s+fslogixRemoteProfileStorageAccountResourceIds: effectiveFslogixExistingRemoteProfileStorageAccountResourceIds$'
                $source | Should -Match '(?m)^output fslogixRemoteProfileStorageAccountResourceIds array = effectiveFslogixExistingRemoteProfileStorageAccountResourceIds$'
                $source | Should -Match '(?m)^output fslogixLocalProfileStorageAccountResourceIds array = deployFSLogixStorage\s+\? fslogix!\.outputs\.profileStorageAccountResourceIds\s+: effectiveFslogixExistingLocalProfileStorageAccountResourceIds'
                $source | Should -Match '(?m)^var effectiveNamingConvention = union\(\s+namingConvention,'
            }
            elseif ($Kind -eq 'Automated') {
                $existing = Get-ProducerSourceBlock $source 'var' 'existingFslogixConfiguration'
                $deployed = Get-ProducerSourceBlock $source 'var' 'deployedFslogixConfiguration'
                $existing | Should -Match '(?m)^\s+localProfileStorageAccountResourceIds: fslogixExistingLocalProfileStorageAccountResourceIds$'
                $existing | Should -Match '(?m)^\s+remoteProfileStorageAccountResourceIds: fslogixExistingRemoteProfileStorageAccountResourceIds$'
                $deployed | Should -Match '(?m)^\s+localProfileStorageAccountResourceIds: fslogixStorage!\.outputs\.profileStorageAccountResourceIds$'
                $deployed | Should -Match '(?m)^\s+remoteProfileStorageAccountResourceIds: fslogixExistingRemoteProfileStorageAccountResourceIds$'
                $policy = Get-ProducerSourceBlock $source 'module' 'sessionHostPolicy'
                $policy | Should -Match '(?m)^\s+fslogixConfiguration: deployFSLogixStorage \? deployedFslogixConfiguration : existingFslogixConfiguration$'
                $source | Should -Match '(?m)^var effectiveNamingConvention = union\(\s+namingConvention,'
            }
            else {
                $configuration = Get-ProducerSourceBlock $source 'output' 'fslogixConfiguration'
                $configuration | Should -Match '(?m)^\s+localProfileStorageAccountResourceIds: fslogix\.outputs\.profileStorageAccountResourceIds$'
                $configuration | Should -Match '(?m)^\s+remoteProfileStorageAccountResourceIds: remoteStorageAccountConfigurationIsValid \? remoteProfileStorageAccountResourceIds : \[\]$'
            }
        }

        It 'exports only preferred aliases and declared parameters from the form' {
            foreach ($binding in $bindings.PSObject.Properties) {
                $source | Should -Match ("(?m)^param " + [regex]::Escape($binding.Name) + ' ')
            }
            foreach ($name in @('fslogixProfileShareSizeInGB', 'fslogixProfileStorageTier', 'fslogixProfileStorageRedundancy', 'fslogixProfileStorageAccountNamePrefix')) {
                $bindings.PSObject.Properties.Name | Should -Contain $name
            }
            $bindings.PSObject.Properties.Name | Should -Not -Contain 'fslogixStorageRedundancy'
            $bindings.PSObject.Properties.Name | Should -Not -Contain 'fslogixShareSizeInGB'
            $bindings.PSObject.Properties.Name | Should -Not -Contain 'shareSizeInGB'
            $bindings.PSObject.Properties.Name | Should -Not -Contain 'profileStorageAccountNamePrefix'
            $bindings.namingConvention | Should -Not -Match 'fslogixProfileStoragePrefix'
        }

        It 'defaults the UI to v2 and explains capacity-based automatic performance with safe hidden outputs' {
            $profileBilling = $elements | Where-Object name -EQ 'profileStorageBillingModel'
            $profileBilling.defaultValue | Should -Be 'Provisioned v2'
            $profileBilling.constraints.allowedValues.value | Should -Be @('Legacy', 'ProvisionedV2')
            ($elements | Where-Object name -EQ 'officeStorageBillingModel').defaultValue | Should -Be 'Inherit Profile'
            foreach ($name in @('profileProvisionedIops', 'profileProvisionedThroughputMiBps', 'officeProvisionedIops', 'officeProvisionedThroughputMiBps')) {
                $element = $elements | Where-Object name -EQ $name
                $element.defaultValue | Should -Be '0'
                $element.label | Should -Match '0 = Automatic \(capacity-based\)'
                $element.label | Should -Not -Match 'recommended'
                $element.visible | Should -Match 'ProvisionedV2'
                if ($name.StartsWith('profile')) {
                    $element.constraints.validationMessage | Should -Match 'automatically calculates performance from the Profile share capacity'
                }
                $binding = $bindings.('fslogix' + $name.Substring(0, 1).ToUpperInvariant() + $name.Substring(1))
                $binding | Should -Match 'ProvisionedV2'
                $binding | Should -Match ', 0\)\]$'
                $binding | Should -Match 'int\('
            }
            $bindings.fslogixProfileStorageBillingModel | Should -Match "'Legacy'\)\]$"
            $bindings.fslogixOfficeStorageBillingModel | Should -Match "'Inherit'\)\]$"
        }

        It 'evaluates numeric form outputs and resets hidden performance for legacy and ANF' {
            $evaluatedBindings = @{}
            foreach ($binding in $bindings.PSObject.Properties) {
                $evaluatedBindings[$binding.Name] = $binding.Value.Replace(', true)', ', $true)')
            }
            $bindings = $evaluatedBindings
            $controls = @{
                profileStorageBillingModel = 'ProvisionedV2'
                officeStorageBillingModel = 'Inherit'
                profileProvisionedIops = '10000'
                profileProvisionedThroughputMiBps = '500'
                officeProvisionedIops = '0'
                officeProvisionedThroughputMiBps = '0'
                storageRedundancy = 'ZoneRedundant'
                storageShareSize = 4096
                shareSizeInGB = '4096'
                service = 'AzureFiles'
                storageService = 'AzureFiles'
                storageSku = 'Premium'
                profileStorageTier = 'Premium'
                netAppServiceLevel = 'Standard'
                containerType = 'ProfileOfficeContainer'
            }
            $steps = switch ($Kind) {
                'Standard' { @{
                    userProfiles = @{
                        storageService = 'AzureFiles'
                        deployStorage = $true
                        fslogixContainerType = 'ProfileOfficeContainer'
                        azureFiles = $controls
                        azureNetAppFiles = @{ storageShareSize = 2048; storageSku = 'Standard' }
                    }
                } }
                'Automated' { @{
                    profiles = @{
                        profileSolution = 'FSLogix'
                        configureSessionHosts = $true
                        deployStorage = $true
                        storage = $controls
                    }
                } }
                default { @{ storage = $controls } }
            }
            (Invoke-TestNamingFormExpression $bindings.fslogixProfileProvisionedIops $steps) | Should -Be 10000
            (Invoke-TestNamingFormExpression $bindings.fslogixProfileProvisionedThroughputMiBps $steps) | Should -Be 500
            (Invoke-TestNamingFormExpression $bindings.fslogixOfficeProvisionedIops $steps) | Should -Be 0
            (Invoke-TestNamingFormExpression $bindings.fslogixOfficeStorageBillingModel $steps) | Should -Be 'Inherit'
            (Invoke-TestNamingFormExpression $bindings.fslogixProfileShareSizeInGB $steps) | Should -Be 4096
            (Invoke-TestNamingFormExpression $bindings.fslogixStorageService $steps) | Should -Be 'AzureFiles'
            (Invoke-TestNamingFormExpression $bindings.fslogixProfileStorageTier $steps) | Should -Be 'Premium'
            (Invoke-TestNamingFormExpression $bindings.fslogixNetAppServiceLevel $steps) | Should -Be 'Premium'
            $controls.profileStorageBillingModel = 'Legacy'
            (Invoke-TestNamingFormExpression $bindings.fslogixProfileProvisionedIops $steps) | Should -Be 0
            $controls.officeProvisionedIops = '3000'
            (Invoke-TestNamingFormExpression $bindings.fslogixOfficeProvisionedIops $steps) | Should -Be 0
            $controls.profileStorageBillingModel = 'ProvisionedV2'
            $controls.officeStorageBillingModel = 'ProvisionedV2'
            switch ($Kind) {
                'Standard' { $steps.userProfiles.storageService = 'AzureNetAppFiles' }
                'Automated' { $controls.service = 'AzureNetAppFiles' }
                default { $controls.storageService = 'AzureNetAppFiles' }
            }
            (Invoke-TestNamingFormExpression $bindings.fslogixProfileProvisionedIops $steps) | Should -Be 0
            (Invoke-TestNamingFormExpression $bindings.fslogixOfficeProvisionedIops $steps) | Should -Be 0
            (Invoke-TestNamingFormExpression $bindings.fslogixProfileStorageBillingModel $steps) | Should -Be 'Legacy'
            (Invoke-TestNamingFormExpression $bindings.fslogixOfficeStorageBillingModel $steps) | Should -Be 'Inherit'
            (Invoke-TestNamingFormExpression $bindings.fslogixStorageService $steps) | Should -Be 'AzureNetAppFiles'
            (Invoke-TestNamingFormExpression $bindings.fslogixNetAppServiceLevel $steps) | Should -Be 'Standard'
            (Invoke-TestNamingFormExpression $bindings.fslogixProfileStorageTier $steps) | Should -Be $LegacyTier
        }

        It 'keeps dropdown labels, expression delimiters and internal control references valid' {
            foreach ($element in $elements | Where-Object { $_.name -match 'BillingModel|Provisioned' -and $_.type -eq 'Microsoft.Common.DropDown' }) {
                $element.defaultValue | Should -BeIn $element.constraints.allowedValues.label
            }
            $formText = $form | ConvertTo-Json -Depth 100
            $expressions = [regex]::Matches($formText, '"(?:[^"\\]|\\.)*"') | ForEach-Object {
                $_.Value | ConvertFrom-Json
            } | Where-Object { $_ -is [string] -and $_.StartsWith('[') -and $_ -match 'BillingModel|Provisioned|ProfileStorage' }
            foreach ($expression in $expressions) {
                $expression | Should -Match '\]$'
                $stripped = [regex]::Replace($expression, "'(?:''|[^'])*'", '')
                ($stripped.ToCharArray() | Where-Object { $_ -eq '(' }).Count |
                    Should -Be ($stripped.ToCharArray() | Where-Object { $_ -eq ')' }).Count
            }
            foreach ($match in [regex]::Matches(($bindings | ConvertTo-Json), "steps\('([^']+)'\)((?:\.[A-Za-z][A-Za-z0-9]*)+)")) {
                $node = $form.view.properties.steps | Where-Object name -EQ $match.Groups[1].Value
                foreach ($part in $match.Groups[2].Value.TrimStart('.').Split('.')) {
                    if ($node.type -eq 'Microsoft.Solutions.ArmApiControl') { break }
                    $next = $node.elements | Where-Object name -EQ $part
                    if (-not $next) {
                        if (-not $node.type -or $node.type -eq 'Microsoft.Common.Section') {
                            throw "Missing form control $part in $($match.Value)"
                        }
                        break
                    }
                    $node = $next
                }
                $node | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'evaluates canonical empty and ordered local/remote Profile arrays' {
        foreach ($case in @(
            @{ Kind = 'Standard'; Entry = 'deployments\hostpools\hostpool.bicep' }
            @{ Kind = 'Automated'; Entry = 'deployments\automatedHostPools\automatedHostPool.bicep' }
        )) {
            $text = Get-Content (Join-Path $repoRoot $case.Entry) -Raw
            $overrides = @{
                fslogixExistingLocalProfileStorageAccountResourceIds = @('old-local')
                fslogixExistingRemoteProfileStorageAccountResourceIds = @('old-remote')
            }
            $legacy = Invoke-ProducerExpressions $text $case.Kind $overrides
            @($legacy.local.value) | Should -Be @('old-local')
            @($legacy.remote.value) | Should -Be @('old-remote')

            $overrides.fslogixExistingLocalProfileStorageAccountResourceIds = @()
            $overrides.fslogixExistingRemoteProfileStorageAccountResourceIds = @('new-remote-1', 'new-remote-2')
            $preferred = Invoke-ProducerExpressions $text $case.Kind $overrides
            @($preferred.local.value).Count | Should -Be 0
            @($preferred.remote.value) | Should -Be @('new-remote-1', 'new-remote-2')

            $overrides.fslogixExistingLocalProfileStorageAccountResourceIds = @('new-local-1', 'new-local-2')
            $overrides.fslogixExistingRemoteProfileStorageAccountResourceIds = @()
            $result = Invoke-ProducerExpressions $text $case.Kind $overrides
            $result.local.value | Should -Be @('new-local-1', 'new-local-2')
            @($result.remote.value).Count | Should -Be 0
            $text | Should -Not -Match '(?m)^\s+(?:local|remote)StorageAccountResourceIds: fslogixExisting(?:Local|Remote)StorageAccountResourceIds$'
        }
    }

    It 'evaluates generated add-on naming for an empty Profile prefix' {
        $text = Get-Content (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\main.bicep') -Raw
        $result = Invoke-ProducerExpressions $text 'Addon' @{
            fslogixProfileStorageAccountNamePrefix = ''
        } -UseProductionNaming
        $result.prefix.value | Should -Be $result.namingPrefix.value
        $result.prefix.value | Should -Not -Be 'oldprefix'
        $result.prefix.value | Should -Match '^fslpc'
    }

    It 'wires resolved standard-host existing IDs and deployed prefix into persisted lifecycle tags' {
        $text = (Get-Content (Join-Path $repoRoot 'deployments\hostpools\hostpool.bicep') -Raw).Replace("`r`n", "`n")
        $local = [regex]::Match($text, '(?m)^var fslLocalProfileStorageAccountNames\b[^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)*').Value
        $remote = [regex]::Match($text, '(?m)^var fslRemoteProfileStorageAccountNames\b[^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)*').Value
        $local | Should -Match '\$\{effectiveFslogixProfileStorageAccountNamePrefix\}\$\{padLeft\(i \+ fslogixStorageIndex'
        $local | Should -Match 'fslLocalProfileStorageAccountNames: string\(map\(\s+effectiveFslogixExistingLocalProfileStorageAccountResourceIds,\s+id => last\(split\(id, ''/''\)\)'
        $remote | Should -Match 'fslRemoteProfileStorageAccountNames: string\(map\(\s+effectiveFslogixExistingRemoteProfileStorageAccountResourceIds,\s+id => last\(split\(id, ''/''\)\)'
        $local | Should -Not -Match 'naming\.fslogixProfileStorageAccountNamePrefix|\bfslogixExistingLocalStorageAccountResourceIds\b'
        $remote | Should -Not -Match '\bfslogixExistingRemoteStorageAccountResourceIds\b'
        $text | Should -Match '(?m)^var hasAssociatedFslStorage = deployFSLogixStorage \|\| !empty\(effectiveFslogixExistingLocalProfileStorageAccountResourceIds\)'
        $text | Should -Match '(?ms)^var fslogixConfigurationTags = hasAssociatedFslStorage\s+\? union\(.*?\bfslLocalProfileStorageAccountNames,\s+fslRemoteProfileStorageAccountNames,'
        $resourceGroup = Get-ProducerSourceBlock $text 'module' 'hostsResourceGroup'
        $resourceGroup | Should -Match 'tags: union\([^\r\n]*\bfslogixConfigurationTags\b'
    }

    It 'persists both resolved automated-policy Profile arrays as lifecycle tags and policy parameters' {
        $text = (Get-Content (Join-Path $repoRoot 'deployments\automatedHostPools\policy\main.bicep') -Raw).Replace("`r`n", "`n")
        foreach ($role in @('Local', 'Remote')) {
            $property = $role.Substring(0, 1).ToLowerInvariant() + $role.Substring(1) + 'ProfileStorageAccountResourceIds'
            $text | Should -Match ('(?m)^\s+fsl' + $role + 'ProfileStorageAccountNames: string\(map\(fslogixConfiguration\.' + $property + ', id => last\(split\(id, ''/''\)\)\)\)$')
            $text | Should -Match ('(?m)^\s+value: fslogixConfiguration\.' + $property + '$')
        }
        $text | Should -Match '(?ms)^var resourceGroupTags = union\(.*?\}, fslogixStorageAccountTags\)'
        $tags = Get-ProducerSourceBlock $text 'module' 'sessionHostResourceGroupTags'
        $tags | Should -Match 'tags: union\(existingSessionHostResourceGroup\.tags \?\? \{\}, resourceGroupTags\)'
    }

    It 'places standard-host Office controls in the Azure Files section they are exported from' {
        $form = Get-Content (Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $step = $form.view.properties.steps | Where-Object name -EQ 'userProfiles'
        $files = $step.elements | Where-Object name -EQ 'azureFiles'
        $netApp = $step.elements | Where-Object name -EQ 'azureNetAppFiles'
        $files.elements.name | Should -Contain 'officeStorageTier'
        $files.elements.name | Should -Contain 'officeShareSizeInGB'
        $netApp.elements.name | Should -Not -Contain 'officeStorageTier'
        ($files.elements | Where-Object name -EQ 'storageSku').defaultValue | Should -Be 'Premium'
    }

    It 'hides the standard-host shard count without removing its internal validation references' {
        $form = Get-Content (Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $step = $form.view.properties.steps | Where-Object name -EQ 'userProfiles'
        $files = $step.elements | Where-Object name -EQ 'azureFiles'
        $count = $files.elements | Where-Object name -EQ 'storageCount'
        $count.type | Should -Be 'Microsoft.Common.Slider'
        $count.visible | Should -BeFalse
        $count.min | Should -Be $count.max
        $count.min | Should -Match 'userGroupPickerBlade\.transformed\.groups'
        ($files.elements | Where-Object name -EQ 'storageIndex').max | Should -Match '\.storageCount'
        $text = $files.elements | ConvertTo-Json -Depth 100
        $text | Should -Match 'existingLocalStorageAccounts.*?storageCount'
        $text | Should -Match 'existingRemoteStorageAccounts.*?storageCount'
        ($form.view.outputs.parameters | ConvertTo-Json -Depth 100) | Should -Not -Match '\.storageCount'
        foreach ($name in @('entraIdTexBlock', 'noShardingTexBlock')) {
            $guidance = ($files.elements | Where-Object name -EQ $name).options.text
            $guidance | Should -Match 'one Profile'
            $guidance | Should -Match 'separate Office account: two accounts in total'
        }
    }

    It 'discovers all v2 LRS/ZRS SKUs without using legacy inventory as v2 fallback' {
        $form = Get-Content (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $scope = $form.view.properties.steps | Where-Object name -EQ 'scope'
        $transforms = ($scope.elements | Where-Object name -EQ 'storageSkusApi').request.transforms
        foreach ($tier in @('standard', 'premium')) {
            foreach ($redundancy in @('Lrs', 'Zrs')) {
                $expression = $transforms.("${tier}V2$redundancy")
                $expression | Should -Match "${tier}V2_$($redundancy.ToUpperInvariant())"
                $expression | Should -Match "kind == 'FileStorage'"
                $expression | Should -Match 'restrictions'
            }
        }
        $storage = $form.view.properties.steps | Where-Object name -EQ 'storage'
        $redundancy = $storage.elements | Where-Object name -EQ 'storageRedundancy'
        $redundancy.defaultValue | Should -Match "profileStorageBillingModel, 'ProvisionedV2'"
        $redundancy.constraints.allowedValues | Should -Match 'premiumV2Zrs'
        $validation = $storage.elements | Where-Object name -EQ 'provisionedV2SkuValidation'
        $validation.constraints.validations.Count | Should -Be 2
        foreach ($rule in $validation.constraints.validations) {
            $rule.isValid | Should -Match 'V2Lrs'
            $rule.isValid | Should -Match 'V2Zrs'
            $rule.isValid | Should -Not -Match 'transformed\.(premium|standard)Zrs'
        }
        ($storage.elements | Where-Object name -EQ 'storageService').defaultValue | Should -Be 'Azure Files'
        $media = $storage.elements | Where-Object name -EQ 'profileStorageTier'
        $media.defaultValue | Should -Be 'Premium SSD'
        $media.defaultValue | Should -BeIn $media.constraints.allowedValues.label
        $level = $storage.elements | Where-Object name -EQ 'netAppServiceLevel'
        $level.defaultValue | Should -Be 'Premium'
        $level.defaultValue | Should -BeIn $level.constraints.allowedValues.label
    }
}
