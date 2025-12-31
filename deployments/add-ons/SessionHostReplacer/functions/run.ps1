# Input bindings are passed in via param block.
param($Timer)

Write-HostDetailed -Message "SessionHostReplacer function started at {0}" -StringValues (Get-Date -AsUTC -Format 'o') -Level Host

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# Initialize environment-agnostic variables from Function App Configuration
$HostPoolSubscriptionId = Read-FunctionAppSetting HostPoolSubscriptionId
$VirtualMachinesSubscriptionId = Read-FunctionAppSetting VirtualMachinesSubscriptionId
$UserAssignedIdentityClientId = Read-FunctionAppSetting UserAssignedIdentityClientId

Write-HostDetailed -Message "UserAssignedIdentityClientId: {0}" -StringValues $(if ($UserAssignedIdentityClientId) { $UserAssignedIdentityClientId } else { "(using system-assigned identity)" }) -Level Verbose
Write-HostDetailed -Message "IDENTITY_ENDPOINT: {0}" -StringValues $(if ($env:IDENTITY_ENDPOINT) { "configured" } else { "MISSING" }) -Level Verbose
Write-HostDetailed -Message "IDENTITY_HEADER: {0}" -StringValues $(if ($env:IDENTITY_HEADER) { "configured" } else { "MISSING" }) -Level Verbose

# Acquire ARM access token
try {
    $ARMToken = Get-AccessToken -ResourceUri (Get-ResourceManagerUri) -ClientId $UserAssignedIdentityClientId
    if ([string]::IsNullOrEmpty($ARMToken)) {
        throw "Get-AccessToken returned null or empty token"
    }
}
catch {
    Write-Error "Failed to acquire ARM access token: $_"
    Write-HostDetailed -Message "Token acquisition error details: {0}" -StringValues $_.Exception.Message -Level Host
    throw
}

Write-HostDetailed -Message "Host Pool SubscriptionId: {0}" -StringValues $HostPoolSubscriptionId -Level Verbose
Write-HostDetailed -Message "Virtual Machines SubscriptionId: {0}" -StringValues $VirtualMachinesSubscriptionId -Level Verbose

# Get session hosts and update tags if needed.
$sessionHosts = Get-SessionHosts -ARMToken $ARMToken
Write-HostDetailed -Message "Found {0} session hosts" -StringValues $sessionHosts.Count -Level Host

# Check previous deployment status if progressive scale-up is enabled
$previousDeploymentStatus = $null
if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
    $deploymentState = Get-DeploymentState
    
    if (-not [string]::IsNullOrEmpty($deploymentState.LastDeploymentName)) {
        Write-HostDetailed -Message "Checking status of previous deployment: {0}" -StringValues $deploymentState.LastDeploymentName -Level Host
        $previousDeploymentStatus = Get-LastDeploymentStatus -DeploymentName $deploymentState.LastDeploymentName -ARMToken $ARMToken
        
        if ($previousDeploymentStatus) {
            if ($previousDeploymentStatus.Succeeded) {
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
                
                Write-HostDetailed "Previous deployment succeeded. ConsecutiveSuccesses: $($deploymentState.ConsecutiveSuccesses), CurrentPercentage: $($deploymentState.CurrentPercentage)%" -Level Host
            }
            elseif ($previousDeploymentStatus.Failed) {
                # Reset on failure
                $deploymentState.ConsecutiveSuccesses = 0
                $deploymentState.CurrentPercentage = $initialDeploymentPercentage
                $deploymentState.LastStatus = 'Failed'
                
                Write-HostDetailed "Previous deployment failed. Resetting consecutive successes to 0, CurrentPercentage: $($deploymentState.CurrentPercentage)%" -Level Warning
            }
            elseif ($previousDeploymentStatus.Running) {
                Write-HostDetailed "Previous deployment is still running. Will check again on next run." -Level Warning
                # Don't update state yet - wait until it completes
            }
            
            # Clear LastDeploymentName after checking (succeeded or failed), but keep it if still running
            if ($previousDeploymentStatus.Succeeded -or $previousDeploymentStatus.Failed) {
                $deploymentState.LastDeploymentName = ''
            }
            
            # Save updated state
            Save-DeploymentState -DeploymentState $deploymentState
        }
    }
}

# Filter to Session hosts that are included in auto replace
$sessionHostsFiltered = $sessionHosts | Where-Object { $_.IncludeInAutomation }
Write-HostDetailed -Message "Filtered to {0} session hosts enabled for automatic replacement: {1}" -StringValues $sessionHostsFiltered.Count, ($sessionHostsFiltered.SessionHostName -join ',') -Level Host

# Get running deployments, if any
$runningDeployments = Get-RunningDeployments -ARMToken $ARMToken
Write-HostDetailed -Message "Found {0} running deployments" -StringValues $runningDeployments.Count -Level Verbose

# Load session host parameters
$sessionHostParameters = [hashtable]::new([System.StringComparer]::InvariantCultureIgnoreCase)
$sessionHostParameters += (Read-FunctionAppSetting SessionHostParameters)

# Get latest version of session host image
Write-HostDetailed -Message "Getting latest image version using Image Reference: {0}" -StringValues ($sessionHostParameters.ImageReference | Out-String) -Level Verbose
$latestImageVersion = Get-LatestImageVersion -ARMToken $ARMToken -ImageReference $sessionHostParameters.ImageReference -Location $sessionHostParameters.Location

# Get number session hosts to deploy
$hostPoolDecisions = Get-HostPoolDecisions -SessionHosts $sessionHostsFiltered -RunningDeployments $runningDeployments -LatestImageVersion $latestImageVersion

# Log comprehensive metrics for monitoring dashboard
$metricsLog = @{
    TotalSessionHosts = $sessionHosts.Count
    EnabledForAutomation = $sessionHostsFiltered.Count
    TargetCount = if ($hostPoolDecisions.TargetSessionHostCount) { $hostPoolDecisions.TargetSessionHostCount } else { 0 }
    ToReplace = if ($hostPoolDecisions.TotalSessionHostsToReplace) { $hostPoolDecisions.TotalSessionHostsToReplace } else { 0 }
    ToReplacePercentage = if ($sessionHostsFiltered.Count -gt 0) { [math]::Round(($hostPoolDecisions.TotalSessionHostsToReplace / $sessionHostsFiltered.Count) * 100, 1) } else { 0 }
    InDrain = $hostPoolDecisions.SessionHostsPendingDelete.Count
    PendingDelete = $hostPoolDecisions.SessionHostsPendingDelete.Count
    ToDeployNow = $hostPoolDecisions.PossibleDeploymentsCount
    RunningDeployments = $runningDeployments.Count
    ReplacementMode = Read-FunctionAppSetting ReplacementMode
    LatestImageVersion = if ($latestImageVersion.Version) { $latestImageVersion.Version } else { "N/A" }
    LatestImageDate = $latestImageVersion.Date
}
Write-HostDetailed -Message "METRICS | Total: {0} | Enabled: {1} | Target: {2} | ToReplace: {3} ({4}%) | InDrain: {5} | ToDeployNow: {6} | RunningDeployments: {7} | Mode: {8} | LatestImage: {9}" `
    -StringValues $metricsLog.TotalSessionHosts, $metricsLog.EnabledForAutomation, $metricsLog.TargetCount, $metricsLog.ToReplace, $metricsLog.ToReplacePercentage, $metricsLog.InDrain, $metricsLog.ToDeployNow, $metricsLog.RunningDeployments, $metricsLog.ReplacementMode, $metricsLog.LatestImageVersion `
    -Level Host

# Deploy new session hosts
$deploymentResult = $null
if ($hostPoolDecisions.PossibleDeploymentsCount -gt 0) {
    Write-HostDetailed -Message "We will deploy {0} session hosts" -StringValues $hostPoolDecisions.PossibleDeploymentsCount -Level Host
    # Deploy session hosts - use SessionHostName (hostname from FQDN) not VMName (Azure VM resource name)
    $existingSessionHostNames = (@($sessionHosts.SessionHostName) + @($hostPoolDecisions.ExistingSessionHostNames)) | Sort-Object | Select-Object -Unique
    
    try {
        $deploymentResult = Deploy-SessionHosts -ARMToken $ARMToken -VirtualMachinesSubscriptionId $VirtualMachinesSubscriptionId -NewSessionHostsCount $hostPoolDecisions.PossibleDeploymentsCount -ExistingSessionHostNames $existingSessionHostNames
        
        # Update deployment state for progressive scale-up tracking
        if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
            $deploymentState = Get-DeploymentState
            
            # Save deployment info for checking on next run
            $deploymentState.LastDeploymentName = $deploymentResult.DeploymentName
            $deploymentState.LastDeploymentCount = $deploymentResult.SessionHostCount
            $deploymentState.LastDeploymentNeeded = $hostPoolDecisions.PossibleDeploymentsCount
            $deploymentState.LastDeploymentPercentage = if ($hostPoolDecisions.PossibleDeploymentsCount -gt 0) {
                [Math]::Round(($deploymentResult.SessionHostCount / $hostPoolDecisions.PossibleDeploymentsCount) * 100)
            }
            else { 0 }
            $deploymentState.LastTimestamp = Get-Date -AsUTC -Format 'o'
            
            Write-HostDetailed "Deployment submitted: $($deploymentResult.DeploymentName). Status will be checked on next run." -Level Host
            
            # Save state
            Save-DeploymentState -DeploymentState $deploymentState
        }
    }
    catch {
        Write-HostDetailed -Level Error "Deployment failed with error: $_"
        
        # Update state to reflect immediate failure (submission error) if progressive scale-up is enabled
        if ([bool]::Parse((Read-FunctionAppSetting EnableProgressiveScaleUp))) {
            $deploymentState = Get-DeploymentState
            $deploymentState.ConsecutiveSuccesses = 0
            $deploymentState.CurrentPercentage = [int]::Parse((Read-FunctionAppSetting InitialDeploymentPercentage))
            $deploymentState.LastStatus = 'Failed'
            $deploymentState.LastDeploymentName = '' # Clear deployment name since submission failed
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
    
    # Acquire Graph token if device cleanup is enabled
    if ($removeEntraDevice -or $removeIntuneDevice) {
        Try {
            $graphEndpoint = Get-GraphEndpoint
            $GraphToken = Get-AccessToken -ResourceUri $graphEndpoint -ClientId $UserAssignedIdentityClientId
            
            if ([string]::IsNullOrEmpty($GraphToken)) {
                Write-Warning "Get-AccessToken returned null or empty Graph token. Device cleanup will be skipped."
                Write-HostDetailed "HINT: Ensure the managed identity has Directory.ReadWrite.All (for Entra ID) and DeviceManagementManagedDevices.ReadWrite.All (for Intune) permissions" -Level Warning
                $GraphToken = $null
            }
        }
        catch {
            Write-Warning "Failed to acquire Graph access token: $_. Device cleanup will be skipped."
            Write-HostDetailed "HINT: Ensure the managed identity has Cloud Device Administrator role (for Entra ID) and DeviceManagementManagedDevices.ReadWrite.All (for Intune)" -Level Warning
            $GraphToken = $null
        }
    }
    If ($GraphToken) {
        Remove-SessionHosts -ARMToken $ARMToken -GraphToken $GraphToken -SessionHostsPendingDelete $hostPoolDecisions.SessionHostsPendingDelete -RemoveEntraDevice $removeEntraDevice -RemoveIntuneDevice $removeIntuneDevice
    }
    Else {
        Remove-SessionHosts -ARMToken $ARMToken -GraphToken $null -SessionHostsPendingDelete $hostPoolDecisions.SessionHostsPendingDelete -RemoveEntraDevice $false -RemoveIntuneDevice $false
    }
}
