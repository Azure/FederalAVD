[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$AppDisplayNamePrefix,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$GraphEndpoint,

    [Parameter(Mandatory = $true)]
    [string]$TenantId
)

$ErrorActionPreference = "Stop"

# Setup Logging
$logPath = "C:\Windows\Logs"
if (-not (Test-Path -Path $logPath)) {
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null
}
$logFile = Join-Path -Path $logPath -ChildPath "Update-StorageAccountApplications-$(Get-Date -Format 'yyyyMMdd-HHmm').log"
Start-Transcript -Path $logFile -Force

try {
    $GraphUri = if ($GraphEndpoint[-1] -eq '/') { $GraphEndpoint.Substring(0, $GraphEndpoint.Length - 1) } else { $GraphEndpoint }
    $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$GraphUri&client_id=$ClientId"
    Write-Output "Requesting access token from IMDS: $TokenUri"
    $Response = Invoke-RestMethod -Headers @{ Metadata = "true" } -Uri $TokenUri
    If ($Response) {
        Write-Output "Successfully obtained response:"
        Write-Output $($Response | ConvertTo-Json -Depth 5)
        $AccessToken = $Response.access_token
    } else {
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

    $tags = @("kdc_enable_cloud_group_sids")

    foreach ($app in $searchResp.value) {
        $appObjectId = $app.id
        $appName = $app.displayName
        Write-Output "Processing Application: $appName (ObjectId: $appObjectId)"

        $uri = "$graphBase/applications/$appObjectId"
        $body = @{ tags = $tags } | ConvertTo-Json -Depth 5

        try {
            Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $body            
            Write-Output "Tags updated successfully for $appName."
        }
        catch {
            Write-Error ("Graph call failed for $appName : " + $_.Exception.Message)
            if ($_.Exception.Response -and $_.Exception.Response.Content) {
                Write-Output "Server response:" $_.Exception.Response.Content
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