# SessionHostReplacer PowerShell Module
# This module contains all helper functions for AVD Session Host Replacer

#Region Token Cache Variables

# Global token cache to reduce token acquisition calls
$Script:AccessTokenCache = @{
    Token     = $null
    ExpiresOn = [DateTime]::MinValue
}

$Script:GraphTokenCache = @{
    Token     = $null
    ExpiresOn = [DateTime]::MinValue
}

#EndRegion Token Cache Variables

#Region Authentication Functions

function Get-AccessToken {
    <#
    .SYNOPSIS
        Retrieves Azure Resource Manager access token using Managed Identity.
    .DESCRIPTION
        Acquires an access token for Azure Resource Manager or other Azure services using
        the function app's managed identity for authenticating ARM API calls.
    .PARAMETER ResourceUrl
        The Azure Resource Manager endpoint URL (e.g., https://management.azure.com/).
    .PARAMETER ClientId
        Optional. The client ID of the user-assigned managed identity. If not specified, uses system-assigned identity.
    .EXAMPLE
        $token = Get-AccessToken -ResourceManagerUrl 'https://management.azure.com/'
    .EXAMPLE
        $token = Get-AccessToken -ResourceManagerUrl 'https://management.azure.com/' -ClientId 'abc123...'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ResourceUrl,
        
        [Parameter(Mandatory = $false)]
        [string] $ClientId
    )
    
    $TokenAuthURI = $env:IDENTITY_ENDPOINT + '?resource=' + $ResourceUrl + '&api-version=2019-08-01'
    
    # Add client_id parameter if using user-assigned identity
    if ($ClientId) {
        $TokenAuthURI += "&client_id=$ClientId"
    }
    
    $TokenResponse = Invoke-RestMethod -Method Get -Headers @{"X-IDENTITY-HEADER" = "$env:IDENTITY_HEADER" } -Uri $TokenAuthURI
    Return $TokenResponse.access_token
}

#EndRegion Authentication Functions

#Region Configuration Functions

function Read-FunctionAppSetting {
    <#
    .SYNOPSIS
        Retrieves configuration values from Azure Function App Settings (environment variables).
    .DESCRIPTION
        Reads values from environment variables with automatic type conversion for JSON, boolean, and numeric values.
        This is the local implementation matching the AzureFunctionConfiguration module behavior.
    .PARAMETER ConfigKey
        The name of the configuration key to retrieve from environment variables.
    .EXAMPLE
        $hostPoolName = Read-FunctionAppSetting HostPoolName
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $ConfigKey
    )
    
    # Get the value from environment variable
    $value = [System.Environment]::GetEnvironmentVariable($ConfigKey)
    
    # Return null if value is null or empty
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }
    
    # Convert JSON strings to hashtables for complex configurations
    if ($value.StartsWith('{')) {
        try {
            return $value | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to parse JSON for $ConfigKey : $_"
            return $value
        }
    }
    
    # Convert boolean strings to actual boolean values
    if ($value -eq 'true' -or $value -eq 'True') {
        return $true
    }
    elseif ($value -eq 'false' -or $value -eq 'False') {
        return $false
    }
    
    # Convert numeric strings to integers where appropriate
    if ($value -match '^\d+$') {
        return [int]$value
    }
    
    return $value
}

#EndRegion Configuration Functions

#Region Logging and Error Handling

function Write-HostDetailed {
    <#
    .SYNOPSIS
        Enhanced logging function with timestamp and level support.
    .DESCRIPTION
        Writes detailed log messages with timestamps and severity levels.
    .PARAMETER Message
        The message to log.
    .PARAMETER Level
        The severity level (Information, Warning, Error, Host).
    .PARAMETER StringValues
        Array of values to format into the message using -f operator.
    .EXAMPLE
        Write-HostDetailed -Message "Processing {0} items" -StringValues 10 -Level Host
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Information', 'Warning', 'Error', 'Host', 'Verbose')]
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
    
    # Add timestamp
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $output = "[$timestamp] [$Level] $formattedMessage"
    
    # Output based on level
    switch ($Level) {
        'Error' {
            Write-Error $output
        }
        'Warning' {
            Write-Warning $output
        }
        'Host' {
            Write-Host $output
        }
        'Verbose' {
            Write-Verbose $output
        }
        default {
            Write-Information $output -InformationAction Continue
        }
    }
}

function Invoke-AzureRestMethodWithRetry {
    <#
    .SYNOPSIS
        Invokes Azure REST API with automatic retry logic for transient failures.
    .DESCRIPTION
        Wraps Invoke-AzureRestMethod with exponential backoff retry for 429 and 5xx errors.
    .PARAMETER AccessToken
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
                Write-HostDetailed "Request failed with status $statusCode. Retrying in $delay seconds (attempt $attempt of $MaxRetries)" -Level Warning
                Start-Sleep -Seconds $delay
            }
            else {
                Write-HostDetailed "Request failed: $_" -Level Error
                throw $_
            }
        }
    }
    
    return $result
}

#EndRegion Logging and Error Handling

#Region Core Helper Functions

function Invoke-GraphApiWithRetry {
    <#
    .SYNOPSIS
        Invokes Microsoft Graph API with automatic retry for DoD endpoint if GCCH fails.
    .DESCRIPTION
        Attempts to call the Graph API with the provided endpoint. If the call fails with
        authentication/forbidden errors, automatically retries with the DoD Graph endpoint.
    .PARAMETER GraphEndpoint
        The initial Graph endpoint to try (e.g., https://graph.microsoft.us).
    .PARAMETER AccessToken
        Bearer token for authentication.
    .PARAMETER Method
        HTTP method (GET, POST, PATCH, DELETE).
    .PARAMETER Uri
        The relative URI path (e.g., /v1.0/devices). Will be appended to GraphEndpoint.
    .PARAMETER Body
        Optional request body for POST/PATCH operations.
    .PARAMETER Headers
        Optional custom headers. Authorization header will be added automatically.
    .EXAMPLE
        Invoke-GraphApiWithRetry -GraphEndpoint $env:GraphEndpoint -ARMToken $token -Method Get -Uri "/v1.0/devices?`$filter=displayName eq 'VM01'"
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $GraphEndpoint,
        
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Patch', 'Delete', 'Put')]
        [string] $Method,
        
        [Parameter(Mandatory = $true)]
        [string] $Uri,
        
        [Parameter()]
        [string] $Body,
        
        [Parameter()]
        [hashtable] $Headers = @{}
    )
    
    # Ensure GraphEndpoint doesn't have trailing slash
    $graphBase = if ($GraphEndpoint[-1] -eq '/') { 
        $GraphEndpoint.Substring(0, $GraphEndpoint.Length - 1) 
    } else { 
        $GraphEndpoint 
    }
    
    # Ensure Uri has leading slash
    $uriPath = if ($Uri[0] -ne '/') { "/$Uri" } else { $Uri }
    
    # Build full URI
    $fullUri = "$graphBase$uriPath"
    
    # Setup headers
    $requestHeaders = $Headers.Clone()
    $requestHeaders['Authorization'] = "Bearer $ARMToken"
    if (-not $requestHeaders.ContainsKey('Content-Type')) {
        $requestHeaders['Content-Type'] = 'application/json'
    }
    
    # List of endpoints to try
    $endpointsToTry = @($graphBase)
    
    # If we're using GCCH endpoint, also try DoD
    if ($graphBase -eq 'https://graph.microsoft.us') {
        $endpointsToTry += 'https://dod-graph.microsoft.us'
    }
    
    $lastError = $null
    foreach ($endpoint in $endpointsToTry) {
        try {
            $currentUri = "$endpoint$uriPath"
            Write-HostDetailed "Attempting Graph API call to: $currentUri" -Level Verbose
            
            $params = @{
                Uri     = $currentUri
                Method  = $Method
                Headers = $requestHeaders
            }
            
            if ($Body) {
                $params['Body'] = $Body
            }
            
            $result = Invoke-RestMethod @params -ErrorAction Stop
            Write-HostDetailed "Successfully called Graph API at $endpoint" -Level Verbose
            return $result
        }
        catch {
            $lastError = $_
            $statusCode = $_.Exception.Response.StatusCode.value__
            
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode.value__
            }
            
            # Retry on authentication/authorization errors (401, 403) or if endpoint not found (404 on base endpoint)
            if ($statusCode -in @(401, 403, 404) -and $endpoint -ne $endpointsToTry[-1]) {
                Write-HostDetailed "Graph API call to $endpoint failed with status $statusCode. Trying next endpoint..." -Level Warning
                continue
            }
            else {
                Write-HostDetailed "Graph API call failed: $($_.Exception.Message)" -Level Error
                throw $_
            }
        }
    }
    
    # If we get here, all endpoints failed
    Write-HostDetailed "All Graph API endpoints failed. Last error: $($lastError.Exception.Message)" -Level Error
    throw $lastError
}

function Invoke-AzureRestMethod {
    <#
        .SYNOPSIS
            Run an Azure REST call with paging support.           
        .PARAMETER AccessToken
            An access token generated by Connect-DCMsGraphAsDelegated or Connect-DCMsGraphAsApplication (depending on what permissions you use in Graph).
        .PARAMETER Method
            The HTTP method for the Graph call, like GET, POST, PUT, PATCH, DELETE. Default is GET.
        .PARAMETER Uri
            The Microsoft Graph URI for the query. Example: https://graph.microsoft.com/v1.0/users/
        .PARAMETER Body
            The request body of the Graph call. This is often used with methids like POST, PUT and PATCH. It is not used with GET.
        .EXAMPLE
            Invoke-AzureRestMethod -ARMToken $ARMToken -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/users/'
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

    # Check if authentication was successfull.
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
            $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $Uri -UseBasicParsing -Method $Method -ContentType "application/json" -Verbose:$false
        }
        else {
            $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $Uri -UseBasicParsing -Method $Method -ContentType "application/json" -Body $Body -Verbose:$false
        }
        if ($QueryRequest.value) {
            $dataToUpload += $QueryRequest.value
        }
        else {
            $dataToUpload += $QueryRequest
        }

        # Invoke REST methods and fetch data until there are no pages left.
        if ($Uri -notlike "*`$top*") {
            while ($QueryRequest.'@odata.nextLink' -and $QueryRequest.'@odata.nextLink' -is [string]) {
                $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $QueryRequest.'@odata.nextLink' -UseBasicParsing -Method $Method -ContentType "application/json" -Verbose:$false
                $dataToUpload += $QueryRequest.value
            }
            While ($QueryRequest.nextLink -and $QueryRequest.nextLink -is [string]) {
                $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $QueryRequest.nextLink -UseBasicParsing -Method $Method -ContentType "application/json" -Verbose:$false
                $dataToUpload += $QueryRequest.value
            }
            While ($QueryRequest.'$skipToken' -and $QueryRequest.'$skipToken' -is [string] -and $Body -ne '') {
                $JsonBody = $Body | ConvertFrom-Json
                $JsonBody | Add-Member -Type NoteProperty -Name '$skipToken' -Value $QueryRequest.'$skipToken' -Force
                $Body = $JsonBody | ConvertTo-Json -Depth 10
                $QueryRequest = Invoke-RestMethod -Headers $HeaderParams -Uri $Uri -UseBasicParsing -Method $Method -Body $Body -ContentType "application/json" -Verbose:$false
                $dataToUpload += $QueryRequest.value
            }
        }
        $dataToUpload
    }
    else {
        Write-Error "No Access Token"
    }
}

#EndRegion Configuration and Utility Functions

#Region Progressive Scale-Up State Management

function Get-DeploymentState {
    <#
    .SYNOPSIS
        Retrieves the deployment state from Azure Table Storage for progressive scale-up tracking.
    .DESCRIPTION
        Reads deployment history from the function app's storage account table to track
        consecutive successful deployments and current scale-up percentage.
    .PARAMETER HostPoolName
        Name of the host pool to retrieve state for.
    .PARAMETER StorageAccountName
        Name of the storage account containing the state table.
    .EXAMPLE
        $state = Get-DeploymentState -HostPoolName 'hp-prod-001'
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        
        [Parameter()]
        [string] $StorageAccountName
    )
    
    try {
        # Parse storage account name from AzureWebJobsStorage if not provided
        if (-not $StorageAccountName) {
            $storageUri = $env:AzureWebJobsStorage__blobServiceUri
            if ($storageUri -match 'https://([^.]+)\.') {
                $StorageAccountName = $Matches[1]
            }
            else {
                throw "Unable to determine storage account name from environment variables"
            }
        }
        
        $tableName = 'sessionHostDeploymentState'
        $partitionKey = $HostPoolName
        $rowKey = 'DeploymentState'
        $storageSuffix = $env:StorageSuffix
        $tableEndpoint = "https://$StorageAccountName.table.$storageSuffix"
        
        # Get storage access token using managed identity for the specific storage account
        $storageToken = Get-AccessToken -ResourceUrl "https://$StorageAccountName.table.$storageSuffix/"
        
        $headers = @{
            'Authorization'  = "Bearer $storageToken"
            'Accept'         = 'application/json;odata=nometadata'
            'x-ms-version'   = '2019-02-02'
            'x-ms-date'      = [DateTime]::UtcNow.ToString('R')
        }
        
        # Check if table exists, create if not
        $tablesUri = "$tableEndpoint/Tables"
        try {
            $existingTables = Invoke-RestMethod -Uri $tablesUri -Headers $headers -Method Get -ContentType 'application/json' -ErrorAction SilentlyContinue
            $tableExists = $existingTables.value | Where-Object { $_.TableName -eq $tableName }
            
            if (-not $tableExists) {
                Write-HostDetailed "Creating deployment state table '$tableName'" -Level Information
                $createTableBody = @{ TableName = $tableName } | ConvertTo-Json
                $headers['Content-Type'] = 'application/json'
                Invoke-RestMethod -Uri $tablesUri -Headers $headers -Method Post -Body $createTableBody -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-HostDetailed "Error checking/creating table: $_" -Level Warning
        }
        
        # Query entity
        $entityUri = "$tableEndpoint/$tableName(PartitionKey='$partitionKey',RowKey='$rowKey')"
        
        try {
            $entity = Invoke-RestMethod -Uri $entityUri -Headers $headers -Method Get -ContentType 'application/json' -ErrorAction Stop
            
            Write-HostDetailed "Retrieved deployment state: ConsecutiveSuccesses=$($entity.ConsecutiveSuccesses), CurrentPercentage=$($entity.CurrentPercentage)%" -Level Information
            return [PSCustomObject]@{
                LastDeploymentCount     = [int]$entity.LastDeploymentCount
                LastDeploymentNeeded    = [int]$entity.LastDeploymentNeeded
                LastDeploymentPercentage = [int]$entity.LastDeploymentPercentage
                LastStatus              = $entity.LastStatus
                LastTimestamp           = $entity.LastTimestamp
                ConsecutiveSuccesses    = [int]$entity.ConsecutiveSuccesses
                CurrentPercentage       = [int]$entity.CurrentPercentage
            }
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                Write-HostDetailed "No deployment state found, initializing new state" -Level Information
                return [PSCustomObject]@{
                    LastDeploymentCount     = 0
                    LastDeploymentNeeded    = 0
                    LastDeploymentPercentage = 0
                    LastStatus              = 'None'
                    LastTimestamp           = (Get-Date -AsUTC -Format 'o')
                    ConsecutiveSuccesses    = 0
                    CurrentPercentage       = (Read-FunctionAppSetting InitialDeploymentPercentage)
                }
            }
            else {
                throw $_
            }
        }
    }
    catch {
        Write-HostDetailed "Failed to retrieve deployment state: $_" -Level Error
        # Return default state on error
        return [PSCustomObject]@{
            LastDeploymentCount     = 0
            LastDeploymentNeeded    = 0
            LastDeploymentPercentage = 0
            LastStatus              = 'Error'
            LastTimestamp           = (Get-Date -AsUTC -Format 'o')
            ConsecutiveSuccesses    = 0
            CurrentPercentage       = (Read-FunctionAppSetting InitialDeploymentPercentage)
        }
    }
}

function Save-DeploymentState {
    <#
    .SYNOPSIS
        Saves the deployment state to Azure Table Storage for progressive scale-up tracking.
    .DESCRIPTION
        Writes deployment history to the function app's storage account table to track
        consecutive successful deployments and update scale-up percentage.
    .PARAMETER DeploymentState
        The deployment state object to save.
    .PARAMETER HostPoolName
        Name of the host pool.
    .PARAMETER StorageAccountName
        Name of the storage account.
    .EXAMPLE
        Save-DeploymentState -DeploymentState $state -HostPoolName 'hp-prod-001'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $DeploymentState,
        
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        
        [Parameter()]
        [string] $StorageAccountName
    )
    
    try {
        # Parse storage account name from AzureWebJobsStorage if not provided
        if (-not $StorageAccountName) {
            $storageUri = $env:AzureWebJobsStorage__blobServiceUri
            if ($storageUri -match 'https://([^.]+)\.') {
                $StorageAccountName = $Matches[1]
            }
            else {
                throw "Unable to determine storage account name from environment variables"
            }
        }
        
        $tableName = 'sessionHostDeploymentState'
        $partitionKey = $HostPoolName
        $rowKey = 'DeploymentState'
        $storageSuffix = $env:StorageSuffix
        $tableEndpoint = "https://$StorageAccountName.table.$storageSuffix"
        
        # Get storage access token using managed identity for the specific storage account
        $storageToken = Get-AccessToken -ResourceUrl "https://$StorageAccountName.table.$storageSuffix/"
        
        $headers = @{
            'Authorization'  = "Bearer $storageToken"
            'Accept'         = 'application/json;odata=nometadata'
            'x-ms-version'   = '2019-02-02'
            'x-ms-date'      = [DateTime]::UtcNow.ToString('R')
            'Content-Type'   = 'application/json'
        }
        
        # Check if table exists, create if not
        $tablesUri = "$tableEndpoint/Tables"
        try {
            $existingTables = Invoke-RestMethod -Uri $tablesUri -Headers $headers -Method Get -ContentType 'application/json' -ErrorAction SilentlyContinue
            $tableExists = $existingTables.value | Where-Object { $_.TableName -eq $tableName }
            
            if (-not $tableExists) {
                Write-HostDetailed "Creating deployment state table '$tableName'" -Level Information
                $createTableBody = @{ TableName = $tableName } | ConvertTo-Json
                Invoke-RestMethod -Uri $tablesUri -Headers $headers -Method Post -Body $createTableBody -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-HostDetailed "Error checking/creating table: $_" -Level Warning
        }
        
        # Prepare entity data
        $entityData = @{
            PartitionKey            = $partitionKey
            RowKey                  = $rowKey
            LastDeploymentCount     = $DeploymentState.LastDeploymentCount
            LastDeploymentNeeded    = $DeploymentState.LastDeploymentNeeded
            LastDeploymentPercentage = $DeploymentState.LastDeploymentPercentage
            LastStatus              = $DeploymentState.LastStatus
            LastTimestamp           = $DeploymentState.LastTimestamp
            ConsecutiveSuccesses    = $DeploymentState.ConsecutiveSuccesses
            CurrentPercentage       = $DeploymentState.CurrentPercentage
        }
        
        # Check if entity exists
        $entityUri = "$tableEndpoint/$tableName(PartitionKey='$partitionKey',RowKey='$rowKey')"
        $entityExists = $false
        
        try {
            Invoke-RestMethod -Uri $entityUri -Headers $headers -Method Get -ErrorAction Stop | Out-Null
            $entityExists = $true
        }
        catch {
            if ($_.Exception.Response.StatusCode -ne 404) {
                throw $_
            }
        }
        
        if ($entityExists) {
            # Update existing entity using MERGE
            $updateHeaders = $headers.Clone()
            $updateHeaders['If-Match'] = '*'
            $body = $entityData | ConvertTo-Json
            Invoke-RestMethod -Uri $entityUri -Headers $updateHeaders -Method Merge -Body $body -ErrorAction Stop | Out-Null
        }
        else {
            # Insert new entity
            $insertUri = "$tableEndpoint/$tableName"
            $body = $entityData | ConvertTo-Json
            Invoke-RestMethod -Uri $insertUri -Headers $headers -Method Post -Body $body -ErrorAction Stop | Out-Null
        }
        
        Write-HostDetailed "Saved deployment state: Status=$($DeploymentState.LastStatus), ConsecutiveSuccesses=$($DeploymentState.ConsecutiveSuccesses), NextPercentage=$($DeploymentState.CurrentPercentage)%" -Level Information
    }
    catch {
        Write-HostDetailed "Failed to save deployment state: $_" -Level Error
    }
}

#EndRegion Progressive Scale-Up State Management

#Region Utility Functions

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

#EndRegion Utility Functions

#Region Session Host Lifecycle Functions

function Deploy-SessionHosts {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string[]] $ExistingSessionHostNames = @(),

        [Parameter(Mandatory = $true)]
        [int] $NewSessionHostsCount,

        [Parameter(Mandatory = $false)]
        [string] $HostPoolResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),

        [Parameter(Mandatory = $true)]
        [string] $VirtualMachinesSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string] $VirtualMachinesResourceGroupName,

        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),

        [Parameter()]
        [string] $SessionHostNamePrefix = (Read-FunctionAppSetting SessionHostNamePrefix),

        [Parameter()]
        [int] $SessionHostInstanceNumberPadding = (Read-FunctionAppSetting SessionHostInstanceNumberPadding),

        [Parameter()]
        [string] $DeploymentPrefix = (Read-FunctionAppSetting SHRDeploymentPrefix),

        [Parameter()]
        [hashtable] $SessionHostParameters = (Read-FunctionAppSetting SessionHostParameters | ConvertTo-CaseInsensitiveHashtable),

        [Parameter()]
        [string] $SessionHostTemplate = (Read-FunctionAppSetting SessionHostTemplate),

        [Parameter()]
        [string] $TagIncludeInAutomation = (Read-FunctionAppSetting Tag_IncludeInAutomation),

        [Parameter()]
        [string] $TagDeployTimestamp = (Read-FunctionAppSetting Tag_DeployTimestamp)
    )

    Write-HostDetailed -Message "Generating new token for the host pool $HostPoolName in Resource Group $HostPoolResourceGroupName"
    $Body = @{
        properties = @{
            registrationInfo = @{
                expirationTime             = (Get-Date).AddHours(8)
                registrationTokenOperation = 'Update'
            }
        }
    }
    Invoke-AzureRestMethod `
        -ARMToken $ARMToken `
        -Body ($Body | ConvertTo-Json -depth 10) `
        -Method Patch `
        -Uri ($ResourceManagerUrl + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $HostPoolResourceGroupName + '/providers/Microsoft.DesktopVirtualization/hostPools/' + $HostPoolName + '?api-version=2024-04-03') | Out-Null
    
    # Calculate Session Host Names
    Write-HostDetailed -Level Host -Message "Existing session host VM names: {0}" -StringValues ($ExistingSessionHostNames -join ',')
    [array] $sessionHostNames = for ($i = 0; $i -lt $NewSessionHostsCount; $i++) {
        $shNumber = 1
        While (("$SessionHostNamePrefix{0:d$SessionHostInstanceNumberPadding}" -f $shNumber) -in $ExistingSessionHostNames) {
            $shNumber++
        }
        $shName = "$SessionHostNamePrefix{0:d$SessionHostInstanceNumberPadding}" -f $shNumber
        $ExistingSessionHostNames += $shName
        $shName
    }
    Write-HostDetailed -Message "Creating session host(s) " + ($sessionHostNames -join ', ')

    # Update Session Host Parameters
    $sessionHostParameters['sessionHostNames'] = $sessionHostNames
    $sessionHostParameters['Tags'][$TagIncludeInAutomation] = $true
    $sessionHostParameters['Tags'][$TagDeployTimestamp] = (Get-Date -AsUTC -Format 'o')
    $deploymentTimestamp = Get-Date -AsUTC -Format 'FileDateTime'
    $deploymentName = "{0}_{1}_Count_{2}_VMs" -f $DeploymentPrefix, $deploymentTimestamp, $sessionHostNames.count
    
    Write-HostDetailed -Message "Deployment name: $deploymentName"
    Write-HostDetailed -Message "Deploying using Template Spec: $sessionHostTemplate"
    $templateSpecVersionResourceId = Get-TemplateSpecVersionResourceId -ResourceId $SessionHostTemplate

    Write-HostDetailed -Message "Deploying $NewSessionHostCount session host(s) to resource group $VirtualMachinesResourceGroupName" 
    
    $Body = @{
        properties = @{
            parameters   = $sessionHostParameters
            templateLink = @{
                id = $templateSpecVersionResourceId
            }
        }
    }
    $Uri = $ResourceManagerUrl + '/subscriptions/' + $VirtualMachinesSubscriptionId + '/resourceGroups/' + $VirtualMachinesResourceGroupName + '/providers/Microsoft.Resources/deployments/' + $deploymentName + '?api-version=2021-04-01'
    $DeploymentJob = Invoke-AzureRestMethod `
        -ARMToken $ARMToken `
        -Body ($Body | ConvertTo-Json -depth 20) `
        -Method Put `
        -Uri $Uri
    #TODO: Add logic to test if deployment is running (aka template is accepted) then finish running the function and let the deployment run in the background.
    Write-HostDetailed -Message 'Pausing for 30 seconds to allow deployment to start'
    Start-Sleep -Seconds 30
    
    # Check deployment status
    $deploymentSucceeded = $true
    if ($deploymentJob.Error) {
        Write-HostDetailed "DeploymentFailed: $($deploymentJob.Error)"
        $deploymentSucceeded = $false
        throw $deploymentJob.Error
    }
    
    # Return deployment information for state tracking
    return [PSCustomObject]@{
        DeploymentName  = $deploymentName
        SessionHostCount = $NewSessionHostsCount
        Succeeded       = $deploymentSucceeded
        Timestamp       = $deploymentTimestamp
    }
}

function Get-LatestImageVersion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ResourceManagerUrl,

        [Parameter(Mandatory = $true)]
        [string] $SubscriptionId,

        [Parameter()]
        [hashtable] $ImageReference,

        [Parameter()]
        [string] $Location
    )

    # Marketplace image
    if ($ImageReference.publisher) {
        if ($ImageReference.version -ne 'latest') {
            Write-HostDetailed  "Image version is not set to latest. Returning version '$($ImageReference.version)'"
            $azImageVersion = $ImageReference.version
        }
        else {
            Write-HostDetailed "Getting latest version of image publisher: $($ImageReference.publisher), offer: $($ImageReference.offer), sku: $($ImageReference.sku) in region: $($Location)"
                      
            $Uri = $ResourceManagerUrl + "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location/publishers/$($ImageReference.publisher)/artifacttypes/vmimage/offers/$($ImageReference.offer)/skus/$($ImageReference.sku)/versions?api-version=2024-07-01"
            
            $Versions = Invoke-AzureRestMethod -ARMToken $ARMToken -Uri $Uri -Method Get

            $azImageVersion = ($Versions | Sort-Object -Property { [version] $_.Name } -Descending | Select-Object -First 1).Name
            Write-HostDetailed  "Latest version of image is $azImageVersion"

            if ($azImageVersion -match "\d+\.\d+\.(?<Year>\d{2})(?<Month>\d{2})(?<Day>\d{2})") {
                $azImageDate = Get-Date -Date ("20{0}-{1}-{2}" -f $Matches.Year, $Matches.Month, $Matches.Day)
                Write-HostDetailed  "Image date is $azImageDate"
            }
            else {
                throw "Image version does not match expected format. Could not extract image date."
            }
        }
    }
    elseif ($ImageReference.Id) {
        Write-HostDetailed "Image is from Shared Image Gallery: $($ImageReference.Id)"
        $imageDefinitionResourceIdPattern = '^\/subscriptions\/(?<subscription>[a-z0-9\-]+)\/resourceGroups\/(?<resourceGroup>[^\/]+)\/providers\/Microsoft\.Compute\/galleries\/(?<gallery>[^\/]+)\/images\/(?<image>[^\/]+)$'
        $imageVersionResourceIdPattern = '^\/subscriptions\/(?<subscription>[a-z0-9\-]+)\/resourceGroups\/(?<resourceGroup>[^\/]+)\/providers\/Microsoft\.Compute\/galleries\/(?<gallery>[^\/]+)\/images\/(?<image>[^\/]+)\/versions\/(?<version>[^\/]+)$'
        if ($ImageReference.Id -match $imageDefinitionResourceIdPattern) {
            Write-HostDetailed 'Image reference is an Image Definition resource.'
            $imageSubscriptionId = $Matches.subscription
            $imageResourceGroup = $Matches.resourceGroup
            $imageGalleryName = $Matches.gallery
            $imageDefinitionName = $Matches.image

            $Uri = $ResourceManagerUri + "/subscriptions/$imageSubscriptionId/resourceGroups/$imageResourceGroup/providers/Microsoft.Compute/galleries/$imageGalleryName/images/$imageDefinitionName/versions?api-version=2023-07-03"
            $latestImageVersion = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri |
            Where-Object { $_.PublishingProfile.ExcludeFromLatest -eq $false } |
            Sort-Object -Property { $_.PublishingProfile.PublishedDate } -Descending |
            Select-Object -First 1
            if (-not $latestImageVersion) {
                throw "No available image versions found."
            }
            Write-HostDetailed "Selected image version with resource Id {0}" -StringValues $latestImageVersion.Id
            $azImageVersion = $latestImageVersion.Name
            $azImageDate = $latestImageVersion.PublishingProfile.PublishedDate
            Write-HostDetailed "Image version is {0} and date is {1}" -StringValues $azImageVersion, $azImageDate.ToString('o')
        }
        elseif ($ImageReference.Id -match $imageVersionResourceIdPattern ) {
            Write-HostDetailed 'Image reference is an Image Version resource.'
            $Uri = $ResourceManagerUri + "$($ImageReference.Id)?api-version=2023-07-03"
            $azImageVersion = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
            $azImageVersion = $imageVersion.Name
            $azImageDate = $imageVersion.PublishingProfile.PublishedDate
            Write-HostDetailed "Image version is {0} and date is {1}" -StringValues $azImageVersion, $azImageDate.ToString('o')
        }
        else {
            throw "Image reference Id does not match expected format for an Image Definition resource."
        }
    }
    else {
        throw "Image reference does not contain a publisher or Id property. ImageReference, publisher, and Id are case sensitive!!"
    }
    return [PSCustomObject]@{
        Version = $azImageVersion
        Date    = $azImageDate
    }
}

function Get-HostPoolDecisions {
    [CmdletBinding()]
    param (
        [Parameter()]
        [array] $SessionHosts = @(),
        [Parameter()]
        $RunningDeployments,
        [Parameter()]
        [int] $TargetVMAgeDays = (Read-FunctionAppSetting TargetVMAgeDays),
        [Parameter()]
        [int] $TargetSessionHostCount = (Read-FunctionAppSetting TargetSessionHostCount),
        [Parameter()]
        [int] $TargetSessionHostBuffer = (Read-FunctionAppSetting TargetSessionHostBuffer),
        [Parameter()]
        [PSCustomObject] $LatestImageVersion,
        [Parameter()]
        [bool] $ReplaceSessionHostOnNewImageVersion = (Read-FunctionAppSetting ReplaceSessionHostOnNewImageVersion),
        [Parameter()]
        [int] $ReplaceSessionHostOnNewImageVersionDelayDays = (Read-FunctionAppSetting ReplaceSessionHostOnNewImageVersionDelayDays),
        [Parameter()]
        [bool] $EnableProgressiveScaleUp = [bool]::Parse((Read-FunctionAppSetting EnableProgressiveScaleUp)),
        [Parameter()]
        [int] $InitialDeploymentPercentage = [int]::Parse((Read-FunctionAppSetting InitialDeploymentPercentage)),
        [Parameter()]
        [int] $ScaleUpIncrementPercentage = [int]::Parse((Read-FunctionAppSetting ScaleUpIncrementPercentage)),
        [Parameter()]
        [int] $MaxDeploymentBatchSize = [int]::Parse((Read-FunctionAppSetting MaxDeploymentBatchSize)),
        [Parameter()]
        [int] $SuccessfulRunsBeforeScaleUp = [int]::Parse((Read-FunctionAppSetting SuccessfulRunsBeforeScaleUp))
    )
    
    Write-HostDetailed "We have $($SessionHosts.Count) session hosts (included in Automation)"
    
    if ($TargetVMAgeDays -gt 0) {
        $targetReplacementDate = (Get-Date).AddDays(-$TargetVMAgeDays)
        [array] $sessionHostsOldAge = $SessionHosts | Where-Object { $_.DeployTimestamp -lt $targetReplacementDate }
        Write-HostDetailed "Found $($sessionHostsOldAge.Count) hosts to replace due to old age. $($($sessionHostsOldAge.SessionHostName) -join ',')"
    }

    if ($ReplaceSessionHostOnNewImageVersion) {
        $latestImageAge = (New-TimeSpan -Start $LatestImageVersion.Date -End (Get-Date -AsUTC)).TotalDays
        Write-HostDetailed "Latest Image $($LatestImageVersion.Version) is $latestImageAge days old."
        if ($latestImageAge -ge $ReplaceSessionHostOnNewImageVersionDelayDays) {
            Write-HostDetailed "Latest Image age is older than (or equal) New Image Delay value $ReplaceSessionHostOnNewImageVersionDelayDays"
            [array] $sessionHostsOldVersion = $sessionHosts | Where-Object { $_.ImageVersion -ne $LatestImageVersion.Version }
            Write-HostDetailed "Found $($sessionHostsOldVersion.Count) session hosts to replace due to new image version. $($($sessionHostsOldVersion.SessionHostName) -Join ',')"
        }
    }

    [array] $sessionHostsToReplace = ($sessionHostsOldAge + $sessionHostsOldVersion) | Select-Object -Property * -Unique
    Write-HostDetailed "Found $($sessionHostsToReplace.Count) session hosts to replace in total. $($($sessionHostsToReplace.SessionHostName) -join ',')"

    $goodSessionHosts = $SessionHosts | Where-Object { $_.SessionHostName -notin $sessionHostsToReplace.SessionHostName }
    $sessionHostsCurrentTotal = ([array]$goodSessionHosts.SessionHostName + [array]$runningDeployments.SessionHostNames ) | Select-Object -Unique
    Write-HostDetailed "We have $($sessionHostsCurrentTotal.Count) good session hosts including $($runningDeployments.SessionHostName.Count) session hosts being deployed"
    Write-HostDetailed "We target having $TargetSessionHostCount session hosts in good shape"
    Write-HostDetailed "We have a buffer of $TargetSessionHostBuffer session hosts more than the target."
    $weCanDeployUpTo = $TargetSessionHostCount + $TargetSessionHostBuffer - $SessionHosts.count - $RunningDeployments.SessionHostNames.Count
    
    if ($weCanDeployUpTo -ge 0) {
        Write-HostDetailed "We can deploy up to $weCanDeployUpTo session hosts" 
        $weNeedToDeploy = $TargetSessionHostCount - $sessionHostsCurrentTotal.Count
        
        if ($weNeedToDeploy -gt 0) {
            Write-HostDetailed "We need to deploy $weNeedToDeploy new session hosts"
            $weCanDeploy = if ($weNeedToDeploy -gt $weCanDeployUpTo) { $weCanDeployUpTo } else { $weNeedToDeploy }
            Write-HostDetailed "Buffer allows deploying $weCanDeploy session hosts"
            
            if ($EnableProgressiveScaleUp -and $weCanDeploy -gt 0) {
                Write-HostDetailed "Progressive scale-up is enabled"
                $deploymentState = Get-DeploymentState
                $currentPercentage = $InitialDeploymentPercentage
                
                if ($deploymentState.ConsecutiveSuccesses -ge $SuccessfulRunsBeforeScaleUp) {
                    $scaleUpMultiplier = [Math]::Floor($deploymentState.ConsecutiveSuccesses / $SuccessfulRunsBeforeScaleUp)
                    $currentPercentage = $InitialDeploymentPercentage + ($scaleUpMultiplier * $ScaleUpIncrementPercentage)
                }
                
                $currentPercentage = [Math]::Min($currentPercentage, 100)
                $percentageBasedCount = [Math]::Ceiling($weCanDeploy * ($currentPercentage / 100.0))
                $actualDeployCount = [Math]::Min($percentageBasedCount, $MaxDeploymentBatchSize)
                $actualDeployCount = [Math]::Min($actualDeployCount, $weCanDeploy)
                
                Write-HostDetailed "Progressive scale-up: Using $currentPercentage% of $weCanDeploy needed = $actualDeployCount hosts (ConsecutiveSuccesses: $($deploymentState.ConsecutiveSuccesses), Max: $MaxDeploymentBatchSize)"
                $weCanDeploy = $actualDeployCount
            }
        }
        else {
            $weCanDeploy = 0
            Write-HostDetailed "We have enough session hosts in good shape."
        }
    }
    else {
        Write-HostDetailed "Buffer is full. We can not deploy more session hosts"
        $weCanDeploy = 0
    }
    
    $weCanDelete = $SessionHosts.Count - $TargetSessionHostCount
    if ($weCanDelete -gt 0) {
        Write-HostDetailed "We need to delete $weCanDelete session hosts"
        if ($weCanDelete -gt $sessionHostsToReplace.Count) {
            Write-HostDetailed "Host pool is over populated"
            $goodSessionHostsToDeleteCount = $weCanDelete - $sessionHostsToReplace.Count
            Write-HostDetailed "We will delete $goodSessionHostsToDeleteCount good session hosts"
            $selectedGoodHostsTotDelete = [array] ($goodSessionHosts | Sort-Object -Property Session | Select-Object -First $goodSessionHostsToDeleteCount)
            Write-HostDetailed "Selected the following good session hosts to delete: $($($selectedGoodHostsTotDelete.VMName) -join ',')"
        }
        else {
            $selectedGoodHostsTotDelete = @()
            Write-HostDetailed "Host pool is not over populated"
        }
        $sessionHostsPendingDelete = ($sessionHostsToReplace + $selectedGoodHostsTotDelete) | Select-Object -First $weCanDelete
        
        if ($EnableProgressiveScaleUp -and $sessionHostsPendingDelete.Count -gt 0) {
            Write-HostDetailed "Progressive scale-up is enabled for deletions"
            $deploymentState = Get-DeploymentState
            $currentPercentage = $InitialDeploymentPercentage
            
            if ($deploymentState.ConsecutiveSuccesses -ge $SuccessfulRunsBeforeScaleUp) {
                $scaleUpMultiplier = [Math]::Floor($deploymentState.ConsecutiveSuccesses / $SuccessfulRunsBeforeScaleUp)
                $currentPercentage = $InitialDeploymentPercentage + ($scaleUpMultiplier * $ScaleUpIncrementPercentage)
            }
            
            $currentPercentage = [Math]::Min($currentPercentage, 100)
            $percentageBasedCount = [Math]::Ceiling($sessionHostsPendingDelete.Count * ($currentPercentage / 100.0))
            $actualDeleteCount = [Math]::Min($percentageBasedCount, $MaxDeploymentBatchSize)
            $actualDeleteCount = [Math]::Min($actualDeleteCount, $sessionHostsPendingDelete.Count)
            
            Write-HostDetailed "Progressive scale-up for deletions: Using $currentPercentage% of $($sessionHostsPendingDelete.Count) pending = $actualDeleteCount hosts (ConsecutiveSuccesses: $($deploymentState.ConsecutiveSuccesses), Max: $MaxDeploymentBatchSize)"
            $sessionHostsPendingDelete = $sessionHostsPendingDelete | Select-Object -First $actualDeleteCount
        }
        
        Write-HostDetailed "The following Session Hosts are now pending delete: $($($SessionHostsPendingDelete.SessionHostName) -join ',')"
    }
    elseif ($sessionHostsToReplace.Count -gt 0) {
        Write-HostDetailed "We need to delete $($sessionHostsToReplace.Count) session hosts but we don't have enough session hosts in the host pool."
    }
    else {
        Write-HostDetailed "We do not need to delete any session hosts"
    }

    return [PSCustomObject]@{
        PossibleDeploymentsCount       = $weCanDeploy
        PossibleSessionHostDeleteCount = $weCanDelete
        SessionHostsPendingDelete      = $sessionHostsPendingDelete
        ExistingSessionHostNames       = ([array]$SessionHosts.SessionHostName + [array]$runningDeployments.SessionHostNames) | Select-Object -Unique
    }
}

function Get-RunningDeployments {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $SubscriptionId,
        [Parameter(Mandatory = $true)]
        [string] $ResourceGroupName,
        [Parameter()]
        [string] $DeploymentPrefix = (Read-FunctionAppSetting SHRDeploymentPrefix)
    )

    Write-HostDetailed -Message "Getting deployments for resource group '$ResourceGroupName'"
    $Uri = $ResourceManagerUri + "/subscriptions/" + $SubscriptionId + '/resourceGroups/' + $ResourceGroupName + '/providers/Microsoft.Resources/deployments/?api-version=2021-04-01'
    $deployments = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
    $deployments = $deployments | Where-Object { $_.DeploymentName -like "$DeploymentPrefix*" }
    Write-HostDetailed -Message "Found $($deployments.Count) deployments marked with $DeploymentPrefix."
    
    $failedDeployments = $deployments | Where-Object { $_.ProvisioningState -eq 'Failed' }
    if ($failedDeployments) {
        Write-HostDetailed -Message "Found $($failedDeployments.Count) failed deployments. These should be cleaned up before automation can resume." -Level Error
        throw "Found {0} failed deployments. These should be cleaned up before automation can resume." -f $failedDeployments.Count
    }
    
    $runningDeployments = $deployments | Where-Object { $_.ProvisioningState -eq 'Running' }
    Write-HostDetailed -Message "Found $($runningDeployments.Count) running deployments."
    
    $warningThreshold = (Get-Date -AsUTC).AddHours(-2)
    $longRunningDeployments = $runningDeployments | Where-Object { $_.Timestamp -lt $warningThreshold }
    if ($longRunningDeployments) {
        Write-HostDetailed -Message "Found $($longRunningDeployments.Count) deployments that have been running for more than 2 hours. This could block future deployments" -Level Warning
    }

    $output = foreach ($deployment in $runningDeployments) {
        $parameters = $deployment.Parameters | ConvertTo-CaseInsensitiveHashtable
        Write-HostDetailed -Message "Deployment $($deployment.DeploymentName) is running and deploying: $(($parameters['sessionHostNames'].Value -join ','))"
        [PSCustomObject]@{
            DeploymentName   = $deployment.DeploymentName
            SessionHostNames = $parameters['sessionHostNames'].Value
            Timestamp        = $deployment.Timestamp
            Status           = $deployment.ProvisioningState
        }
    }
    return $output
}

function Get-SessionHosts {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),
        [Parameter()]
        [string] $ResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [Parameter()]
        [string] $TagIncludeInAutomation = (Read-FunctionAppSetting Tag_IncludeInAutomation),
        [Parameter()]
        [string] $TagDeployTimestamp = (Read-FunctionAppSetting Tag_DeployTimestamp),
        [Parameter()]
        [string] $TagPendingDrainTimeStamp = (Read-FunctionAppSetting Tag_PendingDrainTimestamp),
        [Parameter()]
        [switch] $FixSessionHostTags,
        [Parameter()]
        [bool] $IncludePreExistingSessionHosts = (Read-FunctionAppSetting IncludePreExistingSessionHosts)
    )
    
    Write-HostDetailed -Message "Getting current session hosts in host pool $HostPoolName"
    $Uri = $ResourceManagerUri + '/subscriptions/' + $HostPoolSubscriptionId + '/resourceGroups/' + $ResourceGroupName + '/providers/Microsoft.DesktopVirtualization/hostPools/' + $HostPoolName + '/sessionHosts?api-version=2024-04-03'
    $sessionHosts = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri | Select-Object Name, ResourceId, Session, AllowNewSession, Status
    Write-HostDetailed -Message "Found $($sessionHosts.Count) session hosts"
    
    $result = foreach ($sh in $sessionHosts) {
        Write-HostDetailed -Message "Getting VM details for $($sh.Name)"
        $Uri = $ResourceManagerUri + $sh.ResourceId + '?api-version=2024-03-01'
        $vm = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri | Select-Object Name, TimeCreated, StorageProfile
        Write-HostDetailed -Message "VM was created on $($vm.TimeCreated)"
        Write-HostDetailed -Message "VM exact version is $($vm.StorageProfile.ImageReference.ExactVersion)"
        Write-HostDetailed -Message 'Getting VM tags'
        $Uri = $ResourceManagerUri + $sh.ResourceId + '/providers/Microsoft.Resources/tags/default?api-version=2021-04-01'
        $vmTags = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
        $vmDeployTimeStamp = $vmTags.Properties.TagsProperty[$TagDeployTimestamp]
        
        try {
            $vmDeployTimeStamp = [DateTime]::Parse($vmDeployTimeStamp)
            Write-HostDetailed -Message "VM has a tag $TagDeployTimestamp with value $vmDeployTimeStamp"
        }
        catch {
            $value = if ($null -eq $vmDeployTimeStamp) { 'null' } else { $vmDeployTimeStamp }
            Write-HostDetailed -Message "VM tag $TagDeployTimestamp with value $value is not a valid date"
            if ($FixSessionHostTags) {
                Write-HostDetailed -Message "Copying VM CreateTime to tag $TagDeployTimestamp with value $($vm.TimeCreated.ToString('o'))"
                $Body = @{
                    operation  = 'Merge'
                    properties = @{ $TagDeployTimestamp = $vm.TimeCreated.ToString('o') }
                }
                Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 10) -Method PATCH -Uri $Uri
            }
            $vmDeployTimeStamp = $vm.TimeCreated
        }
        
        $vmIncludeInAutomation = $vmTags.Properties.TagsProperty[$TagIncludeInAutomation]
        if ($vmIncludeInAutomation -eq "True") {
            Write-HostDetailed -Message "VM has a tag $TagIncludeInAutomation with value $vmIncludeInAutomation" 
            $vmIncludeInAutomation = $true
        }
        elseif ($vmIncludeInAutomation -eq "False") {
            Write-HostDetailed -Message "VM has a tag $TagIncludeInAutomation with value $vmIncludeInAutomation"
            $vmIncludeInAutomation = $false
        }
        else {
            $value = if ($null -eq $vmIncludeInAutomation) { 'null' } else { $vmIncludeInAutomation }
            Write-HostDetailed -Message "VM tag with $TagIncludeInAutomation value $value is not set to True/False"
            if ($FixSessionHostTags) {
                Write-HostDetailed -Message "Setting tag $TagIncludeInAutomation to $IncludePreExistingSessionHosts"
                $Body = @{
                    operation  = 'Merge'
                    properties = @{ $TagIncludeInAutomation = $IncludePreExistingSessionHosts }
                }
                Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 10) -Method PATCH -Uri $Uri
            }
            $vmIncludeInAutomation = $IncludePreExistingSessionHosts
        }
        
        $vmPendingDrainTimeStamp = $vmTags.Properties.TagsProperty[$TagPendingDrainTimeStamp]
        try {
            $vmPendingDrainTimeStamp = [DateTime]::Parse($vmPendingDrainTimeStamp)
            Write-HostDetailed -Message "VM has a tag $TagPendingDrainTimeStamp with value $vmPendingDrainTimeStamp" 
        }
        catch {
            Write-HostDetailed -Message "VM tag $TagPendingDrainTimeStamp is not set." 
            $vmPendingDrainTimeStamp = $null
        }

        $fqdn = $sh.Name -replace ".+\/(.+)", '$1'
        $sessionHostName = $fqdn -replace '\..*$', ''
        
        $hostOutput = @{
            VMName                = $vm.Name
            SessionHostName       = $sessionHostName
            FQDN                  = $fqdn
            DeployTimestamp       = $vmDeployTimeStamp
            IncludeInAutomation   = $vmIncludeInAutomation
            PendingDrainTimeStamp = $vmPendingDrainTimeStamp
            ImageVersion          = $vm.StorageProfile.ImageReference.ExactVersion
        }
        $sh.PSObject.Properties.ForEach{ $hostOutput[$_.Name] = $_.Value }
        [PSCustomObject]$hostOutput
    }
    return $result
}

function Get-SessionHostParameters {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $SessionHostParameters = (Read-FunctionAppSetting SessionHostParameters)
    )
    $paramsHash = ConvertFrom-Json $SessionHostParameters -Depth 99 -AsHashtable
    Write-HostDetailed -Message "Session host parameters: $($paramsHash | Out-String)"
    return $paramsHash
}

function Get-TemplateSpecVersionResourceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )
    $Uri = $ResourceManagerUri + $ResourceId + '?api-version=2021-04-01'    
    $azResourceType = (Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri).ResourceType
    Write-HostDetailed -Message "Resource type: $azResourceType"
    switch ($azResourceType) {
        'Microsoft.Resources/templateSpecs' {
            $Uri = $ResourceManagerUri + $ResourceId + '?$expand=versions&api-version=2021-05-01'
            $templateSpecVersions = (Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri).Versions
            Write-HostDetailed -Message "Template Spec has $($templateSpecVersions.count) versions"
            $latestVersion = $templateSpecVersions | Sort-Object -Property CreationTime -Descending -Top 1
            Write-HostDetailed -Message "Latest version: $($latestVersion.Name) Created at $($latestVersion.CreationTime.ToString('o')) - Returning Resource Id $($latestVersion.Id)"
            return $latestVersion.Id
        }
        'Microsoft.Resources/templateSpecs/versions' {
            return $ResourceId
        }
        Default {
            throw ("Supplied value has type '{0}' is not a valid Template Spec or Template Spec version resource Id." -f $azResourceType)
        }
    }
}

function Remove-SessionHosts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $SessionHostsPendingDelete,
        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),
        [Parameter()]
        [string] $ResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [Parameter()]
        [int] $DrainGracePeriodHours = (Read-FunctionAppSetting DrainGracePeriodHours),
        [Parameter()]
        [string] $TagPendingDrainTimeStamp = (Read-FunctionAppSetting Tag_PendingDrainTimestamp),
        [Parameter()]
        [string] $TagScalingPlanExclusionTag = (Read-FunctionAppSetting Tag_ScalingPlanExclusionTag),
        [Parameter()]
        [bool] $RemoveEntraDevice,
        [Parameter()]
        [bool] $RemoveIntuneDevice
    )

    foreach ($sessionHost in $SessionHostsPendingDelete) {
        $drainSessionHost = $false
        $deleteSessionHost = $false

        if ($sessionHost.Session -eq 0) {
            Write-HostDetailed -Message "Session host $($sessionHost.FQDN) has no sessions." 
            $deleteSessionHost = $true
        }
        else {
            Write-HostDetailed -Message "Session host $($sessionHost.FQDN) has $($sessionHost.Session) sessions." 
            if (-Not $sessionHost.AllowNewSession) {
                Write-HostDetailed -Message "Session host $($sessionHost.FQDN) is in drain mode."
                if ($sessionHost.PendingDrainTimeStamp) {
                    Write-HostDetailed -Message "Session Host $($sessionHost.FQDN) drain timestamp is $($sessionHost.PendingDrainTimeStamp)"
                    $maxDrainGracePeriodDate = $sessionHost.PendingDrainTimeStamp.AddHours($DrainGracePeriodHours)
                    Write-HostDetailed -Message "Session Host $($sessionHost.FQDN) can stay in grace period until $($maxDrainGracePeriodDate.ToUniversalTime().ToString('o'))" 
                    if ($maxDrainGracePeriodDate -lt (Get-Date)) {
                        Write-HostDetailed -Message "Session Host $($sessionHost.FQDN) has exceeded the drain grace period."
                        $deleteSessionHost = $true
                    }
                    else {
                        Write-HostDetailed -Message "Session Host $($sessionHost.FQDN) has not exceeded the drain grace period."
                    }
                }
                else {
                    Write-HostDetailed -Message "Session Host $($sessionHost.FQDN) does not have a drain timestamp."
                    $drainSessionHost = $true
                }
            }
            else {
                Write-HostDetailed -Message "Session host $($sessionHost.Name) in not in drain mode. Turning on drain mode." 
                $drainSessionHost = $true
            }
        }

        if ($drainSessionHost) {
            Write-HostDetailed -Message 'Turning on drain mode.'
            $Uri = $ResourceManagerUri + '/subscriptions/' + $HostPoolSubscriptionId + '/resourceGroups/' + $ResourceGroupName + '/providers/Microsoft.DesktopVirtualization/hostPools/' + $HostPoolName + '/sessionHosts/' + $sessionHost.FQDN + '?api-version=2024-04-03'
            Invoke-AzureRestMethod `
                -ARMToken $ARMToken `
                -Body (@{properties = @{allowNewSession = $false } } | ConvertTo-Json) `
                -Method 'PATCH' `
                -Uri $Uri
            $drainTimestamp = (Get-Date).ToUniversalTime().ToString('o')
            Write-HostDetailed -Message "Setting drain timestamp on tag $TagPendingDrainTimeStamp to $drainTimestamp."
            $Uri = $ResourceManagerUri + $sessionHost.ResourceId + '/providers/Microsoft.Resources/tags/default?api-version=2021-04-01'
            $Body = @{
                operation  = 'Merge'
                properties = @{ $TagPendingDrainTimeStamp = $drainTimestamp }
            }
            Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $Uri
            
            if ($TagScalingPlanExclusionTag -ne ' ') {
                Write-HostDetailed -Message "Setting scaling plan exclusion tag $TagScalingPlanExclusionTag to $true."
                $Body = @{
                    operation  = 'Merge'
                    properties = @{ $TagScalingPlanExclusionTag = $true }
                }
                Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $Uri
            }

            Write-HostDetailed -Message 'Notifying Users'
            Send-DrainNotification -SessionHostName ($sessionHost.FQDN)
        }

        if ($deleteSessionHost) {
            Write-HostDetailed -Message "Deleting session host $($SessionHost.SessionHostName)..."
            if ($RemoveEntraDevice) {
                Write-HostDetailed -Message 'Deleting device from Entra ID'
                Remove-EntraDevice -GraphToken $Script:GraphToken -Name $sessionHost.SessionHostName
            }
            if ($RemoveIntuneDevice) {
                Write-HostDetailed -Message 'Deleting device from Intune'
                Remove-IntuneDevice -GraphToken $Script:GraphToken -Name $sessionHost.SessionHostName
            }
            Write-HostDetailed -Message "Removing Session Host from Host Pool $HostPoolName"
            $Uri = $ResourceManagerUri + '/subscriptions/' + $HostPoolSubscriptionId + '/resourceGroups/' + $ResourceGroupName + '/providers/Microsoft.DesktopVirtualization/hostPools/' + $HostPoolName + '/sessionHosts/' + $sessionHost.FQDN + '?api-version=2024-04-03'
            Invoke-AzureRestMethod -ARMToken $ARMToken -Method DELETE -Uri $Uri            
            Write-HostDetailed -Message "Deleting VM: $($sessionHost.ResourceId)..."
            $Uri = $ResourceManagerUri + $sessionHost.ResourceId + '?forceDeletion=true&api-version=2024-07-01'
            Invoke-AzureRestMethod -ARMToken $ARMToken -Method 'DELETE' -Uri $Uri
        }
    }
}

function Remove-EntraDevice {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        $GraphEndpoint = $env:GraphEndpoint,
        [Parameter(Mandatory = $true)]
        $GraphToken,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )
    
    try {
        $Device = Invoke-GraphApiWithRetry `
            -GraphEndpoint $GraphEndpoint `
            -ARMToken $GraphToken `
            -Method Get `
            -Uri "/v1.0/devices?`$filter=displayName eq '$Name'"
        
        If ($Device.value -and $Device.value.Count -gt 0) {
            $Id = $Device.value[0].id
            Write-HostDetailed -Message "Removing session host $Name from Entra ID (Device ID: $Id)"
            
            Invoke-GraphApiWithRetry `
                -GraphEndpoint $GraphEndpoint `
                -ARMToken $GraphToken `
                -Method Delete `
                -Uri "/v1.0/devices/$Id"
            
            Write-HostDetailed -Message "Successfully removed device $Name from Entra ID"
        }
        else {
            Write-HostDetailed -Message "Device $Name not found in Entra ID" -Level Warning
        }
    }
    catch {
        Write-HostDetailed -Message "Failed to remove Entra device $Name : $($_.Exception.Message)" -Level Error
        throw
    }
}

function Remove-IntuneDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $GraphEndpoint = $env:GraphEndpoint,
        [Parameter(Mandatory = $true)]
        $GraphToken,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )
    
    try {
        $Device = Invoke-GraphApiWithRetry `
            -GraphEndpoint $GraphEndpoint `
            -ARMToken $GraphToken `
            -Method Get `
            -Uri "/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$Name'"
        
        If ($Device.value -and $Device.value.Count -gt 0) {
            $Id = $Device.value[0].id
            Write-HostDetailed -Message "Removing session host '$Name' device from Intune (Device ID: $Id)"
            
            Invoke-GraphApiWithRetry `
                -GraphEndpoint $GraphEndpoint `
                -ARMToken $GraphToken `
                -Method Delete `
                -Uri "/v1.0/deviceManagement/managedDevices/$Id"
            
            Write-HostDetailed -Message "Successfully removed device $Name from Intune"
        }
        else {
            Write-HostDetailed -Message "Device $Name not found in Intune" -Level Warning
        }
    }
    catch {
        Write-HostDetailed -Message "Failed to remove Intune device $Name : $($_.Exception.Message)" -Level Error
        throw
    }
}

function Send-DrainNotification {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $SessionHostName,
        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [Parameter()]
        [string] $ResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),
        [Parameter()]
        [int] $DrainGracePeriodHours = (Read-FunctionAppSetting DrainGracePeriodHours),
        [Parameter()]
        [string] $MessageTitle = "Automatic Session Host Maintenance",
        [Parameter()]
        [string] $MessageBody = "Your session host {0} is being replaced. Please save your work and log off. You will be disconnected in {1} hours."
    )
    
    try {
        $ARMToken = Get-AccessToken -ResourceUrl $env:ResourceManagerUrl
        $ResourceManagerUri = $env:ResourceManagerUrl
        
        Write-HostDetailed -Message "Getting user sessions for session host $SessionHostName"
        $SessionsUri = $ResourceManagerUri + '/subscriptions/' + $HostPoolSubscriptionId + '/resourceGroups/' + $ResourceGroupName + '/providers/Microsoft.DesktopVirtualization/hostPools/' + $HostPoolName + '/sessionHosts/' + $SessionHostName + '/userSessions?api-version=2024-04-03'
        
        $sessions = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $SessionsUri
        
        if ($null -eq $sessions -or $sessions.Count -eq 0) {
            Write-HostDetailed -Message "No active sessions found on session host $SessionHostName"
            return
        }
        
        foreach ($session in $sessions) {
            $sessionId = $session.Name -replace '.+\/.+\/(.+)', '$1'
            $userPrincipalName = $session.Properties.UserPrincipalName
            
            if ([string]::IsNullOrWhiteSpace($sessionId)) {
                Write-HostDetailed -Message "Skipping session with invalid ID" -Level Warning
                continue
            }
            
            $formattedMessageBody = $MessageBody -f $SessionHostName, $DrainGracePeriodHours
            
            Write-HostDetailed -Message "Sending drain notification to user $userPrincipalName on session $sessionId"
            
            $MessageUri = $ResourceManagerUri + '/subscriptions/' + $HostPoolSubscriptionId + '/resourceGroups/' + $ResourceGroupName + '/providers/Microsoft.DesktopVirtualization/hostPools/' + $HostPoolName + '/sessionHosts/' + $SessionHostName + '/userSessions/' + $sessionId + '/sendMessage?api-version=2024-04-03'
            
            $MessagePayload = @{
                messageTitle = $MessageTitle
                messageBody  = $formattedMessageBody
            } | ConvertTo-Json -Depth 10
            
            try {
                Invoke-AzureRestMethod -ARMToken $ARMToken -Method Post -Uri $MessageUri -Body $MessagePayload | Out-Null
                Write-HostDetailed -Message "Successfully sent message to user $userPrincipalName"
            }
            catch {
                Write-HostDetailed -Message "Failed to send message to user $userPrincipalName : $_" -Level Warning
            }
        }
    }
    catch {
        Write-HostDetailed -Message "Error in Send-DrainNotification: $_" -Level Error
    }
}

#EndRegion Session Host Lifecycle Functions

# Export all functions
Export-ModuleMember -Function @(
    'Get-AccessToken'
    'Read-FunctionAppSetting'
    'Write-HostDetailed'
    'Invoke-AzureRestMethodWithRetry'
    'Invoke-GraphApiWithRetry'
    'Invoke-AzureRestMethod'
    'Get-DeploymentState'
    'Save-DeploymentState'
    'ConvertTo-CaseInsensitiveHashtable'
    'Deploy-SessionHosts'
    'Get-LatestImageVersion'
    'Get-HostPoolDecisions'
    'Get-RunningDeployments'
    'Get-SessionHosts'
    'Get-SessionHostParameters'
    'Get-TemplateSpecVersionResourceId'
    'Remove-SessionHosts'
    'Remove-EntraDevice'
    'Remove-IntuneDevice'
    'Send-DrainNotification'
)
