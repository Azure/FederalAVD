BeforeDiscovery {
    $dnsCases = @(
        @{ Directory = 'networking'; Entry = 'networking'; Count = 43; Zones = @('backup', 'blob', 'file', 'queue', 'table', 'vault', 'websites') }
        @{ Directory = 'sharedServices'; Entry = 'sharedServices'; Count = 48; Zones = @('vault', 'backup', 'blob', 'queue') }
        @{ Directory = 'imageManagement'; Entry = 'imageManagement'; Count = 17; Zones = @('blob') }
        @{ Directory = 'hostpools'; Entry = 'hostpool'; Count = 134; Zones = @('file', 'vault', 'backup', 'blob', 'queue') }
        @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool'; Count = 129; Zones = @('file', 'vault', 'backup', 'blob', 'queue') }
        @{ Directory = 'hostpoolPoc'; Entry = 'hostpoolPoc'; Count = 17; Zones = @() }
        @{ Directory = 'add-ons\fslogixStorage'; Entry = 'main'; Count = 78; Zones = @('file') }
        @{ Directory = 'add-ons\sessionHostReplacer'; Entry = 'main'; Count = 108; Zones = @('blob', 'table', 'websites') }
        @{ Directory = 'add-ons\imageValidation'; Entry = 'main'; Count = 57; Zones = @('blob', 'vault', 'websites') }
        @{ Directory = 'add-ons\fslogixProfileManagement'; Entry = 'main'; Count = 36; Zones = @('blob', 'vault', 'websites') }
    )
    $entryCases = @(
        @{ Directory = 'sharedServices'; Entry = 'sharedServices'; Modules = @{ keyVaultServiceEndpointSubnetResourceIds = 'keyVaults' } }
        @{ Directory = 'imageManagement'; Entry = 'imageManagement'; Modules = @{ storageServiceEndpointSubnetResourceIds = '' } }
        @{ Directory = 'hostpools'; Entry = 'hostpool'; Modules = @{ storageServiceEndpointSubnetResourceIds = 'fslogix'; keyVaultServiceEndpointSubnetResourceIds = 'sharedKeyVaults' } }
        @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool'; Modules = @{ storageServiceEndpointSubnetResourceIds = 'fslogixStorage'; keyVaultServiceEndpointSubnetResourceIds = 'sharedKeyVaults' } }
        @{ Directory = 'hostpoolPoc'; Entry = 'hostpoolPoc'; Modules = @{ storageServiceEndpointSubnetResourceIds = 'fslogix' } }
        @{ Directory = 'add-ons\fslogixStorage'; Entry = 'main'; Modules = @{ storageServiceEndpointSubnetResourceIds = 'fslogix' } }
        @{ Directory = 'add-ons\sessionHostReplacer'; Entry = 'main'; Modules = @{ storageServiceEndpointSubnetResourceIds = 'functionApp'; functionAppServiceEndpointSubnetResourceIds = 'functionApp' } }
        @{ Directory = 'add-ons\imageValidation'; Entry = 'main'; Modules = @{ storageServiceEndpointSubnetResourceIds = 'functionApp'; functionAppServiceEndpointSubnetResourceIds = 'functionApp'; keyVaultServiceEndpointSubnetResourceIds = '' } }
        @{ Directory = 'add-ons\fslogixProfileManagement'; Entry = 'main'; Modules = @{ storageServiceEndpointSubnetResourceIds = 'functionApp'; functionAppServiceEndpointSubnetResourceIds = 'functionApp'; keyVaultServiceEndpointSubnetResourceIds = '' } }
    )
    $familyCases = @(
        @{ Directory = 'sharedServices'; Entry = 'sharedServices'; Families = @('keyVault'); PrivateDefaults = @{ keyVault = $false } }
        @{ Directory = 'imageManagement'; Entry = 'imageManagement'; Families = @('storage'); PrivateDefaults = @{ storage = $false } }
        @{ Directory = 'hostpools'; Entry = 'hostpool'; Families = @('storage', 'keyVault'); PrivateDefaults = @{ storage = $false; keyVault = $false } }
        @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool'; Families = @('storage', 'keyVault'); PrivateDefaults = @{ storage = $true; keyVault = $false } }
        @{ Directory = 'hostpoolPoc'; Entry = 'hostpoolPoc'; Families = @('storage'); PrivateDefaults = @{} }
        @{ Directory = 'add-ons\fslogixStorage'; Entry = 'main'; Families = @('storage'); PrivateDefaults = @{ storage = $true } }
        @{ Directory = 'add-ons\sessionHostReplacer'; Entry = 'main'; Families = @('storage', 'functionApp'); PrivateDefaults = @{ storage = $false; functionApp = $false } }
        @{ Directory = 'add-ons\imageValidation'; Entry = 'main'; Families = @('storage', 'keyVault', 'functionApp'); PrivateDefaults = @{ storage = $true; keyVault = $true; functionApp = $true } }
        @{ Directory = 'add-ons\fslogixProfileManagement'; Entry = 'main'; Families = @('storage', 'keyVault', 'functionApp'); PrivateDefaults = @{ storage = $true; keyVault = $true; functionApp = $true } }
    )
}

Describe 'Private DNS namespace contracts' {
    It 'preserves parameter counts and canonical DNS namespaces in <Directory>' -TestCases $dnsCases {
        param($Directory, $Entry, $Count, $Zones)
        $template = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\$Entry.json") -Raw | ConvertFrom-Json
        $form = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\uiFormDefinition.json") -Raw | ConvertFrom-Json
        $names = @($template.parameters.PSObject.Properties.Name)
        $names.Count | Should -Be $Count
        @($names | Where-Object { $_ -match '^azure(?:Files?|Blob|Queue|Table|KeyVault|FunctionApp|Backup)PrivateDnsZoneResourceId$' }).Count | Should -Be 0
        $names | Should -Not -Contain 'deployPrivateEndpoints'
        @($names | Where-Object { $_ -match '^(storage(?:File|Blob|Queue|Table)|keyVault|functionApp)PrivateDnsZoneResourceId$' }).Count | Should -Be 0
        if ($Directory -in @('hostpools', 'automatedHostPools', 'imageManagement', 'sharedServices', 'add-ons\sessionHostReplacer')) {
            $schema = $template.definitions.($template.parameters.privateDnsZoneResourceIds.'$ref'.Replace('#/definitions/', ''))
            $schema.additionalProperties | Should -Be $false
            $expectedNamespaces = switch ($Directory) {
                imageManagement { @('blob') }
                sharedServices { @('avdFeed', 'avdGlobalFeed', 'backup', 'blob', 'queue', 'vault') }
                'add-ons\sessionHostReplacer' { @('blob', 'table', 'websites') }
                default { @('avdFeed', 'avdGlobalFeed', 'backup', 'blob', 'file', 'queue', 'vault') }
            }
            @($schema.properties.PSObject.Properties.Name | Sort-Object) | Should -Be $expectedNamespaces
            $form.view.outputs.parameters.PSObject.Properties.Name | Should -Contain 'privateDnsZoneResourceIds'
            foreach ($zone in $Zones) {
                $schema.properties.$zone.type | Should -Be 'string'
                $names | Should -Not -Contain "${zone}PrivateDnsZoneResourceId"
            }
            return
        }
        $actual = @($names | Where-Object { $_ -match '^(file|blob|queue|table|vault|websites|backup)PrivateDnsZoneResourceId$' })
        ($actual | Sort-Object) -join ',' | Should -Be (($Zones | ForEach-Object { "${_}PrivateDnsZoneResourceId" } | Sort-Object) -join ',')
        foreach ($name in $actual) {
            $template.parameters.$name.type | Should -Be 'string'
            $template.parameters.$name.defaultValue | Should -Be ''
            $form.view.outputs.parameters.PSObject.Properties.Name | Should -Contain $name
        }
    }

    It 'returns Networking namespace keys aligned with downstream inputs' {
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\networking\networking.json') -Raw | ConvertFrom-Json
        $zones = $template.outputs.privateDnsZoneResourceIds.value
        ($zones.PSObject.Properties.Name | Sort-Object) -join ',' |
            Should -Be 'avdFeed,avdGlobalFeed,backup,blob,file,queue,table,vault,websites'
        foreach ($prefix in @('file', 'blob', 'queue', 'table', 'vault', 'websites', 'backup')) {
            $zones.$prefix | Should -Match ([regex]::Escape("parameters('${prefix}PrivateDnsZoneResourceId')"))
        }
    }

    It 'passes the same explicit Blob zone ID to Backup and managed-disk consumers' {
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpools\hostpool.json') -Raw | ConvertFrom-Json
        $consumers = @($template.resources.PSObject.Properties | Where-Object {
            $_.Value.properties.parameters.PSObject.Properties.Name -contains 'blobPrivateDnsZoneResourceId'
        })
        $consumers.Count | Should -BeGreaterOrEqual 3
        foreach ($consumer in $consumers) {
            $consumer.Value.properties.parameters.blobPrivateDnsZoneResourceId.value |
                Should -Be "[variables('blobPrivateDnsZoneResourceId')]"
        }
    }

    It 'exposes typed Backup endpoint switches without obsolete root flags' {
        foreach ($case in @(
            @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool'; Flag = 'deployBackupPrivateEndpoints' }
            @{ Directory = 'sharedServices'; Entry = 'sharedServices'; Flag = 'deployBackupPrivateEndpoints' }
        )) {
            $template = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$($case.Directory)\$($case.Entry).json") -Raw | ConvertFrom-Json
            $template.parameters.PSObject.Properties.Name | Should -Not -Contain $case.Flag
            $paas = Get-ContractSchema $template $template.parameters.paasNetworking
            $backup = Get-ContractSchema $template $paas.properties.backup
            $backup.properties.privateEndpoint.type | Should -Be 'bool'
            @($template.parameters.paasNetworking.defaultValue.PSObject.Properties).Count | Should -Be 0
        }
    }
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
    function Get-ContractSchema($Template, $Schema) {
        if ($Schema.'$ref') {
            return $Template.definitions.($Schema.'$ref'.Replace('#/definitions/', ''))
        }
        $Schema
    }
    $networkModule = [IO.Path]::GetRelativePath($TestDrive, (Join-Path $repoRoot 'deployments\shared\modules\orchestration\networking\functions.bicep')).Replace('\', '/')
    function Invoke-SubnetVectors([string]$Expression) {
        $fixture = Join-Path $TestDrive 'subnet-vectors.bicep'
        $import = if ($Expression.Contains('serviceEndpointSubnetIds')) { 'serviceEndpointSubnetIds' } elseif ($Expression.Contains('resolveNetworkAccess')) { 'resolveNetworkAccess' } else { 'endpointTypePublicNetworkAccess' }
        [IO.File]::WriteAllText($fixture, @"
targetScope = 'local'
import { $import } from '$networkModule'
output encodedResults string = base64(string({ results: $Expression }))
"@)
        (Invoke-TestNamingVectors -TemplateFile $fixture).results.value
    }
}

Describe 'Shared-resource private endpoint subnet contracts' {
    It 'routes all endpoint types through exactly two ownership slots in <Directory>' -TestCases @(
        @{ Directory = 'hostpools'; Entry = 'hostpool'; Count = 134; Storage = 'fslogix' }
        @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool'; Count = 129; Storage = 'fslogixStorage' }
    ) {
        param($Directory, $Entry, $Count, $Storage)
        $directoryPath = Join-Path $repoRoot "deployments\$Directory"
        $template = Get-Content -LiteralPath (Join-Path $directoryPath "$Entry.json") -Raw | ConvertFrom-Json
        $form = Get-Content -LiteralPath (Join-Path $directoryPath 'uiFormDefinition.json') -Raw | ConvertFrom-Json
        $names = @($template.parameters.PSObject.Properties.Name)
        $names.Count | Should -Be $Count
        $bindingFunction = 'variables'
            $schema = Get-ContractSchema $template $template.parameters.privateEndpointSubnetResourceIds
            @($schema.properties.PSObject.Properties.Name | Sort-Object) |
                Should -Be @('hostPoolResources', 'sharedResources')
            @($names | Where-Object { $_ -match 'PrivateEndpointSubnetResourceId$' }).Count | Should -Be 0
        $template.resources.sharedKeyVaults.properties.parameters.keyVaultPrivateEndpointSubnetResourceId.value |
            Should -Be "[$bindingFunction('sharedResourcesPrivateEndpointSubnetResourceId')]"
        $template.resources.sharedFilesBackup.properties.parameters.privateEndpointSubnetResourceId.value |
            Should -Be "[$bindingFunction('sharedResourcesPrivateEndpointSubnetResourceId')]"
        $template.resources.sharedAvdWorkspace.properties.parameters.workspaceFeedPrivateEndpointSubnetResourceId |
            Should -Match "$bindingFunction\('sharedResourcesPrivateEndpointSubnetResourceId'\)"
        $template.resources.sharedAvdWorkspace.properties.parameters.globalFeedPrivateEndpointSubnetResourceId.value |
            Should -Be "[$bindingFunction('sharedResourcesPrivateEndpointSubnetResourceId')]"
        $template.resources.$Storage.properties.parameters.storagePrivateEndpointSubnetResourceId.value |
            Should -Be "[$bindingFunction('hostPoolResourcesPrivateEndpointSubnetResourceId')]"
        $template.resources.controlPlane.properties.parameters.hostPoolPrivateEndpointSubnetResourceId.value |
            Should -Be "[$bindingFunction('hostPoolResourcesPrivateEndpointSubnetResourceId')]"
        foreach ($name in $form.view.outputs.parameters.PSObject.Properties.Name) { $names | Should -Contain $name }
        $section = ($form.view.properties.steps | Where-Object name -eq 'zeroTrust').elements |
            Where-Object name -eq 'privateEndpointSubnets'
        foreach ($pair in @(
            @{ Name = 'sharedSubnet'; Parameter = 'sharedResourcesPrivateEndpointSubnetResourceId' }
            @{ Name = 'hostPoolSubnet'; Parameter = 'hostPoolResourcesPrivateEndpointSubnetResourceId' }
        )) {
            $selector = $section.elements | Where-Object name -eq $pair.Name
            $condition = $selector.visible.Substring(1, $selector.visible.Length - 2)
            $form.view.outputs.parameters.privateEndpointSubnetResourceIds |
                Should -Match ([regex]::Escape("steps('zeroTrust').privateEndpointSubnets.$($pair.Name).id"))
            $selector.visible | Should -Match 'avdPrivateLink'
        }
        ($section.elements | Where-Object name -eq 'sharedSubnet').visible | Should -Match 'keyVaultPrivateEndpoint'
        ($section.elements | Where-Object name -eq 'hostPoolSubnet').visible | Should -Match 'storagePrivateEndpoint'
    }
}

Describe 'Service endpoint deployment contracts' {
    It 'exposes only applicable explicit family policies and independent PE defaults in <Directory>' -TestCases $familyCases {
        param($Directory, $Entry, $Families, $PrivateDefaults)
        $template = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\$Entry.json") -Raw | ConvertFrom-Json
        $names = $template.parameters.PSObject.Properties.Name
        $names | Should -Not -Contain 'paasPublicNetworkAccess'
        $names | Should -Not -Contain 'permittedIPs'
        $names | Should -Not -Contain 'fslogixPermittedIPs'
        $names | Should -Not -Contain 'endpointType'
        $names | Should -Not -Contain 'storageNetworkAccess'
        if ($Directory -in @('hostpools', 'automatedHostPools', 'imageManagement', 'sharedServices', 'add-ons\sessionHostReplacer')) {
            $paas = Get-ContractSchema $template $template.parameters.paasNetworking
            foreach ($family in $Families) {
                $schema = Get-ContractSchema $template $paas.properties.$family
                $mode = Get-ContractSchema $template $schema.properties.publicNetworkAccess
                @($mode.allowedValues | Sort-Object) | Should -Be @('Disabled', 'Enabled', 'EnabledWithRestrictions')
                $schema.properties.privateEndpoint.type | Should -Be 'bool'
                $schema.properties.permittedIPs.type | Should -Be 'array'
                $schema.properties.serviceEndpointSubnetResourceIds.type | Should -Be 'array'
            }
            if ($Directory -eq 'add-ons\sessionHostReplacer') {
                $paas.properties.PSObject.Properties.Name | Should -Contain 'functionApp'
                $paas.properties.PSObject.Properties.Name | Should -Not -Contain 'keyVault'
            } else {
                $paas.properties.PSObject.Properties.Name | Should -Not -Contain 'functionApp'
            }
            return
        }
        foreach ($family in @('storage', 'keyVault', 'functionApp')) {
            if ($family -in $Families) {
                $mode = $template.parameters."${family}PublicNetworkAccess"
                $schema = if ($mode.'$ref') { $template.definitions.($mode.'$ref'.Replace('#/definitions/', '')) } else { $mode }
                $schema.type | Should -Be 'string'
                $mode.defaultValue | Should -Be 'Disabled'
                @($schema.allowedValues | Sort-Object) | Should -Be @('Disabled', 'Enabled', 'EnabledWithRestrictions')
                $template.parameters."${family}PermittedIPs".type | Should -Be 'array'
                @($template.parameters."${family}PermittedIPs".defaultValue).Count | Should -Be 0
                if ($PrivateDefaults.ContainsKey($family)) {
                    $template.parameters."${family}PrivateEndpoint".defaultValue | Should -Be $PrivateDefaults[$family]
                    if ($Directory -in @('hostpools', 'automatedHostPools', 'sharedServices')) {
                        $names | Should -Not -Contain "${family}PrivateEndpointSubnetResourceId"
                    } else {
                        $template.parameters."${family}PrivateEndpointSubnetResourceId".type | Should -Be 'string'
                    }
                } else {
                    $names | Should -Not -Contain "${family}PrivateEndpoint"
                    $names | Should -Not -Contain "${family}PrivateEndpointSubnetResourceId"
                }
            } else {
                $names | Should -Not -Contain "${family}PublicNetworkAccess"
                $names | Should -Not -Contain "${family}PermittedIPs"
                $names | Should -Not -Contain "${family}PrivateEndpoint"
                $names | Should -Not -Contain "${family}PrivateEndpointSubnetResourceId"
            }
        }
    }

    It 'forwards explicit resolved family policies, IPs and PEs in <Directory>' -TestCases @(
        @{ Directory = 'sharedServices'; Entry = 'sharedServices'; Symbol = 'keyVaults'; Family = 'keyVault' }
        @{ Directory = 'hostpools'; Entry = 'hostpool'; Symbol = 'sharedKeyVaults'; Family = 'keyVault' }
        @{ Directory = 'hostpools'; Entry = 'hostpool'; Symbol = 'fslogix'; Family = 'storage' }
        @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool'; Symbol = 'sharedKeyVaults'; Family = 'keyVault' }
        @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool'; Symbol = 'fslogixStorage'; Family = 'storage' }
        @{ Directory = 'add-ons\fslogixStorage'; Entry = 'main'; Symbol = 'fslogix'; Family = 'storage' }
    ) {
        param($Directory, $Entry, $Symbol, $Family)
        $template = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\$Entry.json") -Raw | ConvertFrom-Json
        $bindings = $template.resources.$Symbol.properties.parameters
        foreach ($suffix in @('PublicNetworkAccess', 'PermittedIPs', 'PrivateEndpoint', 'PrivateEndpointSubnetResourceId')) {
            $name = "$Family$suffix"
            $inputName = if ($suffix -eq 'PrivateEndpointSubnetResourceId' -and $Directory -in @('hostpools', 'automatedHostPools', 'sharedServices')) {
                if ($Family -eq 'storage') { 'hostPoolResourcesPrivateEndpointSubnetResourceId' } else { 'sharedResourcesPrivateEndpointSubnetResourceId' }
            } else { $name }
            $bindingFunction = if ($Directory -in @('hostpools', 'automatedHostPools', 'sharedServices')) { 'variables' } else { 'parameters' }
            $bindings.$name.value | Should -Be "[$bindingFunction('$inputName')]"
        }
    }

    It 'keeps Key Vault names, defaults and resource interfaces aligned in <Directory>' -TestCases @(
        @{ Directory = 'sharedServices'; Entry = 'sharedServices'; Symbol = 'keyVaults' }
        @{ Directory = 'hostpools'; Entry = 'hostpool'; Symbol = 'sharedKeyVaults' }
        @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool'; Symbol = 'sharedKeyVaults' }
    ) {
        param($Directory, $Entry, $Symbol)
        $template = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\$Entry.json") -Raw | ConvertFrom-Json
        $vaults = $template.resources.$Symbol.properties.template
        $names = $vaults.parameters.PSObject.Properties.Name
        foreach ($oldName in @('paasPublicNetworkAccess', 'permittedIPs', 'privateEndpoint', 'privateEndpointSubnetResourceId')) {
            $names | Should -Not -Contain $oldName
        }
        $mode = $vaults.parameters.keyVaultPublicNetworkAccess
        $schema = $vaults.definitions.($mode.'$ref'.Replace('#/definitions/', ''))
        $schema.type | Should -Be 'string'
        @($schema.allowedValues | Sort-Object) | Should -Be @('Disabled', 'Enabled', 'EnabledWithRestrictions')
        $mode.defaultValue | Should -Be 'Disabled'
        $vaults.parameters.keyVaultPermittedIPs.type | Should -Be 'array'
        @($vaults.parameters.keyVaultPermittedIPs.defaultValue).Count | Should -Be 0
        $vaults.parameters.keyVaultPrivateEndpoint.type | Should -Be 'bool'
        $vaults.parameters.keyVaultPrivateEndpoint.defaultValue | Should -BeFalse
        $vaults.parameters.keyVaultPrivateEndpointSubnetResourceId.type | Should -Be 'string'
        $vaults.parameters.keyVaultPrivateEndpointSubnetResourceId.defaultValue | Should -Be ''
        foreach ($name in @('keyVaultServiceEndpointSubnetResourceIds', 'vaultPrivateDnsZoneResourceId')) {
            $bindingFunction = 'variables'
            $template.resources.$Symbol.properties.parameters.$name.value | Should -Be "[$bindingFunction('$name')]"
        }
        $vaults.variables.effectivePermittedIPs | Should -Match "parameters\('keyVaultPermittedIPs'\)"
        $vaults.variables.networkAccess | Should -Match "parameters\('keyVaultPublicNetworkAccess'\)"
        $vaults.variables.networkAccess | Should -Match "parameters\('keyVaultPrivateEndpoint'\)"
        foreach ($endpoint in @('secretsKeyVault_pe', 'encryptionKeyVault_pe')) {
            $vaults.resources.$endpoint.properties.parameters.subnetResourceId.value | Should -Be "[parameters('keyVaultPrivateEndpointSubnetResourceId')]"
            $vaults.resources.$endpoint.properties.parameters.groupId.value | Should -Be 'vault'
        }
        foreach ($symbol in @('secretsKeyVault', 'encryptionKeyVault')) {
            $resources = @($vaults.resources.$symbol.properties.template.resources.PSObject.Properties.Value |
                Where-Object type -eq 'Microsoft.KeyVault/vaults')
            $resources.Count | Should -Be 1
            $resources[0].properties.publicNetworkAccess | Should -Be "[parameters('publicNetworkAccess')]"
            $resources[0].properties.networkAcls | Should -Be "[parameters('networkAcls')]"
        }
    }

    It 'keeps Storage names and resource mappings through both FSLogix layers in <Directory>' -TestCases @(
        @{ Directory = 'hostpools'; Entry = 'hostpool'; Symbol = 'fslogix' }
        @{ Directory = 'automatedHostPools'; Entry = 'automatedHostPool'; Symbol = 'fslogixStorage' }
        @{ Directory = 'hostpoolPoc'; Entry = 'hostpoolPoc'; Symbol = 'fslogix' }
        @{ Directory = 'add-ons\fslogixStorage'; Entry = 'main'; Symbol = 'fslogix' }
    ) {
        param($Directory, $Entry, $Symbol)
        $template = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\$Entry.json") -Raw | ConvertFrom-Json
        $fslogix = $template.resources.$Symbol.properties.template
        $azureFiles = $fslogix.resources.azureFiles.properties.template
        foreach ($layer in @($fslogix, $azureFiles)) {
            $names = $layer.parameters.PSObject.Properties.Name
            foreach ($oldName in @('paasPublicNetworkAccess', 'permittedIPs', 'privateEndpoint', 'privateEndpointSubnetResourceId')) {
                $names | Should -Not -Contain $oldName
            }
            $mode = $layer.parameters.storagePublicNetworkAccess
            $schema = $layer.definitions.($mode.'$ref'.Replace('#/definitions/', ''))
            $schema.type | Should -Be 'string'
            @($schema.allowedValues | Sort-Object) | Should -Be @('Disabled', 'Enabled', 'EnabledWithRestrictions')
            $mode.defaultValue | Should -Be 'Disabled'
            foreach ($name in @('storagePermittedIPs', 'storageServiceEndpointSubnetResourceIds')) {
                $layer.parameters.$name.type | Should -Be 'array'
                @($layer.parameters.$name.defaultValue).Count | Should -Be 0
            }
            $layer.parameters.storagePrivateEndpoint.type | Should -Be 'bool'
            $layer.parameters.storagePrivateEndpointSubnetResourceId.type | Should -Be 'string'
            $layer.parameters.storagePrivateEndpoint.PSObject.Properties.Name | Should -Not -Contain 'defaultValue'
            $layer.parameters.storagePrivateEndpointSubnetResourceId.PSObject.Properties.Name | Should -Not -Contain 'defaultValue'
        }
        foreach ($name in @('storagePublicNetworkAccess', 'storagePermittedIPs', 'storagePrivateEndpoint', 'storagePrivateEndpointSubnetResourceId', 'storageServiceEndpointSubnetResourceIds', 'filePrivateDnsZoneResourceId')) {
            $fslogix.resources.azureFiles.properties.parameters.$name.value | Should -Be "[parameters('$name')]"
        }
        $azureFiles.variables.networkAccess | Should -Match "parameters\('storagePublicNetworkAccess'\)"
        $azureFiles.variables.networkAccess | Should -Match "parameters\('storagePrivateEndpoint'\)"
        $azureFiles.variables.effectivePermittedIPs | Should -Match "parameters\('storagePermittedIPs'\)"
        $azureFiles.resources.privateEndpoints.condition | Should -Be "[parameters('storagePrivateEndpoint')]"
        $azureFiles.resources.privateEndpoints.properties.parameters.subnetResourceId.value | Should -Be "[parameters('storagePrivateEndpointSubnetResourceId')]"
        $storage = $azureFiles.resources.storageAccounts.properties
        $storage.parameters.networkAcls.value | Should -Be "[variables('storageNetworkAcls')]"
        $storage.parameters.publicNetworkAccess.value | Should -Be "[variables('networkAccess').publicNetworkAccess]"
        $accounts = @($storage.template.resources.PSObject.Properties.Value | Where-Object type -eq 'Microsoft.Storage/storageAccounts')
        $accounts.Count | Should -Be 1
        $accounts[0].properties.networkAcls | Should -Be "[parameters('networkAcls')]"
        $accounts[0].properties.publicNetworkAccess | Should -Be "[parameters('publicNetworkAccess')]"
    }

    It 'preserves the PoC endpoint constants while forwarding its Storage public policy' {
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpoolPoc\hostpoolPoc.json') -Raw | ConvertFrom-Json
        $bindings = $template.resources.fslogix.properties.parameters
        $bindings.storagePrivateEndpoint.value | Should -BeFalse
        $bindings.storagePrivateEndpointSubnetResourceId.value | Should -Be ''
        $bindings.storagePublicNetworkAccess.value | Should -Be "[parameters('storagePublicNetworkAccess')]"
        $bindings.storagePermittedIPs.value | Should -Be "[parameters('storagePermittedIPs')]"
    }

    It 'preserves the application script PrivateEndpoint argument independently of the Bicep input name' {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\azureFiles.bicep') -Raw
        $source | Should -Match "\{ name: 'PrivateEndpoint', value: string\(storagePrivateEndpoint\) \}"
    }

    It 'evaluates all independent mixed public-policy combinations without inferring access from PEs or rules' {
        $vectors = Invoke-SubnetVectors "map(['Disabled', 'EnabledWithRestrictions', 'Enabled'], storage => map(['Disabled', 'EnabledWithRestrictions', 'Enabled'], vault => { storage: resolveNetworkAccess(storage, false, true), vault: resolveNetworkAccess(vault, true, false) }))"
        $modes = @('Disabled', 'EnabledWithRestrictions', 'Enabled')
        for ($s = 0; $s -lt 3; $s++) {
            for ($v = 0; $v -lt 3; $v++) {
                $vectors[$s][$v].storage.publicNetworkAccess | Should -Be $(if ($modes[$s] -eq 'Disabled') { 'Disabled' } else { 'Enabled' })
                $vectors[$s][$v].storage.defaultAction | Should -Be $(if ($modes[$s] -eq 'Enabled') { 'Allow' } else { 'Deny' })
                $vectors[$s][$v].vault.publicNetworkAccess | Should -Be $(if ($modes[$v] -eq 'Disabled') { 'Disabled' } else { 'Enabled' })
                $vectors[$s][$v].vault.defaultAction | Should -Be $(if ($modes[$v] -eq 'Enabled') { 'Allow' } else { 'Deny' })
            }
        }
    }

    It 'exposes optional subnet arrays and forwards them in <Directory>' -TestCases $entryCases {
        param($Directory, $Entry, $Modules)
        $template = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\$Entry.json") -Raw | ConvertFrom-Json
        foreach ($name in $Modules.Keys) {
            if ($Directory -in @('hostpools', 'automatedHostPools', 'imageManagement', 'sharedServices', 'add-ons\sessionHostReplacer')) {
                $family = $name -replace 'ServiceEndpointSubnetResourceIds$', ''
                $paas = Get-ContractSchema $template $template.parameters.paasNetworking
                $schema = Get-ContractSchema $template $paas.properties.$family
                $schema.properties.serviceEndpointSubnetResourceIds.type | Should -Be 'array'
                $resolvedVariable = if ($Directory -eq 'automatedHostPools') { 'networking' } else { 'resolvedNetworking' }
                $template.variables.$name | Should -Be "[variables('$resolvedVariable').$family.serviceEndpointSubnetResourceIds]"
                if ($Modules[$name]) {
                    $template.resources.($Modules[$name]).properties.parameters.$name.value |
                        Should -Be "[variables('$name')]"
                }
                continue
            }
            $template.parameters.$name.type | Should -Be 'array'
            @($template.parameters.$name.defaultValue).Count | Should -Be 0
            if ($Modules[$name]) {
                $binding = $template.resources.($Modules[$name]).properties.parameters.$name.value
                $binding | Should -Match "parameters\('$name'\)"
            }
        }
    }

    It 'normalizes and deduplicates resource IDs across subscriptions and VNets' {
        $ids = @(Invoke-SubnetVectors "serviceEndpointSubnetIds(['/subscriptions/a/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/first/subnets/clients', ' /SUBSCRIPTIONS/A/RESOURCEGROUPS/RG/PROVIDERS/MICROSOFT.NETWORK/VIRTUALNETWORKS/FIRST/SUBNETS/CLIENTS ', '/subscriptions/b/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/second/subnets/clients'])")
        $ids.Count | Should -Be 2
        $ids[0] | Should -Be '/subscriptions/a/resourcegroups/rg/providers/microsoft.network/virtualnetworks/first/subnets/clients'
        $ids[1] | Should -Be '/subscriptions/b/resourcegroups/rg/providers/microsoft.network/virtualnetworks/second/subnets/clients'
        @(Invoke-SubnetVectors 'serviceEndpointSubnetIds([])').Count | Should -Be 0
    }

    It 'rejects invalid subnet input <Id> explicitly' -TestCases @(
        @{ Id = '' }
        @{ Id = ' ' }
        @{ Id = '/subscriptions/a/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet' }
        @{ Id = '/subscriptions/a/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/' }
        @{ Id = '/subscriptions/a/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/account/subnets/client' }
    ) {
        param($Id)
        { Invoke-SubnetVectors "serviceEndpointSubnetIds(['$Id'])" } |
            Should -Throw '*Local naming vectors failed*'
    }

    It 'preserves legacy topology defaults while honoring explicit public-access choices' {
        $modes = Invoke-SubnetVectors "[endpointTypePublicNetworkAccess('Auto', 'private', false), endpointTypePublicNetworkAccess('Auto', 'service', false), endpointTypePublicNetworkAccess('Auto', 'public', false), endpointTypePublicNetworkAccess('Auto', 'public', true), endpointTypePublicNetworkAccess('Disabled', 'service', true), endpointTypePublicNetworkAccess('Enabled', 'private', true)]"
        $modes | Should -Be @('Disabled', 'EnabledWithRestrictions', 'Enabled', 'EnabledWithRestrictions', 'Disabled', 'Enabled')
    }

    It 'separates Function App inbound subnet rules from runtime storage rules' {
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\imageValidation\main.json') -Raw | ConvertFrom-Json
        $app = $template.resources.functionApp.properties.template
        $app.variables.storageSubnetIds | Should -Match "parameters\('storageServiceEndpointSubnetResourceIds'\)"
        $app.variables.storageSubnetIds | Should -Not -Match "parameters\('functionAppServiceEndpointSubnetResourceIds'\)"
        $app.variables.functionAppSubnetIds | Should -Match "parameters\('functionAppServiceEndpointSubnetResourceIds'\)"
        $app.variables.functionAppSubnetIds | Should -Not -Match "parameters\('storageServiceEndpointSubnetResourceIds'\)"
        $app.resources.storageAccount.properties.publicNetworkAccess | Should -Be "[variables('storageNetworkAccess').publicNetworkAccess]"
        $app.resources.functionApp.properties.publicNetworkAccess | Should -Be "[variables('networkAccess').publicNetworkAccess]"
    }

    It 'keeps runtime storage and app policies, IPs, PE subnets and DNS independent in <Directory>' -TestCases @(
        @{ Directory = 'add-ons\sessionHostReplacer' }
        @{ Directory = 'add-ons\imageValidation' }
        @{ Directory = 'add-ons\fslogixProfileManagement' }
    ) {
        param($Directory)
        $template = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\main.json") -Raw | ConvertFrom-Json
        $call = $template.resources.functionApp.properties
        $binding = if ($Directory -eq 'add-ons\sessionHostReplacer') { 'variables' } else { 'parameters' }
        foreach ($family in @('storage', 'functionApp')) {
            foreach ($suffix in @('PublicNetworkAccess', 'PermittedIPs', 'PrivateEndpoint', 'PrivateEndpointSubnetResourceId')) {
                $name = "$family$suffix"
                $call.parameters.$name.value | Should -Be "[$binding('$name')]"
            }
        }
        $app = $call.template
        $app.variables.storageNetworkAccess | Should -Match "parameters\('storagePublicNetworkAccess'\)"
        $app.variables.storageNetworkAccess | Should -Not -Match "parameters\('functionApp"
        $app.variables.networkAccess | Should -Match "parameters\('functionAppPublicNetworkAccess'\)"
        $app.variables.networkAccess | Should -Not -Match "parameters\('storage"
        $app.variables.effectiveStoragePermittedIPs | Should -Match "parameters\('storagePermittedIPs'\)"
        $app.variables.effectiveFunctionAppPermittedIPs | Should -Match "parameters\('functionAppPermittedIPs'\)"
        $app.resources.privateEndpoints_storage.condition | Should -Be "[parameters('storagePrivateEndpoint')]"
        $app.resources.privateEndpoints_storage.properties.subnet.id | Should -Be "[parameters('storagePrivateEndpointSubnetResourceId')]"
        $app.resources.privateEndpoint_functionApp.condition | Should -Be "[parameters('functionAppPrivateEndpoint')]"
        $app.resources.privateEndpoint_functionApp.properties.subnet.id | Should -Be "[parameters('functionAppPrivateEndpointSubnetResourceId')]"
        $app.resources.privateDnsZoneGroups_storage.condition | Should -Match "parameters\('storagePrivateEndpoint'\)"
        $app.resources.privateDnsZoneGroup_functionApp.condition | Should -Match "parameters\('functionAppPrivateEndpoint'\)"
        $app.variables.PSObject.Properties.Name | Should -Not -Contain 'permittedSubnetIds'
        $app.variables.storageSubnetIds | Should -Not -Match 'DelegatedSubnet|PrivateEndpointSubnet'
        $app.variables.functionAppSubnetIds | Should -Not -Match 'DelegatedSubnet|PrivateEndpointSubnet'
        $app.resources.functionApp.properties.virtualNetworkSubnetId | Should -Match "parameters\('functionAppDelegatedSubnetResourceId'\)"
    }

    It 'keeps the directly owned encryption vault independent of runtime Storage and app access in <Directory>' -TestCases @(
        @{ Directory = 'add-ons\imageValidation' }
        @{ Directory = 'add-ons\fslogixProfileManagement' }
    ) {
        param($Directory)
        $template = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Directory\main.json") -Raw | ConvertFrom-Json
        $template.variables.keyVaultNetworkAccess | Should -Match "parameters\('keyVaultPublicNetworkAccess'\)"
        $template.variables.keyVaultNetworkAccess | Should -Not -Match "parameters\('(storage|functionApp)"
        $template.variables.effectiveKeyVaultPermittedIPs | Should -Match "parameters\('keyVaultPermittedIPs'\)"
        $template.variables.keyVaultSubnetIds | Should -Not -Match 'DelegatedSubnet|PrivateEndpointSubnet|virtualMachineSubnet'
        $template.resources.keyVaultPrivateEndpointDeployment.condition | Should -Be "[parameters('keyVaultPrivateEndpoint')]"
        $template.resources.keyVaultPrivateEndpointDeployment.properties.parameters.subnetResourceId.value | Should -Be "[parameters('keyVaultPrivateEndpointSubnetResourceId')]"
        $template.variables.blobDnsZoneId | Should -Match "parameters\('storagePrivateEndpoint'\)"
        $template.variables.appDnsZoneId | Should -Match "parameters\('functionAppPrivateEndpoint'\)"
        $template.variables.vaultDnsZoneId | Should -Match "parameters\('keyVaultPrivateEndpoint'\)"
        $template.variables.integrationSubnetId | Should -Be "[parameters('functionAppDelegatedSubnetResourceId')]"
    }

    It 'uses one explicit Storage policy for both image-management accounts' {
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\imageManagement\imageManagement.json') -Raw | ConvertFrom-Json
        $template.variables.networkAccess | Should -Match "variables\('storagePublicNetworkAccess'\)"
        foreach ($symbol in @('assetsStorageAccount', 'logsStorageAccount')) {
            $template.resources.$symbol.properties.parameters.publicNetworkAccess.value | Should -Be "[variables('networkAccess').publicNetworkAccess]"
            $template.resources.$symbol.properties.parameters.networkAcls.value | Should -Be "[variables('storageNetworkAcls')]"
        }
        $template.variables.storageNetworkAcls.defaultAction | Should -Be "[variables('networkAccess').defaultAction]"
        foreach ($symbol in @('assetsStoragePrivateEndpoint', 'logsStoragePrivateEndpoint')) {
            $template.resources.$symbol.condition | Should -Match "variables\('storagePrivateEndpoint'\)"
            $template.resources.$symbol.properties.parameters.subnetResourceId.value | Should -Be "[variables('storagePrivateEndpointSubnetResourceId')]"
        }
    }

    It 'allows the owned PoC host subnet and sequences ACL creation after networking' {
        $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpoolPoc\hostpoolPoc.json') -Raw | ConvertFrom-Json
        $template.resources.fslogix.properties.parameters.storageServiceEndpointSubnetResourceIds.value | Should -Match "variables\('sessionHostSubnetResourceId'\)"
        $template.resources.fslogix.dependsOn | Should -Contain 'network'
        $template.variables.configureStorageServiceEndpoint | Should -Match 'EnabledWithRestrictions'
        $template.resources.network.properties.parameters.subnets.value | Should -Match 'Microsoft.Storage'
    }
}
