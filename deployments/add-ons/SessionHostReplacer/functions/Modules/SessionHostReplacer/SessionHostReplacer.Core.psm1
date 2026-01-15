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

# Host Pool Name for log message prefixing
$script:HostPoolNameForLogging = $null

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
    if ($isARMToken) {
        # ARM: requires trailing slash
        $tokenResourceUri = if ($ResourceUri[-1] -ne '/') { "$ResourceUri/" } else { $ResourceUri }
        Write-Verbose "Requesting ARM token for resource: $tokenResourceUri (with trailing slash)"
    }
    else {        
        # Graph and Storage: NO trailing slash
        $tokenResourceUri = if ($ResourceUri[-1] -eq '/') { $ResourceUri.TrimEnd('/') } else { $ResourceUri }
        $tokenType = if ($isGraphToken) { "Graph" } elseif ($isStorageToken) { "Storage" } else { "Other" }
        Write-Verbose "Requesting $tokenType token for resource: $tokenResourceUri (no trailing slash)"
    }
    
    # Acquire token from managed identity
    # Build token URI - only include clientid parameter for user-assigned identity
    if ([string]::IsNullOrEmpty($ClientId)) {
        # System-assigned managed identity
        Write-Verbose "Acquiring token using system-assigned managed identity for resource: $tokenResourceUri"
        $TokenAuthURI = $env:MSI_ENDPOINT + '?resource=' + $tokenResourceUri + '&api-version=2017-09-01'
    }
    else {
        # User-assigned managed identity
        Write-Verbose "Acquiring token using user-assigned managed identity (ClientId: $ClientId) for resource: $tokenResourceUri"
        $TokenAuthURI = $env:MSI_ENDPOINT + '?resource=' + $tokenResourceUri + "&clientid=$ClientId" + '&api-version=2019-08-01'
    }
       
    $headers = @{
        Secret = $env:MSI_SECRET
    }
    
    $TokenResponse = Invoke-RestMethod -Method Get -Headers $headers -Uri $TokenAuthURI 4>$Null
    
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
    .EXAMPLE
        $hostPoolName = Read-FunctionAppSetting HostPoolName
    .EXAMPLE
        $value = Read-FunctionAppSetting 'SomeSetting' -NoCache
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $SettingKey,
        
        [Parameter(Mandatory = $false)]
        [switch] $NoCache
    )
    
    # Check cache first unless NoCache is specified
    if (-not $NoCache -and $Script:SettingCache.ContainsKey($SettingKey)) {
        Write-Verbose "Using cached value for $SettingKey"
        return $Script:SettingCache[$SettingKey]
    }
    
    # Get the value from environment variable
    $value = [System.Environment]::GetEnvironmentVariable($SettingKey)
    
    # Return null if value is null or empty
    if ([string]::IsNullOrWhiteSpace($value)) {
        $Script:SettingCache[$SettingKey] = $null
        return $null
    }
    
    # Convert JSON strings to hashtables for complex configurations
    if ($value.StartsWith('{')) {
        try {
            $parsed = $value | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $Script:SettingCache[$SettingKey] = $parsed
            return $parsed
        }
        catch {
            Write-Warning "Failed to parse JSON for $SettingKey : $_"
            $Script:SettingCache[$SettingKey] = $value
            return $value
        }
    }
    
    # Convert boolean strings to actual boolean values
    if ($value -eq 'true' -or $value -eq 'True') {
        $Script:SettingCache[$SettingKey] = $true
        return $true
    }
    elseif ($value -eq 'false' -or $value -eq 'False') {
        $Script:SettingCache[$SettingKey] = $false
        return $false
    }
    
    # Convert numeric strings to integers where appropriate
    if ($value -match '^\d+$') {
        $intValue = [int]$value
        $Script:SettingCache[$SettingKey] = $intValue
        return $intValue
    }
    
    # Cache and return the string value
    $Script:SettingCache[$SettingKey] = $value
    return $value
}

#EndRegion Configuration Functions

#Region Logging and Error Handling

function Set-HostPoolNameForLogging {
    <#
    .SYNOPSIS
        Sets the host pool name to be used as a prefix in all log messages.
    .DESCRIPTION
        This function sets the module-level variable used by Write-LogEntry to prefix all log messages.
    .PARAMETER HostPoolName
        The name of the host pool to use as a prefix.
    .EXAMPLE
        Set-HostPoolNameForLogging -HostPoolName "vdpool-test-01-use2"
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $HostPoolName
    )
    
    $script:HostPoolNameForLogging = $HostPoolName
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
    
    # Add host pool prefix if available
    $prefix = if ($script:HostPoolNameForLogging) { "[$($script:HostPoolNameForLogging)]" } else { "" }
    
    # Build output message (Azure Functions already adds timestamp and level)
    $output = "$prefix $formattedMessage".Trim()
    
    # Output based on level
    switch ($Level) {
        'Trace' {
            Write-Verbose $output
        }
        'Debug' {
            Write-Debug $output
        }
        'Error' {
            Write-Error $output
        }
        'Warning' {
            Write-Warning $output
        }
        'Information' {
            Write-Information $output
        }
    }
}

#EndRegion Logging and Error Handling

#Region REST API Helper Functions

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
        .EXAMPLE
            Invoke-AzureRestMethod -ARMToken $ARMToken -Method 'GET' -Uri 'https://management.azure.com/...'
    #>

    param (
        [parameter(Mandatory = $true)]
        [string]$ARMToken,

        [parameter(Mandatory = $false)]
        [string]$Method = 'GET',

        [parameter(Mandatory = $true)]
        [string]$Uri,

        [parameter(Mandatory = $false)]
        [string]$Body = '',

        [parameter(Mandatory = $false)]
        [hashtable]$AdditionalHeaders
    )

    # Check if authentication was successful.
    if ($ARMToken) {
        # Format headers.
        $HeaderParams = @{
            'Content-Type'  = "application\json"
            'Authorization' = "Bearer $ARMToken"
        }
        If ($AdditionalHeaders) {
            $HeaderParams += $AdditionalHeaders
        }

        # Create an empty array to store the result.
        $QueryRequest = @()
        $dataToUpload = @()

        # Run the first query.
        if ($Method -eq 'GET') {
            $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $Uri -UseBasicParsing -Method $Method -ContentType "application/json" 4>$Null
        }
        else {
            $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $Uri -UseBasicParsing -Method $Method -ContentType "application/json" -Body $Body 4>$Null
        }
        
        # Check if response is a direct array or has a value property
        if ($QueryRequest -is [array]) {
            # Direct array response (e.g., marketplace images API)
            $dataToUpload += $QueryRequest
        }
        elseif ($QueryRequest.value) {
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
                $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $QueryRequest.'@odata.nextLink' -UseBasicParsing -Method $Method -ContentType "application/json" 4>$Null
                $dataToUpload += $QueryRequest.value
            }
            While ($QueryRequest.nextLink -and $QueryRequest.nextLink -is [string]) {
                $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $QueryRequest.nextLink -UseBasicParsing -Method $Method -ContentType "application/json" 4>$Null
                $dataToUpload += $QueryRequest.value
            }
            While ($QueryRequest.'$skipToken' -and $QueryRequest.'$skipToken' -is [string] -and $Body -ne '') {
                $JsonBody = $Body | ConvertFrom-Json
                $JsonBody | Add-Member -Type NoteProperty -Name '$skipToken' -Value $QueryRequest.'$skipToken' -Force
                $Body = $JsonBody | ConvertTo-Json -Depth 10
                $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $Uri -UseBasicParsing -Method $Method -Body $Body -ContentType "application/json" 4>$Null
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
        Wraps Invoke-AzureRestMethod with exponential backoff retry for 429 and 5xx errors.
    .PARAMETER ARMToken
        Azure access token for authentication.
    .PARAMETER Method
        HTTP method (GET, POST, PUT, PATCH, DELETE).
    .PARAMETER Uri
        The REST API endpoint URI.
    .PARAMETER Body
        Optional request body.
    .PARAMETER MaxRetries
        Maximum number of retry attempts (default: 3).
    .PARAMETER RetryDelaySeconds
        Initial retry delay in seconds (default: 5).
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
        [int] $RetryDelaySeconds = 5
    )
    
    $attempt = 0
    $success = $false
    $result = $null
    
    while (-not $success -and $attempt -lt $MaxRetries) {
        $attempt++
        try {
            $result = Invoke-AzureRestMethod -ARMToken $ARMToken -Method $Method -Uri $Uri -Body $Body
            $success = $true
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            $retryable = $statusCode -in @(429, 500, 502, 503, 504)
            
            if ($retryable -and $attempt -lt $MaxRetries) {
                $delay = $RetryDelaySeconds * [Math]::Pow(2, $attempt - 1)
                Write-LogEntry -Message "Request failed with status $statusCode. Retrying in $delay seconds (attempt $attempt of $MaxRetries)" -Level Warning
                Start-Sleep -Seconds $delay
            }
            else {
                Write-LogEntry -Message "Request failed: $_" -Level Error
                throw $_
            }
        }
    }
    
    return $result
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
        $result = Invoke-RestMethod @params -ErrorAction Stop
        return $result
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        
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
                
                $result = Invoke-RestMethod @params -ErrorAction Stop
                return $result
            }
            catch {
                Write-LogEntry -Message "Graph API call to DoD endpoint also failed: $_" -Level Error
                throw $_
            }
        }
        else {
            Write-LogEntry -Message "Graph API call failed: $_" -Level Error
            throw $_
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
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
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
            
            $result = Invoke-RestMethod @params -ErrorAction Stop
            return $result
        }
        catch {
            $lastError = $_
            
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode.value__
                
                # Try to get detailed error message from response body
                try {
                    $errorStream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($errorStream)
                    $errorBody = $reader.ReadToEnd()
                    $reader.Close()
                    
                    if ($errorBody) {
                        Write-LogEntry -Message "Graph API error response: $errorBody" -Level Error
                    }
                }
                catch {
                    # Ignore errors reading error stream
                }
            }
            
            # Retry on authentication/authorization errors (401, 403) or if endpoint not found (404 on base endpoint)
            if ($statusCode -in @(401, 403, 404) -and $endpoint -ne $endpointsToTry[-1].Endpoint) {
                Write-LogEntry -Message "Graph API call to $endpoint failed with status $statusCode. Trying next endpoint..." -Level Warning
                continue
            }
            else {
                Write-LogEntry -Message "Graph API call failed: $($_.Exception.Message)" -Level Error
                throw $_
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
Export-ModuleMember -Function ConvertTo-CaseInsensitiveHashtable, Get-ResourceManagerUri, Get-GraphEndpoint, Get-AccessToken, Read-FunctionAppSetting, Set-HostPoolNameForLogging, Write-LogEntry, Invoke-AzureRestMethod, Invoke-AzureRestMethodWithRetry, Invoke-GraphRestMethod, Invoke-GraphApiWithRetry, Get-VMPowerStates
