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
