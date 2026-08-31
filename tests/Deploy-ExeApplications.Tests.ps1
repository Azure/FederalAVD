$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$originalProgramFiles = $env:ProgramFiles
$originalSystemRoot = $env:SystemRoot
$tempRoot = Join-Path $env:TEMP "FederalAVD-exe-test-$([guid]::NewGuid())"

function Test-ExeApplicationRemoval {
    param ([string]$ScriptPath, [string]$UninstallerRelativePath, [string]$Arguments)
    $uninstallerPath = Join-Path $env:ProgramFiles $UninstallerRelativePath
    New-Item -Path (Split-Path $uninstallerPath -Parent) -ItemType Directory -Force | Out-Null
    Set-Content -Path $uninstallerPath -Value '' -Encoding ASCII
    $global:exeTestCalls = @()
    try {
        function global:Start-Process {
            param ([string]$FilePath, [string]$ArgumentList, [switch]$PassThru, [string]$ErrorAction)
            $global:exeTestCalls += [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList }
            $process = [pscustomobject]@{ ExitCode = 0 }
            $process | Add-Member ScriptMethod WaitForExit { param($TimeoutMs) return $true }
            $process | Add-Member ScriptMethod Kill { }
            return $process
        }
        & $ScriptPath -DeploymentType Uninstall
        if ($global:exeTestCalls.Count -ne 1) { throw "Expected one uninstall process for $ScriptPath." }
        if ($global:exeTestCalls[0].FilePath -ne $uninstallerPath -or $global:exeTestCalls[0].ArgumentList -ne $Arguments) {
            throw "Unexpected uninstall invocation: $($global:exeTestCalls[0] | ConvertTo-Json -Compress)"
        }
        Remove-Item -LiteralPath $uninstallerPath -Force
        $global:exeTestCalls = @()
        & $ScriptPath -DeploymentType Uninstall
        if ($global:exeTestCalls.Count) { throw "$ScriptPath removal was not idempotent." }
    }
    finally {
        Remove-Item function:\Start-Process -ErrorAction SilentlyContinue
        Remove-Variable exeTestCalls -Scope Global -ErrorAction SilentlyContinue
    }
}

try {
    $env:ProgramFiles = Join-Path $tempRoot 'ProgramFiles'
    $env:SystemRoot = $tempRoot
    $env:SUPPRESS_FILELOG = '1'
    Test-ExeApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\Notepad-PlusPlus\Deploy-NotepadPlusPlus.ps1') `
        -UninstallerRelativePath 'Notepad++\uninstall.exe' `
        -Arguments '/S'
    Test-ExeApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\Microsoft-VSCode\Deploy-VSCode.ps1') `
        -UninstallerRelativePath 'Microsoft VS Code\unins000.exe' `
        -Arguments '/VERYSILENT /NORESTART'
    Test-ExeApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\Git-for-Windows\Deploy-GitforWindows.ps1') `
        -UninstallerRelativePath 'Git\unins000.exe' `
        -Arguments '/VERYSILENT /NORESTART'
}
finally {
    $env:ProgramFiles = $originalProgramFiles
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'EXE application lifecycle tests passed.'