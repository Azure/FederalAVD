$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'tools\New-TemplateSpecs.ps1'
$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw "New-TemplateSpecs.ps1 has $($parseErrors.Count) PowerShell parse error(s)."
}

$functionDefinitions = $scriptAst.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $true
)
foreach ($functionDefinition in $functionDefinitions) {
    Invoke-Expression $functionDefinition.Extent.Text
}

Describe 'Template Spec naming conventions' {
    It 'uses the CAF-aligned default convention' {
        $name = New-ConventionName `
            -Components @('resourceType', 'workload', 'purpose', 'location') `
            -Delimiter '-' `
            -ResourceTypeCode 'ts' `
            -Purpose 'image-management' `
            -LocationAbbreviation 'use2' `
            -Workload 'avd'

        $name | Should Be 'ts-avd-image-management-use2'
    }

    It 'supports custom ordering, tokens, delimiters, and resource type codes' {
        $name = New-ConventionName `
            -Components @('freeform1', 'workload', 'purpose', 'environment', 'location', 'resourceType') `
            -Delimiter '_' `
            -ResourceTypeCode 'template' `
            -Purpose 'hostpool' `
            -LocationAbbreviation 'vir' `
            -Workload 'desktop' `
            -Environment 'prod' `
            -Freeform1 'contoso'

        $name | Should Be 'contoso_desktop_hostpool_prod_vir_template'
    }

    It 'omits none and empty optional components' {
        $name = New-ConventionName `
            -Components @('resourceType', 'none', 'freeform1', 'purpose', 'location') `
            -Delimiter '-' `
            -ResourceTypeCode 'ts' `
            -Purpose 'networking' `
            -LocationAbbreviation 'usw'

        $name | Should Be 'ts-networking-usw'
    }

    It 'accepts hashtable and PSCustomObject property sources' {
        $hashtableValue = Get-ObjectPropertyValue `
            -InputObject @{ templateSpecs = 'spec' } `
            -PropertyName 'templateSpecs' `
            -DefaultValue 'ts'
        $objectValue = Get-ObjectPropertyValue `
            -InputObject ([pscustomobject]@{ workload = 'desktop' }) `
            -PropertyName 'workload' `
            -DefaultValue 'avd'

        $hashtableValue | Should Be 'spec'
        $objectValue | Should Be 'desktop'
    }

    It 'does not expose the removed legacy naming parameter' {
        $parameterNames = $scriptAst.ParamBlock.Parameters.Name.VariablePath.UserPath

        ($parameterNames -contains 'NamingConvention') | Should Be $true
        ($parameterNames -contains 'nameConvResTypeAtEnd') | Should Be $false
    }

    It 'contains only ASCII characters' {
        (Get-Content -LiteralPath $scriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) |
            Should BeNullOrEmpty
    }
}
