#region Initialization
$Script:Name = 'Install-PowerBIDesktop'
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

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs')
$ErrorActionPreference = 'Stop'
Write-Log -message "Starting '$PSCommandPath'."
$Installer = (Get-ChildItem -Path $PSScriptRoot -File -Filter '*.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
$Install = Start-Process -FilePath $Installer -ArgumentList "-quiet -norestart ACCEPT_EULA=1 DISABLE_UPDATE_NOTIFICATION=1 ENABLECXP=0" -Wait -PassThru
If ($Install.ExitCode -eq 0) {
    Write-Log -message "Power BI Desktop installed successfully."
}
Else {
    Write-Log -Category 'Error' -message "Power BI Desktop installation failed with exit code $($Install.ExitCode)."
    throw "Power BI Desktop installation failed with exit code $($Install.ExitCode)."
}
