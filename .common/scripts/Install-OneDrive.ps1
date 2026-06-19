param(
    [string]$APIVersion,
    [string]$BlobStorageSuffix,
    [string]$BuildDir = '',
    [string]$UserAssignedIdentityClientId,
    [string]$Uri
)

$ErrorActionPreference = "Stop"

$SoftwareName = 'OneDrive'
$LogFile = "$env:SystemRoot\Logs\Install-$SoftwareName.log"

function Write-Log {
    param([string]$Message)
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

try {
    Write-Log "Starting Script to install '$SoftwareName' with the following parameters:"
    Write-Log ($PSBoundParameters | Format-Table -AutoSize | Out-String)

If ($BuildDir -ne '') {
    $TempDir = Join-Path $BuildDir -ChildPath $SoftwareName
}
Else {
    $TempDir = Join-Path $Env:TEMP -ChildPath $SoftwareName
}
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null 

$RegPath = 'HKLM:\SOFTWARE\Microsoft\OneDrive'
If (Test-Path -Path $RegPath) {
    If (Get-ItemProperty -Path $RegPath -Name AllUsersInstall -ErrorAction SilentlyContinue) {
        $AllUsersInstall = Get-ItemPropertyValue -Path $RegPath -Name AllUsersInstall
    }
}
If ($AllUsersInstall -eq '1') {
    Write-Log "$SoftwareName is already setup per-machine. Quiting."
}
Else {
    Write-Log "Starting '$SoftwareName' install script with following Parameters:"
    Write-Log ($PSBoundParameters | Format-Table -AutoSize | Out-String)
    # Force TLS 1.2 — fresh marketplace images default to TLS 1.0/1.1 which Azure Storage rejects.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $WebClient = New-Object System.Net.WebClient
    If ($Uri -match $BlobStorageSuffix -and $UserAssignedIdentityClientId -ne '') {
        $StorageEndpoint = ($Uri -split "://")[0] + "://" + ($Uri -split "/")[2] + "/"
        $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=$APIVersion&resource=$StorageEndpoint&client_id=$UserAssignedIdentityClientId"
        $AccessToken = ((Invoke-WebRequest -Headers @{Metadata = $true } -Uri $TokenUri -UseBasicParsing).Content | ConvertFrom-Json).access_token
        $WebClient.Headers.Add('x-ms-version', '2017-11-09')
        $webClient.Headers.Add("Authorization", "Bearer $AccessToken")
    }
    $DestFile = Join-Path -Path $TempDir -ChildPath 'OneDriveSetup.exe'
    Write-Log "Downloading 'OneDriveSetup.exe' from '$Uri' to '$DestFile'."
    $webClient.DownloadFile("$Uri", "$DestFile")
    Start-Sleep -Seconds 5
    If (!(Test-Path -Path $DestFile)) { Write-Log "Failed to download $SourceFileName"; Exit 1 }
    $OneDriveSetup = $DestFile
    #Find existing OneDriveSetup
    $RegPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe'
    If (Test-Path -Path $RegPath) {
        Write-Log "Found Per-Machine Installation, determining uninstallation command."
        If (Get-ItemProperty -Path $RegPath -name UninstallString -ErrorAction SilentlyContinue) {
            $UninstallString = (Get-ItemPropertyValue -Path $RegPath -Name UninstallString).toLower()
            $OneDriveSetupindex = $UninstallString.IndexOf('onedrivesetup.exe') + 17
            $Uninstaller = $UninstallString.Substring(0, $OneDriveSetupindex)
            $Arguments = $UninstallString.Substring($OneDriveSetupindex).replace('  ', ' ').trim()
        }
    }
    Else {
        $Uninstaller = $OneDriveSetup
        $Arguments = '/uninstall'
    }    
    # Uninstall existing version
    Write-Log "Running [$Uninstaller $Arguments] to remove any existing versions."
    Start-Process -FilePath $Uninstaller -ArgumentList $Arguments
    If (get-process onedrivesetup) { Wait-Process -Name OneDriveSetup }
    # Set OneDrive for All Users Install
    Write-Log "Setting registry values to indicate a per-machine (AllUsersInstall)"
    New-Item -Path "HKLM:\SOFTWARE\Microsoft\OneDrive" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\OneDrive" -Name AllUsersInstall -PropertyType DWORD -Value 1 -Force | Out-Null
    $Install = Start-Process -FilePath $OneDriveSetup -ArgumentList '/allusers' -Wait -Passthru
    If ($($Install.ExitCode) -eq 0) {
        Write-Log "'$SoftwareName' installed successfully."
    }
    Else {
        Write-Log "'$SoftwareName' install exit code is $($Install.ExitCode)"
        Exit 1
    }
    Write-Log "Configuring OneDrive to startup for each user upon logon."
    New-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name OneDrive -PropertyType String -Value 'C:\Program Files\Microsoft OneDrive\OneDrive.exe /background' -Force | Out-Null
    Write-Log "Installed OneDrive Per-Machine"
    If ((Split-Path $TempDir -Parent) -eq $Env:Temp) { Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
}
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}