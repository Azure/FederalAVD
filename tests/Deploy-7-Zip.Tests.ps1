$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$sourceScriptPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\artifacts\7-Zip\Deploy-7-Zip.ps1'

$tokens = $null
$parseErrors = $null
$scriptAst = [Management.Automation.Language.Parser]::ParseFile(
    $sourceScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Deploy-7-Zip.ps1 has $($parseErrors.Count) PowerShell parse error(s)."
}
if (Get-Content -LiteralPath $sourceScriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) {
    throw 'Deploy-7-Zip.ps1 contains non-ASCII content.'
}

$deploymentType = $scriptAst.ParamBlock.Parameters | Where-Object {
    $_.Name.VariablePath.UserPath -eq 'DeploymentType'
}
$allowedDeploymentTypes = @(
    $deploymentType.Attributes |
        Where-Object { $_.TypeName.FullName -eq 'ValidateSet' } |
        ForEach-Object { $_.PositionalArguments.SafeGetValue() }
)
if (($allowedDeploymentTypes -join ',') -ne 'Install,Uninstall') {
    throw "Unexpected DeploymentType values: $($allowedDeploymentTypes -join ',')"
}

$scriptText = Get-Content -LiteralPath $sourceScriptPath -Raw
if ($scriptText -notmatch "PSChildName -match '\^\\\{\[0-9A-Fa-f-\]\{36\}\\\}\$'") {
    throw 'MSI uninstall does not require a GUID ProductCode registry subkey.'
}
if (-not $scriptText.Contains("Start-Process -FilePath 'msiexec.exe'") -or
    -not $scriptText.Contains('-ArgumentList "/x $($installedApplication.ProductCode)')) {
    throw 'MSI uninstall does not invoke msiexec.exe with /x.'
}

$tempRoot = Join-Path -Path $env:TEMP -ChildPath "FederalAVD-7zip-test-$([guid]::NewGuid())"
$originalSystemRoot = $env:SystemRoot

try {
    $packagePath = Join-Path -Path $tempRoot -ChildPath 'package'
    New-Item -Path $packagePath -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $sourceScriptPath -Destination (Join-Path $packagePath 'Deploy-7-Zip.ps1')
    Set-Content -LiteralPath (Join-Path $packagePath '7z-installer.msi') -Value '' -Encoding ASCII

    $env:SystemRoot = $tempRoot
    $env:SUPPRESS_FILELOG = '1'
    $global:sevenZipProcessCalls = @()
    $global:sevenZipProductCode = '{00000000-0000-0000-0000-000000000001}'
    $global:sevenZipInstalled = $true

    function global:Start-Process {
        param (
            [string]$FilePath,
            [string]$ArgumentList,
            [switch]$PassThru
        )

        $global:sevenZipProcessCalls += [pscustomobject]@{
            FilePath = $FilePath
            ArgumentList = $ArgumentList
        }
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($TimeoutMs) return $true }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
        return $process
    }

    function global:Test-Path {
        param (
            [string]$LiteralPath,
            [string]$Path,
            [string]$PathType
        )

        $candidatePath = if ($LiteralPath) { $LiteralPath } else { $Path }
        if ($candidatePath -like 'Registry::*') { return $global:sevenZipInstalled }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $candidatePath
    }

    function global:Get-ChildItem {
        param (
            [string]$LiteralPath,
            [string]$Path,
            [string]$Filter,
            [switch]$File,
            [string]$ErrorAction
        )

        if ($LiteralPath -like 'Registry::*') {
            return [pscustomobject]@{
                PSPath = 'Registry::7-Zip-Test'
                PSChildName = $global:sevenZipProductCode
            }
        }

        $candidatePath = if ($LiteralPath) { $LiteralPath } else { $Path }
        Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $candidatePath -Filter $Filter -File:$File
    }

    function global:Get-ItemProperty {
        param (
            [string]$LiteralPath,
            [string]$ErrorAction
        )

        return [pscustomobject]@{ DisplayName = '7-Zip 26.00 (x64 edition)' }
    }

    function global:Get-Process {
        return $null
    }

    $deployScriptPath = Join-Path $packagePath 'Deploy-7-Zip.ps1'
    & $deployScriptPath -DeploymentType Install
    if ($global:sevenZipProcessCalls.Count -ne 1 -or
        $global:sevenZipProcessCalls[0].ArgumentList -notlike "*/i *7z-installer.msi*") {
        throw 'A single renamed MSI was not selected for installation.'
    }

    Set-Content -LiteralPath (Join-Path $packagePath 'second-installer.msi') -Value '' -Encoding ASCII
    $global:sevenZipProcessCalls = @()
    $ambiguityError = $null
    try { & $deployScriptPath -DeploymentType Install } catch { $ambiguityError = $_ }
    if (-not $ambiguityError -or $ambiguityError.Exception.Message -notlike 'Expected one MSI installer*') {
        throw 'Multiple MSI installers did not stop installation with an ambiguity error.'
    }
    if ($global:sevenZipProcessCalls.Count -ne 0) { throw 'Installation started despite multiple MSI files.' }
    Remove-Item -LiteralPath (Join-Path $packagePath 'second-installer.msi')

    $global:sevenZipProcessCalls = @()
    & $deployScriptPath -DeploymentType Uninstall

    if ($global:sevenZipProcessCalls.Count -ne 1) {
        throw "Expected one MSI uninstall process, received $($global:sevenZipProcessCalls.Count)."
    }
    $msiUninstallCall = $global:sevenZipProcessCalls[0]
    if ($msiUninstallCall.FilePath -ne 'msiexec.exe' -or
        $msiUninstallCall.ArgumentList -ne "/x $global:sevenZipProductCode /quiet /qn /norestart") {
        throw "Unexpected MSI uninstall invocation: $($msiUninstallCall | ConvertTo-Json -Compress)"
    }

    $global:sevenZipInstalled = $false
    $global:sevenZipProcessCalls = @()
    & $deployScriptPath -DeploymentType Uninstall
    if ($global:sevenZipProcessCalls.Count -ne 0) {
        throw 'Missing MSI installation was not treated as an idempotent removal.'
    }
}
finally {
    Remove-Item function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Item function:\Test-Path -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ChildItem -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ItemProperty -ErrorAction SilentlyContinue
    Remove-Item function:\Get-Process -ErrorAction SilentlyContinue
    Remove-Variable sevenZipProcessCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable sevenZipProductCode -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable sevenZipInstalled -Scope Global -ErrorAction SilentlyContinue
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Deploy-7-Zip tests passed.'
