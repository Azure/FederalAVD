$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module Az.Resources -ErrorAction Stop
$publisherPath = Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1'
$parseErrors = $null
$publisherAst = [System.Management.Automation.Language.Parser]::ParseFile($publisherPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "New-TemplateSpecs.ps1 has $($parseErrors.Count) PowerShell parse error(s)."
}
foreach ($function in $publisherAst.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true
)) {
    Invoke-Expression $function.Extent.Text
}

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
        It "keeps the $($orchestratorCase.Name) and form within the native SDK publication budget" {
            $package = New-TemplateSpecPublicationPackage -TemplateFile $orchestratorCase.TemplatePath -FormFile $orchestratorCase.FormPath
            $payloadSize = Get-TemplateSpecPublicationSize -Package $package -Location 'usgovvirginia'

            ($payloadSize + 16384) | Should BeLessThan 2000000
        }
    }

    It 'publishes staged annotation-filtered files using the normal cmdlet' {
        $publisherPath = Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1'
        $publisher = Get-Content -LiteralPath $publisherPath -Raw

        $publisher | Should Match '-TemplateFile \$templateSpec\.PublicationTemplateFile'
        $publisher | Should Match '-UiFormDefinitionFile \$templateSpec\.PublicationFormFile'
        $publisher | Should Match 'TemplateSpecPackagingEngine\]::Unpack'
        $publisher | Should Not Match 'ConvertTo-MinifiedJson'
        $publisher | Should Not Match 'SerializationSettings\.Formatting\s*='
    }

    foreach ($orchestratorCase in @($orchestratorCases | Where-Object { $_.Name -match 'host-pool' })) {
        It "keeps the $($orchestratorCase.Name) within the ARM nested deployment limit" {
            $template = Get-Content -LiteralPath $orchestratorCase.TemplatePath -Raw | ConvertFrom-Json

            (Get-DeploymentDepth -Node $template) | Should BeLessThan 6
        }
    }
}
