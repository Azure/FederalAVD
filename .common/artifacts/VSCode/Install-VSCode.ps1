<#
.SYNOPSIS
    Installs Visual Studio Code silently and optionally disables automatic updates.

.DESCRIPTION
    Installs the Visual Studio Code executable found in the same directory as this
    script using a fully silent, no-restart installation. Optionally sets the
    machine-wide Group Policy registry value to disable VS Code's built-in update
    mechanism, which is recommended for managed VDI image builds where updates
    should be controlled through the image pipeline rather than the application.

.PARAMETER DisableUpdates
    When set to $true, sets HKLM:\SOFTWARE\Policies\Microsoft\VSCode\UpdateMode
    to 'none', preventing VS Code from automatically checking for and downloading
    updates. Defaults to $false.

.NOTES
    - The installer executable (.exe) must be present in the same directory as
      this script. The first .exe file found is used.
    - Logs are written to C:\Windows\Logs\Install_VSCode-<datetime>.log.
    - Designed to run silently in a SYSTEM context during an image build.

.EXAMPLE
    # Install VS Code and allow automatic updates (default)
    .\Install_VSCode.ps1

.EXAMPLE
    # Install VS Code and disable automatic updates
    .\Install_VSCode.ps1 -DisableUpdates $true
#>
[CmdletBinding()]
param (
    [Parameter()]
    [bool]
    $DisableUpdates
)
#region functions
Function Write-Log {
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet("Info", "Warning", "Error")]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )

    $Date = get-date
    $Content = "[$Date]`t$Category`t`t$Message`n" 
    Add-Content $Script:Log $content -ErrorAction Stop
    If ($Verbose) {
        Write-Verbose $Content
    }
    Else {
        Switch ($Category) {
            'Info' { Write-Host $content }
            'Error' { Write-Error $Content }
            'Warning' { Write-Warning $Content }
        }
    }
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
        [Parameter(Mandatory = $true, Position=0)]
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

Function Set-RegistryValue {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullorEmpty()]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Value,
        [Parameter(Mandatory = $false)]
        [ValidateSet('Binary', 'DWord', 'ExpandString', 'MultiString', 'None', 'QWord', 'String', 'Unknown')]
        [Microsoft.Win32.RegistryValueKind]$Type = 'String'
    )

    [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name

    If (-not (Get-ItemProperty -LiteralPath $key -Name $Name -ErrorAction 'SilentlyContinue')) {
        If (-not (Test-Path -LiteralPath $key -ErrorAction 'Stop')) {
            Try {
                Write-Log -Info -Message "${CmdletName}: Create registry key [$key]."
                # No forward slash found in Key. Use New-Item cmdlet to create registry key
                If ((($Key -split '/').Count - 1) -eq 0) {
                    $null = New-Item -Path $key -ItemType 'Registry' -Force -ErrorAction 'Stop'
                }
                # Forward slash was found in Key. Use REG.exe ADD to create registry key
                Else {
                    $null = & reg.exe Add "$($Key.Substring($Key.IndexOf('::') + 2))"
                    If ($global:LastExitCode -ne 0) {
                        Throw "Failed to create registry key [$Key]"
                    }
                }
            }
            Catch {
                Throw
            }
        }
        Write-Log -category Info -Message "${CmdletName}: Set registry key value: [$key] [$name = $value]."
        $null = New-ItemProperty -LiteralPath $key -Name $name -Value $value -PropertyType $Type -ErrorAction 'Stop'
    }
    ## Update registry value if it does exist
    Else {
        If ($Name -eq '(Default)') {
            ## Set Default registry key value with the following workaround, because Set-ItemProperty contains a bug and cannot set Default registry key value
            $null = $(Get-Item -LiteralPath $key -ErrorAction 'Stop').OpenSubKey('', 'ReadWriteSubTree').SetValue($null, $value)
        }
        Else {
            Write-Log -category Info -Message "${CmdletName}: Update registry key value: [$key] [$name = $value]."
            $null = Set-ItemProperty -LiteralPath $key -Name $name -Value $value -ErrorAction 'Stop'
        }
    }
}

#endregion Functions

#region Initialization
$Script:Name = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$DownloadUrl = 'https://go.microsoft.com/fwlink/?linkid=852157'
New-Log "C:\Windows\Logs"
$ErrorActionPreference = 'Stop'
Write-Log -category Info -message "Starting '$PSCommandPath'."
#endregion

#region Install               
$installer = Get-ChildItem -Path "$PSScriptRoot" -File -Filter '*.exe'
If ($installer.Count -gt 0) {
    $VSCodeExe = $installer[0].FullName
    
} Else {
    Write-Log -category Warning -message "No installer executable found in $PSScriptRoot."
    Write-Log -Category Information -message "Attempting to download installer from $DownloadUrl"
    $VSCodeExe = Join-Path -Path $env:Temp -ChildPath 'VSCodeInstaller.exe'
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $VSCodeExe -ErrorAction Stop
}
Write-Log -message "Starting installation of VSCode."
$Arguments = "/VERYSILENT /NORESTART /MERGETASKS=!runcode" 
Write-Log -message "Executing '$VSCodeexec $Arguments'"
$Installer = Start-Process -FilePath "$VSCodeExe" -ArgumentList $Arguments -Wait -PassThru
If ($($Installer.ExitCode) -eq 0 ) {
    Write-Log -message "'VSCode' installed successfully."
}
Else {
    Write-Log -category Error -message "The exit code is $($Installer.ExitCode)"
}
#endregion Install
if($DisableUpdates) {
    Write-Log -message "Disabling VSCode updates by setting registry value."
    Set-RegistryValue -Key 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode' -Name 'UpdateMode' -Value 'none' -Type 'String'
}
Write-Log -Message "Ending '$PSCommandPath'."

