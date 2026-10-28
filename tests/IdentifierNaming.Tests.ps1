$repoRoot = Split-Path -Parent $PSScriptRoot

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
            'deployments\shared\data\namingPolicy.json'
            'deployments\shared\data\resourceAbbreviations.json'
            'deployments\shared\data\locations.json'
            'deployments\shared\modules\orchestration\naming\functions.bicep'
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
        $policy = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\data\namingPolicy.json') -Raw | ConvertFrom-Json
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

    It 'executes seventy real runtime vectors across five resource types and fourteen profiles' {
        $values.cases.Count | Should Be 70
        foreach ($case in $values.cases) {
            $limit = $policy.limits.($policy.resourceTypes.($case.type).lengthLimit)
            ($case.actual.Length -le $limit) | Should Be $true
            $case.hash | Should Match '^[a-z0-9]{13}$'
            $case.actual.Contains($case.hash) | Should Be $true
            $case.actual | Should Be $case.actual.ToLowerInvariant()
            if ($case.type -eq 'storageAccounts') {
                $case.actual | Should Match '^[a-z0-9]{3,24}$'
            }
            else {
                $case.actual | Should Match '^[a-z0-9][a-z0-9-]*[a-z0-9]$'
            }
        }
    }

    It 'preserves default static components and the full hash while budgeting only the identifier' {
        $app = $values.cases | Where-Object { $_.profile -eq 'default' -and $_.type -eq 'functionApps' }
        $storage = $values.cases | Where-Object { $_.profile -eq 'default' -and $_.type -eq 'storageAccounts' }
        $app.actual | Should Be "fa-avd-inventory-$($app.hash)-use"
        $storage.actual | Should Be "saavdinv$($storage.hash)use"
        $storage.actual.Length | Should Be 24
        $smallest = $values.cases | Where-Object { $_.profile -eq 'single-character-budget' -and $_.type -eq 'storageAccounts' }
        $smallest.actual | Should Be "saavdxxi$($smallest.hash)use"
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
            Should Be 'applicationInsightsName,appServicePlanName,functionAppName,privateEndpointNameConv,privateEndpointNICNameConv,storageAccountName,storageEncryptionIdentityName'
        $values.bundle.storageEncryptionIdentityName | Should Be $values.identityExpected
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
        foreach ($name in @('functionAppName', 'storageAccountName', 'applicationInsightsName', 'appServicePlanName', 'storageEncryptionIdentityName')) {
            $values.bundle.$name | Should Not Be $values.alternateIdentifier.$name
            $values.noLocation[0].$name | Should Not Be $values.noLocation[1].$name
        }
    }

    It 'retains identity when readable tokens normalize or truncate to the same prefix' {
        foreach ($name in @('functionAppName', 'storageAccountName', 'applicationInsightsName', 'appServicePlanName', 'storageEncryptionIdentityName')) {
            $values.normalizationCollision[0].$name | Should Not Be $values.normalizationCollision[1].$name
            $values.longIdentifiers[0].$name | Should Not Be $values.longIdentifiers[1].$name
        }
        $values.longIdentifiers[0].functionAppName.Length | Should Be 60
        $values.longIdentifiers[0].storageAccountName.Length | Should Be 24
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
            $binding | Should Match "parameters\('$($name)Override'\)"
            $binding | Should Match "variables\('names'\)\.$name"
        }
        foreach ($parameter in @('applicationInsightsName', 'privateEndpointNameConv', 'privateEndpointNICNameConv')) {
            $app.properties.parameters.$parameter.value | Should Match "variables\('names'\)\.$parameter"
        }
        $app.properties.parameters.serverFarmId.value | Should Be "[parameters('serverFarmId')]"
    }

    It 'rejects invalid input explicitly: <Name>' -TestCases @(
        @{ Name = 'empty identifier'; Identifier = "''" }
        @{ Name = 'invalid identifier characters'; Identifier = "'inventory/app'" }
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
    ) {
        param($Name, $Identifier, $Convention, $Type, $Context)

        if (-not $Identifier) { $Identifier = "'inventory'" }
        if (-not $Convention) { $Convention = '{}' }
        if (-not $Type) { $Type = 'functionApps' }
        if (-not $Context) { $Context = 'context' }
        $fixture = Join-Path $testDirectory 'tests\fixtures\rejected.bicep'
        [IO.File]::WriteAllLines($fixture, @(
            "targetScope = 'local'"
            "import { resourceNameForType } from '../../deployments/shared/modules/orchestration/naming/functions.bicep'"
            "var context = { subscriptionId: '00000000-1111-2222-3333-444444444444', resourceGroupName: 'rg-addons', location: 'eastus', cloud: 'AzureCloud' }"
            "output rejected string = resourceNameForType($Convention, '$Type', $Identifier, $Context)"
        ))
        $parameters = Join-Path $testDirectory 'tests\fixtures\rejected.bicepparam'
        [IO.File]::WriteAllText($parameters, "using './rejected.bicep'")
        $raw = @(& $bicep local-deploy $parameters --format Json 2>&1)
        $LASTEXITCODE | Should Not Be 0
        $failure = ($raw -join [Environment]::NewLine) | ConvertFrom-Json
        @($failure.outputs.PSObject.Properties).Count | Should Be 0
    }
}
