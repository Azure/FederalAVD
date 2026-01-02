# Input bindings are passed in via param block.
param($Timer)

# Set host pool name for log prefixing
Set-HostPoolNameForLogging -HostPoolName (Read-FunctionAppSetting HostPoolName)

Write-HostDetailed -Message "SessionHostReplacer function started at {0}" -StringValues (Get-Date -AsUTC -Format 'o') -Level Host

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# Initialize environment-agnostic variables from Function App Configuration
$VirtualMachinesSubscriptionId = Read-FunctionAppSetting VirtualMachinesSubscriptionId
$UserAssignedIdentityClientId = Read-FunctionAppSetting UserAssignedIdentityClientId

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

# Get running and failed deployments
$deploymentsInfo = Get-RunningDeployments -ARMToken $ARMToken
$runningDeployments = $deploymentsInfo.RunningDeployments
$failedDeployments = $deploymentsInfo.FailedDeployments
Write-HostDetailed -Message "Found {0} running deployments and {1} failed deployments" -StringValues $runningDeployments.Count, $failedDeployments.Count -Level Verbose

# Handle failed deployments - mark VMs from failed deployments for deletion if they're in the host pool
if ($failedDeployments.Count -gt 0) {
    $failedDeploymentVMs = $failedDeployments.SessionHostNames | Select-Object -Unique
    $sessionHostsFromFailedDeployments = $sessionHostsFiltered | Where-Object { 
        $vmName = $_.SessionHostName
        $failedDeploymentVMs | Where-Object { $vmName -like "$_*" }
    }
    
    if ($sessionHostsFromFailedDeployments) {
        Write-HostDetailed -Message "Found {0} session hosts from failed deployments in the host pool: {1}" -StringValues $sessionHostsFromFailedDeployments.Count, ($sessionHostsFromFailedDeployments.SessionHostName -join ',') -Level Warning
        Write-HostDetailed -Message "These hosts will be marked for deletion and the failed deployment records should be cleaned up manually or will be handled automatically" -Level Warning
        
        # Tag these hosts for deletion by updating their IncludeInAutomation status
        # They'll be picked up in the normal deletion flow
        foreach ($sh in $sessionHostsFromFailedDeployments) {
            Write-HostDetailed -Message "Marking session host {0} from failed deployment for cleanup" -StringValues $sh.SessionHostName -Level Warning
        }
    }
}

# Load session host parameters
$sessionHostParameters = [hashtable]::new([System.StringComparer]::InvariantCultureIgnoreCase)
$sessionHostParameters += (Read-FunctionAppSetting SessionHostParameters)

# Get latest version of session host image
Write-HostDetailed -Message "Getting latest image version using Image Reference: {0}" -StringValues ($sessionHostParameters.ImageReference | Out-String) -Level Verbose
$latestImageVersion = Get-LatestImageVersion -ARMToken $ARMToken -ImageReference $sessionHostParameters.ImageReference -Location $sessionHostParameters.Location

# Get number session hosts to deploy
$hostPoolDecisions = Get-HostPoolDecisions -SessionHosts $sessionHostsFiltered -RunningDeployments $runningDeployments -FailedDeployments $failedDeployments -LatestImageVersion $latestImageVersion

# Check if we're starting a new update cycle and reset progressive scale-up if needed
if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
    $deploymentState = Get-DeploymentState
    $currentImageVersion = if ($latestImageVersion.Version) { $latestImageVersion.Version } else { "N/A" }
    $totalToReplace = if ($hostPoolDecisions.TotalSessionHostsToReplace) { $hostPoolDecisions.TotalSessionHostsToReplace } else { 0 }
    
    # Detect if we're starting a new update cycle
    $isNewCycle = $false
    $resetReason = ""
    
    # Check if image version changed
    if ($deploymentState.LastImageVersion -and $deploymentState.LastImageVersion -ne $currentImageVersion) {
        $isNewCycle = $true
        $resetReason = "Image version changed from $($deploymentState.LastImageVersion) to $currentImageVersion"
    }
    
    # Check if we completed the previous cycle (no hosts to replace) and now have new hosts to replace
    if ($deploymentState.LastTotalToReplace -eq 0 -and $totalToReplace -gt 0) {
        $isNewCycle = $true
        $resetReason = "Starting new update cycle with $totalToReplace hosts to replace (was 0)"
    }
    
    # Reset progressive scale-up for new cycle
    if ($isNewCycle) {
        Write-HostDetailed "Detected new update cycle: $resetReason" -Level Host
        Write-HostDetailed "Resetting progressive scale-up to initial percentage" -Level Host
        $deploymentState.ConsecutiveSuccesses = 0
        $deploymentState.CurrentPercentage = [int]::Parse((Read-FunctionAppSetting InitialDeploymentPercentage))
        $deploymentState.LastStatus = 'NewCycle'
        $deploymentState.LastDeploymentName = ''
        Save-DeploymentState -DeploymentState $deploymentState
    }
    
    # Update tracking values
    $deploymentState.LastImageVersion = $currentImageVersion
    $deploymentState.LastTotalToReplace = $totalToReplace
    Save-DeploymentState -DeploymentState $deploymentState
}

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
        Remove-SessionHosts -ARMToken $ARMToken -GraphToken $GraphToken -SessionHostsPendingDelete $hostPoolDecisions.SessionHostsPendingDelete -RemoveEntraDevice $removeEntraDevice -RemoveIntuneDevice $removeIntuneDevice -ClientId $UserAssignedIdentityClientId
    }
    Else {
        Remove-SessionHosts -ARMToken $ARMToken -GraphToken $null -SessionHostsPendingDelete $hostPoolDecisions.SessionHostsPendingDelete -RemoveEntraDevice $false -RemoveIntuneDevice $false
    }
}

# Log schedule information for workbook visibility
if ($Timer.ScheduleStatus) {
    $nextRun = if ($Timer.ScheduleStatus.Next) { $Timer.ScheduleStatus.Next.ToString('o') } else { "Not available" }
    Write-HostDetailed -Message "SCHEDULE | Next scheduled run: {0}" -StringValues $nextRun -Level Host
}
