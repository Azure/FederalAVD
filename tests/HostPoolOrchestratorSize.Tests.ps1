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
            if ($orchestratorCase.Name -eq 'standard host-pool orchestrator') {
                $payloadSize | Should BeLessThan 1820000
            }
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

Describe 'Template Spec publication size messages' {
    $preflight = $publisherAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $node.Body.Extent.Text.Contains('$payloadBytes = Get-TemplateSpecPublicationSize')
    }, $true)
    $body = $preflight.Body.Extent.Text
    $start = $body.IndexOf('$metadataAllowanceBytes =')
    $end = $body.IndexOf('$targetDirectory =')
    $sizeCheck = [scriptblock]::Create($body.Substring($start, $end - $start))

    It 'separates measured bytes, the reserved margin, and remaining headroom for <Bytes> bytes' -TestCases @(
        @{ Bytes = 0 }
        @{ Bytes = 1895575 }
        @{ Bytes = 1983616 }
    ) {
        param($Bytes)

        $payloadBytes = $Bytes
        $templateSpec = @{ DisplayName = 'Test template' }
        $messages = @(& $sizeCheck)
        $messages.Count | Should Be 4
        $messages[0] | Should Be 'Test template publication size check:'
        $messages[1] | Should Be ("  Measured request: {0:N0} bytes (template, Portal form, linked templates, and request envelope)." -f $Bytes)
        $messages[2] | Should Be ("  Reserved safety margin: {0:N0} bytes (16 KiB for additional publishing metadata; not added to the template)." -f 16384)
        $messages[3] | Should Be ("  Total checked: {0:N0} / {1:N0} bytes; remaining headroom: {2:N0} bytes." -f ($Bytes + 16384), 2000000, (2000000 - $Bytes - 16384))
    }

    It 'rejects content one byte over budget and explains the excess' {
        $payloadBytes = 1983617
        $templateSpec = @{ DisplayName = 'Test template' }
        { & $sizeCheck } | Should Throw 'exceeding'
        { & $sizeCheck } | Should Throw 'by 1 bytes'
    }
}
