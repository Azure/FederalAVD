$repoRoot = Split-Path -Parent $PSScriptRoot

Describe 'Shared naming and module metadata contracts' {
    BeforeAll {
        $testOutputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('FederalAVD-NamingTests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testOutputDirectory -ErrorAction Stop | Out-Null
        $compiledModules = @{}
        $modulePaths = @{
            NamingFunctions = 'deployments\shared\modules\orchestration\naming\functions.bicep'
            HostPoolNaming = 'deployments\shared\modules\orchestration\naming\hostPool.bicep'
            ReplacerNaming = 'deployments\add-ons\sessionHostReplacer\modules\naming.bicep'
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
        $vectorsPath = Join-Path $repoRoot 'tests\fixtures\naming.bicepparam'
        $vectorsOutput = Join-Path $testOutputDirectory 'vectors.json'
        & az bicep build-params --file $vectorsPath --outfile $vectorsOutput
        if ($LASTEXITCODE -ne 0) {
            throw "Bicep naming-vector compilation failed: $vectorsPath"
        }
        $vectors = (Get-Content -LiteralPath $vectorsOutput -Raw | ConvertFrom-Json).parameters
        $policyVectorsOutput = Join-Path $testOutputDirectory 'policy-vectors.json'
        & az bicep build-params --file (Join-Path $repoRoot 'tests\fixtures\naming-policy.bicepparam') --outfile $policyVectorsOutput
        if ($LASTEXITCODE -ne 0) {
            throw 'Bicep policy-vector compilation failed.'
        }
        $policyVectors = (Get-Content -LiteralPath $policyVectorsOutput -Raw | ConvertFrom-Json).parameters
        $policy = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\data\namingPolicy.json') -Raw | ConvertFrom-Json
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
        @{ Name = 'emptyComponents'; Expected = '' }
        @{ Name = 'emptyValues'; Expected = '' }
        @{ Name = 'repeatedComponents'; Expected = 'rg-rg-desktop' }
        @{ Name = 'emptyDelimiter'; Expected = 'stavdimages' }
        @{ Name = 'customComponents'; Expected = 'org_prod_avd_desktop_eus_01_rg' }
        @{ Name = 'preservedWhitespace'; Expected = ' desktop ' }
        @{ Name = 'strippedSeparators'; Expected = 'Abcde' }
        @{ Name = 'sanitizedVault'; Expected = 'Ab-c-d-e' }
    ) {
        param($Name, $Expected)

        $vectors.$Name.value | Should Be $Expected
    }

    It 'describes the compiled module and every parameter and output for <Module>' -TestCases @(
        @{ Module = 'NamingFunctions' }
        @{ Module = 'HostPoolNaming' }
        @{ Module = 'ReplacerNaming' }
        @{ Module = 'FunctionApp' }
        @{ Module = 'HostingPlan' }
        @{ Module = 'FunctionDefinition' }
    ) {
        param($Module)

        $template = $compiledModules[$Module]
        [string]::IsNullOrWhiteSpace($template.metadata.name) | Should Be $false
        [string]::IsNullOrWhiteSpace($template.metadata.description) | Should Be $false
        foreach ($section in @('parameters', 'outputs')) {
            foreach ($property in $template.$section.PSObject.Properties) {
                [string]::IsNullOrWhiteSpace($property.Value.metadata.description) | Should Be $false
            }
        }
    }

    It 'documents every exported naming function and policy object' {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $modulePaths.NamingFunctions) -Raw
        $documentedExports = [regex]::Matches($source, "(?m)^@export\(\)\r?\n@description\('[^\r\n]+'\)\r?\n(?:func|var) (\w+)")
        @($documentedExports).Count | Should Be ([regex]::Matches($source, '(?m)^@export\(\)').Count)
        foreach ($name in @('buildCustomName', 'cnv', 'stripSeps', 'kvSanitize', 'resourceName', 'namingPolicy', 'osDiskNamePattern', 'imageStorageName', 'namePattern')) {
            @($documentedExports | Where-Object { $_.Groups[1].Value -eq $name }).Count | Should Be 1
        }
    }

    It 'keeps a scalar policy import below 1200 compiled bytes without the policy catalog' {
        (Get-Item -LiteralPath (Join-Path $testOutputDirectory 'ScalarPattern.json')).Length | Should BeLessThan 1200
        $variables = $compiledModules.ScalarPattern.variables | ConvertTo-Json -Depth 100 -Compress
        $variables | Should Match 'SHNAME-osdisk'
        $variables | Should Not Match '"defaults"\s*:|"resources"\s*:|"templateSpecs"\s*:'
    }

    It 'does not embed the policy catalog or generic naming functions in small consumers' {
        foreach ($name in @('DeploymentHelper', 'SessionHostVMs')) {
            $variables = $compiledModules[$name].variables | ConvertTo-Json -Depth 100 -Compress
            $variables | Should Not Match '"defaults"\s*:|"resources"\s*:|"templateSpecs"\s*:'
            @($compiledModules[$name].functions | Where-Object { $null -ne $_ }).Count | Should Be 0
        }
    }

    It 'preserves explicit helper identity names and uses a fixed deployment token for fallback' {
        $compiledModules.DeploymentHelper.variables.deploymentUserAssignedIdentityName |
            Should Be "[if(not(empty(parameters('userAssignedIdentityName'))), parameters('userAssignedIdentityName'), replace(parameters('userAssignedIdentityNameConv'), 'TOKEN', 'deployment'))]"
    }

    It 'imports shared naming without redeclaring helpers in <Path>' -TestCases @(
        @{ Path = 'deployments\shared\modules\orchestration\naming\hostPool.bicep'; Functions = @('resourceName', 'scopedUnique', 'deploymentVmName') }
        @{ Path = 'deployments\sharedServices\sharedServices.bicep'; Functions = @('resourceName', 'scopedUnique') }
        @{ Path = 'deployments\imageManagement\imageManagement.bicep'; Functions = @('resourceName', 'imageStorageName', 'validateImageStoragePrefix') }
        @{ Path = 'deployments\add-ons\sessionHostReplacer\modules\naming.bicep'; Functions = @('resourceName') }
    ) {
        param($Path, $Functions)

        $source = Get-Content -LiteralPath (Join-Path $repoRoot $Path) -Raw
        $source | Should Match "(?m)^import \{[^}]+\} from '[^']+/functions\.bicep'"
        foreach ($name in $Functions) {
            $source | Should Match "(?m)^import \{[^}\r\n]*\b$name\b"
        }
        $source | Should Not Match '(?m)^func (resolveComponent|buildCustomName|cnv|stripSeps|kvSanitize)\('
    }

    It 'preserves every resource-role recipe across thirteen convention profiles' {
        $legacy = Get-Content -LiteralPath (Join-Path $repoRoot 'tests\fixtures\naming-legacy-rules.json') -Raw | ConvertFrom-Json
        @(Compare-Object @($policy.resources.PSObject.Properties.Name) @($legacy.PSObject.Properties.Name)) | Should BeNullOrEmpty
        $policyVectors.roleParity.value.Count | Should Be (@($legacy.PSObject.Properties).Count * 13)
        foreach ($case in $policyVectors.roleParity.value) {
            if ($case.actual -cne $case.expected) {
                throw "Name changed in scenario $($case.scenario), role $($case.role): '$($case.actual)' != '$($case.expected)'."
            }
        }
    }

    It 'preserves image-storage budgets and both uniqueness recipes' {
        $policyVectors.storageParity.value.Count | Should Be 52
        foreach ($case in $policyVectors.storageParity.value) {
            $case.actual | Should Be $case.expected
            ($case.actual.Length -le 24) | Should Be $true
            $case.actual | Should Match '^[a-z0-9]+$'
        }
        foreach ($case in $policyVectors.seedParity.value) {
            $case.actual | Should Be $case.expected
        }
        $policyVectors.shortSeed.value | Should Be $policyVectors.expectedShortSeed.value
        $policyVectors.runId.value | Should Be $policyVectors.expectedRunId.value
    }

    It 'preserves internal purpose separators when an identifier is empty' {
        $policyVectors.emptyContextParity.value.Count | Should Be (13 * 9)
        foreach ($case in $policyVectors.emptyContextParity.value) {
            $case.actual | Should Be $case.expected
        }
    }

    It 'retains cloud location mappings and uses prefixed air-gapped region inputs' {
        foreach ($case in @($policyVectors.regionChecks.value | ForEach-Object { $_ })) {
            $case.actual | Should Be $case.expected
        }
        $policyVectors.commercialLocation.value | Should Be 'use'
        $policyVectors.governmentLocation.value | Should Be 'va'
    }

    It 'normalizes vault delimiters after convention assembly' {
        foreach ($role in @('secretsKeyVault', 'encryptionKeyVault')) {
            $purpose = if ($role -eq 'secretsKeyVault') { 'sec' } else { 'enc' }
            $cases = @($policyVectors.roleParity.value | Where-Object {
                $_.role -eq $role -and $_.scenario -in @(0, 2, 3, 4)
            })
            $cases.Count | Should Be 4
            foreach ($case in $cases) {
                $expected = if ($case.scenario -eq 4) {
                    "kvavd${purpose}abc123use2"
                } else {
                    "kv-avd-${purpose}-abc123-use2"
                }
                $case.actual | Should Be $expected
            }
        }
    }

    It 'uses configured delimiters consistently for vaults and permits delimiter-free storage' {
        $policyVectors.emptyDelimiter.value | Should Be 'kvavdsecabc123va'
        @($policyVectors.roleParity.value | Where-Object { $_.scenario -eq 4 -and $_.role -eq 'replacerStorage' }).Count | Should Be 1
        $policyVectors.partialCodes.value.keyVaults | Should Be 'vault'
        $policyVectors.partialCodes.value.workspaces | Should Be 'vdws'
        $policyVectors.resourceTypeFlags.value[1] | Should Be $false
        $policyVectors.resourceTypeFlags.value[10] | Should Be $true
        $policyVectors.resourceTypeFlags.value[11] | Should Be $true
    }

    It 'preserves temporary VM naming, endpoint placement and special legacy defaults' {
        $policyVectors.temporaryVm.value | Should Be $policyVectors.expectedTemporaryVm.value
        $policyVectors.temporaryVm.value.Length | Should Be 15
        $policyVectors.endpointFirst.value | Should Be 'pe-RESOURCE-SUBRESOURCE-VNETID'
        $policyVectors.endpointLast.value | Should Be 'RESOURCE-SUBRESOURCE-VNETID-pe-nic'
        $policyVectors.networkLast.value | Should Be 'avd-use2-ng'
        $policyVectors.quotaEmpty.value | Should Be 'aa-sqm-va'
        $policyVectors.patterns.value.disk | Should Be 'SHNAME-osdisk'
        $policyVectors.patterns.value.key | Should Be 'finance-shr-storage-cmk'
        $policyVectors.patterns.value.buildGroup | Should Be 'rg-dev-avd-image-builds-va-202610181234-abc123'
        $policyVectors.patterns.value.definition | Should Be 'vmid-MicrosoftWindowsDesktop-windows11-win1125h2avd'
    }

    It 'keeps portal snapshots synchronized without Azure access' {
        { & (Join-Path $repoRoot 'tools\Sync-NamingPolicy.ps1') -Check } | Should Not Throw
    }

    It 'propagates a changed policy through actual consumer expressions and generated portal defaults' {
        $copyRoot = Join-Path $testOutputDirectory 'propagation'
        $files = @(
            'deployments\shared\data\namingPolicy.json'
            'deployments\shared\data\resourceAbbreviations.json'
            'deployments\shared\data\locations.json'
            $modulePaths.NamingFunctions
            $modulePaths.HostPoolNaming
            $modulePaths.ReplacerNaming
            'tools\Sync-NamingPolicy.ps1'
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
        $copiedPolicyPath = Join-Path $copyRoot 'deployments\shared\data\namingPolicy.json'
        $changedPolicy = Get-Content -LiteralPath $copiedPolicyPath -Raw | ConvertFrom-Json
        $changedPolicy.defaults.workload = 'desktop'
        $changedPolicy.resources.operationsResourceGroup.purpose = @('ops')
        $changedPolicy.patterns.imageBuildVm = '{prefix}image-{unique}'
        $changedPolicy.patterns.osDisk = 'SHNAME-systemdisk'
        $changedPolicy.patterns.deploymentIdentityPurpose = 'unused-helper-purpose'
        [System.IO.File]::WriteAllText($copiedPolicyPath, (ConvertTo-Json -InputObject $changedPolicy -Depth 100))
        $sync = Join-Path $copyRoot 'tools\Sync-NamingPolicy.ps1'
        $staleDetected = $false
        try {
            & $sync -Check
        }
        catch {
            if ($_.Exception.Message -notlike 'Generated naming policy is stale.*') { throw }
            $staleDetected = $true
        }
        $staleDetected | Should Be $true
        & $sync | Out-Null
        { & $sync -Check } | Should Not Throw
        $defaultOutput = Join-Path $copyRoot 'hostpool-defaults.json'
        & az bicep build --file (Join-Path $copyRoot $modulePaths.HostPoolNaming) --outfile $defaultOutput
        if ($LASTEXITCODE -ne 0) { throw 'Generated naming defaults did not compile.' }
        $default = (Get-Content -LiteralPath $defaultOutput -Raw | ConvertFrom-Json).parameters.namingConvention.defaultValue
        $default.workload | Should Be 'desktop'
        ($default -is [string]) | Should Be $false
        foreach ($relative in $files | Where-Object { $_ -like '*uiFormDefinition.json' }) {
            $form = Get-Content -LiteralPath (Join-Path $copyRoot $relative) -Raw | ConvertFrom-Json
            $payload = ($form.view.properties.steps[0].elements | Where-Object name -eq 'federalAvdNamingPolicy').defaultValue | ConvertFrom-Json
            $payload.defaults.workload | Should Be 'desktop'
            $payload.purposePatterns.operationsResourceGroup | Should Be 'ops'
        }
        $lines = @(
            'using none'
            "import { namingPolicy, osDiskNamePattern, resourceName, namePattern } from '../../deployments/shared/modules/orchestration/naming/functions.bicep'"
            'var namingConvention = {}'
            "var cnv_vmsloc = 'va'"
            "var cnv_loc = 'va'"
            "var loc = 'va'"
            "var regionAbbr = 'va'"
            "var locationAbbreviation = 'va'"
            "var identifier = 'finance'"
            "var uniqueString = 'abc123'"
            "var uniqueStringUrt = 'abc123'"
            "var depPrefix = 'dev-'"
            "var buildRunId = 'abc123'"
            'var sessionHostCount = 2'
            "var sessionHostNames = ['host01', 'host02']"
            "var virtualMachineDiskNameConv = ''"
            "var userAssignedIdentityName = ''"
            "var userAssignedIdentityNameConv = 'uai-TOKEN-va'"
        )
        $consumers = @(
            @{ Name = 'hostPool'; Path = $modulePaths.HostPoolNaming; Variable = 'resourceGroupOperations' }
            @{ Name = 'sharedServices'; Path = 'deployments\sharedServices\sharedServices.bicep'; Variable = 'customRgName' }
            @{ Name = 'imageManagement'; Path = 'deployments\imageManagement\imageManagement.bicep'; Variable = 'customResourceGroupName' }
            @{ Name = 'replacer'; Path = $modulePaths.ReplacerNaming; Variable = 'functionAppName' }
            @{ Name = 'networking'; Path = 'deployments\networking\networking.bicep'; Variable = 'natGatewayName' }
            @{ Name = 'imageBuild'; Path = 'deployments\imageBuild\imageBuild.bicep'; Variable = 'imageVmName' }
            @{ Name = 'osDisks'; Path = $modulePaths.SessionHostVMs; Variable = 'osDiskNames' }
        )
        foreach ($consumer in $consumers) {
            $source = Get-Content -LiteralPath (Join-Path $repoRoot $consumer.Path) -Raw
            $match = [regex]::Matches($source, "(?m)^var $($consumer.Variable) = ([^\r\n]+)")
            $match.Count | Should Be 1
            $lines += "param $($consumer.Name) = $($match[0].Groups[1].Value)"
            if ($consumer.Name -eq 'osDisks') {
                $customDiskExpression = $match[0].Groups[1].Value -replace '\bvirtualMachineDiskNameConv\b', "'custom-SHNAME-disk'"
                $lines += "param customOsDisks = $customDiskExpression"
            }
        }
        $helperSource = Get-Content -LiteralPath (Join-Path $repoRoot $modulePaths.DeploymentHelper) -Raw
        $helperMatch = [regex]::Match($helperSource, '(?s)var deploymentUserAssignedIdentityName =\s*(.*?)\r?\nvar virtualMachineAdminUserName')
        $helperMatch.Success | Should Be $true
        $lines += "param helperDefault = $($helperMatch.Groups[1].Value)"
        $explicitHelperExpression = $helperMatch.Groups[1].Value -replace '\buserAssignedIdentityName\b', "'explicit-helper'"
        $lines += "param helperExplicit = $explicitHelperExpression"
        foreach ($name in @('avdAlerts', 'storageQuotaManager', 'updateRouteTableWithM365Routes')) {
            $source = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\add-ons\$name\main.bicep") -Raw
            $match = [regex]::Matches($source, "(?m)^var automationAccountName = !empty\(automationAccountNameOverride\)\r?\n  \? automationAccountNameOverride\r?\n  : ([^\r\n]+)")
            $match.Count | Should Be 1
            $lines += "param $name = $($match[0].Groups[1].Value)"
        }
        $fixture = Join-Path $copyRoot 'tests\fixtures\propagation.bicepparam'
        New-Item -ItemType Directory -Path (Split-Path -Parent $fixture) -Force | Out-Null
        [System.IO.File]::WriteAllLines($fixture, $lines)
        $output = Join-Path $copyRoot 'propagation.json'
        & az bicep build-params --file $fixture --outfile $output
        if ($LASTEXITCODE -ne 0) { throw 'Changed-policy propagation fixture did not compile.' }
        $names = (Get-Content -LiteralPath $output -Raw | ConvertFrom-Json).parameters
        $names.hostPool.value | Should Be 'rg-desktop-ops-va'
        $names.sharedServices.value | Should Be $names.hostPool.value
        $names.imageManagement.value | Should Be 'rg-desktop-finance-va'
        $names.replacer.value | Should Be 'fa-desktop-finance-shr-abc123-va'
        $names.networking.value | Should Be 'ng-desktop-va'
        $names.avdAlerts.value | Should Be 'aa-desktop-alerts-va'
        $names.storageQuotaManager.value | Should Be 'aa-sqm-finance-va'
        $names.updateRouteTableWithM365Routes.value | Should Be 'aa-urt-abc123-va'
        $names.imageBuild.value | Should Be 'dev-image-abc123'
        ($names.osDisks.value -join ',') | Should Be 'host01-systemdisk,host02-systemdisk'
        ($names.customOsDisks.value -join ',') | Should Be 'custom-host01-disk,custom-host02-disk'
        $names.helperDefault.value | Should Be 'uai-deployment-va'
        $names.helperExplicit.value | Should Be 'explicit-helper'
    }

    It 'keeps runtime-derived host-pool naming behind its deployment boundary' {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpools\hostpool.bicep') -Raw
        $source | Should Match "module naming '../shared/modules/orchestration/naming/hostPool.bicep'"
        $source | Should Match 'virtualMachinesRegion: virtualMachinesRegion'
        $source | Should Match 'var virtualMachinesRegion = vmVirtualNetwork.location'
    }

    It 'emits literal naming defaults rather than ARM variable references' {
        foreach ($name in @('HostPoolNaming', 'ReplacerNaming')) {
            $default = $compiledModules[$name].parameters.namingConvention.defaultValue
            ($default -is [string]) | Should Be $false
            $default.workload | Should Be $policy.defaults.workload
            $default.delimiter | Should Be $policy.defaults.delimiter
            ($default.components -join ',') | Should Be ($policy.defaults.components -join ',')
        }
    }

    It 'keeps detailed naming guidance in source comments rather than emitted parameter metadata' {
        $description = $compiledModules.HostPoolNaming.parameters.namingConvention.metadata.description
        $description | Should Not Match 'Component requirements:'
        $description | Should Not Match 'Key properties:'
        $source = Get-Content -LiteralPath (Join-Path $repoRoot $modulePaths.HostPoolNaming) -Raw
        $source | Should Match '(?m)^// Component requirements:'
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
        $source | Should Not Match '\b(namingPreview|defaultNamePreview|previewConvention|previewHostPool|previewKvSecrets|previewKvEncryption|previewRg|previewGallery|previewVmPatterns|previewNote)\b'
        [string]::IsNullOrWhiteSpace($form.view.outputs.parameters.$Output) | Should Be $false
    }

    It 'retains Key Vault truncation warnings and complete-name override validation in <Directory>' -TestCases @(
        @{ Directory = 'hostpools' }
        @{ Directory = 'sharedServices' }
    ) {
        param($Directory)

        $source = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\uiFormDefinition.json") -Raw
        $source | Should Match '"name": "kvNameTruncationWarning"'
        $source | Should Match '"name": "secretsKeyVaultNameOverride"'
        $source | Should Match '"name": "encryptionKeyVaultNameOverride"'
        $source | Should Match 'checkNameAvailability'
    }
}
