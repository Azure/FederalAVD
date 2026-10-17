param(
    [string]$ResourceManagerUri,
    [string]$UserAssignedIdentityClientId,
    [string]$VmResourceId,
    [ValidateRange(0, 3600)]
    [int]$StableSeconds = 15,
    [ValidateRange(60, 3600)]
    [int]$ReadyTimeoutSeconds = 900,
    [ValidateRange(1, 60)]
    [int]$PollIntervalSeconds = 5
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

    # Restart the VM and wait for the ARM long-running operation to finish before
    # measuring guest readiness. A restart request can remain pending for several
    # minutes while Azure still reports the VM and guest agent as ready.
    $RestartUri = $ResourceManagerUriFixed + $VmResourceId + '/restart?api-version=2024-03-01'
    $RestartResponse = Invoke-WebRequest -Headers $AzureManagementHeader -Method 'Post' -Uri $RestartUri -Body '' -UseBasicParsing

    if ($RestartResponse.StatusCode -eq 200) {
        Write-Output 'VM restart completed synchronously.'
    }
    elseif ($RestartResponse.StatusCode -eq 202) {
        $AsyncUrl = $null
        if ($RestartResponse.Headers.ContainsKey('Azure-AsyncOperation')) {
            $AsyncUrl = $RestartResponse.Headers['Azure-AsyncOperation']
        }
        elseif ($RestartResponse.Headers.ContainsKey('Location')) {
            $AsyncUrl = $RestartResponse.Headers['Location']
        }
        else {
            throw '202 received from restart API but no async polling URL was returned.'
        }

        $RestartDeadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
        $RetryAfterSeconds = 15
        if ($RestartResponse.Headers.ContainsKey('Retry-After')) {
            $ParsedRetryAfter = 0
            if ([int]::TryParse($RestartResponse.Headers['Retry-After'], [ref]$ParsedRetryAfter) -and $ParsedRetryAfter -gt 0) {
                $RetryAfterSeconds = $ParsedRetryAfter
            }
        }

        Write-Output 'Waiting for the ARM restart operation to complete.'
        do {
            if ((Get-Date) -ge $RestartDeadline) {
                throw "Timed out after $ReadyTimeoutSeconds seconds waiting for the ARM restart operation."
            }

            Start-Sleep -Seconds $RetryAfterSeconds
            $RestartStatus = (Invoke-RestMethod -Headers $AzureManagementHeader -Method 'Get' -Uri $AsyncUrl).status
            Write-Output "Restart operation state: $RestartStatus"
        } while ($RestartStatus -notin @('Succeeded', 'Failed', 'Canceled'))

        if ($RestartStatus -ne 'Succeeded') {
            throw "VM restart operation ended with state: $RestartStatus"
        }
    }
    else {
        throw "Unexpected HTTP $($RestartResponse.StatusCode) from restart API."
    }

    $InstanceViewUri = $ResourceManagerUriFixed + $VmResourceId + '/instanceView?api-version=2024-03-01'
    $ReadyDeadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    $StableSince = $null

    Write-Output "Waiting for the image VM to remain running with the guest agent ready for $StableSeconds seconds."
    while ($true) {
        $Now = Get-Date
        if ($Now -ge $ReadyDeadline) {
            throw "Timed out after $ReadyTimeoutSeconds seconds waiting for the image VM to remain ready for $StableSeconds seconds."
        }

        try {
            $VmStatus = Invoke-RestMethod -Headers $AzureManagementHeader -Method 'Get' -Uri $InstanceViewUri
            $PowerState = ($VmStatus.statuses | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1).code
            $AgentState = ($VmStatus.vmAgent.statuses | Where-Object { $_.code -like 'ProvisioningState/*' } | Select-Object -First 1).code
            $VmReady = $PowerState -eq 'PowerState/running' -and $AgentState -eq 'ProvisioningState/succeeded'
        }
        catch {
            $PowerState = 'Unavailable'
            $AgentState = 'Unavailable'
            $VmReady = $false
            Write-Output "Unable to read VM readiness during restart: $($_.Exception.Message)"
        }

        if ($VmReady) {
            if ($null -eq $StableSince) {
                $StableSince = $Now
                Write-Output 'Image VM is running and the guest agent is ready. Starting stability timer.'
            }

            $StableElapsed = [int](($Now - $StableSince).TotalSeconds)
            if ($StableElapsed -ge $StableSeconds) {
                Write-Output "Image VM remained ready for $StableElapsed seconds. Proceeding."
                break
            }
            Write-Output "Image VM ready for $StableElapsed of $StableSeconds required seconds."
        }
        else {
            if ($null -ne $StableSince) {
                Write-Output "Image VM readiness was interrupted (power=$PowerState, agent=$AgentState). Resetting stability timer."
                $StableSince = $null
            }
            else {
                Write-Output "Image VM is not ready (power=$PowerState, agent=$AgentState)."
            }
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
catch {
    throw
}