<#
.SYNOPSIS
Downloads the latest software sources, packages them as zip files, and uploads them to the
image management artifacts storage account blob container.

.DESCRIPTION
Run this script whenever you want to refresh the artifacts in the image management storage account —
for example, after adding new software packages or after new versions are released.

This script does NOT deploy any Azure infrastructure. Deploy the imageManagement Bicep template
first (see deployments/imageManagement/README.md), then use this script to populate the storage
account with artifacts.

.PARAMETER StorageAccountResourceId
The full resource ID of the image management artifacts storage account.
Obtain this from the imageManagement deployment output 'artifactsStorageAccountResourceId'.
Mutually exclusive with -StorageAccountName / -ResourceGroupName.

Example:
  /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-avd-image-management-use2/providers/Microsoft.Storage/storageAccounts/saimgassetsuse2abc123

.PARAMETER StorageAccountName
The name of the image management artifacts storage account.
Must be used together with -ResourceGroupName.
Mutually exclusive with -StorageAccountResourceId.

.PARAMETER ResourceGroupName
The resource group containing the artifacts storage account.
Must be used together with -StorageAccountName.
Mutually exclusive with -StorageAccountResourceId.

.PARAMETER DeleteExistingBlobs
When specified, removes all existing blobs in the artifacts container before uploading.
Use this when you want a clean slate rather than an incremental update.

.PARAMETER SkipDownloadingNewSources
When specified, skips downloading new software versions from the internet.
Use this in air-gapped environments or when the artifacts directory already contains
the correct content and you just want to re-upload.

.PARAMETER ParameterFilePrefix
Custom prefix for the downloads parameter file.
Overrides the automatic environment detection (public / secret / topsecret).
Example: 'contoso' resolves to 'deployments/imageManagement/parameters/contoso.downloads.parameters.json'

.PARAMETER TempDir
Temporary directory used during artifact packaging. Defaults to $Env:Temp.
Use a path on a high-performance drive when processing large artifact sets.

.EXAMPLE
# Standard update using resource ID
.\Update-ImageArtifacts.ps1 -StorageAccountResourceId "/subscriptions/.../storageAccounts/saimgassetsuse2abc123"

.EXAMPLE
# Standard update using storage account name and resource group
.\Update-ImageArtifacts.ps1 -StorageAccountName "saimgassetsuse2abc123" -ResourceGroupName "rg-avd-image-management-use2"

.EXAMPLE
# Air-gapped update — skip internet downloads, just re-package and upload existing artifacts
.\Update-ImageArtifacts.ps1 `
    -StorageAccountName "saimgassetsuse2abc123" `
    -ResourceGroupName "rg-avd-image-management-use2" `
    -SkipDownloadingNewSources

.EXAMPLE
# Clean upload — delete existing blobs first, then upload fresh
.\Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId "/subscriptions/.../storageAccounts/saimgassetsuse2abc123" `
    -DeleteExistingBlobs

.EXAMPLE
# Custom parameter file prefix (useful for multiple environments)
.\Update-ImageArtifacts.ps1 `
    -StorageAccountName "saimgassetsuse2abc123" `
    -ResourceGroupName "rg-avd-image-management-use2" `
    -ParameterFilePrefix "production"
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByResourceId')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
    [string]$StorageAccountResourceId,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [switch]$DeleteExistingBlobs,

    [Parameter(Mandatory = $false)]
    [switch]$SkipDownloadingNewSources,

    [Parameter(Mandatory = $false)]
    [string]$ParameterFilePrefix,

    [Parameter(Mandatory = $false)]
    [string]$TempDir = "$Env:Temp"
)

#region Variables
$ErrorActionPreference = 'Stop'
$ScriptStartTime = Get-Date

$Context = Get-AzContext
If ($null -eq $Context) {
    Throw 'You are not logged in to Azure. Please run Connect-AzAccount before continuing.'
}

$Environment = $Context.Environment.Name
$StorageEndpointSuffix = $Context.Environment.StorageEndpointSuffix
$EnvSuffix = $StorageEndpointSuffix.Substring(5, ($StorageEndpointSuffix.Length - 5))

If ($ParameterFilePrefix -ne '' -and $null -ne $ParameterFilePrefix) {
    Write-Output "Using custom parameter file prefix: '$ParameterFilePrefix'."
    $downloadsParametersPrefix = $ParameterFilePrefix
}
Else {
    If ($Environment -eq 'AzureCloud' -or $Environment -eq 'AzureUSGovernment') {
        $downloadsParametersPrefix = 'public'
    }
    ElseIf ($Environment -match 'USN') {
        $downloadsParametersPrefix = 'topsecret'
    }
    Else {
        $downloadsParametersPrefix = 'secret'
    }
}

$ArtifactsContainerName = 'artifacts'
$TempArtifactsDir = Join-Path -Path $TempDir -ChildPath 'Artifacts'
$ArtifactsDir = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\.common\artifacts')).FullName

If (Test-Path -Path $TempArtifactsDir) {
    Remove-Item -Path $TempArtifactsDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -Path $TempArtifactsDir -ItemType Directory -Force | Out-Null

# Resolve storage account name and resource group from whichever parameter set was used
If ($PSCmdlet.ParameterSetName -eq 'ByResourceId') {
    $SubscriptionId = ($StorageAccountResourceId -Split '/')[2]
    If ((Get-AzContext).Subscription.Id -ne $SubscriptionId) {
        Write-Output "Switching to subscription '$SubscriptionId'."
        Set-AzContext -Subscription $SubscriptionId
    }
    $StorageAccountResourceGroup = ($StorageAccountResourceId -Split '/')[4]
    $StorageAccountName = ($StorageAccountResourceId -Split '/')[-1]
}
Else {
    $StorageAccountResourceGroup = $ResourceGroupName
}
$BlobEndpoint = (Get-AzStorageAccount -ResourceGroupName $StorageAccountResourceGroup -StorageAccountName $StorageAccountName).PrimaryEndpoints.Blob
$ArtifactsContainerUrl = $BlobEndpoint + $ArtifactsContainerName + '/'

Write-Output "Storage account : $StorageAccountName"
Write-Output "Resource group  : $StorageAccountResourceGroup"
Write-Output "Container URL   : $ArtifactsContainerUrl"
#endregion Variables

Write-Output ("[{0} entered]" -f $MyInvocation.MyCommand)

#region Functions
function Get-MsiInfo {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$True, ValueFromPipeline=$true)]
        [IO.FileInfo[]]$Path,
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$Property
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        Write-Verbose "${CmdletName}: Starting with [$PSBoundParameters]"
        $winInstaller = New-Object -ComObject WindowsInstaller.Installer
    }
    Process {
        try {
            Write-Verbose "${CmdletName}: Opening MSIFile: $Path"
            $msiDb = $winInstaller.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $winInstaller, @($Path.FullName, 0))
            if ($Property) {
                Write-Verbose "${CmdletName}: Property: $Property specified"
                $propQuery = 'WHERE ' + (($Property | ForEach-Object { "Property = '$($_)'" }) -join ' OR ')
            }
            $query = ("SELECT Property,Value FROM Property {0}" -f ($propQuery))
            $view = $msiDb.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $msiDb, ($query))
            $null = $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            $msiInfo = [PSCustomObject]@{ 'File' = $Path }
            do {
                $null = $view.GetType().InvokeMember('ColumnInfo', 'GetProperty', $null, $view, 0)
                $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                if (-not $record) { break }
                $propName = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 1) | Select-Object -First 1
                $value    = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 2) | Select-Object -First 1
                $msiInfo  = $msiInfo | Add-Member -MemberType NoteProperty -Name $propName -Value $value -PassThru
            } while ($true)
            $null = $msiDb.GetType().InvokeMember('Commit', 'InvokeMethod', $null, $msiDb, $null)
            $null = $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
            $msiInfo
        }
        catch {
            Write-Error $_
            Write-Error $_.ScriptStackTrace
        }
    }
    End {
        try {
            $null = [Runtime.Interopservices.Marshal]::ReleaseComObject($winInstaller)
            [GC]::Collect()
        }
        catch {
            Write-Error 'Failed to release Windows Installer COM reference'
            Write-Error $_
        }
    }
}

function Get-InternetUrl {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory, HelpMessage = "Specifies the website that contains a link to the desired download.")]
        [uri]$WebSiteUrl,
        [Parameter(Mandatory, HelpMessage = "Specifies the search string. Wildcard '*' can be used.")]
        [string]$SearchString
    )
    $HTML = Invoke-WebRequest -Uri $WebSiteUrl -UseBasicParsing
    $Links = $HTML.Links
    $LinkHref = $HTML.Links.Href | Get-Unique | Where-Object { $_ -like $SearchString }
    If ($LinkHref) {
        if ($LinkHref.Contains('http://') -or $LinkHref.Contains('https://')) {
            Return $LinkHref
        }
        Else {
            Return $WebSiteUrl.AbsoluteUri + $LinkHref
        }
    }
    $LinkHref = $Links | Where-Object { $_.OuterHTML -like $SearchString }
    If ($LinkHref) {
        Return $LinkHref.href
    }
    $escapedPattern = [Regex]::Escape($SearchString) -replace '\\\*', '[^"''\s>]*'
    $regex = "https?://[^""'\s>]*$escapedPattern"
    Return ([regex]::Matches($html.Content, $regex)).Value
}

Function Get-InternetFile {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [uri]$Url,
        [Parameter(Mandatory = $true, Position = 1)]
        [string]$OutputDirectory,
        [Parameter(Mandatory = $false, Position = 2)]
        [string]$OutputFileName
    )
    Begin {
        $ProgressPreference = 'SilentlyContinue'
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    }
    Process {
        $start_time = Get-Date
        If (!$OutputFileName) {
            Write-Verbose "${CmdletName}: No OutputFileName specified. Trying to get file name from URL."
            If ((Split-Path -Path $Url -Leaf).Contains('.')) {
                $OutputFileName = Split-Path -Path $Url -Leaf
                Write-Verbose "${CmdletName}: Url contains file name - '$OutputFileName'."
            }
            Else {
                Write-Verbose "${CmdletName}: Url does not contain file name. Trying 'Location' Response Header."
                $request = [System.Net.WebRequest]::Create($Url)
                $request.AllowAutoRedirect = $false
                $response = $request.GetResponse()
                $Location = $response.GetResponseHeader("Location")
                If ($Location) {
                    $OutputFileName = [System.IO.Path]::GetFileName($Location)
                    Write-Verbose "${CmdletName}: File Name from 'Location' Response Header is '$OutputFileName'."
                }
                Else {
                    Write-Verbose "${CmdletName}: No 'Location' Response Header returned. Trying 'Content-Disposition' Response Header."
                    $result = Invoke-WebRequest -Method GET -Uri $Url -UseBasicParsing
                    $contentDisposition = $result.Headers.'Content-Disposition'
                    If ($contentDisposition) {
                        $OutputFileName = $contentDisposition.Split("=")[1].Replace('"', '')
                        Write-Verbose "${CmdletName}: File Name from 'Content-Disposition' Response Header is '$OutputFileName'."
                    }
                }
            }
        }
        If ($OutputFileName) {
            $wc = New-Object System.Net.WebClient
            $OutputFile = Join-Path $OutputDirectory $OutputFileName
            If (Test-Path -Path $OutputFile) { Remove-Item -Path $OutputFile -Force }
            Write-Verbose "${CmdletName}: Downloading file at '$Url' to '$OutputFile'."
            Try {
                $wc.DownloadFile($Url, $OutputFile)
                $time = (Get-Date).Subtract($start_time).Seconds
                if (Test-Path -Path $OutputFile) {
                    $totalSize = [math]::Round((Get-Item $OutputFile).Length / 1MB, 1)
                    Write-Output "${CmdletName}: Downloaded '$OutputFileName' ($totalSize MB) in $time seconds."
                    $OutputFile
                }
            }
            Catch {
                Write-Error "${CmdletName}: Error downloading file. Please check url."
                Exit 2
            }
        }
        Else {
            Write-Error "${CmdletName}: No OutputFileName specified. Unable to download file."
            Exit 2
        }
    }
    End {}
}

function ConvertTo-LongSafePath {
    param([string] $Path)
    $trimmed = $Path.TrimEnd('\')
    if ($trimmed.StartsWith('\\?\')) { return $trimmed }
    if (-not [System.IO.Path]::IsPathRooted($trimmed)) {
        throw "ConvertTo-LongSafePath requires an absolute path. Received: '$trimmed'"
    }
    if ($trimmed.StartsWith('\\')) {
        return "\\?\UNC\" + $trimmed.Substring(2)
    }
    return "\\?\" + $trimmed
}

function Remove-LongSafePrefix {
    param([string] $Path)
    if ($Path.StartsWith('\\?\UNC\')) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\'))     { return $Path.Substring(4) }
    return $Path
}

function Compress-SubFolderContents {
    [CmdletBinding(SupportsShouldProcess = $True)]
    param(
        [Parameter(Mandatory, HelpMessage = "Specifies the location containing subfolders to be compressed.")]
        [string] $SourceFolderPath,
        [Parameter(Mandatory, HelpMessage = "Specifies the location for the .zip files.")]
        [string] $DestinationFolderPath,
        [Parameter(Mandatory = $false)]
        [ValidateSet("Optimal", "Fastest", "NoCompression")]
        [string] $CompressionLevel = "Fastest"
    )
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $compressionLevelEnum = switch ($CompressionLevel) {
            "Optimal"       { [System.IO.Compression.CompressionLevel]::Optimal }
            "Fastest"       { [System.IO.Compression.CompressionLevel]::Fastest }
            "NoCompression" { [System.IO.Compression.CompressionLevel]::NoCompression }
        }
        if (!(Test-Path -Path $SourceFolderPath)) {
            throw "Source folder not found: '$SourceFolderPath'"
        }
        if (!(Test-Path -Path $DestinationFolderPath)) {
            New-Item -ItemType Directory -Path $DestinationFolderPath | Out-Null
        }
        $subfolders = Get-ChildItem -Path $SourceFolderPath -Directory
        foreach ($sf in $subfolders) {
            try {
                $destinationFilePath = Join-Path -Path $DestinationFolderPath -ChildPath ($sf.Name + ".zip")
                $tempFilePath        = $destinationFilePath + ".tmp"
                $safeTempFilePath    = ConvertTo-LongSafePath $tempFilePath
                Write-Output "Compressing '$($sf.Name)'..."
                Write-Verbose "Archive will be created from: $($sf.FullName)"
                Write-Verbose "Archive will be stored as: $destinationFilePath"
                $baseFullName = (Remove-LongSafePrefix $sf.FullName).TrimEnd('\')
                $baseLen      = $baseFullName.Length + 1
                $zipArchive   = $null
                $failedFiles  = [System.Collections.Generic.List[string]]::new()
                if ($PSCmdlet.ShouldProcess($destinationFilePath, "Create archive from $($sf.FullName)")) {
                    if (Test-Path -Path $tempFilePath) { Remove-Item -Path $tempFilePath -Force }
                    $zipArchive = [System.IO.Compression.ZipFile]::Open(
                        $safeTempFilePath,
                        [System.IO.Compression.ZipArchiveMode]::Create
                    )
                    try {
                        Get-ChildItem -Path $sf.FullName -Directory -Recurse -Force |
                        Where-Object {
                            -not [System.IO.Directory]::EnumerateFiles(
                                (ConvertTo-LongSafePath $_.FullName), '*', 'AllDirectories'
                            ).GetEnumerator().MoveNext()
                        } |
                        ForEach-Object {
                            $normalFull  = (Remove-LongSafePrefix $_.FullName).TrimEnd('\')
                            $relativeDir = ($normalFull.Substring($baseLen) -replace '\\', '/') + '/'
                            $zipArchive.CreateEntry($relativeDir) | Out-Null
                        }
                        Get-ChildItem -Path $sf.FullName -File -Recurse -Force | ForEach-Object {
                            $filePath = $_.FullName
                            try {
                                $longSafePath = ConvertTo-LongSafePath $filePath
                                $normalFull   = (Remove-LongSafePrefix $filePath).TrimEnd('\')
                                $relativePath = $normalFull.Substring($baseLen) -replace '\\', '/'
                                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                                    $zipArchive, $longSafePath, $relativePath, $compressionLevelEnum
                                ) | Out-Null
                            }
                            catch {
                                $failedFiles.Add($filePath)
                                Write-Error "Failed to add file '$filePath': $_"
                            }
                        }
                    }
                    finally {
                        if ($null -ne $zipArchive) { $zipArchive.Dispose(); $zipArchive = $null }
                    }
                    if ($failedFiles.Count -gt 0) {
                        Remove-Item -Path $tempFilePath -Force -ErrorAction SilentlyContinue
                        throw "Archive for '$($sf.Name)' is incomplete — $($failedFiles.Count) file(s) could not be added."
                    }
                    if (Test-Path -Path $destinationFilePath) { Remove-Item -Path $destinationFilePath -Force }
                    Move-Item -Path $tempFilePath -Destination $destinationFilePath
                    Write-Output "Compression completed: '$($sf.Name)'"
                }
            }
            catch {
                if (Test-Path -LiteralPath $tempFilePath) {
                    Remove-Item -Path $tempFilePath -Force -ErrorAction SilentlyContinue
                }
                Write-Error "Compression FAILED for '$($sf.Name)': $_"
            }
        }
    }
    catch {
        Write-Error "Fatal error in Compress-SubFolderContents: $_"
    }
}

function Add-ContentToBlobContainer {
    [CmdletBinding(SupportsShouldProcess = $True)]
    param(
        [Parameter(Mandatory, HelpMessage = "Specifies the name of the resource group that contains the Storage account to update.")]
        [string] $ResourceGroupName,
        [Parameter(Mandatory, HelpMessage = "Specifies the name of the Storage account to update.")]
        [string] $StorageAccountName,
        [Parameter(Mandatory, HelpMessage = "The paths to the content to upload.")]
        [string[]] $contentDirectories,
        [Parameter(Mandatory, HelpMessage = "The name of the container to upload to.")]
        [string] $targetContainer
    )
    $ProgressPreference = 'SilentlyContinue'
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
    foreach ($contentDirectory in $contentDirectories) {
        try {
            If (-Not (Test-Path -Path $contentDirectory)) {
                throw "Cannot find content path to upload [$contentDirectory]"
            }
            $scriptsToUpload = Get-ChildItem -Path $contentDirectory -File -ErrorAction 'Stop'
            if ($PSCmdlet.ShouldProcess("Files to the '$targetContainer' container", "Upload")) {
                foreach ($file in $scriptsToUpload) {
                    Write-Output "Uploading '$($file.Name)' ($([math]::Round($file.Length / 1MB, 1)) MB)..."
                    $file | Set-AzStorageBlobContent -Container $targetContainer -Context $ctx -Force -ErrorAction 'Stop' | Out-Null
                }
            }
            Write-Verbose "$($scriptsToUpload.Count) file(s) uploaded from [$contentDirectory] to container [$targetContainer]"
        }
        catch {
            Write-Error "Upload FAILED: $_"
        }
    }
}

Function Install-Evergreen {
    $adminCheck = [Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())
    $Admin = $adminCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (Get-PSRepository | Where-Object { $_.Name -eq "PSGallery" -and $_.InstallationPolicy -ne "Trusted" }) {
        if ($Admin) {
            Set-PSRepository -Name "PSGallery" -InstallationPolicy "Trusted"
            Install-PackageProvider -Name "NuGet" -MinimumVersion 2.8.5.208 -Force
        } else {
            Install-PackageProvider -Name "NuGet" -MinimumVersion 2.8.5.208 -Force -Scope CurrentUser
        }
    }
    # Check for module in the appropriate scope
    if ($Admin) {
        $Installed = Get-Module -Name "Evergreen" -ListAvailable | `
            Sort-Object -Property @{ Expression = { [System.Version]$_.Version }; Descending = $true } | `
            Select-Object -First 1
        $Published = Find-Module -Name "Evergreen"
        if ($Null -eq $Installed -or [System.Version]$Published.Version -gt [System.Version]$Installed.Version) {
            Install-Module -Name "Evergreen" -Force -AllowClobber
        }
    } else {
        # For non-admin, check CurrentUser scope and suppress warnings
        $CurrentUserPath = [Environment]::GetFolderPath('MyDocuments') + '\PowerShell\Modules\Evergreen'
        if (-not (Test-Path $CurrentUserPath)) {
            $CurrentUserPath = [Environment]::GetFolderPath('MyDocuments') + '\WindowsPowerShell\Modules\Evergreen'
        }
        $Installed = Get-Module -Name "Evergreen" -ListAvailable | Where-Object { $_.Path -like "*$($env:USERNAME)*" } | `
            Sort-Object -Property @{ Expression = { [System.Version]$_.Version }; Descending = $true } | `
            Select-Object -First 1
        
        # Only check for updates if no user-scope version exists or suppress update notifications
        if ($Null -eq $Installed) {
            Install-Module -Name "Evergreen" -Scope CurrentUser -Force -AllowClobber -WarningAction SilentlyContinue
        }
    }
    Import-Module -Name "Evergreen" -Force
}

function Get-EvergreenAppUri {
    param (
        [psobject]$Evergreen
    )
    $filters = @()
    if ($Evergreen.Architecture) {
        $Architecture = $Evergreen.Architecture
        $filters += '$_.Architecture -eq ''' + $Architecture + ''''
    }
    if ($Evergreen.InstallerType) {
        $InstallerType = $Evergreen.InstallerType
        $filters += '$_.InstallerType -eq ''' + $InstallerType + ''''
    }
    if ($Evergreen.Language) {
        $Language = $Evergreen.Language
        $filters += '$_.Language -eq ''' + $Language + ''''
    }
    if ($Evergreen.Type) {
        $Type = $Evergreen.Type
        $filters += '$_.Type -eq ''' + $Type + ''''
    } 
    if ($filters.Count -gt 0) {
        $WhereObject = ($filters -join ' -and ').replace('  ', ' ')
        $ScriptBlock = [scriptblock]::Create("Get-EvergreenApp -name $($Evergreen.name) | Where-Object {$($WhereObject)}")
        Return (Invoke-Command -ScriptBlock $ScriptBlock).Uri
    } Else {
        Return (Get-EvergreenApp -Name $($Evergreen.name)).Uri
    }
}

#endregion Functions

#region Download New Sources

$downloadFilePath = (Join-Path -Path "$PSScriptRoot\imageManagement\parameters" -ChildPath "$downloadsParametersPrefix.downloads.parameters.json")
if ((!$SkipDownloadingNewSources) -and (Test-Path -Path $downloadFilePath)) {

    Write-Output ""
    Write-Output "=== Phase 1: Download ==="
    $DownloadDir = Join-Path -Path $TempArtifactsDir -ChildPath 'downloads'
    New-Item -Path $DownloadDir -ItemType Directory -Force | Out-Null
    $FileVersionInfoFile = Join-Path -Path $ArtifactsDir -ChildPath 'uploadedFileVersionInfo.txt'
    New-Item -Path $FileVersionInfoFile -ItemType File -Force | Out-Null
    $downloadJson = Get-Content -Path $downloadFilePath -Raw -ErrorAction 'Stop'
    $downloadJson = $downloadJson -replace 'ENVSUFFIX', $EnvSuffix
    try {
        $Downloads = $downloadJson | ConvertFrom-Json -ErrorAction 'Stop'
    }
    catch {
        Write-Error "Configuration JSON content could not be converted to a PowerShell object" -ErrorAction 'Stop'
    }

    # Check if any download requires Evergreen and install if needed
    $RequiresEvergreen = $false
    foreach ($key in $Downloads.PSObject.Properties.Name) {
        if ($null -ne $Downloads.$key.Evergreen) {
            $RequiresEvergreen = $true
            break
        }
    }
    If ($RequiresEvergreen -and ($Environment -eq 'AzureCloud' -or $Environment -eq 'AzureUSGovernment')) {
        Write-Output "Evergreen functionality detected in downloads configuration. Installing Evergreen module..."
        Install-Evergreen
    }

    # Check if any download requires winget
    $RequiresWinget = $false
    foreach ($key in $Downloads.PSObject.Properties.Name) {
        if ($null -ne $Downloads.$key.WingetId -and $Downloads.$key.WingetId -ne '') {
            $RequiresWinget = $true
            break
        }
    }
    If ($RequiresWinget -and -not (Get-Command -Name 'winget' -ErrorAction SilentlyContinue)) {
        Write-Warning "One or more downloads require winget, but winget was not found on this system. Winget-based downloads will be skipped."
    }

    $packageCount = ($Downloads.PSObject.Properties.Name).Count
    Write-Output "Processing $packageCount package(s) from '$downloadFilePath'."

    foreach ($key in $Downloads.PSObject.Properties.Name) {
        $Download = $Downloads.$key
        $SoftwareName = $key
        Write-Output ""
        Write-Output "=== $SoftwareName ==="
        $DownloadUrl = $null
        $UseWinget = $false
        If ($null -ne $Download.WingetId -and $Download.WingetId -ne '') {
            $UseWinget = $true
        }
        ElseIf (($null -ne $Download.WebSiteUrl -and $Download.WebSiteUrl -ne '') -and ($null -ne $Download.SearchString -and $Download.SearchString -ne '')) {
            $WebSiteUrl = $Download.WebSiteUrl
            $SearchString = $Download.SearchString
            Write-Output "[$SoftwareName] Determining download URL from '$WebSiteUrl'..."
            $DownloadUrl = Get-InternetUrl -WebSiteUrl $WebSiteUrl -searchstring $SearchString -ErrorAction SilentlyContinue
            If ($null -ne $DownloadUrl) {
                Write-Verbose "[$SoftwareName] Resolved URL: $DownloadUrl"
            } ElseIf ($null -ne $Download.DownloadUrl -and $Download.DownloadUrl -ne '') {
                Write-Output "[$SoftwareName] Download URL available (website fallback)."
                $DownloadUrl = $Download.DownloadUrl
            }
        }
        ElseIf ($null -ne $Download.DownloadUrl -and $Download.DownloadUrl -ne '') {
            Write-Output "[$SoftwareName] Download URL available."
            $DownloadUrl = $Download.DownloadUrl
        }
        ElseIf ($null -ne $Download.APIUrl -and $Download.APIUrl -ne '') {
            Write-Output "[$SoftwareName] Retrieving Edge Templates URL from API..."
            $APIUrl = $Download.APIUrl
            $EdgeUpdatesJSON = Invoke-WebRequest -Uri $APIUrl -UseBasicParsing
            $content = $EdgeUpdatesJSON.content | ConvertFrom-Json
            $Edgereleases = ($content | Where-Object { $_.Product -eq 'Stable' }).releases
            $latestrelease = $Edgereleases | Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq 'x64' } | Sort-Object ProductVersion | Select-Object -Last 1
            $EdgeLatestStableVersion = $latestrelease.ProductVersion
            $policyfiles = ($content | Where-Object { $_.Product -eq 'Policy' }).releases
            $latestPolicyFile = $policyfiles | Where-Object { $_.ProductVersion -eq $EdgeLatestStableVersion }
            If (-not($latestPolicyFile)) {
                $latestPolicyFile = $policyfiles | Sort-Object ProductVersion | Select-Object -Last 1
            }
            $DownloadUrl = $latestPolicyFile.artifacts.Location
            Write-Verbose "[$SoftwareName] Resolved URL: $DownloadUrl"
        }
        ElseIf ($null -ne $Download.GitHubRepo -and $Download.GitHubRepo -ne '') {
            $Repo = $Download.GitHubRepo
            $FileNamePattern = $Download.GitHubFileNamePattern
            $ReleasesUri = "https://api.github.com/repos/$Repo/releases/latest"
            Write-Output "[$SoftwareName] Retrieving URL from GitHub ($Repo)..."
            $DownloadUrl = ((Invoke-RestMethod -Method GET -Uri $ReleasesUri).assets | Where-Object name -like $FileNamePattern).browser_download_url
            Write-Verbose "[$SoftwareName] Resolved URL: $DownloadUrl"
        }
        ElseIf ($null -ne $Download.Evergreen) {
            Write-Output "[$SoftwareName] Retrieving URL via Evergreen..."
            Write-Output "[$SoftwareName] Evergreen config: $($Download.Evergreen)"
            $DownloadUrl = Get-EvergreenAppUri -Evergreen $Download.Evergreen
            Write-Verbose "[$SoftwareName] Resolved URL: $DownloadUrl"
        }

        If ($UseWinget) {
            If (-not (Get-Command -Name 'winget' -ErrorAction SilentlyContinue)) {
                Write-Warning "[$SoftwareName] Skipping: winget is not available on this system."
            }
            Else {
                Write-Output "[$SoftwareName] Downloading via winget (Id: $($Download.WingetId))..."
                Try {
                    $TempSoftwareDownloadDir = Join-Path -Path $DownloadDir -ChildPath ($SoftwareName.Replace(' ', '_'))
                    New-Item -Path $TempSoftwareDownloadDir -ItemType Directory -Force | Out-Null
                    $DestFileName = $Download.DestinationFileName
                    $DestFileFullName = Join-Path $TempSoftwareDownloadDir -ChildPath $DestFileName
                    $VersionText = @()
                    $VersionText += "SoftwareName = $SoftwareName"
                    $VersionText += "WingetId = $($Download.WingetId)"
                    & winget download --id $Download.WingetId --download-directory $TempSoftwareDownloadDir --accept-source-agreements --accept-package-agreements |
                        Where-Object { $_ -match 'Found |Successfully |Installer downloaded:|[Ee]rror|[Ww]arning|[Ff]ailed' } |
                        ForEach-Object { Write-Output "[$SoftwareName]  $_" }
                    $DestFileExtension = [System.IO.Path]::GetExtension($DestFileName)
                    $DownloadedFileItem = Get-ChildItem -Path $TempSoftwareDownloadDir -File | Where-Object { $_.Extension -eq $DestFileExtension } | Select-Object -First 1
                    If ($null -eq $DownloadedFileItem) {
                        $DownloadedFileItem = Get-ChildItem -Path $TempSoftwareDownloadDir -File | Select-Object -First 1
                    }
                    If ($null -eq $DownloadedFileItem) {
                        Throw "Winget did not download any files for '$SoftwareName'."
                    }
                    $VersionText += "Downloaded File = $($DownloadedFileItem.Name)"
                    If ($DownloadedFileItem.FullName -ne $DestFileFullName) {
                        Rename-Item -Path $DownloadedFileItem.FullName -NewName $DestFileName -Force
                    }
                    Write-Output "[$SoftwareName] Download complete."
                    If ([System.IO.Path]::GetExtension($DestFileFullName) -eq '.msi') {
                        $VersionText += Get-MSIInfo -Path $DestFileFullName
                    }
                    ElseIf ([System.IO.Path]::GetExtension($DestFileFullName) -eq '.exe') {
                        $Version = (Get-ItemProperty -Path $DestFileFullName).VersionInfo | Select-Object ProductVersion, FileVersion
                        $VersionText += "$Version"
                    }
                    $VersionText += "Downloaded on = $(Get-Date)"
                    $VersionText += "--------------------------------------------------"
                    Add-Content -Path $FileVersionInfoFile -Value $VersionText
                }
                Catch {
                    Write-Error "Error downloading '$SoftwareName' via winget: $_."
                }
                $DestFolders = $Download.DestinationFolders
                foreach ($DestFolder in $DestFolders) {
                    $DestinationDir = Join-Path -Path $ArtifactsDir -ChildPath $DestFolder
                    If (-not (Test-Path -Path $DestinationDir)) {
                        New-Item -Path $DestinationDir -ItemType Directory -Force | Out-Null
                    }
                    $copySize = [math]::Round((Get-Item $DestFileFullName).Length / 1MB, 1)
                    Write-Output "[$SoftwareName] Copying to artifacts directory ($copySize MB)..."
                    Copy-Item -Path $DestFileFullName -Destination $DestinationDir -Force
                }
            }
        }
        ElseIf (($DownloadUrl -ne '') -and ($null -ne $DownloadUrl)) {
            Write-Output "[$SoftwareName] Downloading from '$DownloadUrl'..."
            Try {
                $TempSoftwareDownloadDir = Join-Path -Path $DownloadDir -ChildPath ($SoftwareName.Replace(' ', '_'))
                New-Item -Path $TempSoftwareDownloadDir -ItemType Directory -Force | Out-Null
                $DestFileName = $Download.DestinationFileName
                $DestFileFullName = Join-Path $TempSoftwareDownloadDir -ChildPath $DestFileName
                $VersionText = @()
                $VersionText += "SoftwareName = $SoftwareName"
                $VersionText += "DownloadUrl = $DownloadUrl"
                Try {
                    $DownloadedFileFullName = Get-InternetFile -Url $DownloadUrl -OutputDirectory $TempSoftwareDownloadDir
                    $DownloadedFile = Split-Path -Path $DownloadedFileFullName -Leaf
                    If ($DownloadedFileFullName -ne $DestFileFullName) {
                        $VersionText += "Download File = $DownloadedFile"
                        Rename-Item -Path $DownloadedFileFullName -NewName $DestFileName -Force
                    }
                }
                Catch {
                    $DownloadedFileFullName = Get-InternetFile -Url $DownloadUrl -OutputDirectory $TempSoftwareDownloadDir -OutputFileName $DestFileName
                    $VersionText += "Download File = $(Split-Path $DownloadedFileFullName -Leaf)"
                }
                Write-Output "[$SoftwareName] Download complete."
                If ([System.IO.Path]::GetExtension($DestFileFullName) -eq '.msi') {
                    $VersionText += Get-MSIInfo -Path $DestFileFullName
                }
                ElseIf ([System.IO.Path]::GetExtension($DestFileFullName) -eq '.exe') {
                    $Version = (Get-ItemProperty -Path $DestFileFullName).VersionInfo | Select-Object ProductVersion, FileVersion
                    $VersionText += "$Version"
                }
                $VersionText += "Downloaded on = $(Get-Date)"
                $VersionText += "--------------------------------------------------"
                Add-Content -Path $FileVersionInfoFile -Value $VersionText
            }
            Catch {
                Write-Error "Error downloading software from '$DownloadUrl': $_."
            }
            $DestFolders = $Download.DestinationFolders
            foreach ($DestFolder in $DestFolders) {
                $DestinationDir = Join-Path -Path $ArtifactsDir -ChildPath $DestFolder
                If (-not (Test-Path -Path $DestinationDir)) {
                    New-Item -Path $DestinationDir -ItemType Directory -Force | Out-Null
                }
                $copySize = [math]::Round((Get-Item $DestFileFullName).Length / 1MB, 1)
                Write-Output "[$SoftwareName] Copying to artifacts directory ($copySize MB)..."
                Copy-Item -Path $DestFileFullName -Destination $DestinationDir -Force
            }
        }
        Else {
            Write-Error "No Internet URL found for '$SoftwareName'."
        }
    }
    Write-Output ""
    Write-Output "Cleaning up download temp directory in background..."
    Start-Job -ScriptBlock {
        param($Path)
        Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
    } -ArgumentList $DownloadDir | Out-Null
}
Else {
    Write-Output "Skipping download phase (-SkipDownloadingNewSources specified or no downloads parameter file found)."
}
#endregion Download New Sources

#region Compress Artifacts

Write-Output ""
Write-Output "=== Phase 2: Compress ==="

if ($PSCmdlet.ShouldProcess("[$ArtifactsDir] subfolders as .zip and store them into [$TempArtifactsDir]", "Compress")) {
    Compress-SubFolderContents -SourceFolderPath $ArtifactsDir -DestinationFolderPath $TempArtifactsDir
    Write-Output "Compression complete."
}
$rootFiles = Get-ChildItem -Path $ArtifactsDir -File | Where-Object { $_.FullName -ne $downloadFilePath }
if ($rootFiles) {
    Write-Output "Copying $($rootFiles.Count) root artifact file(s) to staging directory..."
    $rootFiles | Copy-Item -Destination $TempArtifactsDir -Force
}

#endregion Compress Artifacts

#region Upload Blobs

Write-Output ""
Write-Output "=== Phase 3: Upload ==="

if ($DeleteExistingBlobs) {
    Write-Output "Deleting existing blobs in '$StorageAccountName/$ArtifactsContainerName'."
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
    Get-AzStorageBlob -Container $ArtifactsContainerName -Context $ctx | Remove-AzStorageBlob -Force
}

if ($PSCmdlet.ShouldProcess("storage account '$StorageAccountName'", "Uploading blobs to")) {
    Add-ContentToBlobContainer -ResourceGroupName $StorageAccountResourceGroup -StorageAccountName $StorageAccountName -contentDirectories $TempArtifactsDir -TargetContainer $ArtifactsContainerName
    Write-Output "Upload complete."
}

Write-Output "Cleaning up temp artifacts directory in background..."
Start-Job -ScriptBlock {
    param($Path)
    Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
} -ArgumentList $TempArtifactsDir | Out-Null

#endregion Upload Blobs

$elapsed = (Get-Date) - $ScriptStartTime
Write-Output ""
Write-Output "=== Complete ==="
Write-Output "Elapsed time    : $([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
Write-Output "Artifacts URL   : $ArtifactsContainerUrl"
Write-Verbose ("[{0} exited]" -f $MyInvocation.MyCommand)
