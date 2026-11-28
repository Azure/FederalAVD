BeforeDiscovery {
    $formCases = @(
        @{ Folder = 'hostpools'; Step = 'zeroTrust'; Services = @('storage', 'keyVault') }
        @{ Folder = 'automatedHostPools'; Step = 'zeroTrust'; Services = @('storage', 'keyVault') }
        @{ Folder = 'sharedServices'; Step = 'operations'; Services = @('keyVault') }
        @{ Folder = 'add-ons\fslogixStorage'; Step = 'zeroTrust'; Services = @('storage') }
        @{ Folder = 'add-ons\sessionHostReplacer'; Step = 'infrastructure'; Services = @('storage', 'functionApp') }
        @{ Folder = 'add-ons\imageValidation'; Step = 'functionApp'; Services = @('storage', 'keyVault', 'functionApp') }
        @{ Folder = 'add-ons\fslogixProfileManagement'; Step = 'functionApp'; Services = @('storage', 'keyVault', 'functionApp') }
        @{ Folder = 'hostpoolPoc'; Step = 'options'; Services = @('storage') }
        @{ Folder = 'imageManagement'; Step = 'storageAccounts'; Services = @('storage') }
    )
    $sharedEndpointCases = @(
        foreach ($mask in 0..31) {
            @{
                Mask = $mask
                Secrets = [bool]($mask -band 1)
                Encryption = [bool]($mask -band 2)
                Backup = [bool]($mask -band 4)
                Feed = [bool]($mask -band 8)
                Global = [bool]($mask -band 16)
            }
        }
    )
    function Get-DnsPresentationCases($Elements, $Reference, $Folder) {
        foreach ($element in $Elements) {
            $path = "$Reference.$($element.name)"
            if ($element.type -eq 'Microsoft.Common.DropDown' -and $element.name -match 'PrivateDnsZone$') {
                $namespaces = @{
                    file = 'privatelink.file.'
                    blob = 'privatelink.blob.'
                    queue = 'privatelink.queue.'
                    table = 'privatelink.table.'
                    vault = 'privatelink.vaultcore.'
                    websites = 'privatelink.azurewebsites.'
                    backup = '.backup.'
                    avd = 'privatelink.wvd.'
                    feed = 'privatelink.wvd.'
                    global = 'privatelink-global.wvd.'
                    globalFeed = 'privatelink-global.wvd.'
                }
                $namespace = $namespaces[$element.name -replace 'PrivateDnsZone$', '']
                $api = [regex]::Match($element.constraints.allowedValues, "steps\('[^']+'\)(?:\.[A-Za-z_][A-Za-z0-9_]*)+\.value").Value
                @{
                    Folder = $Folder
                    Reference = $path
                    Control = $element
                    Namespace = $namespace
                    ApiReference = $api -replace '\.value$', ''
                }
            }
            if ($element.elements) {
                Get-DnsPresentationCases $element.elements $path $Folder
            }
        }
    }
    $root = Split-Path -Parent $PSScriptRoot
    $dnsPresentationCases = @(
        Get-ChildItem -LiteralPath (Join-Path $root 'deployments') -Filter 'uiFormDefinition.json' -Recurse -File |
            ForEach-Object {
                $folder = $_.DirectoryName.Substring($root.Length + 1)
                $form = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable
                foreach ($step in $form.view.properties.steps) {
                    Get-DnsPresentationCases $step.elements "steps('$($step.name)')" $folder
                }
            }
    )
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot

    # This bounded evaluator executes the documented functions used by these selectors.
    # It is not a Portal emulator; live rendering and API response transforms still require smoke tests.
    . (Join-Path $PSScriptRoot 'UiFormTestHelpers.ps1')

    function Get-GroupedNetworkingBindings($Parameters) {
        $result = $Parameters.Clone()
        $paasProperties = (ConvertTo-CuiAst $Parameters.paasNetworking).Arguments[0].Arguments[1].Body.Properties
        foreach ($family in @('storage', 'keyVault', 'functionApp')) {
            if (-not $paasProperties.ContainsKey($family)) { continue }
            $outer = ConvertTo-CuiAst (Get-CuiObjectBinding $Parameters.paasNetworking $family)
            $owner = ConvertFrom-CuiAst $outer.Arguments[0]
            $native = "[$(ConvertFrom-CuiAst $outer.Arguments[1])]"
            foreach ($pair in @(
                @{ Key = 'publicNetworkAccess'; Suffix = 'PublicNetworkAccess'; Fallback = "'Disabled'" }
                @{ Key = 'privateEndpoint'; Suffix = 'PrivateEndpoint'; Fallback = 'false' }
                @{ Key = 'permittedIPs'; Suffix = 'PermittedIPs'; Fallback = "parse('[]')" }
                @{ Key = 'serviceEndpointSubnetResourceIds'; Suffix = 'ServiceEndpointSubnetResourceIds'; Fallback = "parse('[]')" }
            )) {
                $inner = Get-CuiObjectBinding $native $pair.Key
                $result["$family$($pair.Suffix)"] = "[if($owner, $($inner.Substring(1, $inner.Length - 2)), $($pair.Fallback))]"
            }
        }
        $placementProperties = (ConvertTo-CuiAst $Parameters.privateEndpointSubnetResourceIds).Arguments[0].Arguments[1].Body.Properties
        foreach ($pair in @(
            @{ Key = 'sharedResources'; Old = 'sharedResourcesPrivateEndpointSubnetResourceId' }
            @{ Key = 'hostPoolResources'; Old = 'hostPoolResourcesPrivateEndpointSubnetResourceId' }
        )) {
            if ($placementProperties.ContainsKey($pair.Key)) {
                $result[$pair.Old] = Get-CuiObjectBinding $Parameters.privateEndpointSubnetResourceIds $pair.Key
            }
        }
        if ($paasProperties.ContainsKey('storage') -and -not $placementProperties.ContainsKey('hostPoolResources')) {
            $result.storagePrivateEndpointSubnetResourceId = Get-CuiObjectBinding $Parameters.privateEndpointSubnetResourceIds 'sharedResources'
        }
        if ($paasProperties.ContainsKey('functionApp')) {
            $placement = Get-CuiObjectBinding $Parameters.privateEndpointSubnetResourceIds 'sharedResources'
            foreach ($family in @('storage', 'functionApp')) {
                $endpoint = $result["${family}PrivateEndpoint"]
                $result["${family}PrivateEndpointSubnetResourceId"] = "[if($($endpoint.Substring(1, $endpoint.Length - 2)), $($placement.Substring(1, $placement.Length - 2)), '')]"
            }
        }
        $dnsProperties = (ConvertTo-CuiAst $Parameters.privateDnsZoneResourceIds).Arguments[0].Arguments[1].Body.Properties
        foreach ($pair in @(
            @{ Key = 'backup'; Old = 'backup' }; @{ Key = 'blob'; Old = 'blob' }
            @{ Key = 'file'; Old = 'file' }; @{ Key = 'vault'; Old = 'vault' }
            @{ Key = 'queue'; Old = 'queue' }; @{ Key = 'avdFeed'; Old = 'avd' }
            @{ Key = 'avdGlobalFeed'; Old = 'globalFeed' }
            @{ Key = 'table'; Old = 'table' }; @{ Key = 'websites'; Old = 'websites' }
        )) {
            if ($dnsProperties.ContainsKey($pair.Key)) {
                $result["$($pair.Old)PrivateDnsZoneResourceId"] = Get-CuiObjectBinding $Parameters.privateDnsZoneResourceIds $pair.Key
            }
        }
        return $result
    }

    function New-SubnetFixture([string] $Vnet, [string] $Group, [string] $Name, [string[]] $Endpoints) {
        return @{
            name = $Name
            id = "/subscriptions/test/resourceGroups/$Group/providers/Microsoft.Network/virtualNetworks/$Vnet/subnets/$Name"
            properties = @{ serviceEndpoints = @($Endpoints | ForEach-Object { @{ service = $_ } }) }
        }
    }

    function New-FormFixture($Step) {
        $same1 = New-SubnetFixture 'east-one' 'rg-one' 'all-services' @('Microsoft.Storage', 'Microsoft.KeyVault', 'Microsoft.Web')
        $same2 = New-SubnetFixture 'east-two' 'rg-two' 'regional-storage' @('Microsoft.Storage')
        $other = New-SubnetFixture 'west-one' 'rg-three' 'wrong-region' @('Microsoft.Storage')
        $global = New-SubnetFixture 'west-one' 'rg-three' 'global-storage' @('Microsoft.Storage.Global')
        $none = New-SubnetFixture 'east-one' 'rg-one' 'unconfigured' @()
        $none.properties.Remove('serviceEndpoints')
        $subnets = @($same1, $same2, $other, $global, $none)
        $vnets = @(
            @{ name = 'east-one'; id = ($same1.id -replace '/subnets/.*$', ''); location = 'eastus'; properties = @{ subnets = @($same1, $none) } }
            @{ name = 'east-two'; id = ($same2.id -replace '/subnets/.*$', ''); location = 'eastus'; properties = @{ subnets = @($same2) } }
            @{ name = 'west-one'; id = ($other.id -replace '/subnets/.*$', ''); location = 'westus'; properties = @{ subnets = @($other, $global) } }
        )
        $state = @{}
        $subscription = @{ id = '/subscriptions/test'; subscriptionId = 'test' }
        foreach ($reference in @(
            "steps('hosts').scope.subscription", "steps('basics').subscription",
            "steps('basics').scope.subscription", "steps('scope').resourceScope.subscription"
        )) { Set-CuiValue $state $reference $subscription }
        foreach ($reference in @(
            "steps('hosts').scope.location.name", "steps('hosts').location.name",
            "steps('basics').location.name", "steps('basics').scope.location.name",
            "steps('scope').resourceScope.location.name"
        )) { Set-CuiValue $state $reference 'eastus' }
        foreach ($reference in @(
            "steps('zeroTrust').permittedIPsSection.paasPublicNetworkAccess",
            "steps('operations').permittedIPsSection.paasPublicNetworkAccess",
            "steps('zeroTrust').privateNetworking.paasPublicNetworkAccess",
            "steps('zeroTrust').publicNetworking.paasPublicNetworkAccess",
            "steps('infrastructure').paasPublicNetworkAccess",
            "steps('functionApp').serviceEndpointAccess.paasPublicNetworkAccess",
            "steps('options').serviceEndpointAccess.paasPublicNetworkAccess",
            "steps('storageAccounts').storageSettings.paasPublicNetworkAccess"
        )) { Set-CuiValue $state $reference 'EnabledWithRestrictions' }
        Set-CuiValue $state "steps('controlPlane').hostPool.type" 'Pooled'
        Set-CuiValue $state "steps('zeroTrust').paasConnectivity.scenario" 'Custom'
        Set-CuiValue $state "steps('operations').paasConnectivity.scenario" 'Custom'
        Set-CuiValue $state "steps('storageAccounts').paasConnectivity.scenario" 'Custom'
        Set-CuiValue $state "steps('infrastructure').paasConnectivity.scenario" 'Custom'
        Set-CuiValue $state "steps('zeroTrust').privateEndpoints.backupPrivateEndpoint" $false
        Set-CuiValue $state "steps('zeroTrust').privateEndpoints.diskPrivateEndpoint" $false
        Set-CuiValue $state "steps('zeroTrust').privateEndpoints.backupPublicNetworkAccess" 'Disabled'
        Set-CuiValue $state "steps('userProfiles').profileSolution" 'FSLogix'
        Set-CuiValue $state "steps('userProfiles').deployStorage" $true
        Set-CuiValue $state "steps('userProfiles').storageService" 'AzureFiles'
        Set-CuiValue $state "steps('profiles').profileSolution" 'FSLogix'
        Set-CuiValue $state "steps('profiles').deployStorage" $true
        Set-CuiValue $state "steps('profiles').storage.service" 'AzureFiles'
        Set-CuiValue $state "steps('storage').storageService" 'AzureFilesPremium'
        Set-CuiValue $state "steps('hosts').identity.source" 'manual'
        Set-CuiValue $state "steps('hosts').identity.deploySecretsKeyVault" $true
        Set-CuiValue $state "steps('hosts').credentials.source" 'create'
        Set-CuiValue $state "steps('hosts').credentials.keyVault.id" '/subscriptions/test/resourceGroups/shared/providers/Microsoft.KeyVault/vaults/credentials'
        Set-CuiValue $state "steps('hosts').diskEncryption.confidentialVMOSDiskEncryption" $false
        Set-CuiValue $state "steps('operationsAndMonitoring').backup.recoveryServices" $false
        Set-CuiValue $state "steps('operationsAndMonitoring').backup.useExistingRecoveryServicesVault" $false
        Set-CuiValue $state "steps('zeroTrust').keyManagement.useExistingEncryptionKv" $false
        Set-CuiValue $state "steps('zeroTrust').keyManagement.existingEncryptionKeyVault.id" '/subscriptions/test/resourceGroups/shared/providers/Microsoft.KeyVault/vaults/encryption'
        foreach ($name in @('Disks', 'Storage', 'RecoveryServicesVault')) {
            Set-CuiValue $state "steps('zeroTrust').keyManagement.keyManagement$name" @('PlatformManaged')
        }
        Set-CuiValue $state "steps('operations').resources.deploySecretsKeyVault" $true
        Set-CuiValue $state "steps('operations').resources.deployEncryptionKeyVault" $true
        Set-CuiValue $state "steps('options').deployFSLogixStorage" $true
        Set-CuiValue $state "steps('storageAccounts').deployArtifactsStorageAccount" $true
        Set-CuiValue $state "steps('storageAccounts').deployBuildLogsStorageAccount" $true
        foreach ($service in @('storage', 'keyVault', 'functionApp')) {
            Set-CuiValue $state "steps('$Step').${service}PublicNetworking.${service}PublicNetworkAccess" 'EnabledWithRestrictions'
            Set-CuiValue $state "steps('$Step').${service}PrivateNetworking.${service}PrivateEndpoint" $true
        }
        Set-CuiValue $state "steps('$Step').serviceEndpointVirtualNetworksApi" @{
            transformed = @{ loaded = $true; vnets = $vnets; subnets = $subnets; nextLink = $null }
        }
        return $state
    }
}

Describe 'Shared Services ownership subnet Portal behavior' {
    BeforeAll {
        $sharedForm = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\sharedServices\uiFormDefinition.json') -Raw | ConvertFrom-Json -AsHashtable
        $sharedNetworkStep = $sharedForm.view.properties.steps | Where-Object name -eq 'privateNetworking'
        $sharedNetwork = $sharedNetworkStep.elements | Where-Object name -eq 'privateEndpointSubnets'
        $sharedVnetApi = $sharedNetwork.elements | Where-Object name -eq 'virtualNetworksApi'
        $sharedSubnetApi = $sharedNetwork.elements | Where-Object name -eq 'subnetsApi'
        $sharedVnet = $sharedNetwork.elements | Where-Object name -eq 'virtualNetwork'
        $sharedSubnet = $sharedNetwork.elements | Where-Object name -eq 'subnet'
        $sharedPrefix = "steps('privateNetworking').privateEndpointSubnets"
    }

    BeforeEach { $fixture = New-FormFixture 'operations' }

    It 'uses one shared subnet without coupling policies or endpoint flags for combination <Mask>' -TestCases $sharedEndpointCases {
        param($Mask, $Secrets, $Encryption, $Backup, $Feed, $Global)
        Set-CuiValue $fixture "steps('operations').resources.deploySecretsKeyVault" $Secrets
        Set-CuiValue $fixture "steps('operations').resources.deployEncryptionKeyVault" $Encryption
        Set-CuiValue $fixture "steps('operations').resources.deployFSLogixBackupVault" $Backup
        Set-CuiValue $fixture "steps('operations').backupNetworking.backupPrivateEndpoint" $true
        Set-CuiValue $fixture "steps('operations').backupNetworking.backupPublicNetworkAccess" 'Disabled'
        Set-CuiValue $fixture "steps('avdControlPlane').sharedWorkspace.manageWorkspace" $true
        Set-CuiValue $fixture "steps('avdControlPlane').workspaceFeedEndpoint.manageFeedEndpoint" $Feed
        Set-CuiValue $fixture "steps('avdControlPlane').globalFeed.manageGlobalWorkspace" $Global
        Set-CuiValue $fixture "$sharedPrefix.subnet.id" '/shared/subnet'
        $required = $Mask -ne 0
        foreach ($mode in @('Disabled', 'EnabledWithRestrictions', 'Enabled')) {
            Set-CuiValue $fixture "steps('operations').keyVaultPublicNetworking.keyVaultPublicNetworkAccess" $mode
            $policy = Invoke-CuiExpression $sharedForm.view.outputs.parameters.paasNetworking $fixture
            (Invoke-CuiExpression $sharedNetwork.visible $fixture) | Should -Be $required
            (Invoke-CuiExpression $sharedForm.view.outputs.parameters.privateEndpointSubnetResourceIds $fixture).sharedResources |
                Should -Be $(if ($required) { '/shared/subnet' } else { '' })
            (Invoke-CuiExpression $sharedForm.view.outputs.parameters.deployWorkspaceFeedPrivateEndpoint $fixture) | Should -Be $Feed
            if ($Backup) { $policy.backup.privateEndpoint | Should -BeTrue }
            else { $policy.backup.Count | Should -Be 0 }
            (Invoke-CuiExpression $sharedForm.view.outputs.parameters.manageGlobalAvdWorkspace $fixture) | Should -Be $Global
            if ($Secrets -or $Encryption) {
                $policy.keyVault.privateEndpoint | Should -BeTrue
                $policy.keyVault.publicNetworkAccess | Should -Be $mode
            } else { $policy.keyVault.Count | Should -Be 0 }
        }
        foreach ($selected in @($false, $true)) {
            Set-CuiValue $fixture "$sharedPrefix.networkSubscription" $(if ($selected) { @{ id = '/subscriptions/test' } } else { $null })
            Set-CuiValue $fixture "$sharedPrefix.virtualNetwork" $(if ($selected) { @{ id = '/subscriptions/test/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared' } } else { $null })
            (Invoke-CuiExpression $sharedVnetApi.condition $fixture) | Should -Be ($required -and $selected)
            (Invoke-CuiExpression $sharedSubnetApi.condition $fixture) | Should -Be ($required -and $selected)
        }
    }

    It 'ignores stale endpoint selections when their resources are not managed' {
        Set-CuiValue $fixture "steps('operations').resources.deploySecretsKeyVault" $false
        Set-CuiValue $fixture "steps('operations').resources.deployEncryptionKeyVault" $false
        Set-CuiValue $fixture "steps('operations').resources.deployFSLogixBackupVault" $false
        Set-CuiValue $fixture "steps('operations').backupNetworking.backupPrivateEndpoint" $true
        Set-CuiValue $fixture "steps('avdControlPlane').sharedWorkspace.manageWorkspace" $false
        Set-CuiValue $fixture "steps('avdControlPlane').workspaceFeedEndpoint.manageFeedEndpoint" $true
        Set-CuiValue $fixture "steps('avdControlPlane').globalFeed.manageGlobalWorkspace" $false
        Set-CuiValue $fixture "$sharedPrefix.subnet.id" '/shared/subnet'
        (Invoke-CuiExpression $sharedNetwork.visible $fixture) | Should -BeFalse
        (Invoke-CuiExpression $sharedForm.view.outputs.parameters.privateEndpointSubnetResourceIds $fixture).sharedResources | Should -Be ''
        (Invoke-CuiExpression $sharedForm.view.outputs.parameters.deployWorkspaceFeedPrivateEndpoint $fixture) | Should -BeFalse
    }

    It 'does not require a subnet for created resources until an endpoint is enabled' {
        Set-CuiValue $fixture "steps('operations').keyVaultPrivateNetworking.keyVaultPrivateEndpoint" $false
        Set-CuiValue $fixture "steps('operations').resources.deployFSLogixBackupVault" $true
        Set-CuiValue $fixture "steps('operations').backupNetworking.backupPrivateEndpoint" $false
        Set-CuiValue $fixture "steps('avdControlPlane').sharedWorkspace.manageWorkspace" $true
        Set-CuiValue $fixture "steps('avdControlPlane').workspaceFeedEndpoint.manageFeedEndpoint" $false
        Set-CuiValue $fixture "steps('avdControlPlane').globalFeed.manageGlobalWorkspace" $false
        Set-CuiValue $fixture "$sharedPrefix.subnet.id" '/shared/subnet'
        foreach ($endpoint in @(
            @{ Reference = "steps('operations').keyVaultPrivateNetworking.keyVaultPrivateEndpoint"; Enabled = $true; Disabled = $false }
            @{ Reference = "steps('operations').backupNetworking.backupPrivateEndpoint"; Enabled = $true; Disabled = $false }
            @{ Reference = "steps('avdControlPlane').workspaceFeedEndpoint.manageFeedEndpoint"; Enabled = $true; Disabled = $false }
            @{ Reference = "steps('avdControlPlane').globalFeed.manageGlobalWorkspace"; Enabled = $true; Disabled = $false }
        )) {
            (Invoke-CuiExpression $sharedNetwork.visible $fixture) | Should -BeFalse
            (Invoke-CuiExpression $sharedForm.view.outputs.parameters.privateEndpointSubnetResourceIds $fixture).sharedResources | Should -Be ''
            Set-CuiValue $fixture $endpoint.Reference $endpoint.Enabled
            (Invoke-CuiExpression $sharedNetwork.visible $fixture) | Should -BeTrue
            (Invoke-CuiExpression $sharedForm.view.outputs.parameters.privateEndpointSubnetResourceIds $fixture).sharedResources | Should -Be '/shared/subnet'
            Set-CuiValue $fixture $endpoint.Reference $endpoint.Disabled
        }
    }

    It 'uses one nondelegated subnet selector and waits for network inventories' {
        $selectors = @($sharedForm.view.properties.steps.elements.elements | Where-Object {
            $_.name -in @('privateEndpointSubnet', 'feedSubnet', 'globalSubnet', 'subnet')
        })
        $selectors.Count | Should -Be 1
        $selectors[0].name | Should -Be 'subnet'
        $sharedVnet.constraints.required | Should -BeTrue
        $sharedSubnet.constraints.required | Should -BeTrue
        Set-CuiValue $fixture "$sharedPrefix.virtualNetworksApi" @{}
        Set-CuiValue $fixture "$sharedPrefix.subnetsApi" @{}
        foreach ($selector in @($sharedVnet, $sharedSubnet)) {
            $options = Invoke-CuiExpression $selector.constraints.allowedValues $fixture -PortalLambdaScope
            $options.Count | Should -Be 1
            $options[0].value | Should -Be ''
        }
        Set-CuiValue $fixture "$sharedPrefix.virtualNetworksApi" @{
            value = @(@{ name = 'shared'; location = 'westus'; id = '/subscriptions/network/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared' })
        }
        $vnets = Invoke-CuiExpression $sharedVnet.constraints.allowedValues $fixture -PortalLambdaScope
        $vnets.Count | Should -Be 1
        $vnets[0].label | Should -Be 'shared'
        Set-CuiValue $fixture "$sharedPrefix.subnetsApi" @{
            value = @(
                @{ name = 'private'; id = '/shared/private'; properties = @{ delegations = @() } }
                @{ name = 'delegated'; id = '/shared/delegated'; properties = @{ delegations = @(@{ name = 'delegation' }) } }
            )
        }
        $subnets = Invoke-CuiExpression $sharedSubnet.constraints.allowedValues $fixture -PortalLambdaScope
        $subnets.Count | Should -Be 1
        $subnets[0].value.id | Should -Be '/shared/private'
    }
}

Describe 'Private DNS zone dropdown presentation and defaults' {
    It 'offers searchable matching zones and label-based defaults in <Folder>: <Reference>' -TestCases $dnsPresentationCases {
        param($Folder, $Reference, $Control, $Namespace, $ApiReference)
        $Control.filter | Should -BeTrue
        $Namespace | Should -Not -BeNullOrEmpty
        $ApiReference | Should -Not -BeNullOrEmpty
        $fixture = New-FormFixture 'zeroTrust'
        foreach ($response in @(@{}, @{ value = @() }, @{ value = @(@{ name = 'unrelated.example'; id = '/dns/unrelated' }) })) {
            Set-CuiValue $fixture $ApiReference $response
            $options = Invoke-CuiExpression $Control.constraints.allowedValues $fixture -PortalLambdaScope
            $options.Count | Should -Be 1
            $options[0].value | Should -Be ''
            (Invoke-CuiExpression $Control.defaultValue $fixture -PortalLambdaScope) | Should -Be $options[0].label
        }
        $zoneName = if ($Namespace -eq '.backup.') { 'privatelink.eastus.backup.example' } else { "${Namespace}example" }
        $firstId = "/subscriptions/test/resourceGroups/dns-one/providers/Microsoft.Network/privateDnsZones/$zoneName"
        $secondName = if ($Namespace -eq '.backup.') { 'privatelink.westus.backup.example' } else { "${Namespace}other.example" }
        $secondId = "/subscriptions/test/resourceGroups/dns-two/providers/Microsoft.Network/privateDnsZones/$secondName"
        Set-CuiValue $fixture $ApiReference @{
            value = @(
                @{ name = 'unrelated.example'; id = '/dns/unrelated' }
                @{ name = $zoneName; id = $firstId }
                @{ name = $secondName; id = $secondId }
            )
        }
        $options = Invoke-CuiExpression $Control.constraints.allowedValues $fixture -PortalLambdaScope
        $options.Count | Should -Be 2
        $options[0].label | Should -Be $zoneName
        $default = Invoke-CuiExpression $Control.defaultValue $fixture -PortalLambdaScope
        $default | Should -Be $zoneName
        $default | Should -Not -Be $firstId
        $firstValue = if ($options[0].value -is [string]) { $options[0].value } else { $options[0].value.id }
        $secondValue = if ($options[1].value -is [string]) { $options[1].value } else { $options[1].value.id }
        $firstValue | Should -Be $firstId
        $secondValue | Should -Be $secondId
    }
}

Describe 'Service endpoint Portal contract: <Folder>' -ForEach $formCases {
    BeforeAll {
        $formPath = Join-Path $repoRoot "deployments\$Folder\uiFormDefinition.json"
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json -AsHashtable
        $submittedParameters = $form.view.outputs.parameters
        if ($Folder -in @('hostpools', 'automatedHostPools', 'imageManagement', 'sharedServices', 'add-ons\sessionHostReplacer')) {
            # Project fields from the actual grouped expression for shared family-level regressions.
            $form.view.outputs.parameters = Get-GroupedNetworkingBindings $submittedParameters
        }
        $formStep = $form.view.properties.steps | Where-Object name -eq $Step
        $api = $formStep.elements | Where-Object name -eq serviceEndpointVirtualNetworksApi
        $sections = @{}
        foreach ($section in $formStep.elements) { $sections[$section.name] = $section }
        $entryNames = @{
            hostpools = 'hostpool.bicep'
            automatedHostPools = 'automatedHostPool.bicep'
            sharedServices = 'sharedServices.bicep'
            hostpoolPoc = 'hostpoolPoc.bicep'
            imageManagement = 'imageManagement.bicep'
        }
        $entryName = if ($entryNames.ContainsKey($Folder)) { $entryNames[$Folder] } else { 'main.bicep' }
        $entrySource = Get-Content -LiteralPath (Join-Path $repoRoot "deployments\$Folder\$entryName") -Raw
        $entryParameters = @([regex]::Matches($entrySource, '(?m)^param\s+([A-Za-z_][A-Za-z0-9_]*)') |
            ForEach-Object { $_.Groups[1].Value })
    }

    BeforeEach { $fixture = New-FormFixture $Step }

    It 'maps only applicable service-family contracts and has no shared-policy outputs' {
        $submittedParameters.ContainsKey('paasPublicNetworkAccess') | Should -BeFalse
        $submittedParameters.ContainsKey('permittedIPs') | Should -BeFalse
        foreach ($service in @('storage', 'keyVault', 'functionApp')) {
            foreach ($suffix in @('PublicNetworkAccess', 'PermittedIPs', 'ServiceEndpointSubnetResourceIds')) {
                $submittedParameters.ContainsKey("$service$suffix") | Should -Be ($Folder -notin @('hostpools', 'automatedHostPools', 'imageManagement', 'sharedServices', 'add-ons\sessionHostReplacer') -and $service -in $Services)
            }
        }
        if ($Folder -in @('hostpools', 'automatedHostPools', 'imageManagement', 'sharedServices', 'add-ons\sessionHostReplacer')) {
            foreach ($name in @('paasNetworking', 'privateEndpointSubnetResourceIds', 'privateDnsZoneResourceIds')) {
                $submittedParameters.ContainsKey($name) | Should -BeTrue
            }
        }
        foreach ($section in ($form.view.properties.steps.elements | Where-Object type -eq 'Microsoft.Common.Section')) {
            $section.elements.type | Should -Not -Contain 'Microsoft.Common.Section'
        }
    }

    It 'references existing controls in the new sections and does not retain removed topology bindings' {
        $raw = Get-Content -LiteralPath $formPath -Raw
        $raw | Should -Not -Match "steps\('zeroTrust'\)\.(privateNetworking|publicNetworking)\.|networkSettings\.networkAccess\b"
        $bindings = @($api | ConvertTo-Json -Depth 40)
        if ($Folder -eq 'sharedServices') {
            $bindings += ($form.view.properties.steps | Where-Object name -eq 'privateNetworking') | ConvertTo-Json -Depth 40
            $bindings += $form.view.outputs.parameters.sharedResourcesPrivateEndpointSubnetResourceId
        }
        foreach ($service in $Services) {
            foreach ($name in @("${service}PrivateNetworking", "${service}PublicNetworking", "${service}ServiceEndpointAccess")) {
                if ($sections.ContainsKey($name)) { $bindings += $sections[$name] | ConvertTo-Json -Depth 40 }
            }
            foreach ($parameter in $form.view.outputs.parameters.Keys | Where-Object { $_.StartsWith($service) }) {
                $bindings += $form.view.outputs.parameters[$parameter]
            }
        }
        foreach ($reference in [regex]::Matches(($bindings -join "`n"), "steps\('([^']+)'\)((?:\.[A-Za-z_][A-Za-z0-9_]*)+)")) {
            $owner = @($form.view.properties.steps | Where-Object name -eq $reference.Groups[1].Value)
            foreach ($part in $reference.Groups[2].Value.TrimStart('.').Split('.')) {
                $owner.Count | Should -Be 1 -Because "the step in $($reference.Value) must exist"
                $control = @($owner[0].elements | Where-Object name -eq $part)
                $control.Count | Should -Be 1 -Because "the control in $($reference.Value) must exist"
                if ($control[0].type -ne 'Microsoft.Common.Section') { break }
                $owner = $control
            }
        }
    }

    It 'maps every output to an entry parameter and removes redundant coupled-topology parameters' {
        foreach ($name in $submittedParameters.Keys) {
            $entryParameters | Should -Contain $name -Because "the form output must match the current $Folder entry contract"
        }
        foreach ($removed in @('storageNetworkAccess', 'endpointType', 'fslogixPrivateEndpoint', 'fslogixPrivateEndpointSubnetResourceId')) {
            $form.view.outputs.parameters.ContainsKey($removed) | Should -BeFalse
        }
        if ($Folder -in @('add-ons\imageValidation', 'add-ons\fslogixProfileManagement')) {
            $form.view.outputs.parameters.ContainsKey('subnetResourceId') | Should -BeFalse
        }
        if ($Folder -eq 'add-ons\imageValidation') {
            $form.view.outputs.parameters.virtualMachineSubnetResourceId | Should -Be "[steps('virtualMachine').network.subnet]"
        }
    }

    It 'selects ownership subnets for service-only and AVD-only deployments' {
        if ($Folder -notin @('hostpools', 'automatedHostPools')) { return }
        foreach ($case in @(
            @{ Storage = $false; Vault = $false; Avd = $false; Route = 'None'; Shared = $false; Host = $false }
            @{ Storage = $true; Vault = $false; Avd = $false; Route = 'None'; Shared = $false; Host = $true }
            @{ Storage = $false; Vault = $true; Avd = $false; Route = 'None'; Shared = $true; Host = $false }
            @{ Storage = $false; Vault = $false; Avd = $true; Route = 'HostPool'; Shared = $false; Host = $true }
            @{ Storage = $false; Vault = $false; Avd = $true; Route = 'FeedAndHostPool'; Shared = $true; Host = $true }
            @{ Storage = $false; Vault = $false; Avd = $true; Route = 'All'; Shared = $true; Host = $true }
        )) {
            $fixture = New-FormFixture $Step
            Set-CuiValue $fixture "steps('zeroTrust').storagePrivateNetworking.storagePrivateEndpoint" $case.Storage
            Set-CuiValue $fixture "steps('zeroTrust').keyVaultPrivateNetworking.keyVaultPrivateEndpoint" $case.Vault
            Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.enablePrivateLink" $case.Avd
            Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.avdPrivateLinkConfig" $case.Route
            Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.privateRoutes" $case.Route
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.deployBackupAndDiskPrivateEndpoints" $false
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.deployBackupPrivateEndpoints" $false
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpointSubnets.sharedSubnet.id" '/shared/subnet'
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpointSubnets.hostPoolSubnet.id" '/host/subnet'
            (Invoke-CuiExpression $form.view.outputs.parameters.sharedResourcesPrivateEndpointSubnetResourceId $fixture) |
                Should -Be $(if ($case.Shared) { '/shared/subnet' } else { '' })
            (Invoke-CuiExpression $form.view.outputs.parameters.hostPoolResourcesPrivateEndpointSubnetResourceId $fixture) |
                Should -Be $(if ($case.Host) { '/host/subnet' } else { '' })
        }
    }

    It 'uses ownership subnets for Backup-only deployments without changing adopted vaults' {
        if ($Folder -notin @('hostpools', 'automatedHostPools')) { return }
        $cases = @(
            @{ Personal = $false; Existing = $false; Shared = $true; Host = $false }
            @{ Personal = $false; Existing = $true; Shared = $false; Host = $false }
        )
        if ($Folder -eq 'hostpools') {
            $cases += @{ Personal = $true; Existing = $true; Shared = $false; Host = $true }
        }
        foreach ($case in $cases) {
            $fixture = New-FormFixture $Step
            Set-CuiValue $fixture "steps('zeroTrust').storagePrivateNetworking.storagePrivateEndpoint" $false
            Set-CuiValue $fixture "steps('zeroTrust').keyVaultPrivateNetworking.keyVaultPrivateEndpoint" $false
            Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.enablePrivateLink" $false
            Set-CuiValue $fixture "steps('controlPlane').hostPool.type" $(if ($case.Personal) { 'Personal' } else { 'Pooled' })
            Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.recoveryServices" $true
            Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.useExistingRecoveryServicesVault" $case.Existing
            Set-CuiValue $fixture "steps('profiles').storage.registerBackup" $true
            Set-CuiValue $fixture "steps('profiles').storage.useExistingRecoveryServicesVault" $case.Existing
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.deployBackupAndDiskPrivateEndpoints" $true
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.backupPrivateEndpoint" $true
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.diskPrivateEndpoint" $true
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.deployBackupPrivateEndpoints" $true
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpointSubnets.sharedSubnet.id" '/shared/subnet'
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpointSubnets.hostPoolSubnet.id" '/host/subnet'
            (Invoke-CuiExpression $form.view.outputs.parameters.sharedResourcesPrivateEndpointSubnetResourceId $fixture) |
                Should -Be $(if ($case.Shared) { '/shared/subnet' } else { '' })
            (Invoke-CuiExpression $form.view.outputs.parameters.hostPoolResourcesPrivateEndpointSubnetResourceId $fixture) |
                Should -Be $(if ($case.Host) { '/host/subnet' } else { '' })
        }
    }

    It 'keeps family private endpoints independent from public modes and other endpoint families' {
        foreach ($service in $Services) {
            $publicMode = $sections["${service}PublicNetworking"].elements | Where-Object name -eq "${service}PublicNetworkAccess"
            $publicMode.defaultValue | Should -Be 'Disabled'
            ($publicMode.constraints.allowedValues.value -join ',') | Should -Be 'Disabled,EnabledWithRestrictions,Enabled'
            if ($Folder -eq 'hostpoolPoc') {
                $form.view.outputs.parameters.ContainsKey("${service}PrivateEndpoint") | Should -BeFalse
                $form.view.outputs.parameters.ContainsKey("${service}PrivateEndpointSubnetResourceId") | Should -BeFalse
                continue
            }
            $privateToggle = $sections["${service}PrivateNetworking"].elements | Where-Object name -eq "${service}PrivateEndpoint"
            $privateToggle.constraints.allowedValues.value | Should -Contain $true
            $privateToggle.constraints.allowedValues.value | Should -Contain $false
            $privatePrefix = "steps('$Step').${service}PrivateNetworking"
            Set-CuiValue $fixture "$privatePrefix.privateEndpointSubnet.id" "/private/$service/subnet"
            Set-CuiValue $fixture "steps('infrastructure').privateEndpointSubnets.privateEndpointSubnet.id" "/private/$service/subnet"
            foreach ($enabled in @($true, $false)) {
                Set-CuiValue $fixture "$privatePrefix.${service}PrivateEndpoint" $enabled
                foreach ($mode in @('Disabled', 'EnabledWithRestrictions', 'Enabled')) {
                    Set-CuiValue $fixture "steps('$Step').${service}PublicNetworking.${service}PublicNetworkAccess" $mode
                    (Invoke-CuiExpression $form.view.outputs.parameters["${service}PrivateEndpoint"] $fixture) | Should -Be $enabled
                    if ($Folder -in @('hostpools', 'automatedHostPools', 'sharedServices')) {
                        $form.view.outputs.parameters.ContainsKey("${service}PrivateEndpointSubnetResourceId") | Should -BeFalse
                    } else {
                        (Invoke-CuiExpression $form.view.outputs.parameters["${service}PrivateEndpointSubnetResourceId"] $fixture) |
                            Should -Be $(if ($enabled) { "/private/$service/subnet" } else { '' })
                    }
                    (Invoke-CuiExpression $form.view.outputs.parameters["${service}PublicNetworkAccess"] $fixture) | Should -Be $mode
                }
            }
        }
    }

    It 'waits for family DNS inventory and populates choices after cold API completion' -Tag 'FamilyDnsCold' {
        foreach ($service in $Services) {
            if ($Folder -eq 'hostpoolPoc') { continue }
            $privateSection = $sections["${service}PrivateNetworking"]
            $dnsApi = $privateSection.elements | Where-Object name -eq privateDnsZonesApi
            $prefix = "steps('$Step').${service}PrivateNetworking"
            Set-CuiValue $fixture "$prefix.${service}PrivateEndpoint" $true
            Set-CuiValue $fixture "$prefix.enablePrivateDNSIntegration" $true
            $dnsControls = @($privateSection.elements | Where-Object {
                $_.type -eq 'Microsoft.Common.DropDown' -and
                $_.constraints.allowedValues -match ([regex]::Escape("$prefix.$($dnsApi.name).value"))
            })
            $dnsControls.Count | Should -BeGreaterThan 0
            Set-CuiValue $fixture "$prefix.$($dnsApi.name)" @{}
            foreach ($control in $dnsControls) {
                $coldOptions = Invoke-CuiExpression $control.constraints.allowedValues $fixture -PortalLambdaScope
                $coldOptions.Count | Should -Be 1
                $coldOptions[0].value | Should -Be ''
            }
            $zones = @('file', 'blob', 'table', 'vaultcore', 'azurewebsites') | ForEach-Object {
                @{
                    name = "privatelink.$_.example"
                    id = "/subscriptions/test/resourceGroups/dns/providers/Microsoft.Network/privateDnsZones/privatelink.$_.example"
                }
            }
            Set-CuiValue $fixture "$prefix.$($dnsApi.name)" @{ value = @($zones) }
            foreach ($control in $dnsControls) {
                $readyOptions = Invoke-CuiExpression $control.constraints.allowedValues $fixture -PortalLambdaScope
                $readyOptions.Count | Should -Be 1
                $readyOptions[0].value | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'uses a shared read-only cloud-relative inventory and explicit transformed completion' {
        $api.request.method | Should -Be 'GET'
        $api.request.path | Should -Not -Match 'https?://|ResourceGraph'
        (Invoke-CuiExpression $api.request.path $fixture) | Should -Be '/subscriptions/test/providers/Microsoft.Network/virtualNetworks?api-version=2022-11-01'
        $api.request.transforms.loaded | Should -Be '`true`'
        $api.request.transforms.vnets | Should -Be 'value'
        $api.request.transforms.subnets | Should -Be 'value[].properties.subnets[]'
        $api.request.transforms.nextLink | Should -Be 'nextLink'
        (Invoke-CuiExpression $api.condition $fixture) | Should -BeTrue
        foreach ($service in $Services) {
            $section = $sections["${service}ServiceEndpointAccess"]
            ($section | ConvertTo-Json -Depth 40) | Should -Not -Match 'serviceEndpointVirtualNetworksApi\.(value|nextLink)\b|serviceEndpointVirtualNetworksApi\.transformed\b(?!\.)'
            $control = $section.elements | Where-Object name -eq "${service}ServiceEndpointSubnets"
            $fixture[$Step].serviceEndpointVirtualNetworksApi = @{}
            (Invoke-CuiExpression $control.visible $fixture) | Should -BeTrue
            (Invoke-CuiExpression $control.constraints.allowedValues $fixture -PortalLambdaScope)[0].label | Should -Be 'Loading subnet inventory'
            $fixture[$Step].serviceEndpointVirtualNetworksApi = (New-FormFixture $Step)[$Step].serviceEndpointVirtualNetworksApi
            $fixture[$Step].serviceEndpointVirtualNetworksApi.transformed.subnets = @()
            (Invoke-CuiExpression $control.constraints.allowedValues $fixture -PortalLambdaScope)[0].label | Should -Be 'No eligible subnets found'
            $fixture[$Step].serviceEndpointVirtualNetworksApi = (New-FormFixture $Step)[$Step].serviceEndpointVirtualNetworksApi
        }
    }

    It 'offers VNet-first multiline options with distinct IDs and endpoint eligibility without nested lambda capture' {
        foreach ($service in $Services) {
            $control = $sections["${service}ServiceEndpointAccess"].elements | Where-Object name -eq "${service}ServiceEndpointSubnets"
            $control.multiselect | Should -BeTrue
            $control.multiLine | Should -BeTrue
            $control.filter | Should -BeTrue
            $control.selectAll | Should -BeFalse
            $control.defaultValue | Should -Be "[parse('[]')]"
            $options = Invoke-CuiExpression $control.constraints.allowedValues $fixture -PortalLambdaScope
            foreach ($option in $options) {
                $option.label | Should -Be "$($option.value.Split('/')[8]) | $($option.value.Split('/')[10])"
                $option.description | Should -Be "Resource Group: $($option.value.Split('/')[4])"
            }
            $options.Count | Should -Be $(if ($service -eq 'storage') { 3 } else { 1 })
            if ($service -eq 'storage') {
                ($options.value -join ',') | Should -Match 'east-one/.+east-two/.+west-one/'
                ($options.value -join ',') | Should -Not -Match 'wrong-region|unconfigured'
            } else {
                $control.toolTip | Should -Match $(if ($service -eq 'keyVault') { 'Microsoft.KeyVault' } else { 'Microsoft.Web' })
            }
        }
    }

    It 'retains IP and subnet allowlists while public access changes independently by service' {
        foreach ($service in $Services) {
            $section = $sections["${service}ServiceEndpointAccess"]
            $selector = $section.elements | Where-Object name -eq "${service}ServiceEndpointSubnets"
            $grid = $section.elements | Where-Object name -eq "${service}PermittedIPs"
            $prefix = "steps('$Step').${service}ServiceEndpointAccess"
            Set-CuiValue $fixture "$prefix.${service}ServiceEndpointSubnets" @('/selected/subnet', '')
            $row = @{ $grid.constraints.columns[0].id = '203.0.113.10' }
            Set-CuiValue $fixture "$prefix.${service}PermittedIPs" @($row)
            foreach ($mode in @('Disabled', 'EnabledWithRestrictions', 'Enabled')) {
                Set-CuiValue $fixture "steps('$Step').${service}PublicNetworking.${service}PublicNetworkAccess" $mode
                (Invoke-CuiExpression $selector.visible $fixture) | Should -Be ($mode -eq 'EnabledWithRestrictions')
                (Invoke-CuiExpression $form.view.outputs.parameters["${service}PublicNetworkAccess"] $fixture) | Should -Be $mode
                $active = $Folder -notin @('hostpools', 'automatedHostPools', 'imageManagement', 'sharedServices', 'add-ons\sessionHostReplacer') -or $mode -eq 'EnabledWithRestrictions'
                (Invoke-CuiExpression $form.view.outputs.parameters["${service}PermittedIPs"] $fixture) -join ',' | Should -Be $(if ($active) { '203.0.113.10' } else { '' })
                (Invoke-CuiExpression $form.view.outputs.parameters["${service}ServiceEndpointSubnetResourceIds"] $fixture) -join ',' | Should -Be $(if ($active) { '/selected/subnet' } else { '' })
                foreach ($other in ($Services | Where-Object { $_ -ne $service })) {
                    (Invoke-CuiExpression $form.view.outputs.parameters["${other}PublicNetworkAccess"] $fixture) | Should -Be 'EnabledWithRestrictions'
                }
            }
            Set-CuiValue $fixture "steps('$Step').${service}PublicNetworking.${service}PublicNetworkAccess" 'EnabledWithRestrictions'
        }
    }

    It 'keeps private endpoint deployment independent for all six public-private combinations' {
        if ($Folder -eq 'hostpoolPoc') { return }
        Set-CuiValue $fixture "steps('infrastructure').privateEndpointSubnets.privateEndpointSubnet.id" '/private/subnet'
        foreach ($service in $Services) {
            $private = "steps('$Step').${service}PrivateNetworking"
            $public = "steps('$Step').${service}PublicNetworking"
            Set-CuiValue $fixture "$private.privateEndpointSubnet.id" '/private/subnet'
            foreach ($enabled in @($true, $false)) {
                Set-CuiValue $fixture "$private.${service}PrivateEndpoint" $enabled
                foreach ($mode in @('Disabled', 'EnabledWithRestrictions', 'Enabled')) {
                    Set-CuiValue $fixture "$public.${service}PublicNetworkAccess" $mode
                    (Invoke-CuiExpression $form.view.outputs.parameters["${service}PrivateEndpoint"] $fixture) | Should -Be $enabled
                    if ($Folder -notin @('hostpools', 'automatedHostPools', 'sharedServices')) {
                        (Invoke-CuiExpression $form.view.outputs.parameters["${service}PrivateEndpointSubnetResourceId"] $fixture) | Should -Be $(if ($enabled) { '/private/subnet' } else { '' })
                    }
                    (Invoke-CuiExpression $form.view.outputs.parameters["${service}PublicNetworkAccess"] $fixture) | Should -Be $mode
                }
            }
        }
    }

    It 'routes private DNS selections through the owning service rather than shared backup flags' {
        if ($Folder -eq 'hostpoolPoc') { return }
        if ($Folder -in @('hostpools', 'automatedHostPools')) {
            $backupFlag = if ($Folder -eq 'automatedHostPools') { 'deployBackupPrivateEndpoints' } else { 'deployBackupAndDiskPrivateEndpoints' }
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.$backupFlag" $false
        }
        foreach ($service in $Services) {
            $private = "steps('$Step').${service}PrivateNetworking"
            Set-CuiValue $fixture "$private.${service}PrivateEndpoint" $true
            Set-CuiValue $fixture "$private.enablePrivateDNSIntegration" $true
            $zones = @($sections["${service}PrivateNetworking"].elements | Where-Object { $_.name -match 'PrivateDnsZone$' })
            foreach ($zone in $zones) {
                $parameter = "$($zone.name)ResourceId"
                $form.view.outputs.parameters[$parameter] | Should -Match ([regex]::Escape("$private.$($zone.name)"))
                Set-CuiValue $fixture "$private.$($zone.name)" '/private/dns-zone'
                (Invoke-CuiExpression $form.view.outputs.parameters[$parameter] $fixture) | Should -Be '/private/dns-zone'
                Set-CuiValue $fixture "$private.${service}PrivateEndpoint" $false
                (Invoke-CuiExpression $form.view.outputs.parameters[$parameter] $fixture) | Should -Be ''
                Set-CuiValue $fixture "$private.${service}PrivateEndpoint" $true
                Set-CuiValue $fixture "$private.enablePrivateDNSIntegration" $false
                (Invoke-CuiExpression $form.view.outputs.parameters[$parameter] $fixture) | Should -Be ''
                Set-CuiValue $fixture "$private.enablePrivateDNSIntegration" $true
            }
        }
        if ($Folder -eq 'hostpools') {
            $sections.storagePrivateNetworking.elements.name | Should -Contain 'filePrivateDnsZone'
            $sections.privateEndpoints.elements.name | Should -Not -Contain 'filePrivateDnsZone'
        }
    }

    It 'hides and suppresses ACL controls for services not created by the deployment' {
        switch ($Folder) {
            hostpools {
                Set-CuiValue $fixture "steps('userProfiles').deployStorage" $false
                Set-CuiValue $fixture "steps('hosts').identity.source" 'keyVault'
                Set-CuiValue $fixture "steps('zeroTrust').keyManagement.useExistingEncryptionKv" $true
            }
            automatedHostPools {
                Set-CuiValue $fixture "steps('profiles').deployStorage" $false
                Set-CuiValue $fixture "steps('hosts').credentials.source" 'existing'
                Set-CuiValue $fixture "steps('zeroTrust').keyManagement.useExistingEncryptionKv" $true
            }
            sharedServices {
                Set-CuiValue $fixture "steps('operations').resources.deploySecretsKeyVault" $false
                Set-CuiValue $fixture "steps('operations').resources.deployEncryptionKeyVault" $false
            }
            'add-ons\fslogixStorage' { Set-CuiValue $fixture "steps('storage').storageService" 'AzureNetAppFiles' }
            hostpoolPoc { Set-CuiValue $fixture "steps('options').deployFSLogixStorage" $false }
            imageManagement {
                Set-CuiValue $fixture "steps('storageAccounts').deployArtifactsStorageAccount" $false
                Set-CuiValue $fixture "steps('storageAccounts').deployBuildLogsStorageAccount" $false
            }
            default { return }
        }
        foreach ($service in $Services) {
            Set-CuiValue $fixture "steps('$Step').${service}ServiceEndpointAccess.${service}ServiceEndpointSubnets" @('/selected/subnet')
            (Invoke-CuiExpression $sections["${service}ServiceEndpointAccess"].visible $fixture) | Should -BeFalse
            (Invoke-CuiExpression $form.view.outputs.parameters["${service}ServiceEndpointSubnetResourceIds"] $fixture).Count | Should -Be 0
            (Invoke-CuiExpression $form.view.outputs.parameters["${service}PermittedIPs"] $fixture).Count | Should -Be 0
            (Invoke-CuiExpression $form.view.outputs.parameters["${service}PublicNetworkAccess"] $fixture) | Should -Be 'Disabled'
        }
    }

    It 'does not infer vault creation from stale hidden profile-encryption selections' {
        if ($Folder -notin @('hostpools', 'automatedHostPools')) { return }
        Set-CuiValue $fixture "steps('zeroTrust').keyManagement.keyManagementStorage" 'CustomerManaged'
        Set-CuiValue $fixture "steps('zeroTrust').keyManagement.keyManagementRecoveryServicesVault" 'CustomerManaged'
        if ($Folder -eq 'hostpools') {
            Set-CuiValue $fixture "steps('userProfiles').deployStorage" $false
            Set-CuiValue $fixture "steps('hosts').identity.source" 'keyVault'
        } else {
            Set-CuiValue $fixture "steps('profiles').deployStorage" $false
            Set-CuiValue $fixture "steps('hosts').credentials.source" 'existing'
        }
        (Invoke-CuiExpression $sections.keyVaultPublicNetworking.visible $fixture) | Should -BeFalse
        (Invoke-CuiExpression $form.view.outputs.parameters.keyVaultServiceEndpointSubnetResourceIds $fixture).Count | Should -Be 0
    }

    It 'keeps Function inbound restrictions independent of outbound integration and runtime Storage' {
        if ('functionApp' -notin $Services) { return }
        $control = $sections.functionAppServiceEndpointAccess.elements | Where-Object name -eq functionAppServiceEndpointSubnets
        $control.toolTip | Should -Match 'inbound.*not outbound'
        $form.view.outputs.parameters.functionAppDelegatedSubnetResourceId | Should -Not -Match 'PublicNetworking|PrivateNetworking|ServiceEndpointAccess'
        $integration = if ($Folder -eq 'add-ons\sessionHostReplacer') {
            "steps('$Step').enableVnetIntegration"
        } else {
            "steps('$Step').networkSettings.enableVnetIntegration"
        }
        $subnet = if ($Folder -eq 'add-ons\sessionHostReplacer') {
            "steps('$Step').functionAppOutboundSubnet"
        } else {
            "steps('$Step').networkSettings.delegatedSubnet"
        }
        Set-CuiValue $fixture $subnet '/outbound/delegated-subnet'
        foreach ($enabled in @($true, $false)) {
            Set-CuiValue $fixture $integration $enabled
            (Invoke-CuiExpression $form.view.outputs.parameters.functionAppDelegatedSubnetResourceId $fixture) |
                Should -Be $(if ($enabled) { '/outbound/delegated-subnet' } else { '' })
        }
    }
}

Describe 'FSLogix Storage subnet inventory regression' {
    BeforeAll {
        $form = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\uiFormDefinition.json') -Raw | ConvertFrom-Json -AsHashtable
        $step = $form.view.properties.steps | Where-Object name -eq zeroTrust
        $section = $step.elements | Where-Object name -eq storageServiceEndpointAccess
        $api = $step.elements | Where-Object name -eq serviceEndpointVirtualNetworksApi
        $control = $section.elements | Where-Object name -eq storageServiceEndpointSubnets
        $status = $section.elements | Where-Object name -eq inventoryStatus
        $warning = $section.elements | Where-Object name -eq inventoryPageWarning
    }

    BeforeEach {
        $fixture = New-FormFixture zeroTrust
        $inventory = $fixture.zeroTrust.serviceEndpointVirtualNetworksApi
        $inventory.Remove('value')
    }

    It 'separates private and public connectivity and groups public allowlists before monitoring' {
        $names = @($step.elements.name)
        [array]::IndexOf($names, 'storagePublicNetworking') | Should -BeGreaterThan ([array]::IndexOf($names, 'storagePrivateNetworking'))
        [array]::IndexOf($names, 'storageServiceEndpointAccess') | Should -BeGreaterThan ([array]::IndexOf($names, 'storagePublicNetworking'))
        [array]::IndexOf($names, 'storageServiceEndpointAccess') | Should -BeLessThan ([array]::IndexOf($names, 'operations'))
        $section.elements.name | Should -Contain 'storagePermittedIPs'
        [array]::IndexOf(@($section.elements.name), 'storagePermittedIPs') | Should -BeLessThan ([array]::IndexOf(@($section.elements.name), 'storageServiceEndpointSubnets'))
        ($step.elements | Where-Object name -eq storagePrivateNetworking).elements.name | Should -Not -Contain 'storagePublicNetworkAccess'
        foreach ($rootSection in ($form.view.properties.steps.elements | Where-Object type -eq 'Microsoft.Common.Section')) {
            $rootSection.elements.type | Should -Not -Contain 'Microsoft.Common.Section'
        }
    }

    It 'keeps public access explicit and independent for all six connectivity combinations' {
        $publicSection = $step.elements | Where-Object name -eq storagePublicNetworking
        $modeControl = $publicSection.elements | Where-Object name -eq storagePublicNetworkAccess
        $warningControl = $publicSection.elements | Where-Object name -eq noPrivateConnectivityWarning
        $modeControl.defaultValue | Should -Be 'Disabled'
        Set-CuiValue $fixture "steps('zeroTrust').storageServiceEndpointAccess.storagePermittedIPs" @(@{ value = '203.0.113.10' })
        Set-CuiValue $fixture "steps('zeroTrust').storageServiceEndpointAccess.storageServiceEndpointSubnets" @('/selected/subnet')
        Set-CuiValue $fixture "steps('zeroTrust').storagePrivateNetworking.privateEndpointSubnet.id" '/private/subnet'
        foreach ($privateEndpoint in @($true, $false)) {
            Set-CuiValue $fixture "steps('zeroTrust').storagePrivateNetworking.storagePrivateEndpoint" $privateEndpoint
            foreach ($mode in @('Disabled', 'EnabledWithRestrictions', 'Enabled')) {
                Set-CuiValue $fixture "steps('zeroTrust').storagePublicNetworking.storagePublicNetworkAccess" $mode
                (Invoke-CuiExpression $form.view.outputs.parameters.storagePublicNetworkAccess $fixture) | Should -Be $mode
                (Invoke-CuiExpression $form.view.outputs.parameters.storagePrivateEndpoint $fixture) | Should -Be $privateEndpoint
                (Invoke-CuiExpression $section.visible $fixture) | Should -Be ($mode -eq 'EnabledWithRestrictions')
                (Invoke-CuiExpression $warningControl.visible $fixture) | Should -Be ($mode -eq 'Disabled' -and -not $privateEndpoint)
                (Invoke-CuiExpression $form.view.outputs.parameters.storagePermittedIPs $fixture) -join ',' | Should -Be '203.0.113.10'
                (Invoke-CuiExpression $form.view.outputs.parameters.storageServiceEndpointSubnetResourceIds $fixture) -join ',' | Should -Be '/selected/subnet'
            }
        }
    }

    It 'supports IP-only, subnet-only, combined and empty restricted allowlists without requiring both rule types' {
        $emptyWarning = $section.elements | Where-Object name -eq emptyAllowlistWarning
        Set-CuiValue $fixture "steps('zeroTrust').storagePrivateNetworking.storagePrivateEndpoint" $false
        foreach ($hasIPs in @($false, $true)) {
            foreach ($hasSubnets in @($false, $true)) {
                $ips = @()
                if ($hasIPs) { $ips = @(@{ value = '203.0.113.10' }) }
                $subnets = @('')
                if ($hasSubnets) { $subnets = @('/selected/subnet') }
                Set-CuiValue $fixture "steps('zeroTrust').storageServiceEndpointAccess.storagePermittedIPs" $ips
                Set-CuiValue $fixture "steps('zeroTrust').storageServiceEndpointAccess.storageServiceEndpointSubnets" $subnets
                (Invoke-CuiExpression $section.visible $fixture) | Should -BeTrue
                (Invoke-CuiExpression $emptyWarning.visible $fixture) | Should -Be (-not $hasIPs -and -not $hasSubnets)
                (Invoke-CuiExpression $form.view.outputs.parameters.storagePermittedIPs $fixture).Count | Should -Be ([int]$hasIPs)
                (Invoke-CuiExpression $form.view.outputs.parameters.storageServiceEndpointSubnetResourceIds $fixture).Count | Should -Be ([int]$hasSubnets)
            }
        }
        Set-CuiValue $fixture "steps('storage').storageService" 'AzureNetAppFiles'
        (Invoke-CuiExpression ($step.elements | Where-Object name -eq storagePrivateNetworking).visible $fixture) | Should -BeFalse
        (Invoke-CuiExpression ($step.elements | Where-Object name -eq storagePublicNetworking).visible $fixture) | Should -BeFalse
        (Invoke-CuiExpression $section.visible $fixture) | Should -BeFalse
        (Invoke-CuiExpression $form.view.outputs.parameters.storagePermittedIPs $fixture).Count | Should -Be 0
        (Invoke-CuiExpression $form.view.outputs.parameters.storageServiceEndpointSubnetResourceIds $fixture).Count | Should -Be 0
        (Invoke-CuiExpression $form.view.outputs.parameters.storagePublicNetworkAccess $fixture) | Should -Be 'Disabled'
    }

    It 'uses only explicit transformed inventory, including pagination' {
        $api.request.transforms.vnets | Should -Be 'value'
        $api.request.transforms.subnets | Should -Be 'value[].properties.subnets[]'
        $api.request.transforms.nextLink | Should -Be 'nextLink'
        $api.request.transforms.loaded | Should -Be '`true`'
        ($section | ConvertTo-Json -Depth 40) | Should -Not -Match 'serviceEndpointVirtualNetworksApi\.(value|nextLink)\b'
        ($section | ConvertTo-Json -Depth 40) | Should -Not -Match 'serviceEndpointVirtualNetworksApi\.transformed\b(?!\.)'
        (Invoke-CuiExpression $control.constraints.allowedValues $fixture).Count | Should -Be 3
        (Invoke-CuiExpression $control.visible $fixture) | Should -BeTrue
        (Invoke-CuiExpression $status.visible $fixture) | Should -BeFalse
        $inventory.transformed.nextLink = '/subscriptions/test/providers/Microsoft.Network/virtualNetworks?nextPage=2'
        (Invoke-CuiExpression $warning.visible $fixture) | Should -BeTrue
    }

    It 'rejects the cross-lambda capture reported by the live Portal runtime' {
        $expression = "[filter(steps('zeroTrust').serviceEndpointVirtualNetworksApi.transformed.subnets, (snet) => not(empty(filter(steps('zeroTrust').serviceEndpointVirtualNetworksApi.transformed.vnets, (vnet) => startsWith(snet.id, concat(vnet.id, '/subnets/'))))))]"
        { Invoke-CuiExpression $expression $fixture -PortalLambdaScope } |
            Should -Throw '*Unresolved lambda variable: snet*'
    }

    It 'filters by endpoint and parent VNet region without capturing outer lambda variables' {
        $options = Invoke-CuiExpression $control.constraints.allowedValues $fixture -PortalLambdaScope
        $options.Count | Should -Be 3
        ($options.value -join ',') | Should -Match 'east-one/.+east-two/.+west-one/'
        ($options.value -join ',') | Should -Not -Match 'wrong-region|unconfigured'
        $control.constraints.allowedValues | Should -Not -Match 'startsWith\(snet\.id'
    }

    It 'shows VNet and subnet names in the label with a resource group description and preserves distinct subnet IDs' {
        $additional = New-SubnetFixture 'east-one' 'rg-one' 'another-storage-subnet' @('Microsoft.Storage')
        $inventory.transformed.subnets += @($additional)
        $inventory.transformed.vnets[0].properties.subnets += @($additional)
        $options = Invoke-CuiExpression $control.constraints.allowedValues $fixture -PortalLambdaScope
        $sameVnet = @($options | Where-Object label -like 'east-one | *')
        $control.multiLine | Should -BeTrue
        $sameVnet.Count | Should -Be 2
        $sameVnet[0].label | Should -Be 'east-one | all-services'
        $sameVnet[1].label | Should -Be 'east-one | another-storage-subnet'
        $sameVnet[0].description | Should -Be 'Resource Group: rg-one'
        $sameVnet[1].description | Should -Be 'Resource Group: rg-one'
        $sameVnet[0].value | Should -Not -Be $sameVnet[1].value
        Set-CuiValue $fixture "steps('zeroTrust').storageServiceEndpointAccess.storageServiceEndpointSubnets" @($sameVnet.value)
        $submitted = Invoke-CuiExpression $form.view.outputs.parameters.storageServiceEndpointSubnetResourceIds $fixture
        ($submitted -join ',') | Should -Be ($sameVnet.value -join ',')
    }

    It 'keeps the selector visible while loading and populates it after a transformed-only response' {
        $ready = $inventory.transformed
        $inventory.Remove('transformed')
        (Invoke-CuiExpression $control.visible $fixture) | Should -BeTrue
        (Invoke-CuiExpression $status.visible $fixture) | Should -BeTrue
        $options = Invoke-CuiExpression $control.constraints.allowedValues $fixture
        $options.Count | Should -Be 1
        $options[0].label | Should -Be 'Loading subnet inventory'
        $options[0].value | Should -Be ''
        Set-CuiValue $fixture "steps('zeroTrust').storageServiceEndpointAccess.storageServiceEndpointSubnets" @('')
        (Invoke-CuiExpression $form.view.outputs.parameters.storageServiceEndpointSubnetResourceIds $fixture).Count | Should -Be 0
        $inventory.transformed = $ready
        (Invoke-CuiExpression $control.constraints.allowedValues $fixture).Count | Should -Be 3
        (Invoke-CuiExpression $status.visible $fixture) | Should -BeFalse
    }

    It 'distinguishes a loaded empty inventory from an inventory that has not loaded' {
        $inventory.transformed = @{ loaded = $true; vnets = @(); subnets = @(); nextLink = $null }
        (Invoke-CuiExpression $control.visible $fixture) | Should -BeTrue
        (Invoke-CuiExpression $status.visible $fixture) | Should -BeFalse
        (Invoke-CuiExpression $control.constraints.allowedValues $fixture)[0].label | Should -Be 'No eligible subnets found'
    }

    It 'waits for the explicit completion marker rather than treating the transformed container as an output property' {
        $inventory.transformed.Remove('loaded')
        (Invoke-CuiExpression $status.visible $fixture) | Should -BeTrue
        (Invoke-CuiExpression $control.constraints.allowedValues $fixture -PortalLambdaScope)[0].label | Should -Be 'Loading subnet inventory'
        $inventory.transformed.loaded = $true
        (Invoke-CuiExpression $status.visible $fixture) | Should -BeFalse
        (Invoke-CuiExpression $control.constraints.allowedValues $fixture -PortalLambdaScope).Count | Should -Be 3
    }
}

Describe 'New public-mode Portal controls' {
    It 'uses an explicit public default independent of outbound integration and outputs filtered IP arrays' -ForEach @(
        @{ Folder = 'add-ons\imageValidation' }
        @{ Folder = 'add-ons\fslogixProfileManagement' }
    ) {
        $form = Get-Content (Join-Path $repoRoot "deployments\$Folder\uiFormDefinition.json") -Raw | ConvertFrom-Json -AsHashtable
        $section = ($form.view.properties.steps | Where-Object name -eq functionApp).elements | Where-Object name -eq storageServiceEndpointAccess
        $publicSection = ($form.view.properties.steps | Where-Object name -eq functionApp).elements | Where-Object name -eq storagePublicNetworking
        $mode = $publicSection.elements | Where-Object name -eq storagePublicNetworkAccess
        $grid = $section.elements | Where-Object name -eq storagePermittedIPs
        $fixture = New-FormFixture functionApp
        foreach ($enabled in @($true, $false)) {
            Set-CuiValue $fixture "steps('functionApp').networkSettings.enableVnetIntegration" $enabled
            $mode.defaultValue | Should -Be 'Disabled'
        }

        ($mode.constraints.allowedValues.value -join ',') | Should -Be 'Disabled,EnabledWithRestrictions,Enabled'
        $grid.constraints.columns.id | Should -Be 'ipAddress'
        $grid.ariaLabel | Should -Not -BeNullOrEmpty
        $grid.constraints.rows.count.min | Should -Be 0
        $validation = $grid.constraints.columns[0].element.constraints.regex
        '203.0.113.10' | Should -Match $validation
        '203.0.113.0/24' | Should -Match $validation
        '999.0.0.1' | Should -Not -Match $validation
        '203.0.113.0/33' | Should -Not -Match $validation
        (Invoke-CuiExpression $form.view.outputs.parameters.storagePermittedIPs $fixture).Count | Should -Be 0
        Set-CuiValue $fixture "steps('functionApp').storageServiceEndpointAccess.storagePermittedIPs" @(
            @{ ipAddress = '203.0.113.10' }, @{ ipAddress = '' }, @{ ipAddress = '203.0.113.0/24' }
        )
        (Invoke-CuiExpression $form.view.outputs.parameters.storagePermittedIPs $fixture) -join ',' |
            Should -Be '203.0.113.10,203.0.113.0/24'
        (Invoke-CuiExpression $form.view.outputs.parameters.storagePublicNetworkAccess $fixture) | Should -Be 'EnabledWithRestrictions'
        foreach ($publicMode in @('Disabled', 'Enabled')) {
            Set-CuiValue $fixture "steps('functionApp').storagePublicNetworking.storagePublicNetworkAccess" $publicMode
            (Invoke-CuiExpression $form.view.outputs.parameters.storagePermittedIPs $fixture) -join ',' |
                Should -Be '203.0.113.10,203.0.113.0/24'
            (Invoke-CuiExpression $grid.visible $fixture) | Should -BeFalse
        }
    }

    It 'uses an explicit PoC public mode and gates controls and outputs on newly created storage' {
        $form = Get-Content (Join-Path $repoRoot 'deployments\hostpoolPoc\uiFormDefinition.json') -Raw | ConvertFrom-Json -AsHashtable
        $section = ($form.view.properties.steps | Where-Object name -eq options).elements | Where-Object name -eq storageServiceEndpointAccess
        $publicSection = ($form.view.properties.steps | Where-Object name -eq options).elements | Where-Object name -eq storagePublicNetworking
        ($publicSection.elements | Where-Object name -eq storagePublicNetworkAccess).defaultValue | Should -Be 'Disabled'
        $fixture = New-FormFixture options
        Set-CuiValue $fixture "steps('options').deployFSLogixStorage" $false
        (Invoke-CuiExpression $section.visible $fixture) | Should -BeFalse
        (Invoke-CuiExpression $form.view.outputs.parameters.storagePublicNetworkAccess $fixture) | Should -Be 'Disabled'
    }
}

Describe 'Standard host-pool DNS consumer ownership' {
    BeforeAll {
        $form = Get-Content (Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $form.view.outputs.parameters = Get-GroupedNetworkingBindings $form.view.outputs.parameters
        $zeroTrust = $form.view.properties.steps | Where-Object name -eq zeroTrust
        $storageNetworking = $zeroTrust.elements | Where-Object name -eq storagePrivateNetworking
        $genericNetworking = $zeroTrust.elements | Where-Object name -eq privateEndpoints
    }

    BeforeEach {
        $fixture = New-FormFixture zeroTrust
        Set-CuiValue $fixture "steps('zeroTrust').storagePrivateNetworking.enablePrivateDNSIntegration" $true
        Set-CuiValue $fixture "steps('zeroTrust').storagePrivateNetworking.filePrivateDnsZone" '/dns/storage/files'
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.enablePrivateDNSIntegration" $true
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.blobPrivateDnsZone" '/dns/generic/blob'
    }

    It 'owns the Files zone in Storage networking and emits it when generic backup networking is disabled' {
        $files = $storageNetworking.elements | Where-Object name -eq filePrivateDnsZone
        $files | Should -Not -BeNullOrEmpty
        $binding = $form.view.outputs.parameters.filePrivateDnsZoneResourceId
        $binding | Should -Match 'storagePrivateNetworking\.storagePrivateEndpoint'
        $binding | Should -Not -Match 'privateEndpoints'
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.deployBackupAndDiskPrivateEndpoints" $false
        (Invoke-CuiExpression $files.visible $fixture) | Should -BeTrue
        (Invoke-CuiExpression $binding $fixture) | Should -Be '/dns/storage/files'
        Set-CuiValue $fixture "steps('zeroTrust').storagePrivateNetworking.storagePrivateEndpoint" $false
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.deployBackupAndDiskPrivateEndpoints" $true
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.diskPrivateEndpoint" $true
        (Invoke-CuiExpression $binding $fixture) | Should -Be ''
    }

    It 'does not emit the Files zone when no Azure Files account is created' {
        Set-CuiValue $fixture "steps('userProfiles').deployStorage" $false
        (Invoke-CuiExpression $form.view.outputs.parameters.filePrivateDnsZoneResourceId $fixture) | Should -Be ''
    }

    It 'keeps generic Blob DNS available for Personal managed disks when the backup vault is adopted' {
        Set-CuiValue $fixture "steps('controlPlane').hostPool.type" 'Personal'
        Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.recoveryServices" $true
        Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.useExistingRecoveryServicesVault" $true
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.deployBackupAndDiskPrivateEndpoints" $true
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.diskPrivateEndpoint" $true
        $blob = $genericNetworking.elements | Where-Object name -eq blobPrivateDnsZone
        (Invoke-CuiExpression $genericNetworking.visible $fixture) | Should -BeTrue
        (Invoke-CuiExpression $blob.visible $fixture) | Should -BeTrue
        (Invoke-CuiExpression $form.view.outputs.parameters.blobPrivateDnsZoneResourceId $fixture) | Should -Be '/dns/generic/blob'
    }
}

Describe 'Standard host-pool grouped networking scenario contract' {
    BeforeAll {
        $standardForm = Get-Content (Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $parameters = $standardForm.view.outputs.parameters
        $networkStep = $standardForm.view.properties.steps | Where-Object name -eq zeroTrust
        $networkSections = @{}
        foreach ($section in $networkStep.elements) { $networkSections[$section.name] = $section }
        $backupSection = $networkSections.privateEndpoints
        $placementSection = $networkSections.privateEndpointSubnets
    }

    BeforeEach {
        $fixture = New-FormFixture zeroTrust
        Set-CuiValue $fixture "steps('zeroTrust').paasConnectivity.scenario" 'Private'
        Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.enablePrivateLink" $false
        Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.avdPrivateLinkConfig" 'HostPool'
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpointSubnets.sharedSubnet.id" '/placement/shared'
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpointSubnets.hostPoolSubnet.id" '/placement/hosts'
        foreach ($service in @('storage', 'keyVault')) {
            Set-CuiValue $fixture "steps('zeroTrust').${service}PrivateNetworking.enablePrivateDNSIntegration" $true
            Set-CuiValue $fixture "steps('zeroTrust').${service}PublicNetworking.${service}PublicNetworkAccess" 'Enabled'
            Set-CuiValue $fixture "steps('zeroTrust').${service}PrivateNetworking.${service}PrivateEndpoint" $false
            $grid = $networkSections["${service}ServiceEndpointAccess"].elements | Where-Object name -eq "${service}PermittedIPs"
            Set-CuiValue $fixture "steps('zeroTrust').${service}ServiceEndpointAccess.${service}PermittedIPs" @(
                @{ $grid.constraints.columns[0].id = $(if ($service -eq 'storage') { '203.0.113.1' } else { '198.51.100.0/24' }) })
            Set-CuiValue $fixture "steps('zeroTrust').${service}ServiceEndpointAccess.${service}ServiceEndpointSubnets" @("/allowlist/$service", '')
        }
        Set-CuiValue $fixture "steps('zeroTrust').storagePrivateNetworking.filePrivateDnsZone" '/dns/file'
        Set-CuiValue $fixture "steps('zeroTrust').keyVaultPrivateNetworking.vaultPrivateDnsZone" '/dns/vault'
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.enablePrivateDNSIntegration" $true
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.backupPrivateDnsZone" '/dns/backup'
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.blobPrivateDnsZone" '/dns/blob'
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.queuePrivateDnsZone" '/dns/queue'
    }

    It 'exports only sealed grouped networking objects and leaves AVD policy separate' {
        foreach ($removed in @(
            'storagePublicNetworkAccess', 'storagePrivateEndpoint', 'storagePermittedIPs', 'storageServiceEndpointSubnetResourceIds',
            'keyVaultPublicNetworkAccess', 'keyVaultPrivateEndpoint', 'keyVaultPermittedIPs', 'keyVaultServiceEndpointSubnetResourceIds',
            'deployBackupAndDiskPrivateEndpoints', 'sharedResourcesPrivateEndpointSubnetResourceId',
            'hostPoolResourcesPrivateEndpointSubnetResourceId', 'backupPrivateDnsZoneResourceId', 'blobPrivateDnsZoneResourceId',
            'filePrivateDnsZoneResourceId', 'vaultPrivateDnsZoneResourceId', 'queuePrivateDnsZoneResourceId',
            'avdPrivateDnsZoneResourceId', 'globalFeedPrivateDnsZoneResourceId'
        )) { $parameters.ContainsKey($removed) | Should -BeFalse }
        $scenario = $networkSections.paasConnectivity.elements | Where-Object name -eq scenario
        $scenario.defaultValue | Should -Be 'Private connectivity'
        ($scenario.constraints.allowedValues.value -join ',') | Should -Be 'Private,Restricted,Custom'
        $parameters.ContainsKey('scenario') | Should -BeFalse
        foreach ($name in @('workspaceFeedPublicNetworkAccess', 'hostPoolPublicNetworkAccess', 'avdPrivateLinkPrivateRoutes')) {
            $parameters[$name] | Should -Not -Match 'paasConnectivity'
        }
        $networkSections.avdPrivateLink | ConvertTo-Json -Depth 100 | Should -Not -Match 'paasConnectivity'
        $paas = Invoke-CuiExpression $parameters.paasNetworking $fixture
        ($paas.Keys | Sort-Object) -join ',' | Should -Be 'backup,disk,keyVault,privateEndpoint,publicNetworkAccess,storage'
        $subnets = Invoke-CuiExpression $parameters.privateEndpointSubnetResourceIds $fixture
        ($subnets.Keys | Sort-Object) -join ',' | Should -Be 'hostPoolResources,sharedResources'
        $dns = Invoke-CuiExpression $parameters.privateDnsZoneResourceIds $fixture
        ($dns.Keys | Sort-Object) -join ',' | Should -Be 'avdFeed,avdGlobalFeed,backup,blob,file,queue,vault'
    }

    It 'evaluates Private defaults as native true and Disabled while suppressing retained public allowlists' {
        $paas = Invoke-CuiExpression $parameters.paasNetworking $fixture
        $paas | Should -BeOfType [hashtable]
        $paas.privateEndpoint | Should -BeOfType [bool]
        $paas.privateEndpoint | Should -BeTrue
        $paas.publicNetworkAccess | Should -Be 'Disabled'
        foreach ($family in @('storage', 'keyVault')) {
            $paas[$family].privateEndpoint | Should -BeTrue
            $paas[$family].publicNetworkAccess | Should -Be 'Disabled'
            ,($paas[$family].permittedIPs) | Should -BeOfType [array]
            $paas[$family].permittedIPs.Count | Should -Be 0
            $paas[$family].serviceEndpointSubnetResourceIds.Count | Should -Be 0
        }
        $subnets = Invoke-CuiExpression $parameters.privateEndpointSubnetResourceIds $fixture
        $subnets.sharedResources | Should -Be '/placement/shared'
        $subnets.hostPoolResources | Should -Be '/placement/hosts'
    }

    It 'evaluates Restricted as native false with distinct string-array allowlists and no implicit placement authorization' {
        Set-CuiValue $fixture "steps('zeroTrust').paasConnectivity.scenario" 'Restricted'
        $paas = Invoke-CuiExpression $parameters.paasNetworking $fixture
        $paas.privateEndpoint | Should -BeOfType [bool]
        $paas.privateEndpoint | Should -BeFalse
        $paas.publicNetworkAccess | Should -Be 'EnabledWithRestrictions'
        foreach ($family in @('storage', 'keyVault')) {
            $paas[$family].privateEndpoint | Should -BeFalse
            $paas[$family].publicNetworkAccess | Should -Be 'EnabledWithRestrictions'
            ,($paas[$family].permittedIPs) | Should -BeOfType [array]
            $paas[$family].permittedIPs[0] | Should -BeOfType [string]
            ,($paas[$family].serviceEndpointSubnetResourceIds) | Should -BeOfType [array]
            $paas[$family].serviceEndpointSubnetResourceIds.Count | Should -Be 1
            $paas[$family].serviceEndpointSubnetResourceIds[0] | Should -Be "/allowlist/$family"
        }
        $paas.storage.permittedIPs[0] | Should -Be '203.0.113.1'
        $paas.keyVault.permittedIPs[0] | Should -Be '198.51.100.0/24'
        $subnets = Invoke-CuiExpression $parameters.privateEndpointSubnetResourceIds $fixture
        $subnets.sharedResources | Should -Be ''
        $subnets.hostPoolResources | Should -Be ''
        $dns = Invoke-CuiExpression $parameters.privateDnsZoneResourceIds $fixture
        $dns.file | Should -Be ''
        $dns.vault | Should -Be ''
    }

    It 'preserves all six Custom public/private combinations without stringifying booleans or lists' {
        Set-CuiValue $fixture "steps('zeroTrust').paasConnectivity.scenario" 'Custom'
        foreach ($family in @('storage', 'keyVault')) {
            foreach ($enabled in @($true, $false)) {
                foreach ($mode in @('Disabled', 'EnabledWithRestrictions', 'Enabled')) {
                    Set-CuiValue $fixture "steps('zeroTrust').${family}PrivateNetworking.${family}PrivateEndpoint" $enabled
                    Set-CuiValue $fixture "steps('zeroTrust').${family}PublicNetworking.${family}PublicNetworkAccess" $mode
                    $paas = Invoke-CuiExpression $parameters.paasNetworking $fixture
                    $paas[$family].privateEndpoint | Should -BeOfType [bool]
                    $paas[$family].privateEndpoint | Should -Be $enabled
                    $paas[$family].publicNetworkAccess | Should -Be $mode
                    $paas[$family].permittedIPs.Count | Should -Be ([int]($mode -eq 'EnabledWithRestrictions'))
                    $paas[$family].serviceEndpointSubnetResourceIds.Count | Should -Be ([int]($mode -eq 'EnabledWithRestrictions'))
                    foreach ($explanation in @(
                        @{ Name = 'publicAccessDisabledInfo'; Mode = 'Disabled' }
                        @{ Name = 'publicAccessEnabledWithRestrictionsInfo'; Mode = 'EnabledWithRestrictions' }
                        @{ Name = 'publicAccessEnabledInfo'; Mode = 'Enabled' }
                    )) {
                        $control = $networkSections["${family}PublicNetworking"].elements |
                            Where-Object name -eq $explanation.Name
                        (Invoke-CuiExpression $control.visible $fixture) | Should -Be ($mode -eq $explanation.Mode)
                        $control.options.text | Should -Not -Match '^\['
                    }
                    $warning = $networkSections["${family}PublicNetworking"].elements | Where-Object name -eq publicAccessEnabledInfo
                    (Invoke-CuiExpression $warning.visible $fixture) | Should -Be ($mode -eq 'Enabled')
                    $warning.options.text | Should -Match 'unrestricted'
                    $warning.type | Should -Be 'Microsoft.Common.InfoBox'
                    $warning.options.style | Should -Be 'Warning'
                }
            }
        }
    }

    It 'applies Private defaults to owned Backup and Disk Access resources and ignores retained custom overrides' {
        Set-CuiValue $fixture "steps('controlPlane').hostPool.type" 'Personal'
        Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.recoveryServices" $true
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.backupPrivateEndpoint" $false
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.diskPrivateEndpoint" $false
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.backupPublicNetworkAccess" 'Enabled'
        $paas = Invoke-CuiExpression $parameters.paasNetworking $fixture
        $paas.backup.privateEndpoint | Should -BeTrue
        $paas.backup.publicNetworkAccess | Should -Be 'Disabled'
        $paas.disk.privateEndpoint | Should -BeTrue
        Set-CuiValue $fixture "steps('zeroTrust').paasConnectivity.scenario" 'Restricted'
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.backupConnectivity" 'Public'
        $paas = Invoke-CuiExpression $parameters.paasNetworking $fixture
        $paas.backup.privateEndpoint | Should -BeFalse
        $paas.disk.privateEndpoint | Should -BeFalse
        $paas.backup.publicNetworkAccess | Should -Be 'Enabled'
    }

    It 'uses native objects rather than manual JSON escaping for every grouped output value' {
        $value = '/fixture/"quoted"\segment'
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpointSubnets.sharedSubnet.id" $value
        Set-CuiValue $fixture "steps('zeroTrust').storagePrivateNetworking.filePrivateDnsZone" $value
        (Invoke-CuiExpression $parameters.privateEndpointSubnetResourceIds $fixture).sharedResources | Should -Be $value
        (Invoke-CuiExpression $parameters.privateDnsZoneResourceIds $fixture).file | Should -Be $value
        foreach ($name in @('paasNetworking', 'privateEndpointSubnetResourceIds', 'privateDnsZoneResourceIds')) {
            $parameters[$name] | Should -Match '^\[first\(map\(parse\('
            $parameters[$name] | Should -Not -Match 'string\(|createObject|replace\(|substring\('
        }
        (Invoke-CuiExpression "[string('already a string')]" $fixture) | Should -Be 'already a string'
    }

    It 'suppresses inactive and adopted family objects, DNS and placement even with stale retained selections' {
        Set-CuiValue $fixture "steps('userProfiles').deployStorage" $false
        Set-CuiValue $fixture "steps('hosts').identity.deploySecretsKeyVault" $false
        Set-CuiValue $fixture "steps('zeroTrust').keyManagement.useExistingEncryptionKv" $true
        Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.recoveryServices" $true
        Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.useExistingRecoveryServicesVault" $true
        $paas = Invoke-CuiExpression $parameters.paasNetworking $fixture
        foreach ($family in @('storage', 'keyVault', 'backup', 'disk')) { $paas[$family].Count | Should -Be 0 }
        $subnets = Invoke-CuiExpression $parameters.privateEndpointSubnetResourceIds $fixture
        $subnets.sharedResources | Should -Be ''
        $subnets.hostPoolResources | Should -Be ''
        $dns = Invoke-CuiExpression $parameters.privateDnsZoneResourceIds $fixture
        foreach ($name in @('backup', 'blob', 'file', 'vault', 'queue')) { $dns[$name] | Should -Be '' }
    }

    It 'requires an explicit Restricted Backup choice only for newly created pooled or Personal vaults' {
        Set-CuiValue $fixture "steps('zeroTrust').paasConnectivity.scenario" 'Restricted'
        Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.recoveryServices" $true
        $choice = $backupSection.elements | Where-Object name -eq backupConnectivity
        $validation = ($backupSection.elements | Where-Object name -eq backupChoicePrerequisite).constraints.validations[0]
        $choice.defaultValue | Should -Be 'Select Backup connectivity'
        $choice.constraints.allowedValues[0].value | Should -Be ''
        foreach ($pool in @('Pooled', 'Personal')) {
            Set-CuiValue $fixture "steps('controlPlane').hostPool.type" $pool
            (Invoke-CuiExpression $choice.visible $fixture) | Should -BeTrue
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.backupConnectivity" ''
            (Invoke-CuiExpression $validation.isValid $fixture) | Should -BeFalse
            foreach ($mode in @('Private', 'Public')) {
                Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.backupConnectivity" $mode
                (Invoke-CuiExpression $validation.isValid $fixture) | Should -BeTrue
                $paas = Invoke-CuiExpression $parameters.paasNetworking $fixture
                $paas.backup.privateEndpoint | Should -Be ($mode -eq 'Private')
                $paas.backup.publicNetworkAccess | Should -Be $(if ($mode -eq 'Private') { 'Disabled' } else { 'Enabled' })
                $warning = $backupSection.elements | Where-Object name -eq backupPublicWarning
                (Invoke-CuiExpression $warning.visible $fixture) | Should -Be ($mode -eq 'Public')
                $warning.options.text | Should -Match 'cannot enforce IP or service-endpoint subnet allowlists'
                $subnets = Invoke-CuiExpression $parameters.privateEndpointSubnetResourceIds $fixture
                $key = if ($pool -eq 'Pooled') { 'sharedResources' } else { 'hostPoolResources' }
                $subnets[$key] | Should -Be $(if ($mode -eq 'Private') { $(if ($pool -eq 'Pooled') { '/placement/shared' } else { '/placement/hosts' }) } else { '' })
            }
            Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.useExistingRecoveryServicesVault" $true
            (Invoke-CuiExpression $choice.visible $fixture) | Should -BeFalse
            (Invoke-CuiExpression $parameters.paasNetworking $fixture).backup.Count | Should -Be 0
            Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.useExistingRecoveryServicesVault" $false
        }
    }

    It 'keeps Custom Backup public access and private endpoint independent from disk access' {
        Set-CuiValue $fixture "steps('zeroTrust').paasConnectivity.scenario" 'Custom'
        Set-CuiValue $fixture "steps('controlPlane').hostPool.type" 'Personal'
        Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.recoveryServices" $true
        foreach ($backupEndpoint in @($true, $false)) {
            foreach ($diskEndpoint in @($true, $false)) {
                foreach ($public in @('Disabled', 'Enabled')) {
                    Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.backupPrivateEndpoint" $backupEndpoint
                    Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.diskPrivateEndpoint" $diskEndpoint
                    Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.backupPublicNetworkAccess" $public
                    $paas = Invoke-CuiExpression $parameters.paasNetworking $fixture
                    $paas.backup.privateEndpoint | Should -Be $backupEndpoint
                    $paas.backup.publicNetworkAccess | Should -Be $public
                    $paas.disk.privateEndpoint | Should -Be $diskEndpoint
                }
            }
        }
    }

    It 'requires Backup DNS even without optional Blob/Queue integration and preserves adopted-vault Disk Blob DNS' {
        Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.recoveryServices" $true
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.enablePrivateDNSIntegration" $false
        $backupDns = $backupSection.elements | Where-Object name -eq backupPrivateDnsZone
        (Invoke-CuiExpression $backupDns.visible $fixture) | Should -BeTrue
        $dns = Invoke-CuiExpression $parameters.privateDnsZoneResourceIds $fixture
        $dns.backup | Should -Be '/dns/backup'
        $dns.blob | Should -Be ''
        $dns.queue | Should -Be ''
        $validation = ($backupSection.elements | Where-Object name -eq backupDnsPrerequisite).constraints.validations[0]
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.backupPrivateDnsZone" ''
        (Invoke-CuiExpression $validation.isValid $fixture) | Should -BeFalse
        Set-CuiValue $fixture "steps('controlPlane').hostPool.type" 'Personal'
        Set-CuiValue $fixture "steps('operationsAndMonitoring').backup.useExistingRecoveryServicesVault" $true
        Set-CuiValue $fixture "steps('zeroTrust').privateEndpoints.enablePrivateDNSIntegration" $true
        $dns = Invoke-CuiExpression $parameters.privateDnsZoneResourceIds $fixture
        $dns.backup | Should -Be ''
        $dns.blob | Should -Be '/dns/blob'
        $dns.queue | Should -Be ''
    }

    It 'blocks restricted no-endpoint empty allowlists independently by created family' {
        Set-CuiValue $fixture "steps('zeroTrust').paasConnectivity.scenario" 'Restricted'
        foreach ($family in @('storage', 'keyVault')) {
            $prerequisite = $networkSections["${family}ServiceEndpointAccess"].elements | Where-Object name -eq allowlistPrerequisite
            (Invoke-CuiExpression $prerequisite.visible $fixture) | Should -BeTrue
            $prefix = "steps('zeroTrust').${family}ServiceEndpointAccess"
            Set-CuiValue $fixture "$prefix.${family}PermittedIPs" @()
            Set-CuiValue $fixture "$prefix.${family}ServiceEndpointSubnets" @('')
            (Invoke-CuiExpression $prerequisite.constraints.validations[0].isValid $fixture) | Should -BeFalse
            Set-CuiValue $fixture "$prefix.${family}ServiceEndpointSubnets" @("/allowlist/$family")
            (Invoke-CuiExpression $prerequisite.constraints.validations[0].isValid $fixture) | Should -BeTrue
            Set-CuiValue $fixture "steps('zeroTrust').paasConnectivity.scenario" 'Custom'
            Set-CuiValue $fixture "steps('zeroTrust').${family}PublicNetworking.${family}PublicNetworkAccess" 'EnabledWithRestrictions'
            Set-CuiValue $fixture "steps('zeroTrust').${family}PrivateNetworking.${family}PrivateEndpoint" $true
            (Invoke-CuiExpression $prerequisite.visible $fixture) | Should -BeFalse
            Set-CuiValue $fixture "steps('zeroTrust').paasConnectivity.scenario" 'Restricted'
        }
    }

    It 'requires placement for active AVD consumers regardless of the PaaS scenario and rejects missing IDs' {
        Set-CuiValue $fixture "steps('zeroTrust').paasConnectivity.scenario" 'Restricted'
        Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.enablePrivateLink" $true
        Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.avdPrivateLinkConfig" 'FeedAndHostPool'
        foreach ($prefix in @('shared', 'hostPool')) {
            $selector = $placementSection.elements | Where-Object name -eq "${prefix}Subnet"
            $prerequisite = $placementSection.elements | Where-Object name -eq "${prefix}SubnetPrerequisite"
            $selector.constraints.required | Should -BeTrue
            (Invoke-CuiExpression $selector.visible $fixture) | Should -BeTrue
            (Invoke-CuiExpression $prerequisite.constraints.validations[0].isValid $fixture) | Should -BeTrue
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpointSubnets.${prefix}Subnet.id" ''
            (Invoke-CuiExpression $prerequisite.constraints.validations[0].isValid $fixture) | Should -BeFalse
        }
    }

    It 'keeps placement inventories cross-subscription and cross-region with guarded label defaults' {
        foreach ($prefix in @('shared', 'hostPool')) {
            $vnet = $placementSection.elements | Where-Object name -eq "${prefix}VirtualNetwork"
            $api = $placementSection.elements | Where-Object name -eq "${prefix}VirtualNetworksApi"
            $reference = "steps('zeroTrust').privateEndpointSubnets.${prefix}VirtualNetworksApi"
            Set-CuiValue $fixture "steps('zeroTrust').privateEndpointSubnets.${prefix}Subscription.subscriptionId" 'other-subscription'
            (Invoke-CuiExpression $api.request.path $fixture) | Should -Be '/subscriptions/other-subscription/providers/Microsoft.Network/virtualNetworks?api-version=2022-11-01'
            Set-CuiValue $fixture $reference @{ value = @() }
            (Invoke-CuiExpression $vnet.defaultValue $fixture) | Should -Be 'Select a subscription or check virtual network availability'
            Set-CuiValue $fixture $reference @{ value = @(
                @{ name = 'remote-vnet'; id = '/subscriptions/other-subscription/resourceGroups/remote-rg/providers/Microsoft.Network/virtualNetworks/remote-vnet'; location = 'westus' }) }
            $options = Invoke-CuiExpression $vnet.constraints.allowedValues $fixture -PortalLambdaScope
            $options[0].label | Should -Be 'remote-vnet'
            $options[0].description | Should -Be 'Location: westus Resource Group: remote-rg'
            (Invoke-CuiExpression $vnet.defaultValue $fixture) | Should -Be 'remote-vnet'
        }
    }

    It 'keeps AVD feed and global-feed DNS namespaces distinct and their defaults safe before discovery' {
        $avd = $networkSections.avdPrivateLink
        foreach ($case in @(
            @{ Name = 'wvdPrivateLinkDnsZone'; Namespace = 'privatelink.wvd.' }
            @{ Name = 'globalFeedPrivateDnsZone'; Namespace = 'privatelink-global.wvd.' }
        )) {
            $control = $avd.elements | Where-Object name -eq $case.Name
            Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.privateDNSZonesApi" @{}
            (Invoke-CuiExpression $control.constraints.allowedValues $fixture -PortalLambdaScope)[0].value | Should -Be ''
            (Invoke-CuiExpression $control.defaultValue $fixture) | Should -Be 'Select a DNS subscription or check zone availability'
            Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.privateDNSZonesApi" @{ value = @(
                @{ name = 'privatelink.wvd.microsoft.com'; id = '/subscriptions/test/resourceGroups/feed-rg/providers/Microsoft.Network/privateDnsZones/privatelink.wvd.microsoft.com' }
                @{ name = 'privatelink-global.wvd.microsoft.com'; id = '/subscriptions/test/resourceGroups/global-rg/providers/Microsoft.Network/privateDnsZones/privatelink-global.wvd.microsoft.com' }
            ) }
            $options = Invoke-CuiExpression $control.constraints.allowedValues $fixture -PortalLambdaScope
            $options.Count | Should -Be 1
            $options[0].label | Should -Be "$($case.Namespace)microsoft.com"
            (Invoke-CuiExpression $control.defaultValue $fixture) | Should -Be $options[0].label
        }
    }

    It 'suppresses global-feed DNS for cold or existing global workspaces but not a loaded-empty inventory' {
        Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.enablePrivateLink" $true
        Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.enablePrivateDNSIntegration" $true
        Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.avdPrivateLinkConfig" 'All'
        Set-CuiValue $fixture "steps('zeroTrust').avdPrivateLink.globalFeedPrivateDnsZone" '/dns/avd-global'
        $control = $networkSections.avdPrivateLink.elements | Where-Object name -eq globalFeedPrivateDnsZone
        (Invoke-CuiExpression $control.visible $fixture) | Should -BeFalse
        (Invoke-CuiExpression $parameters.privateDnsZoneResourceIds $fixture).avdGlobalFeed | Should -Be ''
        Set-CuiValue $fixture "steps('controlPlane').workspacesApi" @{ value = @() }
        (Invoke-CuiExpression $control.visible $fixture) | Should -BeTrue
        (Invoke-CuiExpression $parameters.privateDnsZoneResourceIds $fixture).avdGlobalFeed | Should -Be '/dns/avd-global'
        Set-CuiValue $fixture "steps('controlPlane').workspacesApi" @{ value = @(@{ name = 'existing-global-feed' }) }
        (Invoke-CuiExpression $control.visible $fixture) | Should -BeFalse
        (Invoke-CuiExpression $parameters.privateDnsZoneResourceIds $fixture).avdGlobalFeed | Should -Be ''
    }
}
