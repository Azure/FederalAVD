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

    # Poll until ARM records this run command resource as 'Succeeded' before deleting the VM or resource group.
    # asyncExecution=true means ARM marks the deployment Succeeded as soon as the VM agent starts the script,
    # but we confirm this explicitly rather than relying on a fixed sleep to avoid the race condition where the
    # agent hasn't yet phoned home to ARM before the VM is deleted.
    $RunCommandUri = $ResourceManagerUriFixed + $ManagementVmResourceId + '/runCommands/RemoveImageBuildResources?api-version=2024-03-01'
    $ArmConfirmed = $false
    $Deadline = (Get-Date).AddSeconds(120)
    while (-not $ArmConfirmed -and (Get-Date) -lt $Deadline) {
        Start-Sleep -Seconds 5
        Try {
            $RunCommandResource = Invoke-RestMethod -Headers $AzureManagementHeader -Method 'GET' -Uri $RunCommandUri
            if ($RunCommandResource.properties.provisioningState -eq 'Succeeded') {
                $ArmConfirmed = $true
            }
        } Catch {}
    }

    If (-not [string]::IsNullOrEmpty($ResourceGroupId)) {
        # New RG path  -  delete the entire resource group (cleans up all VMs, disks, NICs, images)
        Invoke-RestMethod -Headers $AzureManagementHeader -Method 'DELETE' -Uri $($ResourceManagerUriFixed + $ResourceGroupId + '?api-version=2021-04-01') | Out-Null
    } Else {
        # Existing RG path  -  delete individual VMs only, leave the RG intact

        # Delete Image VM
        Invoke-RestMethod -Headers $AzureManagementHeader -Method 'DELETE' -Uri $($ResourceManagerUriFixed + $ImageVmResourceId + '?api-version=2024-03-01')

        # Delete the managed image (if it exists  -  only present for Trusted Launch compatible security type)
        If ($ImageResourceId -ne '') {
            Invoke-RestMethod -Headers $AzureManagementHeader -Method 'DELETE' -Uri $($ResourceManagerUriFixed + $ImageResourceId + '?api-version=2024-03-01')
        }

        # Delete the Management VM
        Invoke-RestMethod -Headers $AzureManagementHeader -Method 'DELETE' -Uri $($ResourceManagerUriFixed + $ManagementVmResourceId + '?forceDeletion=true&api-version=2024-03-01')
    }
}
catch {
    throw
}