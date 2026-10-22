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
    [bool]$createHostPoolPoc = $false,
    [bool]$createAutomatedHostPool = $false,
    [bool]$CreateAddOns = $true,
    [ValidateNotNull()]
    [object]$NamingConvention = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\deployments\shared\data\namingPolicy.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).defaults,
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

function Remove-TemplateSpecSchemaAnnotations {
    param (
        [Parameter(Mandatory = $true)]
        [Newtonsoft.Json.Linq.JObject]$Schema,
        [bool]$RemoveDescriptions
    )

    $metadata = $Schema['metadata']
    if ($metadata -is [Newtonsoft.Json.Linq.JObject]) {
        if ($RemoveDescriptions) {
            $metadata.Remove('description') | Out-Null
        }
        $metadata.Remove('__bicep_imported_from!') | Out-Null
        if (-not $metadata.get_HasValues()) {
            $Schema.Remove('metadata') | Out-Null
        }
    }

    # Visit schema children only, never user data in defaultValue or allowedValues.
    foreach ($collectionName in @('properties', 'mapping')) {
        $collection = $Schema[$collectionName]
        if ($collection -is [Newtonsoft.Json.Linq.JObject]) {
            foreach ($property in @($collection.Properties())) {
                if ($property.Value -is [Newtonsoft.Json.Linq.JObject]) {
                    Remove-TemplateSpecSchemaAnnotations -Schema $property.Value -RemoveDescriptions $RemoveDescriptions
                }
            }
        }
    }
    foreach ($childName in @('items', 'additionalProperties', 'discriminator')) {
        $child = $Schema[$childName]
        if ($child -is [Newtonsoft.Json.Linq.JObject]) {
            Remove-TemplateSpecSchemaAnnotations -Schema $child -RemoveDescriptions $RemoveDescriptions
        }
    }
    if ($Schema['prefixItems'] -is [Newtonsoft.Json.Linq.JArray]) {
        foreach ($child in $Schema['prefixItems']) {
            if ($child -is [Newtonsoft.Json.Linq.JObject]) {
                Remove-TemplateSpecSchemaAnnotations -Schema $child -RemoveDescriptions $RemoveDescriptions
            }
        }
    }
}

function Remove-TemplateSpecInternalAnnotations {
    param (
        [Parameter(Mandatory = $true)]
        [Newtonsoft.Json.Linq.JToken]$Node,
        [bool]$IsRoot = $true
    )

    if ($Node -is [Newtonsoft.Json.Linq.JObject]) {
        $isTemplate = [string]$Node['$schema'] -match '^https?://schema\.management\.azure\.com/schemas/[^/]+/(?:subscription|managementGroup|tenant)?deploymentTemplate\.json#?$'
        if ($isTemplate) {
            $metadata = $Node['metadata']
            if ($metadata -is [Newtonsoft.Json.Linq.JObject]) {
                $metadata.Remove('_generator') | Out-Null
                if (-not $metadata.get_HasValues()) {
                    $Node.Remove('metadata') | Out-Null
                }
            }
            foreach ($interfaceName in @('parameters', 'outputs', 'definitions')) {
                $interface = $Node[$interfaceName]
                if ($interface -is [Newtonsoft.Json.Linq.JObject]) {
                    foreach ($property in @($interface.Properties())) {
                        if ($property.Value -is [Newtonsoft.Json.Linq.JObject]) {
                            Remove-TemplateSpecSchemaAnnotations -Schema $property.Value -RemoveDescriptions (-not $IsRoot)
                        }
                    }
                }
            }
        }
        foreach ($property in @($Node.Properties())) {
            if ($property.Name -notin @('metadata', 'defaultValue', 'allowedValues', 'parameters', 'outputs', 'definitions')) {
                Remove-TemplateSpecInternalAnnotations -Node $property.Value -IsRoot ($IsRoot -and -not $isTemplate)
            }
        }
    }
    elseif ($Node -is [Newtonsoft.Json.Linq.JArray]) {
        foreach ($child in $Node) {
            Remove-TemplateSpecInternalAnnotations -Node $child -IsRoot $IsRoot
        }
    }
}

function New-TemplateSpecPublicationPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$TemplateFile,
        [Parameter(Mandatory = $true)]
        [string]$FormFile
    )

    $package = [Microsoft.Azure.Commands.ResourceManager.Cmdlets.Components.TemplateSpecPackagingEngine]::Pack($TemplateFile)
    $package.UIFormDefinition = [Newtonsoft.Json.Linq.JObject]::Parse(
        (Get-Content -LiteralPath $FormFile -Raw -ErrorAction Stop)
    )
    Remove-TemplateSpecInternalAnnotations -Node $package.RootTemplate
    foreach ($artifact in $package.Artifacts) {
        # A linked template is also a public deployment entry point; retain its interface help.
        Remove-TemplateSpecInternalAnnotations -Node $artifact.Template
    }
    return $package
}

function Get-TemplateSpecPublicationSize {
    param (
        [Parameter(Mandatory = $true)]
        $Package,
        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    $client = [Microsoft.Azure.Management.Resources.TemplateSpecsClient]::new(
        [Microsoft.Rest.TokenCredentials]::new('offline')
    )
    try {
        $model = [Microsoft.Azure.Management.Resources.Models.TemplateSpecVersion]::new()
        $model.Location = $Location
        $model.MainTemplate = $Package.RootTemplate
        $model.UiFormDefinition = $Package.UIFormDefinition
        $model.LinkedTemplates = [System.Collections.Generic.List[Microsoft.Azure.Management.Resources.Models.LinkedTemplateArtifact]]::new()
        foreach ($artifact in $Package.Artifacts) {
            $model.LinkedTemplates.Add($artifact)
        }
        $json = [Microsoft.Rest.Serialization.SafeJsonConvert]::SerializeObject($model, $client.SerializationSettings)
        return [Text.Encoding]::UTF8.GetByteCount($json)
    }
    finally {
        $client.Dispose()
    }
}

& (Join-Path $PSScriptRoot 'Sync-NamingPolicy.ps1') -Check

Import-Module Az.Resources -ErrorAction Stop
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
$namingPolicy = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\deployments\shared\data\namingPolicy.json') -Raw | ConvertFrom-Json

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

$components = @(Get-ObjectPropertyValue -InputObject $NamingConvention -PropertyName 'components' -DefaultValue $namingPolicy.defaults.components)
$allowedComponents = @('resourceType', 'purpose', 'location', 'workload', 'environment', 'freeform1', 'freeform2', 'none')
$invalidComponents = @($components | Where-Object { $_ -notin $allowedComponents })
if ($invalidComponents.Count -gt 0) {
    throw "NamingConvention.components contains unsupported values: $($invalidComponents -join ', ')."
}
if ($components -notcontains 'purpose') {
    throw "NamingConvention.components must contain 'purpose' so each Template Spec receives a distinct name."
}

$delimiter = [string](Get-ObjectPropertyValue -InputObject $NamingConvention -PropertyName 'delimiter' -DefaultValue $namingPolicy.defaults.delimiter)
$workload = [string](Get-ObjectPropertyValue -InputObject $NamingConvention -PropertyName 'workload' -DefaultValue $namingPolicy.defaults.workload)
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
        -Purpose ($namingPolicy.resources.operationsResourceGroup.purpose -join $delimiter) `
        -LocationAbbreviation $locationAbbr `
        -Workload $workload `
        -Environment $environment `
        -Freeform1 $freeform1 `
        -Freeform2 $freeform2
    Write-Output "Resource Group Name: $ResourceGroupName"
}

# Build collection of template specs to create
$templateSpecs = @()

if ($createSharedServices) {
    $templateSpecs += @{
        Purpose = $namingPolicy.templateSpecs.sharedServices
        DisplayName = 'AVD Shared Services'
        Description = 'Deploys or adopts shared AVD workspace, feed and global Private Link, Key Vault, monitoring, and FSLogix backup resources'
        TemplateFile = Join-Path $PSScriptRoot -ChildPath '..\deployments\sharedServices\sharedServices.json'
        UiFormDefinition = Join-Path $PSScriptRoot -ChildPath '..\deployments\sharedServices\uiFormDefinition.json'
    }
}

if ($createNetwork) {
    $templateSpecs += @{
        Purpose = $namingPolicy.templateSpecs.networking
        DisplayName = 'AVD Network Spoke'
        Description = 'Deploys the networking components to support Azure Virtual Desktop'
        TemplateFile = Join-Path $PSScriptRoot -ChildPath '..\deployments\networking\networking.json'
        UiFormDefinition = Join-Path $PSScriptRoot -ChildPath '..\deployments\networking\uiFormDefinition.json'
    }
}

if ($createCustomImage) {
    $templateSpecs += @{
        Purpose = $namingPolicy.templateSpecs.imageBuild
        DisplayName = 'AVD Custom Image'
        Description = 'Generates a custom image for Azure Virtual Desktop'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\imageBuild\imageBuild.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\imageBuild\uiFormDefinition.json'
    }
}

if ($createImageManagement) {
    $templateSpecs += @{
        Purpose = $namingPolicy.identifiers.imageManagement
        DisplayName = 'AVD Image Management'
        Description = 'Deploys the image management resources for Azure Virtual Desktop'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\imageManagement\imageManagement.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\imageManagement\uiFormDefinition.json'
    }
}

if ($createHostPool) {
    $templateSpecs += @{
        Purpose = $namingPolicy.templateSpecs.hostPool
        DisplayName = 'AVD Host Pool'
        Description = 'Orchestrates AVD Shared Services and a standard Azure Virtual Desktop host pool'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\hostpools\hostpool.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\hostpools\uiFormDefinition.json'
    }
}

if ($createHostPoolPoc) {
    $templateSpecs += @{
        Purpose = $namingPolicy.templateSpecs.hostPoolPoc
        DisplayName = 'AVD Standard PoC'
        Description = 'Deploys a disposable standard-management Azure Virtual Desktop demo with a standalone NAT-backed virtual network'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\hostpoolPoc\hostpoolPoc.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\hostpoolPoc\uiFormDefinition.json'
    }
}

if ($createAutomatedHostPool) {
    $templateSpecs += @{
        Purpose = $namingPolicy.templateSpecs.automatedHostPool
        DisplayName = 'AVD Automated Host Pool'
        Description = 'Orchestrates AVD Shared Services and an Azure Commercial pooled host pool with automated session host management'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\automatedHostPools\automatedHostPool.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\automatedHostPools\uiFormDefinition.json'
    }
}

if ($CreateAddOns) {
    $addOns = @(
        @{ Purpose = $namingPolicy.templateSpecs.runCommandsOnVms; PreserveLegacyWithoutWorkload = $true; DisplayName = 'Run Commands on VMs'; Description = 'Run scripts on Virtual Machines'; FolderName = 'runCommandsOnVms' },
        @{ Purpose = $namingPolicy.templateSpecs.updateStorageAccountKeyOnSessionHosts; PreserveLegacyWithoutWorkload = $true; DisplayName = 'AVD Update Storage Account Key on Session Hosts'; Description = 'Update FSLogix Storage Account Key on Session Hosts'; FolderName = 'updateStorageAccountKeyOnSessionHosts' },
        @{ Purpose = $namingPolicy.templateSpecs.fslogixStorage; DisplayName = 'AVD FSLogix Storage'; Description = 'Deploys standalone Azure Files or Azure NetApp Files storage for FSLogix profile containers'; FolderName = 'fslogixStorage' },
        @{ Purpose = $namingPolicy.templateSpecs.storageQuotaManager; DisplayName = 'Azure Files Premium Quota Manager'; Description = 'Automatically monitors and increases Azure Files Premium file share quotas for FSLogix profile storage'; FolderName = 'storageQuotaManager' },
        @{ Purpose = $namingPolicy.templateSpecs.sessionHostReplacer; DisplayName = 'AVD Session Host Replacer'; Description = 'Automatically replaces aging or outdated session hosts based on configurable lifecycle policies'; FolderName = 'sessionHostReplacer' }
        @{ Purpose = $namingPolicy.templateSpecs.sessionHostMaintenance; DisplayName = 'Schedule AVD Session Host Maintenance'; Description = 'Schedules a guarded one-time maintenance replacement on an existing DeleteFirst Session Host Replacer'; FolderName = 'sessionHostMaintenance' }
        @{ Purpose = $namingPolicy.resources.sessionHostsTemplateSpec.purpose -join $delimiter; DisplayName = 'AVD Session Hosts'; Description = 'Deploys AVD session hosts into an existing host pool resource group. Can be used standalone via the portal or as the Session Host Replacer deployment template'; FolderName = 'sessionHosts' }
        @{ Purpose = $namingPolicy.templateSpecs.sessionHostPolicy; DisplayName = 'AVD Session Host Policy'; Description = 'Assigns reusable Azure Policy capabilities, including VM Applications, to a dedicated session-host resource group'; FolderName = 'sessionHostPolicy' }
        @{ Purpose = $namingPolicy.resources.alertsAutomation.purpose -join $delimiter; DisplayName = 'AVD Alerts'; Description = 'Deploys Azure Monitor alerts for Azure Virtual Desktop'; FolderName = 'avdAlerts' }
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

$stagingDirectory = Join-Path ([IO.Path]::GetTempPath()) ("FederalAVD-TemplateSpecs-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDirectory -ErrorAction Stop | Out-Null
try {
    # Preflight every selection before creating resources or publishing any versions.
    foreach ($templateSpec in $templateSpecs) {
        $package = New-TemplateSpecPublicationPackage -TemplateFile $templateSpec.TemplateFile -FormFile $templateSpec.UiFormDefinition
        $payloadBytes = Get-TemplateSpecPublicationSize -Package $package -Location $Location
        $metadataAllowanceBytes = 16384
        if ($payloadBytes + $metadataAllowanceBytes -gt 2000000) {
            throw "$($templateSpec.DisplayName) requires $payloadBytes bytes plus a $metadataAllowanceBytes-byte publishing metadata allowance, exceeding the 2,000,000-byte Template Spec budget."
        }
        Write-Output "$($templateSpec.DisplayName): $payloadBytes publication bytes (plus $metadataAllowanceBytes-byte metadata allowance)."
        $targetDirectory = Join-Path $stagingDirectory ([string]$templateSpecs.IndexOf($templateSpec))
        [Microsoft.Azure.Commands.ResourceManager.Cmdlets.Components.TemplateSpecPackagingEngine]::Unpack(
            $package, $targetDirectory, 'main.json', 'uiFormDefinition.json'
        )
        $templateSpec.PublicationTemplateFile = Join-Path $targetDirectory 'main.json'
        $templateSpec.PublicationFormFile = Join-Path $targetDirectory 'uiFormDefinition.json'
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
            -TemplateFile $templateSpec.PublicationTemplateFile `
            -UiFormDefinitionFile $templateSpec.PublicationFormFile `
            -Location $Location `
            -Version $version `
            -Force
    }
}
finally {
    Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction Stop
}

Write-Output "Template Specs Created. You can now find them in the Azure Portal in the '$ResourceGroupName' resource group"