$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repoRoot 'customer-examples\artifacts\Microsoft-Power-BI-Desktop\Deploy-PowerBIDesktop.ps1'
$originalSystemRoot = $env:SystemRoot
$env:SystemRoot = $env:TEMP
$env:SUPPRESS_FILELOG = '1'
$global:powerBiInstalled = $true
$global:powerBiCalls = @()
$global:powerBiUninstaller = Join-Path $env:TEMP 'Power BI Cache\setup.exe'
try {
    function global:Test-Path {
        param ([string]$LiteralPath, [string]$Path, [string]$PathType)
        $candidate = if ($LiteralPath) { $LiteralPath } else { $Path }
        if ($candidate -like 'Registry::*') { return $global:powerBiInstalled }
        if ($candidate -eq $global:powerBiUninstaller) { return $true }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $candidate
    }
    function global:Get-ChildItem {
        param ([string]$LiteralPath, [string]$ErrorAction)
        if ($LiteralPath -like '*Wow6432Node*') { return }
        [pscustomobject]@{ PSPath = 'Registry::Power-BI-Test' }
    }
    function global:Get-ItemProperty {
        param ([string]$LiteralPath, [string]$ErrorAction)
        [pscustomobject]@{
            DisplayName = 'Microsoft Power BI Desktop (x64)'
            Publisher = 'Microsoft Corporation'
            QuietUninstallString = "`"$global:powerBiUninstaller`" -uninstall -quiet -norestart"
        }
    }
    function global:Start-Process {
        param ([string]$FilePath, [string]$ArgumentList, [switch]$PassThru)
        $global:powerBiCalls += [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList }
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member ScriptMethod WaitForExit { param($TimeoutMs) return $true }
        $process | Add-Member ScriptMethod Kill { }
        return $process
    }
    & $scriptPath -DeploymentType Uninstall
    if ($global:powerBiCalls.Count -ne 1 -or $global:powerBiCalls[0].FilePath -ne $global:powerBiUninstaller -or
        $global:powerBiCalls[0].ArgumentList -ne '-uninstall -quiet -norestart') {
        throw "Unexpected Power BI uninstall invocation: $($global:powerBiCalls | ConvertTo-Json -Compress)"
    }
    $global:powerBiInstalled = $false
    $global:powerBiCalls = @()
    & $scriptPath -DeploymentType Uninstall
    if ($global:powerBiCalls.Count) { throw 'Missing Power BI installation was not treated as success.' }
}
finally {
    Remove-Item function:\Test-Path, function:\Get-ChildItem, function:\Get-ItemProperty, function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Variable powerBiInstalled, powerBiCalls, powerBiUninstaller -Scope Global -ErrorAction SilentlyContinue
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
}
Write-Output 'Deploy-PowerBIDesktop tests passed.'