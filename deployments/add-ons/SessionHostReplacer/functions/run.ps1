# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# Initialize environment-agnostic variables from Function App Configuration
$SubscriptionId = Read-FunctionAppSetting SubscriptionId
$HostPoolSubscriptionId = Read-FunctionAppSetting HostPoolSubscriptionId
$VirtualMachinesSubscriptionId = Read-FunctionAppSetting VirtualMachinesSubscriptionId
$ResourceManagerUrl = Read-FunctionAppSetting ResourceManagerUrl
$UserAssignedIdentityClientId = Read-FunctionAppSetting UserAssignedIdentityClientId
$ARMToken = Get-AccessToken -ResourceUrl $ResourceManagerUrl -ClientId $UserAssignedIdentityClientId
Write-HostDetailed -Message "ResourceManagerUrl: {0}" -StringValues $ResourceManagerUrl -Level Host

# Acquire Graph token if device cleanup is enabled
if (Read-FunctionAppSetting 'RemoveEntraDevice' -or Read-FunctionAppSetting 'RemoveIntuneDevice') {
    $GraphEndpoint = Read-FunctionAppSetting 'GraphEndpoint'
    $GraphToken = Get-AccessToken -ResourceUrl $GraphEndpoint -ClientId $UserAssignedIdentityClientId
    Write-HostDetailed -Message "GraphEndpoint: {0}" -StringValues $GraphEndpoint -Level Host
}
Write-HostDetailed -Message "Function App SubscriptionId: {0}" -StringValues $SubscriptionId -Level Host
Write-HostDetailed -Message "Host Pool SubscriptionId: {0}" -StringValues $HostPoolSubscriptionId -Level Host
Write-HostDetailed -Message "Virtual Machines SubscriptionId: {0}" -StringValues $VirtualMachinesSubscriptionId -Level Host

# Decide which Resource group to use for Session Hosts
$HostPoolResourceGroupName = Read-FunctionAppSetting HostPoolResourceGroupName
if ([string]::IsNullOrEmpty((Read-FunctionAppSetting VirtualMachinesResourceGroupName))) {
    $VirtualMachinesResourceGroupName = $HostPoolResourceGroupName
}
else {
    $VirtualMachinesResourceGroupName = Read-FunctionAppSetting VirtualMachinesResourceGroupName
}
Write-HostDetailed -Message "Using resource group {0} for session hosts" -StringValues $VirtualMachinesResourceGroupName -Level Host

# Get session hosts and update tags if needed.
$sessionHosts = Get-SessionHosts -FixSessionHostTags (Read-FunctionAppSetting FixSessionHostTags)
Write-HostDetailed -Message "Found {0} session hosts" -StringValues $sessionHosts.Count -Level Host

# Filter to Session hosts that are included in auto replace
$sessionHostsFiltered = $sessionHosts | Where-Object { $_.IncludeInAutomation }
Write-HostDetailed -Message "Filtered to {0} session hosts enabled for automatic replacement: {1}" -StringValues $sessionHostsFiltered.Count, ($sessionHostsFiltered.SessionHostName -join ',') -Level Host

# Get running deployments, if any
$runningDeployments = Get-RunningDeployments -SubscriptionId $VirtualMachinesSubscriptionId -ResourceGroupName $VirtualMachinesResourceGroupName
Write-HostDetailed -Message "Found {0} running deployments" -StringValues $runningDeployments.Count -Level Host

# Load session host parameters
$sessionHostParameters = [hashtable]::new([System.StringComparer]::InvariantCultureIgnoreCase)
$sessionHostParameters += (Read-FunctionAppSetting SessionHostParameters)

# Get latest version of session host image
Write-HostDetailed -Message "Getting latest image version using Image Reference: {0}" -StringValues ($sessionHostParameters.ImageReference | Out-String) -Level Host
$latestImageVersion = Get-LatestImageVersion -ResourceManagerUrl $ResourceManagerUrl -SubscriptionId $VirtualMachinesSubscriptionId -ImageReference $sessionHostParameters.ImageReference -Location $sessionHostParameters.Location

# Get number session hosts to deploy
$hostPoolDecisions = Get-HostPoolDecisions -SessionHosts $sessionHostsFiltered -RunningDeployments $runningDeployments -LatestImageVersion $latestImageVersion

# Deploy new session hosts
$deploymentResult = $null
if ($hostPoolDecisions.PossibleDeploymentsCount -gt 0) {
    Write-HostDetailed -Message "We will deploy {0} session hosts" -StringValues $hostPoolDecisions.PossibleDeploymentsCount -Level Host
    # Deploy session hosts - use SessionHostName (hostname from FQDN) not VMName (Azure VM resource name)
    $existingSessionHostNames = (@($sessionHosts.SessionHostName) + @($hostPoolDecisions.ExistingSessionHostNames)) | Sort-Object | Select-Object -Unique
    
    try {
        $deploymentResult = Deploy-SessionHosts -VirtualMachinesSubscriptionId $VirtualMachinesSubscriptionId -VirtualMachinesResourceGroupName $VirtualMachinesResourceGroupName -NewSessionHostsCount $hostPoolDecisions.PossibleDeploymentsCount -ExistingSessionHostNames $existingSessionHostNames
        
        # Update deployment state for progressive scale-up tracking
        if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
            $deploymentState = Get-DeploymentState
            
            if ($deploymentResult.Succeeded) {
                # Increment consecutive successes
                $deploymentState.ConsecutiveSuccesses++
                $deploymentState.LastStatus = 'Success'
                
                # Calculate next percentage
                $successfulRunsBeforeScaleUp = [int]::Parse((Read-FunctionAppSetting SuccessfulRunsBeforeScaleUp))
                $scaleUpIncrementPercentage = [int]::Parse((Read-FunctionAppSetting ScaleUpIncrementPercentage))
                $initialDeploymentPercentage = [int]::Parse((Read-FunctionAppSetting InitialDeploymentPercentage))
                
                $scaleUpMultiplier = [Math]::Floor($deploymentState.ConsecutiveSuccesses / $successfulRunsBeforeScaleUp)
                $deploymentState.CurrentPercentage = [Math]::Min(
                    $initialDeploymentPercentage + ($scaleUpMultiplier * $scaleUpIncrementPercentage),
                    100
                )
                
                Write-HostDetailed "Deployment succeeded. ConsecutiveSuccesses: $($deploymentState.ConsecutiveSuccesses), NextPercentage: $($deploymentState.CurrentPercentage)%"
            }
            else {
                # Reset on failure
                $deploymentState.ConsecutiveSuccesses = 0
                $deploymentState.CurrentPercentage = $initialDeploymentPercentage
                $deploymentState.LastStatus = 'Failed'
                
                Write-HostDetailed "Deployment failed. Resetting consecutive successes to 0"
            }
            
            # Update deployment tracking info
            $deploymentState.LastDeploymentCount = $deploymentResult.SessionHostCount
            $deploymentState.LastDeploymentNeeded = $hostPoolDecisions.PossibleDeploymentsCount
            $deploymentState.LastDeploymentPercentage = if ($hostPoolDecisions.PossibleDeploymentsCount -gt 0) {
                [Math]::Round(($deploymentResult.SessionHostCount / $hostPoolDecisions.PossibleDeploymentsCount) * 100)
            } else { 0 }
            $deploymentState.LastTimestamp = Get-Date -AsUTC -Format 'o'
            
            # Save state
            Save-DeploymentState -DeploymentState $deploymentState
        }
    }
    catch {
        Write-HostDetailed -Err "Deployment failed with error: $_"
        
        # Update state to reflect failure if progressive scale-up is enabled
        if ([bool]::Parse((Read-FunctionAppSetting EnableProgressiveScaleUp))) {
            $deploymentState = Get-DeploymentState
            $deploymentState.ConsecutiveSuccesses = 0
            $deploymentState.CurrentPercentage = [int]::Parse((Read-FunctionAppSetting InitialDeploymentPercentage))
            $deploymentState.LastStatus = 'Failed'
            $deploymentState.LastTimestamp = Get-Date -AsUTC -Format 'o'
            Save-DeploymentState -DeploymentState $deploymentState
        }
        
        throw
    }
}

# Delete session hosts
if ($hostPoolDecisions.PossibleSessionHostDeleteCount -gt 0 -and $hostPoolDecisions.SessionHostsPendingDelete.Count -gt 0) {
    Write-HostDetailed -Message "We will decommission {0} session hosts from this list: {1}" -StringValues $hostPoolDecisions.SessionHostsPendingDelete.Count, ($hostPoolDecisions.SessionHostsPendingDelete.SessionHostName -join ',') -Level Host
    # Decommission session hosts
    $removeEntraDevice = Read-FunctionAppSetting RemoveEntraDevice
    $removeIntuneDevice = Read-FunctionAppSetting RemoveIntuneDevice
    Remove-SessionHosts -SessionHostsPendingDelete $hostPoolDecisions.SessionHostsPendingDelete -RemoveEntraDevice $removeEntraDevice -RemoveIntuneDevice $removeIntuneDevice
}

# Write an information log with the current time.
Write-Host "PowerShell timer trigger function finished! TIME: $currentUTCtime"

