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
