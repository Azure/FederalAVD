$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$sourceScriptPath = Join-Path $repoRoot 'customer-examples\artifacts\Google-Chrome-Enterprise\Deploy-GoogleChromeEnterprise.ps1'
$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile($sourceScriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw "Deploy-GoogleChromeEnterprise.ps1 has $($parseErrors.Count) parse error(s)." }
if (Get-Content -LiteralPath $sourceScriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) { throw 'Chrome script contains non-ASCII content.' }

$originalSystemRoot = $env:SystemRoot
$env:SystemRoot = $env:TEMP
$env:SUPPRESS_FILELOG = '1'
$global:chromeInstalled = $true
$global:chromeProcessCalls = @()
$global:chromeProductCode = '{00000000-0000-0000-0000-000000000003}'

try {
    function global:Test-Path {
        param ([string]$LiteralPath, [string]$Path, [string]$PathType)
        $candidatePath = if ($LiteralPath) { $LiteralPath } else { $Path }
        if ($candidatePath -like 'Registry::*') { return $global:chromeInstalled }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $candidatePath
    }
    function global:Get-ChildItem {
        param ([string]$LiteralPath, [string]$ErrorAction)
        if ($LiteralPath -like '*Wow6432Node*') { return }
        [pscustomobject]@{ PSPath = 'Registry::Chrome-Test'; PSChildName = $global:chromeProductCode }
    }
    function global:Get-ItemProperty {
        param ([string]$LiteralPath, [string]$ErrorAction)
        [pscustomobject]@{ DisplayName = 'Google Chrome'; Publisher = 'Google LLC' }
    }
    function global:Get-Process { return $null }
    function global:Start-Process {
        param ([string]$FilePath, [string]$ArgumentList, [switch]$PassThru)
        $global:chromeProcessCalls += [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList }
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member ScriptMethod WaitForExit { param($TimeoutMs) return $true }
        $process | Add-Member ScriptMethod Kill { }
        return $process
    }

    & $sourceScriptPath -DeploymentType Uninstall
    if ($global:chromeProcessCalls.Count -ne 1) { throw "Expected one Chrome uninstall, received $($global:chromeProcessCalls.Count)." }
    $call = $global:chromeProcessCalls[0]
    if ($call.FilePath -ne 'msiexec.exe' -or $call.ArgumentList -ne "/x $global:chromeProductCode /qn /norestart") {
        throw "Unexpected Chrome uninstall invocation: $($call | ConvertTo-Json -Compress)"
    }

    $global:chromeInstalled = $false
    $global:chromeProcessCalls = @()
    & $sourceScriptPath -DeploymentType Uninstall
    if ($global:chromeProcessCalls.Count) { throw 'Missing Chrome installation was not treated as an idempotent removal.' }
}
finally {
    Remove-Item function:\Test-Path, function:\Get-ChildItem, function:\Get-ItemProperty, function:\Get-Process, function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Variable chromeInstalled, chromeProcessCalls, chromeProductCode -Scope Global -ErrorAction SilentlyContinue
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
}

Write-Output 'Deploy-GoogleChromeEnterprise tests passed.'