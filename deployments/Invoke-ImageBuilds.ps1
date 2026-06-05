[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Location,
    [Parameter(Mandatory = $false)]
    [array]$ParameterFilePrefixes = @(),
    [Parameter(Mandatory = $false)]
    [string]$CustomerRootPath = ''
)

$ResolvedCustomerRootPath = if ([string]::IsNullOrWhiteSpace($CustomerRootPath)) {
    Join-Path -Path $PSScriptRoot -ChildPath '..\customer'
} else {
    $CustomerRootPath
}

$DeploymentJobs = @()
ForEach ($Prefix in $ParameterFilePrefixes) {
    $CustomerParameterFile = Join-Path -Path $ResolvedCustomerRootPath -ChildPath "parameters\imageBuild\$Prefix.imagebuild.parameters.json"
    $RepoParameterFile = Join-Path -Path $PSScriptRoot -ChildPath "imageBuild\parameters\$Prefix.imagebuild.parameters.json"
    $ParameterFile = if (Test-Path -Path $CustomerParameterFile) { $CustomerParameterFile } else { $RepoParameterFile }
    If (Test-Path -Path $ParameterFile) {
        Write-Output "Using parameter file: $ParameterFile"
        $Date = Get-Date -Format 'yyyyMMddhhmmss'
        $DeploymentJob = New-AzDeployment -Name "ImageBuild-$Prefix-$Date" -Location $Location -TemplateFile (Join-Path -Path $PSScriptRoot -ChildPath 'imageBuild\imageBuild.json') -TemplateParameterFile $ParameterFile -AsJob 
        Start-Sleep -Seconds 1
    }
    else {
        Write-Error "Parameter file not found. Checked: $CustomerParameterFile and $RepoParameterFile. Please create the parameter file and try again."
        exit
    }
    $DeploymentJobs += $DeploymentJob
}

Wait-Job -Job $DeploymentJobs
Receive-Job -Job $DeploymentJobs