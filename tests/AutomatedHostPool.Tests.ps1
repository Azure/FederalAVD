$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'
$standardFormPath = Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json'
$bicepPath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.bicep'
$armPath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.json'
$policyAdapterPath = Join-Path $repoRoot 'deployments\automatedHostPools\policy\main.bicep'
$availabilitySetAdapterPath = Join-Path $repoRoot 'deployments\automatedHostPools\modules\availabilitySet.bicep'
$availabilitySetPolicyPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\modules\virtualMachine-availabilitySet.policyDefinition.bicep'
$creationSettingsPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\modules\sessionHostCreationSettings.policySetDefinition.bicep'
$readmePath = Join-Path $repoRoot 'deployments\automatedHostPools\README.md'

Describe 'Automated host-pool Availability Set placement' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $standardForm = Get-Content -LiteralPath $standardFormPath -Raw | ConvertFrom-Json
        $formJson = Get-Content -LiteralPath $formPath -Raw
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $arm = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json
        $policyAdapter = Get-Content -LiteralPath $policyAdapterPath -Raw
        $availabilitySetAdapter = Get-Content -LiteralPath $availabilitySetAdapterPath -Raw
        $availabilitySetPolicy = Get-Content -LiteralPath $availabilitySetPolicyPath -Raw
        $creationSettings = Get-Content -LiteralPath $creationSettingsPath -Raw
        $readme = Get-Content -LiteralPath $readmePath -Raw
        $hostsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'hosts' }
        $hostDetails = $hostsStep.elements | Where-Object { $_.name -eq 'hostDetails' }
        $availabilitySection = $hostsStep.elements | Where-Object { $_.name -eq 'availability' }
        $standardHostsStep = $standardForm.view.properties.steps | Where-Object { $_.name -eq 'hosts' }
        $standardAvailabilitySection = $standardHostsStep.elements | Where-Object { $_.name -eq 'availability' }
        $sessionHostCount = $hostDetails.elements | Where-Object { $_.name -eq 'sessionHostCount' }
        $availabilityOption = $availabilitySection.elements | Where-Object { $_.name -eq 'option' }
        $standardAvailabilityOption = $standardAvailabilitySection.elements | Where-Object { $_.name -eq 'availability' }
    }

    It 'offers managed Availability Sets and maps the selection to the template' {
        $availabilityOption.constraints.allowedValues | Should Match 'Availability Sets'
        $availabilityOption.constraints.allowedValues | Should Match 'AvailabilitySets'
        $availabilityOption.constraints.allowedValues | Should Match 'No infrastructure redundancy required'
        $availabilityOption.constraints.allowedValues | Should Match "if\(empty\(filter\("
        $availabilityOption.constraints.allowedValues | Should Not Match "concat\(if\(empty\(filter\("
        $availabilityOption.constraints.allowedValues | Should Match 'parse\(''\[\{"label":"Availability Sets"'
        $availabilityOption.defaultValue | Should Match "'Availability Sets', 'Availability Zones'"
        $standardAvailabilityOption.defaultValue | Should Match "'Availability Sets', 'Availability Zones'"
        $formJson | Should Match '"availability"\s*:\s*"\[steps\(''hosts''\)\.availability\.option\]"'
        $arm.parameters.availability.allowedValues.Count | Should Be 3
        ($arm.parameters.availability.allowedValues -contains 'AvailabilitySets') | Should Be $true
    }

    It 'creates one managed Availability Set and excludes zones' {
        $bicep | Should Match "var deployAvailabilitySet = availability == 'AvailabilitySets' && availabilitySetCapacityIsValid"
        $bicep | Should Match "module availabilitySet 'modules/availabilitySet.bicep' = if \(deployAvailabilitySet\) \{"
        $bicep | Should Not Match 'deploy: deployAvailabilitySet'
        $availabilitySetAdapter | Should Match "module availabilitySet .* = \{"
        $availabilitySetAdapter | Should Not Match '(?m)^param deploy bool$'
        $availabilitySetAdapter | Should Match "../../shared/modules/resourceModules/compute/availabilitySets/deploy.bicep"
        $availabilitySetAdapter | Should Match "replace\(nameConvention, '-##', ''\)"
        $availabilitySetAdapter | Should Not Match '\[for '
        $availabilitySetAdapter | Should Not Match 'padLeft\('
        $availabilitySetAdapter | Should Match 'output resourceId string'
        $bicep | Should Match 'Availability Zones and an Availability Set are mutually exclusive'
        $bicep | Should Match "availability == 'AvailabilityZones' \? availabilityZones : null"
        $readme | Should Match 'create one managed Availability Set'
        $readme | Should Match 'mutually exclusive'
    }

    It 'assigns every VM to the single set through one fail-closed Modify policy assignment' {
        $availabilitySetPolicy | Should Match "field: 'Microsoft.Compute/virtualMachines/availabilitySet.id'"
        $availabilitySetPolicy | Should Match "conflictEffect: 'deny'"
        $availabilitySetPolicy | Should Match "operation: 'AddOrReplace'"
        $availabilitySetPolicy | Should Match "parameters\(\\'availabilitySetResourceId\\'\)"
        $availabilitySetPolicy | Should Not Match 'availabilitySetResourceIds'
        $availabilitySetPolicy | Should Not Match 'first\(skip\('
        $availabilitySetPolicy | Should Not Match 'last\(split\(field\('
        $creationSettings | Should Match "policyDefinitionReferenceId: 'configureAvailabilitySet'"
        $creationSettings | Should Match "availabilitySetResourceId:"
        $creationSettings | Should Not Match 'availabilitySetResourceIds'
        ([regex]::Matches($creationSettings, "policyDefinitionReferenceId: 'configureAvailabilitySet'")).Count | Should Be 1
        $policyAdapter | Should Match "availabilitySetEffect:"
        $policyAdapter | Should Match "value: empty\(availabilitySetResourceId\) \? 'Disabled' : 'Modify'"
        $policyAdapter | Should Not Match 'availabilitySetResourceIds'
        $bicep | Should Match "availabilitySetResourceId: deployAvailabilitySet \? availabilitySet!\.outputs\.resourceId : ''"
        $readme | Should Match 'before the Compute\s+resource provider processes each VM creation request'
    }

    It 'validates single-set capacity including update headroom' {
        $sessionHostCount.max | Should Match 'AvailabilitySets.*200.*1000'
        $bicep | Should Not Match '@maxValue\(200\)[\r\n]+param sessionHostCount'
        $bicep | Should Match 'var availabilitySetCapacityIsValid'
        $bicep | Should Match 'maximumSessionHostCapacity \+ updateMaxVmsRemoved <= 200'
        $bicep | Should Match "Availability Sets require deleteOriginalVm to be true"
        $bicep | Should Match 'use Availability Zones when supported or select no infrastructure redundancy'
        $bicep | Should Match 'dynamicScalingMaximumHostPoolSizes'
        $bicep | Should Match 'schedule.rampUpMaximumHostPoolSize'
        $bicep | Should Match 'schedule.rampDownMaximumHostPoolSize'
        $formJson | Should Match 'Enter a positive whole number.'
        ($arm.parameters.sessionHostCount.PSObject.Properties.Name -contains 'maxValue') | Should Be $false
        $readme | Should Match 'plus `updateMaxVmsRemoved` to be no greater than\s+200'
    }

    It 'warns in the form and uses the correct static or dynamic capacity source' {
        $formJson | Should Match '"name": "availabilitySetCapacityWarning"'
        $formJson | Should Match 'Session Host Update creates replacement VMs before deleting the originals'
        $formJson | Should Match '"name": "availabilitySetStaticCapacityError"'
        $formJson | Should Match 'select Availability Zones when supported or No infrastructure redundancy required'
        $formJson | Should Match "add\(steps\('hosts'\)\.hostDetails\.sessionHostCount, steps\('operationsAndMonitoring'\)\.updates\.maxVmsRemoved\)"
        $formJson | Should Match '"name": "availabilitySetDynamicCapacityError"'
        $formJson | Should Match "not\(empty\(filter\(steps\('controlPlane'\)\.dynamicScaling\.schedules"
        $formJson | Should Not Match "max\(concat\(map\(steps\('controlPlane'\)\.dynamicScaling\.schedules"
        $formJson | Should Match "schedule\.rampUpMaximumHostPoolSize"
        $formJson | Should Match "schedule\.rampDownMaximumHostPoolSize"
        $formJson | Should Match '"deleteOriginalVm": "\[if\(equals\(steps\(''hosts''\)\.availability\.option, ''AvailabilitySets''\), true,'
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'
$bicepPath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.bicep'

function Get-DynamicScheduleColumns {
    $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
    $controlPlane = $form.view.properties.steps | Where-Object { $_.name -eq 'controlPlane' }
    $dynamicScaling = $controlPlane.elements | Where-Object { $_.name -eq 'dynamicScaling' }
    $scheduleGrid = $dynamicScaling.elements | Where-Object { $_.name -eq 'schedules' }
    return @($scheduleGrid.constraints.columns)
}

Describe 'Automated host-pool dynamic scaling schedules' {
    It 'does not require interaction with dropdowns that have effective defaults' {
        $columns = Get-DynamicScheduleColumns
        $dropdownsWithDefaults = @(
            'rampUpLoadBalancingAlgorithm'
            'peakLoadBalancingAlgorithm'
            'rampDownLoadBalancingAlgorithm'
            'rampDownForceLogoffUsers'
            'rampDownStopHostsWhen'
            'offPeakLoadBalancingAlgorithm'
        )

        foreach ($id in $dropdownsWithDefaults) {
            $column = $columns | Where-Object { $_.id -eq $id }
            $column.element.constraints.required | Should Be $false
        }

        ($columns | Where-Object { $_.id -eq 'daysOfWeek' }).element.constraints.required | Should Be $true
    }

    It 'normalizes omitted dropdown values to their displayed defaults' {
        $bicep = Get-Content -LiteralPath $bicepPath -Raw

        $bicep | Should Match "schedule\.\?rampUpLoadBalancingAlgorithm \?\? 'BreadthFirst'"
        $bicep | Should Match "schedule\.\?peakLoadBalancingAlgorithm \?\? 'BreadthFirst'"
        $bicep | Should Match "schedule\.\?rampDownLoadBalancingAlgorithm \?\? 'DepthFirst'"
        $bicep | Should Match 'schedule\.\?rampDownForceLogoffUsers \?\? false'
        $bicep | Should Match "schedule\.\?rampDownStopHostsWhen \?\? 'ZeroSessions'"
        $bicep | Should Match "schedule\.\?offPeakLoadBalancingAlgorithm \?\? 'DepthFirst'"
    }

    It 'groups schedule columns by scaling period' {
        $columns = Get-DynamicScheduleColumns
        $expectedOrder = @(
            'name'
            'daysOfWeek'
            'rampUpStartTime'
            'rampUpLoadBalancingAlgorithm'
            'rampUpMinimumHostsPct'
            'rampUpCapacityThresholdPct'
            'rampUpMinimumHostPoolSize'
            'rampUpMaximumHostPoolSize'
            'peakStartTime'
            'peakLoadBalancingAlgorithm'
            'rampDownStartTime'
            'rampDownLoadBalancingAlgorithm'
            'rampDownMinimumHostsPct'
            'rampDownCapacityThresholdPct'
            'rampDownMinimumHostPoolSize'
            'rampDownMaximumHostPoolSize'
            'rampDownForceLogoffUsers'
            'rampDownWaitTimeMinutes'
            'rampDownNotificationMessage'
            'rampDownStopHostsWhen'
            'offPeakStartTime'
            'offPeakLoadBalancingAlgorithm'
        )

        ($columns.id -join ',') | Should Be ($expectedOrder -join ',')
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'
$readmePath = Join-Path $repoRoot 'deployments\automatedHostPools\README.md'
$bicepPath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.bicep'
$armPath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.json'
$exampleParametersPath = Join-Path $repoRoot 'customer-examples\parameters\automatedHostPools\poc.automatedHostPool.parameters.json'

Describe 'Automated host-pool ephemeral OS disk guidance' {
    BeforeAll {
        $formJson = Get-Content -LiteralPath $formPath -Raw
        $form = $formJson | ConvertFrom-Json
        $controlPlaneStep = $form.view.properties.steps | Where-Object { $_.name -eq 'controlPlane' }
        $hostsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'hosts' }
        $dynamicScaling = $controlPlaneStep.elements | Where-Object { $_.name -eq 'dynamicScaling' }
        $capacity = $hostsStep.elements | Where-Object { $_.name -eq 'capacity' }
        $scalingRecommendation = $dynamicScaling.elements | Where-Object { $_.name -eq 'ephemeralOsDiskRecommendation' }
        $ephemeralWarning = $capacity.elements | Where-Object { $_.name -eq 'ephemeralOsDiskAutoscalingWarning' }
        $placement = $capacity.elements | Where-Object { $_.name -eq 'ephemeralOsDiskPlacement' }
        $readme = Get-Content -LiteralPath $readmePath -Raw
        $bicep = Get-Content -LiteralPath $bicepPath -Raw
        $arm = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json
        $exampleParameters = Get-Content -LiteralPath $exampleParametersPath -Raw | ConvertFrom-Json
        $articleUrl = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/deploy/session-hosts/ephemeral-os-disks?tabs=portal#dynamic-autoscaling-recommendations'
    }

    It 'shows the Microsoft recommendation in the dynamic autoscaling section' {
        $scalingRecommendation.type | Should Be 'Microsoft.Common.InfoBox'
        $scalingRecommendation.options.text | Should Match 'offers only dynamic create/delete autoscaling'
        $scalingRecommendation.options.text | Should Match 'does not offer a power-management-only scaling plan'
        $scalingRecommendation.options.text | Should Match 'Ramp-up Min % and Ramp-down Min % to 100 in every schedule'
        $scalingRecommendation.options.text | Should Match '100% in every phase'
        $scalingRecommendation.options.text | Should Match 'Autoscaling is optional'
        $scalingRecommendation.options.uri | Should Be $articleUrl
    }

    It 'warns when ephemeral OS disks are selected' {
        $ephemeralWarning.type | Should Be 'Microsoft.Common.InfoBox'
        $ephemeralWarning.visible | Should Be "[steps('hosts').capacity.useEphemeralOsDisk]"
        $ephemeralWarning.options.style | Should Be 'Warning'
        $ephemeralWarning.options.text | Should Match 'Dynamic Create/Delete Autoscaling'
        $ephemeralWarning.options.text | Should Match 'not power-management-only scaling'
        $ephemeralWarning.options.text | Should Match 'Do not attach a separate power-management-only scaling plan'
        $ephemeralWarning.options.text | Should Match 'Autoscaling is optional'
        $ephemeralWarning.options.text | Should Match 'Ramp-up Min % and Ramp-down Min % to 100 for every schedule'
        $ephemeralWarning.options.uri | Should Be $articleUrl
    }

    It 'documents the parameter-file configuration and source recommendation' {
        $readme | Should Match 'Autoscaling is optional'
        $readme | Should Match 'does not offer a power-management-only scaling-plan'
        $readme | Should Match 'Do not attach a separate power-management-only scaling plan'
        $readme | Should Match 'Dynamic Autoscaling recommendations for ephemeral OS disks'
        $readme | Should Match 'rampUpMinimumHostsPct[\s\S]*rampDownMinimumHostsPct'
        $readme | Should Match '100% in every phase'
        $readme | Should Match 'CreateDeletePowerManage[\s\S]*prevents the plan from trying to[\s\S]*deallocate'
        $readme | Should Match ([regex]::Escape($articleUrl))
    }

    It 'translates the Compute resource-disk capability to the AVD TempDisk enum' {
        $placement.label | Should Be 'Ephemeral OS Disk Storage'
        $placement.defaultValue | Should Match "'Temporary Disk', 'OS Cache'"
        $placement.constraints.allowedValues | Should Match '\"label\":\"Temporary Disk\"'
        $placement.constraints.allowedValues | Should Match '\"label\":\"OS Cache\"'
        $placement.constraints.allowedValues | Should Match '\"value\":\"TempDisk\"'
        $placement.constraints.allowedValues | Should Match "equals\(placement.value, 'TempDisk'\)"
        $placement.constraints.allowedValues | Should Match "ephemeralOsDiskPlacements\)\), 'ResourceDisk'\)"
        $formJson | Should Match "equals\(steps\('hosts'\).capacity.ephemeralOsDiskPlacement, 'TempDisk'\), 'ResourceDisk'"
        $formJson | Should Match '"ephemeralOsDiskPlacement"\s*:\s*"\[steps\(''hosts''\)\.capacity\.ephemeralOsDiskPlacement\]"'
    }

    It 'sends only AVD-supported placement values to Session Host Configuration' {
        $bicep | Should Match "param ephemeralOsDiskPlacement string = 'TempDisk'"
        $bicep | Should Match 'placement: any\(ephemeralOsDiskPlacement\)'
        $arm.parameters.ephemeralOsDiskPlacement.allowedValues.Count | Should Be 2
        ($arm.parameters.ephemeralOsDiskPlacement.allowedValues -contains 'CacheDisk') | Should Be $true
        ($arm.parameters.ephemeralOsDiskPlacement.allowedValues -contains 'TempDisk') | Should Be $true
        ($arm.parameters.ephemeralOsDiskPlacement.allowedValues -contains 'ResourceDisk') | Should Be $false
        $exampleParameters.parameters.ephemeralOsDiskPlacement.value | Should Be 'TempDisk'
        $readme | Should Match 'AVD Session Host Configuration API requires `TempDisk`'
        $readme | Should Not Match 'legacy alias'
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$entryTemplatePath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.bicep'
$permissionsPath = Join-Path $repoRoot 'deployments\automatedHostPools\modules\permissions.bicep'
$readmePath = Join-Path $repoRoot 'deployments\automatedHostPools\README.md'

Describe 'Automated host-pool identity permissions' {
    BeforeAll {
        $entryTemplate = Get-Content -LiteralPath $entryTemplatePath -Raw
        $permissions = Get-Content -LiteralPath $permissionsPath -Raw
        $readme = Get-Content -LiteralPath $readmePath -Raw
    }

    It 'assigns subscription roles to the Azure Virtual Desktop principal only when used' {
        $entryTemplate | Should Match "module avdServicePrincipalRbac .* = if \(deployDynamicScalingPlan \|\| startVMOnConnect\)"
        $entryTemplate | Should Match "scalingMethod: deployDynamicScalingPlan \? 'CreateDeletePowerManage' : 'None'"
        $entryTemplate | Should Match 'avdServicePrincipalObjectId: deployDynamicScalingPlan \? avdServicePrincipalObjectId : '
        $readme | Should Match 'Pregranting those subscription roles for an unused future feature would violate least\s+privilege'
    }

    It 'grants selected Disk Encryption Set access to each active VM creation identity' {
        $permissions | Should Match 'principalId: principalId[\s\S]+Session Host Management VM requests'
        $permissions | Should Match '!empty\(avdServicePrincipalObjectId\)[\s\S]+principalId: avdServicePrincipalObjectId[\s\S]+dynamic autoscale VM requests'
        $permissions | Should Match 'roleDefinitionId: readerRoleId'
        $readme | Should Match 'enterprise application additionally when dynamic autoscaling is enabled'
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'
$policyPath = Join-Path $repoRoot 'deployments\automatedHostPools\policy\main.bicep'
$entryTemplatePath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.bicep'
$controlPlanePath = Join-Path $repoRoot 'deployments\automatedHostPools\modules\controlPlane.bicep'
$permissionsPath = Join-Path $repoRoot 'deployments\automatedHostPools\modules\permissions.bicep'
$policyDefinitionPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\sessionHostPolicy\modules\vmApplications.policyDefinition.bicep'

Describe 'Automated host-pool VM Application assignments' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $basicsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'basics' }
        $controlPlaneStep = $form.view.properties.steps | Where-Object { $_.name -eq 'controlPlane' }
        $hostsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'hosts' }
        $sessionHostLocation = $hostsStep.elements | Where-Object { $_.name -eq 'location' }
        $resourceSkusApi = $hostsStep.elements | Where-Object { $_.name -eq 'resourceSkusApi' }
        $availability = $hostsStep.elements | Where-Object { $_.name -eq 'availability' }
        $vmApplications = $hostsStep.elements | Where-Object { $_.name -eq 'vmApplications' }
        $applicationsApi = $vmApplications.elements | Where-Object { $_.name -eq 'applicationsApi' }
        $applicationsGrid = $vmApplications.elements | Where-Object { $_.name -eq 'applications' }
        $policySource = Get-Content -LiteralPath $policyPath -Raw
        $entryTemplateSource = Get-Content -LiteralPath $entryTemplatePath -Raw
        $controlPlaneSource = Get-Content -LiteralPath $controlPlanePath -Raw
        $permissionsSource = Get-Content -LiteralPath $permissionsPath -Raw
        $policyDefinitionSource = Get-Content -LiteralPath $policyDefinitionPath -Raw
    }

    It 'uses one deployment subscription selected on Basics' {
        @($basicsStep.elements | Where-Object { $_.name -eq 'subscription' }).Count | Should Be 1
        @($controlPlaneStep.elements | ForEach-Object { @($_.elements) } | Where-Object { $_.name -eq 'subscription' }).Count | Should Be 0
        (Get-Content -LiteralPath $formPath -Raw) | Should Not Match "steps\('controlPlane'\)\.scope\.subscription"
    }

    It 'uses a top-level Control Plane location as the Session Host default' {
        @($controlPlaneStep.elements | Where-Object { $_.name -eq 'controlPlaneLocation' }).Count | Should Be 1
        @($controlPlaneStep.elements | Where-Object { $_.name -eq 'scope' }).Count | Should Be 0
        $sessionHostLocation.defaultValue | Should Be "[steps('controlPlane').controlPlaneLocation.displayName]"
        (Get-Content -LiteralPath $formPath -Raw) | Should Not Match "steps\('controlPlane'\)\.scope\.controlPlaneLocation"
    }

    It 'excludes subscription-restricted zones from availability choices' {
        $resourceSkusApi.request.transforms.vmSizes | Should Match 'zones:locationInfo\[0\]\.zones'
        $resourceSkusApi.request.transforms.vmSizes | Should Match "restrictedZones:restrictions\[\?type == 'Zone'\]\.restrictionInfo\.zones"
        $availabilityOption = $availability.elements | Where-Object { $_.name -eq 'option' }
        $availabilityZones = $availability.elements | Where-Object { $_.name -eq 'availabilityZones' }
        $availabilityOption.defaultValue | Should Match 'sku\.restrictedZones'
        $availabilityOption.constraints.allowedValues | Should Match 'sku\.restrictedZones'
        $availabilityZones.defaultValue | Should Match 'sku\.restrictedZones'
        $availabilityZones.constraints.allowedValues | Should Match 'sku\.restrictedZones'
    }

    It 'offers latest Gallery application version references from ARM' {
        $applicationsApi.condition | Should Be "[and(equals(steps('hosts').vmApplications.enableVmApplications, true), not(empty(steps('hosts').vmApplications.gallery)))]"
        $applicationsApi.request.method | Should Be 'GET'
        $applicationsApi.request.path | Should Match '/applications\?api-version=2024-03-03'
        $applicationsApi.request.transforms.list | Should Be 'value|[*].{label:name, value:id}'
        $applicationsGrid.constraints.columns[0].element.constraints.allowedValues | Should Match "steps\('hosts'\)\.vmApplications\.applicationsApi\.transformed\.list"
        $applicationsGrid.constraints.columns[0].element.constraints.allowedValues | Should Match '/versions/latest'
        $form.view.outputs.parameters.sessionHostVmApplications | Should Be "[steps('hosts').vmApplications.applications]"
        $form.view.outputs.parameters.sessionHostVmApplications | Should Not Match 'applicationsApi'
    }

    It 'shows a schema-compliant multi-row grid only when VM Applications are selected' {
        $applicationsGrid.visible | Should Be "[equals(steps('hosts').vmApplications.enableVmApplications, true)]"
        $applicationsGrid.constraints.rows.count.min | Should Be 1
        $applicationsGrid.constraints.rows.count.max | Should Be 25
        @($applicationsGrid.constraints.columns[0].element.PSObject.Properties.Name) -notcontains 'multiLine' | Should Be $true
        $applicationsGrid.constraints.columns[1].element.type | Should Be 'Microsoft.Common.DropDown'
        @($applicationsGrid.constraints.columns[1].element.constraints.allowedValues.value) | Should Be (1..25)
        @($applicationsGrid.constraints.columns[2].element.PSObject.Properties.Name) -notcontains 'toolTip' | Should Be $true
        @($applicationsGrid.constraints.columns[2].element.PSObject.Properties.Name) -notcontains 'defaultValue' | Should Be $true
        @($vmApplications.elements | Where-Object { $_.name -eq 'noApplicationsInfo' }).Count | Should Be 0
    }

    It 'preserves the policy assignment object contract' {
        @($applicationsGrid.constraints.columns.id) | Should Be @(
            'packageReferenceId'
            'order'
            'treatFailureAsDeploymentFailure'
        )
    }

    It 'accepts version paths and rejects duplicate application definitions in Bicep' {
        $policySource | Should Match "contains\(toLower\(application.packageReferenceId\), '/versions/'\)"
        $policySource | Should Match "lastIndexOf\(toLower\(application.packageReferenceId\), '/versions/'\)"
        $policySource | Should Match 'cannot contain more than one version of the same application'
    }

    It 'accepts a resolved concrete version only when the assignment selects latest for the same application' {
        $policyDefinitionSource | Should Match "equals: '\[current\(\\'configuredApplication\\'\)\.packageReferenceId\]'"
        $policyDefinitionSource | Should Match "endsWith\(toLower\(current\(\\'configuredApplication\\'\)\.packageReferenceId\), \\'/versions/latest\\'\)"
        $policyDefinitionSource | Should Match "lastIndexOf\(toLower\(current\(\\'configuredApplication\\'\)\.packageReferenceId\), \\'/versions/\\'\)"
        $policyDefinitionSource | Should Match "length\(\\'/versions/\\'\)"
        $policyDefinitionSource | Should Match "like: '\[concat\(substring\(current\(\\'configuredApplication\\'\)\.packageReferenceId, 0, add\("
        $policyDefinitionSource | Should Match "component: 'VM Applications'[\s\S]+version: '1\.0\.1'"
    }

    It 'grants the host-pool identity gallery-scoped Reader access before host creation' {
        $entryTemplateSource | Should Match 'sessionHostVmApplications: sessionHostVmApplications'
        $controlPlaneSource | Should Match 'sessionHostVmApplications: sessionHostVmApplications'
        $permissionsSource | Should Match 'var vmApplicationGalleryResourceIds = union\(map\('
        $permissionsSource | Should Match "lastIndexOf\(toLower\(application.packageReferenceId\), '/applications/'\)"
        $permissionsSource | Should Match "var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'"
        $permissionsSource | Should Match "module vmApplicationGalleryReaderRoles '.+/compute/galleries/roleAssignment.bicep'"
        $permissionsSource | Should Match "galleryName: last\(split\(galleryResourceId, '/'\)\)"
        $controlPlaneSource | Should Match 'module sessionHostConfiguration[\s\S]+dependsOn: \[hostPoolPermissions\]'
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'
$armPath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.json'

Describe 'Automated host-pool VM name prefix validation' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $arm = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json
        $hostsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'hosts' }
        $hostDetails = $hostsStep.elements | Where-Object { $_.name -eq 'hostDetails' }
        $prefix = $hostDetails.elements | Where-Object { $_.name -eq 'virtualMachineNamePrefix' }
    }

    It 'limits direct deployments to 10 characters' {
        $arm.parameters.virtualMachineNamePrefix.maxLength | Should Be 10
        $arm.parameters.virtualMachineNamePrefix.metadata.description | Should Match 'Maximum 10 characters'
    }

    It 'limits Form View input to 10 valid characters' {
        $lengthValidation = $prefix.constraints.validations | Where-Object { $_.isValid }
        $regexValidation = $prefix.constraints.validations | Where-Object { $_.regex }

        $lengthValidation.isValid | Should Be "[lessOrEquals(length(steps('hosts').hostDetails.virtualMachineNamePrefix), 10)]"
        $lengthValidation.message | Should Match 'cannot exceed 10 characters'
        $regexValidation.regex | Should Be '^(?!-)(?!.*-$)(?![0-9]+$)[A-Za-z0-9-]+$'
        $regexValidation.message | Should Match 'do not begin or end with a dash'
        'avdhost' | Should Match $regexValidation.regex
        'avd-host' | Should Match $regexValidation.regex
        'avdhost-' | Should Not Match $regexValidation.regex
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'

Describe 'Automated host-pool workspace selection' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $controlPlaneStep = $form.view.properties.steps | Where-Object { $_.name -eq 'controlPlane' }
        $workspaceSection = $controlPlaneStep.elements | Where-Object { $_.name -eq 'workspace' }
        $workspaceCreateOption = $workspaceSection.elements | Where-Object { $_.name -eq 'createOption' }
        $existingWorkspace = $workspaceSection.elements | Where-Object { $_.name -eq 'existingWorkspace' }
        $existingWorkspaceOutput = $form.view.outputs.parameters.existingFeedWorkspaceResourceId
    }

    It 'offers workspace resource IDs as dropdown values' {
        $existingWorkspace.constraints.allowedValues | Should Match '"value":"'
        $existingWorkspace.constraints.allowedValues | Should Match 'vdws\.id'
    }

    It 'uses the standard host-pool update option contract' {
        $workspaceCreateOption.defaultValue | Should Be 'Update an existing Workspace'
        $workspaceCreateOption.constraints.required | Should Be $true
        ($workspaceCreateOption.constraints.allowedValues | Where-Object { $_.value -eq 'update' }).Count | Should Be 1
        $existingWorkspace.visible | Should Match "workspace\.createOption, 'update'"
    }

    It 'outputs the selected workspace exactly like the standard host-pool form' {
        $existingWorkspace.PSObject.Properties.Name | Should Not Match 'defaultValue'
        $existingWorkspaceOutput | Should Be "[if(equals(steps('controlPlane').workspace.createOption, 'update'), steps('controlPlane').workspace.existingWorkspace, '')]"
        $existingWorkspaceOutput | Should Not Match 'workspacesApi'
    }

    It 'matches the standard host-pool workspace parameter name' {
        ($form.view.outputs.parameters.PSObject.Properties.Name -join ',') | Should Match '(^|,)existingFeedWorkspaceResourceId(,|$)'
    }
}
