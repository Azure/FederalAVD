param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceManagerUri,

    [Parameter(Mandatory=$false)]
    [string]$UserAssignedIdentityClientId,

    [Parameter(Mandatory=$true)]
    [string]$VmResourceId
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$LogFile = "$env:SystemRoot\Logs\Generalize-Vm.log"

function Write-Log {
    param([string]$Message)
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

Try {
    Write-Log "Starting VM generalization process."
    # Fix the resource manager URI since only AzureCloud contains a trailing slash
    $ResourceManagerUriFixed = if($ResourceManagerUri[-1] -eq '/'){$ResourceManagerUri.Substring(0,$ResourceManagerUri.Length - 1)} else {$ResourceManagerUri}

    # Get an access token — use UAI client_id when provided, otherwise fall back to system-assigned identity
    Write-Log "Requesting access token for Azure resources."
    $TokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ResourceManagerUriFixed
    if (-not [string]::IsNullOrEmpty($UserAssignedIdentityClientId)) { $TokenUri += '&client_id=' + $UserAssignedIdentityClientId }
    $AzureManagementAccessToken = (Invoke-RestMethod -Headers @{Metadata="true"} -Uri $TokenUri).access_token

    # Set header for Azure Management API
    $AzureManagementHeader = @{
        'Content-Type'='application/json'
        'Authorization'='Bearer ' + $AzureManagementAccessToken
    }

    # Wait for sysprep to complete and shut down the VM (sysprep runs with /shutdown from a scheduled task)
    
    Write-Log "Waiting for sysprep to complete and the VM to stop."
    $SysprepTimeout = (Get-Date).AddMinutes(10)
    Do {
        Start-Sleep -Seconds 15
        if ((Get-Date) -ge $SysprepTimeout) {
            throw "Timed out after 10 minutes waiting for the image VM to stop. Sysprep may have failed. Last power state: $VMPowerState"
        }
        $VmStatus = Invoke-RestMethod -Headers $AzureManagementHeader -Method 'Get' -Uri $($ResourceManagerUriFixed + $VmResourceId + '/instanceView?api-version=2024-03-01')
        $VMPowerState = ($VMStatus.statuses | Where-Object {$_.code -like 'PowerState*'}).displayStatus

    } Until ($VMPowerState -eq 'VM stopped')
    
    # Deallocate the VM (required for capture)
    Write-Log "VM has stopped. Proceeding to deallocate the VM."

    $null = Invoke-RestMethod -Headers $AzureManagementHeader -Method 'Post' -Uri $($ResourceManagerUriFixed + $VmResourceId + '/deallocate?api-version=2024-03-01')

    # Wait for deallocated state
    $DeallocateTimeout = (Get-Date).AddMinutes(5)
    Do {
        Start-Sleep -Seconds 5
        if ((Get-Date) -ge $DeallocateTimeout) {
            throw "Timed out after 15 minutes waiting for the image VM to deallocate. Last power state: $VMPowerState"
        }
        $VmStatus = Invoke-RestMethod -Headers $AzureManagementHeader -Method 'Get' -Uri $($ResourceManagerUriFixed + $VmResourceId + '/instanceView?api-version=2024-03-01')
        $VMPowerState = ($VMStatus.statuses | Where-Object {$_.code -like 'PowerState*'}).displayStatus
    } Until ($VMPowerState -eq 'VM deallocated')

    # Generalize the VM
    Write-Log "VM has been deallocated. Proceeding to generalize the VM."
    $null = Invoke-RestMethod -Headers $AzureManagementHeader -Method 'Post' -Uri $($ResourceManagerUriFixed + $VmResourceId + '/generalize?api-version=2024-03-01')
    Write-Log "VM has been generalized successfully."
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) {
        Write-Log "Inner exception: $($_.Exception.InnerException.Message)"
    }
    Write-Log $_.ScriptStackTrace
    Exit 1
}