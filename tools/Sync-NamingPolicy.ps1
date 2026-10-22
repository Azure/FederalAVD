[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$dataPath = Join-Path $repoRoot 'deployments\shared\data'
$policy = Get-Content -LiteralPath (Join-Path $dataPath 'namingPolicy.json') -Raw | ConvertFrom-Json
$abbreviations = Get-Content -LiteralPath (Join-Path $dataPath 'resourceAbbreviations.json') -Raw | ConvertFrom-Json
if ($policy.defaults.components.Count -gt 6) {
    throw 'Portal naming controls support at most six default components. Update the forms before publishing this policy.'
}
$purposePatterns = [ordered]@{}
foreach ($role in $policy.resources.PSObject.Properties) {
    $purposePatterns[$role.Name] = $role.Value.purpose -join '{delimiter}'
}
$portalPolicy = [ordered]@{
    defaults = $policy.defaults
    identifiers = $policy.identifiers
    limits = $policy.limits
    patterns = $policy.patterns
    resourceTypeCodes = $abbreviations
    purposePatterns = $purposePatterns
}
$payload = ConvertTo-Json -InputObject $portalPolicy -Depth 100 -Compress
$stale = @()

function ConvertTo-BicepLiteral {
    param($Value, [int]$Indent = 0, [string]$NewLine = "`n")

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) {
        $escaped = $Value.Replace('\', '\\').Replace("'", "\'").Replace('${', '\${').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
        return "'$escaped'"
    }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [array]) {
        $items = @($Value | ForEach-Object { ConvertTo-BicepLiteral -Value $_ -Indent $Indent -NewLine $NewLine })
        return '[' + ($items -join ', ') + ']'
    }
    if ($Value -is [pscustomobject]) {
        $properties = foreach ($property in $Value.PSObject.Properties) {
            $key = if ($property.Name -match '^[A-Za-z_][A-Za-z0-9_]*$') { $property.Name } else { ConvertTo-BicepLiteral -Value $property.Name }
            (' ' * ($Indent + 2)) + $key + ': ' + (ConvertTo-BicepLiteral -Value $property.Value -Indent ($Indent + 2) -NewLine $NewLine)
        }
        return '{' + $NewLine + ($properties -join $NewLine) + $NewLine + (' ' * $Indent) + '}'
    }
    return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

$defaultPattern = '(?m)^(?<marker>// naming-policy: (?<path>[A-Za-z0-9_.]+)\r?\n)(?<declaration>param \w+ (?:object|string) = )(?<value>\{\r?\n[\s\S]*?^\}|[^\r\n]+)'
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deployments') -Filter '*.bicep' -Recurse) {
    $before = Get-Content -LiteralPath $file.FullName -Raw
    if (-not $before.Contains('// naming-policy: ')) { continue }
    $newLine = if ($before.Contains("`r`n")) { "`r`n" } else { "`n" }
    $after = [regex]::Replace($before, $defaultPattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($Match)
        $value = $policy
        foreach ($segment in $Match.Groups['path'].Value.Split('.')) {
            $property = $value.PSObject.Properties[$segment]
            if ($null -eq $property) { throw "Unknown generated naming default: $($Match.Groups['path'].Value)" }
            $value = $property.Value
        }
        $Match.Groups['marker'].Value + $Match.Groups['declaration'].Value + (ConvertTo-BicepLiteral -Value $value -NewLine $newLine)
    })
    if ($before -cne $after) {
        if ($Check) { $stale += $file.FullName }
        else {
            [System.IO.File]::WriteAllText($file.FullName, $after, [System.Text.UTF8Encoding]::new($false))
            Write-Output "Updated naming defaults: $($file.FullName)"
        }
    }
}

function Update-PortalNamingDefaults {
    param($Node)

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        if ($Node.type -eq 'Microsoft.Common.DropDown' -and ($Node.name -match '^component([1-6])$' -or $Node.name -eq 'delimiter')) {
            $value = if ($Node.name -eq 'delimiter') {
                $policy.defaults.delimiter
            }
            else {
                $index = [int]$Node.name.Substring(9) - 1
                if ($index -lt $policy.defaults.components.Count) { $policy.defaults.components[$index] } else { 'none' }
            }
            $selection = @($Node.constraints.allowedValues | Where-Object { $_.value -ceq $value })
            if ($selection.Count -ne 1) {
                throw "The $($Node.name) dropdown cannot represent naming default '$value'."
            }
            $Node.defaultValue = $selection[0].label
        }
        elseif ($Node.type -eq 'Microsoft.Common.TextBox' -and $Node.name -eq 'workloadValue') {
            $Node.defaultValue = $policy.defaults.workload
        }
        elseif ($Node.type -eq 'Microsoft.Common.TextBox' -and $Node.name -eq 'delimiter') {
            $Node.defaultValue = $policy.defaults.delimiter
        }
        foreach ($property in @($Node.PSObject.Properties)) {
            Update-PortalNamingDefaults -Node $property.Value
        }
    }
    elseif ($Node -is [array]) {
        foreach ($item in $Node) {
            Update-PortalNamingDefaults -Node $item
        }
    }
}

$forms = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deployments') -Filter 'uiFormDefinition.json' -Recurse
foreach ($file in $forms) {
    $original = Get-Content -LiteralPath $file.FullName -Raw
    $form = $original | ConvertFrom-Json
    $control = @($form.view.properties.steps[0].elements | Where-Object { $_.name -eq 'federalAvdNamingPolicy' })
    if ($control.Count -eq 0) {
        if (@($form.view.outputs.parameters.PSObject.Properties.Name) -contains 'namingConvention') {
            throw "Naming form has no generated policy binding: $($file.FullName)"
        }
        continue
    }
    if ($control.Count -ne 1 -or $control[0].type -ne 'Microsoft.Common.TextBox' -or $control[0].visible -ne $false) {
        throw "Invalid generated naming policy control: $($file.FullName)"
    }
    $before = ConvertTo-Json -InputObject $form -Depth 100
    $step = $form.view.properties.steps[0]
    $step.elements = @($step.elements | Where-Object { $_.name -ne 'federalAvdNamingPolicy' }) + @($control)
    $control[0].defaultValue = $payload
    Update-PortalNamingDefaults -Node $form
    $after = ConvertTo-Json -InputObject $form -Depth 100
    if ($before -cne $after) {
        if ($Check) {
            $stale += $file.FullName
        }
        else {
            [System.IO.File]::WriteAllText($file.FullName, $after + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
            Write-Output "Updated naming policy: $($file.FullName)"
        }
    }
}

if ($stale.Count -gt 0) {
    throw "Generated naming policy is stale. Run tools\Sync-NamingPolicy.ps1 and commit the generated defaults/forms: $($stale -join ', ')"
}
