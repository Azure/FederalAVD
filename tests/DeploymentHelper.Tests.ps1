$repoRoot = Split-Path -Parent $PSScriptRoot
$helperPath = Join-Path $repoRoot 'deployments\shared\modules\orchestration\deploymentHelper\deploy.bicep'
$entryPointPaths = @(
    'deployments\hostpools\hostpool.json'
    'deployments\automatedHostPools\automatedHostPool.json'
    'deployments\add-ons\fslogixStorage\main.json'
)

Describe 'Deployment helper OS disk SKU' {
    BeforeAll {
        $helper = Get-Content -LiteralPath $helperPath -Raw
    }

    It 'uses a fixed Standard SSD independent of workload disk settings' {
        $helper | Should Match "osDiskSku: 'StandardSSD_LRS'"
        $helper | Should Not Match '(?m)^param diskSku string\s*$'
    }

    foreach ($relativePath in $entryPointPaths) {
        It "embeds the fixed helper SKU in $relativePath" {
            $arm = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw
            $arm | Should Match '"osDiskSku"\s*:\s*\{\s*"value"\s*:\s*"StandardSSD_LRS"'
        }
    }
}
