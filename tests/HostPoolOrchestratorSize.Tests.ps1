$repoRoot = Split-Path -Parent $PSScriptRoot
$maximumKnownGoodPayloadBytes = 1243608

$orchestratorCases = @(
    @{
        Name = 'standard host-pool orchestrator'
        TemplatePath = Join-Path $repoRoot 'deployments\hostpools\hostpool.json'
        FormPath = Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json'
    }
    @{
        Name = 'dedicated host-pool PoC orchestrator'
        TemplatePath = Join-Path $repoRoot 'deployments\hostpoolPoc\hostpoolPoc.json'
        FormPath = Join-Path $repoRoot 'deployments\hostpoolPoc\uiFormDefinition.json'
    }
    @{
        Name = 'automated host-pool orchestrator'
        TemplatePath = Join-Path $repoRoot 'deployments\automatedHostPools\automatedHostPool.json'
        FormPath = Join-Path $repoRoot 'deployments\automatedHostPools\uiFormDefinition.json'
    }
)

function Get-DeploymentDepth {
    param(
        [Parameter(Mandatory = $false)]
        $Node,

        [int]
        $Depth = 0
    )

    if ($null -eq $Node) {
        return $Depth
    }

    $maximum = $Depth
    if ($Node -is [System.Collections.IEnumerable] -and
        $Node -isnot [string] -and
        $Node -isnot [pscustomobject]) {
        foreach ($item in $Node) {
            $maximum = [Math]::Max($maximum, (Get-DeploymentDepth -Node $item -Depth $Depth))
        }
        return $maximum
    }

    if ($Node -is [pscustomobject]) {
        $nextDepth = if ($Node.PSObject.Properties['type'] -and
            $Node.type -eq 'Microsoft.Resources/deployments') {
            $Depth + 1
        }
        else {
            $Depth
        }

        $maximum = [Math]::Max($maximum, $nextDepth)
        foreach ($property in $Node.PSObject.Properties) {
            $maximum = [Math]::Max(
                $maximum,
                (Get-DeploymentDepth -Node $property.Value -Depth $nextDepth)
            )
        }
    }

    return $maximum
}

Describe 'Published host-pool orchestrator payload sizes' {
    foreach ($orchestratorCase in $orchestratorCases) {
        It "keeps the $($orchestratorCase.Name) and form below the previous known-good payload" {
            $template = Get-Content -LiteralPath $orchestratorCase.TemplatePath -Raw | ConvertFrom-Json
            $minifiedTemplate = $template | ConvertTo-Json -Depth 100 -Compress
            $form = Get-Content -LiteralPath $orchestratorCase.FormPath -Raw | ConvertFrom-Json
            $minifiedForm = $form | ConvertTo-Json -Depth 100 -Compress
            $payloadSize = [System.Text.Encoding]::UTF8.GetByteCount($minifiedTemplate) +
                [System.Text.Encoding]::UTF8.GetByteCount($minifiedForm)

            $payloadSize | Should BeLessThan $maximumKnownGoodPayloadBytes
        }
    }

    It 'publishes the tracked template and form files' {
        $publisherPath = Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1'
        $publisher = Get-Content -LiteralPath $publisherPath -Raw

        $publisher | Should Match '-TemplateFile \$templateSpec\.TemplateFile'
        $publisher | Should Match '-UiFormDefinitionFile \$templateSpec\.UiFormDefinition'
        $publisher | Should Not Match 'ConvertTo-MinifiedJson'
    }

    foreach ($orchestratorCase in @($orchestratorCases | Where-Object { $_.Name -match 'host-pool' })) {
        It "keeps the $($orchestratorCase.Name) within the ARM nested deployment limit" {
            $template = Get-Content -LiteralPath $orchestratorCase.TemplatePath -Raw | ConvertFrom-Json

            (Get-DeploymentDepth -Node $template) | Should BeLessThan 6
        }
    }
}
