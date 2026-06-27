param(
    [string]$APIVersion,
    [string]$BlobStorageSuffix,
    [string]$BuildDir='',
    [string]$UserAssignedIdentityClientId,
    [string]$Uri
)

$ErrorActionPreference = "Stop"
$Name = 'FSLogix'
$LogFile = "$env:SystemRoot\Logs\Install-$Name.log"

function Write-Log {
    param([string]$Message)
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

try {
    Write-Log "Starting '$SoftwareName' install script with following Parameters:"
    Write-Log ($PSBoundParameters | Format-Table -AutoSize | Out-String)

    If ($BuildDir -ne '') {
        $TempDir = Join-Path $BuildDir -ChildPath $Name
    }
    Else {
        $TempDir = Join-Path $Env:TEMP -ChildPath $Name
    }
    New-Item -Path $TempDir -ItemType Directory -Force | Out-Null
    # Force TLS 1.2  -  fresh marketplace images default to TLS 1.0/1.1 which Azure Storage rejects.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $WebClient = New-Object System.Net.WebClient
    If ($Uri -match $BlobStorageSuffix -and $UserAssignedIdentityClientId -ne '') {
        $StorageEndpoint = ($Uri -split "://")[0] + "://" + ($Uri -split "/")[2] + "/"
        $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=$APIVersion&resource=$StorageEndpoint&client_id=$UserAssignedIdentityClientId"
        $AccessToken = ((Invoke-WebRequest -Headers @{Metadata = $true } -Uri $TokenUri -UseBasicParsing).Content | ConvertFrom-Json).access_token
        $WebClient.Headers.Add('x-ms-version', '2017-11-09')
        $webClient.Headers.Add("Authorization", "Bearer $AccessToken")
    }
    $DestFile = Join-Path -Path $TempDir -ChildPath 'FSLogix.zip'
    Write-Log "Downloading 'FSLogix.zip' from '$uri' to '$DestFile'."
    $webClient.DownloadFile("$Uri", "$DestFile")
    Start-Sleep -seconds 10
    If (!(Test-Path -Path $DestFile)) { Write-Log "Failed to download $SourceFileName"; Exit 1 }
    Unblock-File -Path $DestFile
    Write-Log "Extracting Contents of Zip File"
    Expand-Archive -Path $destFile -DestinationPath $TempDir -Force
    $Installer = (Get-ChildItem -Path $TempDir -File -Recurse -Filter 'FSLogixAppsSetup.exe' | Where-Object { $_.FullName -like '*x64*' }).FullName
    Write-Log "Installation file found: [$Installer], executing installation."
    $Install = Start-Process -FilePath $Installer -ArgumentList "/install /quiet /norestart" -Wait -PassThru
    If ($($Install.ExitCode) -eq 0) {
        Write-Log "'Microsoft FSLogix Apps' installed successfully."
    }
    Else {
        Write-Log "The Install exit code is $($Install.ExitCode)"
        Exit 1
    }
    Write-Log "Copying the FSLogix ADMX and ADML files to the PolicyDefinitions folders."
    Get-ChildItem -Path $TempDir -File -Recurse -Filter '*.admx' | ForEach-Object { Write-Log "Copying $($_.Name)"; Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\" -Force }
    Get-ChildItem -Path $TempDir -File -Recurse -Filter '*.adml' | ForEach-Object { Write-Log "Copying $($_.Name)"; Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\en-us\" -Force }
    If ((Split-Path $TempDir -Parent) -eq $Env:Temp) { Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Log "Installation complete."
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}