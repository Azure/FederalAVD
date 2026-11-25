<#
.SYNOPSIS
    Previews or submits an image-change request for a running SHR operation.
.DESCRIPTION
    Preview is read-only. Apply writes only the separate image-change request row,
    after confirmation and fresh safety checks. It does not change app settings,
    restart the Function App, edit the operation, or perform VM operations.

    Only exact versions of the operation's pinned Azure Compute Gallery definition
    are supported. Missing or unsupported publication/replication metadata blocks
    the request. The worker validates the request again and decides when it is safe
    to consume it; successful submission does not mean the image has changed.
    A request explicitly rejected by the worker can be replaced. Image switching
    does not authorize another deployment batch; fresh scheduled authorization is
    required before the next batch.
.PARAMETER ImageVersion
    Exact numeric major.minor.patch gallery version, not latest or a resource ID.
.PARAMETER SubscriptionId
    Function App subscription. Must match the current Az context.
.PARAMETER Apply
    Submits the request after confirmation. Without this switch, previews only.
.EXAMPLE
    .\Request-SessionHostReplacerImageChange.ps1 -FunctionAppName func-shr `
        -ResourceGroupName rg-operations -ImageVersion 2.1.0
.EXAMPLE
    .\Request-SessionHostReplacerImageChange.ps1 -FunctionAppName func-shr `
        -ResourceGroupName rg-operations -ImageVersion 2.1.0 -Apply
.NOTES
    Requires PowerShell 7.4+, Az.Accounts sign-in, Function App configuration-list
    and gallery version read permissions, Storage Table Data Reader for preview
    (Data Contributor for Apply), and network access to the configured Table endpoint.
    Public endpoints must permit operator access through public-access/firewall rules;
    private endpoints require private DNS/routing. Private endpoints are not required.
    No process environment variables are changed. Confirmation may allow the worker
    to consume the request immediately. Re-preview after any concurrency conflict.
#>
#Requires -Version 7.4
#Requires -Modules Az.Accounts

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $FunctionAppName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ResourceGroupName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string] $ImageVersion,
    [string] $SubscriptionId,
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
$context = Get-AzContext
if (-not $context) { throw 'Sign in using Connect-AzAccount before requesting an image change.' }
if (-not $SubscriptionId) { $SubscriptionId = $context.Subscription.Id }
if ($SubscriptionId -ne $context.Subscription.Id) {
    throw 'The requested subscription must match the active Az context.'
}
$environment = Get-AzEnvironment -Name $context.Environment.Name
$armRoot = $environment.ResourceManagerUrl.TrimEnd('/')
$appId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
$replacerRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $replacerRoot 'functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1') -Scope Local
$coordinator = Get-Module SessionHostReplacer.Continuation -All | Where-Object {
    $_.Path -eq (Join-Path $replacerRoot 'functions\Modules\SessionHostReplacer\SessionHostReplacer.Continuation.psm1')
} | Select-Object -First 1
if (-not $coordinator) { throw 'Cannot load the repository SHR continuation module.' }

function Invoke-ImageChangeArm {
    param([string] $Path, [string] $Method = 'GET')
    $response = Invoke-AzRestMethod -Path $Path -Method $Method -DefaultProfile $context
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
        throw "ARM $Method failed with HTTP $($response.StatusCode)."
    }
    $value = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($value -isnot [System.Collections.IDictionary]) { throw 'ARM returned an invalid resource response.' }
    return $value
}

function Get-ImageChangeSettings {
    $values = (Invoke-ImageChangeArm -Path "$appId/config/appsettings/list?api-version=2024-11-01" -Method POST).properties
    foreach ($name in @('HostPoolSubscriptionId', 'HostPoolResourceGroupName', 'HostPoolName',
        'SessionHostParameters', 'AzureWebJobsStorage__tableServiceUri')) {
        if ([string]::IsNullOrWhiteSpace($values[$name])) { throw "Required app setting '$name' is missing." }
    }
    if (-not [string]::IsNullOrWhiteSpace($values.MaintenanceRequest)) {
        throw 'MaintenanceRequest is populated; an image change is not supported.'
    }
    return $values
}

function Get-ImageChangeHash {
    param([System.Collections.IDictionary] $Settings, [System.Collections.IDictionary] $State)
    & $coordinator {
        param($Values, $OldState)
        Get-ShrConfigurationHash -Settings $Values -OperationState $OldState
    } $Settings $State
}

function Invoke-ImageChangeTable {
    param([string] $Path, [string] $Method = 'GET', [string] $Body, [string] $ETag, [switch] $AllowMissing)
    $token = (Get-AzAccessToken -ResourceUrl $tableEndpoint -DefaultProfile $context).Token
    if ($token -is [securestring]) { $token = [System.Net.NetworkCredential]::new('', $token).Password }
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'No Storage access token was returned.' }
    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/json;odata=nometadata'
        'x-ms-version' = '2019-02-02'
        'x-ms-date' = [DateTime]::UtcNow.ToString('R')
    }
    if ($ETag) {
        if ($ETag -eq '*') { throw 'An unconditional request update is not permitted.' }
        $headers['If-Match'] = $ETag
    }
    $arguments = @{
        Uri = "$tableEndpoint/$Path"; Method = $Method; Headers = $headers
        ContentType = 'application/json'; SkipHttpErrorCheck = $true
        TimeoutSec = 60; MaximumRedirection = 0
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $arguments.Body = $Body }
    $response = Invoke-WebRequest @arguments
    $status = [int]$response.StatusCode
    if ($AllowMissing -and $status -eq 404) { return $null }
    if ($status -in 409, 412) { throw 'Concurrency conflict (HTTP 409/412); no write retry was attempted. Run a new preview.' }
    if ($status -lt 200 -or $status -ge 300) { throw "Table $Method failed with HTTP $status." }
    return $response
}

function Get-ImageChangeRow {
    param([string] $Path, [switch] $AllowMissing)
    $response = Invoke-ImageChangeTable -Path $Path -AllowMissing:$AllowMissing
    if (-not $response) { return $null }
    $entity = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $state = $entity.State | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($state -isnot [System.Collections.IDictionary]) { throw 'Table row has invalid State JSON.' }
    return @{
        State = $state
        ETag = [string](@($response.Headers['ETag'])[0])
    }
}

function Assert-ImageChangeOperation {
    param([System.Collections.IDictionary] $State, [System.Collections.IDictionary] $Settings)
    if ($State.Status -ne 'Running' -or $State.Id -cnotmatch '^[0-9a-f]{32}$') {
        throw 'An active Running operation is required.'
    }
    if ($State.MaintenanceRequest) { throw 'Maintenance operations do not support image changes.' }
    if ($State.Image.Definition -notmatch '^/subscriptions/[^/?#]+/resourceGroups/[^/?#]+/providers/Microsoft\.Compute/galleries/[^/?#]+/images/[^/?#]+$' -or
        $State.Image.Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw 'The operation must pin an exact Azure Compute Gallery image; marketplace images are unsupported.'
    }
    $hash = Get-ImageChangeHash -Settings $Settings -State $State
    if (-not $State.ConfigurationHash -or $hash -ne $State.ConfigurationHash) {
        throw 'The configuration no longer matches the running operation. Resolve it before requesting an image change.'
    }
}

function Assert-ImageChangeSlot {
    param([hashtable] $Row, [System.Collections.IDictionary] $Operation)
    if (-not $Row) { return }
    $previous = $Row.State
    $priorDate = [DateTimeOffset]::MinValue
    $priorRequested = [DateTimeOffset]::MinValue
    if ($previous.SchemaVersion -ne 1 -or $previous.Id -cnotmatch '^[0-9a-f]{32}$' -or
        $previous.OperationId -cnotmatch '^[0-9a-f]{32}$' -or
        $previous.ExpectedImage.Definition -notmatch '^/subscriptions/[^/?#]+/resourceGroups/[^/?#]+/providers/Microsoft\.Compute/galleries/[^/?#]+/images/[^/?#]+$' -or
        $previous.ExpectedImage.Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
        $previous.Image.Definition -ine $previous.ExpectedImage.Definition -or
        $previous.Image.Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
        -not [DateTimeOffset]::TryParse([string]$previous.Image.Date, [ref]$priorDate) -or
        -not [DateTimeOffset]::TryParse([string]$previous.RequestedUtc, [ref]$priorRequested)) {
        throw 'The previous image-change request is invalid or unsupported; refusing to replace it.'
    }
    if (-not $Row.ETag -or $Row.ETag -eq '*') { throw 'The request row has no usable ETag.' }
    if ($previous.OperationId -eq $Operation.Id -and
        $previous.Id -ne $Operation.LastImageChangeRequestId -and
        $previous.Id -ne $Operation.LastImageChangeRejectedId) {
        throw 'An outstanding unconsumed image-change request already exists for this operation.'
    }
    # A different operation ID is stale: the single pool operation row now proves
    # that another operation is active. The conditional PUT still protects its slot.
}

function Get-ValidatedRequestedImage {
    param([System.Collections.IDictionary] $Settings, [System.Collections.IDictionary] $Operation)
    foreach ($version in @($ImageVersion, $Operation.Image.Version)) {
        foreach ($part in ($version -split '\.')) {
            $number = 0
            if (-not [int]::TryParse($part, [ref]$number)) { throw 'Image version components must be supported nonnegative integers.' }
        }
    }
    $comparison = Compare-ImageVersion -Version1 $ImageVersion -Version2 $Operation.Image.Version
    if ($comparison -eq 0) { throw 'The requested image version is already pinned to this operation.' }
    $rollback = $false
    if ($Settings.AllowImageVersionRollback -and -not [bool]::TryParse($Settings.AllowImageVersionRollback, [ref]$rollback)) {
        throw 'AllowImageVersionRollback is invalid.'
    }
    if ($comparison -lt 0 -and -not $rollback) { throw 'An image downgrade requires AllowImageVersionRollback=true.' }
    $includeExcluded = $false
    if ($Settings.IncludeExcludedImageVersions -and -not [bool]::TryParse($Settings.IncludeExcludedImageVersions, [ref]$includeExcluded)) {
        throw 'IncludeExcludedImageVersions is invalid.'
    }
    $parameters = $Settings.SessionHostParameters | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $location = [string]$parameters.Location
    if ([string]::IsNullOrWhiteSpace($location)) { throw 'SessionHostParameters.Location is required to validate replication.' }
    $imageId = "$($Operation.Image.Definition)/versions/$ImageVersion"
    $image = Invoke-ImageChangeArm -Path "${imageId}?`$expand=ReplicationStatus&api-version=2024-03-03"
    if ($image.id -ine $imageId -or $image.name -cne $ImageVersion -or $image.properties.provisioningState -ne 'Succeeded') {
        throw 'The exact gallery version response is missing, unsupported, or not successfully provisioned.'
    }
    $profile = $image.properties.publishingProfile
    $regions = @($profile.targetRegions | Where-Object { ($_.name -replace '\s', '') -eq ($location -replace '\s', '') })
    $replication = @($image.properties.replicationStatus.summary | Where-Object { ($_.region -replace '\s', '') -eq ($location -replace '\s', '') })
    if ($regions.Count -ne 1 -or $replication.Count -ne 1 -or $replication[0].state -ne 'Completed' -or
        ($profile.replicationMode -and $profile.replicationMode -ne 'Full')) {
        throw 'Missing or unsupported metadata: completed Full replication in the target region is required.'
    }
    if ($profile.excludeFromLatest -isnot [bool] -or
        ($null -ne $regions[0].excludeFromLatest -and $regions[0].excludeFromLatest -isnot [bool])) {
        throw 'Missing or unsupported excludeFromLatest metadata.'
    }
    if (-not $includeExcluded -and ($profile.excludeFromLatest -or $regions[0].excludeFromLatest)) {
        throw 'The requested version is excluded from latest globally or in the target region.'
    }
    $published = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$profile.publishedDate, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$published) -or $published -gt [DateTimeOffset]::UtcNow) {
        throw 'Missing or invalid gallery publication date.'
    }
    $delay = 0
    if ($Settings.ReplaceSessionHostOnNewImageVersionDelayDays -and
        (-not [int]::TryParse($Settings.ReplaceSessionHostOnNewImageVersionDelayDays, [ref]$delay) -or $delay -lt 0 -or $delay -gt 30)) {
        throw 'ReplaceSessionHostOnNewImageVersionDelayDays is invalid.'
    }
    if ($published.AddDays($delay) -gt [DateTimeOffset]::UtcNow) { throw 'The requested version has not passed the configured publication-age delay.' }
    # The automatic "latest" helper can fall back to today's date for an exact
    # version and does not check exact-version replication/exclusions. Validate
    # those directly above instead of invoking it or changing process settings.
    return @{ Definition = $Operation.Image.Definition; Version = $ImageVersion; Date = $published.UtcDateTime.ToString('o') }
}

$settings = Get-ImageChangeSettings
$endpoint = [uri]$settings.AzureWebJobsStorage__tableServiceUri
if ($endpoint.Scheme -ne 'https' -or $endpoint.Host -notmatch "^[a-z0-9]{3,24}\.table\.$([regex]::Escape($environment.StorageEndpointSuffix))$" -or
    $endpoint.AbsolutePath -ne '/' -or $endpoint.Query -or $endpoint.UserInfo -or -not $endpoint.IsDefaultPort) {
    throw 'The Table endpoint does not match the active Azure cloud.'
}
$tableEndpoint = $endpoint.GetLeftPart([UriPartial]::Authority)
$key = & $coordinator { param($Values) Get-ShrOperationKey -Settings $Values } $settings
if ([string]::IsNullOrWhiteSpace($key) -or $key -match "['/?#]") { throw 'The operation key is invalid.' }
$operationPath = "shrContinuation(PartitionKey='SHR',RowKey='$key')"
$requestPath = "shrContinuation(PartitionKey='SHR',RowKey='$key-image-change')"
$operation = Get-ImageChangeRow -Path $operationPath
Assert-ImageChangeOperation -State $operation.State -Settings $settings
$hash = Get-ImageChangeHash -Settings $settings -State $operation.State
$previous = Get-ImageChangeRow -Path $requestPath -AllowMissing
Assert-ImageChangeSlot -Row $previous -Operation $operation.State
$requested = Get-ValidatedRequestedImage -Settings $settings -Operation $operation.State
[PSCustomObject]@{
    OperationId = $operation.State.Id
    ImageDefinition = $operation.State.Image.Definition
    CurrentVersion = $operation.State.Image.Version
    RequestedVersion = $requested.Version
    PublishedUtc = $requested.Date
} | Format-List | Out-Host
Write-Host 'The worker revalidates at a conservative safe boundary. SideBySide switches future batches after current deployment health and scaling handoff; previously authorized hosts continue draining/retiring.'
Write-Host 'DeleteFirst finishes its current destructive batch before switching. Saved deployment/cleanup intents are not rewritten.'
Write-Host 'An image switch does not authorize the next batch: fresh scheduled authorization is required. The worker revalidates image eligibility before switching.'
Write-Host 'Existing work is not canceled. Already replaced hosts may need replacement again, causing extra churn, cost and user disruption.'
if (-not $Apply) { Write-Host 'Preview only. Add -Apply to submit a separate request after confirmation.'; return }
if (-not $PSCmdlet.ShouldProcess($appId, "Request operation $($operation.State.Id) change image from $($operation.State.Image.Version) to $ImageVersion; the worker may consume it immediately")) { return }

$freshSettings = Get-ImageChangeSettings
if ($freshSettings.AzureWebJobsStorage__tableServiceUri -ne $settings.AzureWebJobsStorage__tableServiceUri -or
    (Get-ImageChangeHash -Settings $freshSettings -State $operation.State) -ne $hash) {
    throw 'Configuration changed after preview; run a new preview.'
}
$fresh = Get-ImageChangeRow -Path $operationPath
Assert-ImageChangeOperation -State $fresh.State -Settings $freshSettings
if ($fresh.State.Id -ne $operation.State.Id -or $fresh.State.Image.Definition -ine $operation.State.Image.Definition -or
    $fresh.State.Image.Version -cne $operation.State.Image.Version) { throw 'The operation or pinned image changed after preview; run a new preview.' }
$freshRequest = Get-ImageChangeRow -Path $requestPath -AllowMissing
Assert-ImageChangeSlot -Row $freshRequest -Operation $fresh.State
$checkedImage = Get-ValidatedRequestedImage -Settings $freshSettings -Operation $fresh.State
if ($checkedImage.Date -ne $requested.Date) { throw 'The image publication metadata changed after preview; run a new preview.' }
$requestState = @{
    Id = [guid]::NewGuid().ToString('N')
    OperationId = $fresh.State.Id
    ExpectedImage = @{ Definition = $fresh.State.Image.Definition; Version = $fresh.State.Image.Version }
    Image = $checkedImage
    RequestedUtc = [DateTime]::UtcNow.ToString('o')
    SchemaVersion = 1
}
$body = @{
    PartitionKey = 'SHR'; RowKey = "$key-image-change"
    State = ($requestState | ConvertTo-Json -Depth 10 -Compress)
} | ConvertTo-Json -Depth 12 -Compress
if ($freshRequest) {
    Invoke-ImageChangeTable -Path $requestPath -Method PUT -ETag $freshRequest.ETag -Body $body | Out-Null
} else {
    Invoke-ImageChangeTable -Path 'shrContinuation' -Method POST -Body $body | Out-Null
}
Write-Host "Submitted image-change request $($requestState.Id). Verify worker acceptance and progress; submission does not prove consumption."
