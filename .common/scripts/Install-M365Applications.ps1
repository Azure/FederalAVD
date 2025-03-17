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
Function Get-InternetUrl {
    [CmdletBinding()]
    Param (
        [Parameter(
            Mandatory,
            HelpMessage = "Specifies the website that contains a link to the desired download."
        )]
        [uri]$WebSiteUrl,

        [Parameter(
            Mandatory,
            HelpMessage = "Specifies the search string. Wildcard '*' can be used."    
        )]
        [string]$SearchString
    )

    $HTML = Invoke-WebRequest -Uri $WebSiteUrl -UseBasicParsing
    $Links = $HTML.Links
    #First try to find search string in actual link href
    $LinkHref = $HTML.Links.Href | Get-Unique | Where-Object { $_ -like "*$SearchString*" }
    If ($LinkHref) {
        Return $LinkHref
    }
    #If not found, try to find search string in the outer html
    $LinkHrefs = $Links | Where-Object { $_.OuterHTML -like "*$SearchString*" }
    If ($LinkHrefs) {
        Return $LinkHrefs.href
    }
    Return $null
}

function Write-OutputWithTimeStamp {
    param(
        [string]$Message
    )    
    $Timestamp = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
    $Entry = '[' + $Timestamp + '] ' + $Message
    Write-Output $Entry
}

$SoftwareName = 'Microsoft-365-Applications'
Start-Transcript -Path "$env:SystemRoot\Logs\Install-$SoftwareName.log" -Force
Write-OutputWithTimeStamp "Starting Script to install '$SoftwareName' with the following parameters:"
Write-Output ( $PSBoundParameters | Format-Table -AutoSize )

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
Write-OutputWithTimeStamp "Downloading '$Uri' to '$DestFile'."
$webClient.DownloadFile("$Uri", "$DestFile")
Start-Sleep -Seconds 5
If (!(Test-Path -Path $DestFile)) { Write-Error "Failed to download $SourceFileName"; Exit 1 }
Write-OutputWithTimeStamp "Finished downloading"
If ($Environment -ne 'ussec' -and $Environment -ne 'usnat') {
    Write-OutputWithTimeStamp "Extracting the Office 365 Deployment Toolkit."
    Start-Process -FilePath $destFile -ArgumentList "/extract:`"$TempDir\ODT`" /quiet /passive /norestart" -Wait -PassThru | Out-Null
    $Setup = (Get-ChildItem -Path "$TempDir\ODT" -Filter '*setup*.exe').FullName
    Write-OutputWithTimeStamp "Found Office Deployment Tool Setup Executable - '$Setup'."
}
Else {
    $Setup = $DestFile
}
Write-OutputWithTimeStamp "Dynamically creating $SoftwareName configuration file for setup."
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
If ($Environment -eq 'ussec') {
    $Content += '  <Add AllowCdnFallback="TRUE" SourcePath="https://officexo.azurefd.microsoft.scloud/prsstelecontainer/55336b82-a18d-4dd6-b5f6-9e5095c314a6/" Channel="MonthlyEnterprise" OfficeClientEdition="64">'

}
Elseif ($Environment -eq 'usnat') {
    $Content += '  <Add AllowCdnFallback="TRUE" SourcePath="https://officexo.azurefd.eaglex.ic.gov/prsstelecontainer/55336b82-a18d-4dd6-b5f6-9e5095c314a6/" Channel="MonthlyEnterprise" OfficeClientEdition="64">'
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
Write-OutputWithTimeStamp "Config File Content:"
Write-OutputWithTimeStamp "---------------------------------------------------------------------------------------------------------"
$ConfigFileContent = Get-Content -Path $ConfigFile
Write-Output $ConfigFileContent
Write-OutputWithTimeStamp "---------------------------------------------------------------------------------------------------------"
Write-OutputWithTimeStamp "Starting setup process."
$Install = Start-Process -FilePath $Setup -ArgumentList "/configure `"$ConfigFile`"" -Wait -PassThru -ErrorAction "Stop"
If ($($Install.ExitCode) -eq 0) {
    Write-OutputWithTimeStamp "'$SoftwareName' installed successfully."
}
Else {
    Write-Error "'$SoftwareName' install exit code is $($Install.ExitCode)"
}
If ((Split-Path $TempDir -Parent) -eq $Env:Temp) { Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
Stop-Transcript