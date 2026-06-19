param(
    [string]$APIVersion,
    [string]$AppsToInstall,
    [string]$BlobStorageSuffix,
    [string]$BuildDir='',
    [string]$Environment,
    [string]$Uri,
    [string]$UserAssignedIdentityClientId
)
$ErrorActionPreference = "Stop"

$EnvSuffix = $BlobStorageSuffix.Substring(10, ($BlobStorageSuffix.length - 10))

$SoftwareName = 'Microsoft-365-Applications'
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

If ($AppsToInstall -ne '' -and $null -ne $AppsToInstall) {
    [array]$AppsToInstall = $AppsToInstall.Replace('\"', '"') | ConvertFrom-Json
}
Else {
    [array]$AppsToInstall = @("Access", "Excel", "OneNote", "Outlook", "PowerPoint", "Word")
}

If ($BuildDir -ne '') {
    $TempDir = Join-Path $BuildDir -ChildPath $SoftwareName
}
Else {
    $TempDir = Join-Path $Env:TEMP -ChildPath $SoftwareName
}
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null  
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
$SourceFileName = ($Uri -Split "/")[-1]
$DestFile = Join-Path -Path $TempDir -ChildPath $SourceFileName
Write-Log "Downloading '$Uri' to '$DestFile'."
$webClient.DownloadFile("$Uri", "$DestFile")
Start-Sleep -Seconds 5
If (!(Test-Path -Path $DestFile)) { Write-Log "Failed to download $SourceFileName"; Exit 1 }
Write-Log "Finished downloading"
$Setup = $DestFile

Write-Log "Dynamically creating $SoftwareName configuration file for setup."
$ConfigFile = Join-Path -Path $TempDir -ChildPath 'office365x64.xml'
[array]$Content = @()
[array]$ExcludedApps = @()
$ExcludedApps += '      <ExcludeApp ID="Groove" />'
$ExcludedApps += '      <ExcludeApp ID="OneDrive" />'
$ExcludedApps += '      <ExcludeApp ID="Teams" />'
if ($AppsToInstall -notcontains 'Access') {
    $ExcludedApps += '      <ExcludeApp ID="Access" />'
}
if ($AppsToInstall -notcontains 'Excel') {
    $ExcludedApps += '      <ExcludeApp ID="Excel" />'
}
if ($AppsToInstall -notcontains 'OneNote') {
    $ExcludedApps += '      <ExcludeApp ID="OneNote" />'
}
if ($AppsToInstall -notcontains 'Outlook') {
    $ExcludedApps += '      <ExcludeApp ID="Outlook" />'
}
if ($AppsToInstall -notcontains 'PowerPoint') {
    $ExcludedApps += '      <ExcludeApp ID="PowerPoint" />'
}
if ($AppsToInstall -notcontains 'Publisher') {
    $ExcludedApps += '      <ExcludeApp ID="Publisher" />'
}
if ($AppsToInstall -notcontains 'SkypeForBusiness') {
    $ExcludedApps += '      <ExcludeApp ID="Lync" />'
}
if ($AppsToInstall -notcontains 'Word') {
    $ExcludedApps += '      <ExcludeApp ID="Word" />'
}

$Content += '<Configuration>'
If ($Environment -match '^us') {
    $Content += '  <Add AllowCdnFallback="TRUE" SourcePath="https://officexo.azurefd.' + $EnvSuffix + '/prsstelecontainer/55336b82-a18d-4dd6-b5f6-9e5095c314a6/" Channel="MonthlyEnterprise" OfficeClientEdition="64">'
}
Else {
    $Content += '  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise">'
}

If ($AppsToInstall -contains 'Access' -or $AppsToInstall -contains 'Excel' -or $AppsToInstall -contains 'OneNote' -or $AppsToInstall -contains 'Outlook' -or $AppsToInstall -contains 'PowerPoint' -or $AppsToInstall -contains 'Publisher' -or $AppsToInstall -contains 'Word') {
    $Content += '    <Product ID="O365ProPlusRetail">'
    $Content += '      <Language ID="en-us" />'
    $Content += $ExcludedApps
    $Content += '    </Product>'
}
if ($AppsToInstall -contains 'Project') {
    $Content += '    <Product ID="ProjectProRetail">'
    $Content += '      <Language ID="en-us" />'
    $Content += $ExcludedApps
    $Content += '    </Product>'
}
if ($AppsToInstall -contains 'Visio') {
    $Content += '    <Product ID="VisioProRetail">'
    $Content += '      <Language ID="en-us" />'
    $Content += $ExcludedApps
    $Content += '    </Product>'
}
$Content += '  </Add>'
$Content += '  <Property Name="SharedComputerLicensing" Value="1" />'
$Content += '  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />'
$Content += '  <Updates Enabled="FALSE" />'
$Content += '  <Display Level="None" AcceptEULA="TRUE" />'
$Content += '</Configuration>'
Add-Content -Path $ConfigFile -Value $Content
Write-Log "Config File Content:"
Write-Log "---------------------------------------------------------------------------------------------------------"
$ConfigFileContent = Get-Content -Path $ConfigFile
Write-Log $ConfigFileContent
Write-Log "---------------------------------------------------------------------------------------------------------"
Write-Log "Starting setup process."
Write-Log "Command Line: $Setup /configure `"$ConfigFile`""
$Install = Start-Process -FilePath $Setup -ArgumentList "/configure `"$ConfigFile`"" -Wait -PassThru -ErrorAction "Stop"
If ($($Install.ExitCode) -eq 0) {
    Write-Log "'$SoftwareName' installed successfully."
}
Else {
    Write-Log "'$SoftwareName' install exit code is $($Install.ExitCode)"
    Exit 1
}
If ((Split-Path $TempDir -Parent) -eq $Env:Temp) { Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}