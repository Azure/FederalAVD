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
        $bicep | Should Match "module availabilitySet 'modules/availabilitySet.bicep' = \{"
        $bicep | Should Match 'deploy: deployAvailabilitySet'
        $availabilitySetAdapter | Should Match "module availabilitySet .* = if \(deploy\)"
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
        $bicep | Should Match 'availabilitySetResourceId: availabilitySet.outputs.resourceId'
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
