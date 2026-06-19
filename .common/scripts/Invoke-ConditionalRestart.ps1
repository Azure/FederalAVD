param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceManagerUri,

    [Parameter(Mandatory = $false)]
    [string]$UserAssignedIdentityClientId,

    [Parameter(Mandatory = $true)]
    [string]$ImageVmResourceId,

    [Parameter(Mandatory = $true)]
    [string]$RunCommandName
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    $ArmBase = $ResourceManagerUri.TrimEnd('/')

    # Acquire ARM access token from IMDS
    $TokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ArmBase
    if (-not [string]::IsNullOrEmpty($UserAssignedIdentityClientId)) {
        $TokenUri += '&client_id=' + $UserAssignedIdentityClientId
    }
    $Token = (Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri $TokenUri).access_token

    $Headers = @{
        'Content-Type'  = 'application/json'
        'Authorization' = 'Bearer ' + $Token
    }

    # Read the CBS check run command instanceView to determine if a restart is needed.
    # The CBS check script writes RESTART_REQUIRED=true/false to stdout; that text is
    # captured in properties.instanceView.output once the run command completes.
    $RunCommandUri = $ArmBase + $ImageVmResourceId + '/runCommands/' + $RunCommandName + '?$expand=instanceView&api-version=2023-03-01'
    Write-Output "Reading CBS check output from run command '$RunCommandName'..."
    $RunCommand = Invoke-RestMethod -Headers $Headers -Method Get -Uri $RunCommandUri

    $InstanceView = $RunCommand.properties.instanceView
    if ($null -eq $InstanceView) {
        throw "instanceView is null for run command '$RunCommandName'. The run command may not have completed."
    }

    $ExecState = $InstanceView.executionState
    $ExitCode  = $InstanceView.exitCode
    $Output    = $InstanceView.output

    Write-Output "  executionState : $ExecState"
    Write-Output "  exitCode       : $ExitCode"
    Write-Output "  output         : $Output"

    if ($ExecState -ne 'Succeeded' -or $ExitCode -ne 0) {
        throw "CBS check run command did not succeed (executionState=$ExecState, exitCode=$ExitCode). Cannot determine restart requirement."
    }

    if ($Output -match 'RESTART_REQUIRED=true') {
        Write-Output "Restart required. Initiating VM restart via ARM..."

        $RestartUri = $ArmBase + $ImageVmResourceId + '/restart?api-version=2023-03-01'

        # POST restart - ARM returns 200 (sync) or 202 (async LRO).
        # Use Invoke-WebRequest so we can inspect the response headers on a 202.
        $Response = Invoke-WebRequest -Method Post -Uri $RestartUri -Headers $Headers -Body '' -UseBasicParsing

        if ($Response.StatusCode -eq 200) {
            Write-Output "VM restart completed synchronously."
        } elseif ($Response.StatusCode -eq 202) {
            # Locate the async polling URL - prefer Azure-AsyncOperation, fall back to Location
            $AsyncUrl = $null
            if ($Response.Headers.ContainsKey('Azure-AsyncOperation')) {
                $AsyncUrl = $Response.Headers['Azure-AsyncOperation']
            } elseif ($Response.Headers.ContainsKey('Location')) {
                $AsyncUrl = $Response.Headers['Location']
            } else {
                throw "202 received from restart API but no async polling URL found in response headers."
            }

            Write-Output "Polling ARM for restart completion..."
            $Deadline = (Get-Date).AddMinutes(15)
            do {
                if ((Get-Date) -ge $Deadline) {
                    throw "Timed out after 15 minutes waiting for VM restart to complete."
                }
                Start-Sleep -Seconds 15
                $Poll   = Invoke-RestMethod -Method Get -Uri $AsyncUrl -Headers $Headers
                $Status = $Poll.status
                Write-Output "  Restart state: $Status"
            } while ($Status -notin @('Succeeded', 'Failed', 'Canceled'))

            if ($Status -ne 'Succeeded') {
                throw "VM restart operation ended with state: $Status"
            }
        } else {
            throw "Unexpected HTTP $($Response.StatusCode) from restart API."
        }

        # ARM restart is complete once the LRO succeeds, but the guest agent and IMDS
        # need a moment before the next run command can be delivered to the VM.
        Write-Output "VM restarted successfully. Waiting 60 seconds for guest agent to initialize..."
        Start-Sleep -Seconds 60
        Write-Output "Image VM is ready. Proceeding."
    } else {
        Write-Output "No restart required. CBS is settled. Proceeding."
    }
}
catch {
    throw
}
