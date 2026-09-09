param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceManagerUri,

    [Parameter(Mandatory=$false)]
    [string]$UserAssignedIdentityClientId,

    [Parameter(Mandatory=$true)]
    [string]$ImageVmResourceId,

    [Parameter(Mandatory=$true)]
    [string]$ManagementVmResourceId,

    [Parameter(Mandatory=$false)]
    [string]$ImageResourceId,

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupId
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

Try {
    $StopWatch = [Diagnostics.Stopwatch]::StartNew()

    # Fix the resource manager URI since only AzureCloud contains a trailing slash
    $ResourceManagerUriFixed = if($ResourceManagerUri[-1] -eq '/'){$ResourceManagerUri.Substring(0,$ResourceManagerUri.Length - 1)} else {$ResourceManagerUri}

    # Get an access token  -  use UAI client_id when provided, otherwise fall back to system-assigned identity
    $TokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ResourceManagerUriFixed
    if (-not [string]::IsNullOrEmpty($UserAssignedIdentityClientId)) { $TokenUri += '&client_id=' + $UserAssignedIdentityClientId }
    $AzureManagementAccessToken = (Invoke-RestMethod -Headers @{Metadata="true"} -Uri $TokenUri).access_token

    # Set header for Azure Management API
    $AzureManagementHeader = @{
        'Content-Type'='application/json'
        'Authorization'='Bearer ' + $AzureManagementAccessToken
    }

    Function Invoke-ArmDelete {
        param(
            [Parameter(Mandatory=$true)]
            [string]$Uri
        )

        Try {
            Invoke-RestMethod -Headers $AzureManagementHeader -Method 'DELETE' -Uri $Uri | Out-Null
        } Catch {
            $StatusCode = if ($null -ne $_.Exception.Response) {
                [int]$_.Exception.Response.StatusCode
            } else {
                $null
            }

            # Deletion is idempotent; an already-absent temporary resource is the desired state.
            If ($StatusCode -ne 404) {
                Throw
            }
        }
    }

    Function Wait-ForRunCommandReporting {
        # Match deployment-helper cleanup: allow Managed Run Command at least 30 seconds to report
        # status to ARM before deleting its parent VM or resource group.
        $StopWatch.Stop()
        If ($StopWatch.Elapsed.TotalSeconds -lt 30) {
            Start-Sleep -Seconds (30 - $StopWatch.Elapsed.TotalSeconds)
        }
    }

    If (-not [string]::IsNullOrEmpty($ResourceGroupId)) {
        # New RG path  -  delete the entire resource group (cleans up all VMs, disks, NICs, images)
        Wait-ForRunCommandReporting
        Invoke-ArmDelete -Uri $($ResourceManagerUriFixed + $ResourceGroupId + '?api-version=2021-04-01')
    } Else {
        # Existing RG path  -  delete individual VMs only, leave the RG intact

        # Delete Image VM
        Invoke-ArmDelete -Uri $($ResourceManagerUriFixed + $ImageVmResourceId + '?api-version=2024-03-01')

        # Delete the managed image (if it exists  -  only present for Trusted Launch compatible security type)
        If (-not [string]::IsNullOrEmpty($ImageResourceId)) {
            Invoke-ArmDelete -Uri $($ResourceManagerUriFixed + $ImageResourceId + '?api-version=2024-03-01')
        }

        # Delete the Management VM
        Wait-ForRunCommandReporting
        Invoke-ArmDelete -Uri $($ResourceManagerUriFixed + $ManagementVmResourceId + '?forceDeletion=true&api-version=2024-03-01')
    }
}
catch {
    throw
}