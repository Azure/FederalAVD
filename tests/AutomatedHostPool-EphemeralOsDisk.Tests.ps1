$repoRoot = Split-Path -Parent $PSScriptRoot
$formPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'
$readmePath = Join-Path $repoRoot 'deployments\automatedHostPools\README.md'

Describe 'Automated host-pool ephemeral OS disk guidance' {
    BeforeAll {
        $form = Get-Content -LiteralPath $formPath -Raw | ConvertFrom-Json
        $controlPlaneStep = $form.view.properties.steps | Where-Object { $_.name -eq 'controlPlane' }
        $hostsStep = $form.view.properties.steps | Where-Object { $_.name -eq 'hosts' }
        $dynamicScaling = $controlPlaneStep.elements | Where-Object { $_.name -eq 'dynamicScaling' }
        $capacity = $hostsStep.elements | Where-Object { $_.name -eq 'capacity' }
        $scalingRecommendation = $dynamicScaling.elements | Where-Object { $_.name -eq 'ephemeralOsDiskRecommendation' }
        $ephemeralWarning = $capacity.elements | Where-Object { $_.name -eq 'ephemeralOsDiskAutoscalingWarning' }
        $readme = Get-Content -LiteralPath $readmePath -Raw
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
}