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
$FunctionsPath = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\.common\powerShellFunctions')).FullName

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

. "$FunctionsPath\GeneralDeployment\Get-MSIInfo.ps1"
. "$FunctionsPath\Storage\Compress-SubFolderContents.ps1"
. "$FunctionsPath\Storage\Get-InternetFile.ps1"
. "$FunctionsPath\Storage\Get-InternetUrl.ps1"
. "$FunctionsPath\Storage\Add-ContentToBlobContainer.ps1"

#region Download New Sources

$downloadFilePath = (Join-Path -Path "$PSScriptRoot\imageManagement\parameters" -ChildPath "$downloadsParametersPrefix.downloads.parameters.json")
if ((!$SkipDownloadingNewSources) -and (Test-Path -Path $downloadFilePath)) {

    Write-Verbose "###########################################################################"
    Write-Verbose "## 1 - Download New Source Files into the artifacts Directory            ##"
    Write-Verbose "###########################################################################"
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
        . "$FunctionsPath\Storage\Evergreen.ps1"
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

    foreach ($key in $Downloads.PSObject.Properties.Name) {
        $Download = $Downloads.$key
        $SoftwareName = $key
        Write-Output "--------------------------------------------------"
        Write-Output "## Start - $SoftwareName ##"
        $DownloadUrl = $null
        $UseWinget = $false
        If ($null -ne $Download.WingetId -and $Download.WingetId -ne '') {
            $UseWinget = $true
            Write-Output "Winget Id '$($Download.WingetId)' configured for '$SoftwareName'."
        }
        ElseIf (($null -ne $Download.WebSiteUrl -and $Download.WebSiteUrl -ne '') -and ($null -ne $Download.SearchString -and $Download.SearchString -ne '')) {
            $WebSiteUrl = $Download.WebSiteUrl
            $SearchString = $Download.SearchString
            Write-Output "Determining download Url for latest version of '$SoftwareName' from '$WebSiteUrl'."
            $DownloadUrl = Get-InternetUrl -WebSiteUrl $WebSiteUrl -searchstring $SearchString -ErrorAction SilentlyContinue
            If ($null -eq $DownloadUrl -and ($null -ne $Download.DownloadUrl -and $Download.DownloadUrl -ne '')) {
                Write-Output "Download Url directly available."
                $DownloadUrl = $Download.DownloadUrl
            }
        }
        ElseIf ($null -ne $Download.DownloadUrl -and $Download.DownloadUrl -ne '') {
            Write-Output "Download Url directly available."
            $DownloadUrl = $Download.DownloadUrl
        }
        ElseIf ($null -ne $Download.APIUrl -and $Download.APIUrl -ne '') {
            Write-Output "Retrieving the url of the latest version of the Edge Templates from API Url."
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
        }
        ElseIf ($null -ne $Download.GitHubRepo -and $Download.GitHubRepo -ne '') {
            $Repo = $Download.GitHubRepo
            $FileNamePattern = $Download.GitHubFileNamePattern
            $ReleasesUri = "https://api.github.com/repos/$Repo/releases/latest"
            Write-Output "Retrieving the url of the latest version from '$Repo' Github repo."
            $DownloadUrl = ((Invoke-RestMethod -Method GET -Uri $ReleasesUri).assets | Where-Object name -like $FileNamePattern).browser_download_url
        }
        ElseIf ($null -ne $Download.Evergreen) {
            Write-Output "Retrieving the url of the latest version from Evergreen."
            Write-Output "Evergreen Configuration: $($Download.Evergreen)"
            $DownloadUrl = Get-EvergreenAppUri -Evergreen $Download.Evergreen
        }

        If ($UseWinget) {
            If (-not (Get-Command -Name 'winget' -ErrorAction SilentlyContinue)) {
                Write-Warning "Skipping '$SoftwareName': winget is not available on this system."
            }
            Else {
                Write-Output "Downloading '$SoftwareName' via winget (Id: $($Download.WingetId))."
                Try {
                    $TempSoftwareDownloadDir = Join-Path -Path $DownloadDir -ChildPath ($SoftwareName.Replace(' ', '_'))
                    New-Item -Path $TempSoftwareDownloadDir -ItemType Directory -Force | Out-Null
                    $DestFileName = $Download.DestinationFileName
                    $DestFileFullName = Join-Path $TempSoftwareDownloadDir -ChildPath $DestFileName
                    $VersionText = @()
                    $VersionText += "SoftwareName = $SoftwareName"
                    $VersionText += "WingetId = $($Download.WingetId)"
                    & winget download --id $Download.WingetId --download-directory $TempSoftwareDownloadDir --accept-source-agreements --accept-package-agreements | Out-String | Write-Output
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
                    Write-Output "Finished downloading '$SoftwareName' via winget."
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
                ForEach ($DestFolder in $DestFolders) {
                    $DestinationDir = Join-Path -Path $ArtifactsDir -ChildPath $DestFolder
                    If (-not (Test-Path -Path $DestinationDir)) {
                        New-Item -Path $DestinationDir -ItemType Directory -Force | Out-Null
                    }
                    Get-ChildItem -Path $TempSoftwareDownloadDir | Copy-Item -Destination $DestinationDir -Force
                }
            }
        }
        ElseIf (($DownloadUrl -ne '') -and ($null -ne $DownloadUrl)) {
            Write-Output "Downloading '$SoftwareName'."
            Try {
                $TempSoftwareDownloadDir = Join-Path -Path $DownloadDir -ChildPath ($SoftwareName.Replace(' ', '_'))
                New-Item -Path $TempSoftwareDownloadDir -ItemType Directory -Force | Out-Null
                $DestFileName = $Download.DestinationFileName
                $DestFileFullName = Join-Path $TempSoftwareDownloadDir -ChildPath $DestFileName
                $VersionText = @()
                $VersionText += "SoftwareName = $SoftwareName"
                $VersionText += "DownloadUrl = $DownloadUrl"
                Try {
                    $DownloadedFileFullName = Get-InternetFile -Url $DownloadUrl -OutputDirectory $TempSoftwareDownloadDir -Verbose
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
                Write-Output "Finished downloading '$SoftwareName' from Internet."
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
            ForEach ($DestFolder in $DestFolders) {
                $DestinationDir = Join-Path -Path $ArtifactsDir -ChildPath $DestFolder
                If (-not (Test-Path -Path $DestinationDir)) {
                    New-Item -Path $DestinationDir -ItemType Directory -Force | Out-Null
                }
                Get-ChildItem -Path $TempSoftwareDownloadDir | Copy-Item -Destination $DestinationDir -Force
            }
        }
        Else {
            Write-Error "No Internet URL found for '$SoftwareName'."
        }
        Write-Output "## End - $SoftwareName ##"
        Write-Output "--------------------------------------------------"
    }
    Get-Item -Path $DownloadDir | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
Else {
    Write-Verbose "No software configured to be downloaded, or -SkipDownloadingNewSources was specified."
}
#endregion Download New Sources

#region Compress Artifacts

Write-Verbose "###########################################################################"
Write-Verbose "## 2 - Create Zip files for all subfolders inside ArtifactsDir.          ##"
Write-Verbose "###########################################################################"

if ($PSCmdlet.ShouldProcess("[$ArtifactsDir] subfolders as .zip and store them into [$TempArtifactsDir]", "Compress")) {
    Compress-SubFolderContents -SourceFolderPath $ArtifactsDir -DestinationFolderPath $TempArtifactsDir -Verbose
    Write-Verbose "Artifact compression finished."
}
Write-Verbose "Copying files in root of '$ArtifactsDir' to '$TempArtifactsDir'."
Get-ChildItem -Path $ArtifactsDir -File | Where-Object { $_.FullName -ne $downloadFilePath } | Copy-Item -Destination $TempArtifactsDir -Force

#endregion Compress Artifacts

#region Upload Blobs

Write-Verbose "###########################################################################"
Write-Verbose "## 3 - Upload all files in TempArtifactsDir to Storage Account.          ##"
Write-Verbose "###########################################################################"

if ($DeleteExistingBlobs) {
    Write-Output "Deleting existing blobs in '$StorageAccountName/$ArtifactsContainerName'."
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
    Get-AzStorageBlob -Container $ArtifactsContainerName -Context $ctx | Remove-AzStorageBlob -Force
}

if ($PSCmdlet.ShouldProcess("storage account '$StorageAccountName'", "Uploading blobs to")) {
    Add-ContentToBlobContainer -ResourceGroupName $StorageAccountResourceGroup -StorageAccountName $StorageAccountName -contentDirectories $TempArtifactsDir -TargetContainer $ArtifactsContainerName -Verbose
    Write-Verbose "Upload finished."
}

Get-ChildItem -Path $TempArtifactsDir -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

#endregion Upload Blobs

Write-Output "Artifacts container URL: '$ArtifactsContainerUrl'"
Write-Verbose ("[{0} exited]" -f $MyInvocation.MyCommand)
