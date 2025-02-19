<#
.SYNOPSIS
Run this script to automatically download any required files from the internet and put them in their prescribed folders and
then zip up all subfolders and upload all blobs to a storage account blob container for use by packer or Azure VM Image Builder.

#>

param(
    # the temp folder to where the artifact sources are prepared to be uploaded to the storage account.
    [Parameter(ParameterSetName='Deploy', Mandatory=$false)]
    [Parameter(ParameterSetName='UpdateOnly')]
    [string] $TempDir = "$Env:Temp",
    # Determines whether or not to delete existing blobs in the storage account before uploading new blobs.
    [Parameter(ParameterSetName='Deploy', Mandatory=$false)]
    [Parameter(ParameterSetName='UpdateOnly', Mandatory=$false)]
    [switch] $DeleteExistingBlobs,
    # Determines whether or not to download new sources from the internet.
    [Parameter(ParameterSetName='Deploy', Mandatory=$false)]
    [Parameter(ParameterSetName='UpdateOnly', Mandatory=$false)]
    [switch] $SkipDownloadingNewSources,
    # Determines whether or not to deploy/redeploy the storage account using BICEP and the parameter file contained in the storageAccount folder
    [Parameter(ParameterSetName='Deploy')]
    [switch]$DeployImageManagementResources,
    # The Location where the AVD Management Resources are being deployed.
    [Parameter(Mandatory=$true, ParameterSetName='Deploy')]
    [string]$Location,
    # Teams Tenant Type to determine download Url
    [Parameter(ParameterSetName='Deploy', Mandatory=$false)]
    [Parameter(ParameterSetName='UpdateOnly', Mandatory=$false)]
    [ValidateSet("Commercial","GovernmentCommunityCloud","GovernmentCommunityCloudHigh","DepartmentOfDefense")]
    [string] $TeamsTenantType = "Commercial",
    # The full resource ID of the existing storage account to update.
    [Parameter(ParameterSetName='UpdateOnly', Mandatory=$true)]
    [string]$StorageAccountResourceId,
    [Parameter(ParameterSetName='UpdateOnly', Mandatory=$true)]
    [string]$ManagedIdentityResourceID,
    # The container where the artifacts will be stored.
    [Parameter(ParameterSetName='UpdateOnly', Mandatory=$false)]
    [string]$ArtifactsContainerName = 'artifacts'
)

#region Variables
$ErrorActionPreference = 'Stop'

$Context = Get-AzContext

If ($null -eq $Context) {
    Throw 'You are not logged in to Azure. Please login to azure before continuing'
    Exit
} Else {
    $Environment = $Context.Environment.Name
    If ($Environment -eq 'AzureCloud' -or $Environment -eq 'AzureUSGovernment') {
        $downloadsParametersPrefix = 'public'
    } Else {
        $downloadsParametersPrefix = $Environment
    }
}

if ([string]::IsNullOrEmpty($TempDir)) {
    throw "The TempDir parameter cannot be null or empty."
}

$TempArtifactsDir = Join-Path -Path $TempDir -ChildPath 'Artifacts'

$Time = Get-Date -Format 'yyyyMMddhhmmss'
$ArtifactsDir = (Get-Item -Path (Join-Path -Path  $PSScriptRoot -ChildPath '..\.common\artifacts')).FullName
$FunctionsPath = (Get-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\.common\powerShellFunctions')).FullName

If (Test-Path -Path $TempArtifactsDir) {
    Remove-Item -Path $TempArtifactsDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -Path $TempArtifactsDir -ItemType Directory -Force


#endregion Variables

Write-Output ("[{0} entered]" -f $MyInvocation.MyCommand)

. "$FunctionsPath\GeneralDeployment\Get-MSIInfo.ps1"
. "$FunctionsPath\Storage\Compress-SubFolderContents.ps1"
. "$FunctionsPath\Storage\Get-InternetFile.ps1"
. "$FunctionsPath\Storage\Get-InternetUrl.ps1"
. "$FunctionsPath\Storage\Add-ContentToBlobContainer.ps1"

Write-Output "Working Directory: '$PSScriptRoot'"

#region Storage Account Deployment/update

Write-Verbose "###########################################################################"
Write-Verbose "## 1 - Deploy/Update Storage Account and gather variables                ##"
Write-Verbose "###########################################################################"

If ($DeployImageManagementResources) {
    $BicepPath = Join-Path -Path $PSScriptRoot -ChildPath 'imageManagement'
    $Template = (Get-ChildItem -Path $BicepPath -filter 'imageManagement.bicep').FullName
    $Parameters = (Get-ChildItem -Path (Join-Path -Path $BicepPath -ChildPath 'parameters') -Filter 'imagemanagement.parameters.json').FullName  
    Write-Output "Deploying Image Management Resources using BICEP template and parameter file."
    New-AzDeployment -Name "ImageManagement-$Time" -Location $Location -TemplateFile $Template -TemplateParameterFile $Parameters -verbose -artifactsContainerName $ArtifactsContainerName
    $DeploymentOutputs = (Get-AzSubscriptionDeployment -Name "ImageManagement-$Time").Outputs
    $StorageAccountResourceId = $DeploymentOutputs.storageAccountResourceId.value
    $ManagedIdentityResourceId = $DeploymentOutputs.managedIdentityResourceId.value
    $ArtifactsContainerName = $DeploymentOutputs.blobContainerName.value
    Write-Output "Setting variables based on Deployment Outputs:`n"
    Write-Output "`t`$StorageAccountResourceID  = $StorageAccountResourceId"
    Write-Output "`t`$ManagedIdentityResourceID = $ManagedIdentityResourceId"
    Write-Output "`t`$ArtifactsContainerName    = $ArtifactsContainerName"
} Else {
    Write-Output "Gathering variables from provided Parameters:`n"
    Write-Output "`t`$StorageAccountResourceId = '$StorageAccountResourceId'"
    Write-Output "`t`$ArtifactsContainerName = '$ArtifactsContainerName'"
    $SubscriptionId = ($StorageAccountResourceId -Split('/'))[2]
    Write-Output "`t`$SubscriptionId = '$SubscriptionId'"
    If ((Get-AzContext).Subscription -ne $SubscriptionId) { Set-AzContext -Subscription $SubscriptionId }
}
$StorageAccountResourceGroup = ($StorageAccountResourceId -split('/'))[4]
Write-Output "`t`$StorageAccountResourceGroup = $StorageAccountResourceGroup"
$StorageAccountName = ($StorageAccountResourceId -split('/'))[-1]
Write-Output "`t`$StorageAccountName = $StorageAccountName"
$BlobEndpoint = (Get-AzStorageAccount -ResourceGroupName $StorageAccountResourceGroup -StorageAccountName $StorageAccountName).PrimaryEndpoints.Blob
$ArtifactsContainerUrl = $BlobEndpoint + $ArtifactsContainerName.toLower() + '/'
Write-Output "`t`$ArtifactsContainerUrl = $ArtifactsContainerUrl"

#endregion

#region Download New Sources

$downloadFilePath = (Join-Path -Path "$PSScriptRoot\imageManagement\parameters" -ChildPath "$downloadsParametersPrefix.downloads.parameters.json")
if ((!$SkipDownloadingNewSources) -and (Test-Path -Path $downloadFilePath)) {
    Write-Verbose "###########################################################################"
    Write-Verbose "## 2 - Download New Source Files into the artifacts Directory            ##"
    Write-Verbose "###########################################################################"
    $DownloadDir = Join-Path -Path $TempArtifactsDir -ChildPath 'downloads'
    New-Item -Path $DownloadDir -ItemType Directory -Force
    $downloadJson = Get-Content -Path $downloadFilePath -Raw -ErrorAction 'Stop'
    try {
        $Downloads = $downloadJson | ConvertFrom-Json -ErrorAction 'Stop'
    }
    catch {
        Write-Error "Configuration JSON content could not be converted to a PowerShell object" -ErrorAction 'Stop'
    }
    foreach ($Download in $Downloads.Artifacts) {
        $SoftwareName = $Download.Name
        Write-Output "--------------------------------------------------"
        Write-Output "## Start - $SoftwareName ##"
        If ($Download.DownloadUrl -ne '') {
            Write-Output "Download Url directly available."
            $DownloadUrl = $Download.DownloadUrl
        }
        Elseif ($Download.WebSiteUrl -ne '' -and $Download.SearchString -ne '') {
            $WebSiteUrl = $Download.WebSiteUrl
            $SearchString = $Download.SearchString
            Write-Output "Determining download Url for latest version of '$SoftwareName' from '$WebsiteUrl'."
            $DownloadUrl = Get-InternetUrl -WebSiteUrl $WebSiteUrl -searchstring $SearchString -ErrorAction SilentlyContinue
        }
        Elseif ($Download.APIUrl -ne '') {
            $APIUrl = $Download.APIUrl
            $EdgeUpdatesJSON = Invoke-WebRequest -Uri $APIUrl -UseBasicParsing
            $content = $EdgeUpdatesJSON.content | ConvertFrom-Json      
            $Edgereleases = ($content | Where-Object {$_.Product -eq 'Stable'}).releases
            $latestrelease = $Edgereleases | Where-Object {$_.Platform -eq 'Windows' -and $_.Architecture -eq 'x64'} | Sort-Object ProductVersion | Select-Object -last 1
            $EdgeUrl = $latestrelease.artifacts.location
            $EdgeLatestStableVersion = $latestrelease.ProductVersion
            $policyfiles = ($content | Where-Object {$_.Product -eq 'Policy'}).releases
            $latestPolicyFile = $policyfiles | Where-Object {$_.ProductVersion -eq $EdgeLatestStableVersion}
            If (-not($latestPolicyFile)) {   
                $latestpolicyfile = $policyfiles | Sort-Object ProductVersion | Select-Object -last 1
            }  
            $EdgeTemplatesUrl = $latestpolicyfile.artifacts.Location   
            Write-Output "Getting download Urls for latest Edge browser and policy templates from '$APIUrl'."
            If ($SoftwareName -eq 'Edge Enterprise') {
                $DownloadUrl = $EdgeUrl
            }
            Elseif ($SoftwareName -eq 'Edge Enterprise Administrative Templates') {
                $DownloadUrl = $EdgeTemplatesUrl
            }
        }
        Elseif ($Download.GitHubRepo -ne '') {
            $Repo = $Download.GitHubRepo
            $FileNamePattern = $Download.GitHubFileNamePattern
            $ReleasesUri = "https://api.github.com/repos/$Repo/releases/latest"
            Write-Output "Retrieving the url of the latest version from '$Repo' Github repo."
            $DownloadUrl = ((Invoke-RestMethod -Method GET -Uri $ReleasesUri).assets | Where-Object name -like $FileNamePattern).browser_download_url
        }
        ElseIf ($Download.Name -like 'Teams Classic*') {
            Switch ($TeamsTenantType) {
                "Commercial" { $DownloadUrl = "https://teams.microsoft.com/downloads/desktopurl?env=production&plat=windows&arch=x64&managedInstaller=true&download=true" }
                "DepartmentOfDefense" { $DownloadUrl = "https://dod.teams.microsoft.us/downloads/desktopurl?env=production&plat=windows&arch=x64&managedInstaller=true&download=true" }
                "GovernmentCommunityCloud" { $DownloadUrl = "https://teams.microsoft.com/downloads/desktopurl?env=production&plat=windows&arch=x64&managedInstaller=true&ring=general_gcc&download=true" }
                "GovernmentCommunityCloudHigh" { $DownloadUrl = "https://gov.teams.microsoft.us/downloads/desktopurl?env=production&plat=windows&arch=x64&managedInstaller=true&download=true" }
                "USNat" { 
                    $WebSiteUrl = 'https://teams.eaglex.ic.gov/download'
                    $SearchString = 'Teams 64-bit'
                    $DownloadUrl = Get-InternetUrl -WebSiteUrl $WebSiteUrl -searchstring $SearchString
                    $DownloadUrl = $DownloadUrl -replace '.exe', '.msi'
                 }
                 "USSec" {
                    $webSiteUrl = 'https://teams.microsoft.scloud/download'
                    $SearchString = 'Teams 64-bit'
                    $DownloadUrl = Get-InternetUrl -WebSiteUrl $WebSiteUrl -searchstring $SearchString
                    $DownloadUrl = $DownloadUrl -replace '.exe', '.msi'
                 }
            }                        
        }

        If (($DownloadUrl -ne '') -and ($null -ne $DownloadUrl)) {
            Write-Output "Downloading '$SoftwareName'."
            Try {
                $TempSoftwareDownloadDir = Join-Path -Path $DownloadDir -ChildPath ($SoftwareName.Replace(' ', '_'))
                New-Item -Path $TempSoftwareDownloadDir -ItemType Directory -Force
                $DestFileName = $Download.DestinationFileName
                $DestFileFullName = Join-Path $TempSoftwareDownloadDir -ChildPath $DestFileName                
                # Build Version File for Artifacts Directory
                $VersionFileName = $DestFileName + "-fileinfo.txt"
                $VersionFilePath = Join-Path $TempSoftwareDownloadDir -ChildPath $VersionFileName
                $VersionText = @()
                $VersionText += "DownloadUrl = $DownloadUrl"
                Try {
                    # Not supplying the destination file name first so we can try to get the original file name that was downloaded for version information.
                    $DownloadedFileFullName = Get-InternetFile -Url $DownloadUrl -OutputDirectory $TempSoftwareDownloadDir -Verbose
                    $DownloadedFile = Split-Path -Path $DownloadedFileFullName -Leaf
                    If ($DownloadedFileFullName -ne $DestFileFullName) {
                        $VersionText += "Download File = $DownloadedFile"
                        Rename-Item -Path $DownloadedFileFullName -NewName $DestFileName -Force
                    }
                } Catch {
                    $DownloadedFileFullName = Get-InternetFile -Url $DownloadUrl -OutputDirectory $TempSoftwareDownloadDir -OutputFileName $DestFileName
                    $VersionText += "Download File = $(split-path $DownloadedFileFullName -leaf)"
                }
                Write-Output "Finished downloading '$SoftwareName' from Internet."
                Write-Output "Saving File Information to '$VersionFilePath'"
                If ([System.IO.Path]::GetExtension($DestFileFullName) -eq '.msi') {
                    $VersionText += Get-MSIInfo -Path $DestFileFullName
                } Elseif ([System.IO.Path]::GetExtension($DestFileFullName) -eq '.exe') {
                    $Version = (Get-ItemProperty -Path $DestFileFullName).VersionInfo | Select-Object ProductVersion, FileVersion
                    $VersionText += "$Version"
                }
                $VersionText | Out-File $VersionFilePath -Force
            }
            Catch {
                Write-Error "Error downloading software from '$DownloadUrl': $_."
            }
            Write-Output "Copying downloaded files to Artifacts Directory."
            $DestFolders = @()
            $DestFolders = $Download.DestinationFolders
            ForEach ($DestFolder in $DestFolders) {
                $DestinationDir = Join-Path -Path $ArtifactsDir -ChildPath $DestFolder
                If (-not (Test-Path -Path $DestinationDir)) {
                    New-Item -Path $DestinationDir -ItemType Directory -Force
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
else {
    Write-Verbose "No software configured to be downloaded"
}
#endregion Download New Sources

#region Compress contents of Artifacts Subdirectories

Write-Verbose "###########################################################################"
Write-Verbose "## 3 - Create Zip files for all subfolders inside ArtifactsDir.          ##"
Write-Verbose "###########################################################################"

if ($PSCmdlet.ShouldProcess("[$ArtifactsDir] subfolders as .zip and store them into [$TempArtifactsDir]", "Compress")) {
    Compress-SubFolderContents -SourceFolderPath $ArtifactsDir -DestinationFolderPath $TempArtifactsDir -Verbose
    Write-Verbose "Artifact Source Files compression finished"
}
Write-Verbose "Copying files in root of '$ArtifactsDir' to '$TempArtifactsDir'."
Get-ChildItem -Path $ArtifactsDir -file | Where-Object {$_.FullName -ne "$downloadFilePath"} | Copy-Item -Destination $TempArtifactsDir -Force

#endregion Compress Artifacts

#region Upload Blobs to Storage Account

Write-Verbose "###########################################################################"
Write-Verbose "## 4 - Upload all files in `$TempArtifactsDir to Storage Account.                 ##"
Write-Verbose "###########################################################################"
if ($DeleteExistingBlobs) {
    Write-Output "Existing Blobs in Storage Account '$StorageAccountName' are now being deleted."
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
    Get-AzStorageBlob -Container $ArtifactsContainerName -Context $ctx | Remove-AzStorageBlob -Force
}

if ($PSCmdlet.ShouldProcess("storage account '$storageAccountName'", "Uploading Blobs to")) {
    Add-ContentToBlobContainer -ResourceGroupName $StorageAccountResourceGroup -StorageAccountName $StorageAccountName -contentDirectories $TempArtifactsDir -TargetContainer $ArtifactsContainerName -Verbose
    Write-Verbose "Storage account content upload invocation finished"
}

Get-ChildItem -Path $TempArtifactsDir -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

#endregion

#region Output Storage Account Information
Write-Output "The 'ArtifactsLocation'                       = '$ArtifactsContainerUrl'."
Write-Output "The 'ArtifactsUserAssignedIdentityResourceId' = '$ManagedIdentityResourceId'."
#endregion
Write-Verbose ("[{0} exited]" -f $MyInvocation.MyCommand)
