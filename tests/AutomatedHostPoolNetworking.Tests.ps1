BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
    $form = Get-Content (Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json') -Raw | ConvertFrom-Json -AsHashtable
    $template = Get-Content (Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $source = Get-Content (Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.bicep') -Raw
    $zero = $form.view.properties.steps | Where-Object name -eq 'zeroTrust'
    $outputs = $form.view.outputs.parameters
    $fixtureDirectory = Join-Path $repoRoot 'deployments\automatedHostPools\.networking-test-fixtures'
    New-Item $fixtureDirectory -ItemType Directory -Force | Out-Null
    $modulePath = [IO.Path]::GetRelativePath($fixtureDirectory, (Join-Path $repoRoot 'deployments\shared\modules\orchestration\networking\scenarios.bicep')).Replace('\', '/')

    . (Join-Path $PSScriptRoot 'UiFormTestHelpers.ps1')

    function New-AutomatedNetworkingSteps {
        @{
            basics = @{ subscription = @{ id = '/subscriptions/a'; displayName = 'Deployment subscription' } }
            controlPlane = @{ workspacesApi = @{ value = @() } }
            hosts = @{
                credentials = @{ source = 'new'; keyVault = @{ id = '/existing/vault' } }
                location = @{ name = 'eastus' }
                network = @{ virtualNetwork = @{ id = '/vnet'; name = 'VNet' } }
            }
            profiles = @{
                profileSolution = 'FSLogix'; deployStorage = $true
                storage = @{ service = 'AzureFiles'; registerBackup = $false; useExistingRecoveryServicesVault = $false }
            }
            zeroTrust = @{
                paasConnectivity = @{ scenario = 'Private' }
                keyManagement = @{ keyManagementDisks = 'PlatformManaged'; keyManagementStorage = 'PlatformManaged'; useExistingEncryptionKv = $false; existingEncryptionKeyVault = @{ id = '/existing/encryption-vault' } }
                storagePrivateNetworking = @{ storagePrivateEndpoint = $true; enablePrivateDNSIntegration = $true; filePrivateDnsZone = '/dns/file' }
                storagePublicNetworking = @{ storagePublicNetworkAccess = 'Disabled' }
                storageServiceEndpointAccess = @{ storagePermittedIPs = @(); storageServiceEndpointSubnets = @() }
                keyVaultPrivateNetworking = @{ keyVaultPrivateEndpoint = $true; enablePrivateDNSIntegration = $true; vaultPrivateDnsZone = '/dns/vault' }
                keyVaultPublicNetworking = @{ keyVaultPublicNetworkAccess = 'Disabled' }
                keyVaultServiceEndpointAccess = @{ keyVaultPermittedIPs = @(); keyVaultServiceEndpointSubnets = @() }
                privateEndpoints = @{
                    backupPrivateEndpoint = $true; backupPublicNetworkAccess = 'Disabled'; backupConnectivity = ''; enablePrivateDNSIntegration = $true
                    backupPrivateDnsZone = '/dns/backup'; blobPrivateDnsZone = '/dns/blob'; queuePrivateDnsZone = '/dns/queue'
                }
                privateEndpointSubnets = @{
                    sharedSubnet = @{ id = '/subnets/shared' }; hostPoolSubnet = @{ id = '/subnets/host-pool' }
                }
                avdPrivateLink = @{
                    enablePrivateLink = $false; privateRoutes = 'HostPool'; enablePrivateDNSIntegration = $true
                    avdPrivateDnsZone = '/dns/avd'; globalFeedPrivateDnsZone = '/dns/global'
                }
            }
        }
    }

    function Invoke-AutomatedNetworkVector {
        param([string]$Expression)
        $fixture = Join-Path $fixtureDirectory 'automated-network-vectors.bicep'
        $imports = (@('resolvePaasNetworking', 'requirePrivateEndpointSubnet') |
            Where-Object { $Expression.Contains($_) }) -join ', '
        [IO.File]::WriteAllText($fixture, @"
targetScope = 'local'
import { $imports } from '$modulePath'
output encodedResults string = base64(string({ results: $Expression }))
"@)
        (Invoke-TestNamingVectors -TemplateFile $fixture).results.value
    }

    function Get-AutomatedSchema($Schema) {
        if ($Schema.ContainsKey('$ref')) {
            return $template.definitions[$Schema.'$ref'.Replace('#/definitions/', '')]
        }
        $Schema
    }

    $vectors = Invoke-AutomatedNetworkVector @"
{
  defaults: resolvePaasNetworking({}, true, true, true)
  partial: resolvePaasNetworking({ storage: { permittedIPs: ['203.0.113.0/24'] } }, true, true, false)
  explicitFalse: resolvePaasNetworking({ privateEndpoint: false, storage: { privateEndpoint: false }, keyVault: { privateEndpoint: false }, backup: { privateEndpoint: false } }, true, true, true)
  restrictedPrivate: resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false, storage: { permittedIPs: ['203.0.113.0/24'] }, keyVault: { serviceEndpointSubnetResourceIds: ['/subnets/vault'] }, backup: { publicNetworkAccess: 'Disabled', privateEndpoint: true } }, true, true, true)
  restrictedPublic: resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false, storage: { permittedIPs: ['203.0.113.0/24'] }, keyVault: { permittedIPs: ['198.51.100.0/24'] }, backup: { publicNetworkAccess: 'Enabled', privateEndpoint: false } }, true, true, true)
  existing: resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false }, false, false, false)
  modes: map(['Disabled', 'EnabledWithRestrictions', 'Enabled'], mode => map([false, true], pe => resolvePaasNetworking({ publicNetworkAccess: mode, privateEndpoint: pe, storage: { permittedIPs: ['203.0.113.0/24'], serviceEndpointSubnetResourceIds: ['/storage-subnet'] }, keyVault: { permittedIPs: ['198.51.100.0/24'], serviceEndpointSubnetResourceIds: ['/vault-subnet'] }, backup: { publicNetworkAccess: 'Disabled' } }, true, true, true)))
}
"@
}

AfterAll {
    if (Test-Path $fixtureDirectory) { Remove-Item $fixtureDirectory -Recurse -Force }
}

Describe 'Automated host pool typed networking backend' {
    It 'replaces eighteen flat parameters with three sealed relevant interfaces' {
        $template.parameters.Count | Should -Be 129
        foreach ($name in @('paasNetworking', 'privateEndpointSubnetResourceIds', 'privateDnsZoneResourceIds')) {
            $schema = Get-AutomatedSchema $template.parameters[$name]
            $schema.type | Should -Be 'object'
            $schema.additionalProperties | Should -Be $false
            $template.parameters[$name].defaultValue.Count | Should -Be 0
        }
        foreach ($old in @(
            'storagePublicNetworkAccess', 'storagePrivateEndpoint', 'storagePermittedIPs', 'storageServiceEndpointSubnetResourceIds',
            'keyVaultPublicNetworkAccess', 'keyVaultPrivateEndpoint', 'keyVaultPermittedIPs', 'keyVaultServiceEndpointSubnetResourceIds',
            'deployBackupPrivateEndpoints', 'sharedResourcesPrivateEndpointSubnetResourceId', 'hostPoolResourcesPrivateEndpointSubnetResourceId',
            'backupPrivateDnsZoneResourceId', 'blobPrivateDnsZoneResourceId', 'filePrivateDnsZoneResourceId', 'vaultPrivateDnsZoneResourceId',
            'queuePrivateDnsZoneResourceId', 'avdPrivateDnsZoneResourceId', 'globalFeedPrivateDnsZoneResourceId'
        )) {
            $template.parameters.ContainsKey($old) | Should -Be $false
            $outputs.ContainsKey($old) | Should -Be $false
        }
        $paas = Get-AutomatedSchema $template.parameters.paasNetworking
        @($paas.properties.Keys | Sort-Object) | Should -Be @('backup', 'keyVault', 'privateEndpoint', 'publicNetworkAccess', 'storage')
        foreach ($family in @('storage', 'keyVault', 'backup')) {
            (Get-AutomatedSchema $paas.properties[$family]).additionalProperties | Should -Be $false
        }
        $template.parameters.disableManagedDiskPublicNetworkAccess.defaultValue | Should -Be $true
    }

    It 'normalizes defaults and partial objects securely with explicit false intact' {
        foreach ($family in @('storage', 'keyVault', 'backup')) {
            $vectors.defaults.$family.publicNetworkAccess | Should -Be 'Disabled'
            $vectors.defaults.$family.privateEndpoint | Should -Be $true
            $vectors.explicitFalse.$family.privateEndpoint | Should -Be $false
        }
        $vectors.partial.storage.permittedIPs | Should -Be @('203.0.113.0/24')
        @($vectors.partial.keyVault.permittedIPs).Count | Should -Be 0
        $vectors.partial.storage.privateEndpoint | Should -Be $true
    }

    It 'keeps independent lists in every public mode and endpoint combination' {
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

    It 'supports explicit Private and Public Backup choices and exempts adopted vaults' {
        $vectors.restrictedPrivate.backup.publicNetworkAccess | Should -Be 'Disabled'
        $vectors.restrictedPrivate.backup.privateEndpoint | Should -Be $true
        $vectors.restrictedPublic.backup.publicNetworkAccess | Should -Be 'Enabled'
        $vectors.restrictedPublic.backup.privateEndpoint | Should -Be $false
        $vectors.existing.backup.publicNetworkAccess | Should -Be 'Disabled'
    }

    It 'rejects an invalid backend vector: <Reason>' -TestCases @(
        @{ Reason = 'implicit Restricted Backup'; Expression = "resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false }, false, false, true)" }
        @{ Reason = 'Restricted Storage without sources'; Expression = "resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false }, true, false, false)" }
        @{ Reason = 'Restricted Key Vault without sources'; Expression = "resolvePaasNetworking({ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false }, false, true, false)" }
        @{ Reason = 'missing shared placement'; Expression = "requirePrivateEndpointSubnet('', true, 'sharedResources')" }
        @{ Reason = 'missing host-pool placement'; Expression = "requirePrivateEndpointSubnet('', true, 'hostPoolResources')" }
    ) {
        param($Reason, $Expression)
        { Invoke-AutomatedNetworkVector $Expression } | Should -Throw '*Local naming vectors failed*'
    }

    It 'routes resource-shaped inputs and separates AVD and managed-disk policies' {
        $template.resources.sharedFilesBackup.properties.parameters.publicNetworkAccess.value |
            Should -Be "[variables('networking').backup.publicNetworkAccess]"
        $template.resources.sharedFilesBackup.properties.parameters.privateEndpoint.value |
            Should -Be "[variables('backupPrivateEndpoint')]"
        $template.resources.sharedKeyVaults.properties.parameters.keyVaultPrivateEndpointSubnetResourceId.value |
            Should -Be "[variables('sharedResourcesPrivateEndpointSubnetResourceId')]"
        $template.resources.fslogixStorage.properties.parameters.storagePrivateEndpointSubnetResourceId.value |
            Should -Be "[variables('hostPoolResourcesPrivateEndpointSubnetResourceId')]"
        $template.resources.controlPlane.properties.parameters.hostPoolPrivateEndpointSubnetResourceId.value |
            Should -Be "[variables('hostPoolResourcesPrivateEndpointSubnetResourceId')]"
        $template.resources.sessionHostPolicy.properties.parameters.disableManagedDiskPublicNetworkAccess.value |
            Should -Be "[parameters('disableManagedDiskPublicNetworkAccess')]"
        $source | Should -Match "storagePrivateEndpoint \|\| avdPrivateLinkPrivateRoutes != 'None'"
        $source | Should -Match "keyVaultPrivateEndpoint \|\| backupPrivateEndpoint \|\| contains\(\['FeedAndHostPool', 'All'\]"
        $source | Should -Not -Match 'param .*PrivateEndpointSubnetResourceId string = virtualMachineSubnetResourceId'
    }

    It 'fails explicitly for a missing new Backup DNS zone' {
        $Zone = 'backup'
        $declarations = [regex]::Match($source, '(?s)var backupPrivateDnsZoneResourceId =.+?(?=var avdPrivateDnsZoneResourceId)').Value
        $provided = (@('backup', 'blob', 'queue') | Where-Object { $_ -ne $Zone } | ForEach-Object { "${_}: '/dns/$_'" }) -join ', '
        $fixture = Join-Path $fixtureDirectory 'automated-backup-dns.bicep'
        [IO.File]::WriteAllText($fixture, @"
targetScope = 'local'
import { privateDnsZoneResourceIdsType } from '$modulePath'
param privateDnsZoneResourceIds privateDnsZoneResourceIdsType = { $provided }
var backupPrivateEndpoint = true
$declarations
output encodedResults string = base64(string({ results: [backupPrivateDnsZoneResourceId, blobPrivateDnsZoneResourceId, queuePrivateDnsZoneResourceId] }))
"@)
        { Invoke-TestNamingVectors -TemplateFile $fixture } | Should -Throw '*Local naming vectors failed*'
    }

    It 'allows approved external Blob and Queue DNS handling without disabling the Backup endpoint' {
        $declarations = [regex]::Match($source, '(?s)var backupPrivateDnsZoneResourceId =.+?(?=var avdPrivateDnsZoneResourceId)').Value
        $fixture = Join-Path $fixtureDirectory 'automated-backup-optional-dns.bicep'
        [IO.File]::WriteAllText($fixture, @"
targetScope = 'local'
import { privateDnsZoneResourceIdsType } from '$modulePath'
param privateDnsZoneResourceIds privateDnsZoneResourceIdsType = { backup: '/dns/backup' }
var backupPrivateEndpoint = true
$declarations
output encodedResults string = base64(string({ results: [backupPrivateDnsZoneResourceId, blobPrivateDnsZoneResourceId, queuePrivateDnsZoneResourceId] }))
"@)
        (Invoke-TestNamingVectors -TemplateFile $fixture).results.value | Should -Be @('/dns/backup', '', '')
    }
}

Describe 'Automated host pool networking form semantics' {
    It 'defaults to Private and emits native typed objects with safe arbitrary-string roundtrip' {
        $scenario = ($zero.elements | Where-Object name -eq 'paasConnectivity').elements | Where-Object name -eq 'scenario'
        $scenario.defaultValue | Should -Be 'Private connectivity'
        $steps = New-AutomatedNetworkingSteps
        $steps.zeroTrust.storagePrivateNetworking.filePrivateDnsZone = 'quote " slash \ apostrophe '' unicode ' + [char]0x03A9
        $paas = Invoke-CuiExpression $outputs.paasNetworking $steps -PortalLambdaScope
        $paas.publicNetworkAccess | Should -Be 'Disabled'
        $paas.privateEndpoint | Should -Be $true
        $paas.storage.privateEndpoint | Should -Be $true
        $paas.keyVault.privateEndpoint | Should -Be $true
        $paas.backup.Count | Should -Be 0
        $dns = Invoke-CuiExpression $outputs.privateDnsZoneResourceIds $steps -PortalLambdaScope
        $roundtrip = $dns | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable
        $roundtrip.file | Should -Be $steps.zeroTrust.storagePrivateNetworking.filePrivateDnsZone
        foreach ($name in @('paasNetworking', 'privateEndpointSubnetResourceIds', 'privateDnsZoneResourceIds')) {
            $outputs[$name] | Should -Match '^\[first\(map\(parse\(''\[0\]'''
            $outputs[$name] | Should -Not -Match 'parse\(concat'
        }
    }

    It 'preserves Custom false, family modes and independent lists' {
        $steps = New-AutomatedNetworkingSteps
        $steps.zeroTrust.paasConnectivity.scenario = 'Custom'
        $steps.zeroTrust.storagePrivateNetworking.storagePrivateEndpoint = $false
        $steps.zeroTrust.keyVaultPrivateNetworking.keyVaultPrivateEndpoint = $false
        $steps.zeroTrust.storagePublicNetworking.storagePublicNetworkAccess = 'Enabled'
        $steps.zeroTrust.keyVaultPublicNetworking.keyVaultPublicNetworkAccess = 'EnabledWithRestrictions'
        $steps.zeroTrust.storageServiceEndpointAccess.storagePermittedIPs = @(@{ ipAddress = '203.0.113.0/24' }, @{ ipAddress = '' })
        $steps.zeroTrust.keyVaultServiceEndpointAccess.keyVaultPermittedIPs = @(@{ ipAddress = '198.51.100.0/24' })
        $steps.zeroTrust.storageServiceEndpointAccess.storageServiceEndpointSubnets = @('/storage-only')
        $steps.zeroTrust.keyVaultServiceEndpointAccess.keyVaultServiceEndpointSubnets = @('/vault-only')
        $paas = Invoke-CuiExpression $outputs.paasNetworking $steps -PortalLambdaScope
        $paas.storage.privateEndpoint | Should -Be $false
        $paas.keyVault.privateEndpoint | Should -Be $false
        $paas.storage.publicNetworkAccess | Should -Be 'Enabled'
        $paas.keyVault.publicNetworkAccess | Should -Be 'EnabledWithRestrictions'
        @($paas.storage.permittedIPs).Count | Should -Be 0
        $paas.keyVault.permittedIPs | Should -Be @('198.51.100.0/24')
        @($paas.storage.serviceEndpointSubnetResourceIds).Count | Should -Be 0
        $paas.keyVault.serviceEndpointSubnetResourceIds | Should -Be @('/vault-only')
        $subnets = Invoke-CuiExpression $outputs.privateEndpointSubnetResourceIds $steps -PortalLambdaScope
        $subnets.sharedResources | Should -Be ''
        $subnets.hostPoolResources | Should -Be ''
        $dns = Invoke-CuiExpression $outputs.privateDnsZoneResourceIds $steps -PortalLambdaScope
        @($dns.Values | Where-Object { $_ -ne '' }).Count | Should -Be 0
    }

    It 'emits only Restricted Portal allowlists for <Family> in <Mode> with PE=<PrivateEndpoint>' -TestCases @(
        foreach ($family in @('storage', 'keyVault')) {
            foreach ($mode in @('Disabled', 'EnabledWithRestrictions', 'Enabled')) {
                foreach ($privateEndpoint in @($false, $true)) {
                    @{ Family = $family; Mode = $mode; PrivateEndpoint = $privateEndpoint }
                }
            }
        }
    ) {
        param($Family, $Mode, $PrivateEndpoint)
        $steps = New-AutomatedNetworkingSteps
        $steps.zeroTrust.paasConnectivity.scenario = 'Custom'
        foreach ($familyName in @('storage', 'keyVault')) {
            $steps.zeroTrust["${familyName}PublicNetworking"]["${familyName}PublicNetworkAccess"] = 'EnabledWithRestrictions'
            $steps.zeroTrust["${familyName}ServiceEndpointAccess"]["${familyName}PermittedIPs"] = @(@{ ipAddress = "203.0.113.$(if ($familyName -eq 'storage') { 10 } else { 20 })" })
            $steps.zeroTrust["${familyName}ServiceEndpointAccess"]["${familyName}ServiceEndpointSubnets"] = @("/subnets/$familyName", '')
        }
        $steps.zeroTrust["${Family}PublicNetworking"]["${Family}PublicNetworkAccess"] = $Mode
        $steps.zeroTrust["${Family}PrivateNetworking"]["${Family}PrivateEndpoint"] = $PrivateEndpoint
        $paas = Invoke-CuiExpression $outputs.paasNetworking $steps -PortalLambdaScope
        $paas[$Family].publicNetworkAccess | Should -Be $Mode
        $paas[$Family].privateEndpoint | Should -Be $PrivateEndpoint
        $other = if ($Family -eq 'storage') { 'keyVault' } else { 'storage' }
        $paas[$other].permittedIPs | Should -Be $steps.zeroTrust["${other}ServiceEndpointAccess"]["${other}PermittedIPs"][0].ipAddress
        $paas[$other].serviceEndpointSubnetResourceIds | Should -Be @("/subnets/$other")
        if ($Mode -eq 'EnabledWithRestrictions') {
            $paas[$Family].permittedIPs | Should -Be $steps.zeroTrust["${Family}ServiceEndpointAccess"]["${Family}PermittedIPs"][0].ipAddress
            $paas[$Family].serviceEndpointSubnetResourceIds | Should -Be @("/subnets/$Family")
        } else {
            @($paas[$Family].permittedIPs).Count | Should -Be 0
            @($paas[$Family].serviceEndpointSubnetResourceIds).Count | Should -Be 0
            $steps.zeroTrust["${Family}ServiceEndpointAccess"]["${Family}PermittedIPs"] = $null
            $steps.zeroTrust["${Family}ServiceEndpointAccess"]["${Family}ServiceEndpointSubnets"] = $null
            $cold = Invoke-CuiExpression $outputs.paasNetworking $steps -PortalLambdaScope
            @($cold[$Family].permittedIPs).Count | Should -Be 0
            @($cold[$Family].serviceEndpointSubnetResourceIds).Count | Should -Be 0
        }
    }

    It 'uses the effective <Scenario> scenario rather than stale Custom family modes' -TestCases @(
        @{ Scenario = 'Private' }; @{ Scenario = 'Restricted' }
    ) {
        param($Scenario)
        $steps = New-AutomatedNetworkingSteps
        $steps.zeroTrust.paasConnectivity.scenario = $Scenario
        foreach ($family in @('storage', 'keyVault')) {
            $steps.zeroTrust["${family}PublicNetworking"]["${family}PublicNetworkAccess"] = if ($Scenario -eq 'Private') { 'EnabledWithRestrictions' } else { 'Enabled' }
            $steps.zeroTrust["${family}ServiceEndpointAccess"]["${family}PermittedIPs"] = @(@{ ipAddress = '203.0.113.10' })
            $steps.zeroTrust["${family}ServiceEndpointAccess"]["${family}ServiceEndpointSubnets"] = @("/subnets/$family")
        }
        $paas = Invoke-CuiExpression $outputs.paasNetworking $steps -PortalLambdaScope
        foreach ($family in @('storage', 'keyVault')) {
            if ($Scenario -eq 'Restricted') {
                $paas[$family].permittedIPs | Should -Be @('203.0.113.10')
                $paas[$family].serviceEndpointSubnetResourceIds | Should -Be @("/subnets/$family")
            } else {
                @($paas[$family].permittedIPs).Count | Should -Be 0
                @($paas[$family].serviceEndpointSubnetResourceIds).Count | Should -Be 0
            }
        }
    }

    It 'blocks an empty Restricted Backup choice and supports both explicit paths' {
        $steps = New-AutomatedNetworkingSteps
        $steps.profiles.storage.registerBackup = $true
        $steps.zeroTrust.paasConnectivity.scenario = 'Restricted'
        $backup = $zero.elements | Where-Object name -eq 'privateEndpoints'
        $prereq = $backup.elements | Where-Object name -eq 'backupChoicePrerequisite'
        Invoke-CuiExpression $prereq.visible $steps | Should -Be $true
        Invoke-CuiExpression $prereq.constraints.validations[0].isValid $steps | Should -Be $false
        foreach ($choice in @('Private', 'Public')) {
            $steps.zeroTrust.privateEndpoints.backupConnectivity = $choice
            Invoke-CuiExpression $prereq.constraints.validations[0].isValid $steps | Should -Be $true
            $paas = Invoke-CuiExpression $outputs.paasNetworking $steps -PortalLambdaScope
            $paas.backup.privateEndpoint | Should -Be ($choice -eq 'Private')
            $paas.backup.publicNetworkAccess | Should -Be $(if ($choice -eq 'Private') { 'Disabled' } else { 'Enabled' })
        }
        $steps.profiles.storage.useExistingRecoveryServicesVault = $true
        $steps.zeroTrust.privateEndpoints.backupConnectivity = ''
        Invoke-CuiExpression $prereq.visible $steps | Should -Be $false
        (Invoke-CuiExpression $outputs.paasNetworking $steps -PortalLambdaScope).backup.Count | Should -Be 0
    }

    It 'suppresses inactive families and retains AVD-only placement independent of PaaS scenario' {
        $steps = New-AutomatedNetworkingSteps
        $steps.profiles.deployStorage = $false
        $steps.hosts.credentials.source = 'existing'
        $steps.zeroTrust.paasConnectivity.scenario = 'Restricted'
        $steps.controlPlane.workspacesApi.value = $null
        $paas = Invoke-CuiExpression $outputs.paasNetworking $steps -PortalLambdaScope
        foreach ($family in @('storage', 'keyVault', 'backup')) { $paas[$family].Count | Should -Be 0 }
        $subnets = $zero.elements | Where-Object name -eq 'privateEndpointSubnets'
        $shared = $subnets.elements | Where-Object name -eq 'sharedHeader'
        $hostPool = $subnets.elements | Where-Object name -eq 'hostPoolHeader'
        Invoke-CuiExpression $subnets.visible $steps | Should -Be $false
        (Invoke-CuiExpression $outputs.privateDnsZoneResourceIds $steps -PortalLambdaScope).avdGlobalFeed | Should -Be ''
        Invoke-CuiExpression $outputs.existingGlobalFeedResourceId $steps | Should -Be ''
        $steps.zeroTrust.avdPrivateLink.enablePrivateLink = $true
        foreach ($route in @('HostPool', 'FeedAndHostPool', 'All')) {
            $steps.zeroTrust.avdPrivateLink.privateRoutes = $route
            Invoke-CuiExpression $hostPool.visible $steps | Should -Be $true
            Invoke-CuiExpression $shared.visible $steps | Should -Be ($route -ne 'HostPool')
            $placement = Invoke-CuiExpression $outputs.privateEndpointSubnetResourceIds $steps -PortalLambdaScope
            $placement.hostPoolResources | Should -Be '/subnets/host-pool'
            $placement.sharedResources | Should -Be $(if ($route -eq 'HostPool') { '' } else { '/subnets/shared' })
            $dns = Invoke-CuiExpression $outputs.privateDnsZoneResourceIds $steps -PortalLambdaScope
            $dns.avdFeed | Should -Be '/dns/avd'
            $dns.avdGlobalFeed | Should -Be $(if ($route -eq 'All') { '/dns/global' } else { '' })
        }
    }

    It 'blocks missing ownership subnets and Backup DNS without any VM-subnet fallback' {
        $steps = New-AutomatedNetworkingSteps
        $steps.hosts.network.subnet = @{ id = '/subnets/session-hosts' }
        $steps.zeroTrust.privateEndpointSubnets.sharedSubnet.id = ''
        $steps.zeroTrust.privateEndpointSubnets.hostPoolSubnet.id = ''
        $subnets = $zero.elements | Where-Object name -eq 'privateEndpointSubnets'
        foreach ($slot in @('shared', 'hostPool')) {
            $prereq = $subnets.elements | Where-Object name -eq "${slot}SubnetPrerequisite"
            Invoke-CuiExpression $prereq.visible $steps | Should -Be $true
            Invoke-CuiExpression $prereq.constraints.validations[0].isValid $steps | Should -Be $false
        }
        $placement = Invoke-CuiExpression $outputs.privateEndpointSubnetResourceIds $steps -PortalLambdaScope
        $placement.sharedResources | Should -Be ''
        $placement.hostPoolResources | Should -Be ''
        $steps.profiles.storage.registerBackup = $true
        $backup = $zero.elements | Where-Object name -eq 'privateEndpoints'
        $prereq = $backup.elements | Where-Object name -eq 'backupDnsPrerequisite'
        Invoke-CuiExpression $prereq.visible $steps | Should -Be $true
        Invoke-CuiExpression $prereq.constraints.validations[0].isValid $steps | Should -Be $true
        $steps.zeroTrust.privateEndpoints.backupPrivateDnsZone = ''
        Invoke-CuiExpression $prereq.constraints.validations[0].isValid $steps | Should -Be $false
        $steps.zeroTrust.privateEndpoints.backupPrivateDnsZone = '/dns/backup'
        $steps.zeroTrust.privateEndpoints.enablePrivateDNSIntegration = $false
        $dns = Invoke-CuiExpression $outputs.privateDnsZoneResourceIds $steps -PortalLambdaScope
        $dns.backup | Should -Be '/dns/backup'
        $dns.blob | Should -Be ''
        $dns.queue | Should -Be ''
        Invoke-CuiExpression $prereq.constraints.validations[0].isValid $steps | Should -Be $true
        $steps.profiles.storage.useExistingRecoveryServicesVault = $true
        Invoke-CuiExpression $prereq.visible $steps | Should -Be $false
    }

    It 'has guarded cross-subscription ownership inventory, independent eligible lists and literal explanatory text' {
        $subnets = $zero.elements | Where-Object name -eq 'privateEndpointSubnets'
        foreach ($slot in @('shared', 'hostPool')) {
            ($subnets.elements | Where-Object name -eq "${slot}Subscription").type | Should -Be 'Microsoft.Common.SubscriptionSelector'
            ($subnets.elements | Where-Object name -eq "${slot}VirtualNetworksApi").condition | Should -Match 'subscriptionId'
            ($subnets.elements | Where-Object name -eq "${slot}VirtualNetwork").constraints.allowedValues | Should -Match 'Resource Group:'
            ($subnets.elements | Where-Object name -eq "${slot}SubnetPrerequisite").constraints.validations.Count | Should -Be 1
        }
        foreach ($family in @('storage', 'keyVault')) {
            $section = $zero.elements | Where-Object name -eq "${family}ServiceEndpointAccess"
            $allowed = $section.elements | Where-Object name -eq "${family}ServiceEndpointSubnets"
            $allowed.multiselect | Should -Be $true
            $allowed.constraints.allowedValues | Should -Match 'Resource Group:'
            $allowed.constraints.allowedValues | Should -Match '\|'
            $allowed.constraints.allowedValues | Should -Match $(if ($family -eq 'storage') { 'Microsoft.Storage' } else { 'Microsoft.KeyVault' })
        }
        foreach ($element in $zero.elements) {
            foreach ($child in @($element) + @($element.elements)) {
                if ($child.type -eq 'Microsoft.Common.TextBlock') {
                    $child.options.text | Should -Not -Match '^\['
                }
            }
        }
        foreach ($name in $outputs.Keys) { $template.parameters.ContainsKey($name) | Should -Be $true }
    }
}
