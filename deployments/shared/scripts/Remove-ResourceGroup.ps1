param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceManagerUri,

    [Parameter(Mandatory=$true)]
    [string]$UserAssignedIdentityClientId,

    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupResourceId
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

Try {
    $StopWatch = [Diagnostics.Stopwatch]::StartNew()

    # Fix the resource manager URI since only AzureCloud contains a trailing slash
    $ResourceManagerUriFixed = if($ResourceManagerUri[-1] -eq '/'){$ResourceManagerUri.Substring(0,$ResourceManagerUri.Length - 1)} else {$ResourceManagerUri}

    # Get an access token for Azure resources
    $AzureManagementAccessToken = (Invoke-RestMethod -Headers @{Metadata="true"} -Uri $('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ResourceManagerUriFixed + '&client_id=' + $UserAssignedIdentityClientId)).access_token

    # Set header for Azure Management API
    $AzureManagementHeader = @{
        'Content-Type'='application/json'
        'Authorization'='Bearer ' + $AzureManagementAccessToken
    }

    # Wait for at least 30 seconds to allow the Run Command to report status to ARM to avoid deployment failed error when VM is deleted before status is returned.
    # Run commands have a minimum of 20 seconds to report status to ARM. This gives an additional 10 seconds buffer.
    $StopWatch.Stop()
    $StopWatch.Elapsed.TotalSeconds
    If ($StopWatch.Elapsed.TotalSeconds -lt 30) {
        Start-Sleep -Seconds (30 - $StopWatch.Elapsed.TotalSeconds)
    }
    Invoke-RestMethod -Headers $AzureManagementHeader -Method 'DELETE' -Uri $($ResourceManagerUriFixed + $ResourceGroupResourceId + '?forceDeletionTypes=Microsoft.Compute/virtualMachines&api-version=2021-04-01')
}
catch {
    throw
}