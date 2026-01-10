[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$AppDisplayNamePrefix,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$GraphEndpoint
)

$ErrorActionPreference = "Stop"

# Setup Logging
$logPath = "C:\Windows\Logs"
$logFile = Join-Path -Path $logPath -ChildPath "Grant-StorageAccountApplicationConsent-$(Get-Date -Format 'yyyyMMdd-HHmm').log"
Start-Transcript -Path $logFile -Force

# Helper function to invoke Graph API with retry logic for DoD endpoints
function Invoke-GraphApiWithRetry {
    param (
        [Parameter(Mandatory = $true)]
        [string] $GraphEndpoint,
        
        [Parameter(Mandatory = $true)]
        [string] $AccessToken,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Patch', 'Delete')]
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
    
    # Setup headers
    $requestHeaders = $Headers.Clone()
    $requestHeaders['Authorization'] = "Bearer $AccessToken"
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
            $attemptUri = "$endpoint$Uri"
            
            $params = @{
                Uri     = $attemptUri
                Method  = $Method
                Headers = $requestHeaders
            }
            
            if ($Body -and $Method -in @('Post', 'Patch')) {
                $params['Body'] = $Body
            }
            
            $result = Invoke-RestMethod @params
            
            # If we succeeded with a different endpoint than the one provided, log it
            if ($endpoint -ne $graphBase) {
                Write-Warning "Graph API call succeeded with alternate endpoint: $endpoint"
                Write-Warning "Consider updating GraphEndpoint parameter to: $endpoint"
            }
            
            return $result
        }
        catch {
            $lastError = $_
            $statusCode = $null
            
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            
            # Try to extract detailed error from Graph API response
            $errorDetails = ""
            try {
                if ($_.Exception.Response) {
                    $responseStream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($responseStream)
                    $responseBody = $reader.ReadToEnd()
                    $reader.Close()
                    $responseStream.Close()
                    
                    $errorObj = $responseBody | ConvertFrom-Json
                    if ($errorObj.error) {
                        $errorDetails = "`n  Error Code: $($errorObj.error.code)`n  Error Message: $($errorObj.error.message)"
                        if ($errorObj.error.details) {
                            $errorDetails += "`n  Details: $($errorObj.error.details | ConvertTo-Json -Compress)"
                        }
                    }
                }
            }
            catch {
                # If we can't parse error details, just continue
            }
            
            # Retry on authentication/authorization errors (401, 403) or if endpoint not found (404 on base endpoint)
            if ($statusCode -in @(401, 403, 404) -and $endpoint -ne $endpointsToTry[-1]) {
                Write-Warning "Graph API call to $endpoint failed with status $statusCode$errorDetails. Trying alternate endpoint..."
                continue
            }
            else {
                # Don't retry - either not an auth error or we've tried all endpoints
                Write-Error "Graph API call failed with status $statusCode : $($_.Exception.Message)$errorDetails"
                throw
            }
        }
    }
    
    # If we get here, all endpoints failed
    Write-Error "All Graph API endpoints failed. Last error: $($lastError.Exception.Message)"
    throw $lastError
}

try {
    Write-Output "============================================"
    Write-Output "PHASE 2: Grant Admin Consent to Storage Account Applications"
    Write-Output "This grants delegated permissions for authentication"
    Write-Output "============================================"
    
    # Get Graph Access Token using Managed Identity
    $GraphUri = if ($GraphEndpoint[-1] -eq '/') { $GraphEndpoint.Substring(0, $GraphEndpoint.Length - 1) } else { $GraphEndpoint }
    $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$GraphUri&client_id=$ClientId"
    Write-Output "Requesting access token from IMDS..."
    $Response = Invoke-RestMethod -Headers @{ Metadata = "true" } -Uri $TokenUri
    If ($Response) {
        Write-Output "Successfully obtained access token"
        $AccessToken = $Response.access_token
    }
    else {
        throw "Failed to obtain access token from IMDS."
    }
        
    # Search for the application by DisplayName
    $searchUri = "/v1.0/applications?" + '$filter=' + "startswith(displayName, '$AppDisplayNamePrefix')"
    Write-Output "Searching for applications with prefix: $AppDisplayNamePrefix"
    try {
        $searchHeaders = @{ "ConsistencyLevel" = "eventual" }
        $searchResp = Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Get -Uri $searchUri -Headers $searchHeaders
        
        if ($searchResp.value.Count -eq 0) {
            throw "No application found starting with '$AppDisplayNamePrefix'."
        }
        Write-Output "Found $($searchResp.value.Count) applications starting with '$AppDisplayNamePrefix'."
    }
    catch {
        Write-Error ("Failed to search for application: " + $_.Exception.Message)
        throw $_
    }

    foreach ($app in $searchResp.value) {
        $appObjectId = $app.id
        $appName = $app.displayName
        Write-Output ""
        Write-Output "Processing Application: $appName"
        Write-Output "  ObjectId: $appObjectId"
        Write-Output "  AppId: $($app.appId)"
        
        # Grant Delegated Permissions to Storage Account Enterprise Application
        try {
            # Get Service Principal for the Storage Account App (Enterprise Application)
            $spUri = "/v1.0/servicePrincipals?`$filter=appId eq '$($app.appId)'"
            Write-Output "Looking for Service Principal (Enterprise Application)..."
            $spResp = Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Get -Uri $spUri
            
            if ($spResp.value.Count -eq 0) {
                Write-Warning "  Service Principal (Enterprise Application) not found for AppId: $($app.appId)"
                Write-Warning "The Enterprise Application must exist before delegated permissions can be granted."
                Write-Warning "Please verify that the Storage Account has Azure AD authentication enabled."
                continue
            }
            
            # This is the Storage Account's Enterprise Application (Service Principal)
            $storageAccountSP = $spResp.value[0]
            $storageAccountServicePrincipalId = $storageAccountSP.id
            $storageAccountSPDisplayName = $storageAccountSP.displayName
            
            Write-Output "    Found Enterprise Application: $storageAccountSPDisplayName"

            # Get Service Principal for Microsoft Graph (this is the resource being accessed)
            $graphSpUri = "/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'"
            $graphSpResp = Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Get -Uri $graphSpUri
            $graphServicePrincipalId = $graphSpResp.value[0].id

            # Check for existing delegated permission grant
            $grantUri = "/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$storageAccountServicePrincipalId'"
            $allGrantsResp = Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Get -Uri $grantUri
            
            # Filter manually for the specific resource
            $matchingGrants = @($allGrantsResp.value | Where-Object { $_ -and $_.resourceId -eq $graphServicePrincipalId -and $_.id })
            
            # Delegated permissions we want to grant
            $scope = @("openid", "profile", "User.Read")
            $scopeString = $scope -join " "
            
            if ($matchingGrants.Count -gt 0) {
                # Update existing delegated permission grant
                $existingGrant = $matchingGrants[0]
                $grantId = $existingGrant.id
                $existingScope = if ($existingGrant.scope) { $existingGrant.scope } else { "" }
                Write-Output "  Found existing oauth2PermissionGrant"
                Write-Output "    Existing scope: '$existingScope'"
                
                # Validate grantId before attempting update
                if (-not $grantId) {
                    Write-Error "Grant ID is null or empty. Cannot update grant."
                    throw "Invalid grant object returned from Graph API"
                }
                
                $newScope = if ($existingScope) { $existingScope } else { "" }
                $scopeChanged = $false
                foreach ($s in $scope) {
                    if ($newScope -notmatch "\b$s\b") {
                        if ($newScope) { $newScope += " " }
                        $newScope += $s
                        $scopeChanged = $true
                    }
                }
                
                if ($scopeChanged) {
                    $updateGrantUri = "/v1.0/oauth2PermissionGrants/$grantId"
                    $grantBody = @{
                        scope = $newScope.Trim()
                    } | ConvertTo-Json
                    Write-Output "  Updating oauth2PermissionGrant..."
                    Write-Output "    New scope: '$($newScope.Trim())'"
                    Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Patch -Uri $updateGrantUri -Body $grantBody
                    Write-Output "    Successfully updated delegated permissions"
                } else {
                    Write-Output "    All required delegated permissions already exist"
                }

            } else {
                # Create new delegated permission grant
                Write-Output "  Creating new oauth2PermissionGrant..."
                Write-Output "    Scope: '$scopeString'"
                
                # Validate required IDs before attempting creation
                if (-not $storageAccountServicePrincipalId) {
                    throw "Storage Account Service Principal ID is null or empty"
                }
                if (-not $graphServicePrincipalId) {
                    throw "Microsoft Graph Service Principal ID is null or empty"
                }
                
                $grantBody = @{
                    clientId = $storageAccountServicePrincipalId
                    consentType = "AllPrincipals"
                    resourceId = $graphServicePrincipalId
                    scope = $scopeString
                } | ConvertTo-Json
                
                try {
                    Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Post -Uri "/v1.0/oauth2PermissionGrants" -Body $grantBody | Out-Null
                    Write-Output "    Successfully created oauth2PermissionGrant"
                }
                catch {
                    Write-Error "Failed to create oauth2PermissionGrant via Graph API"
                    Write-Error "Error details: $($_.Exception.Message)"
                    throw
                }
            }
        }
        catch {
            Write-Error "Failed to grant delegated permissions for Enterprise Application $appName"
            Write-Error "Error: $($_.Exception.Message)"
            throw
        }
    }
    
    Write-Output ""
    Write-Output "============================================"
    Write-Output "  PHASE 2 COMPLETE: Admin consent granted successfully"
    Write-Output "Storage account applications can now authenticate users"
    Write-Output "============================================"
}
catch {
    Write-Error "PHASE 2 FAILED: $($_.Exception.Message)"
    throw $_
}
finally {
    Stop-Transcript
}
