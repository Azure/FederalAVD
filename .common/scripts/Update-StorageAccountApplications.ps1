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