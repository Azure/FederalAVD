# M365 Route Table Updater - Azure Automation Runbook
# Reads configuration from Automation Variables and authenticates via the
# system-assigned managed identity on the Automation Account.
#
# Local testing: set $env:RouteTableResourceId, $env:M365EndpointInstance, and
# $env:ResourceManagerUri, then run directly. The script auto-detects whether
# it is running inside Azure Automation by checking for Get-AutomationVariable.

# Auto-detect execution context - no param block so Automation does not surface
# a 'LocalTest' prompt when the runbook is triggered manually from the portal.
$isAutomation = $null -ne (Get-Command 'Get-AutomationVariable' -ErrorAction SilentlyContinue)

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

if (-not $isAutomation) {
    Write-Log 'Local mode - reading config from environment variables.'
    $RouteTableResourceId = $env:RouteTableResourceId
    $M365Instance         = if ($env:M365EndpointInstance) { $env:M365EndpointInstance } else { 'worldwide' }
    $ResourceManagerUri   = if ($env:ResourceManagerUri)   { $env:ResourceManagerUri   } else { 'https://management.azure.com/' }
}
else {
    $RouteTableResourceId = Get-AutomationVariable -Name 'RouteTableResourceId'
    $M365Instance         = Get-AutomationVariable -Name 'M365EndpointInstance'
    $ResourceManagerUri   = Get-AutomationVariable -Name 'ResourceManagerUri'
}

if ([string]::IsNullOrEmpty($RouteTableResourceId)) {
    throw 'RouteTableResourceId is not set.'
}
if ([string]::IsNullOrEmpty($M365Instance)) {
    throw 'M365EndpointInstance is not set.'
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

# Route name prefix per instance - worldwide uses the bare 'M365-' prefix;
# other instances get a short environment label so routes from different
# instances can coexist in the same route table without interfering.
$RoutePrefix = switch ($M365Instance) {
    'usgovdod'     { 'M365-DoD-'   }
    'usgovgcchigh' { 'M365-GCCH-'  }
    'china'        { 'M365-China-' }
    default        { 'M365-'       }   # worldwide
}

# Regex that identifies routes owned by this specific instance.
# Worldwide uses a digit-anchored pattern (M365-\d) so it does not
# accidentally match instance-prefixed routes (M365-DoD-, etc.).
$OwnedRoutePattern = switch ($M365Instance) {
    'usgovdod'     { '^M365-DoD-'   }
    'usgovgcchigh' { '^M365-GCCH-'  }
    'china'        { '^M365-China-' }
    default        { '^M365-\d'    }   # worldwide
}

# Short human-readable label for this instance - used in tags and log output.
$InstanceLabel  = switch ($M365Instance) {
    'usgovdod'     { 'DoD'       }
    'usgovgcchigh' { 'GCCH'      }
    'china'        { 'China'     }
    default        { 'worldwide' }
}
# Per-instance version tag so multiple instances can share a route table
# without overwriting each other's version bookmarks.
$VersionTagName = "M365RouteVersion-$InstanceLabel"

Write-Log "Starting | Route table: $RouteTableName | RG: $RgName | Sub: $SubId | Instance: $M365Instance | Prefix: $RoutePrefix"

#endregion Configuration

#region ARM Authentication

if (-not $isAutomation) {
    Write-Log 'Local mode - acquiring ARM token via Azure CLI.'
    try {
        $AzTokenJson = & az account get-access-token --resource ($ResourceManagerUri.TrimEnd('/')) 2>&1
        if ($LASTEXITCODE -ne 0) { throw $AzTokenJson }
        $ArmToken = ($AzTokenJson | ConvertFrom-Json).accessToken
        if ([string]::IsNullOrEmpty($ArmToken)) { throw 'Token was null or empty.' }
    }
    catch {
        throw "Failed to acquire ARM token via Azure CLI: $_"
    }
}
else {
    # Authenticate using the Automation Account system-assigned managed identity.
    # Connect-AzAccount -Identity is the correct approach for Automation sandboxes;
    # IMDS (169.254.169.254) is not available in this execution environment.
    try {
        Connect-AzAccount -Identity | Out-Null
        $tokenObj = Get-AzAccessToken -ResourceUrl ($ResourceManagerUri.TrimEnd('/'))
        # Az module versions differ: Token may be a plain string or a SecureString.
        $ArmToken = if ($tokenObj.Token -is [System.Security.SecureString]) {
            [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
        } else {
            $tokenObj.Token
        }
        if ([string]::IsNullOrEmpty($ArmToken)) {
            throw 'Token was null or empty.'
        }
    }
    catch {
        throw "Failed to acquire ARM access token via managed identity: $_"
    }
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
# We store the last applied version in a per-instance tag (e.g. M365RouteVersion-DoD) on the
# route table itself so the check is stateless and visible to operators.
# Multiple instances can share a route table without overwriting each other's bookmarks.
# If the version matches we skip the full download entirely.
# If the version check fails we log a warning and proceed with the full update
# as a safe fallback.

$CurrentAppliedVersion = if ($null -ne $RouteTable.tags) { $RouteTable.tags.$VersionTagName } else { $null }

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

# Route name format: {prefix}{id}-{serviceArea}-{NN}
#   prefix      - instance label: 'M365-' (worldwide), 'M365-DoD-', 'M365-GCCH-', 'M365-China-'
#   id          - endpoint numeric identifier from the API
#   serviceArea - sanitised service area name (alphanumeric only)
#   NN          - zero-padded two-digit sequence within that endpoint entry (duplicate CIDRs skipped)
#
# Examples (worldwide):
#   M365-1-Exchange-00  -> 13.107.6.152/31
#   M365-1-Exchange-01  -> 13.107.18.10/31
#   M365-11-Teams-00    -> 52.112.0.0/14
# Examples (DoD):
#   M365-DoD-1-Exchange-00  -> 13.107.6.152/31
#
# Both IPv4 and IPv6 CIDR ranges are included as separate routes.
# Azure route tables natively support IPv6 address prefixes.

$Desired   = [System.Collections.Generic.Dictionary[string, string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
# Track seen CIDRs to skip duplicates - the M365 API returns the same prefix in
# multiple endpoint entries and Azure route tables reject duplicate address prefixes.
$SeenCidrs = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$DuplicateCount = 0

foreach ($ep in $Endpoints) {
    if (-not $ep.PSObject.Properties['ips'] -or $null -eq $ep.ips -or $ep.ips.Count -eq 0) {
        continue
    }
    # Sanitise: keep only alphanumeric characters so the name is a valid ARM route name
    $svcArea  = ($ep.serviceArea -replace '[^a-zA-Z0-9]', '')
    # Friendly name overrides - the M365 API labels Teams endpoints as 'Skype'
    $svcArea  = @{ Skype = 'Teams' }[$svcArea] ?? $svcArea
    $routeIdx = 0
    for ($i = 0; $i -lt $ep.ips.Count; $i++) {
        $cidr = $ep.ips[$i]
        if (-not $SeenCidrs.Add($cidr)) {
            $DuplicateCount++
            continue   # same prefix already added by an earlier endpoint entry - skip
        }
        $routeName = "$RoutePrefix$($ep.id)-$svcArea-$($routeIdx.ToString('D2'))"
        $Desired[$routeName] = $cidr
        $routeIdx++
    }
}

Write-Log "Desired M365 routes: $($Desired.Count) (skipped $DuplicateCount duplicate prefixes across endpoint entries)"

#endregion Build Desired Route Set

#region Partition Routes

# Separate M365-managed routes from user-managed routes.
# Only routes whose names start with the instance-specific prefix are touched;
# routes owned by other instances (different prefix) are preserved verbatim.

$ExistingM365 = [System.Collections.Generic.Dictionary[string, string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$NonM365 = [System.Collections.Generic.List[object]]::new()

foreach ($r in $RouteTable.properties.routes) {
    if ($r.name -match $OwnedRoutePattern) {
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

# Legacy cleanup: remove any non-M365-prefixed route whose CIDR conflicts with a desired
# route. This handles routes created before the instance-prefix naming was introduced
# (e.g. 'M365-1-Exchange-00' when now running as DoD). Those routes would otherwise cause
# a RouteConflict error on PUT because Azure rejects duplicate address prefixes.
$DesiredCidrs  = [System.Collections.Generic.HashSet[string]]::new($Desired.Values, [System.StringComparer]::OrdinalIgnoreCase)
$LegacyRemoved = [System.Collections.Generic.List[string]]::new()
$CleanNonM365  = [System.Collections.Generic.List[object]]::new()

foreach ($r in $NonM365) {
    if ($DesiredCidrs.Contains($r.properties.addressPrefix)) {
        $LegacyRemoved.Add($r.name)
    }
    else {
        $CleanNonM365.Add($r)
    }
}
$NonM365 = $CleanNonM365

if ($LegacyRemoved.Count -gt 0) {
    Write-Log "Legacy cleanup: removed $($LegacyRemoved.Count) routes with conflicting CIDRs (old naming convention): $($LegacyRemoved -join ', ')"
}

#endregion Partition Routes

#region Compute Diff

$ToAddOrUpdate = [System.Collections.Generic.List[string]]::new()
$ToRemove      = [System.Collections.Generic.List[string]]::new()
$Unchanged     = 0

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

$TagNeedsUpdate = $LatestVersion -and ($CurrentAppliedVersion -ne $LatestVersion)

if ($ToAddOrUpdate.Count -eq 0 -and $ToRemove.Count -eq 0) {
    if (-not $TagNeedsUpdate) {
        Write-Log 'Route table is already up to date. No changes needed.'
        return
    }
    Write-Log 'Routes are current but version tag is missing or stale - updating tag only.'
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
    $MergedTags[$VersionTagName] = $LatestVersion
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

# Build a per-category breakdown for the log line.
$RouteCounts = @{ user = 0; worldwide = 0; DoD = 0; GCCH = 0; China = 0 }
foreach ($r in $NonM365) {
    $cat = if     ($r.name -match '^M365-DoD-')   { 'DoD' }
           elseif ($r.name -match '^M365-GCCH-')  { 'GCCH' }
           elseif ($r.name -match '^M365-China-') { 'China' }
           elseif ($r.name -match '^M365-\d')     { 'worldwide' }
           else                                    { 'user' }
    $RouteCounts[$cat]++
}
$RouteCounts[$InstanceLabel] += $Desired.Count
$BreakdownParts = [System.Collections.Generic.List[string]]::new()
if ($RouteCounts['user']      -gt 0) { $BreakdownParts.Add("$($RouteCounts['user']) user")           }
if ($RouteCounts['worldwide'] -gt 0) { $BreakdownParts.Add("$($RouteCounts['worldwide']) worldwide") }
if ($RouteCounts['DoD']       -gt 0) { $BreakdownParts.Add("$($RouteCounts['DoD']) DoD")             }
if ($RouteCounts['GCCH']      -gt 0) { $BreakdownParts.Add("$($RouteCounts['GCCH']) GCCH")           }
if ($RouteCounts['China']     -gt 0) { $BreakdownParts.Add("$($RouteCounts['China']) China")         }

Write-Log "Sending PUT with $($NewRoutes.Count) total routes ($($BreakdownParts -join ' + '))..."

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
