$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptPath = Join-Path -Path $repoRoot -ChildPath 'deployments\shared\scripts\Initialize-SessionHost.ps1'
$scriptContent = Get-Content -LiteralPath $scriptPath -Raw

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Initialize-SessionHost.ps1 has $($parseErrors.Count) PowerShell parse error(s)."
}
if (Get-Content -LiteralPath $scriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) {
    throw 'Initialize-SessionHost.ps1 contains non-ASCII content.'
}

$downloadFunction = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-InstallerFromUrl'
    }, $true)
if (-not $downloadFunction) {
    throw 'Get-InstallerFromUrl was not found.'
}

$downloadFunctionText = $downloadFunction.Extent.Text
if ($downloadFunctionText -notmatch '\[int\]\$MaxAttempts\s*=\s*3') {
    throw 'Installer downloads do not default to three attempts.'
}
if ($downloadFunctionText -notmatch '\[int\]\$TimeoutSeconds\s*=\s*120') {
    throw 'Installer downloads do not have the expected bounded timeout.'
}
if ($downloadFunctionText -notmatch 'Invoke-WebRequest[\s\S]*-TimeoutSec\s+\$TimeoutSeconds') {
    throw 'Installer downloads do not apply the bounded timeout.'
}
if ($downloadFunctionText -notmatch 'For\s*\(\$Attempt\s*=\s*1;\s*\$Attempt\s*-le\s*\$MaxAttempts') {
    throw 'Installer downloads do not retry up to MaxAttempts.'
}
if ($downloadFunctionText -notmatch 'Remove-Item\s+-Path\s+\$DestinationPath') {
    throw 'Installer downloads do not remove partial files after failed attempts.'
}
if ($downloadFunctionText -notmatch 'Start-Sleep\s+-Seconds\s+\$RetryDelaySeconds') {
    throw 'Installer downloads do not delay between attempts.'
}

if ($scriptContent -notmatch 'Write-Error\s+-Message\s+"Initialization failed:') {
    throw 'Initialization failures are not surfaced in Run Command output.'
}

Write-Output 'Initialize-SessionHost validation tests passed.'