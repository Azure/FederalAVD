#region Initialization
$SoftwareName = 'Notepad++'
$Script:Name = 'Install-NotepadPlusPlus'
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

$PathExe = (Get-ChildItem -Path $PSScriptRoot -Filter '*.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
Write-Log -Category Info -message "Installing '$SoftwareName' via cmdline: '$PathExe /S /noUpdater' ."
$Installer = Start-Process -FilePath $PathExe  -ArgumentList "/S /noUpdater" -Wait -PassThru
If ($($Installer.ExitCode) -eq 0) {
    Write-Log -Category Info -message "'$SoftwareName' installed successfully."
}
Else {
    Write-Log -Category Warning -Message "The Installer exit code is $($Installer.ExitCode)"
}

Write-Log -Category Info -message "Completed '$SoftwareName' Installation."
