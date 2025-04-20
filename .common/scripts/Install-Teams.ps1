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

function Write-OutputWithTimeStamp {
    param(
        [string]$Message
    )    
    $Timestamp = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
    $Entry = '[' + $Timestamp + '] ' + $Message
    Write-Output $Entry
}

$SoftwareName = 'Teams'
Start-Transcript -Path "$env:SystemRoot\Logs\Install-$SoftwareName.log" -Force
Write-OutputWithTimeStamp "Starting script to install $SoftwareName with the following parameters:"
Write-Output "APIVersion: $APIVersion"
Write-Output "BlobStorageSuffix: $BlobStorageSuffix"
Write-Output "BuildDir: $BuildDir"
Write-Output "UserAssignedIdentityClientId: $UserAssignedIdentityClientId"
Write-Output "TeamsCloudType: $TeamsCloudType"
If ($null -ne $BuildDir -and $BuildDir -ne '') {
    $TempDir = Join-Path $BuildDir -ChildPath $SoftwareName
}
Else {
    $TempDir = Join-Path $Env:TEMP -ChildPath $SoftwareName
}
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null  

[array]$Uris = $Uris.Replace('\"', '"') | ConvertFrom-Json
Write-Output "Uris:"
ForEach ($Uri in $Uris) {
    Write-Output " $Uri"
}
[array]$DestFileNames = $DestFileNames.Replace('\"', '"') | ConvertFrom-Json
Write-Output "DestFileNames:"    
ForEach ($DestFileName in $DestFileNames) {
    Write-Output " $DestFileName"
}
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
    Write-OutputWithTimeStamp "Downloading '$Uri' to '$DestFile'."
    $ErrorActionPreference = 'SilentlyContinue'
    $webClient.DownloadFile($Uri, $DestFile)
    Unblock-File -Path $DestFile
    $ErrorActionPreference = 'Stop'
    $WebClient = $null
}
$BootStrapperFile = Join-Path -Path $TempDir -ChildPath $DestFileNames[0]
If (!(Test-Path -Path $BootStrapperFile)) {
    Write-Error "Failed to download the Teams bootstrapper file."
    Exit 1
}
$MSIXFile = Join-Path -Path $TempDir -ChildPath $DestFileNames[1]
If (!(Test-Path -Path $MSIXFile)) {
    Write-Error "Failed to download the Teams MSIX file."
    Exit 1
}
If ($Uris.Length -gt 2) {
    $WebView2File = Join-Path -Path $TempDir -ChildPath $DestFileNames[2]
    If (!(Test-Path -Path $WebView2File)) {
        Write-OutputWithTimeStamp -Message "Failed to download the WebView2 file."
        $WebView2File = $null
    }    
    $vcRedistFile = Join-Path -Path $TempDir -ChildPath $DestFileNames[3]
    If (!(Test-Path -Path $vcRedistFile)) {
        Write-OutputWithTimeStamp -Message "Failed to download the Visual C++ Redistributable file."
        $vcRedistFile = $null
    }
    $webRTCFile = Join-Path -Path $TempDir -ChildPath $DestFileNames[4]
    If (!(Test-Path -Path $webRTCFile)) {
        Write-OutputWithTimeStamp -Message "Failed to download the WebRTC file."
        $webRTCFile = $null
    }
}
Else {
    $WebView2File = $null
    $vcRedistFile = $null
    $webRTCFile = $null
}

If ($WebView2File -or $vcRedistFile -or $webRTCFile) {
    Write-OutputWithTimeStamp "Starting installation of Teams dependencies."
}
Else {
    Write-OutputWithTimeStamp "No dependencies to install."
}

# Enable media optimizations for Team
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Teams" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Teams" -Name IsWVDEnvironment -PropertyType DWORD -Value 1 -Force | Out-Null

# Check to see if WebView2 is already installed
Write-OutputWithTimeStamp "Checking if WebView2 Runtime is already installed."
If (Test-Path -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') {
    If (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -Name pv -ErrorAction SilentlyContinue) {
        $WebView2Installed = $True
        $InstalledVersion = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -Name pv).pv
        Write-OutputWithTimeStamp "WebView2 Runtime is already installed. Version: $InstalledVersion"
    }
}
If (-not $WebView2Installed -and $null -ne $WebView2File) {
    Write-OutputWithTimeStamp "WebView2 runtime not installed, installing the latest version."
    $WebView2Installer = Start-Process -FilePath $WebView2File -ArgumentList "/silent /install" -Wait -PassThru
    If ($($WebView2Installer.ExitCode) -eq 0 ) {
        Write-OutputWithTimeStamp "Installed the latest version of the Microsoft WebView2 Runtime"
    }
    Else {
        Write-OutputWithTimeStamp "Installion of the Microsoft WebView2 Runtime failed with exit code $($WebView2Installer.ExitCode)"
    }
}
If ($null -ne $vcRedistFile) {
    Write-OutputWithTimeStamp "Installing Microsoft Visual C++ Redistributables."
    $VCRedistInstall = Start-Process -FilePath $vcRedistFile -ArgumentList "/install /passive /norestart" -Wait -PassThru
    If ($VCRedistInstall.ExitCode -eq 0 ) {
        Write-OutputWithTimeStamp "Installed the latest version of Microsoft Visual C++ Redistributable"
    }
    Else {
        Write-OutputWithTimeStamp "Installion of the Microsoft Visual C++ Redistributable failed with exit code $($VCRedistInstall.ExitCode)"
    }
}
If ($null -ne $webRTCFile) {
    Write-OutputWithTimeStamp "Installing the Remote Desktop WebRTC Redirector Service"
    $WebRTCInstall = Start-Process -FilePath msiexec.exe -ArgumentList "/i $webRTCFile /quiet /norestart" -Wait -PassThru
    If ($($WebRTCInstall.ExitCode) -eq 0) {
        Write-OutputWithTimeStamp "Installed the Remote Desktop WebRTC Redirector Service"
    }
    Else {
        Write-OutputWithTimeStamp "Installation of the Remote Desktop WebRTC Redirector Service failed with exit code $($WebRTCInstall.ExitCode)"
    }
}
Write-OutputWithTimeStamp "Starting Teams installation."
$TeamsInstall = Start-Process -FilePath "$BootStrapperFile" -ArgumentList "-p -o `"$MSIXFile`"" -Wait -PassThru
If ($($TeamsInstall.ExitCode) -eq 0) {
    Write-OutputWithTimeStamp "Installed Teams successfully."
}
Else {
    Write-OutputWithTimeStamp "Teams installation failed with exit code $($TeamsInstall.ExitCode)"
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
If ((Split-Path $TempDir -Parent) -eq $Env:Temp) { Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
Write-OutputWithTimeStamp "Completed Installation of all components."
Stop-Transcript