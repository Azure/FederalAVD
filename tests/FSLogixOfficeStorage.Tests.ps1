BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
}

Describe 'Evaluated Azure Files role configuration' {
    BeforeAll {
        $testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-OfficeStorage-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testDirectory -ErrorAction Stop | Out-Null
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\azureFiles.bicep') -Raw
        $match = [regex]::Match($source, '(?ms)^var fileShares = .*?(?=^// Network ACLs)')
        if (-not $match.Success) { throw 'Production role/account expressions were not found.' }
        $roleExpressions = $match.Value
        $configurationModule = Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\configuration.bicep'
        $relativeConfigurationModule = [IO.Path]::GetRelativePath($testDirectory, $configurationModule).Replace('\', '/')

        function Invoke-OfficeAccountConfiguration {
            param([hashtable]$Overrides = @{})
            $inputs = [ordered]@{
                profileStorageAccountNamePrefix = 'pcfixture'
                officeStorageAccountNamePrefix = 'ocfixture'
                fslogixProfileEncryptionKeyNameConv = 'pc-key-##'
                officeEncryptionKeyNameConv = 'oc-key-##'
                keyManagementStorageAccounts = 'CustomerManaged'
                profileStorageTier = 'Premium'
                officeStorageTier = 'Premium'
                profileStorageRedundancy = 'LocallyRedundant'
                officeStorageRedundancy = 'LocallyRedundant'
                profileShareSizeInGB = 1024
                officeShareSizeInGB = 1024
                storageCount = 2
                storageIndex = 3
                containerType = 'ProfileOfficeContainer'
                profileStorageBillingModel = 'Legacy'
                officeStorageBillingModel = 'Legacy'
                profileProvisionedIops = 0
                profileProvisionedThroughputMiBps = 0
                officeProvisionedIops = 0
                officeProvisionedThroughputMiBps = 0
            }
            foreach ($key in $Overrides.Keys) { $inputs[$key] = $Overrides[$key] }
            $lines = @("targetScope = 'local'", "import { resolveFilesConfiguration, fslogixShareNames } from '$relativeConfigurationModule'")
            foreach ($entry in $inputs.GetEnumerator()) {
                if ($entry.Value -is [array]) {
                    $literal = '[' + (($entry.Value | ForEach-Object { "'$_'" }) -join ', ') + ']'
                }
                elseif ($entry.Value -is [int]) { $literal = [string]$entry.Value }
                else { $literal = "'$($entry.Value)'" }
                $lines += "var $($entry.Key) = $literal"
            }
            $lines += $roleExpressions
            $lines += 'output encodedResults string = base64(string({ accounts: accountConfigurations }))'
            $fixture = Join-Path $testDirectory 'accounts.bicep'
            [IO.File]::WriteAllLines($fixture, $lines)
            (Invoke-TestNamingVectors -TemplateFile $fixture).accounts.value
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $testDirectory) {
            Remove-Item -LiteralPath $testDirectory -Recurse -Force -ErrorAction Stop
        }
    }

    It 'creates two paired roles in Profile-then-Office shard order' {
        $accounts = @(Invoke-OfficeAccountConfiguration)
        $accounts.Count | Should -Be 4
        $accounts.name | Should -Be @('pcfixture03', 'pcfixture04', 'ocfixture03', 'ocfixture04')
        $accounts.keyName | Should -Be @('pc-key-03', 'pc-key-04', 'oc-key-03', 'oc-key-04')
        $accounts.roleName | Should -Be @('Profile', 'Profile', 'Office', 'Office')
        foreach ($account in $accounts) {
            $account.PSObject.Properties.Name | Should -Not -Contain 'containerName'
            $account.PSObject.Properties.Name | Should -Not -Contain 'commandPrefix'
        }
        foreach ($account in $accounts[0..1]) { $account.shares | Should -Be @('profile-containers') }
        foreach ($account in $accounts[2..3]) { $account.shares | Should -Be @('office-containers') }
    }

    It 'preserves Profile-only account count and names' {
        $accounts = @(Invoke-OfficeAccountConfiguration @{ containerType = 'ProfileContainer' })
        $accounts.Count | Should -Be 2
        $accounts.name | Should -Be @('pcfixture03', 'pcfixture04')
    }

    It 'uses independent Office redundancy, legacy tier and quota' {
        $accounts = @(Invoke-OfficeAccountConfiguration @{
            officeStorageTier = 'Standard'
            officeStorageRedundancy = 'ZoneRedundant'
            officeShareSizeInGB = 4096
        })
        $accounts[0].configuration.skuName | Should -Be 'Premium_LRS'
        $accounts[0].shareSizeInGB | Should -Be 1024
        $accounts[2].configuration.skuName | Should -Be 'Standard_ZRS'
        $accounts[2].shareSizeInGB | Should -Be 4096
    }

    It 'resolves <Tier> <Redundancy> v2 with independent Office sizing' -TestCases @(
        @{ Tier = 'Standard'; Redundancy = 'LocallyRedundant'; Sku = 'StandardV2_LRS'; Iops = 1205; Throughput = 81 }
        @{ Tier = 'Standard'; Redundancy = 'ZoneRedundant'; Sku = 'StandardV2_ZRS'; Iops = 1205; Throughput = 81 }
        @{ Tier = 'Premium'; Redundancy = 'LocallyRedundant'; Sku = 'PremiumV2_LRS'; Iops = 4024; Throughput = 203 }
        @{ Tier = 'Premium'; Redundancy = 'ZoneRedundant'; Sku = 'PremiumV2_ZRS'; Iops = 4024; Throughput = 203 }
    ) {
        param($Tier, $Redundancy, $Sku, $Iops, $Throughput)
        $accounts = @(Invoke-OfficeAccountConfiguration @{
            profileStorageTier = $Tier
            profileStorageRedundancy = $Redundancy
            profileStorageBillingModel = 'ProvisionedV2'
            officeStorageBillingModel = 'ProvisionedV2'
            officeShareSizeInGB = 2048
        })
        $accounts[0].configuration.kind | Should -Be 'FileStorage'
        $accounts[0].configuration.skuName | Should -Be $Sku
        $accounts[0].configuration.provisionedIops | Should -Be $Iops
        $accounts[0].configuration.provisionedThroughputMiBps | Should -Be $Throughput
        $accounts[0].configuration.accessTier | Should -Be ''
        $accounts[0].configuration.largeFileSharesState | Should -Be ''
        $accounts[2].configuration.provisionedIops | Should -Be 5048
        $accounts[2].configuration.provisionedThroughputMiBps | Should -Be 305
        $accounts.name | Should -Be @('pcfixture03', 'pcfixture04', 'ocfixture03', 'ocfixture04')
    }

    It 'keeps billing and explicit performance independent between roles' {
        $accounts = @(Invoke-OfficeAccountConfiguration @{
            profileStorageBillingModel = 'ProvisionedV2'
            profileProvisionedIops = 10000
            profileProvisionedThroughputMiBps = 500
            officeStorageTier = 'Standard'
        })
        $accounts[0].configuration.provisionedIops | Should -Be 10000
        $accounts[0].configuration.provisionedThroughputMiBps | Should -Be 500
        $accounts[2].configuration.skuName | Should -Be 'Standard_LRS'
        $accounts[2].configuration.provisionedIops | Should -Be 0
    }

    It 'rejects invalid v2 <Case>' -TestCases @(
        @{ Case = 'capacity below minimum'; Overrides = @{ profileStorageBillingModel = 'ProvisionedV2'; profileShareSizeInGB = 31 } }
        @{ Case = 'capacity above maximum'; Overrides = @{ profileStorageBillingModel = 'ProvisionedV2'; profileShareSizeInGB = 262145 } }
        @{ Case = 'SSD IOPS below minimum'; Overrides = @{ profileStorageBillingModel = 'ProvisionedV2'; profileProvisionedIops = 2999 } }
        @{ Case = 'SSD IOPS above maximum'; Overrides = @{ profileStorageBillingModel = 'ProvisionedV2'; profileProvisionedIops = 102401 } }
        @{ Case = 'SSD throughput below minimum'; Overrides = @{ profileStorageBillingModel = 'ProvisionedV2'; profileProvisionedThroughputMiBps = 99 } }
        @{ Case = 'HDD IOPS below minimum'; Overrides = @{ officeStorageBillingModel = 'ProvisionedV2'; officeStorageTier = 'Standard'; officeProvisionedIops = 499 } }
        @{ Case = 'HDD IOPS above maximum'; Overrides = @{ officeStorageBillingModel = 'ProvisionedV2'; officeStorageTier = 'Standard'; officeProvisionedIops = 50001 } }
        @{ Case = 'HDD throughput above maximum'; Overrides = @{ officeStorageBillingModel = 'ProvisionedV2'; officeStorageTier = 'Standard'; officeProvisionedThroughputMiBps = 5121 } }
        @{ Case = 'negative performance'; Overrides = @{ profileStorageBillingModel = 'ProvisionedV2'; profileProvisionedIops = -1 } }
    ) {
        param($Case, $Overrides)
        { Invoke-OfficeAccountConfiguration $Overrides } | Should -Throw '*Invalid provisioned-v2*'
    }

    It 'rejects performance tuning with legacy billing' {
        { Invoke-OfficeAccountConfiguration @{ profileProvisionedIops = 5000 } } | Should -Throw '*ProvisionedV2*'
    }

    It 'accepts v2 capacity boundaries and clamps automatic recommendations' {
        $small = @(Invoke-OfficeAccountConfiguration @{ profileStorageBillingModel = 'ProvisionedV2'; profileShareSizeInGB = 32 })
        $small[0].configuration.provisionedIops | Should -Be 3032
        $small[0].configuration.provisionedThroughputMiBps | Should -Be 104
        $large = @(Invoke-OfficeAccountConfiguration @{ profileStorageBillingModel = 'ProvisionedV2'; profileShareSizeInGB = 262144 })
        $large[0].configuration.provisionedIops | Should -Be 102400
        $large[0].configuration.provisionedThroughputMiBps | Should -Be 10340
    }

    It 'accepts explicit performance boundaries and caps HDD recommendations' {
        $fixture = Join-Path $testDirectory 'boundaries.bicep'
        [IO.File]::WriteAllLines($fixture, @(
            "targetScope = 'local'"
            "import { resolveFilesConfiguration } from '$relativeConfigurationModule'"
            "var results = {"
            "  minSsd: resolveFilesConfiguration('Premium', 'LocallyRedundant', 'ProvisionedV2', 32, 3000, 100)"
            "  maxSsd: resolveFilesConfiguration('Premium', 'ZoneRedundant', 'ProvisionedV2', 262144, 102400, 10340)"
            "  minHdd: resolveFilesConfiguration('Standard', 'LocallyRedundant', 'ProvisionedV2', 32, 500, 60)"
            "  maxHdd: resolveFilesConfiguration('Standard', 'ZoneRedundant', 'ProvisionedV2', 262144, 50000, 5120)"
            "  autoHdd: resolveFilesConfiguration('Standard', 'LocallyRedundant', 'ProvisionedV2', 262144, 0, 0)"
            "}"
            'output encodedResults string = base64(string({ boundaries: results }))'
        ))
        $results = (Invoke-TestNamingVectors -TemplateFile $fixture).boundaries.value
        $results.minSsd.provisionedIops | Should -Be 3000
        $results.minSsd.provisionedThroughputMiBps | Should -Be 100
        $results.maxSsd.provisionedIops | Should -Be 102400
        $results.maxSsd.provisionedThroughputMiBps | Should -Be 10340
        $results.minHdd.provisionedIops | Should -Be 500
        $results.minHdd.provisionedThroughputMiBps | Should -Be 60
        foreach ($name in @('maxHdd', 'autoHdd')) {
            $results.$name.provisionedIops | Should -Be 50000
            $results.$name.provisionedThroughputMiBps | Should -Be 5120
        }
    }

    It 'rejects unsupported billing combinations and oversized legacy shares' {
        { Invoke-OfficeAccountConfiguration @{ profileStorageBillingModel = 'Unknown' } } | Should -Throw '*Unsupported Azure Files*'
        { Invoke-OfficeAccountConfiguration @{ profileShareSizeInGB = 102401 } } | Should -Throw '*Legacy Azure Files*'
    }

    It 'rejects equal role <Setting> including case differences' -TestCases @(
        @{ Setting = 'prefixes'; Overrides = @{ officeStorageAccountNamePrefix = 'PCFIXTURE' } }
        @{ Setting = 'CMK patterns'; Overrides = @{ officeEncryptionKeyNameConv = 'PC-KEY-##' } }
    ) {
        param($Setting, $Overrides)
        { Invoke-OfficeAccountConfiguration $Overrides } | Should -Throw '*must*'
    }
}

Describe 'Evaluated lifecycle Office pairing validation' {
    BeforeAll {
        $pairTestDirectory = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-OfficePairing-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $pairTestDirectory -ErrorAction Stop | Out-Null
        $module = Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\fslogix.bicep'
        $relativeModule = [IO.Path]::GetRelativePath($pairTestDirectory, $module).Replace('\', '/')
        function Invoke-OfficePairing {
            param([string]$InputExpression)
            $fixture = Join-Path $pairTestDirectory 'pairing.bicep'
            [IO.File]::WriteAllLines($fixture, @(
                "targetScope = 'local'"
                "import { validateOfficeStorageAccounts } from '$relativeModule'"
                "var pairs = validateOfficeStorageAccounts($InputExpression)"
                'output encodedResults string = base64(string({ pairs: pairs }))'
            ))
            (Invoke-TestNamingVectors -TemplateFile $fixture).pairs.value
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $pairTestDirectory) {
            Remove-Item -LiteralPath $pairTestDirectory -Recurse -Force -ErrorAction Stop
        }
    }

    It 'preserves paired input order and permits an empty Profile-only Office mapping' {
        $pairs = Invoke-OfficePairing "['pc02','pc01'], ['rp02','rp01'], ['oc02','oc01'], ['ro02','ro01'], true, ['g2','g1']"
        $pairs.local | Should -Be @('oc02', 'oc01')
        $pairs.remote | Should -Be @('ro02', 'ro01')
        $disabled = Invoke-OfficePairing "['pc01'], [], [], [], false, []"
        @($disabled.local).Count | Should -Be 0
    }

    It 'fails before deployment for <Case>' -TestCases @(
        @{ Case = 'missing Office accounts'; Input = "['pc01'], [], [], [], true, []" }
        @{ Case = 'case-insensitive overlap'; Input = "['pc01'], [], ['PC01'], [], true, []" }
        @{ Case = 'duplicate Office shards'; Input = "['pc01','pc02'], [], ['oc01','oc01'], [], true, []" }
        @{ Case = 'case-insensitive Office reuse across locations'; Input = "['pc01'], ['rp01'], ['oc01'], ['OC01'], true, []" }
        @{ Case = 'incomplete remote shards'; Input = "['pc01','pc02'], ['rp01'], ['oc01','oc02'], ['ro01'], true, []" }
        @{ Case = 'wrong shard-group count'; Input = "['pc01','pc02'], [], ['oc01','oc02'], [], true, ['g1']" }
        @{ Case = 'Office disabled'; Input = "['pc01'], [], ['oc01'], [], false, []" }
    ) {
        param($Case, $Input)
        { Invoke-OfficePairing $Input } | Should -Throw '*Office*'
    }
}

Describe 'Lifecycle Office parameter bindings' {
    It 'preserves explicit paired Office order and clears hidden mappings in <Consumer>' -TestCases @(
        @{ Consumer = 'sessionHosts' }
        @{ Consumer = 'sessionHostReplacer' }
    ) {
        param($Consumer)
        $directory = Join-Path $repoRoot "deployments\add-ons\$Consumer"
        $form = Get-Content (Join-Path $directory 'uiFormDefinition.json') -Raw | ConvertFrom-Json
        $template = Get-Content (Join-Path $directory 'main.json') -Raw | ConvertFrom-Json -Depth 100
        $profiles = [pscustomobject]@{
            configureSessionHosts = $true
            storageService = 'AzureFiles'
            fslogixContainerType = 'CloudCacheProfileOfficeContainer'
            azureFiles = [pscustomobject]@{
                existingLocalOfficeStorageAccounts = @('office-shard2', 'office-shard1')
                existingRemoteOfficeStorageAccounts = @('remote-office2', 'remote-office1')
            }
        }
        foreach ($location in @('Local', 'Remote')) {
            $name = "fslogix${location}OfficeStorageAccountResourceIds"
            $template.parameters.$name.type | Should -Be 'array'
            $expression = $form.view.outputs.parameters.$name
            $expression | Should -Match "existing${location}OfficeStorageAccounts"
            $expected = $profiles.azureFiles."existing${location}OfficeStorageAccounts"
            @(Invoke-TestNamingFormExpression -Expression $expression -Steps @{ userProfiles = $profiles }) | Should -Be $expected
        }
        $profiles.configureSessionHosts = $false
        foreach ($location in @('Local', 'Remote')) {
            $expression = $form.view.outputs.parameters."fslogix${location}OfficeStorageAccountResourceIds"
            @(Invoke-TestNamingFormExpression -Expression $expression -Steps @{ userProfiles = $profiles } |
                Where-Object { $null -ne $_ }).Count | Should -Be 0
        }
    }
}

Describe 'Lifecycle ordered account defaults' {
    BeforeAll {
        $defaultTestDirectory = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-OfficeDefaults-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $defaultTestDirectory -ErrorAction Stop | Out-Null
    }
    AfterAll {
        if (Test-Path -LiteralPath $defaultTestDirectory) {
            Remove-Item -LiteralPath $defaultTestDirectory -Recurse -Force -ErrorAction Stop
        }
    }

    It 'keeps saved shard order when discovery returns a different order in <Consumer>' -TestCases @(
        @{ Consumer = 'sessionHosts' }
        @{ Consumer = 'sessionHostReplacer' }
    ) {
        param($Consumer)
        $form = Get-Content (Join-Path $repoRoot "deployments\add-ons\$Consumer\uiFormDefinition.json") -Raw | ConvertFrom-Json
        $elements = @($form.view.properties.steps | ForEach-Object { Get-TestFormElement $_.elements })
        $fields = @('existingLocalStorageAccounts', 'existingLocalOfficeStorageAccounts', 'existingRemoteStorageAccounts', 'existingRemoteOfficeStorageAccounts')
        $expressions = @($fields | ForEach-Object { $name = $_; ($elements | Where-Object name -eq $name).defaultValue })
        $expected = @(@('fslpc02','fslpc01'), @('fsloc02','fsloc01'), @('fslpc12','fslpc11'), @('fsloc12','fsloc11'))
        $tagNames = @('fslLocalProfileStorageAccountNames','fslLocalOfficeStorageAccountNames','fslRemoteProfileStorageAccountNames','fslRemoteOfficeStorageAccountNames')
        $tags = @{}
        for ($i = 0; $i -lt $tagNames.Count; $i++) { $tags[$tagNames[$i]] = ConvertTo-Json -InputObject $expected[$i] -Compress }
        $list = @($expected | ForEach-Object { $_ } | Sort-Object | ForEach-Object { @{ name = $_ } })
        $state = @{ basics = @{ hostsRGProps = @{ tags = $tags } }; userProfiles = @{ azureFiles = @{ storageAccountsApi = @{ transformed = @{ list = $list } } } } }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $state -Depth 20 -Compress)))
        $lines = @("targetScope = 'local'", "var state = json(base64ToString('$encoded'))")
        # Evaluate the actual loaded-data projection using the corresponding Bicep collection functions.
        for ($i = 0; $i -lt $expressions.Count; $i++) {
            $start = $expressions[$i].IndexOf(', filter(')
            $end = $expressions[$i].LastIndexOf(", parse('[]'))]")
            if ($start -lt 0 -or $end -le $start) { throw 'An ordered tag-default projection was not found.' }
            $projection = $expressions[$i].Substring($start + 2, $end - $start - 2).
                Replace("steps('basics')", 'state.basics').
                Replace("steps('userProfiles')", 'state.userProfiles').
                Replace('parse(', 'json(')
            $lines += "var actual$i = $projection"
        }
        $lines += 'output encodedResults string = base64(string({ defaults: [actual0, actual1, actual2, actual3] }))'
        $fixture = Join-Path $defaultTestDirectory 'ordered-defaults.bicep'
        [IO.File]::WriteAllLines($fixture, $lines)
        $actual = (Invoke-TestNamingVectors -TemplateFile $fixture).defaults.value
        $actual.Count | Should -Be 4
        for ($i = 0; $i -lt $expected.Count; $i++) { $actual[$i] | Should -Be $expected[$i] }
    }
}

Describe 'Executable standard initializer Office routing' {
    BeforeAll {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\scripts\Initialize-SessionHost.ps1') -Raw
        $start = $source.IndexOf('# Create Array Lists for storage paths')
        $end = $source.IndexOf('# FSLogix Redirections for Teams and Az CLI', $start)
        $credentialStart = $source.IndexOf("if (`$StorageService -eq 'AzureFiles') {", $end)
        $credentialEnd = $source.IndexOf('# Microsoft Defender Antivirus Local Group Policy exclusions for FSLogix', $credentialStart)
        if ($start -lt 0 -or $end -le $start -or $credentialStart -lt 0 -or $credentialEnd -le $credentialStart) {
            throw 'Production routing/credential boundaries were not found.'
        }
        $routing = [scriptblock]::Create($source.Substring($start, $end - $start))
        $credentials = [scriptblock]::Create($source.Substring($credentialStart, $credentialEnd - $credentialStart))

        $tokens = $null
        $parseErrors = $null
        $initializerAst = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
        $jsonParser = $initializerAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertFrom-JsonString'
        }, $true)
        if ($null -eq $jsonParser) { throw 'Production JSON parser was not found.' }
        . ([scriptblock]::Create($jsonParser.Extent.Text))
        $containerAssignments = @($initializerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -in @('$CloudCacheBool', '$ProfileShareName', '$OfficeShareName')
        }, $true))
        if ($containerAssignments.Count -ne 3) { throw 'Production container-type configuration was not found.' }
        $containerConfiguration = [scriptblock]::Create(($containerAssignments.Extent.Text -join "`n"))

        function Write-Log { param($Message) }
        function Get-CimInstance { param($ClassName) [pscustomobject]@{ Domain = 'example.test' } }
        function Convert-GroupToSID { param($DomainName, $GroupName) "SID-$GroupName" }
        function Set-StorageAccountCredential {
            param($TargetName, $UserName, $Password)
            $script:capturedCredentials.Add([pscustomobject]@{ Target = $TargetName; User = $UserName; Password = $Password })
        }

        function Invoke-OfficeRouting {
            param([hashtable]$Overrides = @{}, [bool]$Office = $true, [bool]$CloudCache = $false)
            $inputs = @{
                StorageService = 'AzureFiles'
                IdentitySolution = 'ActiveDirectoryDomainServices'
                StorageSuffix = 'core.usgovcloudapi.net'
                OSSGroups = '[]'
                LocalProfileStorageAccountNames = '["pc01","pc02"]'
                LocalProfileStorageAccountKeys = '[]'
                RemoteProfileStorageAccountNames = '[]'
                RemoteProfileStorageAccountKeys = '[]'
                LocalOfficeStorageAccountNames = '["oc01","oc02"]'
                LocalOfficeStorageAccountKeys = '[]'
                RemoteOfficeStorageAccountNames = '[]'
                RemoteOfficeStorageAccountKeys = '[]'
                LocalNetAppServers = '["local-profile","local-office"]'
                RemoteNetAppServers = '["remote-profile","remote-office"]'
            }
            foreach ($key in $Overrides.Keys) { $inputs[$key] = $Overrides[$key] }
            foreach ($entry in $inputs.GetEnumerator()) { Set-Variable -Name $entry.Key -Value $entry.Value }
            $ContainerType = if ($Office) {
                if ($CloudCache) { 'CloudCacheProfileOfficeContainer' } else { 'ProfileOfficeContainer' }
            }
            else {
                if ($CloudCache) { 'CloudCacheProfileContainer' } else { 'ProfileContainer' }
            }
            . $containerConfiguration
            $SizeInMBsInt = 30720
            $OSSGroupsArray = @()
            $RegSettings = [Collections.Generic.List[object]]::new()
            $script:capturedCredentials = [Collections.Generic.List[object]]::new()
            . $routing
            . $credentials
            [pscustomobject]@{
                Settings = $RegSettings.ToArray()
                Credentials = $script:capturedCredentials.ToArray()
                LocalProfileNames = $LocalProfileStorageAccountNamesArray
                RemoteProfileNames = $RemoteProfileStorageAccountNamesArray
                LocalProfileKeys = $LocalProfileStorageAccountKeysArray
                RemoteProfileKeys = $RemoteProfileStorageAccountKeysArray
            }
        }
    }

    It 'emits no items for an empty array through the production JSON parser' {
        @(ConvertFrom-JsonString -JsonString '[]' -Name 'empty').Count | Should -Be 0
    }

    It 'routes local-only Entra Kerberos <Mode> with empty remote and key arrays' -TestCases @(
        @{ Mode = 'permission shards'; Groups = '[]'; LocationCount = 2 }
        @{ Mode = 'object-specific shards'; Groups = '["group1","group2"]'; LocationCount = 4 }
    ) {
        param($Mode, $Groups, $LocationCount)
        $result = Invoke-OfficeRouting -Overrides @{
            IdentitySolution = 'EntraKerberos-CloudOnly'
            OSSGroups = $Groups
        }
        $locations = @($result.Settings | Where-Object Name -eq 'VHDLocations')
        $locations.Count | Should -Be $LocationCount
        $locations[0].Value[0] | Should -Be '\\pc01.file.core.usgovcloudapi.net\profile-containers'
        $locations[1].Value[0] | Should -Be '\\oc01.file.core.usgovcloudapi.net\office-containers'
        $result.Credentials.Count | Should -Be 0
    }

    It 'routes VHDLocations to separate role accounts without credentials for AD DS' {
        $result = Invoke-OfficeRouting
        $locations = @($result.Settings | Where-Object Name -eq 'VHDLocations')
        $locations.Count | Should -Be 2
        $locations[0].Value | Should -Be @('\\pc01.file.core.usgovcloudapi.net\profile-containers', '\\pc02.file.core.usgovcloudapi.net\profile-containers')
        $locations[1].Value | Should -Be @('\\oc01.file.core.usgovcloudapi.net\office-containers', '\\oc02.file.core.usgovcloudapi.net\office-containers')
        $locations.PropertyType | Should -Be @('MultiString', 'MultiString')
        $result.Credentials.Count | Should -Be 0
    }

    It 'preserves local/remote Cloud Cache pairing for each OSS group' {
        $result = Invoke-OfficeRouting -CloudCache $true -Overrides @{
            OSSGroups = '["group1","group2"]'
            RemoteProfileStorageAccountNames = '["remote-pc01","remote-pc02"]'
            RemoteOfficeStorageAccountNames = '["remote-oc01","remote-oc02"]'
        }
        $locations = @($result.Settings | Where-Object Name -eq 'CCDLocations')
        $locations.Count | Should -Be 4
        $locations[1].Path | Should -Be 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC\ObjectSpecific\SID-group1'
        $locations[1].Value | Should -Be @(
            'type=smb,connectionString=\\oc01.file.core.usgovcloudapi.net\office-containers'
            'type=smb,connectionString=\\remote-oc01.file.core.usgovcloudapi.net\office-containers'
        )
        $locations[3].Value[0] | Should -Match '\\\\oc02\.'
    }

    It 'preserves remote ANF locations for <Mode>' -TestCases @(
        @{ Mode = 'VHD'; Cloud = $false; Name = 'VHDLocations' }
        @{ Mode = 'Cloud Cache'; Cloud = $true; Name = 'CCDLocations' }
    ) {
        param($Mode, $Cloud, $Name)
        $result = Invoke-OfficeRouting -CloudCache $Cloud -Overrides @{ StorageService = 'AzureNetAppFiles' }
        $locations = @($result.Settings | Where-Object Name -eq $Name)
        @($locations[0].Value).Count | Should -Be 2
        @($locations[1].Value).Count | Should -Be 2
        $locations[1].Value[1] | Should -Match 'remote-office'
    }

    It 'writes the exact keys for both roles at both locations' {
        $result = Invoke-OfficeRouting -Overrides @{
            LocalProfileStorageAccountKeys = '["pk1","pk2"]'
            LocalOfficeStorageAccountKeys = '["ok1","ok2"]'
            RemoteProfileStorageAccountNames = '["remote-pc01","remote-pc02"]'
            RemoteProfileStorageAccountKeys = '["rpk1","rpk2"]'
            RemoteOfficeStorageAccountNames = '["remote-oc01","remote-oc02"]'
            RemoteOfficeStorageAccountKeys = '["rok1","rok2"]'
        }
        $result.Credentials.Count | Should -Be 8
        $result.Credentials.Password | Should -Be @('pk1', 'pk2', 'ok1', 'ok2', 'rpk1', 'rpk2', 'rok1', 'rok2')
        $result.LocalProfileNames | Should -Be @('pc01', 'pc02')
        $result.RemoteProfileNames | Should -Be @('remote-pc01', 'remote-pc02')
        $result.LocalProfileKeys | Should -Be @('pk1', 'pk2')
        $result.RemoteProfileKeys | Should -Be @('rpk1', 'rpk2')
        $result.Credentials[2].User | Should -Be 'localhost\oc01'
    }

    It 'rejects <Case> rather than reusing Profile accounts or ignoring keys' -TestCases @(
        @{ Case = 'missing Office accounts'; Inputs = @{ LocalOfficeStorageAccountNames = '[]' }; Error = '*paired*' }
        @{ Case = 'cross-role overlap'; Inputs = @{ LocalOfficeStorageAccountNames = '["PC01","oc02"]' }; Error = '*different*' }
        @{ Case = 'missing remote Office accounts'; Inputs = @{ RemoteProfileStorageAccountNames = '["rp1","rp2"]' }; Error = '*paired*' }
        @{ Case = 'incomplete remote shard coverage'; Inputs = @{ RemoteProfileStorageAccountNames = '["rp1"]'; RemoteOfficeStorageAccountNames = '["ro1"]' }; Error = '*group counts*' }
        @{ Case = 'wrong OSS group count'; Inputs = @{ OSSGroups = '["only-one"]' }; Error = '*group counts*' }
        @{ Case = 'duplicate Office shards'; Inputs = @{ LocalOfficeStorageAccountNames = '["oc01","OC01"]' }; Error = '*distinct*' }
        @{ Case = 'wrong Office key count'; Inputs = @{ LocalOfficeStorageAccountKeys = '["key1"]' }; Error = '*key*collection*' }
        @{ Case = 'missing paired keys'; Inputs = @{ LocalProfileStorageAccountKeys = '["p1","p2"]' }; Error = '*key for each*' }
    ) {
        param($Case, $Inputs, $Error)
        { Invoke-OfficeRouting -Overrides $Inputs } | Should -Throw $Error
    }

    It 'preserves Profile-only routing and rejects Office inputs when disabled' {
        $result = Invoke-OfficeRouting -Office $false -Overrides @{ LocalOfficeStorageAccountNames = '[]' }
        @($result.Settings | Where-Object Name -eq 'VHDLocations').Count | Should -Be 1
        { Invoke-OfficeRouting -Office $false } | Should -Throw '*disabled*'
    }
}
