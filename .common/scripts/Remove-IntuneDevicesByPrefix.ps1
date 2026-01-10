[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$DeviceNamePrefix,

    [Parameter(Mandatory = $false)]
    [string]$ClientId,

    [Parameter(Mandatory = $false)]
    [string]$GraphEndpoint = "https://graph.microsoft.com",

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# Setup Logging
$logPath = "C:\Windows\Logs"
if (-not (Test-Path $logPath)) {
    $logPath = $env:TEMP
}
$logFile = Join-Path -Path $logPath -ChildPath "Remove-IntuneDevices-$(Get-Date -Format 'yyyyMMdd-HHmm').log"
Start-Transcript -Path $logFile -Force

# Helper function to invoke Graph API with retry logic
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
                        $errorDetails = " - $($errorObj.error.code): $($errorObj.error.message)"
                    }
                }
            }
            catch {
                # If we can't parse error details, just continue
            }
            
            # Retry on authentication/authorization errors (401, 403) or if endpoint not found (404)
            if ($statusCode -in @(401, 403, 404) -and $endpoint -ne $endpointsToTry[-1]) {
                Write-Warning "Graph API call failed with status $statusCode$errorDetails. Trying alternate endpoint..."
                continue
            }
            else {
                Write-Error "Graph API call failed: $($_.Exception.Message)$errorDetails"
                throw
            }
        }
    }
    
    # If we get here, all endpoints failed
    Write-Error "All Graph API endpoints failed. Last error: $($lastError.Exception.Message)"
    throw $lastError
}

try {
    # Get Graph Access Token
    $GraphUri = if ($GraphEndpoint[-1] -eq '/') { $GraphEndpoint.Substring(0, $GraphEndpoint.Length - 1) } else { $GraphEndpoint }
    
    if ($ClientId) {
        # Use Managed Identity
        Write-Output "Authenticating with Managed Identity..."
        $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$GraphUri&client_id=$ClientId"
        $Response = Invoke-RestMethod -Headers @{ Metadata = "true" } -Uri $TokenUri
        If ($Response) {
            Write-Output "✓ Successfully obtained access token"
            $AccessToken = $Response.access_token
        }
        else {
            throw "Failed to obtain access token from IMDS."
        }
    }
    else {
        # Use current user context (requires Graph PowerShell SDK or Az PowerShell)
        Write-Output "Authenticating with current user context..."
        try {
            # Try Microsoft.Graph module first
            $token = Get-MgAccessToken -ErrorAction SilentlyContinue
            if ($token) {
                $AccessToken = $token
                Write-Output "✓ Using Microsoft.Graph module authentication"
            }
            else {
                # Fallback to Az module
                $azContext = Get-AzContext -ErrorAction Stop
                $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
                $profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azProfile)
                $token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
                $AccessToken = $token.AccessToken
                Write-Output "✓ Using Az PowerShell authentication"
            }
        }
        catch {
            throw "Failed to get access token. Please ensure you're logged in with Connect-MgGraph or Connect-AzAccount, or provide a ClientId for Managed Identity authentication."
        }
    }

    # Search for Intune managed devices with the specified prefix
    Write-Output ""
    Write-Output "Searching for Intune devices starting with: '$DeviceNamePrefix'"
    Write-Output "=================================================="
    
    $allDevices = @()
    $searchUri = "/v1.0/deviceManagement/managedDevices?`$filter=startswith(deviceName,'$DeviceNamePrefix')"
    
    do {
        $response = Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Get -Uri $searchUri
        $allDevices += $response.value
        $searchUri = $response.'@odata.nextLink' -replace '.*(/v1.0/.*)', '$1'
    } while ($response.'@odata.nextLink')
    
    if ($allDevices.Count -eq 0) {
        Write-Output "✓ No devices found with prefix '$DeviceNamePrefix'"
        return
    }
    
    Write-Output "Found $($allDevices.Count) device(s) to delete:"
    Write-Output ""
    
    # Display devices in a table format
    $allDevices | ForEach-Object {
        Write-Output "  • $($_.deviceName)"
        Write-Output "    ID: $($_.id)"
        Write-Output "    User: $($_.userDisplayName)"
        Write-Output "    OS: $($_.operatingSystem) $($_.osVersion)"
        Write-Output "    Last Sync: $($_.lastSyncDateTime)"
        Write-Output ""
    }
    
    if ($WhatIf) {
        Write-Output "=================================================="
        Write-Output "WhatIf mode enabled - no devices will be deleted"
        Write-Output "=================================================="
        return
    }
    
    # Confirm deletion
    Write-Output "=================================================="
    Write-Warning "You are about to delete $($allDevices.Count) device(s) from Intune!"
    $confirmation = Read-Host "Type 'DELETE' to confirm deletion"
    
    if ($confirmation -ne 'DELETE') {
        Write-Output "Deletion cancelled by user"
        return
    }
    
    Write-Output ""
    Write-Output "Deleting devices..."
    Write-Output "=================================================="
    
    $successCount = 0
    $failCount = 0
    
    foreach ($device in $allDevices) {
        try {
            Write-Output "Deleting: $($device.deviceName) (ID: $($device.id))"
            $deleteUri = "/v1.0/deviceManagement/managedDevices/$($device.id)"
            Invoke-GraphApiWithRetry -GraphEndpoint $GraphUri -AccessToken $AccessToken -Method Delete -Uri $deleteUri
            Write-Output "  ✓ Successfully deleted"
            $successCount++
        }
        catch {
            Write-Error "  ✗ Failed to delete: $($_.Exception.Message)"
            $failCount++
        }
    }
    
    Write-Output ""
    Write-Output "=================================================="
    Write-Output "Deletion Summary:"
    Write-Output "  ✓ Successfully deleted: $successCount"
    if ($failCount -gt 0) {
        Write-Output "  ✗ Failed: $failCount"
    }
    Write-Output "=================================================="
}
catch {
    Write-Error $_.Exception.Message
    Write-Error $_.ScriptStackTrace
    throw $_
}
finally {
    Stop-Transcript
}
