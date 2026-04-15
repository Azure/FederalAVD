param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceManagerUri,

    [Parameter(Mandatory=$true)]
    [string]$UserAssignedIdentityClientId,

    [Parameter(Mandatory=$true)]
    [string]$VmResourceId
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

function Write-OutputWithTimeStamp {
    param([string]$Message)
    $Timestamp = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
    Write-Output "[$Timestamp] $Message"
}

Try {
    $ResourceManagerUriFixed = if ($ResourceManagerUri[-1] -eq '/') { $ResourceManagerUri.Substring(0, $ResourceManagerUri.Length - 1) } else { $ResourceManagerUri }

    $AzureManagementAccessToken = (Invoke-RestMethod `
        -Headers @{Metadata = "true" } `
        -Uri $('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ResourceManagerUriFixed + '&client_id=' + $UserAssignedIdentityClientId)).access_token

    $AzureManagementHeader = @{
        'Content-Type'  = 'application/json'
        'Authorization' = 'Bearer ' + $AzureManagementAccessToken
    }

    function Get-VmPowerState {
        $VmStatus = Invoke-RestMethod -Headers $AzureManagementHeader -Method 'Get' -Uri $($ResourceManagerUriFixed + $VmResourceId + '/instanceView?api-version=2024-03-01')
        return ($VmStatus.statuses | Where-Object { $_.code -like 'PowerState*' }).code
    }

    # Give the image VM a window to start restarting. The CBS check script issues 'shutdown /r /t 30',
    # so the restart fires ~30 seconds after that Run Command exits. Poll for 90 seconds to detect a
    # power state change. If the VM never goes down, no restart was triggered.
    Write-OutputWithTimeStamp "Waiting to detect if image VM is restarting due to pending CBS operations..."
    $WentDown = $false
    $DownCheckEnd = (Get-Date).AddSeconds(90)

    while ((Get-Date) -lt $DownCheckEnd) {
        $PowerState = Get-VmPowerState
        if ($PowerState -ne 'PowerState/running') {
            Write-OutputWithTimeStamp "Image VM power state changed to '$PowerState'. Waiting for restart to complete..."
            $WentDown = $true
            break
        }
        Start-Sleep -Seconds 5
    }

    if ($WentDown) {
        $UpTimeout = (Get-Date).AddMinutes(10)
        $PowerState = Get-VmPowerState
        while ($PowerState -ne 'PowerState/running') {
            if ((Get-Date) -ge $UpTimeout) {
                throw "Timed out after 10 minutes waiting for the image VM to come back online after CBS restart. Last power state: $PowerState"
            }
            Start-Sleep -Seconds 10
            $PowerState = Get-VmPowerState
        }
        # Allow the guest agent time to fully initialize before the next Run Command is issued
        Write-OutputWithTimeStamp "Image VM is running. Waiting 30 seconds for guest agent to initialize..."
        Start-Sleep -Seconds 30
        Write-OutputWithTimeStamp "Image VM is ready. Proceeding."
    } else {
        Write-OutputWithTimeStamp "Image VM did not restart within the detection window. No CBS reboot was required. Proceeding."
    }
}
catch {
    throw
}
