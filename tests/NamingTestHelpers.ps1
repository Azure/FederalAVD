function Get-TestNamingPolicy {
    $fixture = Join-Path $PSScriptRoot 'fixtures\naming-defaults.bicepparam'
    $json = & az bicep build-params --file $fixture --stdout
    if ($LASTEXITCODE -ne 0) {
        throw "Naming policy fixture did not compile: $fixture"
    }
    $result = $json | ConvertFrom-Json
    $policy = ($result.parametersJson | ConvertFrom-Json).parameters.policy.value
    if ($null -eq $policy) {
        throw "Compiled naming policy is missing from fixture output: $fixture"
    }
    $policy
}

function Get-TestFormElement {
    param([object[]]$Elements)

    foreach ($element in $Elements) {
        $element
        if ($element.elements) {
            Get-TestFormElement -Elements $element.elements
        }
    }
}
