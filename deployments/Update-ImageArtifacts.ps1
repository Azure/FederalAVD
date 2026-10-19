<#
.SYNOPSIS
Downloads the latest software sources, stages repository and customer artifacts, packages them as
zip files, and uploads them to the image management artifacts storage account blob container or
writes them to a local folder.

.DESCRIPTION
Run this script whenever you want to refresh the artifacts in the image management storage account -
for example, after adding new software packages or after new versions are released.

The script stages artifacts from both the repository-owned 'deployments\shared\artifacts' folder and
the customer-owned 'customer\artifacts' folder. Customer artifacts are overlaid on top of
repository artifacts, allowing customers to extend or replace packages without modifying
repo-provided content.

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

.PARAMETER PackageOnly
Packages artifacts into a local folder without requiring an Azure login, subscription, or storage
account. Must be used together with -OutputPath.

.PARAMETER OutputPath
Destination folder for artifacts produced in -PackageOnly mode. Existing files with the same names
are overwritten. Must be used together with -PackageOnly.

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
Preserve-layout Store product IDs try winget first, then use Microsoft's undocumented Store
delivery service if winget fails or is unavailable. The fallback stages verified, unencrypted
x64-compatible packages and dependencies. It is disabled for air-gapped download manifests.

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

.EXAMPLE
# Build artifacts locally for transfer to an air-gapped environment without using Azure
.\Update-ImageArtifacts.ps1 `
    -PackageOnly `
    -OutputPath "C:\AirGapTransfer"
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByResourceId')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
    [string]$StorageAccountResourceId,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true, ParameterSetName = 'LocalPackage')]
    [switch]$PackageOnly,

    [Parameter(Mandatory = $true, ParameterSetName = 'LocalPackage')]
    [string]$OutputPath,

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
$LocalPackageMode = $PSCmdlet.ParameterSetName -eq 'LocalPackage'

If ($LocalPackageMode) {
    $downloadsParametersPrefix = 'public'
    $EnvSuffix = 'core.windows.net'
}
Else {
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
}

$ArtifactsContainerName = 'artifacts'
$TempArtifactsDir = Join-Path -Path $TempDir -ChildPath 'Artifacts'
$RepoArtifactsDir = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath 'shared\artifacts')).FullName
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

# Resolve the local output folder or storage account details for the selected mode.
If ($LocalPackageMode) {
    $ResolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
}
Else {
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
}

If ($LocalPackageMode) {
    Write-Output "Package output  : $ResolvedOutputPath"
}
Else {
    Write-Output "Storage account : $StorageAccountName"
    Write-Output "Resource group  : $StorageAccountResourceGroup"
    Write-Output "Container URL   : $ArtifactsContainerUrl"
}
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
    $LinkHrefs = @($HTML.Links.Href | Where-Object { $_ -like $SearchString })
    $LinkHrefs += @($Links | Where-Object { $_.OuterHTML -like $SearchString } | ForEach-Object { $_.href })

    $escapedPattern = [Regex]::Escape($SearchString) -replace '\\\*', '[^"''\s>]*'
    $regex = "https?://[^""'\s>]*$escapedPattern"
    $LinkHrefs += @([regex]::Matches($HTML.Content, $regex) | ForEach-Object { $_.Value })

    $ResolvedUrls = @(
        $LinkHrefs |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [uri]::new($WebSiteUrl, [string]$_).AbsoluteUri } |
            Sort-Object -Unique
    )

    If ($ResolvedUrls.Count -eq 0) {
        Return $null
    }
    If ($ResolvedUrls.Count -gt 1) {
        Throw "Found multiple download URLs matching '$SearchString' on '$WebSiteUrl': $($ResolvedUrls -join ', ')"
    }

    Return [string]$ResolvedUrls[0]
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
                throw "${CmdletName}: Error downloading file from '$Url'. $($_.Exception.Message)"
            }
        }
        Else {
            throw "${CmdletName}: No OutputFileName could be determined from URL or headers."
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
    # The \\?\ prefix is only reliably supported in managed System.IO methods (ZipFile,
    # FileStream, Directory) on .NET 6+ (PowerShell 7+, PSEdition Core). On Windows PowerShell
    # 5.1 (.NET Framework), \\?\ works at the Win32 level but causes failures inside
    # System.IO.Compression because Path.GetFullPath rejects it. On PS 5.1, return the plain
    # path and rely on the system-level LongPathsEnabled registry key if paths exceed 260 chars.
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $trimmed }
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
                        $tempFilePath,
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

function Get-MicrosoftStorePackageUrl {
    <#
    .SYNOPSIS
        Resolves Microsoft Store products to Microsoft-hosted package download links.
    .DESCRIPTION
        Queries Microsoft's public Display Catalog and FE3 delivery services directly.
        These are undocumented Store interfaces, not a supported Microsoft download API.
        No third-party service, library, account token, or package installation is used.
        Only anonymously available packages can be resolved. Links expire; resolving a
        link does not grant a license or prove offline provisioning is supported.
    .PARAMETER ProductId
        A 12-character Store product ID or an HTTPS Microsoft Store product URL.
    .PARAMETER Architecture
        Filters package identities to this architecture plus neutral packages.
        All (the default) returns every architecture reported by the service.
    .PARAMETER Ring
        Store flight ring: Retail (default), RP, Slow, or Fast. Availability is
        controlled by Microsoft; a ring does not grant access to restricted flights.
    .EXAMPLE
        Get-MicrosoftStorePackageUrl -ProductId 9WZDNCRFHVN5 -Architecture x64
    .EXAMPLE
        Get-MicrosoftStorePackageUrl -ProductId 'https://apps.microsoft.com/detail/9WZDNCRFHVN5' |
            Select-Object -ExpandProperty Url
    .NOTES
        Run on an internet-connected staging machine, not inside an air-gapped cloud.
        The query uses a Windows 11 desktop device profile, not local OS detection.
        Results are not an install plan and can include multiple package versions.
        Encrypted packages are identified by IsEncrypted; this tool does not decrypt them.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('Uri')]
        [ValidateNotNullOrEmpty()]
        [string]$ProductId,

        [ValidateSet('All', 'x64', 'x86', 'arm', 'arm64', 'neutral')]
        [string]$Architecture = 'All',

        [ValidateSet('Retail', 'RP', 'Slow', 'Fast')]
        [string]$Ring = 'Retail'
    )

    $ErrorActionPreference = 'Stop'
    $serviceNamespace = 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService'
    $deliveryEndpoint = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx'

    function Invoke-StoreDeliveryRequest {
        param (
            [string]$Action,
            [string]$Body,
            [switch]$Secured
        )

        $endpoint = $deliveryEndpoint
        if ($Secured) {
            $endpoint += '/secured'
        }
        $created = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $expires = [DateTime]::UtcNow.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $envelope = @"
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">
  <s:Header>
    <a:Action s:mustUnderstand="1">$serviceNamespace/$Action</a:Action>
    <a:MessageID>urn:uuid:$([Guid]::NewGuid())</a:MessageID>
    <a:To s:mustUnderstand="1">$endpoint</a:To>
    <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
      <u:Timestamp xmlns:u="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
        <u:Created>$created</u:Created><u:Expires>$expires</u:Expires>
      </u:Timestamp>
      <WindowsUpdateTicketsToken xmlns="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization"
          xmlns:u="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" u:id="ClientMSA">
        <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><User /></TicketType>
      </WindowsUpdateTicketsToken>
    </o:Security>
  </s:Header>
  <s:Body>$Body</s:Body>
</s:Envelope>
"@
        Write-Verbose "Calling Microsoft delivery service: $Action"
        $response = Invoke-WebRequest -UseBasicParsing -Uri $endpoint -Method Post `
            -ContentType 'application/soap+xml; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($envelope)) -TimeoutSec 60
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.LoadXml([string]$response.Content)
        $fault = $document.SelectSingleNode("//*[local-name()='Fault']")
        if ($null -ne $fault) {
            throw "Microsoft delivery service rejected ${Action}: $($fault.InnerText)"
        }
        return ,$document
    }

    $id = $ProductId.Trim()
    if ($id -notmatch '^[A-Za-z0-9]{12}$') {
        $storeUri = $null
        if (-not [Uri]::TryCreate($id, [UriKind]::Absolute, [ref]$storeUri) -or
            $storeUri.Scheme -ne 'https' -or
            $storeUri.Host -notin @('apps.microsoft.com', 'www.microsoft.com', 'microsoft.com')) {
            throw 'Specify a 12-character Store product ID or an HTTPS apps.microsoft.com / microsoft.com product URL.'
        }
        $match = [regex]::Match($storeUri.AbsolutePath, '(?i)/([a-z0-9]{12})/?$')
        if (-not $match.Success) {
            throw 'The Store URL must end with a 12-character product ID (query strings are allowed).'
        }
        $id = $match.Groups[1].Value
    }
    $id = $id.ToUpperInvariant()

    $catalogUri = "https://displaycatalog.mp.microsoft.com/v7.0/products/${id}?market=US&languages=en-US"
    Write-Verbose "Looking up Microsoft Store product $id"
    $catalog = Invoke-RestMethod -Uri $catalogUri -TimeoutSec 60
    $productFamilies = @()
    $categories = @(
        foreach ($sku in $catalog.Product.DisplaySkuAvailabilities) {
            $fulfillment = $sku.Sku.Properties.FulfillmentData
            if ($fulfillment -is [string] -and -not [string]::IsNullOrWhiteSpace($fulfillment)) {
                $fulfillment = $fulfillment | ConvertFrom-Json
            }
            if ($fulfillment.WuCategoryId) {
                ([Guid]$fulfillment.WuCategoryId).ToString()
            }
            if ($fulfillment.PackageFamilyName) {
                $productFamilies += [string]$fulfillment.PackageFamilyName
            }
        }
    ) | Select-Object -Unique
    if (-not $categories) {
        throw "Product $id has no Store delivery category. It may be unavailable, restricted, or a non-packaged desktop app."
    }

    $cookieResponse = Invoke-StoreDeliveryRequest -Action GetCookie -Body @"
<GetCookie xmlns="$serviceNamespace">
  <oldCookie /><lastChange>2015-10-21T17:01:07Z</lastChange>
  <currentTime>$([DateTime]::UtcNow.ToString('o'))</currentTime><protocolVersion>1.40</protocolVersion>
</GetCookie>
"@
    $cookie = $cookieResponse.SelectSingleNode("//*[local-name()='GetCookieResult']")
    if ($null -eq $cookie -or $null -eq $cookie.SelectSingleNode("*[local-name()='EncryptedData']")) {
        throw 'Microsoft delivery service did not return a cookie.'
    }

    $flightRing = @{ Retail = 'Retail'; RP = 'RP'; Slow = 'WIS'; Fast = 'WIF' }[$Ring]
    $deviceAttributes = "FlightRing=$flightRing;OSVersion=10.0.26100.0;OSArchitecture=AMD64;DeviceFamily=Windows.Desktop;OSSkuId=48;InstallationType=Client;App=WU;AppVer=10.0.26100.0;TelemetryLevel=3;IsFlightingEnabled=1;BranchReadinessLevel=CB;CurrentBranch=ge_release;"
    $packages = @{}
    foreach ($category in $categories) {
        $updates = @{}
        $installedIds = [Collections.Generic.HashSet[int]]::new()
        foreach ($rootId in @(1, 2, 3)) {
            [void]$installedIds.Add($rootId)
        }
        $cachedIds = [Collections.Generic.HashSet[int]]::new()
        $syncComplete = $false
        for ($page = 0; $page -lt 20; $page++) {
            $installedXml = ($installedIds | Sort-Object | ForEach-Object { "<int>$_</int>" }) -join ''
            $cachedXml = ($cachedIds | Sort-Object | ForEach-Object { "<int>$_</int>" }) -join ''
            $sync = Invoke-StoreDeliveryRequest -Action SyncUpdates -Body @"
<SyncUpdates xmlns="$serviceNamespace">
  <cookie>$($cookie.InnerXml)</cookie>
  <parameters>
    <ExpressQuery>false</ExpressQuery>
    <InstalledNonLeafUpdateIDs>$installedXml</InstalledNonLeafUpdateIDs>
    <OtherCachedUpdateIDs>$cachedXml</OtherCachedUpdateIDs>
    <SkipSoftwareSync>false</SkipSoftwareSync>
    <NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>
    <FilterAppCategoryIds><CategoryIdentifier><Id>$category</Id></CategoryIdentifier></FilterAppCategoryIds>
    <TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled>
    <AlsoPerformRegularSync>false</AlsoPerformRegularSync>
    <ComputerSpec />
    <ExtendedUpdateInfoParameters>
      <XmlUpdateFragmentTypes><XmlUpdateFragmentType>Extended</XmlUpdateFragmentType></XmlUpdateFragmentTypes>
      <Locales><string>en-US</string><string>en</string></Locales>
    </ExtendedUpdateInfoParameters>
    <ClientPreferredLanguages><string>en-US</string></ClientPreferredLanguages>
    <ProductsParameters>
      <SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>
      <DeviceAttributes>$deviceAttributes</DeviceAttributes>
      <CallerAttributes>Interactive=1;IsSeeker=0;</CallerAttributes><Products />
    </ProductsParameters>
  </parameters>
</SyncUpdates>
"@
            $newCookie = $sync.SelectSingleNode("//*[local-name()='NewCookie']")
            if ($null -ne $newCookie) {
                $cookie = $newCookie
            }
            $newIdCount = 0
            foreach ($update in $sync.SelectNodes("//*[local-name()='NewUpdates']/*[local-name()='UpdateInfo']")) {
                $updateId = [int]$update.SelectSingleNode("*[local-name()='ID']").InnerText
                if ($cachedIds.Add($updateId)) {
                    $newIdCount++
                }
                if ($update.SelectSingleNode("*[local-name()='IsLeaf']").InnerText -eq 'false') {
                    [void]$installedIds.Add($updateId)
                }
            }
            foreach ($xmlNode in $sync.SelectNodes("//*[local-name()='Xml']")) {
                # Identity and file metadata arrive as separate escaped fragments keyed by ID.
                $updateId = $xmlNode.ParentNode.SelectSingleNode("*[local-name()='ID']").InnerText
                if (-not $updates.ContainsKey($updateId)) {
                    $updates[$updateId] = New-Object System.Xml.XmlDocument
                    $updates[$updateId].XmlResolver = $null
                    $updates[$updateId].LoadXml('<Update />')
                }
                $fragment = New-Object System.Xml.XmlDocument
                $fragment.XmlResolver = $null
                $fragment.LoadXml("<Update>$($xmlNode.InnerText)</Update>")
                foreach ($child in $fragment.DocumentElement.ChildNodes) {
                    [void]$updates[$updateId].DocumentElement.AppendChild($updates[$updateId].ImportNode($child, $true))
                }
            }
            $truncated = $sync.SelectSingleNode("//*[local-name()='Truncated']")
            if ($newIdCount -eq 0 -and ($null -eq $truncated -or $truncated.InnerText -eq 'false')) {
                $syncComplete = $true
                break
            }
        }
        if (-not $syncComplete) {
            throw 'Microsoft update synchronization did not complete in 20 requests. Refusing to return an incomplete package list.'
        }
        foreach ($fragment in $updates.Values) {
            $identity = $fragment.SelectSingleNode("/Update/*[local-name()='UpdateIdentity']")
            $metadata = $fragment.SelectSingleNode("//*[local-name()='AppxMetadata']")
            if ($null -eq $metadata) {
                continue
            }
            $files = @($fragment.SelectNodes("//*[local-name()='Files']/*[local-name()='File']"))
            if ($null -eq $identity -or $files.Count -eq 0) {
                throw 'Microsoft returned package metadata without an update identity or file list.'
            }
            $moniker = $metadata.GetAttribute('PackageMoniker')
            $identityParts = $moniker.Split('_')
            if ($identityParts.Count -ne 5) {
                throw "Microsoft returned an unrecognized package identity: $moniker"
            }
            $family = "$($identityParts[0])_$($identityParts[4])"
            $packageArchitecture = if ($moniker -match '_(x64|x86|arm64|arm|neutral)_') {
                $Matches[1]
            } else {
                throw "Microsoft returned an unrecognized package architecture: $moniker"
            }
            if ($Architecture -ne 'All' -and $packageArchitecture -notin @($Architecture, 'neutral')) {
                continue
            }
            $key = "$($identity.GetAttribute('UpdateID')):$($identity.GetAttribute('RevisionNumber'))"
            $packages[$key] = @{
                Identity = $identity
                Files = $files
                Moniker = $moniker
                Architecture = $packageArchitecture
                Family = $family
                IsMainPackage = $family -in $productFamilies
            }
        }
    }
    if ($packages.Count -eq 0) {
        throw "No package metadata matched product $id and architecture $Architecture. Anonymous access or this device profile may not be supported."
    }

    $results = @(
        foreach ($package in $packages.Values) {
            $locations = Invoke-StoreDeliveryRequest -Action GetExtendedUpdateInfo2 -Secured -Body @"
<GetExtendedUpdateInfo2 xmlns="$serviceNamespace">
  <updateIDs><UpdateIdentity>
    <UpdateID>$($package.Identity.GetAttribute('UpdateID'))</UpdateID>
    <RevisionNumber>$($package.Identity.GetAttribute('RevisionNumber'))</RevisionNumber>
  </UpdateIdentity></updateIDs>
  <infoTypes><XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType></infoTypes>
  <deviceAttributes>$deviceAttributes</deviceAttributes>
</GetExtendedUpdateInfo2>
"@
            foreach ($file in $package.Files) {
                $name = $file.GetAttribute('FileName')
                if ($name -notmatch '\.(appx|appxbundle|msix|msixbundle|eappx|eappxbundle|emsix|emsixbundle)$') {
                    continue
                }
                $digest = $file.GetAttribute('Digest')
                $matchingLocations = @(
                    $locations.SelectNodes("//*[local-name()='FileLocation']") |
                        Where-Object {
                            $digestNode = $_.SelectSingleNode("*[local-name()='FileDigest']")
                            $null -ne $digestNode -and $digestNode.InnerText -ceq $digest
                        }
                )
                if ($matchingLocations.Count -eq 0) {
                    throw "Microsoft returned no download location for $name. The package may require an entitlement."
                }
                foreach ($location in $matchingLocations) {
                    $urlNode = $location.SelectSingleNode("*[local-name()='Url']")
                    $downloadUri = $null
                    if ($null -eq $urlNode -or
                        -not [Uri]::TryCreate($urlNode.InnerText, [UriKind]::Absolute, [ref]$downloadUri) -or
                        $downloadUri.Scheme -notin @('https', 'http') -or
                        -not $downloadUri.Host.EndsWith('.microsoft.com', [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Microsoft returned an unexpected download URL for $name."
                    }
                    [pscustomobject]@{
                        ProductId = $id
                        PackageMoniker = $package.Moniker
                        Architecture = $package.Architecture
                        PackageFamilyName = $package.Family
                        IsMainPackage = $package.IsMainPackage
                        FileName = $name
                        IsEncrypted = [IO.Path]::GetExtension($name) -match '^\.e'
                        Size = [long]$file.GetAttribute('Size')
                        Digest = $digest
                        DigestAlgorithm = $file.GetAttribute('DigestAlgorithm')
                        Sha256Digest = ($file.SelectSingleNode("*[local-name()='AdditionalDigest' and @Algorithm='SHA256']")).InnerText
                        Url = $downloadUri.AbsoluteUri
                    }
                }
            }
        }
    )
    if ($results.Count -eq 0) {
        throw "Microsoft returned no APPX/MSIX package links for product $id."
    }
    $results | Sort-Object -Property PackageMoniker, FileName, Url -Unique
}

function Save-MicrosoftStorePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProductId,
        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    $Links = @(Get-MicrosoftStorePackageUrl -ProductId $ProductId -Architecture All)
    $Candidates = @(
        foreach ($Link in $Links) {
            if ($Link.PackageMoniker -notmatch '^([A-Za-z0-9.-]+)_([0-9]+(?:\.[0-9]+){3})_(x64|x86|arm64|arm|neutral)_([A-Za-z0-9.~+-]*)_([A-Za-z0-9]+)$') {
                throw "Unrecognized Store package identity: $($Link.PackageMoniker)"
            }
            $PackageVersion = [version]$Matches[2]
            $PackageArchitecture = $Matches[3]
            $Group = "$($Matches[1])_$($Matches[3])_$($Matches[4])_$($Matches[5])"
            if ($PackageArchitecture -notin @('x64', 'x86', 'neutral')) {
                continue
            }
            [pscustomobject]@{
                Link = $Link
                Version = $PackageVersion
                Architecture = $PackageArchitecture
                ResourceId = $Matches[4]
                Group = $Group
                Extension = [IO.Path]::GetExtension($Link.FileName).ToLowerInvariant()
            }
        }
    )
    $MainCandidates = @($Candidates | Where-Object {
        $_.Link.IsMainPackage -and $_.Architecture -in @('x64', 'neutral') -and $_.ResourceId -in @('', '~')
    })
    if ($MainCandidates.Count -eq 0) {
        throw "Store product $ProductId has no identifiable x64/neutral main package."
    }
    $LatestMainVersion = ($MainCandidates | Sort-Object Version -Descending | Select-Object -First 1).Version
    $Main = $MainCandidates |
        Where-Object { $_.Version -eq $LatestMainVersion -and -not $_.Link.IsEncrypted } |
        Sort-Object @{ Expression = { if ($_.Architecture -eq 'x64') { 0 } else { 1 } } },
            @{ Expression = { if ($_.Extension -in @('.msixbundle', '.appxbundle')) { 0 } else { 1 } } },
            @{ Expression = { $_.Link.PackageMoniker } } |
        Select-Object -First 1
    if ($null -eq $Main) {
        throw "The newest Store package for $ProductId ($LatestMainVersion) is encrypted; refusing to downgrade or obtain a license implicitly."
    }
    $Selected = @($Main)
    foreach ($Group in @($Candidates | Where-Object { -not $_.Link.IsMainPackage } | Group-Object Group)) {
        $LatestVersion = ($Group.Group | Sort-Object Version -Descending | Select-Object -First 1).Version
        $Dependency = $Group.Group |
            Where-Object { $_.Version -eq $LatestVersion -and -not $_.Link.IsEncrypted } |
            Sort-Object @{ Expression = { $_.Link.FileName } } |
            Select-Object -First 1
        if ($null -eq $Dependency) {
            throw "The newest Store dependency '$($Group.Name)' is encrypted; it cannot be staged for offline provisioning."
        }
        $Selected += $Dependency
    }

    foreach ($Package in $Selected) {
        $Link = $Package.Link
        if ($Package.Extension -notin @('.msix', '.appx', '.msixbundle', '.appxbundle')) {
            throw "Unsupported Store package extension: $($Package.Extension)"
        }
        $Destination = $OutputDirectory
        if (-not $Link.IsMainPackage) {
            $Destination = Join-Path $OutputDirectory "Dependencies\$($Package.Architecture)"
        }
        New-Item -Path $Destination -ItemType Directory -Force | Out-Null
        $FileName = "$($Link.PackageMoniker)$($Package.Extension)"
        $FilePath = Join-Path $Destination $FileName
        $PartialPath = "$FilePath.partial"
        $Algorithm = [string]$Link.DigestAlgorithm
        $Digest = [string]$Link.Digest
        if (-not [string]::IsNullOrWhiteSpace($Link.Sha256Digest)) {
            $Algorithm = 'SHA256'
            $Digest = [string]$Link.Sha256Digest
        }
        if ($Algorithm -notin @('SHA1', 'SHA256') -or [string]::IsNullOrWhiteSpace($Digest) -or $Link.Size -le 0) {
            throw "Store package '$FileName' has no supported digest or valid byte size."
        }
        $ExpectedHash = [BitConverter]::ToString([Convert]::FromBase64String($Digest)).Replace('-', '')
        $DownloadUri = [uri]$Link.Url
        if ($DownloadUri.Scheme -notin @('https', 'http') -or
            -not $DownloadUri.Host.EndsWith('.microsoft.com', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unexpected Store download URL for '$FileName'."
        }
        if ($DownloadUri.Scheme -eq 'http') {
            if ($Algorithm -ne 'SHA256') {
                throw "Store HTTP download '$FileName' requires a SHA256 digest from Microsoft's HTTPS metadata."
            }
            Write-Warning "Store CDN supplied HTTP for '$FileName'; verifying SHA256 from Microsoft's HTTPS metadata before accepting it."
        }
        try {
            Write-Verbose "Downloading Store package '$FileName' ($($Link.Size) bytes)."
            Invoke-WebRequest -UseBasicParsing -Uri $DownloadUri -OutFile $PartialPath -TimeoutSec 300 -MaximumRedirection 0 | Out-Null
            if ((Get-Item -LiteralPath $PartialPath).Length -ne $Link.Size) {
                throw "Store package byte-size mismatch for '$FileName'."
            }
            if ((Get-FileHash -LiteralPath $PartialPath -Algorithm $Algorithm).Hash -cne $ExpectedHash) {
                throw "Store package $Algorithm mismatch for '$FileName'."
            }
            Move-Item -LiteralPath $PartialPath -Destination $FilePath -Force
        }
        finally {
            if (Test-Path -LiteralPath $PartialPath) {
                Remove-Item -LiteralPath $PartialPath -Force
            }
        }
    }
}

function Invoke-WingetOrStoreDownload {
    [CmdletBinding()]
    param(
        [string]$ProductId,
        [string[]]$WingetArguments,
        [string]$OutputDirectory,
        [bool]$AllowStoreFallback
    )

    $Messages = @()
    $FailureReason = 'winget is not available on this system.'
    if (Get-Command -Name winget -ErrorAction SilentlyContinue) {
        try {
            $WingetOutput = @(& winget @WingetArguments 2>&1)
            $WingetExitCode = $LASTEXITCODE
            $Messages = @($WingetOutput | Where-Object {
                $_ -match '^Found |[Dd]ownloaded:|[Ee]rror|[Ff]ailed|[Cc]ould not|[Dd]oes not support'
            })
            if ($WingetExitCode -ne 0) {
                $Detail = ($WingetOutput | Select-Object -Last 1 | Out-String).Trim()
                $FailureReason = "winget download failed with exit code $WingetExitCode. $Detail"
            }
            elseif ($AllowStoreFallback -and -not @(Get-ChildItem -LiteralPath $OutputDirectory -File |
                Where-Object { $_.Extension -in @('.msix', '.msixbundle', '.appx', '.appxbundle') }).Count) {
                $FailureReason = 'winget returned success but downloaded no main APPX/MSIX package.'
            }
            else {
                return [pscustomobject]@{ Source = 'WinGet'; Messages = $Messages }
            }
        }
        catch {
            $FailureReason = "winget could not complete: $($_.Exception.Message)"
        }
    }
    if (-not $AllowStoreFallback) {
        throw $FailureReason
    }
    Write-Warning "[$ProductId] $FailureReason Falling back to Microsoft's undocumented Store delivery service."
    # Discard incomplete WinGet payloads before producing the replacement layout.
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
    Save-MicrosoftStorePackages -ProductId $ProductId -OutputDirectory $OutputDirectory
    return [pscustomobject]@{ Source = 'MicrosoftStore'; Messages = $Messages }
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

    # Collect all x86, x64, and neutral dep files from every app subfolder.
    # DISM requires both x86 and x64 dependency packages on x64 target images.
    # Arm/Arm64 packages are excluded as they do not apply to x64 AVD hosts.
    $AllDeps = Get-ChildItem -Path $ParentDir -Directory |
        Where-Object { $_.Name -ne 'SharedDependencies' } |
        ForEach-Object {
            Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Extension -in $PkgExts -and
                    $_.FullName  -match '(?i)\\dependencies\\' -and
                    $_.Name      -match '(?i)_(x86|x64|neutral)[._]'
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

$downloadFilePath = (Join-Path -Path $PSScriptRoot -ChildPath "shared\data\$downloadsParametersPrefix.downloads.parameters.json")
if ((!$SkipDownloadingNewSources) -and (Test-Path -Path $downloadFilePath)) {

    Write-Output ""
    Write-Output "=== Phase 1: Download ==="
    $DownloadDir = Join-Path -Path $TempArtifactsDir -ChildPath 'sources'
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
            Write-Warning "Winget is still not available after registration attempt. Eligible Store entries will use the direct Store fallback; other winget-based downloads will be skipped."
        }
    }

    $packageCount = ($Downloads.PSObject.Properties.Name).Count
    Write-Output "Processing $packageCount package(s) from '$downloadFilePath'."

    # Cache release metadata by repository so multiple assets requested from the same release
    # are resolved atomically and do not consume one GitHub API request per asset.
    $GitHubReleaseCache = @{}

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
        $DownloadAssets = @()
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
            Write-Output "[$SoftwareName] Retrieving URL from Edge Updates API..."
            $APIUrl = $Download.APIUrl
            $EdgeUpdatesJSON = Invoke-WebRequest -Uri $APIUrl -UseBasicParsing
            $content = $EdgeUpdatesJSON.content | ConvertFrom-Json
            $Edgereleases = ($content | Where-Object { $_.Product -eq 'Stable' }).releases
            $latestrelease = $Edgereleases | Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq 'x64' } | Sort-Object ProductVersion | Select-Object -Last 1
            $EdgeLatestStableVersion = $latestrelease.ProductVersion
            If ($null -ne $Download.APIArtifact -and $Download.APIArtifact -ne '') {
                # Generic artifact selector: find the named artifact from the latest Stable release
                $DownloadUrl = ($latestrelease.artifacts | Where-Object { $_.ArtifactName -eq $Download.APIArtifact }).Location
                Write-Verbose "[$SoftwareName] Resolved '$($Download.APIArtifact)' v$EdgeLatestStableVersion URL: $DownloadUrl"
            }
            Else {
                # Default (legacy): fetch the policy templates CAB matching the Stable version
                $policyfiles = ($content | Where-Object { $_.Product -eq 'Policy' }).releases
                $latestPolicyFile = $policyfiles | Where-Object { $_.ProductVersion -eq $EdgeLatestStableVersion }
                If (-not($latestPolicyFile)) {
                    $latestPolicyFile = $policyfiles | Sort-Object ProductVersion | Select-Object -Last 1
                }
                $DownloadUrl = $latestPolicyFile.artifacts.Location
                Write-Verbose "[$SoftwareName] Resolved URL: $DownloadUrl"
            }
        }
        ElseIf ($null -ne $Download.GitHubRepo -and $Download.GitHubRepo -ne '') {
            $Repo = $Download.GitHubRepo
            $ReleasesUri = "https://api.github.com/repos/$Repo/releases/latest"
            Write-Output "[$SoftwareName] Retrieving URL from GitHub ($Repo)..."
            If (-not $GitHubReleaseCache.ContainsKey($Repo)) {
                $GitHubReleaseCache[$Repo] = Invoke-RestMethod -Method GET -Uri $ReleasesUri
            }
            $FileNamePatterns = @($Download.GitHubFileNamePatterns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            If ($FileNamePatterns.Count -gt 0) {
                foreach ($FileNamePattern in $FileNamePatterns) {
                    $MatchingAssets = @($GitHubReleaseCache[$Repo].assets | Where-Object name -like $FileNamePattern)
                    If ($MatchingAssets.Count -ne 1) {
                        Throw "[$SoftwareName] Expected exactly one GitHub release asset matching '$FileNamePattern' in '$Repo'; found $($MatchingAssets.Count)."
                    }
                    $DownloadAssets += [pscustomobject]@{
                        Name = [string]$MatchingAssets[0].name
                        Url = [string]$MatchingAssets[0].browser_download_url
                        Digest = [string]$MatchingAssets[0].digest
                    }
                }
                Write-Output "[$SoftwareName] Resolved $($DownloadAssets.Count) asset(s) from release '$($GitHubReleaseCache[$Repo].tag_name)'."
            }
            Else {
                $FileNamePattern = $Download.GitHubFileNamePattern
                $MatchingAssets = @($GitHubReleaseCache[$Repo].assets | Where-Object name -like $FileNamePattern)
                If ($MatchingAssets.Count -ne 1) {
                    Throw "[$SoftwareName] Expected exactly one GitHub release asset matching '$FileNamePattern' in '$Repo'; found $($MatchingAssets.Count)."
                }
                $DownloadUrl = $MatchingAssets[0].browser_download_url
                Write-Verbose "[$SoftwareName] Resolved URL: $DownloadUrl"
            }
        }
        If ($UseWinget) {
            $PreserveLayout = ($null -ne $Download.WingetPreserveLayout -and [bool]$Download.WingetPreserveLayout)
            $WingetArch = if ($null -ne $Download.Architecture -and $Download.Architecture -ne '') {
                [string]$Download.Architecture
            } else { 'x64' }
            $WingetSource = if ($null -ne $Download.WingetSource -and $Download.WingetSource -ne '') {
                [string]$Download.WingetSource
            } elseif ($PreserveLayout) { 'msstore' } else { '' }
            $StoreFallbackEligible = $downloadsParametersPrefix -eq 'public' -and
                $PreserveLayout -and $Download.WingetId -match '^[A-Za-z0-9]{12}$' -and
                $WingetSource -eq 'msstore' -and $WingetArch -in @('x64', 'neutral')
            If (-not (Get-Command -Name 'winget' -ErrorAction SilentlyContinue) -and -not $StoreFallbackEligible) {
                Write-Warning "[$SoftwareName] Skipping: winget is not available on this system."
            }
            Else {
                Write-Output "[$SoftwareName] Downloading via winget (Id: $($Download.WingetId))..."
                # WingetPreserveLayout: skip rename and preserve the downloaded folder structure as-is.
                # Use this for MSIX/UWP apps where winget creates a versioned bundle + Dependencies subfolder.
                Try {
                    $TempSoftwareDownloadDir = Join-Path -Path $DownloadDir -ChildPath ($SoftwareName.Replace(' ', '_'))
                    If (Test-Path -Path $TempSoftwareDownloadDir) {
                        Remove-Item -Path $TempSoftwareDownloadDir -Recurse -Force
                    }
                    New-Item -Path $TempSoftwareDownloadDir -ItemType Directory -Force | Out-Null
                    $DestFileName = $Download.DestinationFileName
                    $DestFileFullName = if ($PreserveLayout) { $null } else {
                        Join-Path $TempSoftwareDownloadDir -ChildPath $DestFileName
                    }
                    $VersionText = @()
                    $VersionText += "SoftwareName = $SoftwareName"
                    $VersionText += "WingetId = $($Download.WingetId)"
                    # Resolve architecture: honour a per-entry override, otherwise default to x64.
                    # Set Architecture to 'neutral' to omit --architecture entirely (needed for
                    # multi-arch Store bundles that winget cannot match to a specific arch).
                    # Valid winget values: x86, x64, arm, arm64.
                    $WingetArguments = @(
                        'download', '--id', $Download.WingetId, '--exact',
                        '--download-directory', $TempSoftwareDownloadDir,
                        '--skip-license', '--accept-source-agreements', '--accept-package-agreements',
                        '--disable-interactivity'
                    )
                    If ($WingetSource -notin @('', 'msstore', 'winget')) {
                        Throw "WingetSource for '$SoftwareName' must be 'msstore' or 'winget'."
                    }
                    If ($WingetSource -ne '') {
                        Write-Output "[$SoftwareName] Source       : $WingetSource"
                        $WingetArguments += @('--source', $WingetSource)
                    }
                    If ($WingetArch -eq 'neutral') {
                        Write-Output "[$SoftwareName] Architecture : (omitted - neutral/multi-arch)"
                    }
                    Else {
                        Write-Output "[$SoftwareName] Architecture : $WingetArch"
                        $WingetArguments += @('--architecture', $WingetArch)
                    }

                    $DownloadResult = Invoke-WingetOrStoreDownload -ProductId $Download.WingetId `
                        -WingetArguments $WingetArguments -OutputDirectory $TempSoftwareDownloadDir `
                        -AllowStoreFallback $StoreFallbackEligible
                    $VersionText += "DownloadProvider = $($DownloadResult.Source)"
                    $DownloadResult.Messages |
                        ForEach-Object { Write-Output "[$SoftwareName]  $_" }
                    If ($PreserveLayout) {
                        # Preserve the full downloaded layout (bundle + Dependencies subfolder).
                        # Do not rename any files; the install script will discover them by extension.

                        $PruneExts = @('.msixbundle', '.appxbundle', '.msix', '.appx')

                        # Community winget manifests can provide MSIX framework dependencies as
                        # zip archives. Expand them so the dependency packages can be consolidated
                        # into SharedDependencies for offline image provisioning.
                        $DependencyArchives = Get-ChildItem -Path $TempSoftwareDownloadDir -Recurse -File -Filter '*.zip' |
                            Where-Object { $_.FullName -match '(?i)\\dependencies\\' }
                        foreach ($DependencyArchive in $DependencyArchives) {
                            $DependencyExtractPath = Join-Path -Path $DependencyArchive.DirectoryName -ChildPath $DependencyArchive.BaseName
                            Write-Output "[$SoftwareName] Expanding dependency archive: $($DependencyArchive.Name)"
                            Expand-Archive -LiteralPath $DependencyArchive.FullName -DestinationPath $DependencyExtractPath -Force
                        }

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

                        # --- Prune Arm/Arm64 dependency packages ---
                        # Keep x86, x64, and neutral packages. DISM requires both x86 and
                        # x64 on x64 target images. Arm/Arm64 packages are not applicable
                        # to x64 AVD hosts and are pruned to keep the upload size reasonable.
                        Get-ChildItem -Path $TempSoftwareDownloadDir -Recurse -File |
                            Where-Object {
                                $_.Extension -in $PruneExts -and
                                $_.FullName  -match '(?i)\\dependencies\\' -and
                                $_.Name      -notmatch '(?i)_(x86|x64|neutral)[._]'
                            } | ForEach-Object {
                                Write-Output "[$SoftwareName] Pruning non-applicable dep : $($_.Name)"
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
                    Write-Error "Error downloading '$SoftwareName' using WinGet/Store: $_."
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
        ElseIf ($DownloadAssets.Count -gt 0) {
            Write-Output "[$SoftwareName] Downloading $($DownloadAssets.Count) grouped GitHub release asset(s)..."
            $DestFolders = @(if (@($Download.DestinationFolders).Count -gt 0) { $Download.DestinationFolders } else { '' })
            $PrimaryDestinationDir = Join-Path -Path $ArtifactsDir -ChildPath $DestFolders[0]
            If (-not (Test-Path -Path $PrimaryDestinationDir)) {
                New-Item -Path $PrimaryDestinationDir -ItemType Directory -Force | Out-Null
            }
            foreach ($CleanupPattern in @($Download.DestinationCleanupPatterns)) {
                Get-ChildItem -LiteralPath $PrimaryDestinationDir -File -Filter $CleanupPattern -ErrorAction SilentlyContinue |
                    Remove-Item -Force
            }
            $VersionText = @(
                "SoftwareName = $SoftwareName"
                "GitHubRepo = $Repo"
                "GitHubRelease = $($GitHubReleaseCache[$Repo].tag_name)"
            )
            foreach ($DownloadAsset in $DownloadAssets) {
                $DownloadedAssetPath = @(Get-InternetFile `
                    -Url $DownloadAsset.Url `
                    -OutputDirectory $PrimaryDestinationDir `
                    -OutputFileName $DownloadAsset.Name)[-1]
                If (-not (Test-Path -LiteralPath $DownloadedAssetPath -PathType Leaf)) {
                    Throw "[$SoftwareName] GitHub release asset '$($DownloadAsset.Name)' was not downloaded."
                }
                If (-not [string]::IsNullOrWhiteSpace($DownloadAsset.Digest)) {
                    If ($DownloadAsset.Digest -notmatch '^sha256:([0-9A-Fa-f]{64})$') {
                        Throw "[$SoftwareName] Unsupported digest '$($DownloadAsset.Digest)' for '$($DownloadAsset.Name)'."
                    }
                    $ExpectedHash = $Matches[1].ToUpperInvariant()
                    $ActualHash = (Get-FileHash -LiteralPath $DownloadedAssetPath -Algorithm SHA256).Hash
                    If ($ActualHash -ne $ExpectedHash) {
                        Throw "[$SoftwareName] SHA256 mismatch for '$($DownloadAsset.Name)'."
                    }
                }
                $VersionText += "Downloaded File = $($DownloadAsset.Name)"
            }
            $VersionText += "Downloaded on = $(Get-Date)"
            $VersionText += "--------------------------------------------------"
            Add-Content -Path $FileVersionInfoFile -Value $VersionText

            $copySize = [math]::Round((($DownloadAssets | ForEach-Object {
                (Get-Item -LiteralPath (Join-Path $PrimaryDestinationDir $_.Name)).Length
            } | Measure-Object -Sum).Sum) / 1MB, 1)
            Write-Output "[$SoftwareName] Downloaded grouped assets directly to '$($DestFolders[0])' ($copySize MB)."

            foreach ($DestFolder in @($DestFolders | Select-Object -Skip 1)) {
                $DestinationDir = Join-Path -Path $ArtifactsDir -ChildPath $DestFolder
                If (-not (Test-Path -Path $DestinationDir)) {
                    New-Item -Path $DestinationDir -ItemType Directory -Force | Out-Null
                }
                foreach ($CleanupPattern in @($Download.DestinationCleanupPatterns)) {
                    Get-ChildItem -LiteralPath $DestinationDir -File -Filter $CleanupPattern -ErrorAction SilentlyContinue |
                        Remove-Item -Force
                }
                foreach ($DownloadAsset in $DownloadAssets) {
                    Copy-Item -LiteralPath (Join-Path $PrimaryDestinationDir $DownloadAsset.Name) -Destination $DestinationDir -Force
                }
            }

            if ($CopyDownloadsToCustomerArtifacts) {
                foreach ($DestFolder in $DestFolders) {
                    $CustomerDestinationDir = Join-Path -Path $CustomerArtifactsDir -ChildPath $DestFolder
                    If (-not (Test-Path -Path $CustomerDestinationDir)) {
                        New-Item -Path $CustomerDestinationDir -ItemType Directory -Force | Out-Null
                    }
                    foreach ($CleanupPattern in @($Download.DestinationCleanupPatterns)) {
                        Get-ChildItem -LiteralPath $CustomerDestinationDir -File -Filter $CleanupPattern -ErrorAction SilentlyContinue |
                            Remove-Item -Force
                    }
                    foreach ($DownloadAsset in $DownloadAssets) {
                        Copy-Item -LiteralPath (Join-Path $PrimaryDestinationDir $DownloadAsset.Name) -Destination $CustomerDestinationDir -Force
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
            If ([string]::IsNullOrWhiteSpace($DestFileName)) {
                Write-Warning "[$SoftwareName] Skipping: entry has no DownloadUrl and no DestinationFileName. Add a DestinationFileName to enable pre-staged file lookup."
            }
            Else {
                $DestFolders = if ($Download.DestinationFolders.Count -gt 0) { $Download.DestinationFolders } else { @('') }
                $PreStagedPaths = $DestFolders | ForEach-Object {
                    if ([string]::IsNullOrEmpty($_)) {
                        Join-Path -Path $ArtifactsDir -ChildPath $DestFileName
                    } else {
                        Join-Path -Path $ArtifactsDir -ChildPath (Join-Path -Path $_ -ChildPath $DestFileName)
                    }
                }
                $PreStagedFile = $PreStagedPaths | Where-Object { Test-Path -Path $_ } | Select-Object -First 1
                If ($null -ne $PreStagedFile) {
                    Write-Output "[$SoftwareName] No download URL configured - using pre-staged file found in artifacts directory."
                }
                Else {
                    Write-Warning "[$SoftwareName] No download URL configured and '$DestFileName' was not found in the artifacts directory. If you have enabled the corresponding feature in your image build, pre-stage this file in customer/artifacts/ before running. If you are not using this software, no action is needed."
                }
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
If ($LocalPackageMode) {
    Write-Output "=== Phase 3: Export ==="
    If ($PSCmdlet.ShouldProcess($ResolvedOutputPath, "Copy packaged artifacts to local folder")) {
        If (-not (Test-Path -Path $ResolvedOutputPath)) {
            New-Item -Path $ResolvedOutputPath -ItemType Directory -Force | Out-Null
        }
        $PackagedArtifacts = Get-ChildItem -Path $TempArtifactsDir -File
        $PackagedArtifacts | Copy-Item -Destination $ResolvedOutputPath -Force
        Write-Output "Export complete: $($PackagedArtifacts.Count) artifact file(s) written to '$ResolvedOutputPath'."
    }
}
Else {
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
If ($LocalPackageMode) {
    Write-Output "Artifacts path  : $ResolvedOutputPath"
}
Else {
    Write-Output "Artifacts URL   : $ArtifactsContainerUrl"
}
Write-Verbose ("[{0} exited]" -f $MyInvocation.MyCommand)
