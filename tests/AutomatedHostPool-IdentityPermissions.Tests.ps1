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