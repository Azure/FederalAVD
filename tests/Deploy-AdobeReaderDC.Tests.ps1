$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$sourceScriptPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\artifacts\Adobe-Acrobat-Reader-DC\Deploy-AdobeReaderDC.ps1'

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $sourceScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "Deploy-AdobeReaderDC.ps1 has $($parseErrors.Count) PowerShell parse error(s)."
}
if (Get-Content -LiteralPath $sourceScriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) {
    throw 'Deploy-AdobeReaderDC.ps1 contains non-ASCII content.'
}

$tempRoot = Join-Path -Path $env:TEMP -ChildPath "FederalAVD-adobe-test-$([guid]::NewGuid())"
$originalSystemRoot = $env:SystemRoot

try {
    $packagePath = Join-Path -Path $tempRoot -ChildPath 'package'
    New-Item -Path $packagePath -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $sourceScriptPath -Destination (Join-Path $packagePath 'Deploy-AdobeReaderDC.ps1')
    Set-Content -LiteralPath (Join-Path $packagePath 'reader-current.exe') -Value '' -Encoding ASCII

    $env:SystemRoot = $tempRoot
    $env:SUPPRESS_FILELOG = '1'
    $global:adobeProcessCalls = @()
    $global:adobeInstalledApplicationCount = 1

    function global:Test-Path {
        param (
            [string]$LiteralPath,
            [string]$Path,
            [string]$PathType
        )

        $candidatePath = if ($LiteralPath) { $LiteralPath } else { $Path }
        if ($candidatePath -like 'Registry::*') {
            return $global:adobeInstalledApplicationCount -gt 0
        }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $candidatePath
    }

    function global:Get-ChildItem {
        param (
            [string]$LiteralPath,
            [string]$Filter,
            [switch]$File,
            [string]$ErrorAction
        )

        if ($LiteralPath -notlike 'Registry::*') {
            return Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $LiteralPath -Filter $Filter -File
        }
        for ($index = 1; $index -le $global:adobeInstalledApplicationCount; $index++) {
            [pscustomobject]@{
                PSPath = "Registry::Adobe-Acrobat-Test-$index"
                PSChildName = "{AC76BA86-7AD7-1033-7B44-AC0F074E410$($index - 1)}"
            }
        }
    }

    function global:Get-ItemProperty {
        param (
            [string]$LiteralPath,
            [string]$ErrorAction
        )

        return [pscustomobject]@{
            DisplayName = 'Adobe Acrobat (64-bit)'
            Publisher = 'Adobe'
        }
    }

    function global:Get-Process {
        return $null
    }

    function global:Get-Service {
        return $null
    }

    function global:Get-ScheduledTask {
        return $null
    }

    function global:Start-Process {
        param (
            [string]$FilePath,
            [string]$ArgumentList,
            [switch]$PassThru
        )

        $global:adobeProcessCalls += [pscustomobject]@{
            FilePath = $FilePath
            ArgumentList = $ArgumentList
        }
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($TimeoutMs) return $true }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
        return $process
    }

    $deployScriptPath = Join-Path $packagePath 'Deploy-AdobeReaderDC.ps1'
    & $deployScriptPath -DeploymentType Install

    if ($global:adobeProcessCalls.Count -ne 1) {
        throw "Expected one Adobe install process, received $($global:adobeProcessCalls.Count)."
    }
    $installCall = $global:adobeProcessCalls[0]
    if ($installCall.FilePath -ne (Join-Path $packagePath 'reader-current.exe') -or
        $installCall.ArgumentList -notlike '*UPDATE_MODE=0*') {
        throw "Unexpected Adobe install invocation: $($installCall | ConvertTo-Json -Compress)"
    }

    Set-Content -LiteralPath (Join-Path $packagePath 'second-installer.exe') -Value '' -Encoding ASCII
    $global:adobeProcessCalls = @()
    $installerAmbiguityError = $null
    try { & $deployScriptPath -DeploymentType Install } catch { $installerAmbiguityError = $_ }
    if (-not $installerAmbiguityError -or $installerAmbiguityError.Exception.Message -notlike 'Expected one EXE installer*') {
        throw 'Multiple EXE installers did not stop installation with an ambiguity error.'
    }
    if ($global:adobeProcessCalls.Count -ne 0) { throw 'Installation started despite multiple EXE files.' }
    Remove-Item -LiteralPath (Join-Path $packagePath 'second-installer.exe')

    $global:adobeProcessCalls = @()
    & $deployScriptPath -DeploymentType Uninstall
    if ($global:adobeProcessCalls.Count -ne 1) {
        throw "Expected one Adobe uninstall process, received $($global:adobeProcessCalls.Count)."
    }
    $uninstallCall = $global:adobeProcessCalls[0]
    if ($uninstallCall.FilePath -ne 'msiexec.exe' -or
        $uninstallCall.ArgumentList -ne '/x {AC76BA86-7AD7-1033-7B44-AC0F074E4100} /qn /norestart') {
        throw "Unexpected Adobe uninstall invocation: $($uninstallCall | ConvertTo-Json -Compress)"
    }

    $global:adobeInstalledApplicationCount = 0
    $global:adobeProcessCalls = @()
    & $deployScriptPath -DeploymentType Uninstall
    if ($global:adobeProcessCalls.Count -ne 0) {
        throw 'Missing Adobe installation was not treated as an idempotent removal.'
    }

    $global:adobeInstalledApplicationCount = 2
    $ambiguityError = $null
    try {
        & $deployScriptPath -DeploymentType Uninstall
    }
    catch {
        $ambiguityError = $_
    }
    if (-not $ambiguityError -or $ambiguityError.Exception.Message -notlike 'Multiple Adobe Acrobat MSI installations matched:*') {
        throw 'Multiple Adobe MSI registrations did not stop removal with an ambiguity error.'
    }
}
finally {
    Remove-Item function:\Test-Path -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ChildItem -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ItemProperty -ErrorAction SilentlyContinue
    Remove-Item function:\Get-Process -ErrorAction SilentlyContinue
    Remove-Item function:\Get-Service -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ScheduledTask -ErrorAction SilentlyContinue
    Remove-Item function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Variable adobeProcessCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable adobeInstalledApplicationCount -Scope Global -ErrorAction SilentlyContinue
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Deploy-AdobeReaderDC tests passed.'