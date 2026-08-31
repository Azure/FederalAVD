$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$sourceScriptPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\artifacts\Microsoft-AzCLI\Deploy-AzCLI.ps1'

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $sourceScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "Deploy-AzCLI.ps1 has $($parseErrors.Count) PowerShell parse error(s)."
}
if (Get-Content -LiteralPath $sourceScriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) {
    throw 'Deploy-AzCLI.ps1 contains non-ASCII content.'
}

$originalSystemRoot = $env:SystemRoot
$env:SystemRoot = $env:TEMP
$env:SUPPRESS_FILELOG = '1'
$global:azCliProcessCalls = @()
$global:azCliProductCode = '{00000000-0000-0000-0000-000000000002}'
$nativeUninstallPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'

try {
    function global:Test-Path {
        param (
            [string]$LiteralPath,
            [string]$Path,
            [string]$ErrorAction,
            [string]$ErrorVariable
        )

        $candidatePath = if ($LiteralPath) { $LiteralPath } else { $Path }
        return $candidatePath -eq $nativeUninstallPath
    }

    function global:Get-ChildItem {
        param (
            [string]$LiteralPath,
            [string]$ErrorAction,
            [string]$ErrorVariable
        )

        return [pscustomobject]@{
            PSPath = 'Registry::Azure-CLI-Test'
            PSChildName = $global:azCliProductCode
        }
    }

    function global:Get-ItemProperty {
        param (
            [string]$LiteralPath,
            [string]$ErrorAction
        )

        return [pscustomobject]@{
            DisplayName = 'Microsoft Azure CLI'
            DisplayVersion = '2.77.0'
            Publisher = 'Microsoft Corporation'
            PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Test'
            PSChildName = $global:azCliProductCode
            UninstallString = "MsiExec.exe /X$global:azCliProductCode"
            InstallSource = $null
            InstallLocation = $null
            InstallDate = $null
        }
    }

    function global:Start-Process {
        param (
            [string]$FilePath,
            [string]$ArgumentList,
            [switch]$PassThru
        )

        $global:azCliProcessCalls += [pscustomobject]@{
            FilePath = $FilePath
            ArgumentList = $ArgumentList
        }
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($TimeoutMs) return $true }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
        return $process
    }

    . $sourceScriptPath -DeploymentType Uninstall

    if ($global:azCliProcessCalls.Count -ne 1) {
        $detectedApplication = Get-InstalledApplication -Name 'Microsoft Azure CLI'
        throw "Expected one Azure CLI uninstall process, received $($global:azCliProcessCalls.Count). Detected application: $($detectedApplication | ConvertTo-Json -Compress)"
    }
    $uninstallCall = $global:azCliProcessCalls[0]
    if ($uninstallCall.FilePath -ne 'msiexec.exe' -or
        $uninstallCall.ArgumentList -ne "/X $global:azCliProductCode /qn") {
        throw "Unexpected Azure CLI uninstall invocation: $($uninstallCall | ConvertTo-Json -Compress)"
    }
}
finally {
    Remove-Item function:\Test-Path -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ChildItem -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ItemProperty -ErrorAction SilentlyContinue
    Remove-Item function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Variable azCliProcessCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable azCliProductCode -Scope Global -ErrorAction SilentlyContinue
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
}

Write-Output 'Deploy-AzCLI tests passed.'
