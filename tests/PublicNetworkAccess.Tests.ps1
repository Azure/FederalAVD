BeforeDiscovery {
    $formCases = @(
        @{ Directory = 'sharedServices'; Entry = 'sharedServices'; Step = 'operations'; Services = @('keyVault') }
        @{ Directory = 'imageManagement'; Entry = 'imageManagement'; Step = 'storageAccounts'; Services = @('storage') }
        @{ Directory = 'hostpools'; Entry = 'hostpool'; Step = 'zeroTrust'; Services = @('storage', 'keyVault') }
        @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool'; Step = 'zeroTrust'; Services = @('storage', 'keyVault') }
        @{ Directory = 'add-ons\fslogixStorage'; Entry = 'main'; Step = 'zeroTrust'; Services = @('storage') }
        @{ Directory = 'add-ons\sessionHostReplacer'; Entry = 'main'; Step = 'infrastructure'; Services = @('storage', 'functionApp') }
        @{ Directory = 'add-ons\imageValidation'; Entry = 'main'; Step = 'functionApp'; Services = @('storage', 'keyVault', 'functionApp') }
        @{ Directory = 'add-ons\fslogixProfileManagement'; Entry = 'main'; Step = 'functionApp'; Services = @('storage', 'keyVault', 'functionApp') }
        @{ Directory = 'hostpoolPoc'; Entry = 'hostpoolPoc'; Step = 'options'; Services = @('storage') }
    )
    $matrixCases = @(0..31 | ForEach-Object {
        @{
            Index = $_
            Mode = @('Auto', 'Disabled', 'EnabledWithRestrictions', 'Enabled')[[int][Math]::Floor($_ / 8)]
            PrivateEndpoint = ($_ % 8 -ge 4)
            HasIPs = ($_ % 4 -ge 2)
            HasSubnets = ($_ % 2 -eq 1)
        }
    })
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $formCases = @(
        @{ Directory = 'sharedServices'; Entry = 'sharedServices'; Step = 'operations'; Services = @('keyVault') }
        @{ Directory = 'imageManagement'; Entry = 'imageManagement'; Step = 'storageAccounts'; Services = @('storage') }
        @{ Directory = 'hostpools'; Entry = 'hostpool'; Step = 'zeroTrust'; Services = @('storage', 'keyVault') }
        @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool'; Step = 'zeroTrust'; Services = @('storage', 'keyVault') }
        @{ Directory = 'add-ons\fslogixStorage'; Entry = 'main'; Step = 'zeroTrust'; Services = @('storage') }
        @{ Directory = 'add-ons\sessionHostReplacer'; Entry = 'main'; Step = 'infrastructure'; Services = @('storage', 'functionApp') }
        @{ Directory = 'add-ons\imageValidation'; Entry = 'main'; Step = 'functionApp'; Services = @('storage', 'keyVault', 'functionApp') }
        @{ Directory = 'add-ons\fslogixProfileManagement'; Entry = 'main'; Step = 'functionApp'; Services = @('storage', 'keyVault', 'functionApp') }
        @{ Directory = 'hostpoolPoc'; Entry = 'hostpoolPoc'; Step = 'options'; Services = @('storage') }
    )
    $matrixCases = @(0..31 | ForEach-Object {
        @{
            Index = $_
            Mode = @('Auto', 'Disabled', 'EnabledWithRestrictions', 'Enabled')[[int][Math]::Floor($_ / 8)]
            PrivateEndpoint = ($_ % 8 -ge 4)
            HasIPs = ($_ % 4 -ge 2)
            HasSubnets = ($_ % 2 -eq 1)
        }
    })

}

Describe 'Service-family public-access Portal contracts' {
    It 'exposes independent explicit modes, allowlists, and valid template outputs in <Directory>' -TestCases $formCases {
        param($Directory, $Entry, $Step, $Services)
        $directoryPath = Join-Path $repoRoot "deployments\$Directory"
        $form = Get-Content -LiteralPath (Join-Path $directoryPath 'uiFormDefinition.json') -Raw | ConvertFrom-Json -AsHashtable
        $template = Get-Content -LiteralPath (Join-Path $directoryPath "$Entry.json") -Raw | ConvertFrom-Json -AsHashtable
        $stepControl = $form.view.properties.steps | Where-Object name -eq $Step
        foreach ($service in $Services) {
            $public = $stepControl.elements | Where-Object name -eq "${service}PublicNetworking"
            $allowed = $stepControl.elements | Where-Object name -eq "${service}ServiceEndpointAccess"
            $control = $public.elements | Where-Object name -eq "${service}PublicNetworkAccess"
            $control.type | Should -Be 'Microsoft.Common.DropDown'
            ($control.constraints.allowedValues.value -join ',') | Should -Be 'Disabled,EnabledWithRestrictions,Enabled'
            ($control.constraints.allowedValues.label -join ',') | Should -Be 'Disabled,Enabled with restrictions,Enabled'
            $control.defaultValue | Should -Be 'Disabled'
            $control.constraints.required | Should -BeTrue
            if ($Directory -in @('hostpools', 'automatedHostPools', 'imageManagement', 'sharedServices', 'add-ons\sessionHostReplacer')) {
                $paas = $template.definitions[$template.parameters.paasNetworking.'$ref'.Replace('#/definitions/', '')]
                $family = $template.definitions[$paas.properties[$service].'$ref'.Replace('#/definitions/', '')]
                $family.properties.permittedIPs.type | Should -Be 'array'
                $form.view.outputs.parameters.ContainsKey('paasNetworking') | Should -BeTrue
                $form.view.outputs.parameters.ContainsKey("${service}PublicNetworkAccess") | Should -BeFalse
                $form.view.outputs.parameters.ContainsKey("${service}PermittedIPs") | Should -BeFalse
            } else {
                $template.parameters["${service}PublicNetworkAccess"].defaultValue | Should -Be 'Disabled'
                $template.parameters["${service}PermittedIPs"].type | Should -Be 'array'
            }
            $grid = $allowed.elements | Where-Object name -eq "${service}PermittedIPs"
            if ($Directory -in @('hostpools', 'automatedHostPools', 'imageManagement', 'sharedServices', 'add-ons\sessionHostReplacer')) {
                $grid.visible | Should -Match 'Restricted|EnabledWithRestrictions'
            } else {
                $grid.visible | Should -Be "[equals(steps('$Step').${service}PublicNetworking.${service}PublicNetworkAccess, 'EnabledWithRestrictions')]"
            }
            $grid.ContainsKey('defaultValue') | Should -BeFalse
            $form.view.outputs.parameters["${service}PermittedIPs"] | Should -Not -Match 'PublicNetworkAccess|PrivateEndpoint'
            $form.view.outputs.parameters["${service}ServiceEndpointSubnetResourceIds"] | Should -Not -Match 'PublicNetworkAccess|PrivateEndpoint'
            $modeRef = "steps('$Step').${service}PublicNetworking.${service}PublicNetworkAccess"
            if ($Directory -in @('hostpools', 'automatedHostPools', 'imageManagement', 'sharedServices', 'add-ons\sessionHostReplacer')) {
                $modeRef = "if(equals(steps('$Step').paasConnectivity.scenario, 'Custom'), $modeRef, if(equals(steps('$Step').paasConnectivity.scenario, 'Restricted'), 'EnabledWithRestrictions', 'Disabled'))"
            }
            foreach ($mode in @('Disabled', 'EnabledWithRestrictions', 'Enabled')) {
                $text = $public.elements | Where-Object name -eq "publicAccess${mode}Info"
                $expectedType = if ($Directory -in @('hostpools', 'automatedHostPools', 'imageManagement', 'sharedServices', 'add-ons\sessionHostReplacer') -and $mode -eq 'Enabled') {
                    'Microsoft.Common.InfoBox'
                } else {
                    'Microsoft.Common.TextBlock'
                }
                $text.type | Should -Be $expectedType
                $text.visible | Should -Be "[equals($modeRef, '$mode')]"
                $text.options.text | Should -Not -Match '^\['
                $text.options.text.Length | Should -BeLessThan 180
            }
        }
        $template.parameters.ContainsKey('paasPublicNetworkAccess') | Should -BeFalse
        $template.parameters.ContainsKey('permittedIPs') | Should -BeFalse
        foreach ($name in $form.view.outputs.parameters.Keys) {
            $template.parameters.ContainsKey($name) | Should -BeTrue -Because "$name must be an entry-template parameter in $Directory"
        }
    }

    It 'creates Image Management private endpoints independently of public access' {
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\imageManagement\imageManagement.json') -Raw | ConvertFrom-Json
        foreach ($name in @('assetsStoragePrivateEndpoint', 'logsStoragePrivateEndpoint')) {
            $template.resources.$name.condition | Should -Match "variables\('storagePrivateEndpoint'\)"
            $template.resources.$name.condition | Should -Not -Match 'PublicNetworkAccess|storageNetworkAccess'
        }
    }

    It 'routes automated-host-pool IP allowlists independently without merging families' {
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.json') -Raw | ConvertFrom-Json
        $template.resources.sharedKeyVaults.properties.parameters.keyVaultPermittedIPs.value | Should -Be "[variables('keyVaultPermittedIPs')]"
        $template.resources.fslogixStorage.properties.parameters.storagePermittedIPs.value | Should -Be "[variables('storagePermittedIPs')]"
        $template.parameters.PSObject.Properties.Name | Should -Not -Contain 'fslogixPermittedIPs'
    }

    It 'keeps AVD connections on the host-pool resource subnet in both entry templates' {
        foreach ($case in @(
            @{ Directory = 'hostpools'; Entry = 'hostpool' }
            @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool' }
        )) {
            $directoryPath = Join-Path $repoRoot "deployments\$($case.Directory)"
            $template = Get-Content -LiteralPath (Join-Path $directoryPath "$($case.Entry).json") -Raw | ConvertFrom-Json
            $template.parameters.PSObject.Properties.Name | Should -Not -Contain 'hostPoolPrivateEndpointSubnetResourceId'
            $template.resources.controlPlane.properties.parameters.hostPoolPrivateEndpointSubnetResourceId.value |
                Should -BeExactly "[variables('hostPoolResourcesPrivateEndpointSubnetResourceId')]"
        }
    }
}

Describe 'Service-family compliance parameter evidence' {
    BeforeAll {
        $evidenceParameters = @{}
        foreach ($service in @('storage', 'keyVault', 'functionApp')) {
            $evidenceParameters["${service}PublicNetworkAccess"] = @{ value = 'Disabled' }
            $evidenceParameters["${service}PrivateEndpoint"] = @{ value = $true }
            $evidenceParameters["${service}PrivateEndpointSubnetResourceId"] = @{ value = '/private/endpoint-subnet' }
            $evidenceParameters["${service}PermittedIPs"] = @{ value = @() }
            $evidenceParameters["${service}ServiceEndpointSubnetResourceIds"] = @{ value = @('/allowed/client-subnet') }
        }
        $evidenceFixture = Join-Path $TestDrive 'network-evidence.parameters.json'
        $evidenceCsv = Join-Path $TestDrive 'network-evidence.csv'
        [IO.File]::WriteAllText($evidenceFixture, (@{ parameters = $evidenceParameters } | ConvertTo-Json -Depth 10))
    }

    It 'collects every independent networking input without implying deployed compliance' {
        & (Join-Path $repoRoot '.github\skills\federalavd-compliance-review\scripts\Get-ComplianceParameterEvidence.ps1') `
            -ParameterPath $evidenceFixture -CsvPath $evidenceCsv | Out-Null
        $evidence = @(Import-Csv -LiteralPath $evidenceCsv)
        $evidence.Count | Should -Be 15
        foreach ($name in $evidenceParameters.Keys) {
            @($evidence | Where-Object Parameter -eq $name).Count | Should -Be 1
        }
        ($evidence | Where-Object Parameter -eq storagePermittedIPs).Value | Should -Be '[]'
        ($evidence | Where-Object Parameter -eq storageServiceEndpointSubnetResourceIds).Value | Should -Be '["/allowed/client-subnet"]'
        ($evidence | Where-Object Parameter -eq keyVaultPublicNetworkAccess).Value | Should -Be 'Disabled'
    }

    It 'collects the explicitly scoped Backup and disk endpoint inputs' {
        $parameters = @{
            deployBackupAndDiskPrivateEndpoints = @{ value = $true }
            deployBackupPrivateEndpoints = @{ value = $false }
            backupPrivateEndpointSubnetResourceId = @{ value = '/backup/endpoint-subnet' }
            sharedResourcesPrivateEndpointSubnetResourceId = @{ value = '/shared/endpoint-subnet' }
            hostPoolResourcesPrivateEndpointSubnetResourceId = @{ value = '/host-pool/endpoint-subnet' }
        }
        $fixture = Join-Path $TestDrive 'backup-network-evidence.parameters.json'
        $csv = Join-Path $TestDrive 'backup-network-evidence.csv'
        [IO.File]::WriteAllText($fixture, (@{ parameters = $parameters } | ConvertTo-Json -Depth 5))
        & (Join-Path $repoRoot '.github\skills\federalavd-compliance-review\scripts\Get-ComplianceParameterEvidence.ps1') `
            -ParameterPath $fixture -CsvPath $csv | Out-Null
        $evidence = @(Import-Csv -LiteralPath $csv)
        $evidence.Count | Should -Be 5
        ($evidence | Where-Object Parameter -eq deployBackupAndDiskPrivateEndpoints).Value | Should -Be 'True'
        ($evidence | Where-Object Parameter -eq deployBackupPrivateEndpoints).Value | Should -Be 'False'
        ($evidence | Where-Object Parameter -eq backupPrivateEndpointSubnetResourceId).Value | Should -Be '/backup/endpoint-subnet'
        ($evidence | Where-Object Parameter -eq sharedResourcesPrivateEndpointSubnetResourceId).Value | Should -Be '/shared/endpoint-subnet'
        ($evidence | Where-Object Parameter -eq hostPoolResourcesPrivateEndpointSubnetResourceId).Value | Should -Be '/host-pool/endpoint-subnet'
    }

    It 'records typed networking objects without losing false overrides or independent allowlists' {
        $parameters = @{
            paasNetworking = @{ value = @{
                publicNetworkAccess = 'Disabled'
                privateEndpoint = $true
                storage = @{ privateEndpoint = $false; permittedIPs = @('203.0.113.0/24'); serviceEndpointSubnetResourceIds = @('/storage-source') }
                keyVault = @{ permittedIPs = @('198.51.100.0/24'); serviceEndpointSubnetResourceIds = @('/vault-source') }
            } }
            privateEndpointSubnetResourceIds = @{ value = @{ sharedResources = '/shared-placement'; hostPoolResources = '/host-placement' } }
            privateDnsZoneResourceIds = @{ value = @{ file = '/file-zone'; vault = '/vault-zone' } }
        }
        $fixture = Join-Path $TestDrive 'typed-network-evidence.parameters.json'
        $csv = Join-Path $TestDrive 'typed-network-evidence.csv'
        [IO.File]::WriteAllText($fixture, (@{ parameters = $parameters } | ConvertTo-Json -Depth 10))
        & (Join-Path $repoRoot '.github\skills\federalavd-compliance-review\scripts\Get-ComplianceParameterEvidence.ps1') `
            -ParameterPath $fixture -CsvPath $csv | Out-Null
        $evidence = @(Import-Csv -LiteralPath $csv)
        $evidence.Count | Should -Be 3
        $networking = ($evidence | Where-Object Parameter -eq paasNetworking).Value | ConvertFrom-Json
        $networking.storage.privateEndpoint | Should -Be $false
        $networking.storage.permittedIPs | Should -Be @('203.0.113.0/24')
        $networking.keyVault.permittedIPs | Should -Be @('198.51.100.0/24')
        $networking.storage.serviceEndpointSubnetResourceIds | Should -Be @('/storage-source')
        $networking.keyVault.serviceEndpointSubnetResourceIds | Should -Be @('/vault-source')
    }
}

Describe 'Expanded service public-access matrix' {
    BeforeAll {
        $testOutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-PublicNetwork-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testOutputDirectory -ErrorAction Stop | Out-Null
        $imageJson = Join-Path $testOutputDirectory 'image-network-slice.json'
        & az bicep build --file (Join-Path $repoRoot 'deployments\imageManagement\imageManagement.bicep') --outfile $imageJson
        if ($LASTEXITCODE -ne 0) { throw 'Image Management compilation failed.' }
        $image = Get-Content -LiteralPath $imageJson -Raw | ConvertFrom-Json -AsHashtable

        # Snapshot expansion rejects the existing recursive naming helpers. Isolate the actual
        # compiled storage modules and networking input graph from naming and other dependencies.
        $networkVariables = @{}
        foreach ($name in @(
            'effectiveStoragePermittedIPs', 'storageSubnetIds', 'networkAccess', 'storageNetworkAcls',
            'storageCreated', 'resolvedNetworking', 'storagePublicNetworkAccess', 'storagePrivateEndpoint',
            'storagePermittedIPs', 'storageServiceEndpointSubnetResourceIds'
        )) {
            if (-not $image.variables.ContainsKey($name)) { throw "Missing compiled networking variable: $name" }
            $networkVariables[$name] = $image.variables[$name]
        }
        $networkVariables.copy = @($image.variables.copy | Where-Object { $_.name -in @('storageIpRules', 'storageVnetRules') })
        if ($networkVariables.copy.Count -ne 2) { throw 'Missing compiled IP/subnet rule loops.' }
        $image.variables = $networkVariables
        $compiledFunctions = @{}
        foreach ($namespace in $image.functions) {
            foreach ($member in $namespace.members.GetEnumerator()) {
                $compiledFunctions["$($namespace.namespace).$($member.Key)"] = $member.Value
            }
        }
        $pendingFunctions = [Collections.Generic.Queue[string]]::new()
        $neededFunctions = [Collections.Generic.HashSet[string]]::new()
        $functionCalls = '[A-Za-z_][A-Za-z0-9_.]*(?=\()'
        foreach ($call in [regex]::Matches(($networkVariables | ConvertTo-Json -Depth 100), $functionCalls)) {
            if ($compiledFunctions.ContainsKey($call.Value)) { $pendingFunctions.Enqueue($call.Value) }
        }
        while ($pendingFunctions.Count) {
            $name = $pendingFunctions.Dequeue()
            if (-not $neededFunctions.Add($name)) { continue }
            foreach ($call in [regex]::Matches(($compiledFunctions[$name] | ConvertTo-Json -Depth 100), $functionCalls)) {
                if ($compiledFunctions.ContainsKey($call.Value)) { $pendingFunctions.Enqueue($call.Value) }
            }
        }
        if (-not $neededFunctions.Count) { throw 'Cannot locate compiled networking functions.' }
        $image.functions = @(
            foreach ($namespace in $image.functions) {
                $members = @{}
                foreach ($member in $namespace.members.GetEnumerator()) {
                    if ($neededFunctions.Contains("$($namespace.namespace).$($member.Key)")) {
                        $members[$member.Key] = $member.Value
                    }
                }
                if ($members.Count) { @{ namespace = $namespace.namespace; members = $members } }
            }
        )
        $storageModules = @{}
        foreach ($name in @('assetsStorageAccount', 'logsStorageAccount')) {
            $module = $image.resources[$name]
            $module.Remove('dependsOn')
            $module.Remove('condition')
            $module.name = $name
            $module.resourceGroup = 'network-tests'
            $networkParameters = @{}
            foreach ($parameter in @('networkAcls', 'publicNetworkAccess', 'tags')) {
                $networkParameters[$parameter] = $module.properties.parameters[$parameter]
            }
            $networkParameters.name = @{ value = "[concat('$name', parameters('namingConvention').workload)]" }
            $networkParameters.location = @{ value = "[parameters('location')]" }
            $module.properties.parameters = $networkParameters
            $storageModules[$name] = $module
        }
        $image.resources = $storageModules
        $image.Remove('outputs')
        [IO.File]::WriteAllText($imageJson, ($image | ConvertTo-Json -Depth 100))

        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'tests\fixtures\public-network-access.bicep') -Raw
        $source = $source.Replace("'../../deployments/imageManagement/imageManagement.bicep'", "'./image-network-slice.json'")
        $source = [regex]::Replace($source, "'../../deployments/([^']+)'", {
            param($match)
            $target = Join-Path $repoRoot ('deployments\' + $match.Groups[1].Value.Replace('/', '\'))
            "'" + [IO.Path]::GetRelativePath($testOutputDirectory, $target).Replace('\', '/') + "'"
        })
        [IO.File]::WriteAllText((Join-Path $testOutputDirectory 'public-network-access.bicep'), $source)
        $parameterPath = Join-Path $testOutputDirectory 'public-network-access.bicepparam'
        Copy-Item -LiteralPath (Join-Path $repoRoot 'tests\fixtures\public-network-access.bicepparam') -Destination $parameterPath
        $bicepCommand = Join-Path $HOME ('.azure\bin\bicep' + $(if ($IsWindows) { '.exe' } else { '' }))
        if (-not (Test-Path -LiteralPath $bicepCommand)) { throw "Bicep CLI not found: $bicepCommand" }
        & $bicepCommand snapshot $parameterPath --mode Overwrite `
            --subscription-id 00000000-1111-2222-3333-444444444444 `
            --tenant-id 11111111-2222-3333-4444-555555555555 `
            --location eastus --deployment-name network-tests
        if ($LASTEXITCODE -ne 0) { throw 'Public-network resource snapshot failed.' }
        $snapshotFiles = @(Get-ChildItem -LiteralPath $testOutputDirectory -Filter '*.snapshot.json' -File)
        if ($snapshotFiles.Count -ne 1) { throw 'Expected one deployment snapshot.' }
        $snapshot = Get-Content -LiteralPath $snapshotFiles[0].FullName -Raw | ConvertFrom-Json
        $resources = @($snapshot.predictedResources)
        if ($resources.Count -lt 100) { throw "Missing expanded resources. Snapshot fields: $($snapshot.PSObject.Properties.Name -join ', ')" }
    }

    AfterAll {
        if (Test-Path -LiteralPath $testOutputDirectory) {
            Get-ChildItem -LiteralPath $testOutputDirectory -File | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -ErrorAction Stop
            }
            Remove-Item -LiteralPath $testOutputDirectory -ErrorAction Stop
        }
    }

    It 'resolves storage/vault access for case <Index>: <Mode>, PE=<PrivateEndpoint>, IP=<HasIPs>, subnet=<HasSubnets>' -TestCases $matrixCases {
        param($Index, $Mode, $PrivateEndpoint, $HasIPs, $HasSubnets)

        $services = @('images', 'vaults', 'files', 'apps')
        foreach ($service in $services) {
            $hasRules = $HasIPs -or $HasSubnets
            $expectedPublic = if ($Mode -eq 'Disabled' -or ($Mode -eq 'Auto' -and $PrivateEndpoint -and -not $hasRules)) { 'Disabled' } else { 'Enabled' }
            $expectedDefault = if ($Mode -eq 'Enabled' -or ($Mode -eq 'Auto' -and -not $PrivateEndpoint -and -not $hasRules)) { 'Allow' } else { 'Deny' }
            $matchingResources = @($resources | Where-Object {
                $_.tags.networkCase -eq "$service$Index" -and $_.type -in @('Microsoft.Storage/storageAccounts', 'Microsoft.KeyVault/vaults')
            })
            $invalidImageIntent = $service -eq 'images' -and $Mode -eq 'EnabledWithRestrictions' -and
                -not $PrivateEndpoint -and -not $hasRules
            $matchingResources.Count | Should -Be $(if ($invalidImageIntent) { 0 } elseif ($service -in @('images', 'vaults')) { 2 } else { 1 })
            foreach ($resource in $matchingResources) {
                $resource.properties.publicNetworkAccess | Should -Be $expectedPublic
                $resource.properties.networkAcls.defaultAction | Should -Be $expectedDefault
                $resource.properties.networkAcls.bypass | Should -Be 'AzureServices'
                $ipRules = @($resource.properties.networkAcls.ipRules)
                $ipRules.Count | Should -Be $(if (-not $HasIPs) { 0 } elseif ($service -eq 'apps') { 3 } else { 1 })
                if ($HasIPs) {
                    $ipRules[0].value | Should -Be '203.0.113.10'
                    if ($service -eq 'apps') {
                        $ipRules[1].value | Should -Be '198.51.100.0/24'
                        $ipRules[2].value | Should -Be '192.0.2.10'
                    }
                }
                $expectedSubnets = if ($HasSubnets) { 2 } else { 0 }
                @($resource.properties.networkAcls.virtualNetworkRules).Count | Should -Be $expectedSubnets
                if ($HasSubnets) {
                    @($resource.properties.networkAcls.virtualNetworkRules.id) | Should -Contain '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/other-network/providers/microsoft.network/virtualnetworks/other/subnets/clients'
                    if ($service -eq 'vaults') {
                        foreach ($rule in $resource.properties.networkAcls.virtualNetworkRules) {
                            $rule.ignoreMissingVnetServiceEndpoint | Should -Be $false
                        }
                    }
                }
            }
        }
    }

    It 'rejects Image Management restricted connectivity without an endpoint or approved sources' {
        $negativePath = Join-Path $testOutputDirectory 'invalid-image-network.bicepparam'
        [IO.File]::WriteAllText($negativePath, @'
using './image-network-slice.json'
param paasNetworking = {
  storage: {
    publicNetworkAccess: 'EnabledWithRestrictions'
    privateEndpoint: false
  }
}
param namingConvention = { workload: 'invalidnetwork' }
'@)
        $output = (& $bicepCommand snapshot $negativePath --mode Overwrite `
            --subscription-id 00000000-1111-2222-3333-444444444444 `
            --tenant-id 11111111-2222-3333-4444-555555555555 `
            --location eastus --deployment-name network-tests 2>&1 | Out-String)
        $LASTEXITCODE | Should -Not -Be 0
        $output | Should -Match 'Storage restricted public connectivity requires permittedIPs, serviceEndpointSubnetResourceIds, or a private endpoint'
    }

    It 'pairs Function App storage DNS groups with their private endpoints for case <Index>' -TestCases $matrixCases {
        param($Index, $PrivateEndpoint)

        $groups = @($resources | Where-Object {
            $_.type -eq 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' -and
            $_.name -like "pe-functionstorage${Index}-*/default"
        })
        $services = if ($Index % 4 -eq 0) { @('blob', 'queue', 'table') } else { @('blob', 'table') }
        $groups.Count | Should -Be $(if ($PrivateEndpoint) { $services.Count } else { 0 })
        if ($PrivateEndpoint) {
            foreach ($service in $services) {
                $endpointName = "pe-functionstorage${Index}-$service"
                @($resources | Where-Object {
                    $_.type -eq 'Microsoft.Network/privateEndpoints' -and $_.name -eq $endpointName
                }).Count | Should -Be 1
                $group = @($groups | Where-Object { $_.name -eq "$endpointName/default" })
                $group.Count | Should -Be 1
                $group[0].properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId |
                    Should -Be "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/network-tests/providers/Microsoft.Network/privateDnsZones/privatelink.$service.example.test"
            }
        }
    }

    It 'keeps inbound and runtime-storage subnet authorization independent in case <Index>' -TestCases @(
        @{ Index = 32; StorageRules = 2; InboundRules = 0; StorageDefault = 'Deny'; InboundDefault = 'Allow' }
        @{ Index = 33; StorageRules = 0; InboundRules = 2; StorageDefault = 'Allow'; InboundDefault = 'Deny' }
    ) {
        param($Index, $StorageRules, $InboundRules, $StorageDefault, $InboundDefault)
        $storage = @($resources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' -and $_.tags.networkCase -eq "apps$Index" })
        $app = @($resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' -and $_.tags.networkCase -eq "apps$Index" })
        $storage.Count | Should -Be 1
        $app.Count | Should -Be 1
        $storage[0].properties.networkAcls.defaultAction | Should -Be $StorageDefault
        @($storage[0].properties.networkAcls.virtualNetworkRules).Count | Should -Be $StorageRules
        $app[0].properties.siteConfig.ipSecurityRestrictionsDefaultAction | Should -Be $InboundDefault
        @($app[0].properties.siteConfig.ipSecurityRestrictions | Where-Object vnetSubnetResourceId).Count | Should -Be $InboundRules
    }

    It 'resolves Function App and SCM rules for case <Index>: <Mode>, PE=<PrivateEndpoint>, IP=<HasIPs>, subnet=<HasSubnets>' -TestCases $matrixCases {
        param($Index, $Mode, $PrivateEndpoint, $HasIPs, $HasSubnets)

        $matchingResources = @($resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' -and $_.tags.networkCase -eq "apps$Index" })
        $matchingResources.Count | Should -Be 1
        $app = $matchingResources[0]
        $expectedPublic = if ($Mode -eq 'Disabled' -or ($Mode -eq 'Auto' -and $PrivateEndpoint -and -not ($HasIPs -or $HasSubnets))) { 'Disabled' } else { 'Enabled' }
        $restrict = $Mode -in @('Disabled', 'EnabledWithRestrictions') -or ($Mode -eq 'Auto' -and ($PrivateEndpoint -or $HasIPs -or $HasSubnets))
        $expectedDefault = if ($restrict) { 'Deny' } else { 'Allow' }
        $app.properties.publicNetworkAccess | Should -Be $expectedPublic
        $site = $app.properties.siteConfig
        $site.publicNetworkAccess | Should -Be $expectedPublic
        $site.ipSecurityRestrictionsDefaultAction | Should -Be $expectedDefault
        $site.scmIpSecurityRestrictionsDefaultAction | Should -Be $expectedDefault
        $site.scmIpSecurityRestrictionsUseMain | Should -Be $true
        $rules = @($site.ipSecurityRestrictions | Where-Object { $null -ne $_ })
        $subnetCount = if ($HasSubnets) { 2 } else { 0 }
        @($rules | Where-Object { $_.vnetSubnetResourceId }).Count | Should -Be $subnetCount
        $rules.Count | Should -Be ($(if ($HasIPs) { 3 } else { 0 }) + $subnetCount + $(if ($restrict) { 2 } elseif ($HasIPs -or $HasSubnets) { 1 } else { 0 }))
        @($rules | Where-Object { $_.action -eq 'Deny' }).Count | Should -Be $(if ($restrict) { 1 } else { 0 })
        @($site.scmIpSecurityRestrictions | Where-Object { $_.action -eq 'Deny' }).Count | Should -Be $(if ($restrict) { 1 } else { 0 })
        if ($restrict -or $HasIPs -or $HasSubnets) {
            ($rules | Where-Object { $_.name -eq 'AzureCloud' }).ipAddress | Should -Be 'AzureCloud'
            ($rules | Where-Object { $_.name -eq 'AzureCloud' }).tag | Should -Be 'ServiceTag'
        }
        if ($HasIPs) {
            ($rules | Where-Object { $_.name -eq 'PermittedIP-0' }).ipAddress | Should -Be '203.0.113.10/32'
            ($rules | Where-Object { $_.name -eq 'PermittedIP-1' }).ipAddress | Should -Be '198.51.100.0/24'
            ($rules | Where-Object { $_.name -eq 'PermittedIP-2' }).ipAddress | Should -Be '192.0.2.10/32'
        }
    }

    It 'creates private endpoints only from their own flag in case <Index>: <Mode>, PE=<PrivateEndpoint>' -TestCases $matrixCases {
        param($Index, $Mode, $PrivateEndpoint)

        $targets = @(
            @{ Suffix = "/vaults/kv-secrets-$Index"; Count = 1 }
            @{ Suffix = "/vaults/kv-encryption-$Index"; Count = 1 }
            @{ Suffix = "/storageAccounts/files$($Index)01"; Count = 1 }
            @{ Suffix = "/storageAccounts/functionstorage$Index"; Count = $(if ($Index % 4 -eq 0) { 3 } else { 2 }) }
            @{ Suffix = "/sites/function-$Index"; Count = 1 }
        )
        foreach ($target in $targets) {
            $endpoints = @($resources | Where-Object {
                $_.type -eq 'Microsoft.Network/privateEndpoints' -and
                $_.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId.EndsWith($target.Suffix)
            })
            $endpoints.Count | Should -Be $(if ($PrivateEndpoint) { $target.Count } else { 0 })
        }
    }
}
