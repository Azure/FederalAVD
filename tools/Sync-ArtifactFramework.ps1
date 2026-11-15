[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)][string[]]$ArtifactPath
)

$ErrorActionPreference = 'Stop'
$frameworkPath = Join-Path $PSScriptRoot 'ArtifactFramework.ps1'
$frameworkAst = [Management.Automation.Language.Parser]::ParseFile($frameworkPath, [ref]$null, [ref]$null)
$helpers = @{}
foreach ($definition in $frameworkAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    $helpers[$definition.Name] = $definition.Extent.Text
}
$aliases = @{
    'Remove-MsiApplication' = 'Remove-MsiApplications'
    'Get-InstalledApplication' = 'Get-InstalledApplications'
    'Invoke-Process' = 'Invoke-ApplicationProcess'
}

foreach ($directory in $ArtifactPath) {
    $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.ps1' -File -ErrorAction Stop)
    if ($files.Count -ne 1) { throw "Expected one root entry script in '$directory'; found $($files.Count)." }
    $path = $files[0].FullName
    $text = [IO.File]::ReadAllText($path)
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $definitions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false))
    if ($definitions.Count -eq 0) { throw "No helper section found in '$path'." }
    $edits = [Collections.Generic.List[object]]::new()
    $present = @{}
    foreach ($definition in $definitions) {
        $name = $definition.Name
        if ($aliases.ContainsKey($name)) { $name = $aliases[$name] }
        if ($helpers.ContainsKey($name)) {
            if ($present.ContainsKey($name)) { throw "Duplicate framework helper '$name' in '$path'." }
            $present[$name] = $true
            $edits.Add(@{ Start = $definition.Extent.StartOffset; Length = $definition.Extent.EndOffset - $definition.Extent.StartOffset; Text = $helpers[$name] })
        }
    }
    $needed = @{ 'Write-Log' = $true; 'New-Log' = $true }
    foreach ($command in $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst]
    }, $true)) {
        $name = $command.GetCommandName()
        if (-not $name) { continue }
        $parent = $command.Parent
        while ($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
        if ($parent -and ($helpers.ContainsKey($parent.Name) -or $aliases.ContainsKey($parent.Name))) { continue }
        if ($aliases.ContainsKey($name)) {
            $replacement = $aliases[$name]
            $element = $command.CommandElements[0].Extent
            $edits.Add(@{ Start = $element.StartOffset; Length = $element.EndOffset - $element.StartOffset; Text = $replacement })
            $name = $replacement
        }
        if ($helpers.ContainsKey($name)) { $needed[$name] = $true }
        if ($name -eq 'New-Log') {
            $parameters = @($command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })
            if ('FilePath' -notin $parameters.ParameterName -and 'Name' -notin $parameters.ParameterName) {
                $suffix = " -Name '$($files[0].BaseName)'"
                if ($command.CommandElements.Count -eq 1) {
                    $suffix = " -Path (Join-Path `$env:SystemRoot 'Logs\Software')" + $suffix
                }
                $edits.Add(@{ Start = $command.Extent.EndOffset; Length = 0; Text = $suffix })
            }
        }
    }
    if ($present.ContainsKey('Invoke-MsiProcess') -or $needed.ContainsKey('Invoke-MsiProcess')) {
        $needed['Invoke-ApplicationProcess'] = $true
    }
    if ($present.ContainsKey('Remove-MsiApplications') -or $needed.ContainsKey('Remove-MsiApplications')) {
        $needed['Invoke-MsiProcess'] = $true
        $needed['Invoke-ApplicationProcess'] = $true
    }
    $missing = @($needed.Keys | Where-Object { -not $present.ContainsKey($_) } | Sort-Object)
    if ($missing.Count) {
        $addition = ($missing | ForEach-Object { $helpers[$_] }) -join "`n`n"
        $edits.Add(@{ Start = $definitions[0].Extent.StartOffset; Length = 0; Text = $addition + "`n`n" })
    }
    foreach ($edit in $edits | Sort-Object @{ Expression = 'Start'; Descending = $true }, @{ Expression = 'Length'; Descending = $true }) {
        $text = $text.Remove($edit.Start, $edit.Length).Insert($edit.Start, $edit.Text)
    }
    [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors) | Out-Null
    if ($errors.Count -or $text -match '[^\x00-\x7E]') { throw "Invalid synchronized script: '$path'." }
    $bytes = [IO.File]::ReadAllBytes($path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($bom))
    if (Get-Content -LiteralPath $path | Where-Object { $_ -match '[^\x00-\x7E]' }) { throw "Non-ASCII script: '$path'." }
    Write-Output "Framework synchronized: $path"
}
