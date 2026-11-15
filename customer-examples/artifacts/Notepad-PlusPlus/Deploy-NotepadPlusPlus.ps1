param (
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [int[]]$SuccessExitCodes = @(0, 3010)
)

#region Initialization
$SoftwareName = 'Notepad++'
$Script:Name = 'Deploy-NotepadPlusPlus'
#endregion

#region Supporting Functions
function Invoke-ApplicationProcess {
    param (
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Action,
        [int[]]$SuccessExitCodes = @(0, 3010),
        [int]$TimeoutMs = 600000
    )
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -ErrorAction Stop
    # Windows PowerShell needs a retained handle to read ExitCode after WaitForExit.
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutMs)) { $process.Kill(); throw "$Action timed out." }
    if ($null -eq $process.ExitCode) { throw "$Action did not report an exit code." }
    if ($SuccessExitCodes.Count -gt 0 -and $process.ExitCode -notin $SuccessExitCodes) {
        throw "$Action failed with exit code $($process.ExitCode)."
    }
    return $process
}

function Write-Log {
    param (
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Category = 'Info'
    )
    $content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if ($env:SUPPRESS_FILELOG -ne '1') {
        Add-Content -LiteralPath $script:Log -Value $content -ErrorAction Stop
    }
    switch ($Category) {
        'Info' { Write-Host $content }
        'Warning' { Write-Warning $content }
        'Error' { Write-Error $content -ErrorAction Continue }
    }
}

function New-Log {
    param (
        [Parameter(Position = 0)][string]$Path,
        [string]$Name = 'Artifact',
        [string]$FilePath
    )
    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    if ($FilePath) {
        $script:Log = $FilePath
        $Path = Split-Path $FilePath -Parent
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A log directory or FilePath is required.' }
        $script:Log = Join-Path $Path "$Name-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
    }
    New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
    Add-Content -LiteralPath $script:Log -Value "Date`t`t`tCategory`t`tDetails" -ErrorAction Stop
}

#endregion

## MAIN

#region Initialization

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs') -Name 'Deploy-NotepadPlusPlus'
$ErrorActionPreference = 'Stop'
Write-Log -category Info -message "Starting '$PSCommandPath'."

$ProcessTimeoutMs = 600000
if ($DeploymentType -eq 'Uninstall') {
    $UninstallerPath = Join-Path -Path $Env:ProgramFiles -ChildPath 'Notepad++\uninstall.exe'
    if (-not (Test-Path -LiteralPath $UninstallerPath -PathType Leaf)) {
        Write-Log -Message "'$SoftwareName' is not installed."
    }
    else {
        Write-Log -Message "Removing '$SoftwareName' with '$UninstallerPath /S'."
        $Process = Invoke-ApplicationProcess -FilePath $UninstallerPath -ArgumentList '/S' `
            -Action "'$SoftwareName' uninstaller" -TimeoutMs $ProcessTimeoutMs -SuccessExitCodes @()
        if ($Process.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' uninstaller failed with exit code $($Process.ExitCode)." }
    }
}
else {
    $InstallerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.exe' -File)
    if ($InstallerFiles.Count -eq 0) { throw "No EXE installer found for '$SoftwareName' in '$PSScriptRoot'." }
    if ($InstallerFiles.Count -gt 1) { throw "Expected one EXE installer for '$SoftwareName', but found: $($InstallerFiles.Name -join ', ')" }
    $PathExe = $InstallerFiles[0].FullName
    Write-Log -Message "Installing '$SoftwareName' via cmdline: '$PathExe /S /noUpdater'."
    $Process = Invoke-ApplicationProcess -FilePath $PathExe -ArgumentList '/S /noUpdater' `
        -Action "'$SoftwareName' installer" -TimeoutMs $ProcessTimeoutMs -SuccessExitCodes @()
    if ($Process.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' installer failed with exit code $($Process.ExitCode)." }
    Write-Log -Message "'$SoftwareName' installed successfully."
}

Write-Log -Category Info -message "Completed '$SoftwareName' $DeploymentType."
