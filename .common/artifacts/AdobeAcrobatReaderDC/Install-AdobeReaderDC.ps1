[CmdletBinding()]
param (
    [Parameter()]
    [String]$DisableUpdates = 'True'
)
try {
    [bool]$DisableUpdates = [System.Convert]::ToBoolean($DisableUpdates) 
}
catch [FormatException] {
    $DisableUpdates = $false
}
#region Initialization
$SoftwareName = 'Adobe Reader DC'
$Script:Name = 'Install-AdobeReaderDC'
#endregion

#region Supporting Functions
function Write-Log {

    <#
    .SYNOPSIS
    Creates a log file and stores logs based on categories with tab seperation

    .PARAMETER category
    Category to put into the trace

    .PARAMETER message
    Message to be loged

    .EXAMPLE
    Log 'Info' 'Message'

    #>

    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet("Info", "Warning", "Error")]
        $category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $message
    )

    $date = get-date
    $content = "[$date]`t$category`t`t$message`n"
    Write-Verbose "$Script:Name $content" -verbose

    if (! $script:Log) {
        $File = Join-Path -Path $env:TEMP -ChildPath "$Script:Name.log"
        Write-Warning "Log file not found, create new $File"
        $script:Log = $File
    }
    else {
        $File = $script:Log
    }
    Add-Content $File $content -ErrorAction Stop
}

function New-Log {
    <#
    .SYNOPSIS
    Sets default log file and stores in a script accessible variable $script:Log
    Log File name "packageExecution_$date.log"

    .PARAMETER Path
    Path to the log file

    .EXAMPLE
    New-Log c:\Windows\Logs
    Create a new log file in c:\Windows\Logs
    #>

    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path
    )

    # Create central log file with given date

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
If ($DisableUpdates) {
    $InstallArgs = '-sfx_nu /sALL /msi EULA_ACCEPT=YES ENABLE_CHROMEEXT=0 DISABLE_BROWSER_INTEGRATION=1 ENABLE_OPTIMIZATION=YES ADD_THUMBNAILPREVIEW=0 DISABLEDESKTOPSHORTCUT=1 UPDATE_MODE=0 DISABLE_ARM_SERVICE_INSTALL=1'
}
Else {
    $InstallArgs = '-sfx /sALL /msi EULA_ACCEPT=YES ENABLE_CHROMEEXT=0 DISABLE_BROWSER_INTEGRATION=1 ENABLE_OPTIMIZATION=YES ADD_THUMBNAILPREVIEW=0 DISABLEDESKTOPSHORTCUT=1'
}
$PathExe = (Get-ChildItem -Path $PSScriptRoot -Filter '*.exe').FullName
Write-Log -Category Info -message "Installing '$SoftwareName' via cmdline: '$PathExe $InstallArgs'."
$Installer = Start-Process -FilePath $PathExe -ArgumentList $InstallArgs -Wait -PassThru
If ($($Installer.ExitCode) -eq 0) {
    Write-Log -Category Info -message "'$SoftwareName' installed successfully."
}
Else {
    Write-Log -Category Warning -Message "The Installer exit code is $($Installer.ExitCode)"
}
if ($DisableUpdates) {
    Write-Log -Category Info -message "Disabling '$SoftwareName' Updates."
    Get-Service -Name AdobeARMservice -ErrorAction SilentlyContinue | Set-Service -StartupType Disabled
    Get-ScheduledTask "Adobe Acrobat Update Task*" | Unregister-ScheduledTask -Confirm:$False
}

Write-Log -Category Info -message "Completed '$SoftwareName' Installation."