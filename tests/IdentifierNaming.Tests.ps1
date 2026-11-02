$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')

Describe 'Identifier-based shared resource naming' {
    BeforeAll {
        $testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-IdentifierNaming-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testDirectory -ErrorAction Stop | Out-Null
        $command = Get-Command bicep -ErrorAction SilentlyContinue
        if ($command) {
            $bicep = $command.Source
        }
        else {
            $configRoot = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.azure' }
            $binaryName = if ($env:OS -eq 'Windows_NT') { 'bicep.exe' } else { 'bicep' }
            $bicep = Join-Path (Join-Path $configRoot 'bin') $binaryName
        }
        if (-not (Test-Path -LiteralPath $bicep)) {
            throw 'Bicep CLI is required. Install it with az bicep install before running identifier naming tests.'
        }
        foreach ($relative in @(
            'deployments\shared\data\resourceAbbreviations.json'
            'deployments\shared\data\locations.json'
            'deployments\shared\modules\orchestration\naming\naming.bicep'
            'tests\fixtures\naming-types.bicep'
            'tests\fixtures\naming-types.bicepparam'
        )) {
            $destination = Join-Path $testDirectory $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $destination
        }
        [IO.File]::WriteAllText((Join-Path $testDirectory 'bicepconfig.json'), '{"experimentalFeaturesEnabled":{"localDeploy":true}}')
        $fixture = Join-Path $testDirectory 'tests\fixtures\naming-types.bicep'
        [IO.File]::WriteAllText($fixture, "targetScope = 'local'`n" + (Get-Content -LiteralPath $fixture -Raw))
        $raw = @(& $bicep local-deploy (Join-Path $testDirectory 'tests\fixtures\naming-types.bicepparam') --format Json 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Local Bicep naming evaluation failed: $($raw -join [Environment]::NewLine)" }
        $encoded = ($raw -join [Environment]::NewLine | ConvertFrom-Json).outputs.encodedResults
        # The CLI renderer wraps long strings; base64 preserves exact values through its console transport.
        $values = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
        $policy = Get-TestNamingPolicy
        $integrationPath = Join-Path $testDirectory 'integration.json'
        & $bicep build (Join-Path $repoRoot 'tests\fixtures\naming-function-app.bicep') --outfile $integrationPath
        if ($LASTEXITCODE -ne 0) { throw 'Function App naming/module integration did not compile.' }
        $integration = Get-Content -LiteralPath $integrationPath -Raw | ConvertFrom-Json
    }

    AfterAll {
        if (Test-Path -LiteralPath $testDirectory) {
            Remove-Item -LiteralPath $testDirectory -Recurse -Force -ErrorAction Stop
        }
    }

    It 'executes 504 runtime vectors including exact length boundaries for every type' {
        $values.cases.Count | Should Be 468
        $values.boundaries.Count | Should Be 36
        foreach ($case in $values.cases) {
            $limit = $policy.resourceTypes.($case.type).lengthLimit
            ($case.actual.Length -le $limit) | Should Be $true
            $expectedHashLength = if ($case.type -in @('keyVaults', 'functionApps', 'storageAccounts')) { 6 } else { 0 }
            $case.hash.Length | Should Be $expectedHashLength
            if ($expectedHashLength -gt 0) {
                $case.hash | Should Match '^[a-z0-9]+$'
                $case.actual.Contains($case.hash) | Should Be $true
            }
            else {
                $case.actual | Should Not Match '--'
                $case.actual | Should Not Match '-$'
            }
            $case.actual | Should Be $case.actual.ToLowerInvariant()
            if ($case.type -eq 'storageAccounts') {
                $case.actual | Should Match '^[a-z0-9]{3,24}$'
            }
            elseif ($case.type -eq 'computeGalleries') {
                $case.actual | Should Match '^[a-z0-9][a-z0-9._]*[a-z0-9]$'
            }
            else {
                $case.actual | Should Match '^[a-z0-9][a-z0-9-]*[a-z0-9]$'
            }
            if ($case.type -in @('keyVaults','automationAccounts','recoveryServicesVaults')) {
                $case.actual | Should Match '^[a-z]'
            }
            if ($case.type -eq 'keyVaults') { $case.actual | Should Not Match '--' }
        }
        foreach ($case in $values.boundaries) {
            $case.actual.Length | Should Be $policy.resourceTypes.($case.type).lengthLimit
            $case.actual | Should Match '^([a-z][a-z0-9_]*[-_]avd[-_]a+([-_][a-z0-9]+)?[-_]use|saavda+[a-z0-9]+use)$'
        }
    }

    It 'covers every convention abbreviation while leaving provider-required workbook GUIDs separate' {
        $abbreviations = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\data\resourceAbbreviations.json') -Raw | ConvertFrom-Json
        $expected = @($abbreviations.PSObject.Properties.Name | Where-Object { $_ -ne 'workbooks' } | Sort-Object)
        ($policy.resourceTypes.PSObject.Properties.Name | Sort-Object) -join ',' | Should Be ($expected -join ',')
    }

    It 'uses the complete readable default name for all 33 scope-local types' {
        $abbreviations = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\data\resourceAbbreviations.json') -Raw | ConvertFrom-Json
        $localCases = @($values.cases | Where-Object { $_.profile -eq 'default' -and $_.type -notin @('functionApps', 'storageAccounts', 'keyVaults') })
        $localCases.Count | Should Be 33
        foreach ($case in $localCases) {
            $expected = "$($abbreviations.($case.type))-avd-fin-use"
            if ($case.type -eq 'computeGalleries') { $expected = $expected.Replace('-', '_') }
            $case.actual | Should Be $expected
        }
    }

    It 'defines numeric resource limits and supported formats with bounded uniqueness lengths' {
        $policy.limits.defaultUniqueLength | Should Be 6
        $policy.limits.uniqueSuffix | Should Be 6
        foreach ($type in $policy.resourceTypes.PSObject.Properties) {
            $rule = $type.Value
            ($rule.lengthLimit -is [int] -or $rule.lengthLimit -is [long]) | Should Be $true
            ($rule.lengthLimit -gt 0) | Should Be $true
            ($rule.format -in @('hyphen', 'storage', 'gallery')) | Should Be $true
            if ($rule.globallyUnique) {
                $uniqueLength = if ($null -ne $rule.uniqueLength) { $rule.uniqueLength } else { $policy.limits.defaultUniqueLength }
                ($uniqueLength -is [int] -or $uniqueLength -is [long]) | Should Be $true
                ($uniqueLength -gt 0 -and $uniqueLength -le 13 -and $uniqueLength -lt $rule.lengthLimit) | Should Be $true
            }
            else {
                $rule.uniqueLength | Should BeNullOrEmpty
            }
        }
        $globalTypes = @($policy.resourceTypes.PSObject.Properties | Where-Object { $_.Value.globallyUnique } | ForEach-Object Name | Sort-Object)
        ($globalTypes -join ',') | Should Be 'functionApps,keyVaults,storageAccounts'
    }

    It 'registers the resource type for every typed role and supports each explicit role format' {
        foreach ($role in $policy.resources.PSObject.Properties) {
            if (-not [string]::IsNullOrEmpty($role.Value.type)) {
                $policy.resourceTypes.PSObject.Properties[$role.Value.type] | Should Not BeNullOrEmpty
            }
            if ($null -ne $role.Value.format) {
                $role.Value.format | Should Be 'storage'
            }
        }
    }

    It 'preserves endpoint boundaries and adapter-specific naming recipes' {
        foreach ($case in @($values.endpointTokens) + @($values.endpoints) + @($values.prefixes) + @($values.shortSeeds)) {
            $case.actual | Should Be $case.expected
        }
        $values.resourceGroups[0] | Should Be $values.resourceGroups[1]
    }

    It 'preserves static components and the complete identifier with one shared hash' {
        $app = $values.cases | Where-Object { $_.profile -eq 'default' -and $_.type -eq 'functionApps' }
        $storage = $values.cases | Where-Object { $_.profile -eq 'default' -and $_.type -eq 'storageAccounts' }
        $app.actual | Should Be "fa-avd-fin-$($app.hash)-use"
        $storage.actual | Should Be "saavdfin$($storage.hash)use"
        $app.hash | Should Be $storage.hash
        $expanded = $values.cases | Where-Object { $_.profile -eq 'expanded-workload' -and $_.type -eq 'storageAccounts' }
        $expanded.actual | Should Be "saavdxxfin$($expanded.hash)use"
    }

    It 'honors type-last conventions and partial abbreviation overrides' {
        ($values.cases | Where-Object { $_.profile -eq 'type-last' -and $_.type -eq 'storageAccounts' }).actual | Should Match 'usesa$'
        ($values.cases | Where-Object { $_.profile -eq 'type-last' -and $_.type -eq 'functionApps' }).actual | Should Match '-use-fa$'
        ($values.cases | Where-Object { $_.profile -eq 'partial-code' -and $_.type -eq 'functionApps' }).actual | Should Match '^func-avd-'
        ($values.cases | Where-Object { $_.profile -eq 'partial-code' -and $_.type -eq 'applicationInsights' }).actual | Should Match '^appi-avd-'
        ($values.cases | Where-Object { $_.profile -eq 'location-override' -and $_.type -eq 'functionApps' }).actual | Should Match '-e1$'
    }

    It 'returns the complete naming bundle and distinct CMK identity purpose' {
        ($values.bundle.PSObject.Properties.Name | Sort-Object) -join ',' |
            Should Be 'applicationInsightsName,functionAppName,privateEndpointNameConv,privateEndpointNICNameConv,storageAccountName,storageEncryptionIdentityName'
        $values.bundle.storageEncryptionIdentityName | Should Be $values.identityExpected
        $values.bundle.applicationInsightsName | Should Be 'appi-avd-inventory-use'
        $values.bundle.storageEncryptionIdentityName | Should Be 'uai-avd-inventory-storage-cmk-use'
        $values.bundle.privateEndpointNameConv | Should Be 'pe-RESOURCE-SUBRESOURCE-VNETID'
        $values.bundle.privateEndpointNICNameConv | Should Be 'nic-pe-RESOURCE-SUBRESOURCE-VNETID'
    }

    It 'is stable on redeployment and case-only changes' {
        $expected = $values.bundle | ConvertTo-Json -Compress
        ($values.redeployment | ConvertTo-Json -Compress) | Should Be $expected
        ($values.caseOnly | ConvertTo-Json -Compress) | Should Be $expected
        foreach ($case in $values.caseOnlyTypes) {
            $baseline = $values.cases | Where-Object { $_.profile -eq 'default' -and $_.type -eq $case.type }
            $case.actual | Should Be $baseline.actual
        }
    }

    It 'distinguishes subscriptions resource groups regions and add-on identifiers' {
        @($values.seeds.name | Select-Object -Unique).Count | Should Be 5
        @($values.seeds.storage | Select-Object -Unique).Count | Should Be 5
        foreach ($seed in $values.seeds) {
            $seed.name.Contains($seed.hash) | Should Be $true
            $seed.storage.Contains($seed.hash) | Should Be $true
        }
        foreach ($name in @('functionAppName', 'storageAccountName', 'applicationInsightsName', 'storageEncryptionIdentityName')) {
            $values.bundle.$name | Should Not Be $values.alternateIdentifier.$name
        }
        foreach ($name in @('functionAppName', 'storageAccountName')) {
            $values.noLocation[0].$name | Should Not Be $values.noLocation[1].$name
        }
        foreach ($name in @('applicationInsightsName', 'storageEncryptionIdentityName')) {
            $values.noLocation[0].$name | Should Be $values.noLocation[1].$name
        }
    }

    It 'distinguishes normalized identifiers without hashing scope-local names' {
        foreach ($name in @('functionAppName', 'storageAccountName')) {
            $values.normalizationCollision[0].$name | Should Not Be $values.normalizationCollision[1].$name
        }
        foreach ($name in @('applicationInsightsName', 'storageEncryptionIdentityName')) {
            $values.normalizationCollision[0].$name | Should Be $values.normalizationCollision[1].$name
        }
    }

    It 'names SHR and other add-ons with the common bundle and independently owned shared plan' {
        $finance = $values.applications[0]
        $finance.names.functionAppName | Should Be "fa-avd-finance-shr-$($finance.hash)-use"
        $finance.names.storageAccountName | Should Be "saavdfinanceshr$($finance.hash)use"
        $finance.names.applicationInsightsName | Should Be 'appi-avd-finance-shr-use'
        $finance.names.storageEncryptionIdentityName | Should Be 'uai-avd-finance-shr-storage-cmk-use'
        foreach ($app in $values.applications) {
            $app.sharedPlan | Should Be 'asp-avd-shr-use'
            $app.names.functionAppName.Contains($app.hash) | Should Be $true
            $app.names.storageAccountName.Contains($app.hash) | Should Be $true
        }
        @($values.applications.hash | Select-Object -Unique).Count | Should Be 3
        $values.applications[2].names.applicationInsightsName | Should Be 'appi-avd-finance-job-use'
    }

    It 'applies explicit overrides before evaluating overlength defaults' {
        $values.longOverride.storageAccountName | Should Be 'customshrstorage'
        $values.longOverride.functionAppName | Should Match '^fa-avd-finance-long-shr-[a-z0-9]{6}-use$'
        $values.overrides.functionAppName | Should Be 'custom-function'
        $values.overrides.storageAccountName | Should Be 'customstorage'
        $values.overrides.storageEncryptionIdentityName | Should Be 'custom-storage-identity'
        $values.overrides.applicationInsightsName | Should Be 'appi-avd-finance-shr-use'
    }

    It 'retains host-pool region tags while allowing an explicit location abbreviation' {
        foreach ($name in @('functionAppName', 'storageAccountName', 'applicationInsightsName', 'storageEncryptionIdentityName')) {
            $values.locationTag.$name.EndsWith('e1') | Should Be $true
            $values.locationPrecedence.$name.EndsWith('e2') | Should Be $true
        }
    }

    It 'uses the shared Government Secret and Top Secret region maps' {
        $locations = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\data\locations.json') -Raw | ConvertFrom-Json
        $expected = @('va', $locations.other.east.abbreviation, $locations.other.north.abbreviation)
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $values.clouds[$index].functionAppName.EndsWith('-' + $expected[$index]) | Should Be $true
        }
    }

    It 'compiles actual module wiring while retaining caller explicit overrides and target scope' {
        $integration.variables.names | Should Match "parameters\('targetSubscriptionId'\)"
        $integration.variables.names | Should Match "parameters\('targetResourceGroupName'\)"
        $integration.variables.names | Should Match "parameters\('location'\)"
        $app = $integration.resources.app
        foreach ($name in @('functionAppName', 'storageAccountName')) {
            $binding = $app.properties.parameters.$name | ConvertTo-Json -Compress
            $binding | Should Match "variables\('names'\)\.$name"
            $integration.variables.names | Should Match "parameters\('$($name)Override'\)"
        }
        foreach ($parameter in @('applicationInsightsName', 'privateEndpointNameConv', 'privateEndpointNICNameConv')) {
            $app.properties.parameters.$parameter.value | Should Match "variables\('names'\)\.$parameter"
        }
        $app.properties.parameters.serverFarmId.value | Should Be "[parameters('serverFarmId')]"
    }

    It 'propagates numeric type limits and the default hash length without changing type overrides' {
        $policyPath = Join-Path $testDirectory 'deployments\shared\modules\orchestration\naming\naming.bicep'
        $original = [IO.File]::ReadAllText($policyPath)
        try {
            $changedPolicy = $original.Replace(
                "storageAccounts: { lengthLimit: 24,", "storageAccounts: { lengthLimit: 23,"
            ).Replace('defaultUniqueLength: 6', 'defaultUniqueLength: 5')
            $changedPolicy | Should Not Be $original
            [IO.File]::WriteAllText($policyPath, $changedPolicy)
            $raw = @(& $bicep local-deploy (Join-Path $testDirectory 'tests\fixtures\naming-types.bicepparam') --format Json 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "Changed-policy naming evaluation failed: $($raw -join [Environment]::NewLine)" }
            $encoded = ($raw -join [Environment]::NewLine | ConvertFrom-Json).outputs.encodedResults
            $changed = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
            $storage = $changed.cases | Where-Object { $_.profile -eq 'default' -and $_.type -eq 'storageAccounts' }
            $storage.hash.Length | Should Be 5
            $storage.actual | Should Be "saavdfin$($storage.hash)use"
            ($changed.boundaries | Where-Object type -eq 'storageAccounts').actual.Length | Should Be 23
            foreach ($case in $changed.cases) {
                $expectedLength = if ($case.type -eq 'keyVaults') { 6 } elseif ($case.type -in @('functionApps', 'storageAccounts')) { 5 } else { 0 }
                $case.hash.Length | Should Be $expectedLength
                if ($expectedLength -gt 0) {
                    $case.actual.Contains($case.hash) | Should Be $true
                }
                else {
                    $baseline = $values.cases | Where-Object { $_.profile -eq $case.profile -and $_.type -eq $case.type }
                    $case.actual | Should Be $baseline.actual
                }
            }
        }
        finally {
            [IO.File]::WriteAllText($policyPath, $original)
        }
    }

    It 'rejects invalid input explicitly: <Name>' -TestCases (@(
        @{ Name = 'empty identifier'; Identifier = "''" }
        @{ Name = 'invalid identifier characters'; Identifier = "'inventory/app'" }
        @{ Name = 'overlength SHR storage without override'; Identifier = "'finance-long-shr'"; Type = 'storageAccounts'; ExpectedError = 'Generated name exceeds the 24-character limit' }
        @{ Name = 'leading separator'; Identifier = "'_inventory'" }
        @{ Name = 'missing purpose'; Convention = "{ components: ['resourceType', 'workload', 'location'] }" }
        @{ Name = 'empty components'; Convention = '{ components: [] }' }
        @{ Name = 'all-none components'; Convention = "{ components: ['none'] }" }
        @{ Name = 'repeated purpose'; Convention = "{ components: ['purpose', 'purpose'] }" }
        @{ Name = 'unknown component'; Convention = "{ components: ['purpose', 'unknown'] }" }
        @{ Name = 'invalid delimiter'; Convention = "{ delimiter: '*' }" }
        @{ Name = 'overlong delimiter'; Convention = "{ delimiter: '----' }" }
        @{ Name = 'invalid workload'; Convention = "{ workload: 'my workload' }" }
        @{ Name = 'unbudgetable static components'; Convention = "{ workload: 'abcdefghijklmnopqrstuvwxyz' }"; Type = 'storageAccounts' }
        @{ Name = 'invalid type code'; Convention = "{ resourceTypeCodes: { functionApps: '' } }" }
        @{ Name = 'invalid region abbreviation'; Convention = "{ locationAbbreviation: 'east/us' }" }
        @{ Name = 'unsupported resource type'; Type = 'notARegisteredType' }
        @{ Name = 'empty subscription'; Context = "union(context, { subscriptionId: '' })" }
        @{ Name = 'empty resource group'; Context = "union(context, { resourceGroupName: '' })" }
        @{ Name = 'empty location'; Context = "union(context, { location: '' })" }
        @{ Name = 'empty cloud'; Context = "union(context, { cloud: '' })" }
        @{ Name = 'surrounding scope whitespace'; Context = "union(context, { resourceGroupName: ' rg-addons ' })" }
        @{ Name = 'unsupported cloud'; Context = "union(context, { cloud: 'UnknownCloud' })" }
        @{ Name = 'unsupported cloud with explicit region abbreviation'; Context = "union(context, { cloud: 'UnknownCloud' })"; Convention = "{ locationAbbreviation: 'e1' }" }
        @{ Name = 'vault consecutive hyphens'; Type = 'keyVaults'; Convention = "{ delimiter: '--' }" }
        @{ Name = 'vault numeric first component'; Type = 'keyVaults'; Identifier = "'123inventory'"; Convention = "{ components: ['purpose'] }" }
        @{ Name = 'automation numeric first component'; Type = 'automationAccounts'; Identifier = "'123inventory'"; Convention = "{ components: ['purpose'] }" }
        @{ Name = 'backup vault numeric first component'; Type = 'recoveryServicesVaults'; Identifier = "'123inventory'"; Convention = "{ components: ['purpose'] }" }
    ) + @(
        $discoveryPolicy = Get-TestNamingPolicy
        $discoveryAbbreviations = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\data\resourceAbbreviations.json') -Raw | ConvertFrom-Json
        foreach ($type in $discoveryPolicy.resourceTypes.PSObject.Properties) {
            $code = $discoveryAbbreviations.($type.Name)
            $hashLength = if ($type.Value.globallyUnique) { if ($type.Value.uniqueLength) { $type.Value.uniqueLength } else { $discoveryPolicy.limits.defaultUniqueLength } } else { 0 }
            $overhead = if ($type.Name -eq 'storageAccounts') { "${code}avduse".Length + $hashLength } else { "$code-avd--use".Length + $(if ($hashLength) { 1 + $hashLength } else { 0 }) }
            $identifier = 'a' * ($type.Value.lengthLimit - $overhead + 1)
            @{
                Name = "one character over the $($type.Name) limit"
                Type = $type.Name
                Identifier = "'$identifier'"
                ExpectedError = "Generated name exceeds the $($type.Value.lengthLimit)-character limit"
            }
        }
    )) {
        param($Name, $Identifier, $Convention, $Type, $Context, $ExpectedError)

        if (-not $Identifier) { $Identifier = "'inventory'" }
        if (-not $Convention) { $Convention = '{}' }
        if (-not $Type) { $Type = 'functionApps' }
        if (-not $Context) { $Context = 'context' }
        $fixture = Join-Path $testDirectory 'tests\fixtures\rejected.bicep'
        [IO.File]::WriteAllLines($fixture, @(
            "targetScope = 'local'"
            "import { resourceNameForType } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'"
            "var context = { subscriptionId: '00000000-1111-2222-3333-444444444444', resourceGroupName: 'rg-addons', location: 'eastus', cloud: 'AzureCloud' }"
            "var rejectedName = resourceNameForType($Convention, '$Type', $Identifier, $Context)"
            "output rejected string = rejectedName"
        ))
        $parameters = Join-Path $testDirectory 'tests\fixtures\rejected.bicepparam'
        [IO.File]::WriteAllText($parameters, "using './rejected.bicep'")
        $raw = @(& $bicep local-deploy $parameters --format Json 2>&1)
        $LASTEXITCODE | Should Not Be 0
        $failure = ($raw -join [Environment]::NewLine) | ConvertFrom-Json
        @($failure.outputs.PSObject.Properties | Where-Object { $null -ne $_ }).Count | Should Be 0
        $failure.error | Should Not BeNullOrEmpty
        if ($ExpectedError) {
            ($failure.error -replace '\s+', ' ') | Should Match ([regex]::Escape($ExpectedError))
        }
    }
}
