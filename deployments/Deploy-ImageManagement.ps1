<#
.SYNOPSIS
    Deploys AVD Image Management infrastructure using a named parameter file.

.DESCRIPTION
    Deploys the imageManagement.json ARM template using a parameter file. The script prefers
    customer-owned files in ..\customer\parameters\imageManagement\ and falls back to the repo
    examples in imageManagement\parameters\. Parameter files must follow the naming convention:
    <Prefix>.imageManagement.parameters.json

    After deployment, use Update-ImageArtifacts.ps1 to populate the artifacts
    storage account with software packages.

.PARAMETER Location
    Azure region for the subscription-scoped deployment (e.g. usgovvirginia, eastus2).
    Resources are deployed to the region specified inside the parameter file.

.PARAMETER ParameterFilePrefix
    Prefix of the parameter file to use. The script will look for:
    ..\customer\parameters\imageManagement\<Prefix>.imageManagement.parameters.json
    and then fall back to:
    imageManagement\parameters\<Prefix>.imageManagement.parameters.json

    Included example prefixes:
      basic            - Artifacts storage, public endpoint
      privateEndpoint  - Artifacts + logs storage, private endpoints
      serviceEndpoint  - Artifacts + logs storage, service endpoint subnets
      production       - Full production with CMK, remote gallery, IP rules, tags

.PARAMETER UpdateArtifacts
    When specified, automatically runs Update-ImageArtifacts.ps1 after a successful deployment
    using the artifactsStorageAccountResourceId from the deployment outputs. Skipped if no
    artifacts storage account was deployed.

.PARAMETER CustomerRootPath
    Optional root folder that contains customer-owned parameter files. Defaults to the repo-local
    customer folder next to the deployments folder. Useful when customers keep their overrides
    outside a freshly extracted repo zip.

.EXAMPLE
    .\.Deploy-ImageManagement.ps1 -Location usgovvirginia -ParameterFilePrefix basic

.EXAMPLE
    .\.Deploy-ImageManagement.ps1 -Location usgovvirginia -ParameterFilePrefix privateEndpoint

.EXAMPLE
    .\.Deploy-ImageManagement.ps1 -Location usgovvirginia -ParameterFilePrefix production

.EXAMPLE
    # Deploy infrastructure and immediately upload artifacts in one step
    .\.Deploy-ImageManagement.ps1 -Location usgovvirginia -ParameterFilePrefix basic -UpdateArtifacts
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$ParameterFilePrefix,

    [Parameter(Mandatory = $false)]
    [switch]$UpdateArtifacts,

    [Parameter(Mandatory = $false)]
    [string]$CustomerRootPath = ''
)

$ErrorActionPreference = 'Stop'

$TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath 'imageManagement\imageManagement.json'
$ResolvedCustomerRootPath = if ([string]::IsNullOrWhiteSpace($CustomerRootPath)) {
    Join-Path -Path $PSScriptRoot -ChildPath '..\customer'
} else {
    $CustomerRootPath
}
$CustomerParameterFile = Join-Path -Path $ResolvedCustomerRootPath -ChildPath "parameters\imageManagement\$ParameterFilePrefix.imageManagement.parameters.json"
$RepoParameterFile = Join-Path -Path $PSScriptRoot -ChildPath "imageManagement\parameters\$ParameterFilePrefix.imageManagement.parameters.json"
$ParameterFile = if (Test-Path -Path $CustomerParameterFile) { $CustomerParameterFile } else { $RepoParameterFile }
$DeploymentName = "ImageManagement-$ParameterFilePrefix-$(Get-Date -Format 'yyyyMMddHHmmss')"

if (-not (Test-Path -Path $TemplateFile)) {
    Write-Error "Template file not found: $TemplateFile"
    exit 1
}

if (-not (Test-Path -Path $ParameterFile)) {
    Write-Error "Parameter file not found. Checked: $CustomerParameterFile and $RepoParameterFile`nExpected naming convention: <Prefix>.imageManagement.parameters.json"
    exit 1
}

Write-Output "Deploying Image Management infrastructure..."
Write-Output "  Template   : $TemplateFile"
Write-Output "  Parameters : $ParameterFile"
Write-Output "  Location   : $Location"
Write-Output "  Deployment : $DeploymentName"
Write-Output ""

$Deployment = New-AzDeployment `
    -Name $DeploymentName `
    -Location $Location `
    -TemplateFile $TemplateFile `
    -TemplateParameterFile $ParameterFile `
    -Verbose

Write-Output ""
Write-Output "Deployment complete. Outputs:"
Write-Output "  Compute Gallery     : $($Deployment.Outputs.computeGalleryResourceId.Value)"
Write-Output "  Artifacts Storage   : $($Deployment.Outputs.artifactsStorageAccountResourceId.Value)"
Write-Output "  Artifacts Container : $($Deployment.Outputs.artifactsBlobContainerUrl.Value)"
Write-Output "  Managed Identity    : $($Deployment.Outputs.managedIdentityResourceId.Value)"
Write-Output "  Build Logs Storage  : $($Deployment.Outputs.buildLogsStorageAccountResourceId.Value)"
Write-Output "  Remote Gallery      : $($Deployment.Outputs.remoteComputeGalleryResourceId.Value)"
Write-Output ""

if ($UpdateArtifacts -and -not ([string]::IsNullOrEmpty($Deployment.Outputs.artifactsStorageAccountResourceId.Value))) {
    Write-Output "Next step: populate the artifacts storage account:"
    Write-Output "  .\Update-ImageArtifacts.ps1 -StorageAccountResourceId '$($Deployment.Outputs.artifactsStorageAccountResourceId.Value)'"
}