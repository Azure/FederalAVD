$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$originalSystemRoot = $env:SystemRoot
$env:SystemRoot = $env:TEMP
$env:SUPPRESS_FILELOG = '1'

function Test-MsiApplicationRemoval {
    param (
        [string]$ScriptPath,
        [string]$DisplayName,
        [string]$Publisher,
        [string]$ProductCode
    )

    $global:msiTestInstalled = $true
    $global:msiTestDisplayName = $DisplayName
    $global:msiTestPublisher = $Publisher
    $global:msiTestProductCode = $ProductCode
    $global:msiTestProcessCalls = @()
    try {
        function global:Test-Path {
            param ([string]$LiteralPath, [string]$Path, [string]$PathType)
            $candidatePath = if ($LiteralPath) { $LiteralPath } else { $Path }
            if ($candidatePath -like 'Registry::*') { return $global:msiTestInstalled }
            return Microsoft.PowerShell.Management\Test-Path -LiteralPath $candidatePath
        }
        function global:Get-ChildItem {
            param ([string]$LiteralPath, [string]$ErrorAction)
            if ($LiteralPath -like '*Wow6432Node*') { return }
            [pscustomobject]@{ PSPath = 'Registry::Msi-App-Test'; PSChildName = $global:msiTestProductCode }
        }
        function global:Get-ItemProperty {
            param ([string]$LiteralPath, [string]$ErrorAction)
            [pscustomobject]@{ DisplayName = $global:msiTestDisplayName; Publisher = $global:msiTestPublisher }
        }
        function global:Get-Process { return $null }
        function global:Start-Process {
            param ([string]$FilePath, [string]$ArgumentList, [switch]$PassThru)
            $global:msiTestProcessCalls += [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList }
            $process = [pscustomobject]@{ ExitCode = 0 }
            $process | Add-Member ScriptMethod WaitForExit { param($TimeoutMs) return $true }
            $process | Add-Member ScriptMethod Kill { }
            return $process
        }

        & $ScriptPath -DeploymentType Uninstall
        if ($global:msiTestProcessCalls.Count -ne 1) { throw "Expected one uninstall for $DisplayName." }
        $call = $global:msiTestProcessCalls[0]
        if ($call.FilePath -ne 'msiexec.exe' -or $call.ArgumentList -ne "/x $ProductCode /qn /norestart") {
            throw "Unexpected uninstall for $DisplayName`: $($call | ConvertTo-Json -Compress)"
        }

        $global:msiTestInstalled = $false
        $global:msiTestProcessCalls = @()
        & $ScriptPath -DeploymentType Uninstall
        if ($global:msiTestProcessCalls.Count) { throw "$DisplayName removal was not idempotent." }
    }
    finally {
        Remove-Item function:\Test-Path, function:\Get-ChildItem, function:\Get-ItemProperty, function:\Get-Process, function:\Start-Process -ErrorAction SilentlyContinue
        Remove-Variable msiTestInstalled, msiTestDisplayName, msiTestPublisher, msiTestProductCode, msiTestProcessCalls -Scope Global -ErrorAction SilentlyContinue
    }
}

try {
    Test-MsiApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\PuTTY\Deploy-PuTTY.ps1') `
        -DisplayName 'PuTTY release 0.83 (64-bit)' `
        -Publisher 'Simon Tatham' `
        -ProductCode '{00000000-0000-0000-0000-000000000004}'
    Test-MsiApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\Microsoft-PowerShell-7\Deploy-PowerShell7.ps1') `
        -DisplayName 'PowerShell 7-x64' `
        -Publisher 'Microsoft Corporation' `
        -ProductCode '{00000000-0000-0000-0000-000000000005}'
    Test-MsiApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\Amazon-Workspaces-Client\Deploy-AmazonWorkspacesClient.ps1') `
        -DisplayName 'Amazon WorkSpaces' `
        -Publisher 'Amazon Web Services, Inc' `
        -ProductCode '{00000000-0000-0000-0000-000000000006}'
    Test-MsiApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\Microsoft-Edge-Enterprise\Deploy-MicrosoftEdgeEnterprise.ps1') `
        -DisplayName 'Microsoft Edge' `
        -Publisher 'Microsoft Corporation' `
        -ProductCode '{00000000-0000-0000-0000-000000000007}'
}
finally {
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
}

Write-Output 'MSI application lifecycle tests passed.'