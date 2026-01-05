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
    [bool]$nameConvResTypeAtEnd = $false,
    [bool]$incrementVersion = $true
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

# Build collection of template specs to create
$templateSpecs = @()

if ($createNetwork) {
    $templateSpecs += @{
        Name = 'avd-networking'
        DisplayName = 'AVD Network Spoke'
        Description = 'Deploys the networking components to support Azure Virtual Desktop'
        TemplateFile = Join-Path $PSScriptRoot -ChildPath 'networking\networking.json'
        UiFormDefinition = Join-Path $PSScriptRoot -ChildPath 'networking\uiFormDefinition.json'
    }
}

if ($createCustomImage) {
    $templateSpecs += @{
        Name = 'avd-custom-image'
        DisplayName = 'AVD Custom Image'
        Description = 'Generates a custom image for Azure Virtual Desktop'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath 'imageManagement\imageBuild\imageBuild.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath 'imageManagement\imageBuild\uiFormDefinition.json'
    }
}

if ($createHostPool) {
    $templateSpecs += @{
        Name = 'avd-hostpool'
        DisplayName = 'AVD Host Pool'
        Description = 'Deploys an Azure Virtual Desktop Host Pool'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath 'hostpools\hostpool.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath 'hostpools\uiFormDefinition.json'
    }
}

if ($CreateAddOns) {
    $addOns = @(
        @{ Name = 'run-commands-on-vms'; DisplayName = 'Run Commands on VMs'; Description = 'Run scripts on Virtual Machines'; FolderName = 'RunCommandsOnVms' },
        @{ Name = 'update-storage-account-key-on-session-hosts'; DisplayName = 'AVD Update Storage Account Key on Session Hosts'; Description = 'Update FSLogix Storage Account Key on Session Hosts'; FolderName = 'UpdateStorageAccountKeyOnSessionHosts' },
        @{ Name = 'avd-storage-quota-manager'; DisplayName = 'Azure Files Premium Quota Manager'; Description = 'Automatically monitors and increases Azure Files Premium file share quotas for FSLogix profile storage'; FolderName = 'StorageQuotaManager' },
        @{ Name = 'avd-session-host-replacer'; DisplayName = 'AVD Session Host Replacer'; Description = 'Automatically replaces aging or outdated session hosts based on configurable lifecycle policies'; FolderName = 'SessionHostReplacer' }
    )

    foreach ($addOn in $addOns) {
        $templateSpecs += @{
            Name = $addOn.Name
            DisplayName = $addOn.DisplayName
            Description = $addOn.Description
            TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath "add-ons\$($addOn.FolderName)\main.json"
            UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath "add-ons\$($addOn.FolderName)\uiFormDefinition.json"
        }
    }
}

# Create all template specs using consistent naming convention
foreach ($templateSpec in $templateSpecs) {
    if ($nameConvResTypeAtEnd) {
        $templateSpecName = "$($templateSpec.Name)-$locationAbbr-$($resourceAbbreviations.templateSpecs)"
    } else {
        $templateSpecName = "$($resourceAbbreviations.templateSpecs)-$($templateSpec.Name)-$locationAbbr"
    }
    
    # Determine version number
    $version = '1.0.0'
    if ($incrementVersion) {
        # Check if template spec already exists and increment version
        try {
            $existingTemplateSpec = Get-AzTemplateSpec -ResourceGroupName $ResourceGroupName -Name $templateSpecName -ErrorAction SilentlyContinue
            if ($existingTemplateSpec) {
                # Get all versions and find the latest
                $versions = Get-AzTemplateSpec -ResourceGroupName $ResourceGroupName -Name $templateSpecName -Version * -ErrorAction SilentlyContinue
                if ($versions) {
                    $latestVersion = $versions | ForEach-Object { 
                        [version]$_.Version 
                    } | Sort-Object -Descending | Select-Object -First 1
                    
                    # Increment major version
                    $newMajorVersion = $latestVersion.Major + 1
                    $version = "$newMajorVersion.0.0"
                    Write-Output "Existing template spec found. Incrementing version from $($latestVersion.ToString()) to $version"
                }
            }
        }
        catch {
            Write-Verbose "No existing template spec found. Using version 1.0.0"
        }
    }
    else {
        Write-Output "Version incrementing disabled. Using version 1.0.0 (will overwrite existing version)"
    }
    
    Write-Output "Creating $($templateSpec.DisplayName) Template Spec: $templateSpecName (v$version)"
    New-AzTemplateSpec `
        -ResourceGroupName $ResourceGroupName `
        -Name $templateSpecName `
        -DisplayName $templateSpec.DisplayName `
        -Description $templateSpec.Description `
        -TemplateFile $templateSpec.TemplateFile `
        -UiFormDefinitionFile $templateSpec.UiFormDefinition `
        -Location $Location `
        -Version $version `
        -Force
}

Write-Output "Template Specs Created. You can now find them in the Azure Portal in the '$ResourceGroupName' resource group"