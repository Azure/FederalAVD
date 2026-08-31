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
Function Write-Log {
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet("Info", "Warning", "Error")]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )

    $Content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if (-not $env:SUPPRESS_FILELOG) {
        Add-Content $Script:Log $Content -ErrorAction SilentlyContinue
    }
    Switch ($Category) {
        'Info'    { Write-Host $Content }
        'Error'   { Write-Error $Content -ErrorAction Continue }
        'Warning' { Write-Warning $Content }
    }
}

function New-Log {
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path
    )

    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    $date = Get-Date -UFormat "%Y-%m-%d %H-%M-%S"
    Set-Variable logFile -Scope Script
    $script:logFile = "$Script:Name-$date.log"

    if ((Test-Path $path ) -eq $false) {
        $null = New-Item -Path $path -type directory
    }

    $script:Log = Join-Path $path $logfile

    Add-Content $script:Log "Date`t`t`tCategory`t`tDetails"
}

#endregion

## MAIN

#region Initialization

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs')
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
        $Process = Start-Process -FilePath $UninstallerPath -ArgumentList '/S' -PassThru
        if (-not $Process.WaitForExit($ProcessTimeoutMs)) { $Process.Kill(); throw "'$SoftwareName' uninstaller timed out." }
        if ($Process.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' uninstaller failed with exit code $($Process.ExitCode)." }
    }
}
else {
    $InstallerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.exe' -File)
    if ($InstallerFiles.Count -eq 0) { throw "No EXE installer found for '$SoftwareName' in '$PSScriptRoot'." }
    if ($InstallerFiles.Count -gt 1) { throw "Expected one EXE installer for '$SoftwareName', but found: $($InstallerFiles.Name -join ', ')" }
    $PathExe = $InstallerFiles[0].FullName
    Write-Log -Message "Installing '$SoftwareName' via cmdline: '$PathExe /S /noUpdater'."
    $Process = Start-Process -FilePath $PathExe -ArgumentList '/S /noUpdater' -PassThru
    if (-not $Process.WaitForExit($ProcessTimeoutMs)) { $Process.Kill(); throw "'$SoftwareName' installer timed out." }
    if ($Process.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' installer failed with exit code $($Process.ExitCode)." }
    Write-Log -Message "'$SoftwareName' installed successfully."
}

Write-Log -Category Info -message "Completed '$SoftwareName' $DeploymentType."
