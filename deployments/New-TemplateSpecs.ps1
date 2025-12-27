[CmdletBinding()]
param (
    [string]$ResourceGroupName,
    [Parameter(Mandatory=$true)]
    [string]$Location,
    [bool]$createResourceGroup = $true,
    [bool]$createNetwork = $true,
    [bool]$createCustomImage = $true,
    [bool]$createHostPool = $true,
    [bool]$CreateAddOns = $true,
    [bool]$nameConvResTypeAtEnd = $false
)

$ErrorActionPreference = 'Stop'

$Context = Get-AzContext
If ($null -eq $Context) {
    Throw 'You are not logged in to Azure. Please login to azure before continuing'
    Exit
}

# Load location abbreviations and resource type abbreviations
$locationsPath = Join-Path $PSScriptRoot -ChildPath '..\.common\data\locations.json'
$resourceAbbreviationsPath = Join-Path $PSScriptRoot -ChildPath '..\.common\data\resourceAbbreviations.json'
$locations = Get-Content -Path $locationsPath -Raw | ConvertFrom-Json
$resourceAbbreviations = Get-Content -Path $resourceAbbreviationsPath -Raw | ConvertFrom-Json

# Determine cloud environment and get location abbreviation
$cloud = $Context.Environment.Name
$locationsEnvProperty = if ($cloud -like 'AzureUSGovernment*') { 'other' } else { $cloud }
$locationProperty = $locations.$locationsEnvProperty

# Get location abbreviation - handle US Government cloud by removing 'usgov' prefix
$normalizedLocation = if ($cloud -like 'AzureUSGovernment*') { 
    $Location -replace '^usgov', '' 
} else { 
    $Location 
}
$locationAbbr = $locationProperty.$normalizedLocation.abbreviation

if ($null -eq $locationAbbr) {
    Write-Warning "Could not find abbreviation for location '$Location'. Using full location name."
    $locationAbbr = $Location
}

if ($null -eq $ResourceGroupName -or $ResourceGroupName -eq '') {
    Write-Output 'Resource Group Name not provided. Using default naming convention'
    if ($nameConvResTypeAtEnd) {
        $ResourceGroupName = "avd-management-$locationAbbr-$($resourceAbbreviations.resourceGroups)"
    } else {
        $ResourceGroupName = "$($resourceAbbreviations.resourceGroups)-avd-management-$locationAbbr"
    }
    Write-Output "Resource Group Name: $ResourceGroupName"
}

if ($createResourceGroup) {
    Write-Output "Searching for Resource Group: $ResourceGroupName"
    if (Get-AzResourceGroup | Where-Object { $_.ResourceGroupName -eq $ResourceGroupName }) {
        Write-Output "Resource Group $ResourceGroupName already exists"
    }
    else {
        Write-Output "Resource Group $ResourceGroupName does not exist. Creating Resource Group"
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location
    }
}

if ($createNetwork) {
    Write-Output 'Creating AVD Networking Template Spec'
    $templateFile = Join-Path $PSScriptRoot -ChildPath 'networking\networking.json'
    $uiFormDefinition = Join-Path $PSScriptRoot -ChildPath 'networking\uiFormDefinition.json'
    New-AzTemplateSpec -ResourceGroupName $ResourceGroupName -Name 'avd-Networking' -DisplayName 'Azure Virtual Desktop Networking' -Description 'Deploys the networking components to support Azure Virtual Desktop' -TemplateFile $templateFile -UiFormDefinitionFile $uiFormDefinition -Location $Location -Version '1.0.0' -Force
}

if ($createCustomImage) {
    Write-Output 'Creating AVD Custom Image Template Spec'
    $templateFile = Join-Path -Path $PSScriptRoot -ChildPath 'imageManagement\imageBuild\imageBuild.json'
    $uiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath 'imageManagement\imageBuild\uiFormDefinition.json'
    New-AzTemplateSpec -ResourceGroupName $ResourceGroupName -Name 'avd-custom-image' -DisplayName 'Azure Virtual Desktop Custom Image' -Description 'Generates a custom image for Azure Virtual Desktop' -TemplateFile $templateFile -UiFormDefinitionFile $uiFormDefinition -Location $Location -Version '1.0.0' -Force
}

if ($createHostPool) {
    $templateFile = Join-Path -Path $PSScriptRoot -ChildPath 'hostpools\hostpool.json'
    $uiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath 'hostpools\uiFormDefinition.json'
    Write-Output 'Creating AVD Host Pool Template Spec'
    New-AzTemplateSpec -ResourceGroupName $ResourceGroupName -Name 'avd-hostpool' -DisplayName 'Azure Virtual Desktop Host Pool' -Description 'Deploys an Azure Virtual Desktop Host Pool' -TemplateFile $templateFile -UiFormDefinitionFile $uiFormDefinition -Location $Location -Version '1.0.0' -Force
}

if ($CreateAddOns) {
    $addOns = @(
        @{ FolderName = 'RunCommandsOnVms'; Name = 'run-commands-on-vms'; DisplayName = 'Run Commands on VMs'; Description = 'Run scripts on Virtual Machines' },
        @{ FolderName = 'UpdateStorageAccountKeyOnSessionHosts'; Name = 'update-storage-account-key-on-session-hosts'; DisplayName = 'Update Storage Account Key on Session Hosts'; Description = 'Update FSLogix Storage Account Key on Session Hosts' },
        @{ FolderName = 'StorageQuotaManager'; Name = 'avd-storage-quota-manager'; DisplayName = 'Storage Quota Manager'; Description = 'Automatically monitors and increases Azure Files Premium file share quotas for FSLogix profile storage' },
        @{ FolderName = 'SessionHostReplacer'; Name = 'avd-session-host-replacer'; DisplayName = 'Session Host Replacer'; Description = 'Automatically replaces aging or outdated session hosts based on configurable lifecycle policies' }
    )

    foreach ($addOn in $addOns) {
        if ($nameConvResTypeAtEnd) {
            $templateSpecName = "$($addOn.Name)-$locationAbbr-$($resourceAbbreviations.templateSpecs)"
        } else {
            $templateSpecName = "$($resourceAbbreviations.templateSpecs)-$($addOn.Name)-$locationAbbr"
        }
        $templateFile = Join-Path -Path $PSScriptRoot -ChildPath "add-ons\$($addOn.FolderName)\main.json"
        $uiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath "add-ons\$($addOn.FolderName)\uiFormDefinition.json"
        Write-Output "Creating $($addOn.DisplayName) Template Spec: $templateSpecName"
        New-AzTemplateSpec -ResourceGroupName $ResourceGroupName -Name $templateSpecName -DisplayName $addOn.DisplayName -Description $addOn.Description -TemplateFile $templateFile -UiFormDefinitionFile $uiFormDefinition -Location $Location -Version '1.0.0' -Force
    }
}
Write-Output "Template Specs Created. You can now find them in the Azure Portal in the '$ResourceGroupName' resource group"