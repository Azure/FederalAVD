<#
.SYNOPSIS

Template Spec publisher that stores identical inline templates once.

.DESCRIPTION

Uses the active Azure context and the ARM REST API to publish the complete package.

Repeated nested templates and compiler annotations increase package size. To help
stay within the Template Spec content limit, the publisher filters annotations and
deduplicates eligible templates in an in-memory publication copy. Bicep sources
and tracked ARM files are not changed.

Annotation filtering removes Bicep compiler provenance (_generator and
__bicep_imported_from!) and nested-template parameter/output/type descriptions.
It does not strip metadata indiscriminately: top-level interface descriptions,
other interface metadata, validation constraints, resource/policy metadata,
function logic and descriptions, and the complete Portal form are preserved.
Filtering targets recognized template/schema locations, not similarly named
properties in literal application data. Full module documentation remains in
the repository sources.

After filtering, identical eligible nested templates are identified by SHA-256
and stored once as linked artifacts inside the same Template Spec version.
References use bundled relative paths, not public URLs or separately published
Template Specs. Only templates with explicit inner expression scope are extracted;
outer/default-scope subtrees stay inline to preserve expression behavior.
Unique inner-scope ancestors of extracted duplicates are also linked when needed
to preserve relative-link origin. Pre-existing relative template links are rejected.

Before any Azure writes, every selected package is serialized and size-checked,
including the main template, all linked artifacts, Portal form, and location
envelope. A 16,384-byte safety reserve is included in the 2,000,000-byte budget.
Exceeding that budget stops publication; output reports savings and headroom.
Offline checks do not prove Azure service acceptance or deployment compatibility.

See docs\design.md, sections Generated-template size budgets and Deduplicated
Template Spec publisher, for the design rationale and validation requirements.

The publishing resource group is named using the convention with purpose operations
unless ResourceGroupName overrides it. An existing group is reused; a missing group
is created automatically.

Use -WhatIf first and -TemplateSpecNameSuffix dedup-test for isolated test names.
Live publication and deployment validation are required before production use.

.PARAMETER Location

Required Azure region for the Template Specs and for a resource group if created.
Use the region name for the active Azure cloud, for example eastus or usgovvirginia.

.PARAMETER ResourceGroupName

Optional override for the publishing resource group. Normally omit this parameter:
the naming convention generates the name with purpose operations, for example
rg-avd-operations-use in eastus. Use the override to target a separately named group.
Whether generated or explicit, the group is reused if it exists and created if missing.

.PARAMETER NamingConvention

Optional hashtable or object using the deployment namingConvention schema, not a
file path or JSON string. The parameter declares these defaults:

  components = @('resourceType', 'workload', 'purpose', 'location')
  delimiter = '-'
  workload = 'avd'

The components array must include purpose so each Template Spec has a distinct name.
Other supported component values are environment, freeform1, freeform2, and none.
Optional properties include environment, freeform1, freeform2, locationAbbreviation,
and resourceTypeCodes (for example @{ resourceGroups = 'rg'; templateSpecs = 'ts' }).
Missing properties use defaults; empty component values are omitted from names.
This controls publishing names only, not the naming of resources later deployed
through the published forms. See docs\naming-convention.md for the full schema.

.PARAMETER incrementVersion
Defaults to true. Existing Template Specs get the next numeric major version.
Setting this to false publishes version 1.0.0, overwriting that version if present.

.PARAMETER TemplateSpecNameSuffix

Optional suffix appended to Template Spec names for isolated testing. It does not
change the publishing resource-group name.

.EXAMPLE

.\tools\New-TemplateSpecs.ps1 -Location eastus -WhatIf

Preview using default names, including resource group rg-avd-operations-use.
No resource group or Template Specs are written. Remove -WhatIf to publish.

.EXAMPLE

$naming = @{
    components = @('resourceType', 'workload', 'purpose', 'environment', 'location')
    delimiter = '-'
    workload = 'avd'
    environment = 'prod'
}
.\tools\New-TemplateSpecs.ps1 -Location eastus -NamingConvention $naming -WhatIf

Preview publishing into rg-avd-operations-prod-use, creating it if missing when
run without -WhatIf. No ResourceGroupName or creation flag is needed.

.EXAMPLE

.\tools\New-TemplateSpecs.ps1 -Location usgovvirginia -ResourceGroupName rg-template-catalog -WhatIf

Preview using an explicit publishing group while retaining default Template Spec
names. The group is reused or created automatically when run without -WhatIf.

.NOTES

Sign in and select the intended cloud and subscription before running the script.
Only Location is required. By default, Custom Image, Host Pool, and all add-on
Template Specs are selected. The other create parameters select additional entries;
they publish templates, not workloads. These parameters are booleans, so use
-createCustomImage $false, -createHostPool $false, or -CreateAddOns $false to
exclude the corresponding default selections.

Use Get-Help .\tools\New-TemplateSpecs.ps1 -Full to read this help.

#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [string]$ResourceGroupName = '',
    [Parameter(Mandatory=$true)]
    [string]$Location,
    [bool]$createSharedServices = $false,
    [bool]$createNetwork = $false,
    [bool]$createCustomImage = $true,
    [bool]$createImageManagement = $false,
    [bool]$createHostPool = $true,
    [bool]$createHostPoolPoc = $false,
    [bool]$createAutomatedHostPool = $false,
    [bool]$CreateAddOns = $true,
    [ValidateNotNull()]
    [object]$NamingConvention = @{
        components = @('resourceType', 'workload', 'purpose', 'location')
        delimiter = '-'
        workload = 'avd'
    },
    [bool]$incrementVersion = $true,
    [ValidatePattern('^[A-Za-z0-9_-]*$')]
    [string]$TemplateSpecNameSuffix = ''
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
            foreach ($namespace in $Node['functions']) {
                $members = $namespace['members']
                if ($members -is [Newtonsoft.Json.Linq.JObject]) {
                    foreach ($member in @($members.Properties())) {
                        if ($member.Value -is [Newtonsoft.Json.Linq.JObject]) {
                            Remove-TemplateSpecSchemaAnnotations -Schema $member.Value -RemoveDescriptions $false
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

function Get-DeduplicatedTemplateResources {
    param([Newtonsoft.Json.Linq.JObject]$Template)

    $result = [System.Collections.Generic.List[Newtonsoft.Json.Linq.JObject]]::new()
    $resources = $Template['resources']
    if ($resources -is [Newtonsoft.Json.Linq.JObject]) {
        foreach ($property in $resources.Properties()) {
            if ($property.Value -isnot [Newtonsoft.Json.Linq.JObject]) {
                throw "Invalid symbolic resource '$($property.Name)'."
            }
            $result.Add($property.Value)
        }
    }
    elseif ($resources -is [Newtonsoft.Json.Linq.JArray]) {
        foreach ($resource in $resources) {
            if ($resource -isnot [Newtonsoft.Json.Linq.JObject]) {
                throw 'Invalid resource in the template resources array.'
            }
            $result.Add($resource)
        }
    }
    elseif ($null -ne $resources) {
        throw 'Template resources must be an object or array.'
    }
    return ,$result
}

function Get-DeduplicatedTemplateHash {
    param([Newtonsoft.Json.Linq.JObject]$Template)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Template.ToString([Newtonsoft.Json.Formatting]::None))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Find-DeduplicatedTemplateCandidates {
    param(
        [Newtonsoft.Json.Linq.JObject]$Template,
        [hashtable]$Candidates
    )

    foreach ($resource in (Get-DeduplicatedTemplateResources -Template $Template)) {
        if ([string]$resource['type'] -ine 'Microsoft.Resources/deployments') { continue }
        $properties = $resource['properties']
        if ($properties -isnot [Newtonsoft.Json.Linq.JObject]) { continue }
        $link = $properties['templateLink']
        if ($link -is [Newtonsoft.Json.Linq.JObject] -and $null -ne $link['relativePath']) {
            throw 'This publisher requires self-contained ARM input. Pre-existing relativePath template links are not supported; no package has been published.'
        }
        $child = $properties['template']
        if ($child -isnot [Newtonsoft.Json.Linq.JObject]) { continue }
        # Linked templates have inner scope. Never extract outer/default-scope templates.
        $evaluationOptions = $properties['expressionEvaluationOptions']
        if ($evaluationOptions -is [Newtonsoft.Json.Linq.JObject] -and [string]$evaluationOptions['scope'] -ieq 'inner') {
            $hash = Get-DeduplicatedTemplateHash -Template $child
            if ($Candidates.ContainsKey($hash)) {
                if (-not [Newtonsoft.Json.Linq.JToken]::DeepEquals($Candidates[$hash].Template, $child)) {
                    throw "Template hash collision for '$hash'."
                }
                $Candidates[$hash].Count++
            }
            else {
                $Candidates[$hash] = @{ Count = 1; Template = $child }
            }
        }
        Find-DeduplicatedTemplateCandidates -Template $child -Candidates $Candidates
    }
}

function ConvertTo-DeduplicatedTemplateLinks {
    param(
        [Newtonsoft.Json.Linq.JObject]$Template,
        [hashtable]$Candidates,
        [hashtable]$Artifacts,
        [bool]$InsideArtifact = $false
    )

    $hasLinkedChildren = $false
    foreach ($resource in (Get-DeduplicatedTemplateResources -Template $Template)) {
        if ([string]$resource['type'] -ine 'Microsoft.Resources/deployments') { continue }
        $properties = $resource['properties']
        if ($properties -isnot [Newtonsoft.Json.Linq.JObject]) { continue }
        $child = $properties['template']
        if ($child -isnot [Newtonsoft.Json.Linq.JObject]) { continue }
        $evaluationOptions = $properties['expressionEvaluationOptions']
        # An inline boundary loses the link origin. Outer/default scope cannot be
        # extracted safely, so leave its complete subtree inline.
        if ($evaluationOptions -isnot [Newtonsoft.Json.Linq.JObject] -or [string]$evaluationOptions['scope'] -ine 'inner') {
            continue
        }
        $hash = Get-DeduplicatedTemplateHash -Template $child
        if (-not $Artifacts.ContainsKey($hash)) {
            $artifact = $child.DeepClone()
            $childHasLinks = ConvertTo-DeduplicatedTemplateLinks -Template $artifact -Candidates $Candidates -Artifacts $Artifacts -InsideArtifact $true
            $isDuplicate = $Candidates.ContainsKey($hash) -and $Candidates[$hash].Count -gt 1
            if (-not $isDuplicate -and -not $childHasLinks) { continue }
            $Artifacts[$hash] = $artifact
        }
        $relativePath = if ($InsideArtifact) { "$hash.json" } else { "artifacts/$hash.json" }
        $properties.Remove('template') | Out-Null
        $properties.Remove('expressionEvaluationOptions') | Out-Null
        $properties['templateLink'] = [Newtonsoft.Json.Linq.JObject]::FromObject(@{ relativePath = $relativePath })
        $hasLinkedChildren = $true
    }
    return $hasLinkedChildren
}

function Get-DeduplicatedTemplateSpecPayload {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$Location
    )

    $client = [Microsoft.Azure.Management.Resources.TemplateSpecsClient]::new(
        [Microsoft.Rest.TokenCredentials]::new('offline')
    )
    try {
        $model = [Microsoft.Azure.Management.Resources.Models.TemplateSpecVersion]::new()
        $model.Location = $Location
        $model.MainTemplate = $Package.RootTemplate
        $model.UiFormDefinition = $Package.UIFormDefinition
        $model.LinkedTemplates = $Package.Artifacts
        return [Microsoft.Rest.Serialization.SafeJsonConvert]::SerializeObject($model, $client.SerializationSettings)
    }
    finally {
        $client.Dispose()
    }
}

function New-DeduplicatedTemplateSpecPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$TemplateFile,
        [Parameter(Mandatory = $true)]
        [string]$FormFile,
        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    $package = [pscustomobject]@{
        RootTemplate = [Newtonsoft.Json.Linq.JObject]::Parse((Get-Content -LiteralPath $TemplateFile -Raw -ErrorAction Stop))
        UIFormDefinition = [Newtonsoft.Json.Linq.JObject]::Parse((Get-Content -LiteralPath $FormFile -Raw -ErrorAction Stop))
        Artifacts = [System.Collections.Generic.List[Microsoft.Azure.Management.Resources.Models.LinkedTemplateArtifact]]::new()
        OriginalPayloadBytes = 0
        PayloadBytes = 0
    }
    Remove-TemplateSpecInternalAnnotations -Node $package.RootTemplate
    $package.OriginalPayloadBytes = [Text.Encoding]::UTF8.GetByteCount(
        (Get-DeduplicatedTemplateSpecPayload -Package $package -Location $Location)
    )
    $candidates = @{}
    Find-DeduplicatedTemplateCandidates -Template $package.RootTemplate -Candidates $candidates
    $artifacts = @{}
    $null = ConvertTo-DeduplicatedTemplateLinks -Template $package.RootTemplate -Candidates $candidates -Artifacts $artifacts
    foreach ($hash in @($artifacts.Keys | Sort-Object)) {
        $package.Artifacts.Add([Microsoft.Azure.Management.Resources.Models.LinkedTemplateArtifact]::new(
            "artifacts/$hash.json", $artifacts[$hash]
        ))
    }
    $package.PayloadBytes = [Text.Encoding]::UTF8.GetByteCount(
        (Get-DeduplicatedTemplateSpecPayload -Package $package -Location $Location)
    )
    return $package
}

function Publish-DeduplicatedTemplateSpec {
    param (
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$ParentPayload,
        [Parameter(Mandatory = $true)][string]$VersionPayload
    )

    $requests = @(
        @{ Path = "$($ResourceId)?api-version=2021-05-01"; Payload = $ParentPayload }
        @{ Path = "$ResourceId/versions/$($Version)?api-version=2021-05-01"; Payload = $VersionPayload }
    )
    foreach ($request in $requests) {
        # -Path resolves the management endpoint from the active cloud context.
        $response = Invoke-AzRestMethod -Path $request.Path -Method PUT -Payload $request.Payload -ErrorAction Stop
        if ([int]$response.StatusCode -notin @(200, 201)) {
            throw "Template Spec PUT '$($request.Path)' failed with HTTP $($response.StatusCode): $($response.Content)"
        }
    }
}

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

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    Write-Output 'Resource Group Name not provided. Using naming convention with purpose operations'
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

# Build collection of template specs to create
$templateSpecs = @()

if ($createSharedServices) {
    $templateSpecs += @{
        Purpose = 'shared-services'
        DisplayName = 'AVD Shared Services'
        Description = 'Deploys or adopts shared AVD workspace, feed and global Private Link, Key Vault, monitoring, and FSLogix backup resources'
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
        Description = 'Orchestrates AVD Shared Services and a standard Azure Virtual Desktop host pool'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\hostpools\hostpool.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\hostpools\uiFormDefinition.json'
    }
}

if ($createHostPoolPoc) {
    $templateSpecs += @{
        Purpose = 'hostpool-poc'
        DisplayName = 'AVD Standard PoC'
        Description = 'Deploys a disposable standard-management Azure Virtual Desktop demo with a standalone NAT-backed virtual network'
        TemplateFile = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\hostpoolPoc\hostpoolPoc.json'
        UiFormDefinition = Join-Path -Path $PSScriptRoot -ChildPath '..\deployments\hostpoolPoc\uiFormDefinition.json'
    }
}

if ($createAutomatedHostPool) {
    $templateSpecs += @{
        Purpose = 'automated-hostpool'
        DisplayName = 'AVD Automated Host Pool'
        Description = 'Orchestrates AVD Shared Services and an Azure Commercial pooled host pool with automated session host management'
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

# Serialize and check every complete request before any Azure writes.
foreach ($templateSpec in $templateSpecs) {
    if ([string]::IsNullOrWhiteSpace([string]$templateSpec.Purpose)) {
        throw "Template Spec '$($templateSpec.DisplayName)' has no publishing purpose. Check its catalog entry in tools\New-TemplateSpecs.ps1. Nothing has been published."
    }
    $package = New-DeduplicatedTemplateSpecPackage -TemplateFile $templateSpec.TemplateFile -FormFile $templateSpec.UiFormDefinition -Location $Location
    $templateSpec.PublicationPayload = Get-DeduplicatedTemplateSpecPayload -Package $package -Location $Location
    $budgetedBytes = $package.PayloadBytes + 16384
    Write-Output "$($templateSpec.DisplayName) publication size check:"
    Write-Output ("  Before deduplication: {0:N0} bytes; after: {1:N0} bytes; saved: {2:N0} bytes." -f $package.OriginalPayloadBytes, $package.PayloadBytes, ($package.OriginalPayloadBytes - $package.PayloadBytes))
    Write-Output ("  Packaged linked artifacts: {0}; the measured request includes every artifact and the Portal form." -f $package.Artifacts.Count)
    Write-Output '  Reserved safety margin: 16,384 bytes (16 KiB; not appended to the template).'
    if ($budgetedBytes -gt 2000000) {
        throw "$($templateSpec.DisplayName): complete request plus safety reserve is $budgetedBytes bytes, exceeding the 2,000,000-byte budget. Nothing has been published."
    }
    $remainingBytes = 2000000 - $budgetedBytes
    Write-Output ("  Total checked: {0:N0} / 2,000,000 bytes; remaining headroom: {1:N0} bytes." -f $budgetedBytes, $remainingBytes)
    if ($remainingBytes -le 200000) {
        Write-Warning ("{0} is approaching the Template Spec size limit: {1:N0} / 2,000,000 bytes checked; {2:N0} bytes remaining ({3:N1}%). Includes the 16,384-byte safety reserve." -f $templateSpec.DisplayName, $budgetedBytes, $remainingBytes, ($remainingBytes / 2000000 * 100))
    }
    $templateSpecWorkload = if (-not $namingConventionSupplied -and $templateSpec.PreserveLegacyWithoutWorkload) { '' } else { $workload }
    $templateSpec.Name = New-ConventionName `
        -Components $components -Delimiter $delimiter -ResourceTypeCode $templateSpecTypeCode `
        -Purpose $templateSpec.Purpose -LocationAbbreviation $locationAbbr -Workload $templateSpecWorkload `
        -Environment $environment -Freeform1 $freeform1 -Freeform2 $freeform2
    if (-not [string]::IsNullOrEmpty($TemplateSpecNameSuffix)) {
        $templateSpec.Name += "-$TemplateSpecNameSuffix"
    }
    if ($templateSpec.Name.Length -gt 90) {
        throw "Template Spec name '$($templateSpec.Name)' exceeds 90 characters."
    }
}

if ($templateSpecs.Count -eq 0) {
    throw 'No Template Specs selected. Enable at least one create switch.'
}
$resourceGroupExists = $null -ne (Get-AzResourceGroup -ErrorAction Stop | Where-Object { $_.ResourceGroupName -eq $ResourceGroupName })
if (-not $resourceGroupExists) {
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Create Template Spec resource group')) {
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop | Out-Null
        $resourceGroupExists = $true
    }
}
$existingTemplateSpecs = @()
if ($resourceGroupExists) {
    $existingTemplateSpecs = @(Get-AzTemplateSpec -ResourceGroupName $ResourceGroupName -ErrorAction Stop | ForEach-Object { $_ })
}

$publishedCount = 0
foreach ($templateSpec in $templateSpecs) {
    $existing = @($existingTemplateSpecs | Where-Object { $_.Name -eq $templateSpec.Name })
    if ($existing.Count -gt 0 -and $existing[0].Location -ine $Location) {
        throw "Existing Template Spec '$($templateSpec.Name)' is in '$($existing[0].Location)', not '$Location'. Use its existing location or a different test name."
    }
    $version = '1.0.0'
    if ($incrementVersion -and $existing.Count -gt 0) {
        $existingWithVersions = Get-AzTemplateSpec -ResourceGroupName $ResourceGroupName -Name $templateSpec.Name -ErrorAction Stop
        $versions = @($existingWithVersions.Versions)
        $latestMajor = -1
        foreach ($item in $versions) {
            $parsedVersion = $null
            if (-not [version]::TryParse([string]$item.Name, [ref]$parsedVersion)) {
                throw "Cannot increment non-numeric Template Spec version '$($item.Name)' for '$($templateSpec.Name)'."
            }
            $latestMajor = [Math]::Max($latestMajor, $parsedVersion.Major)
        }
        if ($latestMajor -ge 0) { $version = "$($latestMajor + 1).0.0" }
    }
    elseif (-not $incrementVersion) {
        Write-Warning "Version incrementing is disabled. '$($templateSpec.Name)' version 1.0.0 will be overwritten if it exists."
    }
    $parent = [ordered]@{
        location = $Location
        properties = [ordered]@{ displayName = $templateSpec.DisplayName; description = $templateSpec.Description }
    }
    if ($existing.Count -gt 0 -and $null -ne $existing[0].Tags) {
        $parent.tags = $existing[0].Tags
    }
    $resourceId = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Resources/templateSpecs/{2}' -f `
        $Context.Subscription.Id, [Uri]::EscapeDataString($ResourceGroupName), [Uri]::EscapeDataString($templateSpec.Name)
    if ($PSCmdlet.ShouldProcess("$($templateSpec.Name)/$version", "Publish deduplicated Template Spec in $cloud")) {
        Publish-DeduplicatedTemplateSpec -ResourceId $resourceId -Version $version `
            -ParentPayload (ConvertTo-Json -InputObject $parent -Depth 100) -VersionPayload $templateSpec.PublicationPayload
        $publishedCount++
        Write-Output "Published $($templateSpec.DisplayName): $resourceId/versions/$version"
    }
}
if ($WhatIfPreference) {
    Write-Output 'WhatIf complete. No resources were created or published.'
}
else {
    Write-Output "Published $publishedCount Template Spec version(s) in '$ResourceGroupName'. Test Portal rendering and actual deployments before production use."
}