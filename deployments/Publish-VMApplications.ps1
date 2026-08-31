[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $false)]
    [string]$GalleryResourceId,

    [Parameter(Mandatory = $false)]
    [string]$StorageAccountResourceId,

    [Parameter(Mandatory = $false)]
    [string]$ContainerName = 'artifacts',

    [Parameter(Mandatory = $false)]
    [switch]$ValidateOnly,

    [Parameter(Mandatory = $false)]
    [int]$PollingIntervalSeconds = 30,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutMinutes = 120
)

$ErrorActionPreference = 'Stop'
$ApiVersion = '2024-03-03'

function Get-PropertyValue {
    param (
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return $property.Value
}

function Assert-VMApplicationManifest {
    param ([Parameter(Mandatory = $true)]$Manifest)

    if ($null -eq $Manifest.PSObject.Properties['applications']) {
        throw "Manifest must contain an 'applications' array."
    }

    $applications = @($Manifest.applications)
    if ($applications.Count -eq 0) {
        throw "Manifest 'applications' must contain at least one entry."
    }

    $identities = @{}
    foreach ($application in $applications) {
        foreach ($requiredProperty in @('name', 'version', 'packageBlob', 'supportedOSType', 'install', 'remove', 'targetRegions')) {
            $value = Get-PropertyValue -InputObject $application -Name $requiredProperty
            if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
                throw "VM Application entry is missing required property '$requiredProperty'."
            }
        }

        if ($application.name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
            throw "Application name '$($application.name)' is invalid. Use 1-80 letters, numbers, periods, underscores, or hyphens."
        }
        if ($application.version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
            throw "Version '$($application.version)' for '$($application.name)' must use Major.Minor.Patch numeric format."
        }
        if ($application.supportedOSType -notin @('Windows', 'Linux')) {
            throw "supportedOSType for '$($application.name)' must be Windows or Linux."
        }
        if ($application.install.Length -gt 4096 -or $application.remove.Length -gt 4096) {
            throw "Install and remove commands for '$($application.name)' must not exceed 4096 characters."
        }
        if ($null -ne (Get-PropertyValue -InputObject $application -Name 'update') -and $application.update.Length -gt 4096) {
            throw "Update command for '$($application.name)' must not exceed 4096 characters."
        }
        if ($application.packageBlob -match '[?#]' -or $application.packageBlob.StartsWith('/')) {
            throw "packageBlob for '$($application.name)' must be a relative blob name without a query string."
        }
        if ($application.packageBlob -notmatch '\.zip$') {
            throw "packageBlob for '$($application.name)' must reference a .zip artifact package."
        }

        $packageFileName = Get-PropertyValue -InputObject $application -Name 'packageFileName' -DefaultValue ([IO.Path]::GetFileName($application.packageBlob))
        if ([string]::IsNullOrWhiteSpace($packageFileName) -or $packageFileName -notmatch '\.zip$') {
            throw "packageFileName for '$($application.name)' must preserve the .zip extension."
        }

        $targetRegions = @($application.targetRegions)
        if ($targetRegions.Count -eq 0) {
            throw "targetRegions for '$($application.name)' must contain at least one region."
        }
        $regionNames = @{}
        foreach ($region in $targetRegions) {
            if ([string]::IsNullOrWhiteSpace((Get-PropertyValue -InputObject $region -Name 'name'))) {
                throw "Each target region for '$($application.name)' must have a name."
            }
            if ($regionNames.ContainsKey($region.name.ToLowerInvariant())) {
                throw "Target region '$($region.name)' is duplicated for '$($application.name)'."
            }
            $regionNames[$region.name.ToLowerInvariant()] = $true

            $replicaCount = Get-PropertyValue -InputObject $region -Name 'regionalReplicaCount' -DefaultValue 1
            if ($replicaCount -lt 1) {
                throw "regionalReplicaCount for '$($application.name)' must be at least 1."
            }
            $storageAccountType = Get-PropertyValue -InputObject $region -Name 'storageAccountType' -DefaultValue 'Standard_LRS'
            if ($storageAccountType -notin @('Standard_LRS', 'Standard_ZRS', 'Premium_LRS', 'PremiumV2_LRS')) {
                throw "storageAccountType '$storageAccountType' for '$($application.name)' is invalid."
            }
        }

        $rebootBehavior = Get-PropertyValue -InputObject $application -Name 'scriptBehaviorAfterReboot' -DefaultValue 'None'
        if ($rebootBehavior -notin @('None', 'Rerun')) {
            throw "scriptBehaviorAfterReboot for '$($application.name)' must be None or Rerun."
        }

        $identity = "$($application.name.ToLowerInvariant())/$($application.version)"
        if ($identities.ContainsKey($identity)) {
            throw "Application version '$($application.name)/$($application.version)' appears more than once."
        }
        $identities[$identity] = $true
    }

    return $applications
}

function ConvertTo-CanonicalVersionDefinition {
    param (
        [Parameter(Mandatory = $true)]$Application,
        [Parameter(Mandatory = $true)][string]$MediaLink
    )

    $manageActions = [ordered]@{
        install = $Application.install
        remove = $Application.remove
    }
    $update = Get-PropertyValue -InputObject $Application -Name 'update'
    if (-not [string]::IsNullOrWhiteSpace($update)) {
        $manageActions.update = $update
    }

    $targetRegions = foreach ($region in @($Application.targetRegions)) {
        [ordered]@{
            name = $region.name
            regionalReplicaCount = Get-PropertyValue -InputObject $region -Name 'regionalReplicaCount' -DefaultValue 1
            storageAccountType = Get-PropertyValue -InputObject $region -Name 'storageAccountType' -DefaultValue 'Standard_LRS'
        }
    }

    return [ordered]@{
        source = [ordered]@{ mediaLink = $MediaLink }
        manageActions = $manageActions
        targetRegions = @($targetRegions)
        excludeFromLatest = [bool](Get-PropertyValue -InputObject $Application -Name 'excludeFromLatest' -DefaultValue $false)
        settings = [ordered]@{
            packageFileName = Get-PropertyValue -InputObject $Application -Name 'packageFileName' -DefaultValue ([IO.Path]::GetFileName($Application.packageBlob))
            scriptBehaviorAfterReboot = Get-PropertyValue -InputObject $Application -Name 'scriptBehaviorAfterReboot' -DefaultValue 'None'
        }
    }
}

function Get-DefinitionHash {
    param ([Parameter(Mandatory = $true)]$Definition)

    $json = $Definition | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Invoke-ArmRequest {
    param (
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'PUT')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        $Body,
        [switch]$AllowNotFound
    )

    $parameters = @{
        Method = $Method
        Path = $Path
    }
    if ($null -ne $Body) {
        $parameters.Payload = $Body | ConvertTo-Json -Depth 30 -Compress
    }

    try {
        $response = Invoke-AzRestMethod @parameters
    }
    catch {
        if ($AllowNotFound -and $_.Exception.Response.StatusCode.value__ -eq 404) {
            return $null
        }
        throw
    }

    if ($AllowNotFound -and $response.StatusCode -eq 404) {
        return $null
    }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "ARM $Method request failed with status $($response.StatusCode): $($response.Content)"
    }
    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json -Depth 30
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Manifest file not found: $ManifestPath"
}

try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 30
}
catch {
    throw "Manifest is not valid JSON: $_"
}

$applications = @(Assert-VMApplicationManifest -Manifest $manifest)
Write-Host "Validated $($applications.Count) VM Application manifest entr$(if ($applications.Count -eq 1) { 'y' } else { 'ies' })."

if ($ValidateOnly) {
    return
}

if ([string]::IsNullOrWhiteSpace($GalleryResourceId) -or [string]::IsNullOrWhiteSpace($StorageAccountResourceId)) {
    throw 'GalleryResourceId and StorageAccountResourceId are required unless ValidateOnly is specified.'
}
if ($GalleryResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Compute/galleries/[^/]+$') {
    throw 'GalleryResourceId is not a valid Azure Compute Gallery resource ID.'
}
if ($StorageAccountResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Storage/storageAccounts/([^/]+)$') {
    throw 'StorageAccountResourceId is not a valid storage account resource ID.'
}
$storageAccountName = $Matches[1]
if ($ContainerName -notmatch '^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?$') {
    throw 'ContainerName must be 3-63 lowercase letters, numbers, or hyphens and cannot start or end with a hyphen.'
}
if ($PollingIntervalSeconds -lt 5 -or $TimeoutMinutes -lt 1) {
    throw 'PollingIntervalSeconds must be at least 5 and TimeoutMinutes must be at least 1.'
}

$context = Get-AzContext
if ($null -eq $context) {
    throw 'No Azure context is available. Run Connect-AzAccount for the target cloud first.'
}
$storageEndpointSuffix = $context.Environment.StorageEndpointSuffix
if ([string]::IsNullOrWhiteSpace($storageEndpointSuffix)) {
    throw "Azure environment '$($context.Environment.Name)' does not define a storage endpoint suffix."
}

$galleryPath = "$GalleryResourceId`?api-version=$ApiVersion"
$gallery = Invoke-ArmRequest -Method GET -Path $galleryPath
if ($null -eq $gallery.identity -or $gallery.identity.type -notmatch 'UserAssigned') {
    throw "Gallery '$GalleryResourceId' does not have a user-assigned managed identity. Deploy Image Management before publishing applications."
}

$galleryLocation = $gallery.location
$blobBaseUri = "https://$storageAccountName.blob.$storageEndpointSuffix/$ContainerName"
$publishedApplications = @()

foreach ($application in $applications) {
    $encodedBlobPath = (($application.packageBlob -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $mediaLink = "$blobBaseUri/$encodedBlobPath"
    $definition = ConvertTo-CanonicalVersionDefinition -Application $application -MediaLink $mediaLink
    $definitionHash = Get-DefinitionHash -Definition $definition
    $applicationResourceId = "$GalleryResourceId/applications/$($application.name)"
    $versionResourceId = "$applicationResourceId/versions/$($application.version)"

    $existingApplication = Invoke-ArmRequest -Method GET -Path "$applicationResourceId`?api-version=$ApiVersion" -AllowNotFound
    if ($null -ne $existingApplication -and $existingApplication.properties.supportedOSType -ne $application.supportedOSType) {
        throw "Application '$($application.name)' already exists with supportedOSType '$($existingApplication.properties.supportedOSType)', not '$($application.supportedOSType)'."
    }
    if ($null -eq $existingApplication) {
        $applicationBody = [ordered]@{
            location = $galleryLocation
            properties = [ordered]@{
                supportedOSType = $application.supportedOSType
                description = Get-PropertyValue -InputObject $application -Name 'description' -DefaultValue ''
            }
        }
        Invoke-ArmRequest -Method PUT -Path "$applicationResourceId`?api-version=$ApiVersion" -Body $applicationBody | Out-Null
        $definitionDeadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
        do {
            $existingApplication = Invoke-ArmRequest -Method GET -Path "$applicationResourceId`?api-version=$ApiVersion" -AllowNotFound
            if ($null -ne $existingApplication) {
                break
            }
            if ([DateTime]::UtcNow -ge $definitionDeadline) {
                throw "Timed out waiting for VM Application definition '$($application.name)'."
            }
            Start-Sleep -Seconds $PollingIntervalSeconds
        } while ($true)
        Write-Host "Created VM Application definition '$($application.name)'."
    }

    $existingVersion = Invoke-ArmRequest -Method GET -Path "$versionResourceId`?api-version=$ApiVersion" -AllowNotFound
    if ($null -ne $existingVersion) {
        if ($existingVersion.tags.FederalAVDManifestHash -ne $definitionHash) {
            throw "Application version '$($application.name)/$($application.version)' already exists with different publication settings. Publish changed content under a new semantic version."
        }
        Write-Host "Application version '$($application.name)/$($application.version)' already matches the manifest."
    }
    else {
        $versionBody = [ordered]@{
            location = $galleryLocation
            tags = [ordered]@{ FederalAVDManifestHash = $definitionHash }
            properties = [ordered]@{
                publishingProfile = $definition
                safetyProfile = [ordered]@{ allowDeletionOfReplicatedLocations = $false }
            }
        }
        Invoke-ArmRequest -Method PUT -Path "$versionResourceId`?api-version=$ApiVersion" -Body $versionBody | Out-Null
        Write-Host "Started publication of '$($application.name)/$($application.version)'."
    }

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    do {
        $status = Invoke-ArmRequest -Method GET -Path "$versionResourceId`?api-version=$ApiVersion&%24expand=ReplicationStatus"
        $provisioningState = $status.properties.provisioningState
        $replicationState = $status.properties.replicationStatus.aggregatedState
        if ($provisioningState -eq 'Failed' -or $replicationState -eq 'Failed') {
            $regionalDetails = @($status.properties.replicationStatus.summary | ForEach-Object { "$($_.region): $($_.state) $($_.details)" }) -join '; '
            throw "Publication failed for '$($application.name)/$($application.version)'. $regionalDetails"
        }
        if ($provisioningState -eq 'Succeeded' -and $replicationState -eq 'Completed') {
            break
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for replication of '$($application.name)/$($application.version)'. Provisioning: $provisioningState; replication: $replicationState."
        }
        Start-Sleep -Seconds $PollingIntervalSeconds
    } while ($true)

    Write-Host "Published '$($application.name)/$($application.version)' to all target regions."
    $publishedApplications += [pscustomobject]@{
        name = $application.name
        version = $application.version
        packageReferenceId = $versionResourceId
    }
}

$publishedApplications