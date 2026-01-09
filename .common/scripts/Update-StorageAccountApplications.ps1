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

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$EnableCloudGroupSids = "false"
)

$ErrorActionPreference = "Stop"

# Convert strings to boolean
$PrivateLink = [System.Convert]::ToBoolean($PrivateEndpoint)
$UpdateTag = [System.Convert]::ToBoolean($EnableCloudGroupSids)

# Setup Logging
$logPath = "C:\Windows\Logs"
$logFile = Join-Path -Path $logPath -ChildPath "Update-StorageAccountApplications-$(Get-Date -Format 'yyyyMMdd-HHmm').log"
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
            Write-Output "Attempting Graph API call to: $attemptUri"
            
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
    # Get Graph Access Token using Managed Identity
    $GraphUri = if ($GraphEndpoint[-1] -eq '/') { $GraphEndpoint.Substring(0, $GraphEndpoint.Length - 1) } else { $GraphEndpoint }
    $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$GraphUri&client_id=$ClientId"
    Write-Output "Requesting access token from IMDS: $TokenUri"
    $Response = Invoke-RestMethod -Headers @{ Metadata = "true" } -Uri $TokenUri
    If ($Response) {
        Write-Output "Successfully obtained response:"
        Write-Output $($Response | ConvertTo-Json -Depth 5)
        $AccessToken = $Response.access_token
    }
    else {
        throw "Failed to obtain access token from IMDS."
    }
        
    # Search for the application by DisplayName
    # Using startswith because 'contains' or 'search' might not be supported on all graph endpoints/objects or require consistency level headers
    $searchUri = "/v1.0/applications?" + '$filter=' + "startswith(displayName, '$AppDisplayNamePrefix')"
    Write-Output "Searching for applications with prefix: $AppDisplayNamePrefix"
    try {
        # Add ConsistencyLevel header which is often required for advanced queries
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
            $tags = @("kdc_enable_cloud_group_sids")
  

            $body = @{ tags = $tags } | ConvertTo-Json -Depth 5

            try {
                Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Patch -Uri $uri -Body $body
                Write-Output "Tags updated successfully for $appName."
            }
            catch {
                Write-Error ("Failed to update tags for $appName : " + $_.Exception.Message)
            }
        }
        
        # 2. Update IdentifierUris for PrivateLink
        if ($PrivateLink) {
            try {
                # Get current app again to ensure we have latest identifierUris
                $currentApp = Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Get -Uri $uri
                $currentUris = $currentApp.identifierUris
                $newUris = @($currentUris)
                $urisChanged = $false

                foreach ($identifierUri in $currentUris) {
                    # Check for standard file endpoint pattern (works across clouds: windows.net, usgovcloudapi.net, etc.)
                    if ($identifierUri -match '\.file\.core\.' -and $identifierUri -notmatch '\.privatelink\.file\.core\.') {
                        # Insert .privatelink before .file.core.
                        $privateLinkUri = $identifierUri -replace '\.file\.core\.', '.privatelink.file.core.'
                        
                        # Add to list if not already present (preserving existing URIs)
                        if ($newUris -notcontains $privateLinkUri) {
                            $newUris += $privateLinkUri
                            $urisChanged = $true
                        }
                    }
                }

                if ($urisChanged) {
                    Write-Output "Adding PrivateLink IdentifierUris..."
                    $uriBody = @{ identifierUris = $newUris } | ConvertTo-Json -Depth 5
                    Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Patch -Uri $uri -Body $uriBody
                    Write-Output "IdentifierUris updated successfully for $appName."
                }
                else {
                    Write-Output "PrivateLink IdentifierUris already present or not applicable for $appName."
                }
            }
            catch {
                Write-Error ("Failed to update IdentifierUris for $appName : " + $_.Exception.Message)
            }
        }

        # 3. Grant Delegated Permissions to Storage Account Enterprise Application
        # Note: We're NOT adding these to the App Registration's requiredResourceAccess (API Permissions).
        # We're directly granting delegated permissions to the Enterprise Application via oauth2PermissionGrants.
        # This keeps the App Registration clean and only shows the permissions on the Enterprise Application.
        try {
            Write-Output "============================================"
            Write-Output "Granting delegated permissions to Enterprise Application for: $appName"
            Write-Output "App ID: $($app.appId)"
            Write-Output "============================================"
            
            # Get Service Principal for the Storage Account App (Enterprise Application)
            $spUri = "/v1.0/servicePrincipals?`$filter=appId eq '$($app.appId)'"
            Write-Output "Looking for Service Principal (Enterprise Application) with filter: appId eq '$($app.appId)'"
            $spResp = Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Get -Uri $spUri
            
            if ($spResp.value.Count -eq 0) {
                Write-Warning "Service Principal (Enterprise Application) not found for AppId: $($app.appId)."
                Write-Warning "The Enterprise Application must exist before delegated permissions can be granted."
                Write-Warning "Please verify that the Storage Account has Azure AD authentication enabled and the Enterprise Application exists."
            }
            else {
                # This is the Storage Account's Enterprise Application (Service Principal)
                $storageAccountSP = $spResp.value[0]
                $storageAccountServicePrincipalId = $storageAccountSP.id
                $storageAccountSPDisplayName = $storageAccountSP.displayName
                
                Write-Output "✓ Found Enterprise Application:"
                Write-Output "  Display Name: $storageAccountSPDisplayName"
                Write-Output "  Service Principal ID: $storageAccountServicePrincipalId"
                Write-Output "  App ID: $($storageAccountSP.appId)"

                # Get Service Principal for Microsoft Graph (this is the resource being accessed)
                $graphSpUri = "/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'"
                Write-Output "Looking for Microsoft Graph Service Principal..."
                $graphSpResp = Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Get -Uri $graphSpUri
                $graphServicePrincipalId = $graphSpResp.value[0].id
                Write-Output "✓ Found Microsoft Graph Service Principal ID: $graphServicePrincipalId"

                # Check for existing delegated permission grant
                $grantUri = "/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$storageAccountServicePrincipalId' and resourceId eq '$graphServicePrincipalId'"
                Write-Output "Checking for existing oauth2PermissionGrants..."
                $grantResp = Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Get -Uri $grantUri
                
                # Delegated permissions we want to grant
                $scope = @("openid", "profile", "User.Read")
                $scopeString = $scope -join " "
                
                if ($grantResp.value.Count -gt 0) {
                    # Update existing delegated permission grant
                    $existingGrant = $grantResp.value[0]
                    $grantId = $existingGrant.id
                    $existingScope = $existingGrant.scope
                    Write-Output "✓ Found existing oauth2PermissionGrant:"
                    Write-Output "  Grant ID: $grantId"
                    Write-Output "  Existing Scope: '$existingScope'"
                    Write-Output "  Consent Type: $($existingGrant.consentType)"
                    
                    $newScope = $existingScope
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
                         Write-Output "Updating oauth2PermissionGrant with new scope: '$($newScope.Trim())'"
                         Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Patch -Uri $updateGrantUri -Body $grantBody
                         Write-Output "✓ Successfully updated delegated permissions for Enterprise Application."
                         Write-Output "  New Scope: '$($newScope.Trim())'"
                    } else {
                        Write-Output "✓ All required delegated permissions already exist."
                        Write-Output "  Current Scope: '$existingScope'"
                    }

                } else {
                    # Create new delegated permission grant
                    Write-Output "No existing oauth2PermissionGrant found. Creating new grant..."
                    $grantBody = @{
                        clientId = $storageAccountServicePrincipalId
                        consentType = "AllPrincipals"
                        resourceId = $graphServicePrincipalId
                        scope = $scopeString
                    } | ConvertTo-Json
                    
                    Write-Output "Creating oauth2PermissionGrant with:"
                    Write-Output "  Client (Enterprise App): $storageAccountServicePrincipalId"
                    Write-Output "  Resource (Microsoft Graph): $graphServicePrincipalId"
                    Write-Output "  Consent Type: AllPrincipals"
                    Write-Output "  Scope: '$scopeString'"
                    
                    $newGrant = Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Post -Uri "/v1.0/oauth2PermissionGrants" -Body $grantBody
                    Write-Output "✓ Successfully created oauth2PermissionGrant!"
                    Write-Output "  Grant ID: $($newGrant.id)"
                    Write-Output ""
                    Write-Output "To verify in Azure Portal:"
                    Write-Output "  1. Go to: Enterprise Applications"
                    Write-Output "  2. Find: $storageAccountSPDisplayName"
                    Write-Output "  3. Navigate to: Permissions blade"
                    Write-Output "  4. Look for: Delegated permissions section"
                    Write-Output "  5. You should see: Microsoft Graph - openid, profile, User.Read"
                }
                
                Write-Output "============================================"
            }
        }
        catch {
            Write-Error "Failed to grant delegated permissions for Enterprise Application $appName."
            Write-Error "Error: $($_.Exception.Message)"
            Write-Error "Stack Trace: $($_.ScriptStackTrace)"
            throw
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    throw $_
}
finally {
    Stop-Transcript
}