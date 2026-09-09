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

Describe 'Common host-pool UI form behavior' {
    BeforeAll {
        $standardForm = Get-Content -LiteralPath $standardFormPath -Raw | ConvertFrom-Json
        $automatedForm = Get-Content -LiteralPath $automatedFormPath -Raw | ConvertFrom-Json
        $automatedBicep = Get-Content -LiteralPath $automatedBicepPath -Raw
        $standardFormJson = Get-Content -LiteralPath $standardFormPath -Raw
        $standardBicep = Get-Content -LiteralPath $standardBicepPath -Raw

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
