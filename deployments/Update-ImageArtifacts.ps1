<#
.SYNOPSIS
Downloads the latest software sources, stages repository and customer artifacts, packages them as
zip files, and uploads them to the image management artifacts storage account blob container.

.DESCRIPTION
Run this script whenever you want to refresh the artifacts in the image management storage account -
for example, after adding new software packages or after new versions are released.

The script stages artifacts from both the repository-owned '.common\artifacts' folder and the
customer-owned 'customer\artifacts' folder. Customer artifacts are overlaid on top of repository
artifacts, allowing customers to extend or replace packages without modifying repo-provided content.

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

.PARAMETER CustomerRootPath
Optional. Root folder that contains customer-owned content. Defaults to the repo-local
`customer` folder next to the `deployments` folder. Use this to keep customer content outside
the extracted repo when updating from a fresh zip.

.PARAMETER CustomerArtifactsMode
Controls whether customer artifacts are included when packaging artifacts.
Use `Overlay` to merge customer artifacts over repo artifacts, or `None` to skip customer artifacts.

.PARAMETER CustomerDownloadsMode
Controls whether customer downloads.json content is merged into the base downloads file.
Use `Merge` to apply customer overrides, or `None` to use only the repo-selected base file.

.PARAMETER CopyDownloadsToCustomerArtifacts
When specified, each downloaded file is also copied into the customer\artifacts folder (alongside
the normal staging location). Use this to persist downloads into your customer content so they can
be committed to source control and used in air-gapped environments on subsequent runs with
-SkipDownloadingNewSources.

.NOTES
If `customer\parameters\imageManagement\downloads.json` exists, it is merged on top of the
auto-selected base environment downloads file. Existing keys are overwritten and new keys are added.

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
# Air-gapped update - skip internet downloads, just re-package and upload existing artifacts
.\Update-ImageArtifacts.ps1 `
    -StorageAccountName "saimgassetsuse2abc123" `
    -ResourceGroupName "rg-avd-image-management-use2" `
    -SkipDownloadingNewSources

.EXAMPLE
# Clean upload - delete existing blobs first, then upload fresh
.\Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId "/subscriptions/.../storageAccounts/saimgassetsuse2abc123" `
    -DeleteExistingBlobs

.EXAMPLE
# Merge additional downloads automatically when customer\parameters\imageManagement\downloads.json exists
.\Update-ImageArtifacts.ps1 `
    -StorageAccountName "saimgassetsuse2abc123" `
    -ResourceGroupName "rg-avd-image-management-use2"
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
    [string]$CustomerRootPath = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Overlay', 'None')]
    [string]$CustomerArtifactsMode = 'Overlay',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Merge', 'None')]
    [string]$CustomerDownloadsMode = 'Merge',

    [Parameter(Mandatory = $false)]
    [string]$TempDir = "$Env:Temp",

    [Parameter(Mandatory = $false)]
    [switch]$CopyDownloadsToCustomerArtifacts
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

If ($Environment -eq 'AzureCloud' -or $Environment -eq 'AzureUSGovernment') {
    $downloadsParametersPrefix = 'public'
}
ElseIf ($Environment -match 'USN') {
    $downloadsParametersPrefix = 'topsecret'
}
Else {
    $downloadsParametersPrefix = 'secret'
}

$ArtifactsContainerName = 'artifacts'
$TempArtifactsDir = Join-Path -Path $TempDir -ChildPath 'Artifacts'
$RepoArtifactsDir = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\.common\artifacts')).FullName
$ResolvedCustomerRootPath = if ([string]::IsNullOrWhiteSpace($CustomerRootPath)) {
    Join-Path -Path $PSScriptRoot -ChildPath '..\customer'
} else {
    $CustomerRootPath
}
$CustomerArtifactsDir = Join-Path -Path $ResolvedCustomerRootPath -ChildPath 'artifacts'
$CustomerImageManagementParametersDir = Join-Path -Path $ResolvedCustomerRootPath -ChildPath 'parameters\imageManagement'
$ArtifactsDir = Join-Path -Path $TempArtifactsDir -ChildPath 'stagedArtifacts'
$ResolvedAdditionalDownloadsFilePath = Join-Path -Path $CustomerImageManagementParametersDir -ChildPath 'downloads.json'

If (Test-Path -Path $TempArtifactsDir) {
    Remove-Item -Path $TempArtifactsDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -Path $TempArtifactsDir -ItemType Directory -Force | Out-Null
New-Item -Path $ArtifactsDir -ItemType Directory -Force | Out-Null

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
Write-Output "Repo artifacts  : $RepoArtifactsDir"
Write-Output "Customer assets : $CustomerArtifactsDir"
Write-Output "Customer root   : $ResolvedCustomerRootPath"
Write-Output "Cust art mode   : $CustomerArtifactsMode"
Write-Output "Cust dl mode    : $CustomerDownloadsMode"
#endregion Variables

Write-Output ("[{0} entered]" -f $MyInvocation.MyCommand)

#region Functions
function Get-MsiInfo {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$True)]
        [IO.FileInfo]$Path,
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$Property
    )

    [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    Write-Verbose "${CmdletName}: Starting with [$PSBoundParameters]"

    # WindowsInstaller.Installer is a Windows-only COM object.
    # $IsWindows is available in PowerShell 6+; PSEdition 'Desktop' covers Windows PowerShell 5.x.
    $runningOnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)
    if (-not $runningOnWindows) {
        Write-Warning "${CmdletName}: MSI metadata extraction requires the Windows Installer COM object (WindowsInstaller.Installer) and is not supported on this platform ($($PSVersionTable.OS)). Skipping."
        return
    }

    $winInstaller = New-Object -ComObject WindowsInstaller.Installer
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
    finally {
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
    # Long-path prefix (\\?\) is Windows-only; return path unchanged on other platforms.
    # PSEdition 'Desktop' covers Windows PowerShell 5.x where $IsWindows is not defined.
    if ($PSVersionTable.PSEdition -ne 'Desktop' -and $IsWindows -ne $true) { return $trimmed }
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
    # Long-path prefix (\\?\) is Windows-only; return path unchanged on other platforms.
    if ($PSVersionTable.PSEdition -ne 'Desktop' -and $IsWindows -ne $true) { return $Path }
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
                        throw "Archive for '$($sf.Name)' is incomplete - $($failedFiles.Count) file(s) could not be added."
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

function Copy-ArtifactsContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, HelpMessage = 'Source folder whose contents should be merged into the destination.')]
        [string] $SourceFolderPath,
        [Parameter(Mandatory, HelpMessage = 'Destination folder that receives the source contents.')]
        [string] $DestinationFolderPath
    )

    if (-not (Test-Path -Path $SourceFolderPath)) {
        return
    }

    if (-not (Test-Path -Path $DestinationFolderPath)) {
        New-Item -Path $DestinationFolderPath -ItemType Directory -Force | Out-Null
    }

    foreach ($item in Get-ChildItem -Path $SourceFolderPath -Force) {
        $destinationPath = Join-Path -Path $DestinationFolderPath -ChildPath $item.Name
        if ($item.PSIsContainer) {
            if (-not (Test-Path -Path $destinationPath)) {
                New-Item -Path $destinationPath -ItemType Directory -Force | Out-Null
            }
            Copy-ArtifactsContent -SourceFolderPath $item.FullName -DestinationFolderPath $destinationPath
        }
        elseif ($item.Name -ine '.gitkeep') {
            Copy-Item -Path $item.FullName -Destination $destinationPath -Force
        }
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

function Optimize-SharedDependencies {
    # Deduplicates dependency packages across preserve-layout app subfolders.
    # Each app winget downloads brings its own copy of shared framework packages
    # (VCLibs, WinAppSDK, etc.). This function collects them all, keeps one copy
    # of each (highest version wins), moves them to a SharedDependencies\ folder
    # at the parent level, then removes the per-app Dependencies\ folders.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ParentDir
    )

    Write-Output "Deduplicating shared dependencies under '$ParentDir'..."

    $PkgExts = @('.msixbundle', '.appxbundle', '.msix', '.appx')

    # Collect all x64/neutral dep files from every app subfolder.
    $AllDeps = Get-ChildItem -Path $ParentDir -Directory |
        Where-Object { $_.Name -ne 'SharedDependencies' } |
        ForEach-Object {
            Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Extension -in $PkgExts -and
                    $_.FullName  -match '(?i)\\dependencies\\' -and
                    $_.Name      -match '(?i)_(x64|neutral)[._]'
                }
        }

    If (-not $AllDeps) {
        Write-Output "No dependency packages found under '$ParentDir'. Nothing to deduplicate."
        return
    }

    # Dedup key: strip the version segment so all versions of the same package
    # family + arch map to the same key.
    # e.g. Microsoft.VCLibs.140.00_14.0.33519.0_x64__8wekyb3d8bbwe.appx
    #   -> Microsoft.VCLibs.140.00_x64__8wekyb3d8bbwe.appx
    $SharedDir = Join-Path -Path $ParentDir -ChildPath 'SharedDependencies'
    If (Test-Path -Path $SharedDir) {
        Remove-Item -Path "$SharedDir\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $SharedDir -ItemType Directory -Force | Out-Null

    $Grouped = $AllDeps | Group-Object {
        $_.Name -replace '_[0-9]+(?:\.[0-9]+){1,3}(?=_)', ''
    }

    $KeptCount = 0
    foreach ($Group in $Grouped) {
        $Best = $Group.Group |
            Sort-Object {
                $v = [Version]'0.0.0.0'
                If ($_.Name -match '_([0-9]+(?:\.[0-9]+){1,3})[_.]') {
                    try { $v = [Version]$Matches[1] } catch {}
                }
                $v
            } -Descending |
            Select-Object -First 1
        Copy-Item -Path $Best.FullName -Destination (Join-Path -Path $SharedDir -ChildPath $Best.Name) -Force
        If ($Group.Count -gt 1) {
            $eliminated = ($Group.Group | Where-Object { $_.Name -ne $Best.Name }) -join ', '
            Write-Output "  [merged]  Kept : $($Best.Name)"
            Write-Output "            Dropped ($($Group.Count - 1)) : $eliminated"
        }
        Else {
            Write-Output "  [unique]  $($Best.Name)"
        }
        $KeptCount++
    }
    Write-Output ""
    Write-Output "  Unique packages in SharedDependencies : $KeptCount"
    Write-Output "  Total packages before dedup           : $($AllDeps.Count)"
    Write-Output "  Packages eliminated                   : $($AllDeps.Count - $KeptCount)"
    Write-Output "  NOTE: packages with different major.minor in their name (e.g. WindowsAppRuntime.1.7"
    Write-Output "        vs 1.8, UI.Xaml.2.4 vs 2.8) are separate package families and cannot be merged."

    # Remove per-app Dependencies folders - they are now redundant.
    $RemovedCount = 0
    Get-ChildItem -Path $ParentDir -Directory |
        Where-Object { $_.Name -ne 'SharedDependencies' } |
        ForEach-Object {
            $DepDir = Join-Path -Path $_.FullName -ChildPath 'Dependencies'
            If (Test-Path -Path $DepDir) {
                Remove-Item -Path $DepDir -Recurse -Force
                $RemovedCount++
            }
        }
    Write-Output "  Per-app Dependencies folders removed  : $RemovedCount"
}

#endregion Functions

#region Prepare Artifacts

Write-Output ""
Write-Output "=== Prepare Artifacts ==="
Write-Output "Staging repository artifacts..."
Copy-ArtifactsContent -SourceFolderPath $RepoArtifactsDir -DestinationFolderPath $ArtifactsDir

if ($CustomerArtifactsMode -ne 'None' -and (Test-Path -Path $CustomerArtifactsDir)) {
    Write-Output "Overlaying customer artifacts..."
    Copy-ArtifactsContent -SourceFolderPath $CustomerArtifactsDir -DestinationFolderPath $ArtifactsDir
}
elseif ($CustomerArtifactsMode -eq 'None') {
    Write-Output "Customer artifacts disabled by mode. Continuing with repository artifacts only."
}
else {
    Write-Output "Customer artifacts directory not found. Continuing with repository artifacts only."
}

#endregion Prepare Artifacts

#region Download New Sources

$downloadFilePath = (Join-Path -Path "$PSScriptRoot\.." -ChildPath ".common\data\$downloadsParametersPrefix.downloads.parameters.json")
if ((!$SkipDownloadingNewSources) -and (Test-Path -Path $downloadFilePath)) {

    Write-Output ""
    Write-Output "=== Phase 1: Download ==="
    $DownloadDir = Join-Path -Path $TempArtifactsDir -ChildPath 'downloads'
    New-Item -Path $DownloadDir -ItemType Directory -Force | Out-Null
    # Track parent dirs of preserve-layout destinations for post-loop deduplication.
    $PreserveLayoutParentFolders         = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $CustomerPreserveLayoutParentFolders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
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

    # Merge customer-owned downloads file if present
    if ($CustomerDownloadsMode -ne 'None' -and (Test-Path -Path $ResolvedAdditionalDownloadsFilePath)) {
        Write-Output "Merging additional downloads from '$ResolvedAdditionalDownloadsFilePath'."
        $additionalJson = Get-Content -Path $ResolvedAdditionalDownloadsFilePath -Raw -ErrorAction 'Stop'
        $additionalJson = $additionalJson -replace 'ENVSUFFIX', $EnvSuffix
        try {
            $AdditionalDownloads = $additionalJson | ConvertFrom-Json -ErrorAction 'Stop'
        }
        catch {
            Write-Error "Additional downloads JSON content could not be converted to a PowerShell object" -ErrorAction 'Stop'
        }
        foreach ($key in $AdditionalDownloads.PSObject.Properties.Name) {
            $Downloads | Add-Member -NotePropertyName $key -NotePropertyValue $AdditionalDownloads.$key -Force
        }
    }
    elseif ($CustomerDownloadsMode -eq 'None') {
        Write-Output "Customer downloads disabled by mode. Using the repository-selected base downloads file only."
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
        Write-Output "Winget not found. Attempting to register the App Installer package..."
        try {
            # 'Register' re-associates an already-staged Appx package with the current user context.
            # This is the most common reason winget is absent in automation / build-agent scenarios
            # even though the App Installer package is physically present on the machine.
            Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
            Write-Output "App Installer package registered successfully."
        }
        catch {
            Write-Warning "Could not register the App Installer package: $_"
            Write-Warning "Ensure the App Installer package is present on this machine (Settings > Apps > App Installer) or install winget manually before running this script with winget-based downloads."
        }

        # Refresh the PATH so the newly registered winget.exe is visible in this session.
        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('PATH', 'User')

        if (Get-Command -Name 'winget' -ErrorAction SilentlyContinue) {
            Write-Output "Winget is now available ($(& winget --version))."
        }
        else {
            Write-Warning "Winget is still not available after registration attempt. Winget-based downloads will be skipped."
        }
    }

    $packageCount = ($Downloads.PSObject.Properties.Name).Count
    Write-Output "Processing $packageCount package(s) from '$downloadFilePath'."

    # Clean winget's own working directory so stale files from previous runs do not
    # accumulate. winget creates %TEMP%\WinGet independently of --download-directory.
    $WingetTempDir = Join-Path -Path $Env:TEMP -ChildPath 'WinGet'
    If (Test-Path -Path $WingetTempDir) {
        Write-Output "Cleaning winget temp directory '$WingetTempDir'..."
        Remove-Item -Path $WingetTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

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
        If ($UseWinget) {
            If (-not (Get-Command -Name 'winget' -ErrorAction SilentlyContinue)) {
                Write-Warning "[$SoftwareName] Skipping: winget is not available on this system."
            }
            Else {
                Write-Output "[$SoftwareName] Downloading via winget (Id: $($Download.WingetId))..."
                # WingetPreserveLayout: skip rename and preserve the downloaded folder structure as-is.
                # Use this for MSIX/UWP apps where winget creates a versioned bundle + Dependencies subfolder.
                $PreserveLayout = ($null -ne $Download.WingetPreserveLayout -and [bool]$Download.WingetPreserveLayout)
                Try {
                    $TempSoftwareDownloadDir = Join-Path -Path $DownloadDir -ChildPath ($SoftwareName.Replace(' ', '_'))
                    If (Test-Path -Path $TempSoftwareDownloadDir) {
                        Remove-Item -Path $TempSoftwareDownloadDir -Recurse -Force
                    }
                    New-Item -Path $TempSoftwareDownloadDir -ItemType Directory -Force | Out-Null
                    $DestFileName = $Download.DestinationFileName
                    $DestFileFullName = Join-Path $TempSoftwareDownloadDir -ChildPath $DestFileName
                    $VersionText = @()
                    $VersionText += "SoftwareName = $SoftwareName"
                    $VersionText += "WingetId = $($Download.WingetId)"
                    # Resolve architecture: honour a per-entry override, otherwise default to x64.
                    # Set Architecture to 'neutral' to omit --architecture entirely (needed for
                    # multi-arch Store bundles that winget cannot match to a specific arch).
                    # Valid winget values: x86, x64, arm, arm64.
                    $WingetArch = if ($null -ne $Download.Architecture -and $Download.Architecture -ne '') {
                        $Download.Architecture
                    } else {
                        'x64'
                    }
                    $WingetLogFilter = '^Found |[Dd]ownloaded:|[Ee]rror|[Ff]ailed|[Cc]ould not'
                    if ($WingetArch -eq 'neutral') {
                        Write-Output "[$SoftwareName] Architecture : (omitted - neutral/multi-arch)"
                        & winget download --id $Download.WingetId --download-directory $TempSoftwareDownloadDir --skip-license --accept-source-agreements --accept-package-agreements |
                            Where-Object { $_ -match $WingetLogFilter } | ForEach-Object { Write-Output "[$SoftwareName]  $_" }
                    } else {
                        Write-Output "[$SoftwareName] Architecture : $WingetArch"
                        & winget download --id $Download.WingetId --architecture $WingetArch --download-directory $TempSoftwareDownloadDir --skip-license --accept-source-agreements --accept-package-agreements |
                            Where-Object { $_ -match $WingetLogFilter } | ForEach-Object { Write-Output "[$SoftwareName]  $_" }
                    }
                    If ($PreserveLayout) {
                        # Preserve the full downloaded layout (bundle + Dependencies subfolder).
                        # Do not rename any files; the install script will discover them by extension.

                        $PruneExts = @('.msixbundle', '.appxbundle', '.msix', '.appx')

                        # --- Prune main bundle variants ---
                        # When winget downloads without --architecture it fetches every available
                        # installer variant (X86, Neutral, X64.Arm64, etc.). Keep only the best
                        # one so we don't bloat the zip with variants that will never be installed.
                        $MainCandidates = Get-ChildItem -Path $TempSoftwareDownloadDir -File |
                            Where-Object { $_.Extension -in $PruneExts }
                        If ($MainCandidates.Count -gt 1) {
                            $BestMain = $MainCandidates |
                                Sort-Object @{Expression = {
                                    # 1. Highest version wins.
                                    $v = [Version]'0.0.0.0'
                                    If ($_.Name -match '_([0-9]+(?:\.[0-9]+){1,3})[_.]') {
                                        try { $v = [Version]$Matches[1] } catch {}
                                    }
                                    $v
                                }; Descending = $true },
                                @{Expression = {
                                    # 2. Architecture preference for x64 AVD hosts:
                                    #    x64-specific (0) > multi-arch/neutral (1) > anything else (2).
                                    #    A name containing X64 but NOT also Arm/Arm64 alone is x64-specific.
                                    #    Names like X64.Arm64 are multi-arch bundles (score 1).
                                    If ($_.Name -match '(?i)[_.]X64[_.]' -and $_.Name -notmatch '(?i)[_.]Arm') { 0 }
                                    ElseIf ($_.Name -match '(?i)[_.](Neutral|Universal)[_.]' -or $_.Name -match '(?i)[_.]X64\.Arm') { 1 }
                                    Else { 2 }
                                }},
                                @{Expression = {
                                    # 3. Bundle format preference.
                                    switch ($_.Extension) {
                                        '.msixbundle' { 0 }
                                        '.appxbundle' { 1 }
                                        '.msix'       { 2 }
                                        '.appx'       { 3 }
                                        default       { 4 }
                                    }
                                }},
                                @{Expression = { $_.Length }; Descending = $true } |
                                Select-Object -First 1
                            $MainCandidates | Where-Object { $_.FullName -ne $BestMain.FullName } | ForEach-Object {
                                Write-Output "[$SoftwareName] Pruning bundle variant : $($_.Name)"
                                Remove-Item -Path $_.FullName -Force
                            }
                            Write-Output "[$SoftwareName] Best bundle kept         : $($BestMain.Name)"
                        }

                        # --- Prune non-x64/neutral dependency packages ---
                        # winget may download deps for all architectures; drop everything
                        # that is not x64 or neutral to avoid provisioning errors.
                        Get-ChildItem -Path $TempSoftwareDownloadDir -Recurse -File |
                            Where-Object {
                                $_.Extension -in $PruneExts -and
                                $_.FullName  -match '(?i)\\dependencies\\' -and
                                $_.Name      -notmatch '(?i)_(x64|neutral)[._]'
                            } | ForEach-Object {
                                Write-Output "[$SoftwareName] Pruning non-x64 dep    : $($_.Name)"
                                Remove-Item -Path $_.FullName -Force
                            }

                        $DownloadedFiles = Get-ChildItem -Path $TempSoftwareDownloadDir -Recurse -File
                        If ($DownloadedFiles.Count -eq 0) {
                            Throw "Winget did not download any files for '$SoftwareName'."
                        }
                        $DownloadedFiles | ForEach-Object { $VersionText += "Downloaded File = $($_.Name)" }
                        Write-Output "[$SoftwareName] Download complete ($($DownloadedFiles.Count) file(s), layout preserved)."
                    }
                    Else {
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
                    }
                    $VersionText += "Downloaded on = $(Get-Date)"
                    $VersionText += "--------------------------------------------------"
                    Add-Content -Path $FileVersionInfoFile -Value $VersionText
                }
                Catch {
                    Write-Error "Error downloading '$SoftwareName' via winget: $_."
                }
                $DestFolders = if ($Download.DestinationFolders.Count -gt 0) { $Download.DestinationFolders } else { @('') }
                foreach ($DestFolder in $DestFolders) {
                    $DestinationDir = Join-Path -Path $ArtifactsDir -ChildPath $DestFolder
                    # For preserve-layout downloads, wipe the destination first so stale versioned
                    # files from a previous run (overlaid via customer artifacts) do not accumulate.
                    If ($PreserveLayout -and (Test-Path -Path $DestinationDir)) {
                        Write-Output "[$SoftwareName] Cleaning existing content from staging destination before copying..."
                        Remove-Item -Path "$DestinationDir\*" -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    If (-not (Test-Path -Path $DestinationDir)) {
                        New-Item -Path $DestinationDir -ItemType Directory -Force | Out-Null
                    }
                    $copySize = [math]::Round(((Get-ChildItem -Path $TempSoftwareDownloadDir -Recurse -File | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
                    Write-Output "[$SoftwareName] Copying to artifacts directory ($copySize MB)..."
                    Copy-Item -Path "$TempSoftwareDownloadDir\*" -Destination $DestinationDir -Recurse -Force
                    If ($PreserveLayout) {
                        $parentRelative = Split-Path -Path $DestFolder -Parent
                        If (-not [string]::IsNullOrEmpty($parentRelative)) {
                            $null = $PreserveLayoutParentFolders.Add((Join-Path -Path $ArtifactsDir -ChildPath $parentRelative))
                        }
                    }
                    if ($CopyDownloadsToCustomerArtifacts) {
                        $CustomerDestinationDir = Join-Path -Path $CustomerArtifactsDir -ChildPath $DestFolder
                        If ($PreserveLayout -and (Test-Path -Path $CustomerDestinationDir)) {
                            Write-Output "[$SoftwareName] Cleaning existing content from customer artifacts folder before copying..."
                            Remove-Item -Path "$CustomerDestinationDir\*" -Recurse -Force -ErrorAction SilentlyContinue
                        }
                        If (-not (Test-Path -Path $CustomerDestinationDir)) {
                            New-Item -Path $CustomerDestinationDir -ItemType Directory -Force | Out-Null
                        }
                        Write-Output "[$SoftwareName] Copying to customer artifacts directory ($copySize MB)..."
                        Copy-Item -Path "$TempSoftwareDownloadDir\*" -Destination $CustomerDestinationDir -Recurse -Force
                        If ($PreserveLayout) {
                            $parentRelative = Split-Path -Path $DestFolder -Parent
                            If (-not [string]::IsNullOrEmpty($parentRelative)) {
                                $null = $CustomerPreserveLayoutParentFolders.Add((Join-Path -Path $CustomerArtifactsDir -ChildPath $parentRelative))
                            }
                        }
                    }
                }
            }
        }
        ElseIf (($DownloadUrl -ne '') -and ($null -ne $DownloadUrl)) {
            Write-Output "[$SoftwareName] Downloading from '$DownloadUrl'..."
            Try {
                $TempSoftwareDownloadDir = Join-Path -Path $DownloadDir -ChildPath ($SoftwareName.Replace(' ', '_'))
                If (Test-Path -Path $TempSoftwareDownloadDir) {
                    Remove-Item -Path $TempSoftwareDownloadDir -Recurse -Force
                }
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
            $DestFolders = if ($Download.DestinationFolders.Count -gt 0) { $Download.DestinationFolders } else { @('') }
            foreach ($DestFolder in $DestFolders) {
                $DestinationDir = Join-Path -Path $ArtifactsDir -ChildPath $DestFolder
                If (-not (Test-Path -Path $DestinationDir)) {
                    New-Item -Path $DestinationDir -ItemType Directory -Force | Out-Null
                }
                $copySize = [math]::Round((Get-Item $DestFileFullName).Length / 1MB, 1)
                Write-Output "[$SoftwareName] Copying to artifacts directory ($copySize MB)..."
                Copy-Item -Path $DestFileFullName -Destination $DestinationDir -Force
                if ($CopyDownloadsToCustomerArtifacts) {
                    $CustomerDestinationDir = Join-Path -Path $CustomerArtifactsDir -ChildPath $DestFolder
                    If (-not (Test-Path -Path $CustomerDestinationDir)) {
                        New-Item -Path $CustomerDestinationDir -ItemType Directory -Force | Out-Null
                    }
                    Write-Output "[$SoftwareName] Copying to customer artifacts directory ($copySize MB)..."
                    Copy-Item -Path $DestFileFullName -Destination $CustomerDestinationDir -Force
                }
            }
        }
        Else {
            # No download source configured - check whether the file was pre-staged in customer/artifacts/
            $DestFileName = $Download.DestinationFileName
            $DestFolders = if ($Download.DestinationFolders.Count -gt 0) { $Download.DestinationFolders } else { @('') }
            $PreStagedPaths = $DestFolders | ForEach-Object { Join-Path -Path $ArtifactsDir -ChildPath (Join-Path -Path $_ -ChildPath $DestFileName) }
            $PreStagedFile = $PreStagedPaths | Where-Object { Test-Path -Path $_ } | Select-Object -First 1
            If ($null -ne $PreStagedFile) {
                Write-Output "[$SoftwareName] No download URL configured - using pre-staged file found in artifacts directory."
            }
            Else {
                Write-Warning "[$SoftwareName] No download URL configured and '$DestFileName' was not found in the artifacts directory. If you have enabled the corresponding feature in your image build, pre-stage this file in customer/artifacts/ before running. If you are not using this software, no action is needed."
            }
        }
    }
    # Deduplicate shared framework dependencies across preserve-layout app groups.
    If ($PreserveLayoutParentFolders.Count -gt 0) {
        Write-Output ""
        Write-Output "=== Optimizing Shared Dependencies ==="
        foreach ($parentDir in $PreserveLayoutParentFolders) {
            Optimize-SharedDependencies -ParentDir $parentDir
        }
    }
    If ($CustomerPreserveLayoutParentFolders.Count -gt 0 -and $CopyDownloadsToCustomerArtifacts) {
        Write-Output "Deduplicating shared dependencies in customer artifacts..."
        foreach ($parentDir in $CustomerPreserveLayoutParentFolders) {
            If (Test-Path -Path $parentDir) {
                Optimize-SharedDependencies -ParentDir $parentDir
            }
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
