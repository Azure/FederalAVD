$repoRoot = Split-Path -Parent $PSScriptRoot

$formCases = @(
    @{
        Name = 'standard host pool'
        Path = Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json'
    }
    @{
        Name = 'session hosts add-on'
        Path = Join-Path $repoRoot 'deployments\add-ons\sessionHosts\uiFormDefinition.json'
    }
    @{
        Name = 'session host replacer add-on'
        Path = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\uiFormDefinition.json'
    }
)

Describe 'Host-pool availability-zone controls' {
    foreach ($formCase in $formCases) {
        Context $formCase.Name {
            BeforeAll {
                $form = Get-Content -LiteralPath $formCase.Path -Raw | ConvertFrom-Json
                $hostsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'hosts' }
                $resourceSkusApi = $hostsStep.elements | Where-Object { $_.name -eq 'resourceSkusApi' }
                $specs = $hostsStep.elements | Where-Object { $_.name -eq 'specs' }
                $genericSize = $specs.elements | Where-Object { $_.name -eq 'sizeGeneric' }
                $availability = $hostsStep.elements | Where-Object { $_.name -eq 'availability' }
                $availabilityOption = $availability.elements | Where-Object { $_.name -eq 'availability' }
                $availabilityZones = $availability.elements | Where-Object { $_.name -eq 'availabilityZones' }
            }

            It 'projects advertised and restricted zones from the SKU API' {
                $availabilityZones.constraints.allowedValues | Should Match 'resourceSkusApi\.value'
                $availabilityZones.constraints.allowedValues | Should Match 'locationInfo'
                $availabilityZones.constraints.allowedValues | Should Match "restriction\.type, 'Zone'"
                $availabilityZones.constraints.allowedValues | Should Not Match 'transformed\.'
            }

            It 'keeps availability options populated and filters restricted zone choices' {
                $availabilityOption.constraints.allowedValues | Should Match 'resourceSkusApi\.value'
                $availabilityOption.constraints.allowedValues | Should Match "restriction\.type, 'Zone'"
                $availabilityOption.defaultValue | Should Match "restriction\.type, 'Zone'"
                $availabilityZones.constraints.allowedValues | Should Match "(sku\.restrictedZones|restriction\.type, 'Zone')"
                $availabilityZones.defaultValue | Should Match "(sku\.restrictedZones|restriction\.type, 'Zone')"
            }

            It 'uses an API-backed searchable VM-size dropdown' {
                $genericSize.type | Should Be 'Microsoft.Common.DropDown'
                $genericSize.filter | Should Be $true
                $genericSize.constraints.allowedValues | Should Match "resourceSkusApi\.transformed\.(genericVMSizes|vmSizes)"
                ($resourceSkusApi.request.transforms.PSObject.Properties.Value -join "`n") | Should Match 'description:join'
                (Get-Content -LiteralPath $formCase.Path -Raw) | Should Not Match 'Microsoft\.Compute\.SizeSelector'
            }

            It 'preserves the availabilityZones deployment output' {
                $form.view.outputs.parameters.availabilityZones | Should Match 'availabilityZones'
                $form.view.outputs.parameters.virtualMachineSize | Should Match 'sizeGeneric'
            }
        }
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$standardFormPath = Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json'
$standardBicepPath = Join-Path $repoRoot 'deployments\hostpools\hostpool.bicep'
$automatedFormPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'
$automatedBicepPath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.bicep'
$standardCorePath = $standardBicepPath
$automatedCorePath = $automatedBicepPath
$hostPoolNamingPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\naming\hostPool.bicep'
$standardControlPlanePath = Join-Path $repoRoot 'deployments\hostpools\modules\control-plane\controlPlane.bicep'
$automatedControlPlanePath = Join-Path $repoRoot 'deployments\automatedHostPools\modules\controlPlane.bicep'

Describe 'AVD workspace ownership contract' {
    BeforeAll {
        $standardFormJson = Get-Content -LiteralPath $standardFormPath -Raw
        $automatedFormJson = Get-Content -LiteralPath $automatedFormPath -Raw
        $standardBicep = Get-Content -LiteralPath $standardBicepPath -Raw
        $automatedBicep = Get-Content -LiteralPath $automatedBicepPath -Raw
        $namingModule = Get-Content -LiteralPath $hostPoolNamingPath -Raw
        $standardControlPlane = Get-Content -LiteralPath $standardControlPlanePath -Raw
        $automatedControlPlane = Get-Content -LiteralPath $automatedControlPlanePath -Raw
    }

    It 'keeps host-pool-specific workspace naming exclusive to the dedicated PoC' {
        $namingModule | Should Match "cnv\(cnv_components, cnv_delimiter, cnv_rtCodes\.workspaces, identifier, cnv_cploc"
        $namingModule | Should Match "'\$\{identifier\}\$\{cnv_delimiter\}control\$\{cnv_delimiter\}plane'"
        foreach ($orchestrator in @($standardBicep, $automatedBicep)) {
            $orchestrator | Should Not Match 'workspaceCreationScope'
            $orchestrator | Should Not Match 'createHostPoolSpecificWorkspace'
            $orchestrator | Should Match 'workspaceName: naming\.outputs\.sharedWorkspaceName'
            $orchestrator | Should Match 'workspaceResourceGroupName: naming\.outputs\.sharedResourceGroupControlPlane'
            $orchestrator | Should Match 'createWorkspaceResourceGroup: true'
        }
        ((Get-Content -LiteralPath $standardFormPath -Raw | ConvertFrom-Json).view.outputs.parameters.PSObject.Properties.Name -join ',') |
            Should Not Match 'workspaceCreationScope'
        ((Get-Content -LiteralPath $automatedFormPath -Raw | ConvertFrom-Json).view.outputs.parameters.PSObject.Properties.Name -join ',') |
            Should Not Match 'workspaceCreationScope'
        $pocBicep = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpoolPoc\hostpoolPoc.bicep') -Raw
        $pocBicep | Should Match 'workspaceName: naming\.outputs\.workspaceName'
        $pocBicep | Should Match 'workspaceResourceGroupName: resourceGroupName'
        $automatedParameters = Get-Content -LiteralPath (Join-Path $repoRoot 'customer-examples\parameters\automatedHostPools\example.automatedHostPool.parameters.json') -Raw |
            ConvertFrom-Json
        ($automatedParameters.parameters.PSObject.Properties.Name -join ',') | Should Not Match 'workspaceCreationScope'
    }

    It 'composes shared capabilities directly without nesting the Shared Services entry template' {
        $standardBicep | Should Not Match "module sharedServices '../sharedServices/sharedServices.bicep'"
        $standardBicep | Should Not Match 'hostPoolCore\.bicep'
        $standardBicep | Should Match "module controlPlane 'modules/control-plane/controlPlane.bicep'"
        $standardBicep | Should Match "module sharedMonitoring '../shared/modules/orchestration/monitoring/monitoring.bicep'"
        $standardBicep | Should Match "module sharedKeyVaults '../shared/modules/orchestration/keyVaults/keyVaults.bicep'"
        $standardBicep | Should Match "module sharedAvdWorkspace '../shared/modules/orchestration/avdWorkspace/avdWorkspace.bicep'"
        $standardBicep | Should Match "module sharedFilesBackup '../shared/modules/resourceModules/recoveryServices/fslogixBackupVault.bicep'"
        $automatedBicep | Should Not Match "module sharedServices '../sharedServices/sharedServices.bicep'"
        $automatedBicep | Should Not Match 'automatedHostPoolCore\.bicep'
        $automatedBicep | Should Match "module controlPlane 'modules/controlPlane.bicep'"
        $automatedBicep | Should Match "module sharedMonitoring '../shared/modules/orchestration/monitoring/monitoring.bicep'"
        $automatedBicep | Should Match "module sharedKeyVaults '../shared/modules/orchestration/keyVaults/keyVaults.bicep'"
        $automatedBicep | Should Match "module sharedAvdWorkspace '../shared/modules/orchestration/avdWorkspace/avdWorkspace.bicep'"
        $automatedBicep | Should Match "module sharedFilesBackup '../shared/modules/resourceModules/recoveryServices/fslogixBackupVault.bicep'"
    }

    It 'enables Shared Services private endpoints for new Key Vaults or backup vaults' {
        $standardBicep | Should Match 'var sharedPrivateEndpoint = deployPrivateEndpoints && \(deploySharedKeyVaults \|\| deploySharedFilesBackup\)'
        $automatedBicep | Should Match 'var sharedPrivateEndpoint = deployPrivateEndpoints && \(deploySharedKeyVaults \|\| deploySharedFilesBackup\)'
        $standardBicep | Should Match 'privateEndpoint: sharedPrivateEndpoint'
        $automatedBicep | Should Match 'privateEndpoint: sharedPrivateEndpoint'
    }

    It 'skips the shared Key Vault orchestration when both vaults are existing or unnecessary' {
        $standardBicep |
            Should Match 'var deploySharedKeyVaults = deploySecretsKeyVault \|\| deploySharedEncryptionKeyVault'
        $automatedBicep |
            Should Match 'var deploySharedKeyVaults = deploySharedSecretsKeyVault \|\| deploySharedEncryptionKeyVault'
        foreach ($orchestrator in @($standardBicep, $automatedBicep)) {
            $orchestrator |
                Should Match "module sharedKeyVaults '../shared/modules/orchestration/keyVaults/keyVaults\.bicep' = if \(deploySharedKeyVaults\)"
            $orchestrator |
                Should Match 'sharedKeyVaults!\.outputs\.secretsKeyVaultResourceId'
            $orchestrator |
                Should Match 'sharedKeyVaults!\.outputs\.encryptionKeyVaultResourceId'
        }
    }

    It 'keeps shared workspace and feed endpoint deployment out of both cores' {
        $standardControlPlane | Should Not Match 'module feedWorkspace_pe'
        $standardControlPlane | Should Not Match 'module globalWorkspace'
        $automatedControlPlane | Should Not Match 'module workspaceFeedPrivateEndpoint'
        $automatedControlPlane | Should Not Match 'module globalWorkspace'
        (Get-Content -LiteralPath $standardCorePath -Raw) | Should Match 'existingFeedWorkspaceResourceId: sharedWorkspaceResourceId'
        (Get-Content -LiteralPath $automatedCorePath -Raw) | Should Match 'existingFeedWorkspaceResourceId: effectiveFeedWorkspaceResourceId'
    }

    It 'does not redeploy existing workspaces unless feed networking is explicitly managed' {
        foreach ($orchestrator in @($standardBicep, $automatedBicep)) {
            $orchestrator | Should Match "var createFeedWorkspace = empty\(existingFeedWorkspaceResourceId\)"
            $orchestrator |
                Should Match "var manageFeedWorkspace = createFeedWorkspace \|\| contains\(\['FeedAndHostPool', 'All'\], avdPrivateLinkPrivateRoutes\)"
            $orchestrator |
                Should Match "module sharedAvdWorkspace '../shared/modules/orchestration/avdWorkspace/avdWorkspace\.bicep' = if \(manageFeedWorkspace\)"
            $orchestrator | Should Match 'manageWorkspace: manageFeedWorkspace'
            $orchestrator |
                Should Match '(sharedWorkspaceResourceId|effectiveFeedWorkspaceResourceId) = manageFeedWorkspace\s+\? sharedAvdWorkspace!\.outputs\.workspaceResourceId\s+: existingFeedWorkspaceResourceId'
            $orchestrator |
                Should Match 'output workspaceFeedPrivateEndpointResourceId string = manageFeedWorkspace\s+\? sharedAvdWorkspace!\.outputs\.workspaceFeedPrivateEndpointResourceId\s+:'
            $orchestrator |
                Should Match 'output globalFeedWorkspaceResourceId string = manageFeedWorkspace\s+\? sharedAvdWorkspace!\.outputs\.globalWorkspaceResourceId\s+: existingGlobalFeedResourceId'
            $orchestrator |
                Should Match 'output globalFeedPrivateEndpointResourceId string = manageFeedWorkspace\s+\? sharedAvdWorkspace!\.outputs\.globalFeedPrivateEndpointResourceId\s+:'
        }
    }

    It 'allows the orchestrators to manage feed and global Private Link explicitly' {
        $standardFormJson | Should Match 'explicitly authorizes the deployment'
        $automatedFormJson | Should Match 'explicitly authorizes the deployment'
        $standardFormJson | Should Match '"value": "FeedAndHostPool"'
        $standardFormJson | Should Match '"value": "All"'
        $automatedFormJson | Should Match '"value": "FeedAndHostPool"'
        $automatedFormJson | Should Match '"value": "All"'
    }

    It 'warns before managing feed Private Link on an existing workspace' {
        $standardFormJson | Should Match '"name": "existingWorkspaceOwnership"'
        $automatedFormJson | Should Match '"name": "existingWorkspaceOwnership"'
        $standardFormJson | Should Match '"style": "Warning"'
        $automatedFormJson | Should Match '"style": "Warning"'
        $standardFormJson | Should Match 'Carefully review changes to this existing workspace'
        $automatedFormJson | Should Match 'Carefully review changes to this existing workspace'
        $standardFormJson | Should Match "existingWorkspaceOwnership[\s\S]{0,500}avdPrivateLinkConfig, 'HostPool'"
        $automatedFormJson | Should Match "existingWorkspaceOwnership[\s\S]{0,500}privateRoutes, 'HostPool'"
        $standardFormJson | Should Match 'can affect feed download and client connectivity for every host pool registered to it'
        $automatedFormJson | Should Match 'can affect feed download and client connectivity for every host pool registered to it'
        $standardFormJson | Should Match 'Confirm ownership and coordinate the change before continuing'
        $automatedFormJson | Should Match 'Confirm ownership and coordinate the change before continuing'
    }

    It 'surfaces global-feed detection and its naming limitation' {
        $standardFormJson | Should Match '"name": "infoBox1"'
        $automatedFormJson | Should Match '"name": "existingGlobalFeedInfo"'
        $standardFormJson | Should Match 'reuses its resource ID instead of creating another global-feed workspace'
        $automatedFormJson | Should Match 'reuses its resource ID instead of creating another global-feed workspace'
        $standardFormJson | Should Match '"name": "globalFeedCreationWarning"'
        $automatedFormJson | Should Match '"name": "globalFeedCreationWarning"'
        $standardFormJson | Should Match 'Automatic detection recognizes workspaces that follow the FederalAVD global-feed naming convention'
        $automatedFormJson | Should Match 'Automatic detection recognizes workspaces that follow the FederalAVD global-feed naming convention'
        $standardFormJson | Should Match 'Verify that no global private endpoint exists elsewhere before continuing'
        $automatedFormJson | Should Match 'Verify that no global private endpoint exists elsewhere before continuing'
    }

    It 'does not manage a global-feed workspace that was supplied as existing' {
        $standardBicep | Should Match "manageGlobalWorkspace: avdPrivateLinkPrivateRoutes == 'All' && empty\(existingGlobalFeedResourceId\)"
        $automatedBicep | Should Match "manageGlobalWorkspace: avdPrivateLinkPrivateRoutes == 'All' && empty\(existingGlobalFeedResourceId\)"
    }

    It 'passes monitoring to shared workspace orchestration' {
        $standardBicep | Should Match 'logAnalyticsWorkspaceResourceId: sharedLogAnalyticsWorkspaceResourceId'
        $automatedBicep | Should Match 'logAnalyticsWorkspaceResourceId: effectiveLogAnalyticsWorkspaceResourceId'
    }

    It 'passes global endpoint networking whenever a new global workspace is required' {
        $standardOutputs = (Get-Content -LiteralPath $standardFormPath -Raw | ConvertFrom-Json).view.outputs.parameters
        $automatedOutputs = (Get-Content -LiteralPath $automatedFormPath -Raw | ConvertFrom-Json).view.outputs.parameters

        foreach ($outputs in @($standardOutputs, $automatedOutputs)) {
            $outputs.existingGlobalFeedResourceId | Should Match "empty\(filter\(.+contains\(.+global-feed"
            $outputs.globalFeedPrivateEndpointSubnetResourceId | Should Match "empty\(filter\(.+contains\(.+global-feed"
            $outputs.globalFeedPrivateEndpointSubnetResourceId | Should Not Match 'createOption'
            $outputs.globalFeedPrivateEndpointSubnetResourceId | Should Not Match 'enablePrivateDNSIntegration'
            $outputs.globalFeedPrivateDnsZoneResourceId | Should Match 'enablePrivateDNSIntegration'
            $outputs.globalFeedPrivateDnsZoneResourceId | Should Not Match 'createOption'
        }
    }

    It 'passes feed endpoint settings for new and existing workspaces' {
        $standardOutputs = (Get-Content -LiteralPath $standardFormPath -Raw | ConvertFrom-Json).view.outputs.parameters
        $automatedOutputs = (Get-Content -LiteralPath $automatedFormPath -Raw | ConvertFrom-Json).view.outputs.parameters

        foreach ($outputs in @($standardOutputs, $automatedOutputs)) {
            $outputs.workspaceFeedPrivateEndpointSubnetResourceId | Should Match 'HostPool'
            $outputs.workspaceFeedPrivateEndpointSubnetResourceId | Should Not Match 'createOption'
            $outputs.workspaceFeedPublicNetworkAccess | Should Match 'HostPool'
            $outputs.workspaceFeedPublicNetworkAccess | Should Not Match 'createOption'
        }
    }
}

Describe 'Common host-pool UI form behavior' {
    BeforeAll {
        $standardForm = Get-Content -LiteralPath $standardFormPath -Raw | ConvertFrom-Json
        $automatedForm = Get-Content -LiteralPath $automatedFormPath -Raw | ConvertFrom-Json
        $automatedBicep = Get-Content -LiteralPath $automatedCorePath -Raw
        $standardFormJson = Get-Content -LiteralPath $standardFormPath -Raw
        $standardBicep = Get-Content -LiteralPath $standardCorePath -Raw

        $standardControlPlane = $standardForm.view.properties.steps | Where-Object { $_.name -eq 'controlPlane' }
        $standardWorkspaceApi = $standardControlPlane.elements | Where-Object { $_.name -eq 'workspacesApi' }
        $standardWorkspaceSection = $standardControlPlane.elements | Where-Object { $_.name -eq 'workspace' }
        $standardExistingWorkspace = $standardWorkspaceSection.elements | Where-Object { $_.name -eq 'existingWorkspace' }
        $standardScalingPlan = $standardControlPlane.elements | Where-Object { $_.name -eq 'scalingPlan' }
        $standardPooledSchedules = $standardScalingPlan.elements | Where-Object { $_.name -eq 'pooledSchedules' }
        $standardOutputs = $standardForm.view.outputs.parameters

        $automatedControlPlane = $automatedForm.view.properties.steps | Where-Object { $_.name -eq 'controlPlane' }
        $automatedWorkspaceSection = $automatedControlPlane.elements | Where-Object { $_.name -eq 'workspace' }
        $automatedExistingWorkspace = $automatedWorkspaceSection.elements | Where-Object { $_.name -eq 'existingWorkspace' }

        $automatedProfiles = $automatedForm.view.properties.steps | Where-Object { $_.name -eq 'profiles' }
        $automatedStorage = $automatedProfiles.elements | Where-Object { $_.name -eq 'storage' }
        $automatedStorageService = $automatedStorage.elements | Where-Object { $_.name -eq 'service' }

        $automatedOperations = $automatedForm.view.properties.steps | Where-Object { $_.name -eq 'operationsAndMonitoring' }
        $automatedMonitoring = $automatedOperations.elements | Where-Object { $_.name -eq 'monitoring' }
        $automatedEnableMonitoring = $automatedMonitoring.elements | Where-Object { $_.name -eq 'enableMonitoring' }

        $automatedProfiles = $automatedForm.view.properties.steps | Where-Object { $_.name -eq 'profiles' }
        $entraKerberosInfoBox = $automatedProfiles.elements | Where-Object { $_.name -eq 'entraKerberosInfoBox' }
    }

    It 'configures the scaling plan exclusion tag without applying it to every session host' {
        $standardBicep | Should Match 'scalingPlanExclusionTag: scalingPlanExclusionTag'
        $standardBicep | Should Match 'tags: tags'
        $standardBicep | Should Not Match "var exclusionTag ="
        $standardBicep | Should Not Match "var hostTags ="
        $standardBicep | Should Not Match 'tags: hostTags'
    }

    It 'outputs a selected standard workspace without rechecking API results' {
        $standardOutputs.existingFeedWorkspaceResourceId | Should Be "[if(equals(steps('controlPlane').workspace.createOption, 'update'), steps('controlPlane').workspace.existingWorkspace, '')]"
        $standardOutputs.workspaceFriendlyName | Should Be "[if(equals(steps('controlPlane').workspace.createOption, 'update'), '', steps('controlPlane').naming.workspaceFriendlyName)]"
        $standardOutputs.existingFeedWorkspaceResourceId | Should Not Match 'workspacesApi'
    }

    It 'requires an explicit existing workspace selection in both forms' {
        $standardExistingWorkspace.PSObject.Properties.Name | Should Not Match 'defaultValue'
        $automatedExistingWorkspace.PSObject.Properties.Name | Should Not Match 'defaultValue'
        $standardExistingWorkspace.constraints.required | Should Be $true
        $automatedExistingWorkspace.constraints.required | Should Be $true
    }

    It 'uses the current workspace list API in the standard form' {
        $standardWorkspaceApi.request.path | Should Match 'api-version=2024-04-03'
        $standardWorkspaceApi.request.path | Should Not Match '2022-02-10-preview'
    }

    It 'does not require interaction with pooled scaling dropdowns that have effective defaults' {
        $dropdownsWithDefaults = @(
            'rampUpLoadBalancingAlgorithm'
            'peakLoadBalancingAlgorithm'
            'rampDownLoadBalancingAlgorithm'
            'rampDownForceLogoffUsers'
            'rampDownStopHostsWhen'
            'offPeakLoadBalancingAlgorithm'
        )

        foreach ($id in $dropdownsWithDefaults) {
            $column = $standardPooledSchedules.constraints.columns | Where-Object { $_.id -eq $id }
            $column.element.constraints.required | Should Be $false
        }

        ($standardPooledSchedules.constraints.columns | Where-Object { $_.id -eq 'daysOfWeek' }).element.constraints.required |
            Should Be $true
    }

    It 'normalizes omitted standard pooled scaling dropdowns like the automated host pool' {
        $standardBicep | Should Match "schedule\.\?rampUpLoadBalancingAlgorithm \?\? 'BreadthFirst'"
        $standardBicep | Should Match "schedule\.\?peakLoadBalancingAlgorithm \?\? 'BreadthFirst'"
        $standardBicep | Should Match "schedule\.\?rampDownLoadBalancingAlgorithm \?\? 'DepthFirst'"
        $standardBicep | Should Match 'schedule\.\?rampDownForceLogoffUsers \?\? false'
        $standardBicep | Should Match "schedule\.\?rampDownStopHostsWhen \?\? 'ZeroSessions'"
        $standardBicep | Should Match "schedule\.\?offPeakLoadBalancingAlgorithm \?\? 'DepthFirst'"
    }

    It 'matches the selected standard VM SKU exactly for capabilities and zones' {
        $standardFormJson | Should Not Match "\(sku\) => contains\(sku\.name, if\(equals\(steps\('hosts'\)\.security\.securityType"
        $standardFormJson | Should Match "\(sku\) => equals\(sku\.name, if\(equals\(steps\('hosts'\)\.security\.securityType"
    }

    It 'enables automated AVD Insights monitoring by default' {
        $automatedEnableMonitoring.defaultValue | Should Be $true
    }

    It 'defaults automated FSLogix storage to Azure Files Premium' {
        $automatedStorageService.defaultValue | Should Be 'Azure Files Premium'
        $automatedForm.view.outputs.parameters.fslogixStorageService | Should Match "'AzureFiles Premium'"
        $automatedBicep | Should Match "param fslogixStorageService string = 'AzureFiles Premium'"
    }

    It 'links automated Entra Kerberos guidance to the selected identity model' {
        $entraKerberosInfoBox.options.uri | Should Match 'EntraKerberos-CloudOnly'
        $entraKerberosInfoBox.options.uri | Should Match 'entra-kerberos-cloud-only\.md'
        $entraKerberosInfoBox.options.uri | Should Match 'entra-kerberos-hybrid\.md'
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$standardFormPath = Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json'

Describe 'Standard host-pool FSLogix storage prefix' {
    It 'allows only an optional lowercase alphanumeric prefix up to 13 characters' {
        $form = Get-Content -LiteralPath $standardFormPath -Raw | ConvertFrom-Json
        $tagsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'tagsAndNaming' }
        $namingSection = $tagsStep.elements | Where-Object { $_.name -eq 'naming' }
        $prefix = $namingSection.elements | Where-Object { $_.name -eq 'fslogixStoragePrefixValue' }

        $prefix.constraints.required | Should Be $false
        $prefix.constraints.regex | Should Be '^[a-z0-9]{0,13}$'
        $prefix.toolTip | Should Match 'lowercase letters or numbers'
        $prefix.constraints.validationMessage | Should Match 'lowercase letters or numbers'
        '' | Should Match $prefix.constraints.regex
        'fslogix123456' | Should Match $prefix.constraints.regex
        'fslogix1234567' | Should Not Match $prefix.constraints.regex
        'fslogix-prefix' | Should Not Match $prefix.constraints.regex
        ([regex]::IsMatch('FSLOGIX', $prefix.constraints.regex)) | Should Be $false
    }
}

Describe 'Session host resource naming defaults' {
    It 'uses stable shared defaults independent of resource type abbreviations' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sharedNaming = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\modules\orchestration\naming\hostPool.bicep') -Raw

        $sharedNaming | Should Match "virtualMachineNameConv\s+=.*: 'SHNAME'"
        $sharedNaming | Should Match "virtualMachineDiskNameConv\s+=.*: 'SHNAME-osdisk'"
        $sharedNaming | Should Match "virtualMachineNicNameConv\s+=.*: 'SHNAME-nic'"
    }

    It 'uses the same defaults in the Session Hosts template' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sessionHostsBicep = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHosts\main.bicep') -Raw

        $sessionHostsBicep | Should Match "param virtualMachineNameConv string = 'SHNAME'"
        $sessionHostsBicep | Should Match "param virtualMachineDiskNameConv string = 'SHNAME-osdisk'"
        $sessionHostsBicep | Should Match "param virtualMachineNicNameConv string = 'SHNAME-nic'"
    }

    It 'uses the same defaults in the Session Host Replacer template' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sessionHostReplacerBicep = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.bicep') -Raw

        $sessionHostReplacerBicep | Should Match "param virtualMachineNameConv string = 'SHNAME'"
        $sessionHostReplacerBicep | Should Match "param virtualMachineDiskNameConv string = 'SHNAME-osdisk'"
        $sessionHostReplacerBicep | Should Match "param virtualMachineNicNameConv string = 'SHNAME-nic'"
    }

    It 'uses the same defaults in the standard host pool form' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $standardForm = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $standardNamingStep = $standardForm.view.properties.steps | Where-Object { $_.name -eq 'tagsAndNaming' }
        $standardNamingSection = $standardNamingStep.elements | Where-Object { $_.name -eq 'naming' }
        $vmControl = $standardNamingSection.elements | Where-Object { $_.name -eq 'vmNameConvOverride' }
        $diskControl = $standardNamingSection.elements | Where-Object { $_.name -eq 'diskNameConvOverride' }
        $nicControl = $standardNamingSection.elements | Where-Object { $_.name -eq 'nicNameConvOverride' }

        $vmControl.defaultValue | Should Be 'SHNAME'
        $diskControl.defaultValue | Should Be 'SHNAME-osdisk'
        $nicControl.defaultValue | Should Be 'SHNAME-nic'
        $vmControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
        $diskControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
        $nicControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
    }

    It 'preserves tag precedence in the Session Hosts form fallbacks' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sessionHostsForm = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHosts\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $sessionHostsAdvancedStep = $sessionHostsForm.view.properties.steps | Where-Object { $_.name -eq 'advanced' }
        $sessionHostsNamingSection = $sessionHostsAdvancedStep.elements | Where-Object { $_.name -eq 'sessionHostNaming' }
        $vmControl = $sessionHostsNamingSection.elements | Where-Object { $_.name -eq 'virtualMachineNameConvOverride' }
        $diskControl = $sessionHostsNamingSection.elements | Where-Object { $_.name -eq 'diskNameConvOverride' }
        $nicControl = $sessionHostsNamingSection.elements | Where-Object { $_.name -eq 'networkInterfaceNameConvOverride' }

        $vmControl.defaultValue | Should Be "[coalesce(steps('basics').hostsRGProps.tags.virtualMachineNameConv, 'SHNAME')]"
        $diskControl.defaultValue | Should Be "[coalesce(steps('basics').hostsRGProps.tags.virtualMachineDiskNameConv, 'SHNAME-osdisk')]"
        $nicControl.defaultValue | Should Be "[coalesce(steps('basics').hostsRGProps.tags.virtualMachineNicNameConv, 'SHNAME-nic')]"
        $vmControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
        $diskControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
        $nicControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
    }

    It 'preserves tag precedence in the Session Host Replacer form fallbacks' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sessionHostReplacerForm = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $sessionHostReplacerAdvancedStep = $sessionHostReplacerForm.view.properties.steps | Where-Object { $_.name -eq 'advanced' }
        $sessionHostReplacerNamingSection = $sessionHostReplacerAdvancedStep.elements | Where-Object { $_.name -eq 'sessionHostNaming' }
        $vmControl = $sessionHostReplacerNamingSection.elements | Where-Object { $_.name -eq 'virtualMachineNameConvOverride' }
        $diskControl = $sessionHostReplacerNamingSection.elements | Where-Object { $_.name -eq 'diskNameConvOverride' }
        $nicControl = $sessionHostReplacerNamingSection.elements | Where-Object { $_.name -eq 'networkInterfaceNameConvOverride' }

        $vmControl.defaultValue | Should Be "[coalesce(steps('basics').hostsRGProps.tags.virtualMachineNameConv, 'SHNAME')]"
        $diskControl.defaultValue | Should Be "[coalesce(steps('basics').hostsRGProps.tags.virtualMachineDiskNameConv, 'SHNAME-osdisk')]"
        $nicControl.defaultValue | Should Be "[coalesce(steps('basics').hostsRGProps.tags.virtualMachineNicNameConv, 'SHNAME-nic')]"
        $vmControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
        $diskControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
        $nicControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
    }
}

Describe 'Standard host-pool PoC form' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $pocFormPath = Join-Path $repoRoot 'deployments\hostpoolPoc\uiFormDefinition.json'
        $hostPoolTemplatePath = Join-Path $repoRoot 'deployments\hostpoolPoc\hostpoolPoc.json'
        $pocBicepPath = Join-Path $repoRoot 'deployments\hostpoolPoc\hostpoolPoc.bicep'
        $publisherPath = Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1'
        $quickStartPath = Join-Path $repoRoot 'docs\quick-start.md'
        $hostPoolReadmePath = Join-Path $repoRoot 'deployments\hostpoolPoc\README.md'
        $pocParametersPath = Join-Path $repoRoot 'customer-examples\parameters\hostpoolPoc\poc.hostpoolPoc.parameters.json'
        $azureFilesBicepPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\fslogix\modules\azureFiles.bicep'
        $pocFormJson = Get-Content -LiteralPath $pocFormPath -Raw
        $pocForm = Get-Content -LiteralPath $pocFormPath -Raw | ConvertFrom-Json
        $hostPoolTemplateJson = Get-Content -LiteralPath $hostPoolTemplatePath -Raw
        $hostPoolTemplate = $hostPoolTemplateJson | ConvertFrom-Json
        $pocBicep = Get-Content -LiteralPath $pocBicepPath -Raw
        $azureFilesBicep = Get-Content -LiteralPath $azureFilesBicepPath -Raw
        $pocOutputs = $pocForm.view.outputs.parameters
    }

    It 'uses the complete subscription deployment output contract' {
        $basicsStep = $pocForm.view.properties.steps | Where-Object { $_.name -eq 'basics' }
        $scope = $basicsStep.elements | Where-Object { $_.name -eq 'scope' }

        $scope.type | Should Be 'Microsoft.Common.ResourceScope'
        $pocForm.view.outputs.kind | Should Be 'Subscription'
        $pocForm.view.outputs.subscriptionId | Should Be "[steps('basics').scope.subscription.id]"
        $pocForm.view.outputs.location | Should Be "[steps('basics').scope.location.name]"
    }

    It 'uses the streamlined three-step experience' {
        @($pocForm.view.properties.steps).Count | Should Be 3
        ($pocForm.view.properties.steps.name -join ',') | Should Be 'basics,sessionHosts,options'
    }

    It 'requires desktop access groups on the first page' {
        $basicsStep = $pocForm.view.properties.steps | Where-Object { $_.name -eq 'basics' }
        $groupPicker = $basicsStep.elements | Where-Object { $_.name -eq 'groupPickerBlade' }
        $groupSelector = $basicsStep.elements | Where-Object { $_.name -eq 'groupSelector' }

        $groupPicker.type | Should Be 'Microsoft.Solutions.BladeInvokeControl'
        $groupPicker.bladeReference.parameters.selectionMinimum | Should Be 1
        $groupSelector.type | Should Be 'Microsoft.Common.Selector'
        $groupSelector.constraints.required | Should Be $true
        $groupSelector.value | Should Be "[steps('basics').groupPickerBlade.transformed.groups]"
        $pocOutputs.appGroupSecurityGroups |
            Should Be "[steps('basics').groupPickerBlade.transformed.groups]"
    }

    It 'describes the PoC as a disposable demo that ends before pilot or production' {
        $flowContent = @(
            $pocFormJson
            Get-Content -LiteralPath $quickStartPath -Raw
            Get-Content -LiteralPath $hostPoolReadmePath -Raw
            Get-Content -LiteralPath $pocParametersPath -Raw
        ) -join "`n"

        $flowContent | Should Match '(?i)\bdisposable\b'
        $flowContent | Should Match '(?i)\btear (?:it )?down\b'
        $flowContent | Should Match '(?i)\bpilot\b'
        $flowContent | Should Match '(?i)start a new'
        $flowContent | Should Match '(?i)full AVD Host Pool'
    }

    It 'warns that common Azure Policy guardrails may deny the PoC' {
        $basicsStep = $pocForm.view.properties.steps | Where-Object { $_.name -eq 'basics' }
        $policyWarning = $basicsStep.elements |
            Where-Object { $_.name -eq 'policyCompatibilityWarning' }
        $documentation = @(
            Get-Content -LiteralPath $quickStartPath -Raw
            Get-Content -LiteralPath $hostPoolReadmePath -Raw
        )

        $policyWarning.type | Should Be 'Microsoft.Common.InfoBox'
        $policyWarning.options.style | Should Be 'Warning'
        $policyWarning.options.text | Should Match '(?i)Azure Policy guardrails'
        $policyWarning.options.text | Should Match '(?i)may deny this deployment'
        $policyWarning.options.text | Should Match '(?i)Do not weaken production guardrails'
        foreach ($content in $documentation) {
            $content | Should Match '(?i)Azure Policy guardrails'
            $content | Should Match '(?i)may deny the deployment'
            $content | Should Match '(?i)Do not weaken production guardrails'
        }
    }

    It 'fixes the isolated PoC ownership and security posture' {
        $pocBicep | Should Match "identitySolution: 'EntraId'"
        $pocBicep | Should Match "availability: 'None'"
        $pocBicep | Should Match 'encryptionAtHost: false'
        $pocBicep | Should Match "hostPoolRDPProperties: 'enablerdsaadauth:i:1;'"
        $pocBicep | Should Match 'deployScalingPlan: false'
        $pocBicep | Should Match 'deployRecoveryServices: false'
        $pocBicep | Should Match 'deployPrivateEndpoints: false'
        $pocBicep | Should Match "avdPrivateLinkPrivateRoutes: 'None'"
        $pocBicep | Should Match 'workspaceResourceGroupName: resourceGroupName'
    }

    It 'defaults optional profiles on and monitoring off' {
        $optionsStep = $pocForm.view.properties.steps | Where-Object { $_.name -eq 'options' }
        $fslogix = $optionsStep.elements | Where-Object { $_.name -eq 'deployFSLogixStorage' }
        $monitoring = $optionsStep.elements | Where-Object { $_.name -eq 'enableMonitoring' }

        $fslogix.type | Should Be 'Microsoft.Common.OptionsGroup'
        $fslogix.label | Should Be 'FSLogix Profile Containers'
        $fslogix.defaultValue | Should Be 'Yes - deploy FSLogix profile containers (2 hosts)'
        $monitoring.type | Should Be 'Microsoft.Common.OptionsGroup'
        $monitoring.defaultValue | Should Be 'No - skip monitoring resources'
        $pocBicep | Should Match 'var sessionHostCount = deployFSLogixStorage \? 2 : 1'

        $sessionHostsStep = $pocForm.view.properties.steps | Where-Object { $_.name -eq 'sessionHosts' }
        @($sessionHostsStep.elements | Where-Object { $_.name -eq 'sessionHostCount' }).Count | Should Be 0
    }

    It 'skips the deployment helper and NTFS ACL step for storage-account-key authentication' {
        $standardBicep = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpools\hostpool.bicep') -Raw
        $fslogixStorageAddonBicep = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\fslogixStorage\main.bicep') -Raw

        $azureFilesBicep | Should Match "module SetNTFSPermissions .* = if \(identitySolution != 'EntraId'\)"
        $standardBicep | Should Match "var createDeploymentVm = \(deployFSLogixStorage && identitySolution != 'EntraId'\)"
        $fslogixStorageAddonBicep | Should Match "var deploymentVirtualMachineRequired = identitySolution != 'EntraId'"
        $fslogixStorageAddonBicep | Should Match 'module deploymentHelper .* = if \(deployDeploymentVirtualMachine\)'
        $fslogixStorageAddonBicep | Should Match 'module cleanupDeploymentHelper .* = if \(deployDeploymentVirtualMachine\)'
        $pocBicep | Should Not Match 'module deploymentResourceGroup'
        $pocBicep | Should Not Match 'module deploymentHelper'
        $pocBicep | Should Not Match 'module cleanupDeploymentHelper'
        $pocBicep | Should Match "deploymentUserAssignedIdentityClientId: ''"
        $pocBicep | Should Match "deploymentVirtualMachineName: ''"
    }

    It 'explains the streamlined PoC decisions at each step' {
        $allElements = @($pocForm.view.properties.steps | ForEach-Object { $_.elements })
        $infoBoxes = @($allElements | Where-Object { $_.type -eq 'Microsoft.Common.InfoBox' })
        $infoText = $infoBoxes.options.text -join "`n"

        $infoBoxes.Count | Should BeGreaterThan 5
        $infoText | Should Match 'Microsoft Entra security groups'
        $infoText | Should Match 'private session-host subnet'
        $infoText | Should Match 'NAT Gateway'
        $infoText | Should Match 'do not receive public IP addresses'
        $infoText | Should Match 'latest available Windows 11 multi-session SKU'
        $infoText | Should Match 'FSLogix profile containers'
        $infoText | Should Match 'two session hosts'
        $infoText | Should Match 'Windows Credential Manager'
        $infoText | Should Match 'AVD Insights'
        $infoText | Should Match 'disposable demonstration environment'
        $infoText | Should Match 'delete the consolidated PoC resource group'
        $infoUris = $infoBoxes.options.uri -join "`n"
        $infoUris | Should Match 'azure/nat-gateway/nat-overview'
        $infoUris | Should Match 'azure/virtual-desktop/configure-single-sign-on'
        $infoUris | Should Match 'fslogix/overview-what-is-fslogix'
        $infoUris | Should Match 'azure/virtual-desktop/insights'
    }

    It 'limits VM sizes to region-available 4-vCPU D4s and D4as SKUs' {
        $sessionHostsStep = $pocForm.view.properties.steps | Where-Object { $_.name -eq 'sessionHosts' }
        $vmSizesApi = $sessionHostsStep.elements | Where-Object { $_.name -eq 'vmSizesApi' }
        $vmSize = $sessionHostsStep.elements | Where-Object { $_.name -eq 'virtualMachineSize' }

        $vmSizesApi.request.path | Should Match 'Microsoft\.Compute/skus'
        $vmSizesApi.request.path | Should Match '\$filter=location eq'
        $vmSizesApi.request.transforms.sizes | Should Match "starts_with\(name, 'Standard_D4s_'\)"
        $vmSizesApi.request.transforms.sizes | Should Match "starts_with\(name, 'Standard_D4as_'\)"
        $vmSizesApi.request.transforms.sizes | Should Match "name == 'vCPUs'"
        $vmSizesApi.request.transforms.sizes | Should Match "== '4'"
        $vmSizesApi.request.transforms.sizes | Should Match "type == 'Location'"
        $vmSizesApi.request.transforms.sizes | Should Match "name == 'MemoryGB'"
        $vmSize.type | Should Be 'Microsoft.Common.DropDown'
        $vmSize.multiLine | Should Be $true
        $vmSize.filter | Should Be $true
        $vmSize.constraints.allowedValues | Should Be "[steps('sessionHosts').vmSizesApi.transformed.sizes]"
    }

    It 'selects the latest region-available Office 365 marketplace SKU' {
        $sessionHostsStep = $pocForm.view.properties.steps | Where-Object { $_.name -eq 'sessionHosts' }
        $skuApi = $sessionHostsStep.elements | Where-Object { $_.name -eq 'office365SkusApi' }

        $skuApi.type | Should Be 'Microsoft.Solutions.ArmApiControl'
        $skuApi.condition | Should Match "steps\('basics'\)\.scope\.subscription\.id"
        $skuApi.condition | Should Match "steps\('basics'\)\.scope\.location\.name"
        $skuApi.request.path | Should Match '/publishers/MicrosoftWindowsDesktop/artifacttypes/vmimage/offers/office-365/skus'
        $skuApi.request.transforms.latest | Should Match 'starts_with\(name, `win11`\)'
        $skuApi.request.transforms.latest | Should Match 'contains\(name, `avd`\)'
        $skuApi.request.transforms.latest | Should Match 'contains\(name, `m365`\)'
        $skuApi.request.transforms.latest | Should Match 'sort_by'
        $skuApi.request.transforms.latest | Should Match 'reverse'
        $skuApi.request.transforms.latest | Should Match '\|\[0\]'
        $pocBicep | Should Match "imagePublisher: 'MicrosoftWindowsDesktop'"
        $pocBicep | Should Match "imageOffer: 'office-365'"
        $pocOutputs.imageSku | Should Be "[steps('sessionHosts').office365SkusApi.transformed.latest]"
    }

    It 'maps every form output and every required input to the host-pool template' {
        $templateParameterNames = @($hostPoolTemplate.parameters.PSObject.Properties.Name)
        $outputNames = @($pocOutputs.PSObject.Properties.Name)
        $unmappedOutputs = @($outputNames | Where-Object { $_ -notin $templateParameterNames })
        $requiredParameters = @(
            $hostPoolTemplate.parameters.PSObject.Properties |
                Where-Object { -not $_.Value.PSObject.Properties['defaultValue'] } |
                ForEach-Object { $_.Name }
        )
        $missingRequiredParameters = @($requiredParameters | Where-Object { $_ -notin $outputNames })

        $unmappedOutputs | Should BeNullOrEmpty
        $missingRequiredParameters | Should BeNullOrEmpty
    }

    It 'publishes the dedicated PoC template with the dedicated PoC form' {
        $publisher = Get-Content -LiteralPath $publisherPath -Raw

        $publisher | Should Match '\[bool\]\$createHostPoolPoc = \$false'
        $publisher | Should Match "Purpose = 'hostpool-poc'"
        $publisher | Should Match "DisplayName = 'AVD Standard PoC'"
        $publisher | Should Match 'deployments\\hostpoolPoc\\hostpoolPoc\.json'
        $publisher | Should Match 'deployments\\hostpoolPoc\\uiFormDefinition\.json'
    }

    It 'creates a private NAT-backed network in the consolidated PoC resource group' {
        $hostPoolBicep = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpools\hostpool.bicep') -Raw

        $hostPoolBicep | Should Not Match 'deployStandaloneNetwork'
        $hostPoolBicep | Should Not Match 'standaloneNetwork'
        $pocBicep | Should Match "module resourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy\.bicep'"
        $pocBicep | Should Match "module network '../networking/modules/vnet-sub-module\.bicep'"
        ([regex]::Matches(
            $pocBicep,
            "resourceId\(\s*subscription\(\)\.subscriptionId,\s*resourceGroupName,"
        )).Count | Should Be 3
        $pocBicep | Should Match "defaultRouting: 'nat'"
        $pocBicep | Should Match 'defaultOutboundAccess: false'
        $pocBicep | Should Match 'vnetResourceGroupName: resourceGroupName'
        $pocBicep | Should Match 'subnetResourceId: sessionHostSubnetResourceId'
        $pocBicep | Should Match 'publicIPName:'
        $pocBicep | Should Match 'natGatewayName:'
        $pocFormJson | Should Not Match 'virtualNetworksApi'
        $pocFormJson | Should Not Match '"name": "subnet"'

        $pocParameters = Get-Content -LiteralPath $pocParametersPath -Raw | ConvertFrom-Json
        ($pocParameters.parameters.PSObject.Properties.Name -notcontains 'deployStandaloneNetwork') |
            Should Be $true
        ($pocParameters.parameters.PSObject.Properties.Name -notcontains 'virtualMachineSubnetResourceId') |
            Should Be $true
        $hostPoolBicep | Should Not Match 'resourceGroupOrganization'
        $hostPoolBicep | Should Not Match 'consolidatedResourceGroup'
    }

    It 'does not emit invalid private-endpoint virtual network collection references' {
        $hostPoolTemplateJson | Should Not Match 'privateEndpointVirtualNetworks'
        $hostPoolTemplateJson |
            Should Not Match "indexOf\(variables\('privateEndpointVirtualNetworkResourceIds'\)"
    }
}
