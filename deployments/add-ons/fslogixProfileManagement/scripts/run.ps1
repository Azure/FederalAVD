<#
.SYNOPSIS
Removes expired FSLogix profiles from Azure Files through HTTPS FileREST requests.

.DESCRIPTION
Runs as a timer-triggered Function App using its system-assigned managed identity.
Required app settings: SubscriptionIds (comma-separated GUIDs) and DeleteOlderThanDays (1-36500).
Discovers storage accounts and shares named profilecontainers using Azure Resource Manager.
ResourceManagerUrl optionally overrides the default public-cloud management endpoint.
The identity needs Reader and Storage File Data Privileged Contributor in every target subscription.
GraphResourceUrl optionally overrides the Microsoft Graph endpoint inferred from ResourceManagerUrl.
User.Read.All application permission with admin consent enables best-effort Entra user lookup.

Each top-level folder is treated as one profile. Its entire contents are deleted only
when it contains qualifying profile disks and all of those disks are expired.
Folders without qualifying disks are retained; root-level disks are evaluated individually.

.PARAMETER Timer
Timer-trigger metadata supplied by the Function App host; not used to determine expiration.

.NOTES
Supports -WhatIf for a read-only preview; authentication and enumeration still occur.
Run while users are signed out: the inventory and deletion are not atomic.
No SMB mount, storage account key, or temporary VM is used.
#>
[CmdletBinding(SupportsShouldProcess)]
param($Timer)

# Make request and parsing failures terminate cleanup rather than continuing with incomplete information.
$ErrorActionPreference = 'Stop'

# Emit one JSON object per event, without mixing telemetry into helper return values.
function Write-CleanupLog
{
    param(
        [string]$EventType,
        [string]$Message,
        [string]$Path,
        [string]$ItemType,
        [string]$Level = 'Information',
        [hashtable]$Metrics = @{}
    )

    $Record = [ordered]@{
        SchemaVersion = 1
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
        RunId = $script:RunId
        EventType = $EventType
        Level = $Level
        SubscriptionId = $script:LogContext.SubscriptionId
        StorageAccount = $script:LogContext.StorageAccount
        ShareName = $script:LogContext.ShareName
        ShareUri = $script:LogContext.ShareUri
        ProfileFolder = $script:LogContext.ProfileFolder
        Path = $Path
        ItemType = $ItemType
        UserSid = $script:LogContext.UserSid
        UserDisplayName = $script:LogContext.UserDisplayName
        UserId = $script:LogContext.UserId
        UserLookupStatus = $script:LogContext.UserLookupStatus
        Message = $Message
    }
    foreach ($Key in $Metrics.Keys) { $Record[$Key] = $Metrics[$Key] }
    Write-Information ($Record | ConvertTo-Json -Compress) -InformationAction Continue
}

# Entra SIDs embed an object GUID; synchronized AD SIDs are matched against the user's on-premises SID.
# Lookup is enrichment only: retain the SID and an explicit status if Graph cannot resolve it.
function Resolve-ProfileUser
{
    param(
        [string]$Name,
        [string]$GraphResourceUrl
    )

    $User = @{ UserSid = $null; UserDisplayName = $null; UserId = $null; UserLookupStatus = 'NoSid' }
    if ($Name -notmatch '(?i)(?<![a-z0-9])S-1-(?:\d+-)+\d+(?![a-z0-9-])') { return $User }
    $Sid = $Matches[0].ToUpperInvariant()
    if ($script:ProfileUsers.ContainsKey($Sid)) { return $script:ProfileUsers[$Sid] }
    $User.UserSid = $Sid
    try
    {
        if ([string]::IsNullOrWhiteSpace($GraphResourceUrl))
        {
            throw "The Microsoft Graph resource URL is not set. This solution was not developed to operate in this Azure cloud ($env:Cloud)."
        }
        $Headers = @{
            Authorization = 'Bearer ' + (Get-ManagedIdentityToken -Audience $GraphResourceUrl)
            ConsistencyLevel = 'eventual'
        }
        if ($Sid -match '^S-1-12-1-(\d+)-(\d+)-(\d+)-(\d+)$')
        {
            # Each SID component stores four GUID bytes in little-endian order, independently of host endianness.
            $Bytes = [byte[]]::new(16)
            for ($Index = 0; $Index -lt 4; $Index++)
            {
                $Part = [uint32]::Parse($Matches[$Index + 1], [cultureinfo]::InvariantCulture)
                for ($Offset = 0; $Offset -lt 4; $Offset++)
                {
                    $Bytes[$Index * 4 + $Offset] = [byte](($Part -shr ($Offset * 8)) -band 255)
                }
            }
            $ObjectId = [guid]::new($Bytes)
            $Uri = $GraphResourceUrl + "v1.0/users/$ObjectId" + '?$select=id,displayName'
            $Match = Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -TimeoutSec 30
            $Users = @($Match)
        }
        else
        {
            $Filter = [uri]::EscapeDataString("onPremisesSecurityIdentifier eq '$Sid'")
            $Uri = $GraphResourceUrl + 'v1.0/users?$select=id,displayName&$count=true&$filter=' + $Filter
            $Response = Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -TimeoutSec 30
            if ($null -eq $Response.value) { throw 'Graph returned an invalid user listing.' }
            $Users = @($Response.value)
            if ($Response.'@odata.nextLink') { throw 'Graph returned multiple pages for a single SID; refusing an ambiguous match.' }
        }
        if ($Users.Count -eq 0)
        {
            $User.UserLookupStatus = 'NotFound'
        }
        elseif ($Users.Count -eq 1 -and $Users[0].id -and ![string]::IsNullOrWhiteSpace($Users[0].displayName))
        {
            $User.UserId = [string]$Users[0].id
            $User.UserDisplayName = [string]$Users[0].displayName
            $User.UserLookupStatus = 'Resolved'
        }
        else { throw 'Graph returned an ambiguous or incomplete user match.' }
    }
    catch
    {
        $User.UserLookupStatus = 'Failed'
        $script:LogContext.UserSid = $Sid
        $script:LogContext.UserLookupStatus = 'Failed'
        Write-CleanupLog -EventType 'UserLookupFailed' -Level 'Warning' -Message $_.Exception.Message
    }
    $script:ProfileUsers[$Sid] = $User
    $User
}

# Cache separate tokens for Resource Manager discovery and Storage data-plane requests.
function Get-ManagedIdentityToken
{
    param([string]$Audience)

    # Cache the managed-identity token and refresh it five minutes before expiration.
    # Use the Function App host endpoint without an identity selector to request its system-assigned identity.
    $CachedToken = $script:IdentityTokens[$Audience]
    if (!$CachedToken -or [DateTimeOffset]::UtcNow -ge $CachedToken.RefreshTime)
    {
        if ([string]::IsNullOrWhiteSpace($env:IDENTITY_ENDPOINT) -or [string]::IsNullOrWhiteSpace($env:IDENTITY_HEADER))
        {
            throw 'Function App managed identity endpoint is unavailable. Enable the system-assigned managed identity and ensure IDENTITY_ENDPOINT and IDENTITY_HEADER are present.'
        }
        $Resource = [uri]::EscapeDataString($Audience)
        $TokenUri = $env:IDENTITY_ENDPOINT + '?api-version=2019-08-01&resource=' + $Resource
        # The host injects this header value; never log it or the returned bearer token.
        $TokenHeaders = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }
        $Token = Invoke-RestMethod -Method Get -Uri $TokenUri -Headers $TokenHeaders -TimeoutSec 30
        if ([string]::IsNullOrWhiteSpace($Token.access_token))
        {
            throw "Managed identity did not return an access token for '$Audience'."
        }

        # expires_on is Unix time in seconds, not a token lifetime in seconds.
        $CachedToken = @{
            AccessToken = $Token.access_token
            RefreshTime = [DateTimeOffset]::FromUnixTimeSeconds([long]$Token.expires_on).AddMinutes(-5)
        }
        $script:IdentityTokens[$Audience] = $CachedToken
    }
    $CachedToken.AccessToken
}

# Follow ARM nextLink values for both storage-account and file-share discovery.
function Get-ArmResources
{
    param([string]$Uri)

    do
    {
        $PageUri = [uri]$Uri
        if ($PageUri.Scheme -ne 'https' -or $PageUri.Authority -ne ([uri]$ResourceManagerUrl).Authority)
        {
            throw "Unexpected Resource Manager discovery URL: '$Uri'."
        }
        $Headers = @{ Authorization = 'Bearer ' + (Get-ManagedIdentityToken -Audience $ResourceManagerUrl) }
        $Page = Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -TimeoutSec 120
        if ($null -eq $Page.value)
        {
            throw "Invalid Resource Manager listing for '$Uri'."
        }
        $Page.value
        $Uri = [string]$Page.nextLink
    } while ($Uri)
}

# Centralize FileREST requests for listing and deletion within the current share.
function Invoke-FileRest
{
    param(
        [string]$Method,
        [string]$Path = '',
        [string]$Query = ''
    )

    # Path is relative to the share; an empty path targets the share's root directory.
    # Query distinguishes directory operations from file operations at the same URL.
    # Encode individual names without encoding path separators. OAuth FileREST requires backup intent.
    $EncodedPath = ($Path.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $Uri = $ShareUri
    if ($EncodedPath) { $Uri += '/' + $EncodedPath }
    if ($Query) { $Uri += '?' + $Query }
    $Headers = @{
        Authorization = 'Bearer ' + (Get-ManagedIdentityToken -Audience $StorageAudience)
        'x-ms-date' = [DateTime]::UtcNow.ToString('R', [cultureinfo]::InvariantCulture)
        'x-ms-version' = '2022-11-02'
        # Backup intent requires privileged Azure Files data permissions; it does not create a backup.
        'x-ms-file-request-intent' = 'backup'
        # Preserve trailing dots in names so requests address exactly the entries that were listed.
        'x-ms-allow-trailing-dot' = 'true'
    }
    try
    {
        Invoke-WebRequest -Method $Method -Uri $Uri -Headers $Headers -TimeoutSec 120 -UseBasicParsing
    }
    catch
    {
        # Mark only recognized FileREST failures; token and ARM failures must still terminate.
        if ([int]$_.Exception.Response.StatusCode -eq 403)
        {
            $_.Exception.Data['FileRestForbidden'] = $true
        }
        elseif ([int]$_.Exception.Response.StatusCode -eq 409 -and
            $_.Exception.Response.Headers.Contains('x-ms-error-code'))
        {
            $ErrorCode = @($_.Exception.Response.Headers.GetValues('x-ms-error-code'))[0]
            if ($ErrorCode -cin @('SharingViolation', 'DirectoryNotEmpty'))
            {
                $_.Exception.Data['FileRestErrorCode'] = $ErrorCode
                $_.Exception.Data['FileRestPath'] = $Path
                $_.Exception.Data['FileRestMethod'] = $Method
                $_.Exception.Data['FileRestItemType'] = if ($Query -match '(^|&)restype=directory(&|$)') { 'Directory' } else { 'File' }
                if ($_.Exception.Response.Headers.Contains('x-ms-request-id'))
                {
                    $_.Exception.Data['FileRestRequestId'] = @($_.Exception.Response.Headers.GetValues('x-ms-request-id'))[0]
                }
            }
        }
        throw
    }
}

# Enumerate every page of a directory listing, including the timestamps used for expiration.
function Get-FileRestEntries
{
    param([string]$Path = '')

    # Continuation markers are opaque service values, not directory names or numeric page offsets.
    $Marker = ''
    do
    {
        $Query = 'restype=directory&comp=list&include=Timestamps'
        if ($Marker) { $Query += '&marker=' + [uri]::EscapeDataString($Marker) }
        $Response = Invoke-FileRest -Method Get -Path $Path -Query $Query
        # FileREST returns XML. A missing Entries element is an invalid response, not an empty folder.
        [xml]$Listing = $Response.Content.TrimStart([char]0xFEFF)
        $Entries = $Listing.SelectSingleNode('/EnumerationResults/Entries')
        if ($null -eq $Entries)
        {
            throw "Invalid directory listing for '$Path'."
        }
        foreach ($Entry in $Entries.ChildNodes)
        {
            if ($Entry.LocalName -notin @('File', 'Directory')) { continue }

            # Azure encodes names containing XML-invalid characters; validate decoded names before building paths.
            $NameNode = $Entry.SelectSingleNode('Name')
            if ($null -eq $NameNode) { throw "Missing entry name in directory '$Path'." }
            $Name = $NameNode.InnerText
            if ($NameNode.GetAttribute('Encoded') -eq 'true')
            {
                $Name = [uri]::UnescapeDataString($Name)
            }
            if ([string]::IsNullOrWhiteSpace($Name) -or $Name -in @('.', '..') -or $Name.Contains('/') -or $Name.Contains('\'))
            {
                throw "Invalid entry name in directory '$Path'."
            }

            # Keep names decoded in the inventory; Invoke-FileRest encodes them once when sending requests.
            $EntryPath = if ($Path) { $Path + '/' + $Name } else { $Name }
            $SizeBytes = $null
            if ($Entry.LocalName -eq 'File')
            {
                $Length = 0L
                if (![long]::TryParse([string]$Entry.Properties.'Content-Length', [ref]$Length) -or $Length -lt 0)
                {
                    throw "Missing or invalid Content-Length for '$EntryPath'; refusing to report an unknown file size."
                }
                $SizeBytes = $Length
            }
            [pscustomobject]@{
                Path = $EntryPath
                Name = $Name
                IsDirectory = $Entry.LocalName -eq 'Directory'
                Properties = $Entry.Properties
                SizeBytes = $SizeBytes
            }
        }

        # An empty NextMarker ends enumeration, including for an empty directory.
        $Marker = [string]$Listing.EnumerationResults.NextMarker
    } while ($Marker)
}

# Recursively inventory a profile before deciding whether its entire directory can be removed.
function Get-ProfileTree
{
    param([string]$Path)

    foreach ($Entry in Get-FileRestEntries -Path $Path)
    {
        $Entry
        if ($Entry.IsDirectory) { Get-ProfileTree -Path $Entry.Path }
    }
}

# Differencing/merge disks do not determine profile age, but are removed with an expired profile.
function Test-ProfileDisk
{
    param($Entry)

    !$Entry.IsDirectory -and $Entry.Name -match '\.vhdx?$' -and $Entry.Name -notin @('Merge.vhdx', 'RW.vhdx')
}

# Require both timestamps and use the newer one so recent access OR writes preserve the profile.
function Test-ExpiredDisk
{
    param(
        $Entry,
        [DateTimeOffset]$DeleteBefore
    )

    # Fail closed on missing or malformed timestamps rather than treating unknown activity as old.
    $Times = foreach ($Property in @('LastAccessTime', 'LastWriteTime'))
    {
        $Value = [string]$Entry.Properties.$Property
        if ([string]::IsNullOrWhiteSpace($Value))
        {
            throw "Missing $Property for '$($Entry.Path)'; refusing to determine expiration."
        }
        $ParsedTime = [DateTimeOffset]::MinValue
        if (![DateTimeOffset]::TryParse($Value, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$ParsedTime))
        {
            throw "Invalid $Property for '$($Entry.Path)'; refusing to determine expiration."
        }
        $ParsedTime
    }

    # Strictly older than the cutoff: a timestamp equal to the cutoff is retained.
    ($Times | Sort-Object -Descending | Select-Object -First 1) -lt $DeleteBefore
}

function Invoke-ProfileCleanup
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ShareUri,
        [string]$GraphResourceUrl,
        [DateTimeOffset]$DeleteBefore
    )

    Write-CleanupLog -EventType 'ShareCleanupStarted' -Message "Removing profiles last used before $($DeleteBefore.ToString('o'))"
    $ProfileCount = 0L
    $DeletedProfiles = 0L
    $TotalBytes = 0L
    $DeletedBytes = 0L
    $EligibleProfiles = 0L
    $EligibleBytes = 0L
    $InventoryComplete = $true

    # Treat top-level folders as independent profiles; never delete the share root itself.
    foreach ($RootEntry in Get-FileRestEntries)
    {
        $script:LogContext.ProfileFolder = if ($RootEntry.IsDirectory) { $RootEntry.Path } else { $null }
        foreach ($Key in @('UserSid', 'UserDisplayName', 'UserId', 'UserLookupStatus')) { $script:LogContext[$Key] = $null }
        try
        {
            # Root-level profile disks are evaluated individually without removing neighboring files.
            if (!$RootEntry.IsDirectory)
            {
                $TotalBytes += $RootEntry.SizeBytes
                if (!(Test-ProfileDisk $RootEntry)) { continue }
                $ProfileCount++
                $Expired = Test-ExpiredDisk -Entry $RootEntry -DeleteBefore $DeleteBefore
                if ($Expired) { $EligibleProfiles++; $EligibleBytes += $RootEntry.SizeBytes }
                Write-CleanupLog -EventType 'ProfileInventoried' -Path $RootEntry.Path -ItemType 'File' -Message 'Inventoried root-level profile disk' -Metrics @{
                    SizeBytes = $RootEntry.SizeBytes; Eligible = $Expired; Preview = [bool]$WhatIfPreference
                }
                if ($Expired -and $PSCmdlet.ShouldProcess("$ShareUri/$($RootEntry.Path)", 'Delete expired profile disk'))
                {
                    $User = Resolve-ProfileUser -Name $RootEntry.Name -GraphResourceUrl $GraphResourceUrl
                    foreach ($Key in $User.Keys) { $script:LogContext[$Key] = $User[$Key] }
                    Invoke-FileRest -Method Delete -Path $RootEntry.Path | Out-Null
                    $DeletedBytes += $RootEntry.SizeBytes
                    $DeletedProfiles++
                    Write-CleanupLog -EventType 'DiskDeleted' -Path $RootEntry.Path -ItemType 'File' -Message 'Deleted expired root-level profile disk' -Metrics @{ SizeBytes = $RootEntry.SizeBytes }
                }
                continue
            }

            # Preserve folders without qualifying disks or with any unexpired disk, including nested disks.
            # Materialize the inventory before making changes so eligibility uses the complete profile tree.
            $Tree = @(Get-ProfileTree -Path $RootEntry.Path)
            $ProfileBytes = 0L
            foreach ($File in $Tree | Where-Object { !$_.IsDirectory }) { $ProfileBytes += $File.SizeBytes }
            $TotalBytes += $ProfileBytes
            $Disks = @($Tree | Where-Object { Test-ProfileDisk $_ })
            if ($Disks.Count -eq 0) { continue }
            $ProfileCount++
            $HasUnexpiredDisk = $false

            # Check every disk, even after finding a recent one, so invalid timestamps still surface as errors.
            foreach ($Disk in $Disks)
            {
                if (!(Test-ExpiredDisk -Entry $Disk -DeleteBefore $DeleteBefore)) { $HasUnexpiredDisk = $true }
            }
            if (!$HasUnexpiredDisk) { $EligibleProfiles++; $EligibleBytes += $ProfileBytes }
            Write-CleanupLog -EventType 'ProfileInventoried' -Path $RootEntry.Path -ItemType 'Directory' -Message 'Inventoried profile directory' -Metrics @{
                SizeBytes = $ProfileBytes; Eligible = !$HasUnexpiredDisk; Preview = [bool]$WhatIfPreference
            }
            if ($HasUnexpiredDisk) { continue }

            # Honor -WhatIf/-Confirm before deleting any part of this profile.
            if (!$PSCmdlet.ShouldProcess("$ShareUri/$($RootEntry.Path)", 'Delete expired profile directory and ALL contents')) { continue }
            $User = Resolve-ProfileUser -Name $RootEntry.Name -GraphResourceUrl $GraphResourceUrl
            foreach ($Key in $User.Keys) { $script:LogContext[$Key] = $User[$Key] }

            # Delete profile disks first so an SMB sharing violation stops cleanup before ancillary files are removed.
            foreach ($Disk in $Disks)
            {
                Invoke-FileRest -Method Delete -Path $Disk.Path | Out-Null
                $DeletedBytes += $Disk.SizeBytes
                Write-CleanupLog -EventType 'DiskDeleted' -Path $Disk.Path -ItemType 'File' -Message 'Deleted profile disk' -Metrics @{ SizeBytes = $Disk.SizeBytes }
            }

            # Once profile disks are removed, delete all remaining contents, including excluded disk names.
            foreach ($File in $Tree | Where-Object { !$_.IsDirectory -and !(Test-ProfileDisk $_) })
            {
                Invoke-FileRest -Method Delete -Path $File.Path | Out-Null
                $DeletedBytes += $File.SizeBytes
                Write-CleanupLog -EventType 'FileDeleted' -Path $File.Path -ItemType 'File' -Message 'Deleted profile file' -Metrics @{ SizeBytes = $File.SizeBytes }
            }

            # FileREST only deletes empty directories, so remove descendants before their parents.
            foreach ($Directory in $Tree | Where-Object IsDirectory | Sort-Object { $_.Path.Split('/').Count } -Descending)
            {
                Invoke-FileRest -Method Delete -Path $Directory.Path -Query 'restype=directory' | Out-Null
                Write-CleanupLog -EventType 'DirectoryDeleted' -Path $Directory.Path -ItemType 'Directory' -Message 'Deleted nested directory'
            }

            # Delete the profile folder last. Concurrently created contents cause this request to fail, not recurse.
            Invoke-FileRest -Method Delete -Path $RootEntry.Path -Query 'restype=directory' | Out-Null
            $DeletedProfiles++
            Write-CleanupLog -EventType 'ProfileDeleted' -Path $RootEntry.Path -ItemType 'Directory' -Message 'Deleted profile directory and all contents' -Metrics @{ SizeBytes = $ProfileBytes }
        }
        catch
        {
            $Failure = $_.Exception.Data
            if ($Failure['FileRestErrorCode'] -cnotin @('SharingViolation', 'DirectoryNotEmpty')) { throw }
            if ($Failure['FileRestMethod'] -eq 'Get') { $InventoryComplete = $false }
            Write-CleanupLog -EventType 'ProfileSkipped' -Level 'Warning' -Path $Failure['FileRestPath'] -ItemType $Failure['FileRestItemType'] -Message "FileREST HTTP 409 $($Failure['FileRestErrorCode']) during $($Failure['FileRestMethod']); request ID: $($Failure['FileRestRequestId']). $($_.Exception.Message). Skipping the remainder of this profile; prior deletions are not rolled back."
            continue
        }
    }
    foreach ($Key in @('ProfileFolder', 'UserSid', 'UserDisplayName', 'UserId', 'UserLookupStatus')) { $script:LogContext[$Key] = $null }
    Write-CleanupLog -EventType 'ShareInventoryCompleted' -Message 'Logical file sizes, not allocated or billed capacity; remaining values are estimates from this scan and successful deletions' -Metrics @{
        InventoryComplete = $InventoryComplete
        ProfileCountBefore = $ProfileCount
        ProfileCountAfter = $ProfileCount - $DeletedProfiles
        TotalBytesBefore = $TotalBytes
        TotalBytesAfter = $TotalBytes - $DeletedBytes
        EligibleProfiles = $EligibleProfiles
        EligibleBytes = $EligibleBytes
        DeletedProfiles = $DeletedProfiles
        DeletedBytes = $DeletedBytes
        Preview = [bool]$WhatIfPreference
    }
}

$script:RunId = [guid]::NewGuid().ToString()
$script:LogContext = @{}

try
{
    # Set the security protocol to TLS 1.2 for secure REST API communication.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    # App settings arrive as strings; reject missing, nonnumeric, or out-of-range retention values.
    $RetentionDays = 0
    if (![int]::TryParse($env:DeleteOlderThanDays, [ref]$RetentionDays) -or $RetentionDays -lt 1 -or $RetentionDays -gt 365)
    {
        throw 'DeleteOlderThanDays must be an integer between 1 and 365.'
    }
    $DeleteBefore = [DateTimeOffset]::UtcNow.AddDays(-$RetentionDays)
    
    # Validate the entire comma-separated list before making requests or deleting profiles.
    if ([string]::IsNullOrWhiteSpace($env:SubscriptionIds))
    {
        throw 'SubscriptionIds must contain comma-separated non-empty subscription GUIDs.'
    }

    $SubscriptionIds = @(foreach ($Value in $env:SubscriptionIds.Split(','))
    {
        $ParsedId = [guid]::Empty
        if (![guid]::TryParse($Value.Trim(), [ref]$ParsedId) -or $ParsedId -eq [guid]::Empty)
        {
            throw "Invalid subscription GUID in SubscriptionIds: '$Value'."
        }
        $ParsedId.ToString()
    }) | Select-Object -Unique

    # Resource Manager URL for the current cloud to make Azure REST API requests.
    $ResourceManagerUrl = switch($env:Cloud) { 
        'AzureCloud' { 'https://management.azure.com/' }
        'AzureUSGovernment' { 'https://management.usgovcloudapi.net/' }
        'USSEC' { 'https://management.azure.microsoft.scloud/' }
        'default' { '' }
    }
  
    # This is the token audience, not the URL used to send file requests.
    # https://storage.azure.com/ is shared by Azure public and Government clouds.
    $StorageAudience = 'https://storage.azure.com/'

    # Microsoft Graph URL for REST API requests.
    $GraphResourceUrl = switch($env:Cloud) { 
        'AzureCloud' { 'https://graph.microsoft.com/' }
        'AzureUSGovernment' { 'https://graph.microsoft.us/' }
        'USSEC' { 'https://graph.microsoft.scloud/' }
        'default' { '' }
    }

    # Start each execution with an empty cache; ARM and Storage tokens are cached separately by audience.
    $script:IdentityTokens = @{}
    $script:ProfileUsers = @{}

    foreach ($SubscriptionId in $SubscriptionIds)
    {
        # REST URLs carry the subscription context; no Az module or Set-AzContext is needed.
        $script:LogContext = @{ SubscriptionId = $SubscriptionId }
        Write-CleanupLog -EventType 'SubscriptionStarted' -Message 'Discovering profilecontainers shares'
        
        # ARM discovery avoids probing nonexistent shares through FileREST and works across resource groups.
        $AccountsUri = $ResourceManagerUrl + "subscriptions/$SubscriptionId/providers/Microsoft.Storage/storageAccounts?api-version=2023-05-01"
        foreach ($Account in Get-ArmResources -Uri $AccountsUri)
        {
            $script:LogContext = @{ SubscriptionId = $SubscriptionId; StorageAccount = $Account.name }
           
            # Accounts that do not expose Azure Files cannot contain a profilecontainers share.
            $FileEndpoint = [string]$Account.properties.primaryEndpoints.file
            if (!$FileEndpoint)
            {
                Write-CleanupLog -EventType 'AccountSkipped' -Message 'No Azure Files endpoint'
                continue
            }

            # ARM returns the full account resource ID, including its resource group.
            # A missing ID is a discovery error, not evidence that the target share is absent.
            if ([string]::IsNullOrWhiteSpace($Account.id))
            {
                throw "Missing resource ID for storage account '$($Account.name)'."
            }

            # List shares through the management plane; Get-ArmResources follows all continuation links.
            # Use an exact, case-sensitive name match rather than a prefix or wildcard match.
            $SharesUri = $ResourceManagerUrl.TrimEnd('/') + $Account.id + '/fileServices/default/shares?api-version=2023-05-01'
            $ProfileShare = @(Get-ArmResources -Uri $SharesUri | Where-Object { $_.name -ceq 'profilecontainers' })

            # A successful listing without the target share is an expected skip.
            # Authorization and network failures instead propagate to the outer catch block.
            if ($ProfileShare.Count -eq 0)
            {
                Write-CleanupLog -EventType 'AccountSkipped' -Message 'No profilecontainers share'
                continue
            }

            # Use the advertised endpoint rather than constructing a public-cloud DNS name.
            $ShareUri = $FileEndpoint.TrimEnd('/') + '/profilecontainers'
            $script:LogContext.ShareName = 'profilecontainers'
            $script:LogContext.ShareUri = $ShareUri

            # Discovery is read-only even during a preview; explicitly pass -WhatIf to the cleanup helper.
            # The helper retains the same cutoff and expiration rules for each discovered share.
            try
            {
                Invoke-ProfileCleanup -ShareUri $ShareUri -GraphResourceUrl $GraphResourceUrl -DeleteBefore $DeleteBefore -WhatIf:$WhatIfPreference
            }
            catch
            {
                if (!$_.Exception.Data['FileRestForbidden']) { throw }
                Write-CleanupLog -EventType 'AccountSkipped' -Level 'Error' -Message "FileREST HTTP 403 Forbidden: $($_.Exception.Message). Skipping the remaining cleanup for this storage account; prior deletions are not rolled back."
                continue
            }
            foreach ($Key in @('ProfileFolder', 'UserSid', 'UserDisplayName', 'UserId', 'UserLookupStatus')) { $script:LogContext[$Key] = $null }
            Write-CleanupLog -EventType 'ShareCleanupCompleted' -Message 'Finished processing this share; see ProfileSkipped events for incomplete profile cleanup'
        }
        $script:LogContext = @{ SubscriptionId = $SubscriptionId }
        Write-CleanupLog -EventType 'SubscriptionCompleted' -Message 'Completed subscription cleanup'
    }
    $script:LogContext = @{}
    Write-CleanupLog -EventType 'RunCompleted' -Message 'Finished processing all configured subscriptions; see AccountSkipped and ProfileSkipped events for incomplete cleanup'
}
catch
{
    # Surface failures to the Function host; deletion is not transactional and may be partially complete.
    Write-CleanupLog -EventType 'RunFailed' -Level 'Error' -Message $_.Exception.Message
    throw
}
