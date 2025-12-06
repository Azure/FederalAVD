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
        
    $graphBase = "$GraphUri/v1.0"
    $headers = @{
        Authorization  = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }

    # Search for the application by DisplayName
    # Using startswith because 'contains' or 'search' might not be supported on all graph endpoints/objects or require consistency level headers
    $searchUri = "$graphBase/applications?" + '$filter=' + "startswith(displayName, '$AppDisplayNamePrefix')"
    Write-Output "Searching for applications: $searchUri"
    try {
        # Add ConsistencyLevel header which is often required for advanced queries
        $searchHeaders = $headers.Clone()
        $searchHeaders.Add("ConsistencyLevel", "eventual")
        $searchResp = Invoke-RestMethod -Method Get -Uri $searchUri -Headers $searchHeaders        
        if ($searchResp.value.Count -eq 0) {
            throw "No application found starting with '$AppDisplayNamePrefix'."
        }
        Write-Output "Found $($searchResp.value.Count) applications starting with '$AppDisplayNamePrefix'."
    }
    catch {
        Write-Error ("Failed to search for application: " + $_.Exception.Message)
        throw $_
    }

    # Constants for Graph Permissions
    $GraphAppId = "00000003-0000-0000-c000-000000000000"
    $UserReadId = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
    $OpenIdId = "37f7f235-527c-4136-accd-4a02d197296e"
    $ProfileId = "14dad69e-099b-42c9-810b-d002981feec1"

    # Get Microsoft Graph Service Principal in this tenant
    $graphSPUri = "$graphBase/servicePrincipals?`$filter=appId eq '$GraphAppId'"
    $graphSPResp = Invoke-RestMethod -Method Get -Uri $graphSPUri -Headers $headers
    if ($graphSPResp.value.Count -eq 0) {
        throw "Could not find Microsoft Graph Service Principal in tenant."
    }
    $GraphSPObjectId = $graphSPResp.value[0].id
    Write-Output "Found Microsoft Graph Service Principal: $GraphSPObjectId"

    foreach ($app in $searchResp.value) {
        $appObjectId = $app.id
        $appName = $app.displayName
        Write-Output "Processing Application: $appName (ObjectId: $appObjectId)"
        
        $uri = "$graphBase/applications/$appObjectId"

        If ($UpdateTag) {
            $tags = @("kdc_enable_cloud_group_sids")
  
            # 1. Update Tags
            $body = @{ tags = $tags } | ConvertTo-Json -Depth 5

            try {
                Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $body            
                Write-Output "Tags updated successfully for $appName."
            }
            catch {
                Write-Error ("Failed to update tags for $appName : " + $_.Exception.Message)
            }
        }

        # 2. Update Required Resource Access (API Permissions)
        try {
            # Get current app to ensure we have latest requiredResourceAccess
            $currentApp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
            $currentRRA = $currentApp.requiredResourceAccess
            
            # Filter out existing Graph entry to replace it, or append if not present
            $newRRA = if ($currentRRA) { $currentRRA | Where-Object { $_.resourceAppId -ne $GraphAppId } } else { @() }
            
            # Add Graph Permissions
            $newRRA += @{
                resourceAppId  = $GraphAppId
                resourceAccess = @(
                    @{ id = $UserReadId; type = "Scope" },
                    @{ id = $OpenIdId; type = "Scope" },
                    @{ id = $ProfileId; type = "Scope" }
                )
            }
            
            # Ensure newRRA is an array, otherwise ConvertTo-Json might make it a single object if only one entry exists
            $rraBody = @{ requiredResourceAccess = @($newRRA) } | ConvertTo-Json -Depth 10
            Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $rraBody
            Write-Output "Updated API permissions (requiredResourceAccess) for $appName."
        }
        catch {
            $errorMsg = "Failed to update API permissions for $appName : " + $_.Exception.Message
            # Try to capture detailed error response from the API
            if ($_.ErrorDetails) {
                $errorMsg += "`nDetails: " + $_.ErrorDetails.Message
            } elseif ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $details = $reader.ReadToEnd()
                    $errorMsg += "`nDetails: $details"
                } catch {}
            }
            Write-Error $errorMsg
        }

        # 3. Grant Admin Consent
        try {
            # Get Service Principal for the App
            $spUri = "$graphBase/servicePrincipals?`$filter=appId eq '$($app.appId)'"
            $spResp = Invoke-RestMethod -Method Get -Uri $spUri -Headers $headers
            
            $appSPObjectId = $null
            if ($spResp.value.Count -eq 0) {
                Write-Output "Service Principal not found for $appName. Creating it..."
                $spBody = @{ appId = $app.appId } | ConvertTo-Json
                $newSP = Invoke-RestMethod -Method Post -Uri "$graphBase/servicePrincipals" -Headers $headers -Body $spBody
                $appSPObjectId = $newSP.id
                Write-Output "Created Service Principal: $appSPObjectId"
            }
            else {
                $appSPObjectId = $spResp.value[0].id
                Write-Output "Found Service Principal: $appSPObjectId"
            }

            # Check/Create OAuth2PermissionGrant
            $grantUri = "$graphBase/oauth2PermissionGrants?`$filter=clientId eq '$appSPObjectId' and consentType eq 'AllPrincipals' and resourceId eq '$GraphSPObjectId'"
            $grantResp = Invoke-RestMethod -Method Get -Uri $grantUri -Headers $headers
            
            $targetScopes = @("openid", "profile", "User.Read")
            
            if ($grantResp.value.Count -eq 0) {
                Write-Output "Granting admin consent..."
                $grantBody = @{
                    clientId    = $appSPObjectId
                    consentType = "AllPrincipals"
                    resourceId  = $GraphSPObjectId
                    scope       = ($targetScopes -join " ")
                } | ConvertTo-Json
                Invoke-RestMethod -Method Post -Uri "$graphBase/oauth2PermissionGrants" -Headers $headers -Body $grantBody
                Write-Output "Admin consent granted successfully."
            }
            else {
                Write-Output "Updating existing admin consent..."
                $existingGrant = $grantResp.value[0]
                $existingScopes = $existingGrant.scope.Split(' ')
                $mergedScopes = ($existingScopes + $targetScopes) | Select-Object -Unique
                $finalScopeString = $mergedScopes -join " "
                
                if ($finalScopeString -ne $existingGrant.scope) {
                    $grantUpdateBody = @{ scope = $finalScopeString } | ConvertTo-Json
                    $grantId = $existingGrant.id
                    Invoke-RestMethod -Method Patch -Uri "$graphBase/oauth2PermissionGrants/$grantId" -Headers $headers -Body $grantUpdateBody
                    Write-Output "Admin consent updated successfully."
                }
                else {
                    Write-Output "Admin consent already up to date."
                }
            }
        }
        catch {
            Write-Error ("Failed to grant admin consent for $appName : " + $_.Exception.Message)
            if ($_.Exception.Response -and $_.Exception.Response.Content) {
                Write-Output "Server response:" $_.Exception.Response.Content
            }
        }
        # 4. Update IdentifierUris for PrivateLink
        if ($PrivateLink) {
            try {
                # Get current app again to ensure we have latest identifierUris
                $currentApp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
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
                    Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $uriBody
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
    }
}
catch {
    Write-Error $_.Exception.Message
    throw $_
}
finally {
    Stop-Transcript
}