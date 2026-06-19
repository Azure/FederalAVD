param(
    [string]$APIVersion,
    [string]$BlobStorageSuffix,
    [string]$BuildDir = '',
    [string]$UserAssignedIdentityClientId = '',
    [string]$TeamsCloudType,
    [string]$Uris,
    [string]$DestFileNames
)

$ErrorActionPreference = 'Stop'

$SoftwareName = 'Teams'
$LogFile = "$env:SystemRoot\Logs\Install-$SoftwareName.log"

function Write-Log {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Message
    )
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

try {
    Write-Log ($PSBoundParameters | Format-Table -AutoSize | Out-String)
    If ($null -ne $BuildDir -and $BuildDir -ne '') {
        $TempDir = Join-Path $BuildDir -ChildPath $SoftwareName
    }
    Else {
        $TempDir = Join-Path $Env:TEMP -ChildPath $SoftwareName
    }
    New-Item -Path $TempDir -ItemType Directory -Force | Out-Null  

    [array]$Uris = $Uris.Replace('\"', '"') | ConvertFrom-Json
    Write-Log "Uris:"
    ForEach ($Uri in $Uris) {
        Write-Log " $Uri"
    }
    [array]$DestFileNames = $DestFileNames.Replace('\"', '"') | ConvertFrom-Json
    Write-Log "DestFileNames:"
    ForEach ($DestFileName in $DestFileNames) {
        Write-Log " $DestFileName"
    }
    # Force TLS 1.2 — fresh marketplace images default to TLS 1.0/1.1 which Azure Storage rejects.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    For ($i = 0; $i -lt $Uris.Length; $i++) {
        $WebClient = New-Object System.Net.WebClient
        $Uri = $Uris[$i]
        $DestFileName = $DestFileNames[$i]
        if ($Uri -match $BlobStorageSuffix) {
            $StorageEndpoint = ($Uri -split "://")[0] + "://" + ($Uri -split "/")[2] + "/"
            $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=$APIVersion&resource=$StorageEndpoint&client_id=$UserAssignedIdentityClientId"
            $AccessToken = ((Invoke-WebRequest -Headers @{Metadata = $true } -Uri $TokenUri -UseBasicParsing).Content | ConvertFrom-Json).access_token
            $WebClient.Headers.Add('x-ms-version', '2017-11-09')
            $webClient.Headers.Add("Authorization", "Bearer $AccessToken")
        }
        $DestFile = Join-Path -Path $TempDir -ChildPath $DestFileName
        Write-Log "Downloading '$Uri' to '$DestFile'."
        $ErrorActionPreference = 'SilentlyContinue'
        $webClient.DownloadFile($Uri, $DestFile)
        Unblock-File -Path $DestFile
        $ErrorActionPreference = 'Stop'
        $WebClient = $null
    }
    $BootStrapperFile = Join-Path -Path $TempDir -ChildPath $DestFileNames[0]
    If (!(Test-Path -Path $BootStrapperFile)) {
        Write-Log "Failed to download the Teams bootstrapper file."
        Exit 1
    }
    $MSIXFile = Join-Path -Path $TempDir -ChildPath $DestFileNames[1]
    If (!(Test-Path -Path $MSIXFile)) {
        Write-Log "Failed to download the Teams MSIX file."
        Exit 1
    }
    If ($Uris.Length -gt 2) {
        $WebView2File = Join-Path -Path $TempDir -ChildPath $DestFileNames[2]
        If (!(Test-Path -Path $WebView2File)) {
            Write-Log -Message "Failed to download the WebView2 file."
            $WebView2File = $null
        }    
        $vcRedistFile = Join-Path -Path $TempDir -ChildPath $DestFileNames[3]
        If (!(Test-Path -Path $vcRedistFile)) {
            Write-Log -Message "Failed to download the Visual C++ Redistributable file."
            $vcRedistFile = $null
        }
        $webRTCFile = Join-Path -Path $TempDir -ChildPath $DestFileNames[4]
        If (!(Test-Path -Path $webRTCFile)) {
            Write-Log -Message "Failed to download the WebRTC file."
            $webRTCFile = $null
        }
    }
    Else {
        $WebView2File = $null
        $vcRedistFile = $null
        $webRTCFile = $null
    }

    If ($WebView2File -or $vcRedistFile -or $webRTCFile) {
        Write-Log "Starting installation of Teams dependencies."
    }
    Else {
        Write-Log "No dependencies to install."
    }

    # Enable media optimizations for Team
    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Teams" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Teams" -Name IsWVDEnvironment -PropertyType DWORD -Value 1 -Force | Out-Null

    # Check to see if WebView2 is already installed
    Write-Log "Checking if WebView2 Runtime is already installed."
    If (Test-Path -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') {
        If (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -Name pv -ErrorAction SilentlyContinue) {
            $WebView2Installed = $True
            $InstalledVersion = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -Name pv).pv
            Write-Log "WebView2 Runtime is already installed. Version: $InstalledVersion"
        }
    }
    If (-not $WebView2Installed -and $null -ne $WebView2File) {
        Write-Log "WebView2 runtime not installed, installing the latest version."
        $WebView2Installer = Start-Process -FilePath $WebView2File -ArgumentList "/silent /install" -Wait -PassThru
        If ($($WebView2Installer.ExitCode) -eq 0 ) {
            Write-Log "Installed the latest version of the Microsoft WebView2 Runtime"
        }
        Else {
            Write-Log "Installion of the Microsoft WebView2 Runtime failed with exit code $($WebView2Installer.ExitCode)"
        }
    }
    If ($null -ne $vcRedistFile) {
        Write-Log "Installing Microsoft Visual C++ Redistributables."
        $VCRedistInstall = Start-Process -FilePath $vcRedistFile -ArgumentList "/install /passive /norestart" -Wait -PassThru
        If ($VCRedistInstall.ExitCode -eq 0 ) {
            Write-Log "Installed the latest version of Microsoft Visual C++ Redistributable"
        }
        Else {
            Write-Log "Installion of the Microsoft Visual C++ Redistributable failed with exit code $($VCRedistInstall.ExitCode)"
        }
    }
    If ($null -ne $webRTCFile) {
        Write-Log "Installing the Remote Desktop WebRTC Redirector Service"
        $WebRTCInstall = Start-Process -FilePath msiexec.exe -ArgumentList "/i $webRTCFile /quiet /norestart" -Wait -PassThru
        If ($($WebRTCInstall.ExitCode) -eq 0) {
            Write-Log "Installed the Remote Desktop WebRTC Redirector Service"
        }
        Else {
            Write-Log "Installation of the Remote Desktop WebRTC Redirector Service failed with exit code $($WebRTCInstall.ExitCode)"
        }
    }
    Write-Log "Starting Teams installation."
    $TeamsInstall = Start-Process -FilePath "$BootStrapperFile" -ArgumentList "-p -o `"$MSIXFile`"" -Wait -PassThru
    If ($($TeamsInstall.ExitCode) -eq 0) {
        # Get Version of currently installed new Teams Package
        $TeamsVersion = (Get-AppxPackage -Name MSTeams).Version
        Write-Log "Installed Teams Version $TeamsVersion successfully."
    }
    Else {
        Write-Log "Teams installation failed with exit code $($TeamsInstall.ExitCode)"
    }

    Switch ($TeamsCloudType) {
        "GCC" {
            $CloudType = 2
        }
        "GCCH" {
            $CloudType = 3
        }
        "DOD" {
            $CloudType = 4
        }
        "GovSecret" {
            $CloudType = 5
        }
        "GovTopSecret" {
            $CloudType = 6
        }
        "Gallatin" {
            $CloudType = 7
        }
    }
    If ($CloudType) {
        $null = Start-Process -FilePath reg.exe -ArgumentList "LOAD HKLM\Default $env:SystemDrive\Users\Default\ntuser.dat" -Wait
        $null = Start-Process -FilePath reg.exe -ArgumentList "ADD HKLM\Default\SOFTWARE\Microsoft\Office\16.0\Teams /n CloudType /t REG_DWORD /v $CloudType /f" -Wait -PassThru
        Start-Sleep -Seconds 5
        [System.GC]::Collect()
        $null = Start-Process -FilePath reg.exe -ArgumentList "UNLOAD HKLM\Default" -Wait -PassThru
    }
    # Teams Meeting Add-in
    # Get Teams Meeting Addin Version
    If (-not ($CloudType -eq 5 -or $CloudType -eq 6 -or $CloudType -eq 7)) {
        #https://learn.microsoft.com/en-us/microsoftteams/teams-client-vdi-requirements-deploy#deployment-method-for-non-persistent-environments-where-teams-autoupdate-is-disabled
        $TeamsMeetingAddinInstall = Start-Process -FilePath "$BootStrapperFile" -ArgumentList "--installTMA" -Wait -PassThru
        If ($($TeamsMeetingAddinInstall.ExitCode) -eq 0) {
            Write-Log "Installed Teams Meeting Add-in successfully."
            $TMAInstalled
        }
        Else {
            Write-Log "Teams Meeting Add-in installation failed with exit code $($TeamsMeetingAddinInstall.ExitCode)"
        }
    }
    If (-not $TMAInstalled) {
        Write-Log "Attempting to install the Teams Meeting Add-in via msi installer."
        $TMAPath = "{0}\WindowsApps\MSTeams_{1}_x64__8wekyb3d8bbwe\MicrosoftTeamsMeetingAddInInstaller.msi" -f $env:programfiles, $TeamsVersion    
        If ($TMAPath -and (Test-Path -Path $TMAPath)) {

            Write-Log "Found Teams Meeting Add-in installer at path: $TMAPath"
            $TMAVersion = (Get-AppLockerFileInformation -Path $TMAPath | Select-Object -ExpandProperty Publisher).BinaryVersion
            Write-Log "Found Teams Meeting Addin Version: $TMAVersion"
            # Install parameters
            $TargetDir = "{0}\Microsoft\TeamsMeetingAdd-in\{1}\" -f ${env:ProgramFiles(x86)}, $TMAVersion
            $params = '/i "{0}" TARGETDIR="{1}" /qn ALLUSERS=1' -f $TMAPath, $TargetDir
            # Start the install process
            Write-Log "executing msiexec.exe $params"
            $install = Start-Process -FilePath 'msiexec.exe' -ArgumentList $params -PassThru
            $timeout = 30

            for ($elapsed = 0; $elapsed -lt $timeout; $elapsed++) {
                if ($install.HasExited) {
                    Write-Log "msiexec closed with exit code: $($install.ExitCode)"
                    break
                }
                Start-Sleep -Seconds 1
            }

            if (-not $install.HasExited) {
                Write-Log "msiexec did not exit within $timeout seconds. Terminating process."
                Stop-Process -Id $install.Id -Force
            }
        }
        Else {
            Write-Log "Error: Teams Meeting Add-in installer not found at path: $TMAPath"
        }
    
    }

    If ((Split-Path $TempDir -Parent) -eq $Env:Temp) { Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Log "Completed Installation of all components."
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}