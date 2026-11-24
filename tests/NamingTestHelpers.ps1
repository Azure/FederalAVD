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

function Invoke-TestNamingFormExpression {
    param([string]$Expression, [hashtable]$Steps)

    # Evaluate only the scalar form functions used by regressions, not the Portal runtime.
    $functions = @{
        steps = { param($name) $Steps[$name] }.GetNewClosure()
        'if' = { param($condition, $yes, $no) if ($condition) { $yes } else { $no } }
        empty = { param($value) $null -eq $value -or $value.Length -eq 0 }
        equals = { param($left, $right) $left -ceq $right }
        contains = { param($value, $item) if ($value -is [string]) { $value.Contains($item) } else { $value -contains $item } }
        startsWith = { param($value, $prefix) $null -ne $value -and $value.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }
        int = { param($value) [int]$value }
        concat = { [string]::Concat([string[]]$args) }
        coalesce = { foreach ($value in $args) { if ($null -ne $value) { return $value } } }
        parse = { param($value) $value | ConvertFrom-Json -ErrorAction Stop }
        'not' = { param($value) -not $value }
        'or' = { $true -in $args }
        'and' = { $false -notin $args }
    }
    $body = $Expression.Substring(1, $Expression.Length - 2)
    $body = [regex]::Replace($body, "'(?:[^']|'')*'|\b(?:steps|if|empty|equals|contains|startsWith|int|concat|coalesce|parse|not|or|and)\(|(?<!\$)\b(?:true|false)\b", {
        param($match)
        if ($match.Value.StartsWith("'")) { $match.Value }
        elseif ($match.Value -in @('true', 'false')) { '$' + $match.Value }
        else { '$functions.' + $match.Value.TrimEnd('(') + '.InvokeReturnAsIs(' }
    })
    & ([scriptblock]::Create($body))
}

function Invoke-TestNamingVectors {
    param([Parameter(Mandatory)][string]$TemplateFile)

    $command = Get-Command bicep -ErrorAction SilentlyContinue
    $configRoot = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.azure' }
    $binaryName = if ($env:OS -eq 'Windows_NT') { 'bicep.exe' } else { 'bicep' }
    $bicep = if ($command) { $command.Source } else { Join-Path (Join-Path $configRoot 'bin') $binaryName }
    if (-not (Test-Path -LiteralPath $bicep)) { throw 'Bicep CLI is required to evaluate naming vectors.' }
    $directory = Split-Path -Parent $TemplateFile
    [IO.File]::WriteAllText((Join-Path $directory 'bicepconfig.json'), '{"experimentalFeaturesEnabled":{"localDeploy":true}}')
    $parametersPath = Join-Path $directory (([IO.Path]::GetFileNameWithoutExtension($TemplateFile)) + '.bicepparam')
    [IO.File]::WriteAllText($parametersPath, "using './$([IO.Path]::GetFileName($TemplateFile))'")
    $raw = @(& $bicep local-deploy $parametersPath --format Json 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Local naming vectors failed: $($raw -join [Environment]::NewLine)" }
    if (($raw -join [Environment]::NewLine).TrimStart() -notlike '{*') {
        throw "Local naming vectors returned unexpected diagnostics: $($raw -join [Environment]::NewLine)"
    }
    $encoded = ($raw -join [Environment]::NewLine | ConvertFrom-Json).outputs.encodedResults
    $values = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
    $parameters = [pscustomobject]@{}
    foreach ($property in $values.PSObject.Properties) {
        $parameters | Add-Member -NotePropertyName $property.Name -NotePropertyValue ([pscustomobject]@{ value = $property.Value })
    }
    $parameters
}
