param (
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [int[]]$SuccessExitCodes = @(0, 3010)
)

#region Supporting Functions
Function Get-InstalledApplication {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)]
        [ValidateNotNullorEmpty()]
        [string[]]$Name,
        [Parameter(Mandatory = $false)]
        [switch]$Exact = $false,
        [Parameter(Mandatory = $false)]
        [switch]$WildCard = $false,
        [Parameter(Mandatory = $false)]
        [switch]$RegEx = $false,
        [Parameter(Mandatory = $false)]
        [ValidateNotNullorEmpty()]
        [string]$ProductCode,
        [Parameter(Mandatory = $false)]
        [switch]$IncludeUpdatesAndHotfixes
    )

    Begin {
        ## Get the name of this function and write header
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        Write-Log -Message "Starting ${CmdletName}"
        [string[]]$regKeyApplications = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        [string]$MSIProductCodeRegExPattern = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'
        [boolean]$is64Bit = [Environment]::Is64BitOperatingSystem
    }
    Process {
        If ($name) {
            Write-Log -Message "${CmdletName}: Get information for installed Application Name(s) [$($name -join ', ')]..."
        }
        If ($productCode) {
            Write-Log -Message "${CmdletName}: Get information for installed Product Code [$ProductCode]..."
        }

        ## Enumerate the installed applications from the registry for applications that have the "DisplayName" property
        [psobject[]]$regKeyApplication = @()
        ForEach ($regKey in $regKeyApplications) {
            If (Test-Path -LiteralPath $regKey -ErrorAction 'SilentlyContinue' -ErrorVariable '+ErrorUninstallKeyPath') {
                [psobject[]]$UninstallKeyApps = Get-ChildItem -LiteralPath $regKey -ErrorAction 'SilentlyContinue' -ErrorVariable '+ErrorUninstallKeyPath'
                ForEach ($UninstallKeyApp in $UninstallKeyApps) {
                    Try {
                        [psobject]$regKeyApplicationProps = Get-ItemProperty -LiteralPath $UninstallKeyApp.PSPath -ErrorAction 'Stop'
                        If ($regKeyApplicationProps.DisplayName) { [psobject[]]$regKeyApplication += $regKeyApplicationProps }
                    }
                    Catch {
                        Write-Warning "${CmdletName}: Unable to enumerate properties from registry key path [$($UninstallKeyApp.PSPath)]."
                        Continue
                    }
                }
            }
        }
        If ($ErrorUninstallKeyPath) {
            Write-Warning "${CmdletName}: The following error(s) took place while enumerating installed applications from the registry."
        }

        $UpdatesSkippedCounter = 0
        ## Create a custom object with the desired properties for the installed applications and sanitize property details
        [psobject[]]$installedApplication = @()
        ForEach ($regKeyApp in $regKeyApplication) {
            Try {
                [string]$appDisplayName = ''
                [string]$appDisplayVersion = ''
                [string]$appPublisher = ''

                ## Bypass any updates or hotfixes
                If ((-not $IncludeUpdatesAndHotfixes) -and (($regKeyApp.DisplayName -match '(?i)kb\d+') -or ($regKeyApp.DisplayName -match 'Cumulative Update') -or ($regKeyApp.DisplayName -match 'Security Update') -or ($regKeyApp.DisplayName -match 'Hotfix'))) {
                    $UpdatesSkippedCounter += 1
                    Continue
                }

                ## Remove any control characters which may interfere with logging and creating file path names from these variables
                $appDisplayName = $regKeyApp.DisplayName -replace '[^\u001F-\u007F]', ''
                $appDisplayVersion = $regKeyApp.DisplayVersion -replace '[^\u001F-\u007F]', ''
                $appPublisher = $regKeyApp.Publisher -replace '[^\u001F-\u007F]', ''


                ## Determine if application is a 64-bit application
                [boolean]$Is64BitApp = If (($is64Bit) -and ($regKeyApp.PSPath -notmatch '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE\\SOFTWARE\\Wow6432Node')) { $true } Else { $false }

                If ($ProductCode) {
                    ## Verify if there is a match with the product code passed to the script
                    If ($regKeyApp.PSChildName -match [regex]::Escape($productCode)) {
                        Write-Log -Message "${CmdletName}:Found installed application [$appDisplayName] version [$appDisplayVersion] matching product code [$productCode]."
                        $installedApplication += New-Object -TypeName 'PSObject' -Property @{
                            UninstallSubkey    = $regKeyApp.PSChildName
                            ProductCode        = If ($regKeyApp.PSChildName -match $MSIProductCodeRegExPattern) { $regKeyApp.PSChildName } Else { [string]::Empty }
                            DisplayName        = $appDisplayName
                            DisplayVersion     = $appDisplayVersion
                            UninstallString    = $regKeyApp.UninstallString
                            InstallSource      = $regKeyApp.InstallSource
                            InstallLocation    = $regKeyApp.InstallLocation
                            InstallDate        = $regKeyApp.InstallDate
                            Publisher          = $appPublisher
                            Is64BitApplication = $Is64BitApp
                        }
                    }
                }

                If ($name) {
                    ## Verify if there is a match with the application name(s) passed to the script
                    ForEach ($application in $Name) {
                        $applicationMatched = $false
                        If ($exact) {
                            #  Check for an exact application name match
                            If ($regKeyApp.DisplayName -eq $application) {
                                $applicationMatched = $true
                                Write-Log -Message "${CmdletName}: Found installed application [$appDisplayName] version [$appDisplayVersion] using exact name matching for search term [$application]."
                            }
                        }
                        ElseIf ($WildCard) {
                            #  Check for wildcard application name match
                            If ($regKeyApp.DisplayName -like $application) {
                                $applicationMatched = $true
                                Write-Log -Message "${CmdletName}: Found installed application [$appDisplayName] version [$appDisplayVersion] using wildcard matching for search term [$application]."
                            }
                        }
                        ElseIf ($RegEx) {
                            #  Check for a regex application name match
                            If ($regKeyApp.DisplayName -match $application) {
                                $applicationMatched = $true
                                Write-Log -Message "${CmdletName}: Found installed application [$appDisplayName] version [$appDisplayVersion] using regex matching for search term [$application]."
                            }
                        }
                        #  Check for a contains application name match
                        ElseIf ($regKeyApp.DisplayName -match [regex]::Escape($application)) {
                            $applicationMatched = $true
                            Write-Log -Message "${CmdletName}: Found installed application [$appDisplayName] version [$appDisplayVersion] using contains matching for search term [$application]."
                        }

                        If ($applicationMatched) {
                            $installedApplication += New-Object -TypeName 'PSObject' -Property @{
                                UninstallSubkey    = $regKeyApp.PSChildName
                                ProductCode        = If ($regKeyApp.PSChildName -match $MSIProductCodeRegExPattern) { $regKeyApp.PSChildName } Else { [string]::Empty }
                                DisplayName        = $appDisplayName
                                DisplayVersion     = $appDisplayVersion
                                UninstallString    = $regKeyApp.UninstallString
                                InstallSource      = $regKeyApp.InstallSource
                                InstallLocation    = $regKeyApp.InstallLocation
                                InstallDate        = $regKeyApp.InstallDate
                                Publisher          = $appPublisher
                                Is64BitApplication = $Is64BitApp
                            }
                        }
                    }
                }
            }
            Catch {
                Write-Log -Category Error -Message "${CmdletName}: Failed to resolve application details from registry for [$appDisplayName]."
                Continue
            }
        }

        If (-not $IncludeUpdatesAndHotfixes) {
            ## Write to log the number of entries skipped due to them being considered updates
            If ($UpdatesSkippedCounter -eq 1) {
                Write-Log -Message "${CmdletName}: Skipped 1 entry while searching, because it was considered a Microsoft update."
            }
            else {
                Write-Log -Message "${CmdletName}: Skipped $UpdatesSkippedCounter entries while searching, because they were considered Microsoft updates."
            }
        }

        If (-not $installedApplication) {
            Write-Log -Message "${CmdletName}: Found no application based on the supplied parameters."
        }

        Write-Output -InputObject $installedApplication
    }
    End {
        Write-Log -Message "Ending ${CmdletName}"
    }
}

function New-Log {
    Param (
        [Parameter(Position = 0)]
        [string] $Path = (Join-Path -Path $env:SystemRoot -ChildPath 'Logs')
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

Function Remove-MSIApplication {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)]
        [ValidateNotNullorEmpty()]
        [string]$Name
    )
    $InstalledApp = Get-InstalledApplication -Name $Name
    If ($InstalledApp -and $InstalledApp.ProductCode -ne '') {
        $ProductCode = $InstalledApp.ProductCode
        Write-Log -Message "Removing $Name with Product Code $ProductCode"
        $UninstallTimeoutMs = 600000 # 10 minutes
        $uninstall = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/X $ProductCode /qn" -PassThru
        if (-not $uninstall.WaitForExit($UninstallTimeoutMs)) {
            $uninstall.Kill()
            Write-Log -Category Warning -Message "$Name uninstaller timed out after $($UninstallTimeoutMs / 60000) minutes and was terminated."
        }
        elseif ($Uninstall.ExitCode -eq '0' -or $Uninstall.ExitCode -eq '3010') {
            Write-Log -Message "Uninstalled successfully"
        }
        else {
            Write-Log -Message "$ProductCode uninstall exit code $($uninstall.ExitCode)" -category Warning
        }
    }
}

function Wait-MsiexecIdle {
    # msiexec serializes all MSI transactions through a global Windows Installer mutex.
    # Only one MSI transaction can run at a time. If an Azure Policy deployIfNotExists
    # extension or concurrent deployment holds the lock, this waits up to 5 minutes.
    param ([int]$WaitSeconds = 300)
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
[string]$Script:Name = 'Deploy-AzCLI'
$SoftwareName = 'Microsoft Azure CLI'
New-Log -Path (Join-Path -Path "$env:SystemRoot\Logs" -ChildPath 'Software')
If ($DeploymentType -eq 'Install') {
    Wait-MsiexecIdle
    Remove-MSIApplication -Name $SoftwareName
    $installerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.msi' -File)
    if ($installerFiles.Count -eq 0) { throw "No MSI installer found for '$SoftwareName' in '$PSScriptRoot'." }
    if ($installerFiles.Count -gt 1) { throw "Expected one MSI installer for '$SoftwareName', but found: $($installerFiles.Name -join ', ')" }
    $pathMsi = $installerFiles[0].FullName
    Write-Log -Message "Starting '$SoftwareName' installation and configuration."
    Write-Log -Message "Installing '$SoftwareName' via cmdline:"
    Write-Log -Message "     'msiexec.exe /i `"$pathMSI`" /qn /norestart'"
    $InstallerTimeoutMs = 600000 # 10 minutes
    $Installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$pathMSI`" /qn /norestart" -PassThru
    if (-not $Installer.WaitForExit($InstallerTimeoutMs)) {
        $Installer.Kill()
        Write-Log -Category Error -Message "'$SoftwareName' installer timed out after $($InstallerTimeoutMs / 60000) minutes and was terminated."
        exit 1
    }
    elseif ($Installer.ExitCode -in $SuccessExitCodes) {
        if ($Installer.ExitCode -eq 3010) { Write-Log -Message "'$SoftwareName' installed successfully. A reboot is required." }
        else { Write-Log -Message "'$SoftwareName' installed successfully." }
    }
    else {
        Write-Log -Category Error -Message "'$SoftwareName' installer failed with exit code $($Installer.ExitCode)."
        exit $Installer.ExitCode
    }
    Write-Log -Message "Completed '$SoftwareName' Installation."
}
Else {
    Write-Log -Message "Searching for and removing $SoftwareName if found."
    Remove-MSIApplication -Name $SoftwareName
}
