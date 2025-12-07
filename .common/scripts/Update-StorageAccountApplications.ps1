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

    foreach ($app in $searchResp.value) {
        $appObjectId = $app.id
        $appName = $app.displayName
        Write-Output "Processing Application: $appName (ObjectId: $appObjectId)"
        
        $uri = "$graphBase/applications/$appObjectId"

        # 1. Update Tags
        If ($UpdateTag) {
            $tags = @("kdc_enable_cloud_group_sids")
  

            $body = @{ tags = $tags } | ConvertTo-Json -Depth 5

            try {
                Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $body            
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

        # 3. Update Required Resource Access (API Permissions)
        try {
            Write-Output "Checking API Permissions for $appName..."
            # Get current app again to ensure we have latest state
            $currentApp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
            $requiredResourceAccess = $currentApp.requiredResourceAccess
            
            # Microsoft Graph App ID
            $graphAppId = "00000003-0000-0000-c000-000000000000"
            
            # Permissions to ensure
            $permissionsToEnsure = @(
                @{ Id = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"; Type = "Scope"; Name = "User.Read" },
                @{ Id = "37f7f235-527c-4136-accd-4a02d197296e"; Type = "Scope"; Name = "openid" },
                @{ Id = "14dad69e-099b-42c9-810b-d002981feec1"; Type = "Scope"; Name = "profile" }
            )

            $graphAccess = $null
            $otherAccess = @()

            if ($requiredResourceAccess) {
                foreach ($access in $requiredResourceAccess) {
                    if ($access.resourceAppId -eq $graphAppId) {
                        $graphAccess = $access
                    } else {
                        $otherAccess += $access
                    }
                }
            }

            if ($null -eq $graphAccess) {
                $graphAccess = @{
                    resourceAppId = $graphAppId
                    resourceAccess = @()
                }
            }

            $accessChanged = $false
            $currentAccessList = @()
            if ($graphAccess.resourceAccess) {
                $currentAccessList = @($graphAccess.resourceAccess)
            }
            
            $currentAccessIds = $currentAccessList | ForEach-Object { $_.id }

            foreach ($perm in $permissionsToEnsure) {
                if ($currentAccessIds -notcontains $perm.Id) {
                    Write-Output "Adding $($perm.Name) permission..."
                    $currentAccessList += @{
                        id = $perm.Id
                        type = $perm.Type
                    }
                    $accessChanged = $true
                }
            }

            if ($accessChanged) {
                $graphAccess.resourceAccess = $currentAccessList
                # Reconstruct the full list
                $finalResourceAccess = @($otherAccess) + @($graphAccess)
                
                $body = @{ requiredResourceAccess = $finalResourceAccess } | ConvertTo-Json -Depth 5
                Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $body
                Write-Output "API Permissions updated successfully for $appName."
            } else {
                Write-Output "API Permissions already correct for $appName."
            }
        }
        catch {
            Write-Warning "Failed to update API Permissions for $appName : $($_.Exception.Message)"
        }

        # 4. Grant Admin Consent
        try {
            Write-Output "Attempting to grant admin consent for openid, profile, User.Read..."
            
            # Get Service Principal for the App
            $spUri = "$graphBase/servicePrincipals?`$filter=appId eq '$($app.appId)'"
            $spResp = Invoke-RestMethod -Method Get -Uri $spUri -Headers $headers
            if ($spResp.value.Count -eq 0) {
                Write-Warning "Service Principal not found for AppId: $($app.appId). Cannot grant consent."
            }
            else {
                $clientServicePrincipalId = $spResp.value[0].id

                # Get Service Principal for Microsoft Graph
                $graphSpUri = "$graphBase/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'"
                $graphSpResp = Invoke-RestMethod -Method Get -Uri $graphSpUri -Headers $headers
                $graphServicePrincipalId = $graphSpResp.value[0].id

                # Check for existing grant
                $grantUri = "$graphBase/oauth2PermissionGrants?`$filter=clientId eq '$clientServicePrincipalId' and resourceId eq '$graphServicePrincipalId'"
                $grantResp = Invoke-RestMethod -Method Get -Uri $grantUri -Headers $headers
                
                $scope = @("openid", "profile", "User.Read")
                
                if ($grantResp.value.Count -gt 0) {
                    # Update existing grant
                    $grantId = $grantResp.value[0].id
                    $existingScope = $grantResp.value[0].scope                    
                    $newScope = $existingScope
                    foreach ($s in $scope) {
                        if ($newScope -notmatch "\b$s\b") {
                            $newScope += " $s"
                        }
                    }
                    
                    if ($newScope -ne $existingScope) {
                         $updateGrantUri = "$graphBase/oauth2PermissionGrants/$grantId"
                         $grantBody = @{
                            scope = $newScope
                         } | ConvertTo-Json
                         Invoke-RestMethod -Method Patch -Uri $updateGrantUri -Headers $headers -Body $grantBody
                         Write-Output "Admin consent updated for $appName."
                    } else {
                        Write-Output "Admin consent already exists for $appName."
                    }

                } else {
                    # Create new grant
                    $grantBody = @{
                        clientId = $clientServicePrincipalId
                        consentType = "AllPrincipals"
                        resourceId = $graphServicePrincipalId
                        scope = ($scope -join " ")
                    } | ConvertTo-Json
                    
                    Invoke-RestMethod -Method Post -Uri "$graphBase/oauth2PermissionGrants" -Headers $headers -Body $grantBody
                    Write-Output "Admin consent granted for $appName."
                }
            }
        }
        catch {
            Write-Warning "Failed to grant admin consent for $appName. Error: $($_.Exception.Message)"
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