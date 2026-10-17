[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$AppDisplayNamePrefix,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$GraphEndpoint,

    [Parameter(Mandatory = $false)]
    [string]$PrivateEndpoint = "false",

    [Parameter(Mandatory = $false)]
    [string]$EnableCloudGroupSids = "false"
)

$ErrorActionPreference = "Stop"

# Convert strings to boolean
$PrivateLink = [System.Convert]::ToBoolean($PrivateEndpoint)
$UpdateTag = [System.Convert]::ToBoolean($EnableCloudGroupSids)

# Setup Logging
$logPath = "C:\Windows\Logs"
$logFile = Join-Path -Path $logPath -ChildPath "Update-StorageAccountApplicationManifest-$(Get-Date -Format 'yyyyMMdd-HHmm').log"
Start-Transcript -Path $logFile -Force

# Gets an access token for the specified Microsoft Graph resource from the VM managed identity
function Get-GraphAccessToken {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Resource,

        [Parameter(Mandatory = $true)]
        [string] $ClientId
    )

    $tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Resource&client_id=$ClientId"
    $response = Invoke-RestMethod -Headers @{ Metadata = "true" } -Uri $tokenUri
    if (-not $response -or -not $response.access_token) {
        throw "Failed to obtain access token for $Resource from IMDS."
    }
    return $response.access_token
}

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
        [hashtable] $Headers = @{},

        [Parameter()]
        [string] $ClientId = $script:ClientId
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
    
    # List of endpoints to try. Tokens are audience-specific, so the DoD endpoint gets its own token.
    $endpointsToTry = @(
        @{ Endpoint = $graphBase; Token = $AccessToken }
    )
    
    # If we're using GCCH endpoint, also try DoD with a fresh token
    if ($graphBase -eq 'https://graph.microsoft.us') {
        $endpointsToTry += @{ Endpoint = 'https://dod-graph.microsoft.us'; Token = $null }
    }
    
    $lastError = $null
    foreach ($endpointConfig in $endpointsToTry) {
        $endpoint = $endpointConfig.Endpoint
        try {
            if (-not $endpointConfig.Token) {
                Write-Host "Requesting access token for $endpoint from IMDS..."
                $endpointConfig.Token = Get-GraphAccessToken -Resource $endpoint -ClientId $ClientId
            }
            $requestHeaders['Authorization'] = "Bearer $($endpointConfig.Token)"
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
            
            # Retry on authentication/authorization errors (401, 403) against the next Graph endpoint
            if ($statusCode -in @(401, 403) -and $endpoint -ne $endpointsToTry[-1].Endpoint) {
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
    Write-Output "PHASE 1: Update Storage Account Application Manifest"
    Write-Output "This updates tags and identifier URIs for privatelink FQDN support"
    Write-Output "============================================"
    
    # Get Graph Access Token using Managed Identity
    $GraphUri = if ($GraphEndpoint[-1] -eq '/') { $GraphEndpoint.Substring(0, $GraphEndpoint.Length - 1) } else { $GraphEndpoint }
    Write-Output "Requesting access token from IMDS..."
    $AccessToken = Get-GraphAccessToken -Resource $GraphUri -ClientId $ClientId
    Write-Output "Successfully obtained access token"
        
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
        Write-Output "Processing Application: $appName (ObjectId: $appObjectId)"
        
        $uri = "/v1.0/applications/$appObjectId"

        # 1. Update Tags
        If ($UpdateTag) {
            Write-Output "Updating tags with kdc_enable_cloud_group_sids..."
            $tags = @("kdc_enable_cloud_group_sids")
            $body = @{ tags = $tags } | ConvertTo-Json -Depth 5

            try {
                Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Patch -Uri $uri -Body $body
                Write-Output "Tags updated successfully for $appName."
            }
            catch {
                Write-Error ("Failed to update tags for $appName : " + $_.Exception.Message)
                throw
            }
        }
        
        # 2. Update IdentifierUris for PrivateLink
        if ($PrivateLink) {
            Write-Output "Updating IdentifierUris for PrivateLink FQDN support..."
            try {
                # Get current app again to ensure we have latest identifierUris
                $currentApp = Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Get -Uri $uri
                $currentUris = $currentApp.identifierUris
                $newUris = @($currentUris)
                $urisChanged = $false

                Write-Output "Current IdentifierUris:"
                foreach ($existingUri in $currentUris) {
                    Write-Output "  - $existingUri"
                }

                foreach ($identifierUri in $currentUris) {
                    # Check for standard file endpoint pattern (works across clouds: windows.net, usgovcloudapi.net, etc.)
                    # Only process URIs that have a proper scheme (api://, http://, https://) to comply with Azure AD policy
                    if ($identifierUri -match '\.file\.core\.' -and 
                        $identifierUri -notmatch '\.privatelink\.file\.core\.' -and
                        $identifierUri -match '^(api|http|https)://') {
                        # Insert .privatelink before .file.core.
                        $privateLinkUri = $identifierUri -replace '\.file\.core\.', '.privatelink.file.core.'
                        
                        # Add to list if not already present (preserving existing URIs)
                        if ($newUris -notcontains $privateLinkUri) {
                            Write-Output "  Adding PrivateLink URI: $privateLinkUri"
                            $newUris += $privateLinkUri
                            $urisChanged = $true
                        }
                    }
                }

                if ($urisChanged) {
                    $uriBody = @{ identifierUris = $newUris } | ConvertTo-Json -Depth 5
                    Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Patch -Uri $uri -Body $uriBody
                    Write-Output "IdentifierUris updated successfully for $appName."
                    Write-Output "New IdentifierUris:"
                    foreach ($newUri in $newUris) {
                        Write-Output "  - $newUri"
                    }
                }
                else {
                    Write-Output "PrivateLink IdentifierUris already present or not applicable for $appName."
                }
            }
            catch {
                Write-Error ("Failed to update IdentifierUris for $appName : " + $_.Exception.Message)
                throw
            }
        }
    }
    
    Write-Output "============================================"
    Write-Output "PHASE 1 COMPLETE: Manifest updated successfully"
    Write-Output "Storage account applications can now authenticate via privatelink endpoints"
    Write-Output "============================================"
}
catch {
    Write-Error "PHASE 1 FAILED: $($_.Exception.Message)"
    throw $_
}
finally {
    Stop-Transcript
}