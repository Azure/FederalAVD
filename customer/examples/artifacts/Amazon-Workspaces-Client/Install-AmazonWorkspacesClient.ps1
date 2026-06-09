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
$SoftwareName = 'Amazon-Workspaces-Client'
$Script:Name = 'Install-AmazonWorkspacesClient'
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

Function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Name,
        [Parameter()]
        [string]
        $Path,
        [Parameter()]
        [string]$PropertyType,
        [Parameter()]
        $Value
    )
    Begin {
        Write-Log -message "[Set-RegistryValue]: Setting Registry Value: $Name"
    }
    Process {
        # Create the registry Key(s) if necessary.
        If (!(Test-Path -Path $Path)) {
            Write-Log -message "[Set-RegistryValue]: Creating Registry Key: $Path"
            New-Item -Path $Path -Force | Out-Null
        }
        # Check for existing registry setting
        $RemoteValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        If ($RemoteValue) {
            # Get current Value
            $CurrentValue = Get-ItemPropertyValue -Path $Path -Name $Name
            Write-Log -message "[Set-RegistryValue]: Current Value of $($Path)\$($Name) : $CurrentValue"
            If ($Value -ne $CurrentValue) {
                Write-Log -message "[Set-RegistryValue]: Setting Value of $($Path)\$($Name) : $Value"
                Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
            }
            Else {
                Write-Log -message "[Set-RegistryValue]: Value of $($Path)\$($Name) is already set to $Value"
            }          
        }
        Else {
            Write-Log -message "[Set-RegistryValue]: Setting Value of $($Path)\$($Name) : $Value"
            New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
        }
        Start-Sleep -Milliseconds 500
    }
    End {
    }
}

#endregion

## MAIN

#region Initialization

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs')
Write-Log -category Info -message "Starting '$PSCommandPath'."

$PathMSI = (Get-ChildItem -Path $PSScriptRoot -Filter '*.msi' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
Write-Log -Category Info -message "Installing '$SoftwareName' via cmdline: 'msiexec /i `"$PathMSI`" /qn ALLUSERS=1'."
$Installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$PathMSI`" /qn ALLUSERS=1" -Wait -PassThru
If ($($Installer.ExitCode) -eq 0) {
    Write-Log -Category Info -message "'$SoftwareName' installed successfully."
}
Else {
    Write-Log -Category Warning -Message "The Installer exit code is $($Installer.ExitCode)"
}
if ($DisableUpdates) {
    Set-RegistryValue -Name 'clientUpgradeDisabled' -Path 'HKLM:\SOFTWARE\WOW6432Node\Amazon\Amazon WorkSpaces Client' -PropertyType 'STRING' -Value 1
}    

Write-Log -Category Info -message "Completed '$SoftwareName' Installation."
