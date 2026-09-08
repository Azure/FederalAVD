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
    $global:msiTestExitCodes = @(1618, 0)
    $global:msiTestSleepCalls = @()
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
        function global:Start-Process {
            param ([string]$FilePath, [string]$ArgumentList, [switch]$PassThru)
            $global:msiTestProcessCalls += [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList }
            $exitCode = $global:msiTestExitCodes[[math]::Min($global:msiTestProcessCalls.Count - 1, $global:msiTestExitCodes.Count - 1)]
            $process = [pscustomobject]@{ ExitCode = $exitCode }
            $process | Add-Member ScriptMethod WaitForExit { param($TimeoutMs) return $true }
            $process | Add-Member ScriptMethod Kill { }
            return $process
        }
        function global:Start-Sleep {
            param ([int]$Seconds, [int]$Milliseconds)
            $global:msiTestSleepCalls += if ($Seconds) { $Seconds } else { $Milliseconds / 1000 }
        }

        & $ScriptPath -DeploymentType Uninstall
        if ($global:msiTestProcessCalls.Count -ne 2) { throw "Expected $DisplayName to retry once after exit code 1618." }
        foreach ($call in $global:msiTestProcessCalls) {
            if ($call.FilePath -ne 'msiexec.exe' -or $call.ArgumentList -ne "/x $ProductCode /qn /norestart") {
                throw "Unexpected uninstall for $DisplayName`: $($call | ConvertTo-Json -Compress)"
            }
        }
        if ($global:msiTestSleepCalls.Count -ne 1 -or $global:msiTestSleepCalls[0] -ne 30) {
            throw "Expected one 30-second retry delay for $DisplayName."
        }

        $global:msiTestProcessCalls = @()
        $global:msiTestExitCodes = @(1618)
        $global:msiTestSleepCalls = @()
        $retryFailure = $null
        try {
            & $ScriptPath -DeploymentType Uninstall
        }
        catch {
            $retryFailure = $_
        }
        if (-not $retryFailure -or $retryFailure.Exception.Message -notmatch 'failed after 11 attempts with exit code 1618') {
            throw "Expected bounded exit code 1618 retry failure for $DisplayName."
        }
        if ($global:msiTestProcessCalls.Count -ne 11 -or $global:msiTestSleepCalls.Count -ne 10) {
            throw "Expected 11 attempts and 10 delays before failing $DisplayName."
        }

        $global:msiTestProcessCalls = @()
        $global:msiTestExitCodes = @(1639)
        $global:msiTestSleepCalls = @()
        $nonRetryableFailure = $null
        try {
            & $ScriptPath -DeploymentType Uninstall
        }
        catch {
            $nonRetryableFailure = $_
        }
        if (-not $nonRetryableFailure -or $nonRetryableFailure.Exception.Message -notmatch 'failed with exit code 1639') {
            throw "Expected immediate non-retryable MSI failure for $DisplayName."
        }
        if ($global:msiTestProcessCalls.Count -ne 1 -or $global:msiTestSleepCalls.Count -ne 0) {
            throw "Expected no retry or delay for non-1618 failure from $DisplayName."
        }

        $global:msiTestInstalled = $false
        $global:msiTestProcessCalls = @()
        & $ScriptPath -DeploymentType Uninstall
        if ($global:msiTestProcessCalls.Count) { throw "$DisplayName removal was not idempotent." }
    }
    finally {
        Remove-Item function:\Test-Path, function:\Get-ChildItem, function:\Get-ItemProperty, function:\Start-Process, function:\Start-Sleep -ErrorAction SilentlyContinue
        Remove-Variable msiTestInstalled, msiTestDisplayName, msiTestPublisher, msiTestProductCode, msiTestProcessCalls, msiTestExitCodes, msiTestSleepCalls -Scope Global -ErrorAction SilentlyContinue
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