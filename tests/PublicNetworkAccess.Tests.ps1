$repoRoot = Split-Path -Parent $PSScriptRoot
$formCases = @(
    @{ Directory = 'sharedServices'; Entry = 'sharedServices' }
    @{ Directory = 'imageManagement'; Entry = 'imageManagement' }
    @{ Directory = 'hostpools'; Entry = 'hostpool' }
    @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool' }
    @{ Directory = 'add-ons\fslogixStorage'; Entry = 'main' }
    @{ Directory = 'add-ons\sessionHostReplacer'; Entry = 'main' }
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

function Get-PublicAccessControlReference($Directory) {
    switch ($Directory) {
        'sharedServices' { "steps('operations').permittedIPsSection.paasPublicNetworkAccess" }
        'imageManagement' { "steps('storageAccounts').storageSettings.paasPublicNetworkAccess" }
        'hostpools' { "steps('zeroTrust').permittedIPsSection.paasPublicNetworkAccess" }
        'automatedHostPools' { "steps('zeroTrust').permittedIPsSection.paasPublicNetworkAccess" }
        'add-ons\fslogixStorage' { "steps('zeroTrust').privateNetworking.paasPublicNetworkAccess" }
        'add-ons\sessionHostReplacer' { "steps('infrastructure').paasPublicNetworkAccess" }
        default { throw "No public-access control reference defined for '$Directory'." }
    }
}

Describe 'PaaS public-access Portal contracts' {
    It 'exposes three explicit choices and maps the mode in <Directory>' -TestCases $formCases {
        param($Directory, $Entry)

        $directoryPath = Join-Path $repoRoot "deployments\$Directory"
        $form = Get-Content -LiteralPath (Join-Path $directoryPath 'uiFormDefinition.json') -Raw | ConvertFrom-Json
        $template = Get-Content -LiteralPath (Join-Path $directoryPath "$Entry.json") -Raw | ConvertFrom-Json
        function Find-NetworkControl($Elements) {
            foreach ($element in $Elements) {
                if ($element.name -eq 'paasPublicNetworkAccess') { $element }
                if ($element.elements) { Find-NetworkControl $element.elements }
            }
        }
        $controls = @(foreach ($step in $form.view.properties.steps) { Find-NetworkControl $step.elements })
        $controls.Count | Should Be 1
        $control = $controls[0]
        $control.type | Should Be 'Microsoft.Common.DropDown'
        ($control.constraints.allowedValues.value -join ',') | Should Be 'Disabled,EnabledWithRestrictions,Enabled'
        ($control.constraints.allowedValues.label -join ',') | Should Be 'Disabled,Enabled with restrictions,Enabled'
        $control.constraints.required | Should Be $true
        $control.defaultValue | Should Match "'Disabled'"
        $control.defaultValue | Should Match "'Enabled'"
        $control.defaultValue | Should Not Match 'permittedIPs|PermittedIPs'
        $form.view.outputs.parameters.paasPublicNetworkAccess | Should Match '\.paasPublicNetworkAccess'
        $template.parameters.paasPublicNetworkAccess.defaultValue | Should Be 'Auto'
        $modeType = $template.definitions.publicNetworkAccessMode
        @(
            Compare-Object @('Auto', 'Disabled', 'EnabledWithRestrictions', 'Enabled') @($modeType.allowedValues)
        ) | Should BeNullOrEmpty
        foreach ($name in $form.view.outputs.parameters.PSObject.Properties.Name) {
            ($template.parameters.PSObject.Properties.Name -contains $name) | Should Be $true
        }
    }

    It 'shows IP rules only in restricted mode without gating rule outputs on the access mode' -TestCases $formCases {
        param($Directory, $Entry)

        $form = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\uiFormDefinition.json") -Raw | ConvertFrom-Json
        function Find-NetworkGrid($Elements) {
            foreach ($element in $Elements) {
                if ($element.name -in @('permittedIPs', 'storagePermittedIPs')) { $element }
                if ($element.elements) { Find-NetworkGrid $element.elements }
            }
        }
        $grids = @(foreach ($step in $form.view.properties.steps) { Find-NetworkGrid $step.elements })
        $grids.Count | Should Be 1
        $modeReference = Get-PublicAccessControlReference $Directory
        $grids[0].visible | Should Be "[equals($modeReference, 'EnabledWithRestrictions')]"
        ($null -eq $grids[0].PSObject.Properties['defaultValue']) | Should Be $true
        $expectedColumn = if ($Directory -eq 'add-ons\fslogixStorage') { 'value' } else { 'ipAddress' }
        $grids[0].constraints.columns[0].id | Should Be $expectedColumn
        $outputName = if ($Directory -eq 'imageManagement') { 'storagePermittedIPs' } else { 'permittedIPs' }
        $form.view.outputs.parameters.$outputName | Should Not Match 'paasPublicNetworkAccess|configureZeroTrustNetworking'
    }

    It 'shows one concise literal explanation per mode and gates the IP heading in <Directory>' -TestCases $formCases {
        param($Directory, $Entry)

        $form = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\uiFormDefinition.json") -Raw | ConvertFrom-Json
        function Find-NetworkExplanation($Elements) {
            foreach ($element in $Elements) {
                if ($element.name -in @('permittedIPsDisabledInfo', 'permittedIPsRestrictedInfo', 'permittedIPsEnabledInfo', 'permittedIPsInfo')) {
                    $element
                }
                if ($element.elements) { Find-NetworkExplanation $element.elements }
            }
        }
        $controls = @(foreach ($step in $form.view.properties.steps) { Find-NetworkExplanation $step.elements })
        $modeReference = Get-PublicAccessControlReference $Directory
        $explanations = @($controls | Where-Object { $_.name -ne 'permittedIPsInfo' })
        $explanations.Count | Should Be 3
        foreach ($mode in @(
            @{ Name = 'permittedIPsDisabledInfo'; Value = 'Disabled' }
            @{ Name = 'permittedIPsRestrictedInfo'; Value = 'EnabledWithRestrictions' }
            @{ Name = 'permittedIPsEnabledInfo'; Value = 'Enabled' }
        )) {
            $explanation = @($explanations | Where-Object { $_.name -eq $mode.Name })
            $explanation.Count | Should Be 1
            $explanation[0].type | Should Be 'Microsoft.Common.TextBlock'
            $explanation[0].visible | Should Be "[equals($modeReference, '$($mode.Value)')]"
            $explanation[0].options.text | Should Not Match '^\['
            $explanation[0].options.text.Length | Should BeLessThan 180
        }
        foreach ($heading in @($controls | Where-Object { $_.name -eq 'permittedIPsInfo' })) {
            $heading.visible | Should Be "[equals($modeReference, 'EnabledWithRestrictions')]"
        }
    }

    It 'preserves subnet restrictions in the initial Service Endpoint selection' {
        $form = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\imageManagement\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $section = ($form.view.properties.steps | Where-Object { $_.name -eq 'storageAccounts' }).elements |
            Where-Object { $_.name -eq 'storageSettings' }
        ($section.elements | Where-Object { $_.name -eq 'storageNetworkAccess' }).defaultValue |
            Should Be 'Public Endpoint'
        ($section.elements | Where-Object { $_.name -eq 'paasPublicNetworkAccess' }).defaultValue |
            Should Match "'ServiceEndpoint'\), 'Enabled with restrictions'"
    }

    It 'keeps Image Management private endpoint creation independent of public access mode' {
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\imageManagement\imageManagement.json') -Raw | ConvertFrom-Json
        $template.resources.assetsStoragePrivateEndpoint.condition |
            Should Be "[and(parameters('deployArtifactsStorageAccount'), equals(parameters('storageNetworkAccess'), 'PrivateEndpoint'))]"
        $template.resources.logsStoragePrivateEndpoint.condition |
            Should Be "[and(parameters('deployBuildLogsStorageAccount'), equals(parameters('storageNetworkAccess'), 'PrivateEndpoint'))]"
    }

    It 'retains the automated-host-pool legacy Azure Files allowlist while adding a shared list' {
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.json') -Raw | ConvertFrom-Json
        $template.parameters.fslogixPermittedIPs.defaultValue.Count | Should Be 0
        $template.parameters.permittedIPs.defaultValue.Count | Should Be 0
        $template.resources.sharedKeyVaults.properties.parameters.permittedIPs.value | Should Be "[parameters('permittedIPs')]"
        $template.resources.fslogixStorage.properties.parameters.permittedIPs.value |
            Should Be "[union(parameters('fslogixPermittedIPs'), parameters('permittedIPs'))]"
    }

    It 'does not read hidden access controls when no managed PaaS resource is selected' -TestCases @(
        @{ Directory = 'hostpools'; Step = 'zeroTrust'; Section = 'permittedIPsSection' }
        @{ Directory = 'automatedHostPools'; Step = 'zeroTrust'; Section = 'permittedIPsSection' }
        @{ Directory = 'imageManagement'; Step = 'storageAccounts'; Section = 'storageSettings' }
    ) {
        param($Directory, $Step, $Section)

        $form = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\uiFormDefinition.json") -Raw | ConvertFrom-Json
        $sectionControl = ($form.view.properties.steps | Where-Object { $_.name -eq $Step }).elements |
            Where-Object { $_.name -eq $Section }
        $condition = $sectionControl.visible.Substring(1, $sectionControl.visible.Length - 2)
        $form.view.outputs.parameters.paasPublicNetworkAccess |
            Should Be "[if($condition, steps('$Step').$Section.paasPublicNetworkAccess, 'Auto')]"
        if ($Directory -eq 'automatedHostPools') {
            $form.view.outputs.parameters.permittedIPs |
                Should Be "[if($condition, filter(map(steps('zeroTrust').permittedIPsSection.permittedIPs, (item) => item.ipAddress), (ip) => not(empty(ip))), parse('[]'))]"
        }
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
        foreach ($name in @('effectiveStoragePermittedIPs', 'networkAccess', 'storageNetworkAcls')) {
            if (-not $image.variables.ContainsKey($name)) { throw "Missing compiled networking variable: $name" }
            $networkVariables[$name] = $image.variables[$name]
        }
        $networkVariables.copy = @($image.variables.copy | Where-Object { $_.name -in @('storageIpRules', 'storageVnetRules') })
        if ($networkVariables.copy.Count -ne 2) { throw 'Missing compiled IP/subnet rule loops.' }
        $image.variables = $networkVariables
        $networkFunctions = @($image.functions | Where-Object { $_.members.ContainsKey('resolveNetworkAccess') })
        if ($networkFunctions.Count -ne 1) { throw 'Cannot locate the compiled network resolver.' }
        $image.functions = @(@{
            namespace = $networkFunctions[0].namespace
            members = @{ resolveNetworkAccess = $networkFunctions[0].members.resolveNetworkAccess }
        })
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

        $services = @('images')
        if ($Index % 2 -eq 0) { $services += @('vaults', 'files', 'apps') }
        foreach ($service in $services) {
            $hasRules = $HasIPs -or ($service -eq 'images' -and $HasSubnets)
            $expectedPublic = if ($Mode -eq 'Disabled' -or ($Mode -eq 'Auto' -and $PrivateEndpoint -and -not $hasRules)) { 'Disabled' } else { 'Enabled' }
            $expectedDefault = if ($Mode -eq 'Enabled' -or ($Mode -eq 'Auto' -and -not $PrivateEndpoint -and -not $hasRules)) { 'Allow' } else { 'Deny' }
            $matches = @($resources | Where-Object {
                $_.tags.networkCase -eq "$service$Index" -and $_.type -in @('Microsoft.Storage/storageAccounts', 'Microsoft.KeyVault/vaults')
            })
            $matches.Count | Should Be $(if ($service -in @('images', 'vaults')) { 2 } else { 1 })
            foreach ($resource in $matches) {
                $resource.properties.publicNetworkAccess | Should Be $expectedPublic
                $resource.properties.networkAcls.defaultAction | Should Be $expectedDefault
                $resource.properties.networkAcls.bypass | Should Be 'AzureServices'
                $ipRules = @($resource.properties.networkAcls.ipRules)
                $ipRules.Count | Should Be $(if (-not $HasIPs) { 0 } elseif ($service -eq 'apps') { 3 } else { 1 })
                if ($HasIPs) {
                    $ipRules[0].value | Should Be '203.0.113.10'
                    if ($service -eq 'apps') {
                        $ipRules[1].value | Should Be '198.51.100.0/24'
                        $ipRules[2].value | Should Be '192.0.2.10'
                    }
                }
                if ($service -eq 'images') {
                    @($resource.properties.networkAcls.virtualNetworkRules).Count | Should Be $(if ($HasSubnets) { 1 } else { 0 })
                }
            }
        }
    }

    It 'pairs Function App storage DNS groups with their private endpoints for case <Index>' -TestCases @($matrixCases | Where-Object { $_.Index % 2 -eq 0 }) {
        param($Index, $PrivateEndpoint)

        $groups = @($resources | Where-Object {
            $_.type -eq 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' -and
            $_.name -like "pe-functionstorage${Index}-*/default"
        })
        $services = if ($Index % 4 -eq 0) { @('blob', 'queue', 'table') } else { @('blob', 'table') }
        $groups.Count | Should Be $(if ($PrivateEndpoint) { $services.Count } else { 0 })
        if ($PrivateEndpoint) {
            foreach ($service in $services) {
                $endpointName = "pe-functionstorage${Index}-$service"
                @($resources | Where-Object {
                    $_.type -eq 'Microsoft.Network/privateEndpoints' -and $_.name -eq $endpointName
                }).Count | Should Be 1
                $group = @($groups | Where-Object { $_.name -eq "$endpointName/default" })
                $group.Count | Should Be 1
                $group[0].properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId |
                    Should Be "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/network-tests/providers/Microsoft.Network/privateDnsZones/privatelink.$service.example.test"
            }
        }
    }

    It 'resolves Function App and SCM rules for case <Index>: <Mode>, PE=<PrivateEndpoint>, IP=<HasIPs>' -TestCases @($matrixCases | Where-Object { $_.Index % 2 -eq 0 }) {
        param($Index, $Mode, $PrivateEndpoint, $HasIPs)

        $matches = @($resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' -and $_.tags.networkCase -eq "apps$Index" })
        $matches.Count | Should Be 1
        $app = $matches[0]
        $expectedPublic = if ($Mode -eq 'Disabled' -or ($Mode -eq 'Auto' -and $PrivateEndpoint -and -not $HasIPs)) { 'Disabled' } else { 'Enabled' }
        $restrict = $Mode -in @('Disabled', 'EnabledWithRestrictions') -or ($Mode -eq 'Auto' -and ($PrivateEndpoint -or $HasIPs))
        $expectedDefault = if ($restrict) { 'Deny' } elseif ($Mode -eq 'Auto') { $null } else { 'Allow' }
        $app.properties.publicNetworkAccess | Should Be $expectedPublic
        $site = $app.properties.siteConfig
        $site.publicNetworkAccess | Should Be $expectedPublic
        $site.ipSecurityRestrictionsDefaultAction | Should Be $expectedDefault
        $site.scmIpSecurityRestrictionsDefaultAction | Should Be $expectedDefault
        if ($Mode -ne 'Auto' -or $restrict) { $site.scmIpSecurityRestrictionsUseMain | Should Be $true }
        $rules = @($site.ipSecurityRestrictions | Where-Object { $null -ne $_ })
        $rules.Count | Should Be ($(if ($HasIPs) { 3 } else { 0 }) + $(if ($restrict) { 2 } elseif ($HasIPs) { 1 } else { 0 }))
        @($rules | Where-Object { $_.action -eq 'Deny' }).Count | Should Be $(if ($restrict) { 1 } else { 0 })
        @($site.scmIpSecurityRestrictions | Where-Object { $_.action -eq 'Deny' }).Count | Should Be $(if ($restrict) { 1 } else { 0 })
        if ($restrict -or $HasIPs) {
            ($rules | Where-Object { $_.name -eq 'AzureCloud' }).ipAddress | Should Be 'AzureCloud'
            ($rules | Where-Object { $_.name -eq 'AzureCloud' }).tag | Should Be 'ServiceTag'
        }
        if ($HasIPs) {
            ($rules | Where-Object { $_.name -eq 'PermittedIP-0' }).ipAddress | Should Be '203.0.113.10/32'
            ($rules | Where-Object { $_.name -eq 'PermittedIP-1' }).ipAddress | Should Be '198.51.100.0/24'
            ($rules | Where-Object { $_.name -eq 'PermittedIP-2' }).ipAddress | Should Be '192.0.2.10/32'
        }
    }

    It 'creates private endpoints only from their own flag in case <Index>: <Mode>, PE=<PrivateEndpoint>' -TestCases @($matrixCases | Where-Object { $_.Index % 2 -eq 0 }) {
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
            $endpoints.Count | Should Be $(if ($PrivateEndpoint) { $target.Count } else { 0 })
        }
    }
}
