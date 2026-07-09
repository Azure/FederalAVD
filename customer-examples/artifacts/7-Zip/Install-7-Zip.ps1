#region Initialization
$SoftwareName = '7-Zip'
$Script:Name = 'Install-7-Zip'
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

function Wait-MsiexecIdle {
    [CmdletBinding()]
    param (
        [int]$WaitSeconds = 300
    )
    $elapsed = 0
    Write-Log -Category Info -Message 'Pre-flight: checking for active msiexec processes...'
    while ($elapsed -lt $WaitSeconds) {
        if (-not (Get-Process -Name 'msiexec' -ErrorAction SilentlyContinue | Where-Object { -not $_.HasExited })) { break }
        Write-Log -Category Info -Message "Pre-flight: msiexec is active. Waiting 10 s... ($elapsed / $WaitSeconds s elapsed)"
        Start-Sleep -Seconds 10
        $elapsed += 10
    }
    if ($elapsed -ge $WaitSeconds) {
        Write-Log -Category Warning -Message "Pre-flight: msiexec was still active after $WaitSeconds seconds. Installation may queue or fail."
    }
    else {
        Write-Log -Category Info -Message 'Pre-flight: msiexec serialization lock is free.'
    }
}

#endregion

## MAIN

#region Initialization

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs')
$ErrorActionPreference = 'Stop'
Write-Log -category Info -message "Starting '$PSCommandPath'."

$PathMSI = (Get-ChildItem -Path $PSScriptRoot -Filter '*.msi' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
Write-Log -Category Info -message "Installing '$SoftwareName' via cmdline: 'msiexec /i `"$PathMSI`" /quiet /noreboot'."
Wait-MsiexecIdle
$InstallerTimeoutMs = 600000 # 10 minutes
$Installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$PathMSI`" /quiet /noreboot" -PassThru
if (-not $Installer.WaitForExit($InstallerTimeoutMs)) {
    $Installer.Kill()
    Write-Log -Category Warning -Message "'$SoftwareName' installer timed out after $($InstallerTimeoutMs / 60000) minutes and was terminated."
}
elseif ($Installer.ExitCode -eq 0 -or $Installer.ExitCode -eq 3010) {
    if ($Installer.ExitCode -eq 3010) { Write-Log -Category Info -message "'$SoftwareName' installed successfully. A reboot is required." }
    else { Write-Log -Category Info -message "'$SoftwareName' installed successfully." }
}
else {
    Write-Log -Category Warning -Message "The Installer exit code is $($Installer.ExitCode)"
}

Write-Log -Category Info -message "Completed '$SoftwareName' Installation."
