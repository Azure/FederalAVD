BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
}

Describe 'Shared naming and module metadata contracts' {
    BeforeAll {
        $testOutputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('FederalAVD-NamingTests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testOutputDirectory -ErrorAction Stop | Out-Null
        $compiledModules = @{}
        $modulePaths = @{
            NamingFunctions = 'deployments\shared\modules\orchestration\naming\naming.bicep'
            NamingInternals = 'deployments\shared\modules\orchestration\naming\internal.bicep'
            HostPoolNaming = 'tests\fixtures\naming-bundles.bicep'
            Replacer = 'deployments\add-ons\sessionHostReplacer\main.bicep'
            FunctionApp = 'deployments\shared\modules\resourceModules\functionApp\functionApp.bicep'
            HostingPlan = 'deployments\shared\modules\resourceModules\functionApp\functionAppHostingPlan.bicep'
            FunctionDefinition = 'deployments\shared\modules\resourceModules\functionApp\function.bicep'
            ScalarPattern = 'tests\fixtures\naming-scalar-import.bicep'
            DeploymentHelper = 'deployments\shared\modules\orchestration\deploymentHelper\deploy.bicep'
            SessionHostVMs = 'deployments\shared\modules\orchestration\sessionHosts\virtualMachines.bicep'
        }
        foreach ($module in $modulePaths.Keys) {
            $source = Join-Path $repoRoot $modulePaths[$module]
            $output = Join-Path $testOutputDirectory "$module.json"
            & az bicep build --file $source --outfile $output
            if ($LASTEXITCODE -ne 0) {
                throw "Bicep compilation failed: $source"
            }
            $compiledModules[$module] = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
        }
        foreach ($relative in @(
            'deployments\shared\data\resourceAbbreviations.json'
            'deployments\shared\data\locations.json'
            $modulePaths.NamingFunctions
            $modulePaths.NamingInternals
            'tests\fixtures\naming-vectors.bicep'
            'tests\fixtures\naming-policy.bicep'
        )) {
            $destination = Join-Path $testOutputDirectory $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $destination
        }
        $vectors = Invoke-TestNamingVectors -TemplateFile (Join-Path $testOutputDirectory 'tests\fixtures\naming-vectors.bicep')
        $policyVectors = Invoke-TestNamingVectors -TemplateFile (Join-Path $testOutputDirectory 'tests\fixtures\naming-policy.bicep')
        $policy = Get-TestNamingPolicy
        $namingForms = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deployments') -Filter 'uiFormDefinition.json' -Recurse |
            ForEach-Object {
                $source = Get-Content -LiteralPath $_.FullName -Raw
                $form = $source | ConvertFrom-Json
                if (@($form.view.outputs.parameters.PSObject.Properties.Name) -contains 'namingConvention') {
                    [pscustomobject]@{
                        Path = $_.FullName
                        Source = $source
                        Form = $form
                    }
                }
            })
    }

    AfterAll {
        if (Test-Path -LiteralPath $testOutputDirectory) {
            Remove-Item -LiteralPath $testOutputDirectory -Recurse -Force -ErrorAction Stop
        }
    }

    It 'preserves the executable naming vector <Name>' -TestCases @(
        @{ Name = 'defaultName'; Expected = 'rg-avd-desktop-eus' }
        @{ Name = 'reversedName'; Expected = 'avd-sec-abc123-va-kv' }
        @{ Name = 'omittedComponents'; Expected = 'rg-eus' }
        @{ Name = 'repeatedComponents'; Expected = 'rg-rg-desktop' }
        @{ Name = 'emptyDelimiter'; Expected = 'stavdimages' }
        @{ Name = 'customComponents'; Expected = 'org_prod_avd_desktop_eus_01_rg' }
        @{ Name = 'preservedCase'; Expected = 'Desktop' }
        @{ Name = 'strippedSeparators'; Expected = 'Abcde' }
        @{ Name = 'sanitizedVault'; Expected = 'Ab-c-d-e-sec-abc123' }
    ) {
        param($Name, $Expected)

        $vectors.$Name.value | Should -Be $Expected
    }

    It 'describes the compiled module and every parameter and output for <Module>' -TestCases @(
        @{ Module = 'NamingFunctions' }
        @{ Module = 'HostPoolNaming' }
        @{ Module = 'FunctionApp' }
        @{ Module = 'HostingPlan' }
        @{ Module = 'FunctionDefinition' }
    ) {
        param($Module)

        $template = $compiledModules[$Module]
        [string]::IsNullOrWhiteSpace($template.metadata.name) | Should -Be $false
        [string]::IsNullOrWhiteSpace($template.metadata.description) | Should -Be $false
        foreach ($section in @('parameters', 'outputs')) {
            foreach ($property in $template.$section.PSObject.Properties) {
                [string]::IsNullOrWhiteSpace($property.Value.metadata.description) | Should -Be $false
            }
        }
    }

    It 'preserves qualified private-endpoint naming calls in <Template>' -TestCases @(
        @{ Template = 'FunctionApp' }
        @{ Template = 'Replacer' }
        @{ Template = 'TrackedReplacer' }
    ) {
        param($Template)

        $app = switch ($Template) {
            'FunctionApp' { $compiledModules.FunctionApp }
            'Replacer' { $compiledModules.Replacer.resources.functionApp.properties.template }
            'TrackedReplacer' {
                (Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.json') -Raw |
                    ConvertFrom-Json).resources.functionApp.properties.template
            }
        }
        $app | Should -Not -BeNullOrEmpty
        ($app | ConvertTo-Json -Depth 100) | Should -Not -Match '(?<![\w.])privateEndpointName\s*\('
        $names = @($app.variables.copy | Where-Object { $_.name -eq 'storagePrivateEndpointNames' })
        $names.Count | Should -Be 1
        $names[0].input | Should -Match '__bicep\.privateEndpointName\('
        $app.resources.privateEndpoints_storage.name | Should -Match "variables\('storagePrivateEndpointNames'\)"
        $app.resources.privateDnsZoneGroups_storage.name | Should -Match "variables\('storagePrivateEndpointNames'\)"
    }

    It 'exposes six documented public naming functions and one shared convention type without policy internals' {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $modulePaths.NamingFunctions) -Raw
        $documentedExports = [regex]::Matches($source, "(?m)^@export\(\)\r?\n@description\('[^\r\n]+'\)\r?\n(?:func|var|type) (\w+)")
        @($documentedExports).Count | Should -Be ([regex]::Matches($source, '(?m)^@export\(\)').Count)
        @($documentedExports).Count | Should -Be 7
        [regex]::Matches($source, '(?m)^func ').Count | Should -Be 6
        @($documentedExports | Where-Object { $_.Groups[1].Value -eq 'namingConventionConfig' }).Count | Should -Be 1
        foreach ($name in @('resourceNameForType', 'functionAppNames', 'hostPoolNames', 'fslogixNames', 'sharedServicesNames', 'imageManagementNames')) {
            @($documentedExports | Where-Object { $_.Groups[1].Value -eq $name }).Count | Should -Be 1
        }
        foreach ($name in @('resourceName', 'namingPolicy', 'resolveConvention', 'regionAbbreviation', 'shortScopedUnique', 'imageStorageName', 'namePattern', 'buildCustomName', 'cnv', 'stripSeps', 'kvSanitize', 'deploymentVmName', 'scopedUnique', 'privateEndpointVnetToken', 'fslogixStoragePrefix')) {
            @($documentedExports | Where-Object { $_.Groups[1].Value -eq $name }).Count | Should -Be 0
        }
    }

    It 'keeps a scalar policy import below 1200 compiled bytes without the policy catalog' {
        (Get-Item -LiteralPath (Join-Path $testOutputDirectory 'ScalarPattern.json')).Length | Should -BeLessThan 1200
        $variables = $compiledModules.ScalarPattern.variables | ConvertTo-Json -Depth 100 -Compress
        $variables | Should -Match 'SHNAME-osdisk'
        $variables | Should -Not -Match '"defaults"\s*:|"resources"\s*:|"templateSpecs"\s*:'
    }

    It 'publishes a sealed optional convention schema while retaining legacy Portal keys' {
        $schema = $compiledModules.Replacer.parameters.namingConvention
        while ($schema.'$ref') {
            $schema = $compiledModules.Replacer.definitions.($schema.'$ref'.Split('/')[-1])
        }
        $schema.type | Should -Be 'object'
        $schema.additionalProperties | Should -Be $false
        foreach ($key in @('customToken1', 'customToken2', 'freeform1', 'freeform2')) {
            $schema.properties.$key.type | Should -Be 'string'
        }
        foreach ($form in $namingForms) {
            $binding = [string]$form.Form.view.outputs.parameters.namingConvention
            foreach ($match in [regex]::Matches($binding, '"([A-Za-z0-9_]+)"\s*:')) {
                $prefix = $binding.Substring(0, $match.Index)
                $depth = [regex]::Matches($prefix, '\{').Count - [regex]::Matches($prefix, '\}').Count
                if ($depth -eq 1) {
                    ($schema.properties.PSObject.Properties.Name -contains $match.Groups[1].Value) |
                        Should -Be $true -Because "$($form.Path) emits top-level convention key $($match.Groups[1].Value)"
                }
                else {
                    $depth | Should -Be 2
                    ($policy.resourceTypes.PSObject.Properties.Name -contains $match.Groups[1].Value) |
                        Should -Be $true -Because 'nested keys are resource-type abbreviation overrides'
                }
            }
        }
        $schema.required | Should -BeNullOrEmpty
    }

    It 'compiles the complete expandable <Example> quick start without an adapter file' -TestCases @(
        @{ Example = 'Automation Account'; Module = 'automationAccount'; Override = 'automationAccountNameOverride' }
        @{ Example = 'Function App'; Module = 'app'; Override = 'functionAppNameOverride' }
    ) {
        param($Example, $Module, $Override)

        $guide = Get-Content -LiteralPath (Join-Path $repoRoot 'docs\naming-convention.md') -Raw
        $quickStart = [regex]::Match($guide, '(?s)## Add-on developer quick start\r?\n(.*?)\r?\n---').Groups[1].Value
        $examples = @([regex]::Matches($quickStart, '(?s)<details>\s*<summary>(.*?)</summary>(.*?)</details>'))
        $examples.Count | Should -Be 2
        $exampleBlock = @($examples | Where-Object { $_.Groups[1].Value.StartsWith("${Example}:") })
        $exampleBlock.Count | Should -Be 1
        $snippets = @([regex]::Matches($exampleBlock[0].Groups[2].Value, '(?s)```bicep\r?\n(.*?)```'))
        $snippets.Count | Should -Be 1
        $snippet = $snippets[0].Groups[1].Value
        $snippet | Should -Not -BeNullOrEmpty
        $snippet | Should -Match 'param namingConvention namingConventionConfig = \{\}'
        $snippet | Should -Match "param $Override string = ''"
        $snippet | Should -Match "'<purpose>'"
        $snippet | Should -Match 'resourceGroup\(\)\.name'
        $directory = Join-Path $testOutputDirectory "deployments\add-ons\quickStart\$Module"
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $documentedDirectory = Join-Path $repoRoot 'deployments\add-ons\quickStart'
        $snippet = [regex]::Replace($snippet, "(?m)(import \{[^\r\n]+\} from |module \w+ )'([^']+)'", {
            param($match)

            $source = [IO.Path]::GetFullPath((Join-Path $documentedDirectory $match.Groups[2].Value))
            Test-Path -LiteralPath $source | Should -Be $true
            $relative = [IO.Path]::GetRelativePath($directory, $source).Replace('\', '/')
            "$($match.Groups[1].Value)'$relative'"
        })
        $fixture = Join-Path $directory 'main.bicep'
        [IO.File]::WriteAllText($fixture, $snippet)
        $compiled = Join-Path $directory 'main.json'
        & az bicep build --file $fixture --outfile $compiled
        $LASTEXITCODE | Should -Be 0
        $template = Get-Content -LiteralPath $compiled -Raw | ConvertFrom-Json
        $template.parameters.namingConvention.defaultValue | Should -Not -BeOfType [string]
        $moduleParameters = $template.resources.$Module.properties.parameters
        if ($Example -eq 'Automation Account') {
            $template.variables.names.automationAccountName | Should -Match "parameters\('automationAccountNameOverride'\)"
            $template.variables.names.automationAccountName | Should -Match "'Microsoft\.Automation/automationAccounts'"
            $template.variables.names.logAnalyticsWorkspaceName | Should -Match "parameters\('logAnalyticsWorkspaceNameOverride'\)"
            $template.variables.names.logAnalyticsWorkspaceName | Should -Match "'Microsoft\.OperationalInsights/workspaces'"
            $moduleParameters.automationAccountName.value | Should -Be "[variables('names').automationAccountName]"
            $template.resources.workspace.properties.parameters.name.value | Should -Be "[variables('names').logAnalyticsWorkspaceName]"
            $moduleParameters.logAnalyticsWorkspaceResourceId.value | Should -Match "reference\('workspace'\)\.outputs\.resourceId"
            $template.resources.automationAccount.dependsOn | Should -Contain 'workspace'
            $template.outputs.automationAccountResourceId.value | Should -Match "reference\('automationAccount'\)"
            $template.outputs.logAnalyticsWorkspaceResourceId.value | Should -Match "reference\('workspace'\)"
        }
        else {
            $template.variables.names | Should -Match "parameters\('functionAppNameOverride'\)"
            foreach ($key in @('functionAppName', 'storageAccountName', 'applicationInsightsName', 'privateEndpointNameConv', 'privateEndpointNICNameConv')) {
                $moduleParameters.$key.value | Should -Be "[variables('names').$key]"
            }
        }
    }

    It 'rejects invalid typed convention defaults at compilation: <Name>' -TestCases @(
        @{ Name = 'wrong property type'; Expression = '{ workload: 42 }' }
        @{ Name = 'misspelled property'; Expression = "{ worklod: 'avd' }" }
        @{ Name = 'unknown component'; Expression = "{ components: ['purpose', 'unknown'] }" }
        @{ Name = 'wrong abbreviation type'; Expression = '{ resourceTypeCodes: { keyVaults: 42 } }' }
    ) {
        param($Name, $Expression)

        $fixture = Join-Path $testOutputDirectory 'tests\fixtures\invalid-convention.bicep'
        [IO.File]::WriteAllText($fixture, "import { namingConventionConfig } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'`nparam namingConvention namingConventionConfig = $Expression`noutput convention object = namingConvention")
        $raw = @(& az bicep build --file $fixture --outfile (Join-Path $testOutputDirectory 'invalid-convention.json') 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        ($raw -join [Environment]::NewLine) | Should -Match 'BCP'
    }

    It 'does not embed the policy catalog or generic naming functions in small consumers' {
        foreach ($name in @('DeploymentHelper', 'SessionHostVMs')) {
            $variables = $compiledModules[$name].variables | ConvertTo-Json -Depth 100 -Compress
            $variables | Should -Not -Match '"defaults"\s*:|"resources"\s*:|"templateSpecs"\s*:'
            @($compiledModules[$name].functions | Where-Object { $null -ne $_ }).Count | Should -Be 0
        }
    }

    It 'preserves explicit helper identity names and uses a fixed deployment token for fallback' {
        $compiledModules.DeploymentHelper.variables.deploymentUserAssignedIdentityName |
            Should -Be "[if(not(empty(parameters('userAssignedIdentityName'))), parameters('userAssignedIdentityName'), replace(parameters('userAssignedIdentityNameConv'), 'TOKEN', 'deployment'))]"
    }

    It 'imports shared naming without redeclaring helpers in <Path>' -TestCases @(
        @{ Path = 'deployments\hostpools\hostpool.bicep'; Functions = @('hostPoolNames') }
        @{ Path = 'deployments\automatedHostPools\automatedHostPool.bicep'; Functions = @('hostPoolNames') }
        @{ Path = 'deployments\hostpoolPoc\hostpoolPoc.bicep'; Functions = @('hostPoolNames') }
        @{ Path = 'deployments\add-ons\fslogixStorage\main.bicep'; Functions = @('fslogixNames') }
        @{ Path = 'deployments\sharedServices\sharedServices.bicep'; Functions = @('sharedServicesNames') }
        @{ Path = 'deployments\imageManagement\imageManagement.bicep'; Functions = @('imageManagementNames') }
        @{ Path = 'deployments\add-ons\sessionHostReplacer\main.bicep'; Functions = @('functionAppNames', 'resourceNameForType') }
        @{ Path = 'deployments\networking\networking.bicep'; Functions = @('resourceName') }
        @{ Path = 'deployments\imageBuild\imageBuild.bicep'; Functions = @('imageBuildRunId', 'namePattern') }
        @{ Path = 'deployments\hostpoolPoc\hostpoolPoc.bicep'; Functions = @('resourceName') }
        @{ Path = 'deployments\add-ons\avdAlerts\main.bicep'; Functions = @('resourceName') }
        @{ Path = 'deployments\add-ons\storageQuotaManager\main.bicep'; Functions = @('resourceName') }
        @{ Path = 'deployments\add-ons\updateRouteTableWithM365Routes\main.bicep'; Functions = @('resourceName') }
        @{ Path = 'deployments\automatedHostPools\modules\controlPlane.bicep'; Functions = @('privateEndpointName') }
        @{ Path = 'deployments\hostpools\modules\control-plane\controlPlane.bicep'; Functions = @('privateEndpointName') }
        @{ Path = 'deployments\shared\modules\orchestration\avdWorkspace\avdWorkspace.bicep'; Functions = @('privateEndpointName') }
        @{ Path = 'deployments\shared\modules\orchestration\keyVaults\keyVaults.bicep'; Functions = @('privateEndpointName') }
        @{ Path = 'deployments\shared\modules\orchestration\fslogix\modules\azureFiles.bicep'; Functions = @('privateEndpointName') }
        @{ Path = 'deployments\shared\modules\resourceModules\functionApp\functionApp.bicep'; Functions = @('privateEndpointName') }
    ) {
        param($Path, $Functions)

        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        $source | Should -Match "(?m)^import \{[^}]+\} from '[^']+/naming/(naming|internal)\.bicep'"
        foreach ($name in $Functions) {
            $source | Should -Match "(?m)^import \{[^}\r\n]*\b$name\b"
        }
        $source | Should -Not -Match '(?m)^func (resolveComponent|buildCustomName|cnv|stripSeps|kvSanitize)\('
    }

    It 'keeps one naming implementation without obsolete import paths' {
        $canonical = Join-Path $repoRoot 'deployments\shared\modules\orchestration\naming\naming.bicep'
        (Test-Path -LiteralPath (Join-Path $repoRoot 'deployments\shared\modules\orchestration\naming\functions.bicep')) | Should -Be $false
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deployments') -Filter '*.bicep' -Recurse -File) {
            if ($file.FullName -in @($canonical, (Join-Path $repoRoot $modulePaths.NamingInternals))) { continue }
            $source = Get-Content -LiteralPath $file.FullName -Raw
            $source | Should -Not -Match "from '[^']*/naming/functions\.bicep'"
            $source | Should -Not -Match 'loadJsonContent\([^\r\n]*namingPolicy\.json'
            $source | Should -Not -Match '(?m)^func (buildCustomName|cnv|resourceName|resourceNameForType|privateEndpointName)\('
            $source | Should -Not -Match 'length\([^)]*[Vv]net[^)]*\) < 37|take\(scopedUnique\('
        }
    }

    It 'evaluates current resource roles and uses centralized SHR naming' {
        $policyVectors.roleNames.value.Count | Should -Be (@($policy.resources.PSObject.Properties).Count * 10 - 6)
        (Test-Path -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\modules\naming.bicep')) | Should -Be $false
        (Test-Path -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\modules\naming.json')) | Should -Be $false
        foreach ($case in $policyVectors.roleNames.value) {
            $case.actual | Should -Be $case.expected
        }
    }

    It 'enforces image-storage budgets and scoped uniqueness' {
        $policyVectors.storageNames.value.Count | Should -Be 52
        foreach ($case in $policyVectors.storageNames.value) {
            ($case.actual.Length -le 24) | Should -Be $true
            $case.actual | Should -Match '^[a-z0-9]+$'
        }
        $policyVectors.scopedSeeds.value.actual | Should -Be $policyVectors.scopedSeeds.value.expected
        $policyVectors.shortSeed.value | Should -Be $policyVectors.expectedShortSeed.value
        $policyVectors.runId.value | Should -Be $policyVectors.expectedRunId.value
    }

    It 'preserves internal purpose separators when an identifier is empty' {
        $expected = @{
            deploymentResourceGroup = 'rg-avd--deployment-use2'
            hostsResourceGroup = 'rg-avd--hosts-use2'
            storageResourceGroup = 'rg-avd--storage-use2'
            identityPattern = 'uai-avd--TOKEN-use2'
            diskEncryptionSetPattern = 'des-avd--TOKEN-use2'
            quotaAutomation = 'aa-sqm-use2'
        }
        foreach ($role in $expected.Keys) {
            $policyVectors.emptyIdentifierNames.value.$role | Should -Be $expected[$role]
        }
    }

    It 'retains cloud location mappings and uses prefixed air-gapped region inputs' {
        foreach ($case in @($policyVectors.regionChecks.value | ForEach-Object { $_ })) {
            $case.actual | Should -Be $case.expected
        }
        $policyVectors.commercialLocation.value | Should -Be 'use'
        $policyVectors.governmentLocation.value | Should -Be 'va'
    }

    It 'normalizes vault delimiters after convention assembly' {
        foreach ($role in @('secretsKeyVault', 'encryptionKeyVault')) {
            $purpose = if ($role -eq 'secretsKeyVault') { 'sec' } else { 'enc' }
            $cases = @($policyVectors.roleNames.value | Where-Object {
                $_.role -eq $role -and $_.scenario -in @(0, 2, 3, 4)
            })
            $cases.Count | Should -Be 4
            foreach ($case in $cases) {
                $expected = if ($case.scenario -eq 4) {
                    "kvavd${purpose}abc123use2"
                } else {
                    "kv-avd-${purpose}-abc123-use2"
                }
                $case.actual | Should -Be $expected
            }
        }
    }

    It 'uses configured delimiters consistently for vaults and permits delimiter-free storage' {
        $policyVectors.emptyDelimiter.value | Should -Be 'kvavdsecabc123va'
        @($policyVectors.storageNames.value | Where-Object { $_.actual -match '^[a-z0-9]+$' }).Count | Should -Be 52
        $policyVectors.partialCodes.value.keyVaults | Should -Be 'vault'
        $policyVectors.partialCodes.value.workspaces | Should -Be 'vdws'
        $policyVectors.resourceTypeFlags.value[1] | Should -Be $false
        $policyVectors.resourceTypeFlags.value[10] | Should -Be $true
        $policyVectors.resourceTypeFlags.value[11] | Should -Be $true
    }

    It 'preserves temporary VM naming, endpoint placement and special legacy defaults' {
        $policyVectors.temporaryVm.value | Should -Be $policyVectors.expectedTemporaryVm.value
        $policyVectors.temporaryVm.value.Length | Should -Be 15
        $policyVectors.endpointFirst.value | Should -Be 'pe-RESOURCE-SUBRESOURCE-VNETID'
        $policyVectors.endpointLast.value | Should -Be 'RESOURCE-SUBRESOURCE-VNETID-pe-nic'
        $policyVectors.networkLast.value | Should -Be 'avd-use2-ng'
        $policyVectors.quotaEmpty.value | Should -Be 'aa-sqm-va'
        $policyVectors.patterns.value.disk | Should -Be 'SHNAME-osdisk'
        $policyVectors.patterns.value.key | Should -Be 'finance-shr-storage-cmk'
        $policyVectors.patterns.value.buildGroup | Should -Be 'rg-dev-avd-image-builds-va-202610181234-abc123'
        $policyVectors.patterns.value.definition | Should -Be 'vmid-MicrosoftWindowsDesktop-windows11-win1125h2avd'
    }

    It 'preserves network names with equivalent conventions and applies shared overrides' {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\networking\networking.bicep') -Raw
        $source | Should -Match 'param namingConvention namingConventionConfig'
        $source | Should -Not -Match 'nameConvResTypeAtEnd|legacyConvention'
        $cases = @(
            @{ Convention = '{}'; Location = 'eastus2'; Cloud = 'AzureCloud'; Expected = @('ng-avd-use2', 'pip-avd-use2', 'rt-avd-use2', 'nsg-avd-use2') }
            @{ Convention = "{ components: ['workload', 'purpose', 'location', 'resourceType'] }"; Location = 'eastus2'; Cloud = 'AzureCloud'; Expected = @('avd-use2-ng', 'avd-use2-pip', 'avd-use2-rt', 'avd-use2-nsg') }
            @{ Convention = '{}'; Location = 'usgovvirginia'; Cloud = 'AzureUSGovernment'; Expected = @('ng-avd-va', 'pip-avd-va', 'rt-avd-va', 'nsg-avd-va') }
            @{ Convention = "{ components: ['customToken1', 'environment', 'workload', 'location', 'resourceType'], customToken1: 'org', environment: 'prod', workload: 'desktop', delimiter: '_', locationAbbreviation: 'site', resourceTypeCodes: { natGateways: 'nat' } }"; Location = 'eastus2'; Cloud = 'AzureCloud'; Expected = @('org_prod_desktop_site_nat', 'org_prod_desktop_site_pip', 'org_prod_desktop_site_rt', 'org_prod_desktop_site_nsg') }
            @{ Convention = "{ components: ['resourceType', 'location'], locationAbbreviation: '' }"; Location = 'eastus2'; Cloud = 'AzureCloud'; Expected = @('ng-use2', 'pip-use2', 'rt-use2', 'nsg-use2') }
        )
        $variables = @('natGatewayName', 'publicIPName', 'routeTableName', 'nsgName')
        $lines = @(
            "targetScope = 'local'"
            "import { namingConventionConfig } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'"
            "import { regionAbbreviation, resourceName } from '../../deployments/shared/modules/orchestration/naming/internal.bicep'"
        )
        $outputs = @()
        $abbreviation = [regex]::Match($source, '(?m)^var locationAbbreviation = ([^\r\n]+)').Groups[1].Value
        $abbreviation | Should -Not -BeNullOrEmpty
        for ($caseIndex = 0; $caseIndex -lt $cases.Count; $caseIndex++) {
            $case = $cases[$caseIndex]
            $lines += "param namingConvention$caseIndex namingConventionConfig = $($case.Convention)"
            $region = $abbreviation.Replace('environment().name', "'$($case.Cloud)'").
                Replace('namingConvention', "namingConvention$caseIndex") -replace '\blocation\b', "'$($case.Location)'"
            $lines += "var locationAbbreviation$caseIndex = $region"
            foreach ($variable in $variables) {
                $expression = [regex]::Match($source, "(?m)^var $variable = ([^\r\n]+)").Groups[1].Value
                $expression | Should -Not -BeNullOrEmpty
                $expression = $expression.Replace('namingConvention', "namingConvention$caseIndex").
                    Replace('locationAbbreviation', "locationAbbreviation$caseIndex")
                $lines += "var $variable$caseIndex = $expression"
                $outputs += "$variable$caseIndex"
            }
        }
        $lines += "output encodedResults string = base64(string({ $(($outputs | ForEach-Object { "${_}: $_" }) -join ', ') }))"
        $fixture = Join-Path $testOutputDirectory 'tests\fixtures\networking.bicep'
        [IO.File]::WriteAllLines($fixture, $lines)
        $actual = Invoke-TestNamingVectors -TemplateFile $fixture
        for ($caseIndex = 0; $caseIndex -lt $cases.Count; $caseIndex++) {
            for ($variableIndex = 0; $variableIndex -lt $variables.Count; $variableIndex++) {
                $actual.("$($variables[$variableIndex])$caseIndex").value |
                    Should -Be $cases[$caseIndex].Expected[$variableIndex]
            }
        }
    }

    It 'keeps Portal forms self-contained without hidden naming-policy controls' {
        ($namingForms.Count -gt 0) | Should -Be $true
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deployments') -Filter 'uiFormDefinition.json' -Recurse) {
            Get-Content -LiteralPath $file.FullName -Raw | Should -Not -Match 'federalAvdNamingPolicy'
        }
    }

    It 'keeps editable abbreviation defaults and optional-field fallbacks aligned with the shared catalog' {
        $abbreviations = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\data\resourceAbbreviations.json') -Raw | ConvertFrom-Json
        $keys = @{
            rtCodeRg = 'resourceGroups'; rtCodeHp = 'hostPools'; rtCodeDag = 'desktopApplicationGroups'
            rtCodeWs = 'workspaces'; rtCodeWorkspace = 'workspaces'; rtCodeSp = 'scalingPlans'
            rtCodeVm = 'virtualMachines'; rtCodeDisk = 'osdisks'; rtCodeDes = 'diskEncryptionSets'
            rtCodeDa = 'diskAccesses'; rtCodeAs = 'availabilitySets'; rtCodeSa = 'storageAccounts'
            rtCodeNaa = 'netAppAccounts'; rtCodeNacp = 'netAppCapacityPools'; rtCodeKv = 'keyVaults'
            rtCodeUai = 'userAssignedIdentities'; rtCodePe = 'privateEndpoints'; rtCodeNic = 'networkInterfaces'
            rtCodeLaw = 'logAnalyticsWorkspaces'; rtCodeDce = 'dataCollectionEndpoints'
            rtCodeRsv = 'recoveryServicesVaults'; rtCodeGal = 'computeGalleries'
        }
        foreach ($form in $namingForms) {
            $controls = @(Get-TestFormElement -Elements $form.Form.view.properties.steps.elements)
            foreach ($control in $controls | Where-Object type -eq 'Microsoft.Common.TextBox') {
                if ($control.name -like 'rtCode*') {
                    $keys.ContainsKey($control.name) | Should -Be $true
                    $key = $keys[$control.name]
                }
                elseif ($control.name -in @($abbreviations.PSObject.Properties.Name)) {
                    $key = $control.name
                }
                else {
                    continue
                }
                $expected = $abbreviations.$key
                $control.defaultValue | Should -Be $expected
                $directory = Split-Path -Leaf (Split-Path -Parent $form.Path)
                if ($directory -in @('sharedServices', 'imageManagement')) {
                    $reference = [regex]::Escape("steps('tagsAndNaming').naming.$($control.name)")
                    $form.Form.view.outputs.parameters.namingConvention |
                        Should -Match "if\(empty\($reference\),\s*'$expected',\s*$reference\)"
                }
            }
        }
    }

    It 'keeps naming-form outputs aligned with the deployment parameter contracts' {
        foreach ($form in $namingForms) {
            $templates = @(Get-ChildItem -LiteralPath (Split-Path -Parent $form.Path) -Filter '*.json' -File |
                Where-Object { Test-Path -LiteralPath ([IO.Path]::ChangeExtension($_.FullName, '.bicep')) })
            $templates.Count | Should -Be 1
            $template = Get-Content -LiteralPath $templates[0].FullName -Raw | ConvertFrom-Json
            foreach ($parameter in $form.Form.view.outputs.parameters.PSObject.Properties.Name) {
                ($parameter -in @($template.parameters.PSObject.Properties.Name)) | Should -Be $true
            }
        }
    }

    It 'does not require a JSON policy or synchronization gate to publish Template Specs' {
        Test-Path -LiteralPath (Join-Path $repoRoot 'deployments\shared\data\namingPolicy.json') | Should -Be $false
        Test-Path -LiteralPath (Join-Path $repoRoot 'tools\Sync-NamingPolicy.ps1') | Should -Be $false
        Get-Content -LiteralPath (Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1') -Raw |
            Should -Not -Match 'namingPolicy\.json|Sync-NamingPolicy'
    }

    It 'keeps literal publisher defaults and publishing purposes aligned with the compiled policy' {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1') -Raw
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $defaults = $ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'NamingConvention' }
        $defaults | Should -Not -BeNullOrEmpty
        $actual = $defaults.DefaultValue.SafeGetValue()
        ($actual.components -join ',') | Should -Be ($policy.defaults.components -join ',')
        $actual.delimiter | Should -Be $policy.defaults.delimiter
        $actual.workload | Should -Be $policy.defaults.workload
        $purposes = @([regex]::Matches($source, "(?m)^\s*(?:@\{\s*)?Purpose = '([^']+)'") |
            ForEach-Object { $_.Groups[1].Value })
        $expected = @($policy.templateSpecs.PSObject.Properties.Value) +
            @($policy.identifiers.imageManagement, ($policy.resources.alertsAutomation.purpose -join '-'), 'image-validation')
        ($purposes | Sort-Object) -join ',' | Should -Be (($expected | Sort-Object) -join ',')
        $source | Should -Match ([regex]::Escape("-Purpose '$($policy.resources.operationsResourceGroup.purpose -join '-')'"))
    }

    It 'preserves literal runtime patterns and adopted-host fallbacks in the <Directory> form' -TestCases @(
        @{ Directory = 'hostpools' }
        @{ Directory = 'add-ons\sessionHosts' }
        @{ Directory = 'add-ons\sessionHostReplacer' }
    ) {
        param($Directory)

        $form = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\uiFormDefinition.json") -Raw | ConvertFrom-Json
        $keys = @{
            vmNameConvOverride = 'virtualMachine'; virtualMachineNameConvOverride = 'virtualMachine'
            diskNameConvOverride = 'osDisk'; nicNameConvOverride = 'nic'
            networkInterfaceNameConvOverride = 'nic'; availabilitySetNameConvOverride = 'standaloneAvailabilitySet'
        }
        $tags = @{
            virtualMachine = 'virtualMachineNameConv'; osDisk = 'virtualMachineDiskNameConv'
            nic = 'virtualMachineNicNameConv'; standaloneAvailabilitySet = 'availabilitySetNameConv'
        }
        $controls = @(Get-TestFormElement -Elements $form.view.properties.steps.elements |
            Where-Object { $keys.ContainsKey($_.name) })
        $controls.Count | Should -Be $(if ($Directory -eq 'hostpools') { 3 } else { 4 })
        foreach ($control in $controls) {
            $key = $keys[$control.name]
            $expected = $policy.patterns.$key
            if ($Directory -ne 'hostpools') {
                $expected = "[coalesce(steps('basics').hostsRGProps.tags.$($tags[$key]), '$expected')]"
            }
            $control.defaultValue | Should -Be $expected
        }
    }

    It 'uses policy-aligned literal naming defaults in the <Directory> form' -TestCases @(
        @{ Directory = 'hostpools'; DelimiterType = 'Microsoft.Common.DropDown' }
        @{ Directory = 'automatedHostPools'; DelimiterType = 'Microsoft.Common.DropDown' }
        @{ Directory = 'sharedServices'; DelimiterType = 'Microsoft.Common.DropDown' }
        @{ Directory = 'imageManagement'; DelimiterType = 'Microsoft.Common.TextBox' }
    ) {
        param($Directory, $DelimiterType)

        $form = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\uiFormDefinition.json") -Raw | ConvertFrom-Json
        $step = $form.view.properties.steps | Where-Object name -eq 'tagsAndNaming'
        $naming = $step.elements | Where-Object name -eq 'naming'
        $delimiter = $naming.elements | Where-Object name -eq 'delimiter'
        $workload = $naming.elements | Where-Object name -eq 'workloadValue'
        $workload.defaultValue | Should -Be $policy.defaults.workload
        $workload.defaultValue | Should -Be 'avd'
        $delimiter.type | Should -Be $DelimiterType
        if ($DelimiterType -eq 'Microsoft.Common.DropDown') {
            $delimiter.defaultValue | Should -Be 'Hyphen (-)'
            @($delimiter.constraints.allowedValues).Count | Should -Be 2
            ($delimiter.constraints.allowedValues | Where-Object label -eq $delimiter.defaultValue).value | Should -Be $policy.defaults.delimiter
            @($delimiter.constraints.allowedValues | Where-Object value -ceq '-').Count | Should -Be 1
            @($delimiter.constraints.allowedValues | Where-Object value -ceq '_').Count | Should -Be 1
            $delimiter.constraints.PSObject.Properties['regex'] | Should -BeNullOrEmpty
        }
        else {
            $delimiter.defaultValue | Should -Be $policy.defaults.delimiter
            $delimiter.constraints.regex | Should -Be '^[-_.]{1,3}$'
        }
        $components = @($naming.elements | Where-Object name -match '^component[1-6]$')
        ($components.Count -ge $policy.defaults.components.Count) | Should -Be $true
        foreach ($component in $components) {
            $index = [int]$component.name.Substring(9) - 1
            $expected = if ($index -lt $policy.defaults.components.Count) { $policy.defaults.components[$index] } else { 'none' }
            ($component.constraints.allowedValues | Where-Object label -eq $component.defaultValue).value | Should -Be $expected
        }
        $form.view.outputs.parameters.namingConvention | Should -Match "steps\('tagsAndNaming'\)\.naming\.delimiter"
        $form.view.outputs.parameters.namingConvention | Should -Match "steps\('tagsAndNaming'\)\.naming\.workloadValue"
    }

    It 'propagates a changed native policy through actual consumers without rewriting authoring defaults' {
        $copyRoot = Join-Path $testOutputDirectory 'propagation'
        $files = @(
            'deployments\shared\data\resourceAbbreviations.json'
            'deployments\shared\data\locations.json'
            $modulePaths.NamingFunctions
            $modulePaths.NamingInternals
            $modulePaths.Replacer
            'deployments\hostpools\uiFormDefinition.json'
            'deployments\automatedHostPools\uiFormDefinition.json'
            'deployments\sharedServices\uiFormDefinition.json'
            'deployments\imageManagement\uiFormDefinition.json'
            'deployments\add-ons\fslogixStorage\uiFormDefinition.json'
            'deployments\add-ons\sessionHostReplacer\uiFormDefinition.json'
            'deployments\add-ons\sessionHosts\uiFormDefinition.json'
        )
        foreach ($relative in $files) {
            $destination = Join-Path $copyRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $destination
        }
        $copiedPolicyPath = Join-Path $copyRoot $modulePaths.NamingInternals
        $originalPolicy = Get-Content -LiteralPath $copiedPolicyPath -Raw
        $changedPolicy = $originalPolicy.Replace("workload: 'avd'", "workload: 'desktop'").
            Replace("sharedFslogix: 'fslogix'", "sharedFslogix: 'profiles'").
            Replace("purpose: ['operations']", "purpose: ['ops']").
            Replace("imageBuildVm: '{prefix}img-{unique}'", "imageBuildVm: '{prefix}image-{unique}'").
            Replace("'SHNAME-osdisk'", "'SHNAME-systemdisk'").
            Replace("deploymentIdentityPurpose: 'deployment'", "deploymentIdentityPurpose: 'unused-helper-purpose'")
        $changedPolicy | Should -Not -Be $originalPolicy
        [System.IO.File]::WriteAllText($copiedPolicyPath, $changedPolicy)
        $defaultOutput = Join-Path $copyRoot 'hostpool-defaults.json'
        $defaultDeclaration = [regex]::Match(
            (Get-Content -LiteralPath (Join-Path $copyRoot $modulePaths.Replacer) -Raw),
            '(?ms)^param namingConvention namingConventionConfig = \{.*?^\}'
        ).Value
        $defaultDeclaration | Should -Not -BeNullOrEmpty
        $defaultFixture = Join-Path $copyRoot 'deployments\add-ons\sessionHostReplacer\naming-defaults.bicep'
        [IO.File]::WriteAllText($defaultFixture, "import { namingConventionConfig } from '../../shared/modules/orchestration/naming/naming.bicep'`n" + $defaultDeclaration + "`noutput convention object = namingConvention")
        & az bicep build --file $defaultFixture --outfile $defaultOutput
        if ($LASTEXITCODE -ne 0) { throw 'Literal naming defaults did not compile.' }
        $default = (Get-Content -LiteralPath $defaultOutput -Raw | ConvertFrom-Json).parameters.namingConvention.defaultValue
        $default.workload | Should -Be $policy.defaults.workload
        ($default -is [string]) | Should -Be $false
        foreach ($relative in $files | Where-Object { $_ -like '*uiFormDefinition.json' }) {
            (Get-FileHash -LiteralPath (Join-Path $copyRoot $relative)).Hash |
                Should -Be (Get-FileHash -LiteralPath (Join-Path $repoRoot $relative)).Hash
        }
        $lines = @(
            "targetScope = 'local'"
            "import { namingPolicy, osDiskNamePattern, resourceName, namePattern } from '../../deployments/shared/modules/orchestration/naming/internal.bicep'"
            "import { sharedServicesNames, imageManagementNames } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'"
            'var changedPolicy = namingPolicy'
            'var namingConvention = {}'
            "var regionAbbr = 'va'"
            "var locationAbbreviation = 'va'"
            "var identifier = 'finance'"
            "var uniqueStringUrt = 'abc123'"
            "var depPrefix = 'dev-'"
            "var buildRunId = 'abc123'"
            'var sessionHostCount = 2'
            "var sessionHostNames = ['host01', 'host02']"
            "var virtualMachineDiskNameConv = ''"
            "var userAssignedIdentityName = ''"
            "var userAssignedIdentityNameConv = 'uai-TOKEN-va'"
            "var context = { subscriptionId: '00000000-1111-2222-3333-444444444444', cloud: 'AzureUSGovernment', location: 'usgovvirginia' }"
            "var sharedNames = sharedServicesNames(namingConvention, context, { secretsKeyVaultName: 'explicit-secrets', encryptionKeyVaultName: 'explicit-encryption' })"
            "var imageNames = imageManagementNames(namingConvention, context, 'PlatformManaged')"
            'var sharedServices = sharedNames.operationsResourceGroupName'
            'var imageManagement = imageNames.resourceGroupName'
        )
        $consumers = @(
            @{ Name = 'networking'; Path = 'deployments\networking\networking.bicep'; Variable = 'natGatewayName' }
            @{ Name = 'imageBuild'; Path = 'deployments\imageBuild\imageBuild.bicep'; Variable = 'imageVmName' }
            @{ Name = 'osDisks'; Path = $modulePaths.SessionHostVMs; Variable = 'osDiskNames' }
        )
        foreach ($consumer in $consumers) {
            $source = Get-Content -LiteralPath (Join-Path $repoRoot $consumer.Path) -Raw
            $match = [regex]::Matches($source, "(?m)^var $($consumer.Variable) = ([^\r\n]+)")
            $match.Count | Should -Be 1
            $lines += "var $($consumer.Name) = $($match[0].Groups[1].Value)"
            if ($consumer.Name -eq 'osDisks') {
                $customDiskExpression = $match[0].Groups[1].Value -replace '\bvirtualMachineDiskNameConv\b', "'custom-SHNAME-disk'"
                $lines += "var customOsDisks = $customDiskExpression"
            }
        }
        $helperSource = Get-Content -LiteralPath (Join-Path $repoRoot $modulePaths.DeploymentHelper) -Raw
        $helperMatch = [regex]::Match($helperSource, '(?s)var deploymentUserAssignedIdentityName =\s*(.*?)\r?\nvar virtualMachineAdminUserName')
        $helperMatch.Success | Should -Be $true
        $lines += "var helperDefault = $($helperMatch.Groups[1].Value)"
        $explicitHelperExpression = $helperMatch.Groups[1].Value -replace '\buserAssignedIdentityName\b', "'explicit-helper'"
        $lines += "var helperExplicit = $explicitHelperExpression"
        foreach ($name in @('avdAlerts', 'storageQuotaManager', 'updateRouteTableWithM365Routes')) {
            $source = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\add-ons\$name\main.bicep") -Raw
            $match = [regex]::Matches($source, "(?m)^var automationAccountName = !empty\(automationAccountNameOverride\)\r?\n  \? automationAccountNameOverride\r?\n  : ([^\r\n]+)")
            $match.Count | Should -Be 1
            $lines += "var $name = $($match[0].Groups[1].Value)"
        }
        $lines += "output encodedResults string = base64(string({ changedPolicy: changedPolicy, sharedServices: sharedServices, imageManagement: imageManagement, networking: networking, imageBuild: imageBuild, osDisks: osDisks, customOsDisks: customOsDisks, helperDefault: helperDefault, helperExplicit: helperExplicit, avdAlerts: avdAlerts, storageQuotaManager: storageQuotaManager, updateRouteTableWithM365Routes: updateRouteTableWithM365Routes }))"
        $fixture = Join-Path $copyRoot 'tests\fixtures\propagation.bicep'
        New-Item -ItemType Directory -Path (Split-Path -Parent $fixture) -Force | Out-Null
        [System.IO.File]::WriteAllLines($fixture, $lines)
        $names = Invoke-TestNamingVectors -TemplateFile $fixture
        $names.changedPolicy.value.defaults.workload | Should -Be 'desktop'
        $names.changedPolicy.value.identifiers.sharedFslogix | Should -Be 'profiles'
        $names.sharedServices.value | Should -Be 'rg-desktop-ops-va'
        $names.imageManagement.value | Should -Be 'rg-desktop-image-management-va'
        $names.networking.value | Should -Be 'ng-desktop-va'
        $names.avdAlerts.value | Should -Be 'aa-desktop-alerts-va'
        $names.storageQuotaManager.value | Should -Be 'aa-sqm-finance-va'
        $names.updateRouteTableWithM365Routes.value | Should -Be 'aa-urt-abc123-va'
        $names.imageBuild.value | Should -Be 'dev-image-abc123'
        ($names.osDisks.value -join ',') | Should -Be 'host01-systemdisk,host02-systemdisk'
        ($names.customOsDisks.value -join ',') | Should -Be 'custom-host01-disk,custom-host02-disk'
        $names.helperDefault.value | Should -Be 'uai-deployment-va'
        $names.helperExplicit.value | Should -Be 'explicit-helper'
    }

    It 'uses explicit host-pool locations and direct central naming without a deployment boundary' {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpools\hostpool.bicep') -Raw
        $source | Should -Match 'var naming = hostPoolNames\(effectiveNamingConvention, hpBaseName,'
        $source | Should -Match 'virtualMachinesLocation: virtualMachinesLocation'
        $source | Should -Not -Match 'vmVirtualNetwork|module naming '
        Test-Path -LiteralPath (Join-Path $repoRoot 'deployments\shared\modules\orchestration\naming\hostPool.bicep') | Should -Be $false
    }

    It 'emits literal naming defaults rather than ARM variable references' {
        foreach ($form in $namingForms) {
            $templates = @(Get-ChildItem -LiteralPath (Split-Path -Parent $form.Path) -Filter '*.json' -File |
                Where-Object { Test-Path -LiteralPath ([IO.Path]::ChangeExtension($_.FullName, '.bicep')) })
            $templates.Count | Should -Be 1
            $template = Get-Content -LiteralPath $templates[0].FullName -Raw | ConvertFrom-Json
            $default = $template.parameters.namingConvention.defaultValue
            ($default -is [string]) | Should -Be $false
            $default.workload | Should -Be $policy.defaults.workload
            $default.delimiter | Should -Be $policy.defaults.delimiter
            ($default.components -join ',') | Should -Be ($policy.defaults.components -join ',')
        }
        $sessionHosts = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHosts\main.json') -Raw | ConvertFrom-Json
        $sessionHosts.parameters.virtualMachineNameConv.defaultValue | Should -Be $policy.patterns.virtualMachine
        $sessionHosts.parameters.virtualMachineDiskNameConv.defaultValue | Should -Be $policy.patterns.osDisk
        $sessionHosts.parameters.virtualMachineNicNameConv.defaultValue | Should -Be $policy.patterns.nic
        $sessionHosts.parameters.availabilitySetNameConv.defaultValue | Should -Be $policy.patterns.standaloneAvailabilitySet
    }

    It 'keeps preservation details in shared guidance rather than emitted library metadata' {
        $description = $compiledModules.NamingFunctions.metadata.description
        $description | Should -Not -Match 'Component requirements:'
        $description | Should -Not -Match 'Key properties:'
        $guide = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\modules\orchestration\naming\README.md') -Raw
        $guide | Should -Match 'generated storage-group name'
        $guide | Should -Match 'raw region abbreviation'
    }
}

Describe 'Portal naming without resource-name previews' {
    It 'omits naming previews without dangling references in <Directory>' -TestCases @(
        @{ Directory = 'hostpools'; Output = 'namingConvention' }
        @{ Directory = 'sharedServices'; Output = 'namingConvention' }
        @{ Directory = 'imageManagement'; Output = 'namingConvention' }
        @{ Directory = 'add-ons\sessionHostReplacer'; Output = 'namingConvention' }
        @{ Directory = 'add-ons\avdAlerts'; Output = 'automationAccountNameOverride' }
        @{ Directory = 'add-ons\storageQuotaManager'; Output = 'automationAccountNameOverride' }
    ) {
        param($Directory, $Output)

        $formPath = Join-Path $repoRoot "deployments\$Directory\uiFormDefinition.json"
        $source = Get-Content -LiteralPath $formPath -Raw
        $form = $source | ConvertFrom-Json
        $source | Should -Not -Match '\b(namingPreview|defaultNamePreview|previewConvention|previewHostPool|previewKvSecrets|previewKvEncryption|previewRg|previewGallery|previewVmPatterns|previewNote)\b'
        [string]::IsNullOrWhiteSpace($form.view.outputs.parameters.$Output) | Should -Be $false
    }

    Describe 'Portal naming hidden component outputs in <Directory>' -ForEach @(
        @{ Directory = 'imageManagement' }
        @{ Directory = 'sharedServices' }
        @{ Directory = 'hostpools' }
        @{ Directory = 'automatedHostPools' }
    ) {
        BeforeAll {
            $form = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\uiFormDefinition.json") -Raw | ConvertFrom-Json
            $step = $form.view.properties.steps | Where-Object name -eq 'tagsAndNaming'
            $naming = $step.elements | Where-Object name -eq 'naming'
            $defaults = @{}
            foreach ($control in $naming.elements) {
                $defaults[$control.name] = if ($control.type -eq 'Microsoft.Common.DropDown') {
                    ($control.constraints.allowedValues | Where-Object label -eq $control.defaultValue).value
                } else {
                    $control.defaultValue
                }
            }
            $binding = $form.view.outputs.parameters.namingConvention
            $templates = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "deployments\$Directory") -Filter '*.json' -File |
                Where-Object { Test-Path -LiteralPath ([IO.Path]::ChangeExtension($_.FullName, '.bicep')) })
            $templates.Count | Should -Be 1
            $template = Get-Content -LiteralPath $templates[0].FullName -Raw | ConvertFrom-Json
            $schema = $template.parameters.namingConvention
            while ($schema.'$ref') {
                $schema = $template.definitions.($schema.'$ref'.Split('/')[-1])
            }
            $allowedComponents = $schema.properties.components.allowedValues
            $allowedComponents | Should -Not -BeNullOrEmpty
        }

        It 'submits valid defaults when the hidden sixth component is unset' {
            foreach ($unset in @($null, '')) {
                $values = $defaults.Clone()
                $values.component6 = $unset
                $result = Invoke-TestNamingFormExpression $binding @{ tagsAndNaming = @{ naming = $values } }
                ($result.components -join ',') | Should -Be 'resourceType,workload,purpose,location,none,none'
                @($result.components | Where-Object { $_ -notin $allowedComponents }).Count | Should -Be 0
            }
        }

        It 'normalizes every hidden component after an earlier stop selection' {
            foreach ($stop in 2..6) {
                foreach ($unset in @($null, '')) {
                    $values = $defaults.Clone()
                    $values["component$stop"] = 'none'
                    for ($index = $stop + 1; $index -le 6; $index++) {
                        $values["component$index"] = $unset
                    }
                    $result = Invoke-TestNamingFormExpression $binding @{ tagsAndNaming = @{ naming = $values } }
                    $result.components.Count | Should -Be 6
                    @($result.components | Where-Object { $_ -notin $allowedComponents }).Count | Should -Be 0
                    for ($index = 1; $index -le 6; $index++) {
                        $expected = if ($index -lt $stop) { $defaults["component$index"] } else { 'none' }
                        $result.components[$index - 1] | Should -Be $expected
                    }
                }
            }
        }

        It 'preserves all six explicitly selected components' {
            $values = $defaults.Clone()
            $expected = @('freeform1', 'environment', 'workload', 'purpose', 'location', 'resourceType')
            for ($index = 1; $index -le 6; $index++) {
                $values["component$index"] = $expected[$index - 1]
            }
            $result = Invoke-TestNamingFormExpression $binding @{ tagsAndNaming = @{ naming = $values } }
            ($result.components -join ',') | Should -Be ($expected -join ',')
        }
    }

    It 'explains Key Vault length failures and retains complete-name override validation in <Directory>' -TestCases @(
        @{ Directory = 'hostpools' }
        @{ Directory = 'sharedServices' }
    ) {
        param($Directory)

        $source = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\uiFormDefinition.json") -Raw
        $source | Should -Match '"name": "kvNameTruncationWarning"'
        $source | Should -Match '"name": "secretsKeyVaultNameOverride"'
        $source | Should -Match '"name": "encryptionKeyVaultNameOverride"'
        $source | Should -Match 'checkNameAvailability'
        $form = $source | ConvertFrom-Json
        $warning = Get-TestFormElement -Elements $form.view.properties.steps.elements |
            Where-Object name -eq 'kvNameTruncationWarning'
        $warning.options.text | Should -Not -Match '^\['
        $warning.options.text | Should -Match 'Overlength generated names fail deployment; they are not truncated'
    }
}
