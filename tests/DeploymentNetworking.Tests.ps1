BeforeDiscovery {
    $solutionCases = @(
        @{ Name = 'Image Management'; Folder = 'imageManagement'; Entry = 'imageManagement'; Step = 'storageAccounts'; Family = 'storage'; Count = 17; Families = @('storage'); Zones = @('blob') }
        @{ Name = 'Shared Services'; Folder = 'sharedServices'; Entry = 'sharedServices'; Step = 'operations'; Family = 'keyVault'; Count = 48; Families = @('backup', 'keyVault'); Zones = @('avdFeed', 'avdGlobalFeed', 'backup', 'blob', 'queue', 'vault') }
    )
}

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'UiFormTestHelpers.ps1')
}

Describe 'Typed networking scenarios in <Name>' -ForEach $solutionCases {
    BeforeAll {
        $directory = Join-Path $repoRoot "deployments\$Folder"
        $template = Get-Content (Join-Path $directory "$Entry.json") -Raw | ConvertFrom-Json -Depth 100
        $form = Get-Content (Join-Path $directory 'uiFormDefinition.json') -Raw | ConvertFrom-Json -AsHashtable
        $outputs = $form.view.outputs.parameters
        $networkStep = $form.view.properties.steps | Where-Object name -eq $Step
        $sections = @{}
        foreach ($section in $networkStep.elements) { $sections[$section.name] = $section }
        function Get-SolutionSchema($Schema) {
            if ($Schema.'$ref') { return $template.definitions.($Schema.'$ref'.Replace('#/definitions/', '')) }
            return $Schema
        }
    }

    BeforeEach {
        $fixture = @{}
        Set-CuiValue $fixture "steps('$Step').paasConnectivity.scenario" 'Private'
        foreach ($pair in @(
            @{ Reference = "steps('storageAccounts').deployArtifactsStorageAccount"; Value = $true }
            @{ Reference = "steps('storageAccounts').deployBuildLogsStorageAccount"; Value = $true }
            @{ Reference = "steps('operations').resources.deploySecretsKeyVault"; Value = $true }
            @{ Reference = "steps('operations').resources.deployEncryptionKeyVault"; Value = $true }
            @{ Reference = "steps('operations').resources.deployFSLogixBackupVault"; Value = $false }
            @{ Reference = "steps('operations').backupNetworking.backupConnectivity"; Value = '' }
            @{ Reference = "steps('operations').backupNetworking.backupPrivateEndpoint"; Value = $false }
            @{ Reference = "steps('operations').backupNetworking.backupPublicNetworkAccess"; Value = 'Enabled' }
            @{ Reference = "steps('operations').privateDnsSection.enablePrivateDNSIntegration"; Value = $true }
            @{ Reference = "steps('operations').privateDnsSection.backupPrivateDnsZone"; Value = '/dns/backup' }
            @{ Reference = "steps('operations').privateDnsSection.blobPrivateDnsZone"; Value = '/dns/blob' }
            @{ Reference = "steps('operations').privateDnsSection.queuePrivateDnsZone"; Value = '/dns/queue' }
            @{ Reference = "steps('avdControlPlane').sharedWorkspace.manageWorkspace"; Value = $false }
            @{ Reference = "steps('avdControlPlane').workspaceFeedEndpoint.manageFeedEndpoint"; Value = $false }
            @{ Reference = "steps('avdControlPlane').globalFeed.manageGlobalWorkspace"; Value = $false }
            @{ Reference = "steps('avdControlPlane').privateDns.enablePrivateDNSIntegration"; Value = $true }
            @{ Reference = "steps('avdControlPlane').privateDns.reuseFeedPrivateDnsZoneForGlobalFeed"; Value = $false }
            @{ Reference = "steps('avdControlPlane').privateDns.feedPrivateDnsZone.id"; Value = '/dns/feed' }
            @{ Reference = "steps('avdControlPlane').privateDns.globalPrivateDnsZone.id"; Value = '/dns/global' }
            @{ Reference = "steps('privateNetworking').privateEndpointSubnets.subnet.id"; Value = '/placement/shared' }
            @{ Reference = "steps('storageAccounts').storagePrivateNetworking.privateEndpointSubnet.id"; Value = '/placement/shared' }
        )) { Set-CuiValue $fixture $pair.Reference $pair.Value }
        Set-CuiValue $fixture "steps('$Step').${Family}PublicNetworking.${Family}PublicNetworkAccess" 'Enabled'
        Set-CuiValue $fixture "steps('$Step').${Family}PrivateNetworking.${Family}PrivateEndpoint" $false
        Set-CuiValue $fixture "steps('$Step').${Family}PrivateNetworking.enablePrivateDNSIntegration" $true
        $zoneName = if ($Family -eq 'storage') { 'blob' } else { 'vault' }
        Set-CuiValue $fixture "steps('$Step').${Family}PrivateNetworking.${zoneName}PrivateDnsZone" "/dns/$zoneName"
        Set-CuiValue $fixture "steps('$Step').${Family}ServiceEndpointAccess.${Family}PermittedIPs" @(@{ ipAddress = '203.0.113.10' })
        Set-CuiValue $fixture "steps('$Step').${Family}ServiceEndpointAccess.${Family}ServiceEndpointSubnets" @('/allowlist/source', '')
    }

    It 'exposes only applicable sealed families, shared placement and DNS namespaces' {
        @($template.parameters.PSObject.Properties).Count | Should -Be $Count
        $paas = Get-SolutionSchema $template.parameters.paasNetworking
        $paas.additionalProperties | Should -BeFalse
        @($paas.properties.PSObject.Properties.Name | Where-Object { $_ -notin @('privateEndpoint', 'publicNetworkAccess') } | Sort-Object) |
            Should -Be $Families
        $placement = Get-SolutionSchema $template.parameters.privateEndpointSubnetResourceIds
        $placement.additionalProperties | Should -BeFalse
        $placement.properties.PSObject.Properties.Name | Should -Be 'sharedResources'
        $dns = Get-SolutionSchema $template.parameters.privateDnsZoneResourceIds
        $dns.additionalProperties | Should -BeFalse
        @($dns.properties.PSObject.Properties.Name | Sort-Object) | Should -Be $Zones
        foreach ($name in @('paasNetworking', 'privateEndpointSubnetResourceIds', 'privateDnsZoneResourceIds')) {
            @($template.parameters.$name.defaultValue.PSObject.Properties).Count | Should -Be 0
            $outputs.ContainsKey($name) | Should -BeTrue
        }
        foreach ($name in $outputs.Keys) { $template.parameters.PSObject.Properties.Name | Should -Contain $name }
        $scenario = $sections.paasConnectivity.elements | Where-Object name -eq scenario
        $scenario.defaultValue | Should -Be 'Private connectivity'
        $scenario.constraints.allowedValues.value | Should -Be @('Private', 'Restricted', 'Custom')
    }

    It 'uses native private defaults and does not leak retained public rules' {
        $policy = Invoke-CuiExpression $outputs.paasNetworking $fixture
        $policy.privateEndpoint | Should -BeOfType [bool]
        $policy.privateEndpoint | Should -BeTrue
        $policy.publicNetworkAccess | Should -Be 'Disabled'
        $policy[$Family].privateEndpoint | Should -BeTrue
        $policy[$Family].publicNetworkAccess | Should -Be 'Disabled'
        ,$policy[$Family].permittedIPs | Should -BeOfType [array]
        $policy[$Family].permittedIPs.Count | Should -Be 0
        $policy[$Family].serviceEndpointSubnetResourceIds.Count | Should -Be 0
        (Invoke-CuiExpression $outputs.privateEndpointSubnetResourceIds $fixture).sharedResources | Should -Be '/placement/shared'
    }

    It 'uses independent IP and subnet rules without authorizing private endpoint placement' {
        Set-CuiValue $fixture "steps('$Step').paasConnectivity.scenario" 'Restricted'
        $policy = Invoke-CuiExpression $outputs.paasNetworking $fixture
        $policy.privateEndpoint | Should -BeOfType [bool]
        $policy.privateEndpoint | Should -BeFalse
        $policy[$Family].publicNetworkAccess | Should -Be 'EnabledWithRestrictions'
        $policy[$Family].permittedIPs | Should -Be @('203.0.113.10')
        $policy[$Family].serviceEndpointSubnetResourceIds | Should -Be @('/allowlist/source')
        (Invoke-CuiExpression $outputs.privateEndpointSubnetResourceIds $fixture).sharedResources | Should -Be ''
        $zones = Invoke-CuiExpression $outputs.privateDnsZoneResourceIds $fixture
        foreach ($zone in $zones.Values) { $zone | Should -Be '' }
        $guard = $sections["${Family}ServiceEndpointAccess"].elements | Where-Object name -eq allowlistPrerequisite
        (Invoke-CuiExpression $guard.constraints.validations[0].isValid $fixture) | Should -BeTrue
        Set-CuiValue $fixture "steps('$Step').${Family}ServiceEndpointAccess.${Family}PermittedIPs" @()
        Set-CuiValue $fixture "steps('$Step').${Family}ServiceEndpointAccess.${Family}ServiceEndpointSubnets" @('')
        (Invoke-CuiExpression $guard.constraints.validations[0].isValid $fixture) | Should -BeFalse
    }

    It 'preserves all six Custom public/private combinations and literal warnings' {
        Set-CuiValue $fixture "steps('$Step').paasConnectivity.scenario" 'Custom'
        foreach ($mode in @('Disabled', 'EnabledWithRestrictions', 'Enabled')) {
            foreach ($pe in @($false, $true)) {
                Set-CuiValue $fixture "steps('$Step').${Family}PublicNetworking.${Family}PublicNetworkAccess" $mode
                Set-CuiValue $fixture "steps('$Step').${Family}PrivateNetworking.${Family}PrivateEndpoint" $pe
                $policy = Invoke-CuiExpression $outputs.paasNetworking $fixture
                $policy[$Family].publicNetworkAccess | Should -Be $mode
                $policy[$Family].privateEndpoint | Should -BeOfType [bool]
                $policy[$Family].privateEndpoint | Should -Be $pe
                foreach ($choice in @('Disabled', 'EnabledWithRestrictions', 'Enabled')) {
                    $info = $sections["${Family}PublicNetworking"].elements | Where-Object name -eq "publicAccess${choice}Info"
                    (Invoke-CuiExpression $info.visible $fixture) | Should -Be ($choice -eq $mode)
                    $info.options.text | Should -Not -Match '^\['
                }
                $warning = $sections["${Family}PublicNetworking"].elements | Where-Object name -eq publicAccessEnabledInfo
                $warning.type | Should -Be 'Microsoft.Common.InfoBox'
                $warning.options.style | Should -Be 'Warning'
            }
        }
    }

    It 'retains quotes and backslashes as strings in native object outputs' {
        Set-CuiValue $fixture "steps('$Step').paasConnectivity.scenario" 'Restricted'
        $opaque = '/source/quoted"id\path'
        Set-CuiValue $fixture "steps('$Step').${Family}ServiceEndpointAccess.${Family}ServiceEndpointSubnets" @($opaque)
        $policy = Invoke-CuiExpression $outputs.paasNetworking $fixture
        ,$policy[$Family].serviceEndpointSubnetResourceIds | Should -BeOfType [array]
        $policy[$Family].serviceEndpointSubnetResourceIds[0] | Should -BeExactly $opaque
    }

    It 'suppresses all inactive-family IDs and permits an unloaded inactive inventory' {
        Set-CuiValue $fixture "steps('storageAccounts').deployArtifactsStorageAccount" $false
        Set-CuiValue $fixture "steps('storageAccounts').deployBuildLogsStorageAccount" $false
        Set-CuiValue $fixture "steps('operations').resources.deploySecretsKeyVault" $false
        Set-CuiValue $fixture "steps('operations').resources.deployEncryptionKeyVault" $false
        $policy = Invoke-CuiExpression $outputs.paasNetworking $fixture
        $policy[$Family].Count | Should -Be 0
        (Invoke-CuiExpression $outputs.privateEndpointSubnetResourceIds $fixture).sharedResources | Should -Be ''
        foreach ($zone in (Invoke-CuiExpression $outputs.privateDnsZoneResourceIds $fixture).Values) { $zone | Should -Be '' }
    }

    It 'blocks missing required private endpoint placement explicitly' {
        $section = if ($Folder -eq 'imageManagement') { $sections.storagePrivateNetworking } else {
            ($form.view.properties.steps | Where-Object name -eq privateNetworking).elements | Where-Object name -eq privateEndpointSubnets
        }
        $guard = $section.elements | Where-Object name -eq sharedSubnetPrerequisite
        (Invoke-CuiExpression $guard.visible $fixture) | Should -BeTrue
        Set-CuiValue $fixture "steps('privateNetworking').privateEndpointSubnets.subnet.id" ''
        Set-CuiValue $fixture "steps('storageAccounts').storagePrivateNetworking.privateEndpointSubnet.id" ''
        (Invoke-CuiExpression $guard.constraints.validations[0].isValid $fixture) | Should -BeFalse
    }

    It 'requires an explicit new Backup choice and valid DNS rather than a public fallback' {
        if ($Folder -ne 'sharedServices') { return }
        $endpoint = $sections.backupNetworking.elements | Where-Object name -eq backupPrivateEndpoint
        $endpoint.type | Should -Be 'Microsoft.Common.OptionsGroup'
        $defaultEndpoint = $endpoint.constraints.allowedValues | Where-Object label -eq $endpoint.defaultValue
        $defaultEndpoint.value | Should -BeOfType [bool]
        $defaultEndpoint.value | Should -BeTrue
        $endpoint.constraints.allowedValues | Where-Object label -eq No |
            ForEach-Object value | Should -BeFalse
        Set-CuiValue $fixture "steps('operations').paasConnectivity.scenario" 'Restricted'
        Set-CuiValue $fixture "steps('operations').resources.deployFSLogixBackupVault" $true
        $guard = $sections.backupNetworking.elements | Where-Object name -eq backupChoicePrerequisite
        (Invoke-CuiExpression $guard.visible $fixture) | Should -BeTrue
        (Invoke-CuiExpression $guard.constraints.validations[0].isValid $fixture) | Should -BeFalse
        (Invoke-CuiExpression $outputs.paasNetworking $fixture).backup.Count | Should -Be 0
        foreach ($choice in @('Private', 'Public')) {
            Set-CuiValue $fixture "steps('operations').backupNetworking.backupConnectivity" $choice
            (Invoke-CuiExpression $guard.constraints.validations[0].isValid $fixture) | Should -BeTrue
            $backup = (Invoke-CuiExpression $outputs.paasNetworking $fixture).backup
            $backup.privateEndpoint | Should -Be ($choice -eq 'Private')
            $backup.publicNetworkAccess | Should -Be $(if ($choice -eq 'Private') { 'Disabled' } else { 'Enabled' })
        }
        Set-CuiValue $fixture "steps('operations').backupNetworking.backupConnectivity" 'Private'
        Set-CuiValue $fixture "steps('operations').privateDnsSection.enablePrivateDNSIntegration" $false
        $dnsGuard = $sections.privateDnsSection.elements | Where-Object name -eq backupDnsPrerequisite
        (Invoke-CuiExpression $dnsGuard.visible $fixture) | Should -BeTrue
        (Invoke-CuiExpression $dnsGuard.constraints.validations[0].isValid $fixture) | Should -BeFalse
        Set-CuiValue $fixture "steps('operations').resources.deployFSLogixBackupVault" $false
        (Invoke-CuiExpression $guard.visible $fixture) | Should -BeFalse
        (Invoke-CuiExpression $outputs.paasNetworking $fixture).backup.Count | Should -Be 0
    }

    It 'retains AVD-only shared placement in every scenario without changing its policy' {
        if ($Folder -ne 'sharedServices') { return }
        Set-CuiValue $fixture "steps('operations').resources.deploySecretsKeyVault" $false
        Set-CuiValue $fixture "steps('operations').resources.deployEncryptionKeyVault" $false
        foreach ($scenario in @('Private', 'Restricted', 'Custom')) {
            Set-CuiValue $fixture "steps('operations').paasConnectivity.scenario" $scenario
            foreach ($global in @($false, $true)) {
                Set-CuiValue $fixture "steps('avdControlPlane').sharedWorkspace.manageWorkspace" (-not $global)
                Set-CuiValue $fixture "steps('avdControlPlane').workspaceFeedEndpoint.manageFeedEndpoint" (-not $global)
                Set-CuiValue $fixture "steps('avdControlPlane').globalFeed.manageGlobalWorkspace" $global
                (Invoke-CuiExpression $outputs.privateEndpointSubnetResourceIds $fixture).sharedResources | Should -Be '/placement/shared'
                $zones = Invoke-CuiExpression $outputs.privateDnsZoneResourceIds $fixture
                $zones.avdFeed | Should -Be $(if ($global) { '' } else { '/dns/feed' })
                $zones.avdGlobalFeed | Should -Be $(if ($global) { '/dns/global' } else { '' })
                foreach ($name in @('deployWorkspaceFeedPrivateEndpoint', 'avdWorkspacePublicNetworkAccess', 'manageGlobalAvdWorkspace')) {
                    $outputs[$name] | Should -Not -Match 'paasConnectivity'
                }
            }
        }
    }
}
