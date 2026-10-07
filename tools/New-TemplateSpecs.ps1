[CmdletBinding()]
param (
    [string]$ResourceGroupName,
    [Parameter(Mandatory=$true)]
    [string]$Location,
    [bool]$createResourceGroup = $true,
    [bool]$createSharedServices = $false,
    [bool]$createNetwork = $false,
    [bool]$createCustomImage = $true,
    [bool]$createImageManagement = $false,
    [bool]$createHostPool = $true,
    [bool]$createAutomatedHostPool = $false,
    [bool]$CreateAddOns = $true,
    [ValidateNotNull()]
    [object]$NamingConvention = @{
        components = @('resourceType', 'workload', 'purpose', 'location')
        delimiter = '-'
        workload = 'avd'
    },
    [bool]$incrementVersion = $true
)

$ErrorActionPreference = 'Stop'
$namingConventionSupplied = $PSBoundParameters.ContainsKey('NamingConvention')

function Get-ObjectPropertyValue {
    param (
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName,
        [object]$DefaultValue
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($PropertyName) -and $null -ne $InputObject[$PropertyName]) {
            return $InputObject[$PropertyName]
        }

        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -ne $property -and $null -ne $property.Value) {
        return $property.Value
    }

    return $DefaultValue
}

function New-ConventionName {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Components,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Delimiter,
        [Parameter(Mandatory = $true)]
        [string]$ResourceTypeCode,
        [Parameter(Mandatory = $true)]
        [string]$Purpose,
        [Parameter(Mandatory = $true)]
        [string]$LocationAbbreviation,
        [AllowEmptyString()]
        [string]$Workload = '',
        [AllowEmptyString()]
        [string]$Environment = '',
        [AllowEmptyString()]
        [string]$Freeform1 = '',
        [AllowEmptyString()]
        [string]$Freeform2 = ''
    )

    $values = @{
        resourceType = $ResourceTypeCode
        purpose = $Purpose
        location = $LocationAbbreviation
        workload = $Workload
        environment = $Environment
        freeform1 = $Freeform1
        freeform2 = $Freeform2
    }

    $nameParts = foreach ($component in $Components) {
        if ($component -ne 'none' -and -not [string]::IsNullOrWhiteSpace([string]$values[$component])) {
            [string]$values[$component]
        }
    }

    if ($nameParts.Count -eq 0) {
        throw "The naming convention produced an empty name for purpose '$Purpose'."
    }

    return [string]::Join($Delimiter, $nameParts)
}

$Context = Get-AzContext
If ($null -eq $Context) {
    Throw 'You are not logged in to Azure. Please login to azure before continuing'
    Exit
}

# Load location abbreviations and resource type abbreviations
$locationsPath = Join-Path $PSScriptRoot -ChildPath '..\deployments\shared\data\locations.json'
$resourceAbbreviationsPath = Join-Path $PSScriptRoot -ChildPath '..\deployments\shared\data\resourceAbbreviations.json'
$locations = Get-Content -Path $locationsPath -Raw | ConvertFrom-Json
$resourceAbbreviations = Get-Content -Path $resourceAbbreviationsPath -Raw | ConvertFrom-Json

# Determine cloud environment and get location abbreviation
$cloud = $Context.Environment.Name
$isAirGappedCloud = $cloud -like 'US*'
$locationsEnvProperty = if ($isAirGappedCloud) { 'other' } else { $cloud }
$locationProperty = $locations.$locationsEnvProperty
$locationForLookup = if ($isAirGappedCloud -and $Location.Length -gt 5) {
    $Location.Substring(5)
}
else {
    $Location
}

$locationAbbr = $locationProperty.$locationForLookup.abbreviation

if ($null -eq $locationAbbr) {
    Write-Warning "Could not find abbreviation for location '$Location'. Using full location name."
    $locationAbbr = $Location
}

$components = @(Get-ObjectPropertyValue -InputObject $NamingConvention -PropertyName 'components' -DefaultValue @('resourceType', 'workload', 'purpose', 'location'))
$allowedComponents = @('resourceType', 'purpose', 'location', 'workload', 'environment', 'freeform1', 'freeform2', 'none')
$invalidComponents = @($components | Where-Object { $_ -notin $allowedComponents })
if ($invalidComponents.Count -gt 0) {
    throw "NamingConvention.components contains unsupported values: $($invalidComponents -join ', ')."
}
if ($components -notcontains 'purpose') {
    throw "NamingConvention.components must contain 'purpose' so each Template Spec receives a distinct name."
}

$delimiter = [string](Get-ObjectPropertyValue -InputObject $NamingConvention -PropertyName 'delimiter' -DefaultValue '-')
$workload = [string](Get-ObjectPropertyValue -InputObject $NamingConvention -PropertyName 'workload' -DefaultValue 'avd')
$environment = [string](Get-ObjectPropertyValue -InputObject $NamingConvention -PropertyName 'environment' -DefaultValue '')
$freeform1 = [string](Get-ObjectPropertyValue -InputObject $NamingConvention -PropertyName 'freeform1' -DefaultValue '')
$freeform2 = [string](Get-ObjectPropertyValue -InputObject $NamingConvention -PropertyName 'freeform2' -DefaultValue '')
$locationAbbreviationOverride = [string](Get-ObjectPropertyValue -InputObject $NamingConvention -PropertyName 'locationAbbreviation' -DefaultValue '')
if (-not [string]::IsNullOrWhiteSpace($locationAbbreviationOverride)) {
    $locationAbbr = $locationAbbreviationOverride
}

$resourceTypeCodes = Get-ObjectPropertyValue -InputObject $NamingConvention -PropertyName 'resourceTypeCodes' -DefaultValue @{}
$resourceGroupTypeCode = [string](Get-ObjectPropertyValue -InputObject $resourceTypeCodes -PropertyName 'resourceGroups' -DefaultValue $resourceAbbreviations.resourceGroups)
$templateSpecTypeCode = [string](Get-ObjectPropertyValue -InputObject $resourceTypeCodes -PropertyName 'templateSpecs' -DefaultValue $resourceAbbreviations.templateSpecs)

if ($null -eq $ResourceGroupName -or $ResourceGroupName -eq '') {
    Write-Output 'Resource Group Name not provided. Using default naming convention'
    $ResourceGroupName = New-ConventionName `
        -Components $components `
        -Delimiter $delimiter `
        -ResourceTypeCode $resourceGroupTypeCode `
        -Purpose 'operations' `
        -LocationAbbreviation $locationAbbr `
        -Workload $workload `
        -Environment $environment `
        -Freeform1 $freeform1 `
        -Freeform2 $freeform2
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

if ($createSharedServices) {
    $templateSpecs += @{
        Purpose = 'shared-services'
        DisplayName = 'AVD Shared Services'
        Description = 'Deploys optional shared AVD services: Key Vaults, monitoring resources, and an FSLogix Recovery Services vault and policy'
        TemplateFile = Join-Path $PSScriptRoot -ChildPath '..\deployments\sharedServices\sharedServices.json'
        UiFormDefinition = Join-Path $PSScriptRoot -ChildPath '..\deployments\sharedServices\uiFormDefinition.json'
    }
}

if ($createNetwork) {
    $templateSpecs += @{
        Purpose = 'networking'
        DisplayName = 'AVD Network Spoke'
        Description = 'Deploys the networking components to support Azure Virtual Desktop'
        TemplateFile = Join-Path $PSScriptRoot -ChildPath '..\deployments\networking\networking.json'
        UiFormDefinition = Join-Path $PSScriptRoot -ChildPath '..\deployments\networking\uiFormDefinition.json'
    }
}

if ($createCustomImage) {
    $templateSpecs += @{
        Purpose = 'custom-image'
        DisplayName = 'AVD Custom Image'
        Description = 'Generates a custom image for Azure Virtual Desktop'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\imageBuild\imageBuild.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\imageBuild\uiFormDefinition.json'
    }
}

if ($createImageManagement) {
    $templateSpecs += @{
        Purpose = 'image-management'
        DisplayName = 'AVD Image Management'
        Description = 'Deploys the image management resources for Azure Virtual Desktop'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\imageManagement\imageManagement.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\imageManagement\uiFormDefinition.json'
    }
}

if ($createHostPool) {
    $templateSpecs += @{
        Purpose = 'hostpool'
        DisplayName = 'AVD Host Pool'
        Description = 'Deploys an Azure Virtual Desktop Host Pool'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\hostpools\hostpool.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\hostpools\uiFormDefinition.json'
    }
}

if ($createAutomatedHostPool) {
    $templateSpecs += @{
        Purpose = 'automated-hostpool'
        DisplayName = 'AVD Automated Host Pool'
        Description = 'Deploys an Azure Commercial AVD pooled host pool with automated session host management'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\automatedHostPools\automatedHostPool.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\automatedHostPools\uiFormDefinition.json'
    }
}

if ($CreateAddOns) {
    $addOns = @(
        @{ Purpose = 'run-commands-on-vms'; PreserveLegacyWithoutWorkload = $true; DisplayName = 'Run Commands on VMs'; Description = 'Run scripts on Virtual Machines'; FolderName = 'runCommandsOnVms' },
        @{ Purpose = 'update-storage-account-key-on-session-hosts'; PreserveLegacyWithoutWorkload = $true; DisplayName = 'AVD Update Storage Account Key on Session Hosts'; Description = 'Update FSLogix Storage Account Key on Session Hosts'; FolderName = 'updateStorageAccountKeyOnSessionHosts' },
        @{ Purpose = 'fslogix-storage'; DisplayName = 'AVD FSLogix Storage'; Description = 'Deploys standalone Azure Files or Azure NetApp Files storage for FSLogix profile containers'; FolderName = 'fslogixStorage' },
        @{ Purpose = 'storage-quota-manager'; DisplayName = 'Azure Files Premium Quota Manager'; Description = 'Automatically monitors and increases Azure Files Premium file share quotas for FSLogix profile storage'; FolderName = 'storageQuotaManager' },
        @{ Purpose = 'session-host-replacer'; DisplayName = 'AVD Session Host Replacer'; Description = 'Automatically replaces aging or outdated session hosts based on configurable lifecycle policies'; FolderName = 'sessionHostReplacer' }
        @{ Purpose = 'session-host-maintenance'; DisplayName = 'Schedule AVD Session Host Maintenance'; Description = 'Schedules a guarded one-time maintenance replacement on an existing DeleteFirst Session Host Replacer'; FolderName = 'sessionHostMaintenance' }
        @{ Purpose = 'session-hosts'; DisplayName = 'AVD Session Hosts'; Description = 'Deploys AVD session hosts into an existing host pool resource group. Can be used standalone via the portal or as the Session Host Replacer deployment template'; FolderName = 'sessionHosts' }
        @{ Purpose = 'session-host-policy'; DisplayName = 'AVD Session Host Policy'; Description = 'Assigns reusable Azure Policy capabilities, including VM Applications, to a dedicated session-host resource group'; FolderName = 'sessionHostPolicy' }
        @{ Purpose = 'alerts'; DisplayName = 'AVD Alerts'; Description = 'Deploys Azure Monitor alerts for Azure Virtual Desktop'; FolderName = 'avdAlerts' }
    )

    foreach ($addOn in $addOns) {
        $templateSpecs += @{
            Purpose = $addOn.Purpose
            PreserveLegacyWithoutWorkload = $addOn.PreserveLegacyWithoutWorkload
            DisplayName = $addOn.DisplayName
            Description = $addOn.Description
            TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath "..\deployments\add-ons\$($addOn.FolderName)\main.json"
            UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath "..\deployments\add-ons\$($addOn.FolderName)\uiFormDefinition.json"
        }
    }
}

# Create all template specs using consistent naming convention
foreach ($templateSpec in $templateSpecs) {
    $templateSpecWorkload = if (
        -not $namingConventionSupplied -and
        $templateSpec.PreserveLegacyWithoutWorkload
    ) {
        ''
    }
    else {
        $workload
    }

    $templateSpecName = New-ConventionName `
        -Components $components `
        -Delimiter $delimiter `
        -ResourceTypeCode $templateSpecTypeCode `
        -Purpose $templateSpec.Purpose `
        -LocationAbbreviation $locationAbbr `
        -Workload $templateSpecWorkload `
        -Environment $environment `
        -Freeform1 $freeform1 `
        -Freeform2 $freeform2
    
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