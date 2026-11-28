BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'UiFormTestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'NamingTestHelpers.ps1')
    $directory = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer'
    $template = Get-Content (Join-Path $directory 'main.json') -Raw | ConvertFrom-Json -Depth 100
    $source = Get-Content (Join-Path $directory 'main.bicep') -Raw
    $form = Get-Content (Join-Path $directory 'uiFormDefinition.json') -Raw | ConvertFrom-Json -AsHashtable
    $outputs = $form.view.outputs.parameters
    $sections = @{}
    foreach ($section in ($form.view.properties.steps | Where-Object name -eq infrastructure).elements) {
        $sections[$section.name] = $section
    }
    $networkingModule = [IO.Path]::GetRelativePath($TestDrive, (Join-Path $repoRoot 'deployments\shared\modules\orchestration\networking\scenarios.bicep')).Replace('\', '/')
    $outboundExpression = [regex]::Match($source, '(?ms)^var functionAppOutboundSubnetResourceId = (.+?)(?=^\s*$)').Groups[1].Value.Trim()
    if (-not $outboundExpression) { throw 'Replacer outbound guard was not found in the entry source.' }

    function Invoke-ReplacerNetworkVector {
        param(
            [string]$Policy = '{}',
            [string]$Placement = '/subscriptions/test/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/pe',
            [string]$Outbound = '/subscriptions/test/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/outbound'
        )
        $fixture = Join-Path $TestDrive 'replacer-network-vector.bicep'
        [IO.File]::WriteAllText($fixture, @"
targetScope = 'local'
import { functionAppPaasNetworkingType, resolveFunctionAppNetworking, requirePrivateEndpointSubnet } from '$networkingModule'
param paasNetworking functionAppPaasNetworkingType = $Policy
param functionAppDelegatedSubnetResourceId string = '$Outbound'
var resolvedNetworking = resolveFunctionAppNetworking(paasNetworking)
var storagePrivateEndpoint = resolvedNetworking.storage.privateEndpoint
var functionAppOutboundSubnetResourceId = $outboundExpression
output encodedResults string = base64(string({ results: {
  networking: resolvedNetworking
  placement: requirePrivateEndpointSubnet('$Placement', storagePrivateEndpoint || resolvedNetworking.functionApp.privateEndpoint, 'sharedResources')
  outbound: functionAppOutboundSubnetResourceId
} }))
"@)
        (Invoke-TestNamingVectors -TemplateFile $fixture).results.value
    }

    function Get-ReplacerSchema($Schema) {
        if ($Schema.'$ref') { return $template.definitions.($Schema.'$ref'.Replace('#/definitions/', '')) }
        $Schema
    }
}

Describe 'Session Host Replacer typed networking' {
    BeforeEach {
        $fixture = @{}
        Set-CuiValue $fixture "steps('infrastructure').paasConnectivity.scenario" 'Private'
        Set-CuiValue $fixture "steps('infrastructure').privateEndpointSubnets.privateEndpointSubnet.id" '/placement/shared'
        Set-CuiValue $fixture "steps('infrastructure').enableVnetIntegration" $true
        Set-CuiValue $fixture "steps('infrastructure').functionAppOutboundSubnet" '/outbound/delegated'
        foreach ($family in @('storage', 'functionApp')) {
            Set-CuiValue $fixture "steps('infrastructure').${family}PrivateNetworking.${family}PrivateEndpoint" $false
            Set-CuiValue $fixture "steps('infrastructure').${family}PrivateNetworking.enablePrivateDNSIntegration" $true
            Set-CuiValue $fixture "steps('infrastructure').${family}PublicNetworking.${family}PublicNetworkAccess" 'Enabled'
            Set-CuiValue $fixture "steps('infrastructure').${family}ServiceEndpointAccess.${family}PermittedIPs" @(@{ ipAddress = "203.0.113.10" }, @{ ipAddress = '' })
            Set-CuiValue $fixture "steps('infrastructure').${family}ServiceEndpointAccess.${family}ServiceEndpointSubnets" @("/source/$family", '')
        }
        foreach ($zone in @('blob', 'table')) {
            Set-CuiValue $fixture "steps('infrastructure').storagePrivateNetworking.${zone}PrivateDnsZone" "/dns/$zone"
        }
        Set-CuiValue $fixture "steps('infrastructure').functionAppPrivateNetworking.websitesPrivateDnsZone" '/dns/websites'
    }

    It 'replaces thirteen flat parameters with three sealed applicable objects' {
        @($template.parameters.PSObject.Properties).Count | Should -Be 108
        foreach ($name in @('paasNetworking', 'privateEndpointSubnetResourceIds', 'privateDnsZoneResourceIds')) {
            (Get-ReplacerSchema $template.parameters.$name).additionalProperties | Should -BeFalse
            @($template.parameters.$name.defaultValue.PSObject.Properties).Count | Should -Be 0
        }
        $policy = Get-ReplacerSchema $template.parameters.paasNetworking
        @($policy.properties.PSObject.Properties.Name | Sort-Object) | Should -Be @('functionApp', 'privateEndpoint', 'publicNetworkAccess', 'storage')
        foreach ($family in @('storage', 'functionApp')) {
            (Get-ReplacerSchema $policy.properties.$family).additionalProperties | Should -BeFalse
            foreach ($suffix in @('PublicNetworkAccess', 'PermittedIPs', 'PrivateEndpoint', 'PrivateEndpointSubnetResourceId', 'ServiceEndpointSubnetResourceIds')) {
                $template.parameters.PSObject.Properties.Name | Should -Not -Contain "$family$suffix"
                $outputs.ContainsKey("$family$suffix") | Should -BeFalse
            }
        }
        (Get-ReplacerSchema $template.parameters.privateEndpointSubnetResourceIds).properties.PSObject.Properties.Name | Should -Be 'sharedResources'
        @((Get-ReplacerSchema $template.parameters.privateDnsZoneResourceIds).properties.PSObject.Properties.Name | Sort-Object) |
            Should -Be @('blob', 'table', 'websites')
        foreach ($name in $outputs.Keys) { $template.parameters.PSObject.Properties.Name | Should -Contain $name }
    }

    It 'keeps the scenario visible and defaults to private connectivity' {
        (Invoke-CuiExpression $sections.paasConnectivity.visible $fixture) | Should -BeTrue
        ($sections.paasConnectivity.elements | Where-Object name -eq scenario).defaultValue | Should -Be 'Private connectivity'
        $policy = Invoke-CuiExpression $outputs.paasNetworking $fixture
        foreach ($family in @('storage', 'functionApp')) {
            $policy[$family].privateEndpoint | Should -BeOfType [bool]
            $policy[$family].privateEndpoint | Should -BeTrue
            $policy[$family].publicNetworkAccess | Should -Be 'Disabled'
            $policy[$family].permittedIPs.Count | Should -Be 0
            $policy[$family].serviceEndpointSubnetResourceIds.Count | Should -Be 0
        }
        (Invoke-CuiExpression $outputs.privateEndpointSubnetResourceIds $fixture).sharedResources | Should -Be '/placement/shared'
        $dns = Invoke-CuiExpression $outputs.privateDnsZoneResourceIds $fixture
        $dns.blob | Should -Be '/dns/blob'
        $dns.table | Should -Be '/dns/table'
        $dns.websites | Should -Be '/dns/websites'
    }

    It 'keeps restricted Storage and operator app/SCM sources independent with no private endpoints' {
        Set-CuiValue $fixture "steps('infrastructure').paasConnectivity.scenario" 'Restricted'
        Set-CuiValue $fixture "steps('infrastructure').functionAppServiceEndpointAccess.functionAppPermittedIPs" @(@{ ipAddress = '198.51.100.0/24' })
        $policy = Invoke-CuiExpression $outputs.paasNetworking $fixture
        $policy.privateEndpoint | Should -BeFalse
        $policy.publicNetworkAccess | Should -Be 'EnabledWithRestrictions'
        foreach ($family in @('storage', 'functionApp')) {
            $policy[$family].privateEndpoint | Should -BeFalse
            $policy[$family].publicNetworkAccess | Should -Be 'EnabledWithRestrictions'
            $policy[$family].serviceEndpointSubnetResourceIds | Should -Be @("/source/$family")
        }
        $policy.storage.permittedIPs | Should -Be @('203.0.113.10')
        $policy.functionApp.permittedIPs | Should -Be @('198.51.100.0/24')
        (Invoke-CuiExpression $outputs.privateEndpointSubnetResourceIds $fixture).sharedResources | Should -Be ''
        foreach ($zone in (Invoke-CuiExpression $outputs.privateDnsZoneResourceIds $fixture).Values) { $zone | Should -Be '' }
    }

    It 'requires an explicit source for each restricted family without a private endpoint' {
        Set-CuiValue $fixture "steps('infrastructure').paasConnectivity.scenario" 'Restricted'
        foreach ($family in @('storage', 'functionApp')) {
            $guard = $sections["${family}ServiceEndpointAccess"].elements | Where-Object name -eq allowlistPrerequisite
            (Invoke-CuiExpression $guard.visible $fixture) | Should -BeTrue
            Set-CuiValue $fixture "steps('infrastructure').${family}ServiceEndpointAccess.${family}PermittedIPs" @()
            Set-CuiValue $fixture "steps('infrastructure').${family}ServiceEndpointAccess.${family}ServiceEndpointSubnets" @('')
            (Invoke-CuiExpression $guard.constraints.validations[0].isValid $fixture) | Should -BeFalse
            Set-CuiValue $fixture "steps('infrastructure').${family}ServiceEndpointAccess.${family}PermittedIPs" @(@{ ipAddress = '203.0.113.10' })
            (Invoke-CuiExpression $guard.constraints.validations[0].isValid $fixture) | Should -BeTrue
        }
    }

    It 'uses one shared placement selector and does not infer outbound integration or sources' {
        foreach ($family in @('storage', 'functionApp')) {
            $sections["${family}PrivateNetworking"].elements.name | Should -Not -Contain 'privateEndpointSubnet'
        }
        $placementGuard = $sections.privateEndpointSubnets.elements | Where-Object name -eq subnetPrerequisite
        Set-CuiValue $fixture "steps('infrastructure').privateEndpointSubnets.privateEndpointSubnet.id" ''
        (Invoke-CuiExpression $placementGuard.constraints.validations[0].isValid $fixture) | Should -BeFalse
        $outboundGuard = $sections.paasConnectivity.elements | Where-Object name -eq outboundPrerequisite
        foreach ($enabled in @($false, $true)) {
            Set-CuiValue $fixture "steps('infrastructure').enableVnetIntegration" $enabled
            (Invoke-CuiExpression $outboundGuard.constraints.validations[0].isValid $fixture) | Should -Be $enabled
        }
        Set-CuiValue $fixture "steps('infrastructure').functionAppOutboundSubnet" ''
        (Invoke-CuiExpression $outboundGuard.constraints.validations[0].isValid $fixture) | Should -BeFalse
    }

    It 'supports custom headless timers and private operator access independently of runtime Storage' {
        Set-CuiValue $fixture "steps('infrastructure').paasConnectivity.scenario" 'Custom'
        Set-CuiValue $fixture "steps('infrastructure').storagePublicNetworking.storagePublicNetworkAccess" 'EnabledWithRestrictions'
        Set-CuiValue $fixture "steps('infrastructure').functionAppPublicNetworking.functionAppPublicNetworkAccess" 'Disabled'
        foreach ($endpoint in @($false, $true)) {
            Set-CuiValue $fixture "steps('infrastructure').functionAppPrivateNetworking.functionAppPrivateEndpoint" $endpoint
            $policy = Invoke-CuiExpression $outputs.paasNetworking $fixture
            $policy.storage.privateEndpoint | Should -BeFalse
            $policy.functionApp.privateEndpoint | Should -Be $endpoint
            $policy.functionApp.publicNetworkAccess | Should -Be 'Disabled'
            $policy.functionApp.permittedIPs.Count | Should -Be 0
            (Invoke-CuiExpression $outputs.privateEndpointSubnetResourceIds $fixture).sharedResources |
                Should -Be $(if ($endpoint) { '/placement/shared' } else { '' })
            $outboundGuard = $sections.paasConnectivity.elements | Where-Object name -eq outboundPrerequisite
            (Invoke-CuiExpression $outboundGuard.visible $fixture) | Should -BeFalse
        }
    }

    It 'supports external DNS without leaking retained zone IDs' {
        foreach ($family in @('storage', 'functionApp')) {
            Set-CuiValue $fixture "steps('infrastructure').${family}PrivateNetworking.enablePrivateDNSIntegration" $false
        }
        foreach ($zone in (Invoke-CuiExpression $outputs.privateDnsZoneResourceIds $fixture).Values) { $zone | Should -Be '' }
        (Invoke-CuiExpression $outputs.paasNetworking $fixture).functionApp.privateEndpoint | Should -BeTrue
    }

    It 'preserves quoted source strings as native arrays rather than interpolated JSON' {
        Set-CuiValue $fixture "steps('infrastructure').paasConnectivity.scenario" 'Restricted'
        Set-CuiValue $fixture "steps('infrastructure').storageServiceEndpointAccess.storagePermittedIPs" @(@{ ipAddress = "literal'quoted" })
        $policy = Invoke-CuiExpression $outputs.paasNetworking $fixture
        ,$policy.storage.permittedIPs | Should -BeOfType [array]
        $policy.storage.permittedIPs | Should -Be @("literal'quoted")
    }

    It 'preserves shared SCM restrictions and optional Blob/Table DNS with no Queue storage' {
        $app = $template.resources.functionApp.properties.template
        $app.resources.functionApp.properties.siteConfig.scmIpSecurityRestrictionsUseMain | Should -BeTrue
        $template.resources.functionApp.properties.parameters.enableQueueStorage.value | Should -BeFalse
        $template.resources.functionApp.properties.parameters.enableTableStorage.value | Should -BeTrue
        $template.resources.functionApp.properties.parameters.functionAppDelegatedSubnetResourceId.value |
            Should -Be "[variables('functionAppOutboundSubnetResourceId')]"
        $sections.functionAppServiceEndpointAccess.elements.name | Should -Contain 'operatorAccessInfo'
        ($sections.functionAppPrivateNetworking.elements | Where-Object name -eq privateEndpointInfo).options.text |
            Should -Match 'app and SCM records'
    }

    It 'resolves empty backend objects securely and preserves the outbound route' {
        $vector = Invoke-ReplacerNetworkVector
        foreach ($family in @('storage', 'functionApp')) {
            $vector.networking.$family.privateEndpoint | Should -BeTrue
            $vector.networking.$family.publicNetworkAccess | Should -Be 'Disabled'
        }
        $vector.outbound | Should -Match '/subnets/outbound$'
        $vector.placement | Should -Match '/subnets/pe$'
    }

    It 'rejects missing private placement and missing outbound integration through the actual entry guard' {
        $outboundExpression | Should -Match "fail\('functionAppDelegatedSubnetResourceId is required"
        { Invoke-ReplacerNetworkVector -Placement '' } | Should -Throw '*Local naming vectors failed*'
        { Invoke-ReplacerNetworkVector -Outbound ' ' } | Should -Throw '*Local naming vectors failed*'
    }

    It 'rejects source-free restricted backend configuration separately for Storage and app' {
        { Invoke-ReplacerNetworkVector -Policy "{ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false, functionApp: { permittedIPs: ['198.51.100.0/24'] } }" } |
            Should -Throw '*Storage*'
        { Invoke-ReplacerNetworkVector -Policy "{ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false, storage: { permittedIPs: ['203.0.113.10'] } }" } |
            Should -Throw '*Function App*'
        { Invoke-ReplacerNetworkVector -Policy "{ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false, storage: { permittedIPs: [' '] }, functionApp: { permittedIPs: ['198.51.100.0/24'] } }" } |
            Should -Throw '*Storage*'
    }

    It 'preserves explicit false and allows restricted operator rules without private placement or outbound integration' {
        $vector = Invoke-ReplacerNetworkVector -Policy "{ publicNetworkAccess: 'EnabledWithRestrictions', privateEndpoint: false, storage: { permittedIPs: ['203.0.113.10'] }, functionApp: { permittedIPs: ['198.51.100.0/24'] } }" -Placement '' -Outbound ''
        $vector.networking.storage.privateEndpoint | Should -BeFalse
        $vector.networking.functionApp.privateEndpoint | Should -BeFalse
        $vector.networking.storage.permittedIPs | Should -Be @('203.0.113.10')
        $vector.networking.functionApp.permittedIPs | Should -Be @('198.51.100.0/24')
        $vector.placement | Should -Be ''
        $vector.outbound | Should -Be ''
    }
}
