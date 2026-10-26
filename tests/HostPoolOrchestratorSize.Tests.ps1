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
            $package = New-DeduplicatedTemplateSpecPackage -TemplateFile $orchestratorCase.TemplatePath -FormFile $orchestratorCase.FormPath -Location 'usgovvirginia'
            $payloadSize = $package.PayloadBytes

            ($payloadSize + 16384) | Should BeLessThan 2000000
            if ($orchestratorCase.Name -eq 'standard host-pool orchestrator') {
                $payloadSize | Should BeLessThan 1820000
            }
        }

    }

    It 'publishes complete deduplicated requests using the cloud-aware REST API' {
        $publisherPath = Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1'
        $publisher = Get-Content -LiteralPath $publisherPath -Raw

        $publisher | Should Match 'Publish-DeduplicatedTemplateSpec -ResourceId'
        $publisher | Should Match '-VersionPayload \$templateSpec\.PublicationPayload'
        $publisher | Should Match 'Invoke-AzRestMethod -Path'
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
        $node.Body.Extent.Text.Contains('$budgetedBytes = $package.PayloadBytes + 16384')
    }, $true)
    $body = $preflight.Body.Extent.Text
    $start = $body.IndexOf('$budgetedBytes =')
    $end = $body.IndexOf('$templateSpecWorkload =')
    $sizeCheck = [scriptblock]::Create($body.Substring($start, $end - $start))

    It 'separates measured bytes, the reserved margin, and remaining headroom for <Bytes> bytes' -TestCases @(
        @{ Bytes = 0 }
        @{ Bytes = 1895575 }
        @{ Bytes = 1983616 }
    ) {
        param($Bytes)

        $package = @{ PayloadBytes = $Bytes; OriginalPayloadBytes = $Bytes; Artifacts = @() }
        $templateSpec = @{ DisplayName = 'Test template' }
        $messages = @(& $sizeCheck)
        $messages.Count | Should Be 5
        $messages[0] | Should Be 'Test template experimental publication size check:'
        $messages[1] | Should Be ("  Before deduplication: {0:N0} bytes; after: {0:N0} bytes; saved: 0 bytes." -f $Bytes)
        $messages[2] | Should Be '  Packaged linked artifacts: 0; the measured request includes every artifact and the Portal form.'
        $messages[3] | Should Be '  Reserved safety margin: 16,384 bytes (16 KiB; not appended to the template).'
        $messages[4] | Should Be ("  Total checked: {0:N0} / 2,000,000 bytes; remaining headroom: {1:N0} bytes." -f ($Bytes + 16384), (2000000 - $Bytes - 16384))
    }

    It 'rejects content one byte over budget and explains the excess' {
        $package = @{ PayloadBytes = 1983617; OriginalPayloadBytes = 1983617; Artifacts = @() }
        $templateSpec = @{ DisplayName = 'Test template' }
        { & $sizeCheck } | Should Throw 'exceeding'
        { & $sizeCheck } | Should Throw 'Nothing has been published'
    }
}
