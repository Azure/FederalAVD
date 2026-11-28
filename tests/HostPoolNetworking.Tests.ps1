BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
    $networkingModule = [IO.Path]::GetRelativePath($TestDrive, (Join-Path $repoRoot 'deployments\shared\modules\orchestration\networking\scenarios.bicep')).Replace('\', '/')
    $template = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpools\hostpool.json') -Raw | ConvertFrom-Json -Depth 100

    function Invoke-HostPoolNetworkVector {
        param([string]$Expression)

        $fixture = Join-Path $TestDrive 'hostpool-network-vectors.bicep'
        $imports = (@('resolvePaasNetworking', 'requirePrivateEndpointSubnet') |
            Where-Object { $Expression.Contains($_) }) -join ', '
        [IO.File]::WriteAllText($fixture, @"
targetScope = 'local'
import { $imports } from '$networkingModule'
output encodedResults string = base64(string({ results: $Expression }))
"@)
        (Invoke-TestNamingVectors -TemplateFile $fixture).results.value
    }

    function Get-NetworkSchema {
        param($Schema)
        if ($Schema.'$ref') {
            return $template.definitions.($Schema.'$ref'.Replace('#/definitions/', ''))
        }
        $Schema
    }

    $vectors = Invoke-HostPoolNetworkVector @"
{
  defaults: resolvePaasNetworking({}, true, true, true)
  partial: resolvePaasNetworking({ storage: { permittedIPs: ['203.0.113.0/24'] } }, true, true, false)
  explicitFalse: resolvePaasNetworking({ privateEndpoint: false, storage: { privateEndpoint: false }, backup: { privateEndpoint: false }, disk: { privateEndpoint: false } }, true, true, true)
  mixed: resolvePaasNetworking({ storage: { publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false, permittedIPs: ['203.0.113.0/24'] } }, true, true, true)
  restricted: resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false, storage: { permittedIPs: ['203.0.113.0/24'] }, keyVault: { serviceEndpointSubnetResourceIds: ['/vault-subnet'] }, backup: { publicNetworkAccess: 'Enabled', privateEndpoint: false } }, true, true, true)
  privateBackup: resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false, storage: { permittedIPs: ['203.0.113.0/24'] }, keyVault: { permittedIPs: ['198.51.100.0/24'] }, backup: { publicNetworkAccess: 'Disabled', privateEndpoint: true } }, true, true, true)
  existing: resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false }, false, false, false)
  modes: map(['Disabled', 'EnabledWithRestrictions', 'Enabled'], mode => map([false, true], pe => resolvePaasNetworking({ publicNetworkAccess: mode, privateEndpoint: pe, storage: { permittedIPs: ['203.0.113.0/24'], serviceEndpointSubnetResourceIds: ['/storage-subnet'] }, keyVault: { permittedIPs: ['198.51.100.0/24'], serviceEndpointSubnetResourceIds: ['/vault-subnet'] }, backup: { publicNetworkAccess: 'Disabled' } }, true, true, true)))
}
"@
}

Describe 'Standard host pool typed networking contract' {
    It 'replaces eighteen flat inputs with three sealed typed objects' {
        @($template.parameters.PSObject.Properties).Count | Should -Be 134
        foreach ($name in @('paasNetworking', 'privateEndpointSubnetResourceIds', 'privateDnsZoneResourceIds')) {
            $schema = Get-NetworkSchema $template.parameters.$name
            $schema.type | Should -Be 'object'
            $schema.additionalProperties | Should -Be $false
            @($template.parameters.$name.defaultValue.PSObject.Properties).Count | Should -Be 0
        }
        foreach ($old in @(
            'storagePublicNetworkAccess', 'storagePrivateEndpoint', 'storagePermittedIPs', 'storageServiceEndpointSubnetResourceIds',
            'keyVaultPublicNetworkAccess', 'keyVaultPrivateEndpoint', 'keyVaultPermittedIPs', 'keyVaultServiceEndpointSubnetResourceIds',
            'deployBackupAndDiskPrivateEndpoints', 'sharedResourcesPrivateEndpointSubnetResourceId', 'hostPoolResourcesPrivateEndpointSubnetResourceId',
            'backupPrivateDnsZoneResourceId', 'blobPrivateDnsZoneResourceId', 'filePrivateDnsZoneResourceId', 'vaultPrivateDnsZoneResourceId',
            'queuePrivateDnsZoneResourceId', 'avdPrivateDnsZoneResourceId', 'globalFeedPrivateDnsZoneResourceId'
        )) {
            $template.parameters.PSObject.Properties.Name | Should -Not -Contain $old
        }
        $paas = Get-NetworkSchema $template.parameters.paasNetworking
        foreach ($family in @('storage', 'keyVault', 'backup', 'disk')) {
            (Get-NetworkSchema $paas.properties.$family).additionalProperties | Should -Be $false
        }
        $paas.properties.PSObject.Properties.Name | Should -Not -Contain 'functionApp'
        $subnets = Get-NetworkSchema $template.parameters.privateEndpointSubnetResourceIds
        @($subnets.properties.PSObject.Properties.Name | Sort-Object) |
            Should -Be @('hostPoolResources', 'sharedResources')
        $dns = Get-NetworkSchema $template.parameters.privateDnsZoneResourceIds
        @($dns.properties.PSObject.Properties.Name | Sort-Object) |
            Should -Be @('avdFeed', 'avdGlobalFeed', 'backup', 'blob', 'file', 'queue', 'vault')
    }

    It 'normalizes omitted and partial fields securely without merging service allowlists' {
        foreach ($family in @('storage', 'keyVault', 'backup')) {
            $vectors.defaults.$family.publicNetworkAccess | Should -Be 'Disabled'
            $vectors.defaults.$family.privateEndpoint | Should -Be $true
        }
        $vectors.defaults.disk.privateEndpoint | Should -Be $true
        $vectors.partial.storage.permittedIPs | Should -Be @('203.0.113.0/24')
        @($vectors.partial.keyVault.permittedIPs).Count | Should -Be 0
        @($vectors.partial.storage.serviceEndpointSubnetResourceIds).Count | Should -Be 0
        $vectors.partial.storage.privateEndpoint | Should -Be $true
        $vectors.partial.storage.publicNetworkAccess | Should -Be 'Disabled'
    }

    It 'preserves explicit false and limits overrides to their service family' {
        foreach ($family in @('storage', 'keyVault', 'backup', 'disk')) {
            $vectors.explicitFalse.$family.privateEndpoint | Should -Be $false
        }
        $vectors.mixed.storage.publicNetworkAccess | Should -Be 'EnabledWithRestrictions'
        $vectors.mixed.storage.privateEndpoint | Should -Be $false
        $vectors.mixed.keyVault.publicNetworkAccess | Should -Be 'Disabled'
        $vectors.mixed.keyVault.privateEndpoint | Should -Be $true
        $vectors.mixed.backup.privateEndpoint | Should -Be $true
    }

    It 'keeps independent IP and service-endpoint lists in every public mode and PE combination' {
        $modes = @('Disabled', 'EnabledWithRestrictions', 'Enabled')
        for ($m = 0; $m -lt 3; $m++) {
            for ($p = 0; $p -lt 2; $p++) {
                $resolved = $vectors.modes[$m][$p]
                foreach ($family in @('storage', 'keyVault')) {
                    $resolved.$family.publicNetworkAccess | Should -Be $modes[$m]
                    $resolved.$family.privateEndpoint | Should -Be ([bool]$p)
                }
                $resolved.storage.permittedIPs | Should -Be @('203.0.113.0/24')
                $resolved.keyVault.permittedIPs | Should -Be @('198.51.100.0/24')
                $resolved.storage.serviceEndpointSubnetResourceIds | Should -Be @('/storage-subnet')
                $resolved.keyVault.serviceEndpointSubnetResourceIds | Should -Be @('/vault-subnet')
            }
        }
    }

    It 'supports both explicit Backup connectivity choices without requiring a choice for adopted vaults' {
        $vectors.restricted.backup.publicNetworkAccess | Should -Be 'Enabled'
        $vectors.restricted.backup.privateEndpoint | Should -Be $false
        $vectors.privateBackup.backup.publicNetworkAccess | Should -Be 'Disabled'
        $vectors.privateBackup.backup.privateEndpoint | Should -Be $true
        $vectors.existing.backup.publicNetworkAccess | Should -Be 'Disabled'
    }

    It 'rejects invalid networking intent explicitly: <Reason>' -TestCases @(
        @{ Reason = 'missing Backup choice'; Expression = "resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false }, false, false, true)" }
        @{ Reason = 'empty Storage restricted sources'; Expression = "resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false }, true, false, false)" }
        @{ Reason = 'empty Key Vault restricted sources'; Expression = "resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false }, false, true, false)" }
        @{ Reason = 'missing shared endpoint subnet'; Expression = "requirePrivateEndpointSubnet('', true, 'sharedResources')" }
        @{ Reason = 'missing host-pool endpoint subnet'; Expression = "requirePrivateEndpointSubnet('', true, 'hostPoolResources')" }
        @{ Reason = 'whitespace endpoint subnet'; Expression = "requirePrivateEndpointSubnet(' ', true, 'sharedResources')" }
        @{ Reason = 'incomplete endpoint subnet ID'; Expression = "requirePrivateEndpointSubnet('/subscriptions/a/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet', true, 'hostPoolResources')" }
        @{ Reason = 'blank restricted IP sources'; Expression = "resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false, storage: { permittedIPs: [' ', ''] } }, true, false, false)" }
        @{ Reason = 'unsupported Backup firewall mode'; Expression = "resolvePaasNetworking({ backup: { publicNetworkAccess: 'EnabledWithRestrictions' } }, false, false, true)" }
        @{ Reason = 'unsupported service family'; Expression = "resolvePaasNetworking({ functionApp: {} }, false, false, false)" }
        @{ Reason = 'misspelled nested setting'; Expression = "resolvePaasNetworking({ storage: { privateEndpoints: false } }, false, false, false)" }
    ) {
        param($Reason, $Expression)
        { Invoke-HostPoolNetworkVector $Expression } | Should -Throw '*Local naming vectors failed*'
    }

    It 'retains resource-shaped composer interfaces and routes independent policies through them' {
        $template.resources.sharedFilesBackup.properties.parameters.publicNetworkAccess.value |
            Should -Be "[variables('backupPublicNetworkAccess')]"
        $template.resources.sessionHosts.properties.parameters.vaultPublicNetworkAccess.value |
            Should -Be "[variables('backupPublicNetworkAccess')]"
        $template.resources.sessionHosts.properties.parameters.deployBackupPrivateEndpoints.value |
            Should -Be "[variables('backupPrivateEndpoint')]"
        $template.resources.diskAccess.properties.parameters.deployPrivateEndpoint.value |
            Should -Be "[variables('diskPrivateEndpoint')]"
        $template.resources.sharedKeyVaults.properties.parameters.keyVaultPublicNetworkAccess.value |
            Should -Be "[variables('keyVaultPublicNetworkAccess')]"
        $template.resources.fslogix.properties.parameters.storagePublicNetworkAccess.value |
            Should -Be "[variables('storagePublicNetworkAccess')]"
        $template.parameters.avdPrivateLinkPrivateRoutes.defaultValue | Should -Be 'None'
        $template.resources.controlPlane.properties.parameters.avdPrivateLinkPrivateRoutes.value |
            Should -Be "[variables('hostPoolPrivateLinkPrivateRoutes')]"
    }

    It 'validates required subnet IDs without changing their casing or requiring inactive placement' {
        $id = '/subscriptions/a/resourceGroups/NetworkRG/providers/Microsoft.Network/virtualNetworks/HubVNet/subnets/PrivateEndpoints'
        Invoke-HostPoolNetworkVector "requirePrivateEndpointSubnet(' $id ', true, 'sharedResources')" | Should -Be $id
        Invoke-HostPoolNetworkVector "requirePrivateEndpointSubnet('', false, 'hostPoolResources')" | Should -Be ''
    }

    It 'keeps the PoC adapter legacy default while supporting independently supplied vault public access' {
        $hosts = $template.resources.sessionHosts.properties.template
        $hosts.parameters.vaultPublicNetworkAccess.defaultValue |
            Should -Be "[if(parameters('deployBackupPrivateEndpoints'), 'Disabled', 'Enabled')]"
        $hosts.resources.recoveryServicesModule.properties.parameters.publicNetworkAccess.value |
            Should -Be "[parameters('vaultPublicNetworkAccess')]"
    }
}
