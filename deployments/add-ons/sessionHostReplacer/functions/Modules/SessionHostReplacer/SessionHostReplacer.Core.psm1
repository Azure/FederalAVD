# SessionHostReplacer Core Utility Module
# This module contains core utility functions for AVD Session Host Replacer
# Imported by SessionHostReplacer.psm1

#Region Module-Level Variables

# Setting cache to avoid repeated environment variable reads
$Script:SettingCache = @{}

# Cached and normalized ResourceManagerUri without trailing slash
$script:ResourceManagerUri = $null

# Cached and normalized GraphEndpoint without trailing slash
$script:GraphEndpoint = $null
$script:ShrLogContext = $null

#EndRegion Module-Level Variables

#Region Helper Functions

function ConvertTo-CaseInsensitiveHashtable {
    <#
    .SYNOPSIS
        Converts objects to case-insensitive hashtables.
    .DESCRIPTION
        Converts hashtables, PSCustomObjects, OrderedDictionaries, and JSON strings to case-insensitive hashtables.
    .PARAMETER InputObject
        The object to convert.
    .EXAMPLE
        $params = @{Name='Test'; Value='123'} | ConvertTo-CaseInsensitiveHashtable
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        $InputObject
    )
    
    process {
        if ($null -eq $InputObject) {
            return $null
        }
        
        # If already a hashtable, convert to case-insensitive
        if ($InputObject -is [hashtable]) {
            $ciHashtable = New-Object 'System.Collections.Hashtable' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($key in $InputObject.Keys) {
                $value = $InputObject[$key]
                # Recursively convert nested hashtables
                if ($value -is [hashtable] -or $value -is [PSCustomObject]) {
                    $ciHashtable[$key] = ConvertTo-CaseInsensitiveHashtable -InputObject $value
                }
                else {
                    $ciHashtable[$key] = $value
                }
            }
            return $ciHashtable
        }
        
        # If PSCustomObject or OrderedDictionary, convert to case-insensitive hashtable
        if ($InputObject -is [PSCustomObject] -or $InputObject -is [System.Collections.Specialized.OrderedDictionary]) {
            $ciHashtable = New-Object 'System.Collections.Hashtable' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $InputObject.PSObject.Properties) {
                $value = $property.Value
                # Recursively convert nested objects
                if ($value -is [hashtable] -or $value -is [PSCustomObject]) {
                    $ciHashtable[$property.Name] = ConvertTo-CaseInsensitiveHashtable -InputObject $value
                }
                else {
                    $ciHashtable[$property.Name] = $value
                }
            }
            return $ciHashtable
        }
        
        # If JSON string, parse and convert
        if ($InputObject -is [string]) {
            try {
                $parsed = $InputObject | ConvertFrom-Json
                return ConvertTo-CaseInsensitiveHashtable -InputObject $parsed
            }
            catch {
                Write-Error "Unable to parse string as JSON: $_"
                return $null
            }
        }
        
        # Return as-is if cannot convert
        Write-Warning "InputObject type [$($InputObject.GetType().Name)] cannot be converted to case-insensitive hashtable"
        return $InputObject
    }
}

function Get-ResourceManagerUri {
    <#
    .SYNOPSIS
        Gets the ResourceManagerUri without trailing slash.
    .DESCRIPTION
        Retrieves ResourceManagerUri from configuration and ensures it never ends with a trailing slash
        for consistent URI building across all functions. Value is cached for performance.
    .EXAMPLE
        $uri = Get-ResourceManagerUri
    #>
    if ($null -eq $script:ResourceManagerUri) {
        $uri = Read-FunctionAppSetting ResourceManagerUri
        # Remove trailing slash for consistent URI building
        $script:ResourceManagerUri = if ($uri -and $uri[-1] -eq '/') { $uri.TrimEnd('/') } else { $uri }
    }
    return $script:ResourceManagerUri
}

function Get-GraphEndpoint {
    <#
    .SYNOPSIS
        Gets the Microsoft Graph endpoint without trailing slash.
    .DESCRIPTION
        Retrieves GraphEndpoint from configuration and ensures it never ends with a trailing slash
        for consistent URI building. Value is cached for performance.
    .EXAMPLE
        $endpoint = Get-GraphEndpoint
    #>
    if ($null -eq $script:GraphEndpoint) {
        $endpoint = Read-FunctionAppSetting GraphEndpoint
        # Remove trailing slash for consistent URI building
        $script:GraphEndpoint = if ($endpoint -and $endpoint[-1] -eq '/') { $endpoint.TrimEnd('/') } else { $endpoint }
    }
    return $script:GraphEndpoint
}

#EndRegion Helper Functions

#Region Authentication Functions

function Get-AccessToken {
    <#
    .SYNOPSIS
        Retrieves Azure access token using Managed Identity.
    .DESCRIPTION
        Acquires an access token for Azure services using the function app's managed identity.
        Supports both system-assigned and user-assigned managed identities.
        - If ClientId is provided (or UserAssignedIdentityClientId setting is configured), uses user-assigned identity
        - If ClientId is null/empty, uses system-assigned identity
        Tokens are requested fresh on each call to avoid caching complexity.
    .PARAMETER ResourceUri
        The Azure resource endpoint URL (e.g., https://management.azure.com/, https://graph.microsoft.com).
    .PARAMETER ClientId
        Optional. The client ID of the user-assigned managed identity. 
        If not specified, attempts to read from UserAssignedIdentityClientId app setting.
        If still null/empty, uses system-assigned managed identity.
    .EXAMPLE
        # Use system-assigned managed identity
        $token = Get-AccessToken -ResourceUri 'https://management.azure.com/' -ClientId ''
    .EXAMPLE
        # Use user-assigned managed identity with explicit ClientId
        $token = Get-AccessToken -ResourceUri 'https://graph.microsoft.com' -ClientId 'abc123...'
    .EXAMPLE
        # Use user-assigned managed identity from app settings (default behavior)
        $token = Get-AccessToken -ResourceUri 'https://management.azure.com/'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ResourceUri,
        
        [Parameter(Mandatory = $false)]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )
    
    # Determine token type for logging
    $isARMToken = $ResourceUri -like "*management*"
    $isGraphToken = $ResourceUri -like "*graph*"
    $isStorageToken = $ResourceUri -like "*storage*" -or $ResourceUri -like "*.table.*" -or $ResourceUri -like "*.blob.*"
    
    # ARM tokens require trailing slash, Graph and Storage tokens should NOT have trailing slash
    $tokenResourceUri = if ($isARMToken) {
        # ARM: requires trailing slash
        $uri = if ($ResourceUri[-1] -ne '/') { "$ResourceUri/" } else { $ResourceUri }
        Write-Verbose "Requesting ARM token for resource: $uri (with trailing slash)"
        $uri
    }
    else {        
        # Graph and Storage: NO trailing slash
        $uri = if ($ResourceUri[-1] -eq '/') { $ResourceUri.TrimEnd('/') } else { $ResourceUri }
        $tokenType = if ($isGraphToken) { "Graph" } elseif ($isStorageToken) { "Storage" } else { "Other" }
        Write-Verbose "Requesting $tokenType token for resource: $uri (no trailing slash)"
        $uri
    }
    
    # Acquire token from managed identity
    # Build token URI - only include client_id parameter for user-assigned identity
    if ([string]::IsNullOrEmpty($ClientId)) {
        # System-assigned managed identity
        Write-Verbose "Acquiring token using system-assigned managed identity for resource: $tokenResourceUri"
        $TokenAuthURI = $env:IDENTITY_ENDPOINT + '?resource=' + $tokenResourceUri + '&api-version=2019-08-01'
    }
    else {
        # User-assigned managed identity
        Write-Verbose "Acquiring token using user-assigned managed identity (ClientId: $ClientId) for resource: $tokenResourceUri"
        $TokenAuthURI = $env:IDENTITY_ENDPOINT + '?resource=' + $tokenResourceUri + "&client_id=$ClientId" + '&api-version=2019-08-01'
    }
       
    # Add cache-busting headers to force fresh token acquisition
    $headers = @{
        "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER
    }
    
    $TokenResponse = Invoke-RestMethod -Method Get -Headers $headers -Uri $TokenAuthURI -DisableKeepAlive
    
    Write-Verbose "Successfully acquired token for $tokenResourceUri"
    
    return $TokenResponse.access_token
}

#EndRegion Authentication Functions

#Region Configuration Functions

function Read-FunctionAppSetting {
    <#
    .SYNOPSIS
        Retrieves configuration values from Azure Function App Settings with caching.
    .DESCRIPTION
        Reads values from environment variables with automatic type conversion and caching
        to avoid repeated environment variable reads during execution.
    .PARAMETER ConfigKey
        The name of the configuration key to retrieve from environment variables.
    .PARAMETER NoCache
        Optional. Bypass the cache and read directly from environment variable.
    .PARAMETER AsBoolean
        Optional. Process the value as a boolean.
    .EXAMPLE
        $hostPoolName = Read-FunctionAppSetting HostPoolName
    .EXAMPLE
        $value = Read-FunctionAppSetting 'SomeSetting' -NoCache
    .EXAMPLE
        $enabled = Read-FunctionAppSetting EnableProgressiveScaleUp -AsBoolean
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $SettingKey,
        
        [Parameter(Mandatory = $false)]
        [switch] $NoCache,
        
        [Parameter(Mandatory = $false)]
        [switch] $AsBoolean
    )
    
    # Check cache first unless NoCache is specified
    if (-not $NoCache -and $Script:SettingCache.ContainsKey($SettingKey)) {
        Write-Verbose "Using cached value for $SettingKey"
        return $Script:SettingCache[$SettingKey]
    }
    
    # Get the value from environment variable
    $value = [System.Environment]::GetEnvironmentVariable($SettingKey)
    
    # Return null or false if value is null or empty
    if ([string]::IsNullOrWhiteSpace($value)) {
        If ( $AsBoolean ) {
            $Script:SettingCache[$SettingKey] = $false
            return $false
        }
        Else {
            $Script:SettingCache[$SettingKey] = $null
            return $null
        }
    }
    Else {
        If ( $AsBoolean ) {
            if ($value.ToLower() -eq 'true') {
                $Script:SettingCache[$SettingKey] = $true
                return $true
            }
            else {
                $Script:SettingCache[$SettingKey] = $false
                return $false
            }
        }
        if ($value -match '^\d+$') {
            [int]$intValue = [int]$value
            $Script:SettingCache[$SettingKey] = $intValue
            return $intValue
        }
        if ($value.StartsWith('{') -or $value.StartsWith('[')) {
            Try {
                If ($value.StartsWith('{')) {
                    $parsed = $value | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    $Script:SettingCache[$SettingKey] = $parsed
                    return $parsed
                }
                Else {
                    $parsed = $value | ConvertFrom-Json -ErrorAction Stop
                    $Script:SettingCache[$SettingKey] = $parsed
                    return $parsed
                }
            }
            catch {
                Write-Warning "Failed to parse JSON for $SettingKey : $_"
                $Script:SettingCache[$SettingKey] = $value
                return $value
            }
        }
        else {
            $Script:SettingCache[$SettingKey] = $value
            return $value
        }
    }        
}

function Assert-DeviceCleanupConfiguration {
    <#
    .SYNOPSIS
        Validates identity-aware device cleanup requirements before replacement begins.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ReplacementMode,

        [Parameter(Mandatory = $true)]
        [string] $IdentitySolution,

        [Parameter(Mandatory = $true)]
        [bool] $RemoveEntraDevice,

        [Parameter(Mandatory = $true)]
        [bool] $RemoveIntuneDevice,

        [Parameter()]
        [bool] $IntuneEnrollment = $false
    )

    $isEntraJoined = $IdentitySolution -in @('EntraId', 'EntraKerberos-Hybrid', 'EntraKerberos-CloudOnly')

    if ($ReplacementMode -in @('DeleteFirst', 'MaintenanceWindow') -and $isEntraJoined -and -not $RemoveEntraDevice) {
        Write-LogEntry -Message "CRITICAL ERROR: Entra device cleanup is required for exact-name replacement of Microsoft Entra joined session hosts." -Level Error
        throw "RemoveEntraDevice must be enabled for exact-name replacement of Microsoft Entra joined session hosts"
    }

    if ($ReplacementMode -in @('DeleteFirst', 'MaintenanceWindow') -and -not $RemoveIntuneDevice) {
        if ($isEntraJoined -and $IntuneEnrollment) {
            Write-LogEntry -Message "Intune cleanup is disabled for Intune-enrolled Microsoft Entra joined hosts. Cleanup is highly recommended before DeleteFirst hostname reuse to prevent stale or duplicate managed-device records." -Level Warning
        }
        elseif ($IdentitySolution -eq 'ActiveDirectoryDomainServices') {
            Write-LogEntry -Message "If these AD DS hosts are Microsoft Entra hybrid joined and enrolled in Intune, Intune cleanup is highly recommended before DeleteFirst hostname reuse to prevent stale or duplicate managed-device records." -Level Warning
        }
    }
}

#EndRegion Configuration Functions

#Region Logging and Error Handling

function Set-ShrLogContext {
    param([ValidateSet('Initiation', 'Reconciliation')][string] $Trigger,
        [AllowNull()][System.Collections.IDictionary] $Operation)

    if ($Trigger -or -not $script:ShrLogContext) {
        $script:ShrLogContext = @{ Trigger = $Trigger; CycleId = ''; Batch = 0; Metrics = @{} }
    }
    if ($PSBoundParameters.ContainsKey('Operation')) {
        $id = if ($Operation) { [string]$Operation['Id'] } else { '' }
        if ($id -ne $script:ShrLogContext.CycleId) { $script:ShrLogContext.Metrics = @{} }
        $script:ShrLogContext.CycleId = $id
        $script:ShrLogContext.Batch = if ($Operation) { [int]$Operation['BatchNumber'] } else { 0 }
    }
}

function Clear-ShrLogContext {
    $script:ShrLogContext = $null
}

function Write-ShrEvent {
    param(
        [ValidateSet('SHR_TIMER', 'SHR_EVENT')][string] $Category = 'SHR_EVENT',
        [Parameter(Mandatory)][Alias('Event')][string] $EventName,
        [System.Collections.IDictionary] $State,
        [System.Collections.IDictionary] $Metrics
    )

    if ($PSBoundParameters.ContainsKey('State')) { Set-ShrLogContext -Operation $State }
    if (-not $script:ShrLogContext) { Set-ShrLogContext }
    if ($Metrics) {
        $script:ShrLogContext.Metrics = @{}
        foreach ($key in @('TotalSessionHosts', 'InDrain', 'RunningDeployments', 'NewHostsTotal', 'NewHostsAvailable')) {
            if ($Metrics.Contains($key)) { $script:ShrLogContext.Metrics[$key] = [int]$Metrics[$key] }
        }
        if ($Metrics.Contains('NewHostsSafeToProceed')) {
            $script:ShrLogContext.Metrics.NewHostsSafeToProceed = [bool]$Metrics['NewHostsSafeToProceed']
        }
    }
    $counts = $script:ShrLogContext.Metrics
    $phase = $EventName
    if ($EventName -eq 'AuthorizationExpired') {
        $phase = 'AuthorizationExpired'
    } elseif ($State -and $State['Status'] -in @('Completed', 'NeedsAttention', 'Superseded')) {
        $phase = [string]$State['Status']
    } elseif ($State -and $State['ExpansionBlocked']) {
        $phase = 'ExpansionBlockedRecovery'
    } elseif ($State -and $State['AwaitingImageBatch']) {
        $phase = 'WaitingForImageBatchAuthorization'
    } elseif ($EventName -in @('Progress', 'Waiting')) {
        $phase = if ($State['CleanupIntent']) { 'WaitingForCleanup' }
        elseif ($counts['RunningDeployments'] -gt 0) { 'WaitingForDeployment' }
        elseif ($counts.ContainsKey('NewHostsSafeToProceed') -and -not $counts['NewHostsSafeToProceed']) { 'WaitingForHealth' }
        elseif ($State['DeploymentBatchReady'] -and $State['MoreDeploymentsAllowed']) { 'WaitingForScheduledAuthorization' }
        elseif ($counts['InDrain'] -gt 0) { 'Draining' }
        else { 'WaitingForProgress' }
    }
    $deploymentResourceId = ''
    $uri = $null
    if ($State -and $State['DeploymentIntent'] -and
        [uri]::TryCreate([string]$State['DeploymentIntent']['Uri'], [UriKind]::Absolute, [ref]$uri) -and
        $uri.AbsolutePath -match '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Resources/deployments/[^/]+$') {
        $deploymentResourceId = $uri.AbsolutePath
    }
    # Emit only this allowlist; operation state and deployment bodies can contain credentials.
    $data = [ordered]@{
        SchemaVersion = 1
        Event = $EventName
        Trigger = $script:ShrLogContext.Trigger
        CycleId = $script:ShrLogContext.CycleId
        Batch = $script:ShrLogContext.Batch
        FunctionApp = $env:WEBSITE_SITE_NAME
        Phase = $phase
        InitiationEnabled = (Read-FunctionAppSetting InitiationEnabled -AsBoolean)
    }
    $data.Reason = switch ($phase) {
        'WaitingForLease' { 'Another invocation owns this cycle; wait for release or lease expiry.' }
        'WaitingForCleanup' { 'Exact-resource cleanup must finish before names can be reused.' }
        'WaitingForDeployment' { 'An ARM deployment is still running.' }
        'WaitingForHealth' { 'Replacement hosts have not met the configured availability gate.' }
        'WaitingForScheduledAuthorization' { 'Another batch needs initiation authority; authorized retirement can continue.' }
        'ExpansionBlockedRecovery' { 'New expansion is blocked after the no-progress threshold; checkpointed recovery continues.' }
        'WaitingForImageBatchAuthorization' { 'The approved image target requires fresh scheduled initiation authority before its next batch can start.' }
        'Draining' { 'Authorized old hosts are still draining.' }
        'WaitingForProgress' { 'Awaiting capacity, readiness, scaling handoff or retirement checks; inspect cycle logs.' }
        'AuthorizationExpired' { 'Initial authority expired before a batch started; a new initiation tick is required.' }
        'DeploymentFailed' { 'A session-host deployment failed; inspect the failure category, resource and error code.' }
        'NeedsAttention' {
            switch -Regex ([string]$State['LastError']) {
                '^SHR domain-join credential failure' { 'Domain-join credentials need correction and explicit checked recovery; failed resources are retained.'; break }
                '^SHR operation deadline expired' { 'Operation deadline expired; checked recovery is required.'; break }
                '^SHR operation configuration changed' { 'Protected configuration changed; restore it or use checked recovery.'; break }
                '^SHR operation lease is no longer' { 'Invocation lost ownership; inspect cycle and invocation logs.'; break }
                default { 'Operation stopped; inspect the correlated invocation logs before recovery.' }
            }
        }
        default { '' }
    }
    if ($State) {
        $data.Status = [string]$State['Status']
        $data.StartedUtc = $State['CreatedUtc']
        $data.DeadlineUtc = $State['DeadlineUtc']
        $data.LeaseExpiresUtc = $State['LockExpiresUtc']
        $data.LeaseHeld = -not [string]::IsNullOrEmpty([string]$State['LockOwner'])
        $data.ImageVersion = if ($State['Image']) { [string]$State['Image']['Version'] } else { $null }
        $data.ImageDefinition = if ($State['Image']) { [string]$State['Image']['Definition'] } else { $null }
        $data.Target = if ($null -ne $State['TargetCount']) { [int]$State['TargetCount'] } else { $null }
        $data.DeploymentName = if ($State['DeploymentIntent']) { [string]$State['DeploymentIntent']['Name'] } else { $null }
        $data.DeploymentResourceId = $deploymentResourceId
        $data.SupersedesCycleId = [string]$State['SupersedesOperationId']
        $data.ExpansionBlocked = [bool]$State['ExpansionBlocked']
        $data.LastProgressUtc = [string]$State['LastProgressUtc']
        $data.ProgressTimeoutHours = if ($null -ne $State['ProgressTimeoutHours']) { [int]$State['ProgressTimeoutHours'] } else { $null }
        $data.ScheduleWaitStartedUtc = [string]$State['ScheduleWaitStartedUtc']
        $data.AwaitingImageBatch = [bool]$State['AwaitingImageBatch']
        $data.LastImageChangeRequestId = [string]$State['LastImageChangeRequestId']
        $data.LastImageChangeRejectedId = [string]$State['LastImageChangeRejectedId']
        if ($State['DeploymentFailure']) {
            foreach ($field in @('Id', 'Category', 'Code', 'ResourceId', 'DeploymentName', 'DetectedUtc', 'AcknowledgedUtc')) {
                $data["Failure$field"] = [string]$State['DeploymentFailure'][$field]
            }
            $data.FailureRequiresAttention = [bool]$State['DeploymentFailure']['RequiresAttention'] -and
                -not $State['DeploymentFailure']['AcknowledgedUtc']
            if ($State['DeploymentFailure']['InstanceViewDiagnostics']) {
                $data.FailureInstanceViewOutcome = [string]$State['DeploymentFailure']['InstanceViewDiagnostics']['Outcome']
            }
        }
        $data.InDrain = $counts['InDrain']
        $data.RunningDeployments = $counts['RunningDeployments']
    }
    $level = if ($EventName -in @('Checkpoint', 'Reconciling', 'Progress', 'DeploymentObserved')) { 'Trace' } else { 'Information' }
    Write-LogEntry -Message "$Category | $($data | ConvertTo-Json -Depth 4 -Compress)" -Level $level
}

function Write-LogEntry {
    <#
    .SYNOPSIS
        Enhanced logging function with level support.
    .DESCRIPTION
        Writes detailed log messages function app levels.
    .PARAMETER Message
        The message to log.
    .PARAMETER Level
        The function app monitoring level (Trace, Debug, Information, Warning, Error, Critical).
    .PARAMETER StringValues
        Array of values to format into the message using -f operator.
    .EXAMPLE
        Write-LogEntry -Message "Processing {0} items" -StringValues 10 -Level Host
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),

        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
        [string] $Level = 'Information',
        
        [Parameter(Mandatory = $false)]
        [object[]] $StringValues
    )
    
    # Format message with string values if provided
    if ($StringValues -and $StringValues.Count -gt 0) {
        try {
            $formattedMessage = $Message -f $StringValues
        }
        catch {
            $formattedMessage = $Message
            Write-Warning "Failed to format message with provided string values"
        }
    }
    else {
        $formattedMessage = $Message
    }
    
    # Native app/invocation identity links these messages to the structured cycle records.
    $output = if ($hostPoolName) { "[$hostPoolName] $formattedMessage".Trim() } else { $formattedMessage.Trim() }
    
    # Output based on level
    switch ($Level) {
        'Trace' {
            Write-Verbose $output
        }
        'Debug' {
            Write-Debug $output
        }
        'Error' {
            Write-Error $output -ErrorAction Continue
        }
        'Warning' {
            Write-Warning $output
        }
        'Information' {
            # Use Write-Host for Information level to ensure proper display in Azure Functions
            Write-Host $output
        }
    }
}

#EndRegion Logging and Error Handling

#Region REST API Helper Functions

function Get-ShrExceptionChain {
    param($Failure)

    if ($Failure -is [System.Management.Automation.ErrorRecord]) { $Failure = $Failure.Exception }
    if ($Failure -isnot [Exception]) { return }
    $pending = [System.Collections.Generic.Queue[Exception]]::new()
    $seen = [System.Collections.Generic.HashSet[Exception]]::new()
    $pending.Enqueue($Failure)
    while ($pending.Count -gt 0 -and $seen.Count -lt 32) {
        $exception = $pending.Dequeue()
        if (-not $seen.Add($exception)) { continue }
        $exception
        if ($exception -is [AggregateException]) {
            foreach ($inner in $exception.InnerExceptions) { $pending.Enqueue($inner) }
        } elseif ($exception.InnerException) {
            $pending.Enqueue($exception.InnerException)
        }
    }
}

function Get-ShrHttpStatusCode {
    <#
    .SYNOPSIS
        Extracts typed HTTP status evidence without parsing exception messages.
    .OUTPUTS
        An integer status code, or no output when no HTTP status is available.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [Alias('InputObject', 'Exception', 'Failure')]
        $ErrorRecord
    )

    process {
        foreach ($exception in (Get-ShrExceptionChain $ErrorRecord)) {
            foreach ($candidate in @($exception.Response.StatusCode, $exception.StatusCode, $exception.Data['StatusCode'])) {
                $status = 0
                if ($null -ne $candidate -and [int]::TryParse([string]$candidate, [ref]$status) -and
                    $status -ge 100 -and $status -le 599) {
                    return $status
                }
                if ($candidate -is [System.Net.HttpStatusCode]) { return [int]$candidate }
            }
        }
    }
}

function Test-ShrTransientFailure {
    <#
    .SYNOPSIS
        Identifies retryable HTTP or typed transport failures; messages are never evidence.
    .DESCRIPTION
        HTTP evidence, including storage exception Data['StatusCode'], takes precedence
        over transport wrappers. Marked ownership conflicts are never transient. This
        classifies a failure, not permission to replay a mutation; mutations must be
        reconciled by their caller.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [Alias('InputObject', 'Exception', 'Failure')]
        $ErrorRecord
    )

    process {
        $exceptions = @(Get-ShrExceptionChain $ErrorRecord)
        if (@($exceptions | Where-Object { $_.Data['ShrOwnershipConflict'] -eq $true }).Count -gt 0) {
            return $false
        }
        $statuses = @($exceptions | ForEach-Object { Get-ShrHttpStatusCode $_ })
        if ($statuses.Count -gt 0) {
            return @($statuses | Where-Object { $_ -notin @(408, 429, 500, 502, 503, 504) }).Count -eq 0
        }
        foreach ($exception in $exceptions) {
            if ($exception -is [System.Net.Http.HttpRequestException] -or
                $exception -is [System.Threading.Tasks.TaskCanceledException] -or
                $exception -is [TimeoutException]) { return $true }
            if ($exception -is [System.Net.WebException] -and $exception.Status -in @(
                [System.Net.WebExceptionStatus]::Timeout,
                [System.Net.WebExceptionStatus]::ConnectFailure,
                [System.Net.WebExceptionStatus]::ConnectionClosed,
                [System.Net.WebExceptionStatus]::KeepAliveFailure,
                [System.Net.WebExceptionStatus]::NameResolutionFailure,
                [System.Net.WebExceptionStatus]::ProxyNameResolutionFailure,
                [System.Net.WebExceptionStatus]::PipelineFailure,
                [System.Net.WebExceptionStatus]::ReceiveFailure,
                [System.Net.WebExceptionStatus]::SendFailure
            )) { return $true }
        }
        return $false
    }
}

function Get-ShrRetryAfterSeconds {
    param($Failure)

    foreach ($exception in (Get-ShrExceptionChain $Failure)) {
        $headers = $exception.Response.Headers
        if (-not $headers) { continue }
        if ($headers -is [System.Net.Http.Headers.HttpResponseHeaders]) {
            $retryAfter = $headers.RetryAfter
            if ($null -ne $retryAfter.Delta) { return [Math]::Max(0, $retryAfter.Delta.TotalSeconds) }
            if ($null -ne $retryAfter.Date) {
                return [Math]::Max(0, ($retryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds)
            }
        } else {
            $value = @($headers['Retry-After'])[0]
            $seconds = 0
            if ([int]::TryParse([string]$value, [ref]$seconds) -and $seconds -ge 0) { return $seconds }
            $date = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse([string]$value, [ref]$date)) {
                return [Math]::Max(0, ($date - [DateTimeOffset]::UtcNow).TotalSeconds)
            }
        }
    }
}

function Invoke-ShrRestRequest {
    <#
    .SYNOPSIS
        Sends one request, with at most three GET attempts in a 15-second local budget.
    .DESCRIPTION
        All normal ARM and Graph helpers use this path, including individual collection
        pages. Never replays mutations. Retry-After beyond the five-second delay cap or
        remaining budget causes immediate deferral, rather than retrying before the server
        permits it. Worker deadline/ownership checks run outside the transport catch.
    #>
    param(
        [Parameter(Mandatory)][hashtable] $Parameters,
        [int] $MaxAttempts = 3,
        [int] $RetryDelaySeconds = 1
    )

    $isGet = $Parameters.Method -eq 'Get'
    $limit = if ($isGet) { [Math]::Clamp($MaxAttempts, 1, 3) } else { 1 }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $request = $Parameters.Clone()
    $request.ErrorAction = 'Stop'
    $hasOperationTimeout = (Get-Command Invoke-RestMethod).Parameters.ContainsKey('OperationTimeoutSeconds')
    $lastFailure = $null
    for ($attempt = 1; $attempt -le $limit; $attempt++) {
        if ($attempt -gt 1 -and (Get-Command Assert-ShrWorkerLease -ErrorAction SilentlyContinue)) {
            Assert-ShrWorkerLease
        }
        if ($attempt -gt 1 -and $clock.Elapsed.TotalSeconds + 1 -ge 15) {
            Write-LogEntry -Message "GET transient retries exhausted: local retry budget expired; preserving the original request failure." -Level Error
            throw $lastFailure
        }
        if ($isGet) {
            $request.TimeoutSec = [Math]::Max(1, [Math]::Min(10, [Math]::Floor(15 - $clock.Elapsed.TotalSeconds)))
            if ($hasOperationTimeout) { $request.OperationTimeoutSeconds = $request.TimeoutSec }
        }
        try {
            return Invoke-RestMethod @request
        } catch {
            if (-not $isGet -or -not (Test-ShrTransientFailure $_)) { throw }
            $lastFailure = $_
            $delay = [Math]::Min(5, [Math]::Max(0, $RetryDelaySeconds) * [Math]::Pow(2, $attempt - 1))
            $retryAfter = Get-ShrRetryAfterSeconds $_
            if ($null -ne $retryAfter) { $delay = [Math]::Max($delay, $retryAfter) }
            if ($attempt -ge $limit -or $delay -gt 5 -or
                $clock.Elapsed.TotalSeconds + $delay + 1 -ge 15) {
                Write-LogEntry -Message "GET transient retries exhausted or retry budget unavailable after $attempt attempt(s); preserving the original request failure." -Level Error
                throw
            }
            if (Get-Command Assert-ShrWorkerLease -ErrorAction SilentlyContinue) { Assert-ShrWorkerLease }
            Write-LogEntry -Message "Transient GET failure; retrying in $delay second(s), attempt $($attempt + 1) of $limit." -Level Warning
            Start-Sleep -Seconds $delay
        }
    }
}

function Invoke-AzureRestMethod {
    <#
        .SYNOPSIS
            Run an Azure REST call with paging support.           
        .PARAMETER ARMToken
            An access token for Azure Resource Manager.
        .PARAMETER Method
            The HTTP method for the REST call, like GET, POST, PUT, PATCH, DELETE. Default is GET.
        .PARAMETER Uri
            The Azure Resource Manager URI for the query.
        .PARAMETER Body
            The request body of the REST call. This is often used with methods like POST, PUT and PATCH.
        .PARAMETER AdditionalHeaders
            Optional additional headers to include in the request.
        .PARAMETER RequireCollection
            Reject missing or malformed collection envelopes, including subsequent pages.
        .PARAMETER MaxRetries
            Maximum total attempts per GET page (default: 3, capped at 3); mutations are sent once.
        .PARAMETER RetryDelaySeconds
            Initial GET retry delay (default: 1 second); delays are capped at 5 seconds and
            each page has a 15-second local retry budget. Longer Retry-After values defer.
        .EXAMPLE
            Invoke-AzureRestMethod -ARMToken $ARMToken -Method 'GET' -Uri 'https://management.azure.com/...'
    #>

    param (
        [parameter(Mandatory = $true)]
        [string]$ARMToken,

        [parameter(Mandatory = $false)]
        [string]$Method = 'GET',

        [switch]$RequireCollection,

        [parameter(Mandatory = $true)]
        [string]$Uri,

        [parameter(Mandatory = $false)]
        [string]$Body = '',

        [parameter(Mandatory = $false)]
        [hashtable]$AdditionalHeaders,

        [int]$MaxRetries = 3,

        [int]$RetryDelaySeconds = 1
    )

    if ($Method -ne 'GET' -and (Get-Command Assert-ShrWorkerLease -ErrorAction SilentlyContinue)) {
        Assert-ShrWorkerLease
    }

    # Check if authentication was successful.
    if ($ARMToken) {
        # Format headers.
        $HeaderParams = @{
            'Content-Type'  = "application/json"
            'Authorization' = "Bearer $ARMToken"
        }
        If ($AdditionalHeaders) {
            $HeaderParams += $AdditionalHeaders
        }

        # Create an empty array to store the result.
        $QueryRequest = @()
        $dataToUpload = @()
        $validateCollection = {
            param($Response)
            if ($RequireCollection -and ($null -eq $Response -or
                $Response.value -isnot [System.Collections.IList])) {
                throw "Invalid collection response from '$Uri'; resource absence cannot be established."
            }
        }

        # Run the first query.
        if ($Method -eq 'GET') {
            $QueryRequest = Invoke-ShrRestRequest -Parameters @{ Headers = $HeaderParams; Uri = $Uri; Method = $Method; Verbose = $false } -MaxAttempts $MaxRetries -RetryDelaySeconds $RetryDelaySeconds
        }
        else {
            $QueryRequest = Invoke-ShrRestRequest -Parameters @{ Headers = $HeaderParams; Uri = $Uri; Method = $Method; Body = $Body; Verbose = $false } -MaxAttempts $MaxRetries -RetryDelaySeconds $RetryDelaySeconds
        }
        
        & $validateCollection $QueryRequest
        # Check if response is a direct array or has a value property
        if ($QueryRequest -is [array]) {
            # Direct array response (e.g., marketplace images API)
            $dataToUpload += $QueryRequest
        }
        elseif ($null -ne $QueryRequest -and $QueryRequest.PSObject.Properties.Name -contains 'value') {
            # Paged response with value property
            $dataToUpload += $QueryRequest.value
        }
        else {
            # Single object response
            $dataToUpload += $QueryRequest
        }

        # Invoke REST methods and fetch data until there are no pages left.
        if ($Uri -notlike "*`$top*") {
            while ($QueryRequest.'@odata.nextLink' -and $QueryRequest.'@odata.nextLink' -is [string]) {
                $QueryRequest = Invoke-ShrRestRequest -Parameters @{ Headers = $HeaderParams; Uri = $QueryRequest.'@odata.nextLink'; Method = $Method; Verbose = $false } -MaxAttempts $MaxRetries -RetryDelaySeconds $RetryDelaySeconds
                & $validateCollection $QueryRequest
                $dataToUpload += $QueryRequest.value
            }
            While ($QueryRequest.nextLink -and $QueryRequest.nextLink -is [string]) {
                $QueryRequest = Invoke-ShrRestRequest -Parameters @{ Headers = $HeaderParams; Uri = $QueryRequest.nextLink; Method = $Method; Verbose = $false } -MaxAttempts $MaxRetries -RetryDelaySeconds $RetryDelaySeconds
                & $validateCollection $QueryRequest
                $dataToUpload += $QueryRequest.value
            }
            While ($QueryRequest.'$skipToken' -and $QueryRequest.'$skipToken' -is [string] -and $Body -ne '') {
                $JsonBody = $Body | ConvertFrom-Json
                $JsonBody | Add-Member -Type NoteProperty -Name '$skipToken' -Value $QueryRequest.'$skipToken' -Force
                $Body = $JsonBody | ConvertTo-Json -Depth 10
                $QueryRequest = Invoke-ShrRestRequest -Parameters @{ Headers = $HeaderParams; Uri = $Uri; Method = $Method; Body = $Body; Verbose = $false } -MaxAttempts $MaxRetries -RetryDelaySeconds $RetryDelaySeconds
                & $validateCollection $QueryRequest
                $dataToUpload += $QueryRequest.value
            }
        }
        $dataToUpload
    }
    else {
        Write-Error "No Access Token"
    }
}

function Invoke-AzureRestMethodWithRetry {
    <#
    .SYNOPSIS
        Invokes Azure REST API with automatic retry logic for transient failures.
    .DESCRIPTION
        Uses the same bounded GET-only retry path as Invoke-AzureRestMethod. Mutations
        are sent once; their caller must reconcile ambiguous outcomes.
    .PARAMETER ARMToken
        Azure access token for authentication.
    .PARAMETER Method
        HTTP method (GET, POST, PUT, PATCH, DELETE).
    .PARAMETER Uri
        The REST API endpoint URI.
    .PARAMETER Body
        Optional request body.
    .PARAMETER MaxRetries
        Maximum total GET attempts (default: 3, capped at 3).
    .PARAMETER RetryDelaySeconds
        Initial retry delay in seconds (default: 1, capped at 5).
    .EXAMPLE
        Invoke-AzureRestMethodWithRetry -ARMToken $token -Method Get -Uri $uri -MaxRetries 5
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Put', 'Patch', 'Delete')]
        [string] $Method,
        
        [Parameter(Mandatory = $true)]
        [string] $Uri,
        
        [Parameter()]
        [string] $Body,
        
        [Parameter()]
        [int] $MaxRetries = 3,
        
        [Parameter()]
        [int] $RetryDelaySeconds = 1
    )
    
    Invoke-AzureRestMethod -ARMToken $ARMToken -Method $Method -Uri $Uri -Body $Body `
        -MaxRetries $MaxRetries -RetryDelaySeconds $RetryDelaySeconds
}

function Invoke-GraphRestMethod {
    <#
    .SYNOPSIS
        Invokes Microsoft Graph API with retry support for DoD endpoint.
    .DESCRIPTION
        Attempts to call the Graph API with the provided endpoint. If the call fails with
        authentication/forbidden errors, automatically retries with the DoD Graph endpoint.
    .PARAMETER GraphToken
        Bearer token for authentication.
    .PARAMETER Method
        HTTP method (GET, POST, PATCH, DELETE, PUT).
    .PARAMETER Uri
        The full Graph API URI (e.g., https://graph.microsoft.us/v1.0/devices).
    .PARAMETER Body
        Optional request body for POST/PATCH operations.
    .EXAMPLE
        Invoke-GraphRestMethod -GraphToken $token -Method Get -Uri "https://graph.microsoft.us/v1.0/devices"
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $GraphToken,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Patch', 'Delete', 'Put')]
        [string] $Method,
        
        [Parameter(Mandatory = $true)]
        [string] $Uri,
        
        [Parameter()]
        [string] $Body
    )
    
    if ($Method -ne 'Get' -and (Get-Command Assert-ShrWorkerLease -ErrorAction SilentlyContinue)) {
        Assert-ShrWorkerLease
    }

    $headers = @{
        'Authorization' = "Bearer $GraphToken"
        'Content-Type'  = 'application/json'
    }
    
    $params = @{
        Uri     = $Uri
        Method  = $Method
        Headers = $headers
    }
    
    if ($Body) {
        $params['Body'] = $Body
    }
    
    try {
        $result = Invoke-ShrRestRequest -Parameters $params
        return $result
    }
    catch {
        $statusCode = Get-ShrHttpStatusCode $_
        
        # If using GCCH endpoint and got auth error, try DoD endpoint
        if ($Uri -like "*graph.microsoft.us*" -and $statusCode -in @(401, 403)) {
            Write-LogEntry -Message "Graph API call to GCCH failed with status $statusCode. Trying DoD endpoint..." -Level Warning
            
            # Replace GCCH endpoint with DoD
            $dodUri = $Uri -replace 'graph\.microsoft\.us', 'dod-graph.microsoft.us'
            
            try {
                # Acquire new token for DoD endpoint
                $dodToken = Get-AccessToken -ResourceUri 'https://dod-graph.microsoft.us'
                $headers['Authorization'] = "Bearer $dodToken"
                $params['Uri'] = $dodUri
                $params['Headers'] = $headers
                
                if ($Method -ne 'Get' -and (Get-Command Assert-ShrWorkerLease -ErrorAction SilentlyContinue)) {
                    Assert-ShrWorkerLease
                }
                $result = Invoke-ShrRestRequest -Parameters $params
                return $result
            }
            catch {
                Write-LogEntry -Message "Graph API call to DoD endpoint also failed: $_" -Level Warning
                throw
            }
        }
        else {
            Write-LogEntry -Message "Graph API call failed: $_" -Level Warning
            throw
        }
    }
}

function Invoke-GraphApiWithRetry {
    <#
    .SYNOPSIS
        Invokes Microsoft Graph API with automatic retry for DoD endpoint if GCCH fails.
    .DESCRIPTION
        Attempts to call the Graph API with the provided endpoint. If the call fails with
        authentication/forbidden errors, automatically retries with the DoD Graph endpoint
        and acquires a fresh token for that endpoint.
    .PARAMETER GraphEndpoint
        The initial Graph endpoint to try (e.g., https://graph.microsoft.us).
    .PARAMETER GraphToken
        Bearer token for authentication (for the GraphEndpoint).
    .PARAMETER Method
        HTTP method (GET, POST, PATCH, DELETE, PUT).
    .PARAMETER Uri
        The relative URI path (e.g., /v1.0/devices). Will be appended to GraphEndpoint.
    .PARAMETER Body
        Optional request body for POST/PATCH operations.
    .PARAMETER Headers
        Optional custom headers. Authorization header will be added automatically.
    .PARAMETER ClientId
        Optional client ID for user-assigned managed identity (needed to acquire new token for DoD endpoint).
    .PARAMETER SuppressNotFoundError
        Preserves a DELETE 404 exception without error logging so the device-cleanup caller can report an already-absent device.
    .EXAMPLE
        Invoke-GraphApiWithRetry -GraphEndpoint $env:GraphEndpoint -GraphToken $token -Method Get -Uri "/v1.0/devices?`$filter=displayName eq 'VM01'" -ClientId $clientId
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $GraphEndpoint,
        
        [Parameter(Mandatory = $true)]
        [string] $GraphToken,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Patch', 'Delete', 'Put')]
        [string] $Method,
        
        [Parameter(Mandatory = $true)]
        [string] $Uri,
        
        [Parameter()]
        [string] $Body,
        
        [Parameter()]
        [hashtable] $Headers = @{},
        
        [Parameter()]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId),

        [Parameter()]
        [switch] $SuppressNotFoundError
    )
    
    # Ensure GraphEndpoint doesn't have trailing slash
    $graphBase = if ($GraphEndpoint[-1] -eq '/') { 
        $GraphEndpoint.Substring(0, $GraphEndpoint.Length - 1) 
    }
    else { 
        $GraphEndpoint 
    }
    
    # Ensure Uri has leading slash
    $uriPath = if ($Uri[0] -ne '/') { "/$Uri" } else { $Uri }  
    
    # List of endpoints to try
    $endpointsToTry = @(
        @{ Endpoint = $graphBase; Token = $GraphToken }
    )
    
    # If we're using GCCH endpoint, also try DoD with a fresh token
    if ($graphBase -eq 'https://graph.microsoft.us') {
        $endpointsToTry += @{ 
            Endpoint = 'https://dod-graph.microsoft.us'
            Token    = $null  # Will acquire fresh token if needed
        }
    }
    
    $lastError = $null
    foreach ($endpointConfig in $endpointsToTry) {
        $endpoint = $endpointConfig.Endpoint
        $token = $endpointConfig.Token
        
        # If no token provided for this endpoint, acquire one
        if (-not $token) {
            try {
                $token = Get-AccessToken -ResourceUri $endpoint -ClientId $ClientId
            }
            catch {
                Write-LogEntry -Message "Failed to acquire token for $endpoint : $_" -Level Warning
                continue
            }
        }
        
        if ($Method -ne 'Get' -and (Get-Command Assert-ShrWorkerLease -ErrorAction SilentlyContinue)) {
            Assert-ShrWorkerLease
        }

        try {
            $currentUri = "$endpoint$uriPath"
            
            # Setup headers with correct token for this endpoint
            $requestHeaders = $Headers.Clone()
            $requestHeaders['Authorization'] = "Bearer $token"
            if (-not $requestHeaders.ContainsKey('Content-Type')) {
                $requestHeaders['Content-Type'] = 'application/json'
            }
            
            $params = @{
                Uri     = $currentUri
                Method  = $Method
                Headers = $requestHeaders
            }
            
            if ($Body) {
                $params['Body'] = $Body
            }
            
            $result = Invoke-ShrRestRequest -Parameters $params
            return $result
        }
        catch {
            $lastError = $_
            $statusCode = Get-ShrHttpStatusCode $_

            if ($SuppressNotFoundError -and $Method -eq 'Delete' -and $statusCode -eq 404) {
                throw
            }
            
            if ($_.Exception.Response) {
                # Try to get detailed error message from response body
                try {
                    if ($_.Exception.Response -is [System.Net.Http.HttpResponseMessage]) {
                        $errorBody = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    } else {
                        $errorStream = $_.Exception.Response.GetResponseStream()
                        $reader = New-Object System.IO.StreamReader($errorStream)
                        try { $errorBody = $reader.ReadToEnd() }
                        finally { $reader.Dispose() }
                    }
                    
                    if ($errorBody) {
                        Write-LogEntry -Message "Graph API error response: $errorBody" -Level Error
                    }
                }
                catch {
                    Write-LogEntry -Message 'Graph error-response details could not be read or emitted; the original request failure will still be handled.' -Level Trace
                }
            }
            
            # Retry on authentication/authorization errors (401, 403) against the next Graph endpoint
            if ($statusCode -in @(401, 403) -and $endpoint -ne $endpointsToTry[-1].Endpoint) {
                Write-LogEntry -Message "Graph API call to $endpoint failed with status $statusCode. Trying next endpoint..." -Level Warning
                continue
            }
            else {
                Write-LogEntry -Message "Graph API call failed: $($_.Exception.Message)" -Level Error
                throw
            }
        }
    }
    
    # If we get here, all endpoints failed
    Write-LogEntry -Message "All Graph API endpoints failed. Last error: $($lastError.Exception.Message)" -Level Error
    throw $lastError
}

#EndRegion REST API Helper Functions

#Region VM Helper Functions

function Get-VMPowerStates {
    <#
    .SYNOPSIS
        Queries power state for specific VMs by resource ID.
    .DESCRIPTION
        Retrieves instanceView with power state for a list of VM resource IDs.
        Used for lazy loading to avoid querying all VMs when only deletion candidates need power state.
    .PARAMETER ARMToken
        Azure Resource Manager access token.
    .PARAMETER VMResourceIds
        Array of VM resource IDs to query.
    .PARAMETER ResourceManagerUri
        The Azure Resource Manager endpoint URI.
    .EXAMPLE
        $powerStates = Get-VMPowerStates -ARMToken $token -VMResourceIds @('/subscriptions/.../vm1', '/subscriptions/.../vm2')
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array] $VMResourceIds,
        
        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri)
    )
    
    if ($VMResourceIds.Count -eq 0) {
        return @{}
    }
    
    Write-LogEntry -Message "Querying power state for $($VMResourceIds.Count) VMs" -Level Trace
    
    $powerStates = @{}
    
    foreach ($resourceId in $VMResourceIds) {
        try {
            $Uri = "$ResourceManagerUri$resourceId/instanceView?api-version=2024-07-01"
            $instanceView = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
            
            # Extract power state from statuses
            $powerStateCode = ($instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' }).code
            $isPoweredOff = $powerStateCode -like 'PowerState/deallocated' -or $powerStateCode -like 'PowerState/stopped'
            
            $powerStates[$resourceId] = $isPoweredOff
            Write-LogEntry -Message "VM $resourceId power state: $powerStateCode (PoweredOff=$isPoweredOff)" -Level Trace
        }
        catch {
            Write-LogEntry -Message "Failed to get power state for VM $resourceId : $_" -Level Warning
            $powerStates[$resourceId] = $false  # Assume powered on if query fails
        }
    }
    
    return $powerStates
}

#EndRegion VM Helper Functions

# Export functions
Export-ModuleMember -Function ConvertTo-CaseInsensitiveHashtable, Get-ResourceManagerUri, Get-GraphEndpoint, Get-AccessToken, Read-FunctionAppSetting, Assert-DeviceCleanupConfiguration, Write-LogEntry, Set-ShrLogContext, Clear-ShrLogContext, Write-ShrEvent, Test-ShrTransientFailure, Get-ShrHttpStatusCode, Invoke-AzureRestMethod, Invoke-AzureRestMethodWithRetry, Invoke-GraphRestMethod, Invoke-GraphApiWithRetry, Get-VMPowerStates
