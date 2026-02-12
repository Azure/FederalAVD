[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Location,
    [Parameter(Mandatory = $false)]
    [array]$ParameterFilePrefixes = @()
)

$DeploymentJobs = @()
ForEach ($Prefix in $ParameterFilePrefixes) {
    $ParameterFile = Join-Path -Path $PSScriptRoot -ChildPath "imageBuild\parameters\$Prefix.imagebuild.parameters.json"
    If (Test-Path -Path $ParameterFile) {
        Write-Output "Using parameter file: $ParameterFile"
        $Date = Get-Date -Format 'yyyyMMddhhmmss'
        $DeploymentJob = New-AzDeployment -Name "ImageBuild-$Prefix-$Date" -Location 'eastus2' -TemplateFile (Join-Path -Path $PSScriptRoot -ChildPath 'imageBuild\imageBuild.json') -TemplateParameterFile $ParameterFile -AsJob 
        Start-Sleep -Seconds 1
    }
    else {
        Write-Error "Parameter file $ParameterFile does not exist. Please create the parameter file and try again."
        exit
    }
    $DeploymentJobs += $DeploymentJob
}

Wait-Job -Job $DeploymentJobs
Receive-Job -Job $DeploymentJobs