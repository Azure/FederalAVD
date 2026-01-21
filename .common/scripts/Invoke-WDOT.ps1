param(
    [string]$APIVersion,
    [string]$BlobStorageSuffix,
    [string]$BuildDir='',
    [string]$Uri,
    [string]$UserAssignedIdentityClientId
)
$ErrorActionPreference = "Stop"

function Write-OutputWithTimeStamp {
    param(
        [string]$Message
    )    
    $Timestamp = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
    $Entry = '[' + $Timestamp + '] ' + $Message
    Write-Output $Entry
}

$SoftwareName = 'WDOT'
If ($null -eq $Uri -or $Uri -eq '') {
    $Uri = 'https://codeload.github.com/The-Virtual-Desktop-Team/Windows-Desktop-Optimization-Tool/zip/refs/heads/main'
}
If ($BuildDir -ne '') {
    $TempDir = Join-Path $BuildDir -ChildPath $SoftwareName
}
Else {
    $TempDir = Join-Path $Env:TEMP -ChildPath $SoftwareName
}
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null  

Start-Transcript -Path "$env:SystemRoot\Logs\$SoftwareName.log" -Force
Write-OutputWithTimeStamp "Starting '$SoftwareName' script with the following parameters:"
Write-Output ( $PSBoundParameters | Format-Table -AutoSize )

$WebClient = New-Object System.Net.WebClient
If ($Uri -match $BlobStorageSuffix -and $UserAssignedIdentityClientId -ne '') {
    $StorageEndpoint = ($Uri -split "://")[0] + "://" + ($Uri -split "/")[2] + "/"
    $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=$APIVersion&resource=$StorageEndpoint&client_id=$UserAssignedIdentityClientId"
    $AccessToken = ((Invoke-WebRequest -Headers @{Metadata = $true } -Uri $TokenUri -UseBasicParsing).Content | ConvertFrom-Json).access_token
    $WebClient.Headers.Add('x-ms-version', '2017-11-09')
    $webClient.Headers.Add("Authorization", "Bearer $AccessToken")
}
$DestFile = Join-Path -Path $TempDir -ChildPath 'WDOT.zip'
Write-OutputWithTimeStamp "Downloading '$Uri' to '$DestFile'."
$webClient.DownloadFile("$Uri", "$DestFile")
Start-Sleep -seconds 5
If (!(Test-Path -Path $DestFile)) { Write-Error "Failed to download $Uri"; Exit 1 }
Unblock-File -Path $DestFile
Expand-Archive -LiteralPath $DestFile -DestinationPath $TempDir -Force
$NewConfigScriptPath = (Get-ChildItem -Path $TempDir -Recurse | Where-Object { $_.Name -eq "New-WVDConfigurationFiles.ps1" }).FullName
& $NewConfigScriptPath -FolderName 'AVD'
Write-OutputWithTimeStamp "Created new WDOT configuration files for AVD"
$ScriptPath = (Get-ChildItem -Path $TempDir -Recurse | Where-Object { $_.Name -eq "Windows_Optimization.ps1" }).FullName
If ($null -eq $ScriptPath) { Write-Error "Failed to find the script in the downloaded archive"; Exit 1 }
$ScriptContents = Get-Content -Path $ScriptPath
$ScriptUpdate = $ScriptContents.Replace("Set-NetAdapterAdvancedProperty", "#Set-NetAdapterAdvancedProperty")
$ScriptUpdate | Set-Content -Path $ScriptPath
& $ScriptPath -ConfigProfile 'AVD' -Optimizations @("Autologgers", "DefaultUserSettings", "LocalPolicy", "NetworkOptimizations", "ScheduledTasks", "Services", "WindowsMediaPlayer") -AdvancedOptimizations @("Edge", "RemoveLegacyIE") -AcceptEULA
Write-OutputWithTimeStamp "Optimized the operating system using the Windows Desktop Optimization Tool"
If ((Split-Path $TempDir -Parent) -eq $Env:Temp) { Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
Stop-Transcript