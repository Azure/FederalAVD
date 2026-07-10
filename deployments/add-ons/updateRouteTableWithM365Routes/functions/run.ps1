# Input bindings are passed in via param block.
param($Timer)

if ($Timer.IsPastDue) {
    Write-Host 'M365 Route Updater is running late!'
}

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

#region Helpers

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$Warn,
        [switch]$Err
    )
    $ts   = Get-Date -AsUTC -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Message"
    if ($Err)      { Write-Error   $line }
    elseif ($Warn) { Write-Warning $line }
    else           { Write-Host    $line }
}

#endregion Helpers

#region Configuration

$RouteTableResourceId = $env:RouteTableResourceId
$M365Instance         = $env:M365EndpointInstance
$ResourceManagerUri   = $env:ResourceManagerUri

if ([string]::IsNullOrEmpty($RouteTableResourceId)) {
    throw 'RouteTableResourceId environment variable is not set.'
}
if ([string]::IsNullOrEmpty($M365Instance)) {
    throw 'M365EndpointInstance environment variable is not set.'
}

# Normalise URI - ARM REST calls expect a trailing slash
if (-not $ResourceManagerUri.EndsWith('/')) {
    $ResourceManagerUri = "$ResourceManagerUri/"
}

# Parse ARM resource ID segments
# /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/routeTables/{name}
$rtParts        = $RouteTableResourceId -split '/'
$SubId          = $rtParts[2]
$RgName         = $rtParts[4]
$RouteTableName = $rtParts[8]

Write-Log "Starting | Route table: $RouteTableName | RG: $RgName | Sub: $SubId | Instance: $M365Instance"

#endregion Configuration

#region ARM Authentication

try {
    $TokenUri  = "$($env:IDENTITY_ENDPOINT)?resource=$ResourceManagerUri&api-version=2019-08-01"
    $TokenResp = Invoke-RestMethod -Method Get -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER } -Uri $TokenUri
    $ArmToken  = $TokenResp.access_token
    if ([string]::IsNullOrEmpty($ArmToken)) {
        throw 'Token was null or empty.'
    }
}
catch {
    throw "Failed to acquire ARM access token: $_"
}

$ArmHeader = @{
    Authorization  = "Bearer $ArmToken"
    'Content-Type' = 'application/json'
}

Write-Log 'ARM token acquired.'

#endregion ARM Authentication

#region Read Current Route Table

$ApiVersion = '2023-09-01'
$RtBaseUri  = "$($ResourceManagerUri)subscriptions/$SubId/resourceGroups/$RgName/providers/Microsoft.Network/routeTables/$RouteTableName"
$RtUri      = "$RtBaseUri`?api-version=$ApiVersion"

try {
    $RouteTable = Invoke-RestMethod -Method Get -Headers $ArmHeader -Uri $RtUri
}
catch {
    throw "Failed to GET route table '$RouteTableName': $_"
}

Write-Log "Read route table. Existing routes: $($RouteTable.properties.routes.Count)"

#endregion Read Current Route Table

#region Check M365 Data Version

# The M365 endpoint API exposes a lightweight /version/{instance} endpoint that
# returns a version string (format YYYYMMDDNN) for the selected instance.
# We store the last applied version in a tag (M365RouteVersion) on the route
# table itself so the check is stateless and visible to operators.
# If the version matches we skip the full download entirely.
# If the version check fails we log a warning and proceed with the full update
# as a safe fallback.

$CurrentAppliedVersion = if ($null -ne $RouteTable.tags) { $RouteTable.tags.'M365RouteVersion' } else { $null }

$LatestVersion = $null
try {
    $VersionUrl  = "https://endpoints.office.com/version/$M365Instance`?clientrequestid=$([System.Guid]::NewGuid().ToString())"
    $VersionResp = Invoke-RestMethod -Method Get -Uri $VersionUrl
    # Response may be a single object {latest: ...} or an array when called without an instance.
    if ($VersionResp -is [array]) {
        $LatestVersion = ($VersionResp | Where-Object { $_.instance -ieq $M365Instance }).latest
    }
    else {
        $LatestVersion = $VersionResp.latest
    }
    Write-Log "Version check: latest=$LatestVersion | applied=$($CurrentAppliedVersion ?? '(none)')"
}
catch {
    Write-Log "Version check failed (non-fatal) - proceeding with full download: $_" -Warn
}

if ($LatestVersion -and $CurrentAppliedVersion -and $LatestVersion -eq $CurrentAppliedVersion) {
    Write-Log "M365 data is current (version $LatestVersion). No update needed."
    return
}

#endregion Check M365 Data Version

#region Download M365 IP Ranges

# The Microsoft 365 endpoint API returns a JSON array of endpoint objects.
# Each object may contain an 'ips' array with IPv4 and/or IPv6 CIDR ranges.
# Supported instance values:
#   worldwide    - Microsoft 365 Worldwide (including GCC)
#   china        - Microsoft 365 operated by 21 Vianet
#   usgovdod     - Microsoft 365 U.S. Government DoD
#   usgovgcchigh - Microsoft 365 U.S. Government GCC High

$RequestId = [System.Guid]::NewGuid().ToString()
$M365Url   = "https://endpoints.office.com/endpoints/$M365Instance`?clientrequestid=$RequestId"

Write-Log "Downloading M365 IP ranges from: $M365Url"

try {
    $Endpoints = Invoke-RestMethod -Method Get -Uri $M365Url
}
catch {
    throw "Failed to download M365 endpoint data: $_"
}

Write-Log "Downloaded $($Endpoints.Count) M365 endpoint entries."

#endregion Download M365 IP Ranges

#region Build Desired Route Set

# Route name format: M365-{id}-{serviceArea}-{NN}
#   id          - endpoint numeric identifier from the API
#   serviceArea - sanitised service area name (alphanumeric only)
#   NN          - zero-padded two-digit index of the IP within that endpoint entry
#
# Examples:
#   M365-1-Exchange-00  -> 13.107.6.152/31
#   M365-1-Exchange-01  -> 13.107.18.10/31
#   M365-11-Skype-00    -> 52.112.0.0/14
#
# Both IPv4 and IPv6 CIDR ranges are included as separate routes.
# Azure route tables natively support IPv6 address prefixes.

$Desired = [System.Collections.Generic.Dictionary[string, string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($ep in $Endpoints) {
    if (-not $ep.PSObject.Properties['ips'] -or $null -eq $ep.ips -or $ep.ips.Count -eq 0) {
        continue
    }
    # Sanitise: keep only alphanumeric characters so the name is a valid ARM route name
    $svcArea = ($ep.serviceArea -replace '[^a-zA-Z0-9]', '')
    for ($i = 0; $i -lt $ep.ips.Count; $i++) {
        $routeName = "M365-$($ep.id)-$svcArea-$($i.ToString('D2'))"
        $Desired[$routeName] = $ep.ips[$i]
    }
}

Write-Log "Desired M365 routes: $($Desired.Count)"

#endregion Build Desired Route Set

#region Partition Routes

# Separate M365-managed routes from user-managed routes.
# Only routes whose names start with 'M365-' are touched by this function.
# All other routes are preserved verbatim.

$ExistingM365 = [System.Collections.Generic.Dictionary[string, string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$NonM365 = [System.Collections.Generic.List[object]]::new()

foreach ($r in $RouteTable.properties.routes) {
    if ($r.name -match '^M365-') {
        $ExistingM365[$r.name] = $r.properties.addressPrefix
    }
    else {
        # Rebuild route objects without read-only ARM properties (id, type, etag)
        # so the PUT body is accepted by the API.
        $props = [ordered]@{
            addressPrefix = $r.properties.addressPrefix
            nextHopType   = $r.properties.nextHopType
        }
        if (-not [string]::IsNullOrEmpty($r.properties.nextHopIpAddress)) {
            $props['nextHopIpAddress'] = $r.properties.nextHopIpAddress
        }
        $NonM365.Add([ordered]@{ name = $r.name; properties = $props })
    }
}

Write-Log "Partitioned: $($ExistingM365.Count) existing M365 routes, $($NonM365.Count) non-M365 routes preserved."

#endregion Partition Routes

#region Compute Diff

$ToAddOrUpdate  = [System.Collections.Generic.List[string]]::new()
$ToRemove  = [System.Collections.Generic.List[string]]::new()
$Unchanged = 0

foreach ($name in $Desired.Keys) {
    if ($ExistingM365.ContainsKey($name) -and $ExistingM365[$name] -eq $Desired[$name]) {
        $Unchanged++
    }
    else {
        $ToAddOrUpdate.Add($name)
    }
}

foreach ($name in $ExistingM365.Keys) {
    if (-not $Desired.ContainsKey($name)) {
        $ToRemove.Add($name)
    }
}

Write-Log "Diff: $($ToAddOrUpdate.Count) to add/update, $($ToRemove.Count) to remove, $Unchanged unchanged."

if ($ToAddOrUpdate.Count -eq 0 -and $ToRemove.Count -eq 0) {
    Write-Log 'Route table is already up to date. No changes needed.'
    return
}

#endregion Compute Diff

#region Build and PUT Updated Route Table

# Merge non-M365 routes (preserved) with the full desired M365 route set.
# This replaces all old M365 routes (including stale ones) in a single atomic PUT.
$NewRoutes = [System.Collections.Generic.List[object]]::new()
$NewRoutes.AddRange($NonM365)

foreach ($name in $Desired.Keys) {
    $NewRoutes.Add([ordered]@{
        name       = $name
        properties = [ordered]@{
            addressPrefix = $Desired[$name]
            nextHopType   = 'Internet'
        }
    })
}

# Construct PUT body. Only include writable top-level properties.
# Merge existing tags with the new version tag so other tags are preserved.
$MergedTags = [ordered]@{}
if ($null -ne $RouteTable.tags) {
    foreach ($prop in $RouteTable.tags.PSObject.Properties) {
        $MergedTags[$prop.Name] = $prop.Value
    }
}
if ($LatestVersion) {
    $MergedTags['M365RouteVersion'] = $LatestVersion
}

$PutBody = [ordered]@{
    location   = $RouteTable.location
    properties = [ordered]@{
        disableBgpRoutePropagation = [bool]$RouteTable.properties.disableBgpRoutePropagation
        routes                     = $NewRoutes
    }
}
if ($MergedTags.Count -gt 0) {
    $PutBody['tags'] = $MergedTags
}

$BodyJson = $PutBody | ConvertTo-Json -Depth 10 -Compress

Write-Log "Sending PUT with $($NewRoutes.Count) total routes ($($NonM365.Count) user + $($Desired.Count) M365)..."

try {
    $Result = Invoke-RestMethod -Method Put -Headers $ArmHeader -Uri $RtUri -Body $BodyJson
    Write-Log "PUT accepted. Provisioning state: $($Result.properties.provisioningState)"
}
catch {
    throw "Failed to PUT route table '$RouteTableName': $_"
}

#endregion Build and PUT Updated Route Table

#region Summary

$RemovedList = if ($ToRemove.Count -gt 0) { $ToRemove -join ', ' } else { 'none' }
Write-Log "DONE | Added/updated: $($ToAddOrUpdate.Count) | Removed: $($ToRemove.Count) ($RemovedList) | Unchanged: $Unchanged"

#endregion Summary
