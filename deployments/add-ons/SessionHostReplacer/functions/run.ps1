# Input bindings are passed in via param block.
param($Timer)

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

Write-LogEntry -Message "SessionHostReplacer function started at {0}" -StringValues (Get-Date -AsUTC -Format 'o')

# Log configuration settings for workbook visibility
$enableShutdownRetention = Read-FunctionAppSetting EnableShutdownRetention -AsBoolean
$replacementMode = Read-FunctionAppSetting ReplacementMode
$minimumDrainMinutes = Read-FunctionAppSetting MinimumDrainMinutes
$drainGracePeriodHours = Read-FunctionAppSetting DrainGracePeriodHours
$minimumCapacityPercentage = Read-FunctionAppSetting MinimumCapacityPercentage
$maxDeletionsPerCycle = Read-FunctionAppSetting MaxDeletionsPerCycle
$enableProgressiveScaleUp = Read-FunctionAppSetting EnableProgressiveScaleUp -AsBoolean
$initialDeploymentPercentage = Read-FunctionAppSetting InitialDeploymentPercentage
$scaleUpIncrementPercentage = Read-FunctionAppSetting ScaleUpIncrementPercentage
$successfulRunsBeforeScaleUp = Read-FunctionAppSetting SuccessfulRunsBeforeScaleUp
$maxDeploymentBatchSize = Read-FunctionAppSetting MaxDeploymentBatchSize
$minimumHostIndex = Read-FunctionAppSetting MinimumHostIndex
$shutdownRetentionDays = Read-FunctionAppSetting ShutdownRetentionDays
$targetSessionHostCount = Read-FunctionAppSetting TargetSessionHostCount
$enableProgressiveScaleUp = Read-FunctionAppSetting EnableProgressiveScaleUp -AsBoolean
$removeEntraDevice = Read-FunctionAppSetting RemoveEntraDevice -AsBoolean
$removeIntuneDevice = Read-FunctionAppSetting RemoveIntuneDevice -AsBoolean

# Build settings log with N/A for non-applicable values based on replacement mode
$settingsLog = @{
    ReplacementMode             = $replacementMode
    MinimumDrainMinutes         = $minimumDrainMinutes
    DrainGracePeriodHours       = $drainGracePeriodHours
    MinimumCapacityPercent      = if ($replacementMode -eq 'DeleteFirst') { "$minimumCapacityPercentage (static)" } else { 'N/A' }
    MaxDeletionsPerCycle        = if ($replacementMode -eq 'DeleteFirst') { $maxDeletionsPerCycle } else { 'N/A' }
    EnableProgressiveScaleUp    = $enableProgressiveScaleUp
    InitialDeploymentPercent    = if ($enableProgressiveScaleUp) { $initialDeploymentPercentage } else { 'N/A' }
    ScaleUpIncrementPercent     = if ($enableProgressiveScaleUp) { $scaleUpIncrementPercentage } else { 'N/A' }
    SuccessfulRunsBeforeScaleUp = if ($enableProgressiveScaleUp) { $successfulRunsBeforeScaleUp } else { 'N/A' }
    MaxDeploymentBatchSize      = if ($replacementMode -eq 'SideBySide') { $maxDeploymentBatchSize } else { 'N/A' }
    MinimumHostIndex            = $minimumHostIndex
    EnableShutdownRetention     = if ($replacementMode -eq 'SideBySide') { $enableShutdownRetention } else { 'N/A' }
    ShutdownRetentionDays       = if ($replacementMode -eq 'SideBySide' -and $enableShutdownRetention -eq 'True') { $shutdownRetentionDays } else { 'N/A' }
    TargetSessionHostCount      = if ($targetSessionHostCount -eq 0) { 'Auto' } else { $targetSessionHostCount }
    DynamicCapacityEnabled      = if ($replacementMode -eq 'DeleteFirst') { 'Yes' } else { 'N/A' }
}

Write-LogEntry -Message "SETTINGS | ReplacementMode: {0} | MinimumDrainMinutes: {1} | DrainGracePeriodHours: {2} | MinimumCapacityPercent: {3} | MaxDeletionsPerCycle: {4} | EnableProgressiveScaleUp: {5} | InitialDeploymentPercent: {6} | ScaleUpIncrementPercent: {7} | SuccessfulRunsBeforeScaleUp: {8} | MaxDeploymentBatchSize: {9} | MinimumHostIndex: {10} | EnableShutdownRetention: {11} | ShutdownRetentionDays: {12} | TargetSessionHostCount: {13} | DynamicCapacity: {14}" -StringValues $settingsLog.ReplacementMode, $settingsLog.MinimumDrainMinutes, $settingsLog.DrainGracePeriodHours, $settingsLog.MinimumCapacityPercent, $settingsLog.MaxDeletionsPerCycle, $settingsLog.EnableProgressiveScaleUp, $settingsLog.InitialDeploymentPercent, $settingsLog.ScaleUpIncrementPercent, $settingsLog.SuccessfulRunsBeforeScaleUp, $settingsLog.MaxDeploymentBatchSize, $settingsLog.MinimumHostIndex, $settingsLog.EnableShutdownRetention, $settingsLog.ShutdownRetentionDays, $settingsLog.TargetSessionHostCount, $settingsLog.DynamicCapacityEnabled

# Acquire ARM access token
try {
    $ARMToken = Get-AccessToken -ResourceUri (Get-ResourceManagerUri)
    if ([string]::IsNullOrEmpty($ARMToken)) {
        throw "Get-AccessToken returned null or empty token"
    }
}
catch {
    Write-Error "Failed to acquire ARM access token: $_"
    Write-LogEntry -Message "Token acquisition error details: {0}" -StringValues $_.Exception.Message
    throw
}

# Fetch ALL VMs in the resource group once to avoid redundant queries throughout the run
# Power state will be queried lazily for deletion candidates only
Write-LogEntry -Message "Fetching all VMs in resource group for caching"
$virtualMachinesSubscriptionId = Read-FunctionAppSetting VirtualMachinesSubscriptionId
$virtualMachinesResourceGroupName = Read-FunctionAppSetting VirtualMachinesResourceGroupName
$resourceManagerUri = Get-ResourceManagerUri
$Uri = "$resourceManagerUri/subscriptions/$virtualMachinesSubscriptionId/resourceGroups/$virtualMachinesResourceGroupName/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01"
$cachedVMs = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
Write-LogEntry -Message "Cached {0} VMs from resource group" -StringValues $cachedVMs.Count

# Check for and cleanup expired shutdown VMs BEFORE fetching session hosts (so the list is already clean)
if ($enableShutdownRetention) {
    Write-LogEntry -Message "Shutdown retention is enabled - checking for expired shutdown VMs"
    
    # Acquire Graph token for device cleanup if enabled
    $GraphToken = $null
    
    if ($removeEntraDevice -or $removeIntuneDevice) {
        try {
            $graphEndpoint = Get-GraphEndpoint
            $GraphToken = Get-AccessToken -ResourceUri $graphEndpoint
            
            if ([string]::IsNullOrEmpty($GraphToken)) {
                Write-LogEntry -Message "Warning: Could not acquire Graph token for device cleanup" -Level Warning
            }
        }
        catch {
            Write-LogEntry -Message "Warning: Failed to acquire Graph token for device cleanup: $_" -Level Warning
        }
    }
    
    # Cleanup expired shutdown VMs
    $cleanupResults = Remove-ExpiredShutdownVMs -ARMToken $ARMToken -GraphToken $GraphToken -CachedVMs $cachedVMs
    
    if ($cleanupResults.CleanedUpCount -gt 0) {
        Write-LogEntry -Message "Cleaned up {0} expired shutdown VM(s)" -StringValues $cleanupResults.CleanedUpCount
        
        # Remove deleted VMs from cache (more efficient than re-querying all VMs)
        if ($cleanupResults.DeletedVMNames -and $cleanupResults.DeletedVMNames.Count -gt 0) {
            Write-LogEntry -Message "Removing {0} deleted VM(s) from cache" -StringValues $cleanupResults.DeletedVMNames.Count -Level Trace
            $cachedVMs = $cachedVMs | Where-Object { $_.name -notin $cleanupResults.DeletedVMNames }
            Write-LogEntry -Message "Cache updated: {0} VMs remaining" -StringValues $cachedVMs.Count -Level Trace
        }
    }
}

# Get session hosts and update tags if needed (pass cached VMs)
$sessionHosts = Get-SessionHosts -ARMToken $ARMToken -CachedVMs $cachedVMs
Write-LogEntry -Message "Found {0} session hosts" -StringValues $sessionHosts.Count

# Check previous deployment status and pending host mappings
$previousDeploymentStatus = $null

# Get deployment state if needed (for progressive scale-up OR DeleteFirst mode)
if ($enableProgressiveScaleUp -or $replacementMode -eq 'DeleteFirst') {
    $deploymentState = Get-DeploymentState
    
    if (-not [string]::IsNullOrEmpty($deploymentState.LastDeploymentName)) {
        Write-LogEntry -Message "Checking status of previous deployment: {0}" -StringValues $deploymentState.LastDeploymentName
        $previousDeploymentStatus = Get-LastDeploymentStatus -DeploymentName $deploymentState.LastDeploymentName -ARMToken $ARMToken
        
        if ($previousDeploymentStatus) {
            if ($previousDeploymentStatus.Succeeded) {
                # Verify hosts from pending mappings actually registered before counting as success (DeleteFirst mode)
                $allHostsRegistered = $true
                if ($replacementMode -eq 'DeleteFirst' -and $deploymentState.PendingHostMappings -and $deploymentState.PendingHostMappings -ne '{}') {
                    $pendingMappings = $deploymentState.PendingHostMappings | ConvertFrom-Json
                    $expectedHostNames = $pendingMappings.PSObject.Properties.Name
                    $registeredHostNames = $sessionHosts.SessionHostName
                    $missingHosts = $expectedHostNames | Where-Object { $_ -notin $registeredHostNames }
                    
                    if ($missingHosts.Count -eq 0) {
                        Write-LogEntry -Message "All {0} pending host(s) successfully registered - clearing mappings" -StringValues $expectedHostNames.Count -Level Trace
                        $deploymentState.PendingHostMappings = '{}'
                        $allHostsRegistered = $true
                    }
                    else {
                        Write-LogEntry -Message "Deployment succeeded but {0} host(s) not yet registered: {1} - keeping mappings and NOT counting as successful run" -StringValues $missingHosts.Count, ($missingHosts -join ', ') -Level Warning
                        $allHostsRegistered = $false
                        # Keep mappings and don't increment success counter - hosts may still be registering or there may be a registration issue
                    }
                }
                
                # Only increment consecutive successes and update scale-up percentage if progressive scale-up is enabled AND hosts registered
                if ($enableProgressiveScaleUp) {
                    if ($allHostsRegistered) {
                        $deploymentState.ConsecutiveSuccesses++
                        $deploymentState.LastStatus = 'Success'
                        
                        # Calculate next percentage
                        $successfulRunsBeforeScaleUp = (Read-FunctionAppSetting SuccessfulRunsBeforeScaleUp)
                        $scaleUpIncrementPercentage = (Read-FunctionAppSetting ScaleUpIncrementPercentage)
                        $initialDeploymentPercentage = (Read-FunctionAppSetting InitialDeploymentPercentage)
                        
                        $scaleUpMultiplier = [Math]::Floor($deploymentState.ConsecutiveSuccesses / $successfulRunsBeforeScaleUp)
                        $deploymentState.CurrentPercentage = [Math]::Min(
                            $initialDeploymentPercentage + ($scaleUpMultiplier * $scaleUpIncrementPercentage),
                            100
                        )                
                        Write-LogEntry -Message "Previous deployment succeeded with all hosts registered. ConsecutiveSuccesses: $($deploymentState.ConsecutiveSuccesses), CurrentPercentage: $($deploymentState.CurrentPercentage)%"
                    }
                    else {
                        # Deployment succeeded but hosts didn't register - don't count as success or scale up
                        $deploymentState.LastStatus = 'PendingRegistration'
                        Write-LogEntry -Message "Deployment succeeded but hosts not yet registered - NOT incrementing success counter or scaling up" -Level Warning
                    }
                }
                elseif ($allHostsRegistered) {
                    # Progressive scale-up disabled, but still track success for DeleteFirst mode
                    $deploymentState.LastStatus = 'Success'
                    Write-LogEntry -Message "Previous deployment succeeded with all hosts registered (progressive scale-up disabled)"
                }
            }
            elseif ($previousDeploymentStatus.Failed) {
                Write-LogEntry -Message "Previous deployment failed. Cleaning up partial resources before redeployment." -Level Warning
                
                # Acquire Graph token for device cleanup if enabled
                $GraphToken = $null
                
                if ($removeEntraDevice -or $removeIntuneDevice) {
                    try {
                        $graphEndpoint = Get-GraphEndpoint
                        $GraphToken = Get-AccessToken -ResourceUri $graphEndpoint
                        
                        if ([string]::IsNullOrEmpty($GraphToken)) {
                            Write-LogEntry -Message "Warning: Could not acquire Graph token for device cleanup" -Level Warning
                        }
                    }
                    catch {
                        Write-LogEntry -Message "Warning: Failed to acquire Graph token for device cleanup: $_" -Level Warning
                    }
                }
                
                # Clean up the failed deployment and its partial resources
                $failedDeploymentInfo = @([PSCustomObject]@{
                        DeploymentName = $deploymentState.LastDeploymentName
                    })
                
                try {
                    Remove-FailedDeploymentArtifacts -ARMToken $ARMToken -GraphToken $GraphToken -FailedDeployments $failedDeploymentInfo -RegisteredSessionHostNames $sessionHosts.SessionHostName -RemoveEntraDevice $removeEntraDevice -RemoveIntuneDevice $removeIntuneDevice -CachedVMs $cachedVMs
                    Write-LogEntry -Message "Completed cleanup of failed deployment artifacts"
                }
                catch {
                    Write-LogEntry -Message "Error during failed deployment cleanup: $_" -Level Error
                }
                
                # DO NOT clear pending host mappings - those hosts still need deployment after cleanup
                # PendingHostMappings will persist until deployment succeeds and VMs register
                Write-LogEntry -Message "Keeping {0} pending host mapping(s) for retry after cleanup" -StringValues (($deploymentState.PendingHostMappings | ConvertFrom-Json).Count) -Level Trace
                
                # Reset progressive scale-up on failure (if enabled)
                if ($enableProgressiveScaleUp) {
                    $deploymentState.ConsecutiveSuccesses = 0
                    $initialDeploymentPercentage = (Read-FunctionAppSetting InitialDeploymentPercentage)
                    $deploymentState.CurrentPercentage = $initialDeploymentPercentage
                    Write-LogEntry -Message "Reset consecutive successes to 0, CurrentPercentage: $($deploymentState.CurrentPercentage)%" -Level Warning
                }
                $deploymentState.LastStatus = 'Failed'
            }
            elseif ($previousDeploymentStatus.Running) {
                Write-LogEntry -Message "Previous deployment is still running. Will check again on next run." -Level Warning
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
Write-LogEntry -Message "Filtered to {0} session hosts enabled for automatic replacement: {1}" -StringValues $sessionHostsFiltered.Count, ($sessionHostsFiltered.SessionHostName -join ',')

# Further filter out VMs that are already in shutdown retention (to avoid redundant shutdown operations)
if ($enableShutdownRetention) {
    $shutdownRetentionTag = Read-FunctionAppSetting Tag_ShutdownTimestamp
    $hostsInShutdownRetention = @()
    
    Write-LogEntry -Message "Checking for session hosts already in shutdown retention using tag: $shutdownRetentionTag" -Level Trace
    
    foreach ($sessionHost in $sessionHostsFiltered) {
        $vmName = $sessionHost.ResourceId.Split('/')[-1]
        $vm = $cachedVMs | Where-Object { $_.name -eq $vmName } | Select-Object -First 1
        
        if ($vm) {
            $hasRetentionTag = $vm.tags -and ($vm.tags.PSObject.Properties.Name -contains $shutdownRetentionTag)
            Write-LogEntry -Message "VM ${vmName}: Has tags=$($null -ne $vm.tags), Has retention tag=$hasRetentionTag" -Level Trace
            
            if ($hasRetentionTag) {
                $hostsInShutdownRetention += $sessionHost
                Write-LogEntry -Message "VM $vmName is in shutdown retention - will exclude from replacement processing" -Level Trace
            }
        }
        else {
            Write-LogEntry -Message "VM $vmName not found in cached VMs" -Level Trace
        }
    }
    
    if ($hostsInShutdownRetention.Count -gt 0) {
        $shutdownRetentionNames = $hostsInShutdownRetention.SessionHostName -join ', '
        Write-LogEntry -Message "Excluding {0} session host(s) already in shutdown retention from replacement processing: {1}" -StringValues $hostsInShutdownRetention.Count, $shutdownRetentionNames
        $sessionHostsFiltered = $sessionHostsFiltered | Where-Object { $_.SessionHostName -notin $hostsInShutdownRetention.SessionHostName }
    }
    else {
        Write-LogEntry -Message "No session hosts found in shutdown retention" -Level Trace
    }
}

# Get running and failed deployments
$deploymentsInfo = Get-Deployments -ARMToken $ARMToken
$runningDeployments = $deploymentsInfo.RunningDeployments
$failedDeployments = $deploymentsInfo.FailedDeployments
Write-LogEntry -Message "Found {0} running deployments and {1} failed deployments" -StringValues $runningDeployments.Count, $failedDeployments.Count

# Clean up failed deployments and orphaned VMs
if ($failedDeployments.Count -gt 0) {
    Write-LogEntry -Message "Processing {0} failed deployments for cleanup" -StringValues $failedDeployments.Count
    Remove-FailedDeploymentArtifacts -ARMToken $ARMToken -FailedDeployments $failedDeployments -RegisteredSessionHostNames $sessionHostsFiltered.SessionHostName -CachedVMs $cachedVMs
}

# Load session host parameters
$sessionHostParameters = [hashtable]::new([System.StringComparer]::InvariantCultureIgnoreCase)
$sessionHostParameters += (Read-FunctionAppSetting SessionHostParameters)

# Get latest version of session host image
Write-LogEntry -Message "Getting latest image version using Image Reference."
$latestImageVersion = Get-LatestImageVersion -ARMToken $ARMToken -ImageReference $sessionHostParameters.ImageReference -Location $sessionHostParameters.Location

# Read AllowImageVersionRollback setting with default of false
$allowImageVersionRollback = Read-FunctionAppSetting AllowImageVersionRollback -AsBoolean

# CRITICAL: Check if we're starting a new update cycle and reset progressive scale-up if needed
# This MUST happen BEFORE Get-SessionHostReplacementPlan so the reset state is used
if (Read-FunctionAppSetting EnableProgressiveScaleUp -AsBoolean) {
    $deploymentState = Get-DeploymentState
    $currentImageVersion = if ($latestImageVersion.Version) { $latestImageVersion.Version } else { 'N/A' }
    
    # Log current state for debugging
    $lastToReplace = if ($null -eq $deploymentState.LastImageVersion) { 0 } else { $deploymentState.LastTotalToReplace }
    Write-LogEntry -Message "New cycle detection - Current: ImageVersion='$currentImageVersion', LastTotalToReplace=$lastToReplace"
    Write-LogEntry -Message "New cycle detection - Previous: LastImageVersion='$($deploymentState.LastImageVersion)' (IsNull: $($null -eq $deploymentState.LastImageVersion)), LastStatus='$($deploymentState.LastStatus)'"
    
    # Check if image version changed AND we were previously up to date (not already in a cycle)
    # This prevents repeatedly triggering new cycle on every run while hosts are still being replaced
    # Treat null/missing LastTotalToReplace as 0 (up to date) for backward compatibility
    
    # Evaluate each condition separately for visibility
    $hasLastImageVersion = -not [string]::IsNullOrEmpty($deploymentState.LastImageVersion)
    $imageVersionChanged = $deploymentState.LastImageVersion -ne $currentImageVersion
    $currentVersionValid = $currentImageVersion -ne "N/A"
    $wasUpToDate = $lastToReplace -eq 0
    
    Write-LogEntry -Message "New cycle detection conditions - HasLastImageVersion: $hasLastImageVersion, ImageVersionChanged: $imageVersionChanged, CurrentVersionValid: $currentVersionValid, WasUpToDate: $wasUpToDate"
    
    if ($hasLastImageVersion -and $imageVersionChanged -and $currentVersionValid -and $wasUpToDate) {
        Write-LogEntry -Message "New cycle detection - Image version changed from $($deploymentState.LastImageVersion) to $currentImageVersion (was previously up to date)"
        Write-LogEntry -Message "Resetting progressive scale-up to initial percentage"
        $deploymentState.ConsecutiveSuccesses = 0
        $deploymentState.CurrentPercentage = (Read-FunctionAppSetting InitialDeploymentPercentage)
        $deploymentState.LastStatus = 'NewCycle'
        $deploymentState.LastDeploymentName = ''
        # Update LastImageVersion immediately so we don't trigger new cycle on every subsequent run
        $deploymentState.LastImageVersion = $currentImageVersion
        Save-DeploymentState -DeploymentState $deploymentState
    }
    else {
        Write-LogEntry -Message "New cycle detection - Conditions not met, no new cycle triggered" -Level Trace
    }
}

# OPTIMIZATION: Lightweight pre-check to determine if host pool is up to date
# This avoids expensive operations (scaling plan query, full replacement plan calculation) when no work is needed
Write-LogEntry -Message "Performing lightweight up-to-date check" -Level Trace

$isUpToDate = $false
$replaceSessionHostOnNewImageVersionDelayDays = (Read-FunctionAppSetting ReplaceSessionHostOnNewImageVersionDelayDays)
$latestImageAge = (New-TimeSpan -Start $latestImageVersion.Date -End (Get-Date -AsUTC)).TotalDays

# Check for work in progress that requires full processing
$skipLightweightCheck = $false

# DeleteFirst mode: Check for pending host mappings or hosts in drain mode
if ($replacementMode -eq 'DeleteFirst') {
    $deploymentState = Get-DeploymentState
    $hasPendingMappings = $deploymentState.PendingHostMappings -and $deploymentState.PendingHostMappings -ne '{}'
    
    if ($hasPendingMappings) {
        Write-LogEntry -Message "Lightweight check: Found pending host mappings from previous deletion - proceeding with full processing" -Level Trace
        $skipLightweightCheck = $true
    }
    # Check if there are hosts in drain mode (work in progress)
    elseif (($sessionHostsFiltered | Where-Object { -not $_.AllowNewSession }).Count -gt 0) {
        $hostsInDrainMode = ($sessionHostsFiltered | Where-Object { -not $_.AllowNewSession }).Count
        Write-LogEntry -Message "Lightweight check: Found $hostsInDrainMode host(s) in drain mode - proceeding with full processing" -Level Trace
        $skipLightweightCheck = $true
    }
}

# Check if there are any running or failed deployments (both modes)
if ($runningDeployments.Count -gt 0 -or $failedDeployments.Count -gt 0) {
    Write-LogEntry -Message "Lightweight check: Found $($runningDeployments.Count) running and $($failedDeployments.Count) failed deployments - proceeding with full processing" -Level Trace
    $skipLightweightCheck = $true
}

# If no work in progress, perform quick image version check
if (-not $skipLightweightCheck) {
    # Check if image is old enough to trigger replacements
    if ($latestImageAge -ge $replaceSessionHostOnNewImageVersionDelayDays) {
        
        # Quick version comparison - check if all hosts are on latest version
        $hostsNeedingReplacement = 0
        foreach ($sh in $sessionHostsFiltered) {
            if ($sh.ImageVersion -ne $latestImageVersion.Version) {
                # Check if image definition changed (not a rollback scenario)
                $imageDefinitionChanged = $false
                if ($sh.ImageDefinition -and $latestImageVersion.Definition) {
                    $imageDefinitionChanged = ($sh.ImageDefinition -ne $latestImageVersion.Definition)
                }
                
                if ($imageDefinitionChanged) {
                    # Image definition changed - needs replacement
                    $hostsNeedingReplacement++
                    break  # Found at least one, no need to check more
                }
                else {
                    # Same image definition, check version comparison
                    $versionComparison = Compare-ImageVersion -Version1 $sh.ImageVersion -Version2 $latestImageVersion.Version
                    
                    if ($versionComparison -lt 0) {
                        # VM version is older - needs replacement
                        $hostsNeedingReplacement++
                        break  # Found at least one, no need to check more
                    }
                    elseif ($versionComparison -gt 0 -and $allowImageVersionRollback) {
                        # VM version is newer but rollback is allowed - needs replacement
                        $hostsNeedingReplacement++
                        break  # Found at least one, no need to check more
                    }
                }
            }
        }
        
        if ($hostsNeedingReplacement -eq 0) {
            $isUpToDate = $true
            Write-LogEntry -Message "Lightweight check: All session hosts are on latest image version $($latestImageVersion.Version)" -Level Trace
        }
        else {
            Write-LogEntry -Message "Lightweight check: Found hosts needing replacement - proceeding with full replacement plan" -Level Trace
        }
    }
    else {
        # Image is too new - no replacements will be triggered
        $isUpToDate = $true
        Write-LogEntry -Message "Lightweight check: Latest image is only $([Math]::Round($latestImageAge, 1)) days old (delay: $replaceSessionHostOnNewImageVersionDelayDays days) - no replacements needed" -Level Trace
    }
}

# If up to date, skip expensive operations and go straight to early exit path
if ($isUpToDate) {
    Write-LogEntry -Message "Host pool is UP TO DATE - skipping replacement plan calculation and scaling plan query"
    
    # Create a minimal replacement plan for early exit logic
    $hostPoolReplacementPlan = [PSCustomObject]@{
        PossibleDeploymentsCount       = 0
        PossibleSessionHostDeleteCount = 0
        SessionHostsPendingDelete      = @()
        ExistingSessionHostNames       = $sessionHostsFiltered.SessionHostName
        TargetSessionHostCount         = $sessionHostsFiltered.Count
        TotalSessionHostsToReplace     = 0
    }
    
    # Skip scaling plan query (not needed when up to date)
    $scalingPlanTarget = $null
}
else {
    # Host pool needs work - run full replacement plan calculation
    Write-LogEntry -Message "Host pool requires updates - running full replacement plan calculation"
    
    # Query scaling plan for dynamic minimum capacity (DeleteFirst mode only)
    # This is ONLY needed when we're actually going to delete hosts
    $scalingPlanTarget = $null
    if ($replacementMode -ieq 'DeleteFirst') {
        try {
            $hostPoolSubscriptionId = Read-FunctionAppSetting HostPoolSubscriptionId
            $hostPoolResourceGroupName = Read-FunctionAppSetting HostPoolResourceGroupName
            $hostPoolName = Read-FunctionAppSetting HostPoolName
            $hostPoolResourceId = "/subscriptions/$hostPoolSubscriptionId/resourceGroups/$hostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$hostPoolName"
            
            Write-LogEntry -Message "DeleteFirst mode: Querying scaling plan for dynamic minimum capacity target"
            $scalingPlanTarget = Get-ScalingPlanCurrentTarget -ARMToken $ARMToken -HostPoolResourceId $hostPoolResourceId
            
            if ($scalingPlanTarget -and $scalingPlanTarget.CapacityPercentage) {
                Write-LogEntry -Message "Dynamic capacity from scaling plan: $($scalingPlanTarget.CapacityPercentage)% (Plan: $($scalingPlanTarget.ScalingPlanName), Schedule: $($scalingPlanTarget.ScheduleName), Phase: $($scalingPlanTarget.Phase))"
            }
            else {
                Write-LogEntry -Message "No active scaling plan schedule found - will use static MinimumCapacityPercentage setting"
            }
        }
        catch {
            Write-LogEntry -Message "Failed to query scaling plan (will use static capacity): $($_.Exception.Message)" -Level Warning
            $scalingPlanTarget = $null
        }
    }
    
    # Get full replacement plan with all calculations
    $hostPoolReplacementPlan = Get-SessionHostReplacementPlan `
        -ARMToken $ARMToken `
        -SessionHosts $sessionHostsFiltered `
        -RunningDeployments $runningDeployments `
        -LatestImageVersion $latestImageVersion `
        -AllowImageVersionRollback $allowImageVersionRollback `
        -ScalingPlanTarget $scalingPlanTarget `
        -GraphToken $GraphToken `
        -RemoveEntraDevice $removeEntraDevice `
        -RemoveIntuneDevice $removeIntuneDevice
}

# EARLY EXIT: Check if host pool is up to date (nothing to do)
if ($hostPoolReplacementPlan.TotalSessionHostsToReplace -eq 0 -and 
    $hostPoolReplacementPlan.PossibleDeploymentsCount -eq 0 -and 
    $hostPoolReplacementPlan.PossibleSessionHostDeleteCount -eq 0 -and
    $runningDeployments.Count -eq 0 -and
    $failedDeployments.Count -eq 0) {
    
    Write-LogEntry -Message "Host pool is UP TO DATE - all session hosts are on the latest image version and no work is needed."
    
    # Update LastImageVersion now that the cycle is complete
    if (Read-FunctionAppSetting EnableProgressiveScaleUp -AsBoolean) {
        $deploymentState = Get-DeploymentState
        $currentImageVersion = if ($latestImageVersion.Version) { $latestImageVersion.Version } else { 'N/A' }
        
        # Only update if it changed (to avoid unnecessary writes)
        if ($deploymentState.LastImageVersion -ne $currentImageVersion) {
            Write-LogEntry -Message "Cycle complete - updating LastImageVersion from $($deploymentState.LastImageVersion) to $currentImageVersion" -Level Trace
            $deploymentState.LastImageVersion = $currentImageVersion
            Save-DeploymentState -DeploymentState $deploymentState
        }
    }
    
    # CRITICAL: Check if scaling exclusion tags need to be removed before exiting
    # This handles the case where tags were set in a previous run but the cycle just completed
    $hostsInDrainMode = ($sessionHostsFiltered | Where-Object { -not $_.AllowNewSession }).Count
    $shutdownRetentionCount = if ($enableShutdownRetention -and $hostsInShutdownRetention) { $hostsInShutdownRetention.Count } else { 0 }
    
    # Check if cycle is truly complete (no hosts in drain mode)
    $cycleComplete = $hostsInDrainMode -eq 0
    
    # In SideBySide mode with shutdown retention: also remove tags from new hosts if old hosts are in retention
    $sideBySideRetentionTransition = $replacementMode -eq 'SideBySide' -and $enableShutdownRetention -and $shutdownRetentionCount -gt 0
    
    if ($cycleComplete -or $sideBySideRetentionTransition) {
        if ($cycleComplete) {
            Write-LogEntry -Message "Update cycle complete - removing scaling exclusion tags (preserving tags on shutdown retention VMs)."
        }
        else {
            Write-LogEntry -Message "SideBySide mode with shutdown retention - removing scaling exclusion tags from new active hosts."
        }
        
        $tagScalingPlanExclusionTag = Read-FunctionAppSetting Tag_ScalingPlanExclusionTag
        $resourceManagerUri = Get-ResourceManagerUri
        
        # Get list of VMs currently in shutdown retention
        $shutdownRetentionVMs = @()
        if ($enableShutdownRetention) {
            $shutdownRetentionTag = Read-FunctionAppSetting Tag_ShutdownTimestamp
            foreach ($vm in $cachedVMs) {
                if ($vm.tags -and ($vm.tags.PSObject.Properties.Name -contains $shutdownRetentionTag)) {
                    $shutdownRetentionVMs += $vm.name
                }
            }
        }
        
        # Only proceed if a scaling exclusion tag is configured
        if ($tagScalingPlanExclusionTag -and $tagScalingPlanExclusionTag -ne ' ') {
            $hostsWithExclusionTag = 0
            
            foreach ($sessionHost in $sessionHostsFiltered) {
                try {
                    $vmName = $sessionHost.ResourceId.Split('/')[-1]
                    
                    # Skip if this VM is in shutdown retention
                    if ($shutdownRetentionVMs -contains $vmName) {
                        Write-LogEntry -Message "Preserving scaling exclusion tag on shutdown retention VM: $vmName" -Level Trace
                        continue
                    }
                    
                    # Check if exclusion tag exists with SessionHostReplacer value
                    $vmTags = $sessionHost.Tags
                    if ($vmTags.ContainsKey($tagScalingPlanExclusionTag) -and $vmTags[$tagScalingPlanExclusionTag] -eq 'SessionHostReplacer') {
                        Write-LogEntry -Message "Removing scaling exclusion tag from $($sessionHost.SessionHostName)" -Level Trace
                        
                        $tagsUri = "$resourceManagerUri$($sessionHost.ResourceId)/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
                        $Body = @{
                            operation  = 'Delete'
                            properties = @{
                                tags = @{ $tagScalingPlanExclusionTag = '' }
                            }
                        }
                        
                        Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $tagsUri | Out-Null
                        $hostsWithExclusionTag++
                    }
                }
                catch {
                    Write-LogEntry -Message "Error removing scaling exclusion tag from $($sessionHost.SessionHostName): $($_.Exception.Message)" -Level Warning
                }
            }
            
            if ($hostsWithExclusionTag -gt 0) {
                Write-LogEntry -Message "Removed scaling exclusion tags from {0} session host(s)" -StringValues $hostsWithExclusionTag
            }
        }
    }
    
    # Log basic metrics for monitoring dashboard
    $metricsLog = @{
        TotalSessionHosts    = $sessionHosts.Count
        EnabledForAutomation = $sessionHostsFiltered.Count
        TargetCount          = if ($hostPoolReplacementPlan.TargetSessionHostCount) { $hostPoolReplacementPlan.TargetSessionHostCount } else { 0 }
        ToReplace            = 0
        ToReplacePercentage  = 0
        InDrain              = $hostsInDrainMode
        PendingDelete        = 0
        ShutdownRetention    = $shutdownRetentionCount
        ToDeployNow          = 0
        RunningDeployments   = 0
        LatestImageVersion   = if ($latestImageVersion.Version) { $latestImageVersion.Version } else { "N/A" }
        LatestImageDate      = $latestImageVersion.Date
        Status               = if ($cycleComplete) { "UpToDate" } else { "Draining" }
    }
    
    # Log image metadata for workbook visibility
    if ($latestImageVersion.Definition -like "marketplace:*") {
        $marketplaceParts = $latestImageVersion.Definition -replace "^marketplace:", "" -split "/"
        Write-LogEntry -Message "IMAGE_INFO | Type: Marketplace | Publisher: {0} | Offer: {1} | Sku: {2} | Version: {3}" `
            -StringValues $marketplaceParts[0], $marketplaceParts[1], $marketplaceParts[2], $latestImageVersion.Version
    }
    else {
        $galleryMatch = [regex]::Match($latestImageVersion.Definition, "/galleries/([^/]+)/images/([^/]+)")
        $galleryName = $galleryMatch.Groups[1].Value
        $imageDefinition = $galleryMatch.Groups[2].Value
        Write-LogEntry -Message "IMAGE_INFO | Type: Gallery | Gallery: {0} | ImageDefinition: {1} | Version: {2}" `
            -StringValues $galleryName, $imageDefinition, $latestImageVersion.Version
    }
    
    Write-LogEntry -Message "METRICS | Total: {0} | Enabled: {1} | Target: {2} | ToReplace: {3} ({4}%) | InDrain: {5} | PendingDelete: {6} | ShutdownRetention: {7} | ToDeployNow: {8} | RunningDeployments: {9} | LatestImage: {10} | Status: {11}" `
        -StringValues $metricsLog.TotalSessionHosts, $metricsLog.EnabledForAutomation, $metricsLog.TargetCount, $metricsLog.ToReplace, $metricsLog.ToReplacePercentage, $metricsLog.InDrain, $metricsLog.PendingDelete, $metricsLog.ShutdownRetention, $metricsLog.ToDeployNow, $metricsLog.RunningDeployments, $metricsLog.LatestImageVersion, $metricsLog.Status
    
    # Update host pool status tag with current state
    try {
        Update-HostPoolStatus `
            -ARMToken $ARMToken `
            -SessionHosts $sessionHostsFiltered `
            -RunningDeployments 0 `
            -FailedDeployments @() `
            -HostsToReplace 0 `
            -CachedVMs $cachedVMs
    }
    catch {
        Write-LogEntry -Message "Failed to update host pool status tag: $($_.Exception.Message)" -Level Warning
    }
    
    # Log completion timestamp for workbook visibility
    Write-LogEntry -Message "SCHEDULE | Function execution completed at: {0}" -StringValues (Get-Date -AsUTC -Format 'o')
    Write-LogEntry -Message "SessionHostReplacer function completed - host pool is up to date"
    
    return
}

# Host pool needs work - continue with normal processing
Write-LogEntry -Message "Host pool requires updates - proceeding with replacement operations"

# Check availability of new session hosts (hosts already on the latest image version)
# This provides metrics for monitoring and is used as a safety check before removing old hosts
# ONLY run this check if there are actually hosts to replace - otherwise shutdown hosts trigger false positives
if ($hostPoolReplacementPlan.TotalSessionHostsToReplace -gt 0) {
    $newHostAvailability = Test-NewSessionHostsAvailable -ARMToken $ARMToken -SessionHosts $sessionHosts -LatestImageVersion $latestImageVersion
}
else {
    # No hosts need replacement - all hosts are on latest image
    # For metrics purposes, count all enabled hosts as "new" (on latest image)
    $hostsOnLatestImage = $sessionHosts | Where-Object { 
        $_.ImageVersion -eq $latestImageVersion.Version -and 
        -not $_.IsUnavailable
    }
    $availableOnLatest = $hostsOnLatestImage | Where-Object { $_.Status -eq 'Available' }
    
    Write-LogEntry -Message "All {0} enabled session hosts are on latest image version {1}" -StringValues $hostsOnLatestImage.Count, $latestImageVersion.Version -Level Trace
    $newHostAvailability = [PSCustomObject]@{
        TotalNewHosts       = $hostsOnLatestImage.Count
        AvailableCount      = $availableOnLatest.Count
        AvailablePercentage = if ($hostsOnLatestImage.Count -gt 0) { [Math]::Round(($availableOnLatest.Count / $hostsOnLatestImage.Count) * 100) } else { 0 }
        SafeToProceed       = $true  # Always safe when no replacements needed
        Message             = "All session hosts up to date"
    }
}

# New cycle detection will now happen earlier in the flow, before replacement plan calculation

# Check replacement mode to determine execution order
$replacementMode = Read-FunctionAppSetting ReplacementMode
Write-LogEntry -Message "Replacement Mode: {0}" -StringValues $replacementMode

if ($replacementMode -eq 'DeleteFirst') {
    # ================================================================================================
    # DELETE-FIRST MODE: Delete idle hosts first, then deploy replacements
    # ================================================================================================
    Write-LogEntry -Message "Using DELETE-FIRST mode: will delete idle hosts before deploying replacements"
    
    # STEP 1: Delete session hosts first
    $deletedSessionHostNames = @()
    $hostPropertyMapping = @{}
    $deletionResults = $null
    
    # Check if there's a pending host mapping from a previous failed deployment or registration issue
    # PendingHostMappings is essential for DeleteFirst mode to track deleted hosts for name reuse
    $hasPendingUnresolvedHosts = $false
    $deploymentState = Get-DeploymentState
    if ($deploymentState.PendingHostMappings -and $deploymentState.PendingHostMappings -ne '{}') {
        try {
            $hostPropertyMapping = $deploymentState.PendingHostMappings | ConvertFrom-Json -AsHashtable
            Write-LogEntry -Message "Loaded {0} pending host mapping(s) from previous run" -StringValues $hostPropertyMapping.Count
                
            # Check if any pending hosts are still unresolved (deleted but not registered)
            $pendingHostNames = $hostPropertyMapping.Keys
            $registeredHostNames = $sessionHosts.SessionHostName
            $unresolvedHosts = $pendingHostNames | Where-Object { $_ -notin $registeredHostNames }
                
            if ($unresolvedHosts.Count -gt 0) {
                $hasPendingUnresolvedHosts = $true
                Write-LogEntry -Message "CRITICAL: {0} host(s) were previously deleted but not yet registered: {1}" -StringValues $unresolvedHosts.Count, ($unresolvedHosts -join ', ') -Level Warning
                Write-LogEntry -Message "BLOCKING new deletions until pending hosts are resolved (deployment failure or registration issue)" -Level Warning
            }
            else {
                Write-LogEntry -Message "All pending hosts are now registered - clearing mappings" -Level Trace
                $deploymentState.PendingHostMappings = '{}'
                Save-DeploymentState -DeploymentState $deploymentState
                $hostPropertyMapping = @{}
            }
        }
        catch {
            Write-LogEntry -Message "Failed to parse pending host mappings: $_" -Level Warning
            $hostPropertyMapping = @{}
        }
    }
    
    # SAFETY CHECK: Verify any previously deployed new hosts are available before deleting more old capacity
    # This prevents cascading capacity loss if previous deployments created VMs that didn't register properly
    $shouldSkipEntireFlow = $false
    if (-not $newHostAvailability.SafeToProceed -and $newHostAvailability.TotalNewHosts -gt 0) {
        Write-LogEntry -Message "SAFETY CHECK FAILED: {0}" -StringValues $newHostAvailability.Message -Level Warning
        Write-LogEntry -Message "Halting DeleteFirst mode - will not delete old hosts until existing new hosts become available" -Level Warning
        Write-LogEntry -Message "This prevents further capacity loss when previous deployments have hosts that aren't accessible" -Level Warning
        # Skip the entire delete/deploy cycle - exit DeleteFirst flow
        $shouldSkipEntireFlow = $true
    }
    
    # Log pending host retry scenario
    if ($hasPendingUnresolvedHosts) {
        Write-LogEntry -Message "SAFETY CHECK FAILED: Cannot delete more hosts while previous deletions have unresolved deployments or registration issues" -Level Warning
        Write-LogEntry -Message "Will retry deployment of pending hosts without deleting additional capacity" -Level Warning
    }
    
    # Execute deletion logic only if we're not in a pending host retry scenario
    if (-not $shouldSkipEntireFlow -and -not $hasPendingUnresolvedHosts) {
        if ($newHostAvailability.TotalNewHosts -gt 0) {
            Write-LogEntry -Message "SAFETY CHECK PASSED: {0}" -StringValues $newHostAvailability.Message
        }

        if ($hostPoolReplacementPlan.PossibleSessionHostDeleteCount -gt 0 -and $hostPoolReplacementPlan.SessionHostsPendingDelete.Count -gt 0) {
            Write-LogEntry -Message "We can decommission {0} session hosts from this list: {1}" -StringValues $hostPoolReplacementPlan.SessionHostsPendingDelete.Count, ($hostPoolReplacementPlan.SessionHostsPendingDelete.SessionHostName -join ',')
        
            # Capture the names and dedicated host properties of hosts being deleted so we can reuse them
            $deletedSessionHostNames = $hostPoolReplacementPlan.SessionHostsPendingDelete.SessionHostName
            Write-LogEntry -Message "Deleted host names will be available for reuse: {0}" -StringValues ($deletedSessionHostNames -join ',') -Level Trace
        
            # Build mapping of hostname to dedicated host properties for reuse (merge with existing from previous run)
            # IMPORTANT: Include ALL hosts being deleted (even those without dedicated host properties)
            # This ensures we track which hosts need deployment even if deployment fails
            foreach ($sessionHost in $hostPoolReplacementPlan.SessionHostsPendingDelete) {
                # Only add if not already in mapping (preserve previous mappings)
                if (-not $hostPropertyMapping.ContainsKey($sessionHost.SessionHostName)) {
                    $hostPropertyMapping[$sessionHost.SessionHostName] = @{
                        HostId      = $sessionHost.HostId
                        HostGroupId = $sessionHost.HostGroupId
                        Zones       = $sessionHost.Zones
                    }
                    
                    if ($sessionHost.HostId -or $sessionHost.HostGroupId) {
                        Write-LogEntry -Message "Captured dedicated host properties for {0}: HostId={1}, HostGroupId={2}, Zones={3}" -StringValues $sessionHost.SessionHostName, $sessionHost.HostId, $sessionHost.HostGroupId, ($sessionHost.Zones -join ', ') -Level Trace
                    }
                    else {
                        Write-LogEntry -Message "Captured {0} for tracking (no dedicated host properties)" -StringValues $sessionHost.SessionHostName -Level Trace
                    }
                }
            }
        
            # Save host property mapping to deployment state BEFORE deletion attempt (for recovery if deletion succeeds but deployment fails)
            # This is critical for DeleteFirst mode to track which hosts need deployment
            $deploymentState = Get-DeploymentState
            if ($hostPropertyMapping.Count -gt 0) {
                $deploymentState.PendingHostMappings = ($hostPropertyMapping | ConvertTo-Json -Compress)
                Write-LogEntry -Message "Saved {0} host property mapping(s) to deployment state before deletion" -StringValues $hostPropertyMapping.Count -Level Trace
            }
            else {
                $deploymentState.PendingHostMappings = '{}'
            }
            Save-DeploymentState -DeploymentState $deploymentState

            # Acquire Graph token if device cleanup is enabled
            $GraphToken = $null
            if ($removeEntraDevice -or $removeIntuneDevice) {
                Try {
                    $graphEndpoint = Get-GraphEndpoint
                    $GraphToken = Get-AccessToken -ResourceUri $graphEndpoint
                
                    if ([string]::IsNullOrEmpty($GraphToken)) {
                        Write-LogEntry -Message "CRITICAL ERROR: Get-AccessToken returned null or empty Graph token but device cleanup is enabled." -Level Error
                        Write-LogEntry -Message "HINT: Ensure the managed identity has Directory.ReadWrite.All (for Entra ID) and DeviceManagementManagedDevices.ReadWrite.All (for Intune) permissions" -Level Error
                        Write-LogEntry -Message "Delete-First mode cannot proceed without device cleanup capability - hostname reuse will fail" -Level Error
                        throw "Graph token acquisition failed but device cleanup is required in DeleteFirst mode"
                    }
                }
                catch {
                    Write-LogEntry -Message "CRITICAL ERROR: Failed to acquire Graph access token but device cleanup is enabled: $_" -Level Error
                    Write-LogEntry -Message "HINT: Ensure the managed identity has Cloud Device Administrator role (for Entra ID) and DeviceManagementManagedDevices.ReadWrite.All (for Intune)" -Level Error
                    Write-LogEntry -Message "Delete-First mode cannot proceed without device cleanup capability - hostname reuse will fail" -Level Error
                    throw "Graph token acquisition failed but device cleanup is required in Delete-First mode"
                }
            }
        
            # Perform deletion
            $deletionResults = Remove-SessionHosts -ARMToken $ARMToken -GraphToken $GraphToken -SessionHostsPendingDelete $hostPoolReplacementPlan.SessionHostsPendingDelete -RemoveEntraDevice $removeEntraDevice -RemoveIntuneDevice $removeIntuneDevice
        
            # Check deletion results
            if ($deletionResults.FailedDeletions.Count -gt 0) {
                Write-LogEntry -Message "CRITICAL ERROR: {0} session host deletion(s) failed in Delete-First mode" -StringValues $deletionResults.FailedDeletions.Count -Level Error
                foreach ($failure in $deletionResults.FailedDeletions) {
                    Write-LogEntry -Message "  - {0}: {1}" -StringValues $failure.SessionHostName, $failure.Reason -Level Error
                }
                Write-LogEntry -Message "Delete-First mode cannot proceed with deployments - hostname conflicts will occur if we try to reuse failed deletion names" -Level Error
                Write-LogEntry -Message "Successful deletions: {0}" -StringValues ($deletionResults.SuccessfulDeletions -join ', ') -Level Trace
                throw "Session host deletion failures in Delete-First mode prevent safe hostname reuse"
            }
        
            Write-LogEntry -Message "Successfully deleted {0} session host(s): {1}" -StringValues $deletionResults.SuccessfulDeletions.Count, ($deletionResults.SuccessfulDeletions -join ', ')
        
            # Update pending delete list to reflect successful deletions
            if ($deletionResults.SuccessfulDeletions.Count -gt 0) {
                $hostPoolReplacementPlan.SessionHostsPendingDelete = @($hostPoolReplacementPlan.SessionHostsPendingDelete | Where-Object { $_ -notin $deletionResults.SuccessfulDeletions })
                Write-LogEntry -Message "Updated pending delete count to {0} after removing successfully deleted hosts" -StringValues $hostPoolReplacementPlan.SessionHostsPendingDelete.Count -Level Trace
            
                # Validate complete deletion (VM, Entra ID, Intune) - BLOCKING in DeleteFirst mode
                $verificationResults = Confirm-SessionHostDeletions `
                    -ARMToken $ARMToken `
                    -GraphToken $GraphToken `
                    -DeletedHostNames $deletionResults.SuccessfulDeletions `
                    -SessionHosts $sessionHosts `
                    -RemoveEntraDevice $removeEntraDevice `
                    -RemoveIntuneDevice $removeIntuneDevice
                
                # In DeleteFirst mode, device cleanup MUST succeed for hostname reuse
                # Check if any hosts have incomplete device cleanup
                $deviceCleanupRequired = $removeEntraDevice -or $removeIntuneDevice
                if ($deviceCleanupRequired -and $verificationResults.IncompleteHosts.Count -gt 0) {
                    Write-LogEntry -Message "CRITICAL ERROR: Device cleanup incomplete for {0} host(s) in Delete-First mode" -StringValues $verificationResults.IncompleteHosts.Count -Level Error
                    
                    foreach ($incompleteHost in $verificationResults.IncompleteHosts) {
                        $failures = @()
                        if (-not $incompleteHost.EntraIDConfirmed -and $removeEntraDevice) { $failures += "Entra ID" }
                        if (-not $incompleteHost.IntuneConfirmed -and $removeIntuneDevice) { $failures += "Intune" }
                        
                        if ($failures.Count -gt 0) {
                            Write-LogEntry -Message "  - {0}: Device cleanup failed for {1}" -StringValues $incompleteHost.Name, ($failures -join ', ') -Level Error
                        }
                    }
                    
                    Write-LogEntry -Message "Delete-First mode cannot proceed - hostname reuse will fail if devices still exist in Entra ID/Intune" -Level Error
                    Write-LogEntry -Message "TROUBLESHOOTING: Verify managed identity has Graph API permissions (Device.ReadWrite.All, DeviceManagementManagedDevices.ReadWrite.All)" -Level Error
                    throw "Device cleanup verification failed in Delete-First mode - cannot safely reuse hostnames"
                }
                
                Write-LogEntry -Message "Device cleanup verification passed - safe to reuse hostnames" -Level Trace
            }
        
            $deletedSessionHostNames = $deletionResults.SuccessfulDeletions
        
            # Calculate how many net-new hosts we're adding (growing the pool)
            # Example: Current=8, Target=10, Need to replace=1 → Deploy 3 (1 replacement + 2 net-new), Delete 1
            # In progressive scale-up scenarios, originalDeployCount may be less than hostsToReplace (batch sizing)
            # Net-new should never be negative - if we're doing batch replacements, net-new = 0
            $hostsToReplace = $hostPoolReplacementPlan.TotalSessionHostsToReplace
            $originalDeployCount = $hostPoolReplacementPlan.PossibleDeploymentsCount
            $netNewHosts = [Math]::Max(0, $originalDeployCount - $hostsToReplace)
            
            # Only limit REPLACEMENT deployments to match successful deletions (don't limit net-new growth)
            # If hosts were drained but not deleted yet, they're still taking up space for replacements
            $maxReplacements = $deletionResults.SuccessfulDeletions.Count
            $actualDeployCount = $maxReplacements + $netNewHosts
            
            if ($actualDeployCount -lt $originalDeployCount) {
                Write-LogEntry -Message "Delete-First mode: Reducing deployments from {0} to {1} (limited to {2} replacements + {3} net-new, some hosts still draining)" -StringValues $originalDeployCount, $actualDeployCount, $maxReplacements, $netNewHosts -Level Warning
                $hostPoolReplacementPlan.PossibleDeploymentsCount = $actualDeployCount
            }
        }
    
        # STEP 2: Deploy replacement session hosts
        if ($hostPoolReplacementPlan.PossibleDeploymentsCount -gt 0) {
            Write-LogEntry -Message "We will deploy {0} replacement session hosts" -StringValues $hostPoolReplacementPlan.PossibleDeploymentsCount
        
            # In DeleteFirst mode: exclude deleted host names so they can be reused
            # Calculate existing names: all current hosts + running deployments - just deleted hosts
            $currentExistingNames = (@($sessionHosts.SessionHostName) + @($hostPoolReplacementPlan.ExistingSessionHostNames)) | Sort-Object | Select-Object -Unique
            $existingSessionHostNames = $currentExistingNames | Where-Object { $_ -notin $deletedSessionHostNames }
        
            Write-LogEntry -Message "Excluded {0} deleted host name(s) from existing list to allow reuse" -StringValues $deletedSessionHostNames.Count -Level Trace
            Write-LogEntry -Message "Available for reuse: {0}" -StringValues ($deletedSessionHostNames -join ',') -Level Trace
        }
    } # End of deletion logic block
    
    # STEP 2: Deploy replacement session hosts (executes whether we deleted hosts or are retrying pending deployments)
    if (-not $shouldSkipEntireFlow -and $hostPoolReplacementPlan.PossibleDeploymentsCount -gt 0) {
        Write-LogEntry -Message "We will deploy {0} replacement session hosts" -StringValues $hostPoolReplacementPlan.PossibleDeploymentsCount
        
        # In DeleteFirst mode: exclude deleted host names so they can be reused
        # Calculate existing names: all current hosts + running deployments - just deleted hosts
        $currentExistingNames = (@($sessionHosts.SessionHostName) + @($hostPoolReplacementPlan.ExistingSessionHostNames)) | Sort-Object | Select-Object -Unique
        $existingSessionHostNames = $currentExistingNames | Where-Object { $_ -notin $deletedSessionHostNames }
        
        if ($deletedSessionHostNames.Count -gt 0) {
            Write-LogEntry -Message "Excluded {0} deleted host name(s) from existing list to allow reuse" -StringValues $deletedSessionHostNames.Count -Level Trace
            Write-LogEntry -Message "Available for reuse: {0}" -StringValues ($deletedSessionHostNames -join ',') -Level Trace
        }
        elseif ($hasPendingUnresolvedHosts) {
            Write-LogEntry -Message "Retrying deployment for {0} pending host(s) from previous failed deployment" -StringValues $hostPropertyMapping.Count -Level Warning
        }
        
        try {
            $deploymentResult = Deploy-SessionHosts -ARMToken $ARMToken -NewSessionHostsCount $hostPoolReplacementPlan.PossibleDeploymentsCount -ExistingSessionHostNames $existingSessionHostNames -PreferredSessionHostNames $deletedSessionHostNames -PreferredHostProperties $hostPropertyMapping
            
            # Log deployment submission immediately for workbook visibility
            Write-LogEntry -Message "Deployment submitted: {0} VMs requested, deployment name: {1}" -StringValues $deploymentResult.SessionHostCount, $deploymentResult.DeploymentName
            
            # Update deployment state for progressive scale-up tracking
            if (Read-FunctionAppSetting EnableProgressiveScaleUp -AsBoolean) {
                $deploymentState = Get-DeploymentState               
                # Save deployment info for checking on next run
                $deploymentState.LastDeploymentName = $deploymentResult.DeploymentName
                $deploymentState.LastDeploymentCount = $deploymentResult.SessionHostCount
                $deploymentState.LastDeploymentNeeded = $hostPoolReplacementPlan.PossibleDeploymentsCount
                $deploymentState.LastDeploymentPercentage = if ($hostPoolReplacementPlan.PossibleDeploymentsCount -gt 0) { [Math]::Round(($deploymentResult.SessionHostCount / $hostPoolReplacementPlan.PossibleDeploymentsCount) * 100) } else { 0 }
                $deploymentState.LastTimestamp = Get-Date -AsUTC -Format 'o'                
                Write-LogEntry -Message "Deployment submitted: $($deploymentResult.DeploymentName). Status will be checked on next run."
                
                # Save state
                Save-DeploymentState -DeploymentState $deploymentState
            }
        }
        catch {
            Write-LogEntry -Message "Deployment failed with error: $_" -Level Error
            
            # Update state to reflect immediate failure (submission error) if progressive scale-up is enabled
            if ($enableProgressiveScaleUp) {
                $deploymentState = Get-DeploymentState
                $deploymentState.ConsecutiveSuccesses = 0
                $deploymentState.CurrentPercentage = (Read-FunctionAppSetting InitialDeploymentPercentage)
                $deploymentState.LastStatus = 'Failed'
                $deploymentState.LastDeploymentName = '' # Clear deployment name since submission failed
                $deploymentState.LastTimestamp = Get-Date -AsUTC -Format 'o'
                Save-DeploymentState -DeploymentState $deploymentState
            }            
            throw
        }
    }
} # End of DeleteFirst mode
else {
    # ================================================================================================
    # SIDE-BY-SIDE MODE: Deploy new hosts first, then delete old ones
    # ================================================================================================
    Write-LogEntry -Message "Using SIDE-BY-SIDE mode: will deploy new hosts before deleting old ones"
    
    # STEP 1: Deploy new session hosts first
    $deploymentResult = $null
    if ($hostPoolReplacementPlan.PossibleDeploymentsCount -gt 0) {
        Write-LogEntry -Message "We will deploy {0} session hosts" -StringValues $hostPoolReplacementPlan.PossibleDeploymentsCount
        # Deploy session hosts - use SessionHostName (hostname from FQDN) not VMName (Azure VM resource name)
        $existingSessionHostNames = (@($sessionHosts.SessionHostName) + @($hostPoolReplacementPlan.ExistingSessionHostNames)) | Sort-Object | Select-Object -Unique
        
        try {
            $deploymentResult = Deploy-SessionHosts -ARMToken $ARMToken -NewSessionHostsCount $hostPoolReplacementPlan.PossibleDeploymentsCount -ExistingSessionHostNames $existingSessionHostNames
            
            # Log deployment submission immediately for workbook visibility
            Write-LogEntry -Message "Deployment submitted: {0} VMs requested, deployment name: {1}" -StringValues $deploymentResult.SessionHostCount, $deploymentResult.DeploymentName
            
            # Update deployment state for progressive scale-up tracking
            if (Read-FunctionAppSetting EnableProgressiveScaleUp -AsBoolean) {
                $deploymentState = Get-DeploymentState
                
                # Save deployment info for checking on next run
                $deploymentState.LastDeploymentName = $deploymentResult.DeploymentName
                $deploymentState.LastDeploymentCount = $deploymentResult.SessionHostCount
                $deploymentState.LastDeploymentNeeded = $hostPoolReplacementPlan.PossibleDeploymentsCount
                $deploymentState.LastDeploymentPercentage = if ($hostPoolReplacementPlan.PossibleDeploymentsCount -gt 0) {
                    [Math]::Round(($deploymentResult.SessionHostCount / $hostPoolReplacementPlan.PossibleDeploymentsCount) * 100)
                }
                else { 0 }
                $deploymentState.LastTimestamp = Get-Date -AsUTC -Format 'o'
                
                Write-LogEntry -Message "Deployment submitted: $($deploymentResult.DeploymentName). Status will be checked on next run."
                
                # Save state
                Save-DeploymentState -DeploymentState $deploymentState
            }
        }
        catch {
            Write-LogEntry -Message "Deployment failed with error: $_" -Level Error
            
            # Update state to reflect immediate failure (submission error) if progressive scale-up is enabled
            if ($enableProgressiveScaleUp) {
                $deploymentState = Get-DeploymentState
                $deploymentState.ConsecutiveSuccesses = 0
                $deploymentState.CurrentPercentage = (Read-FunctionAppSetting InitialDeploymentPercentage)
                $deploymentState.LastStatus = 'Failed'
                $deploymentState.LastDeploymentName = '' # Clear deployment name since submission failed
                $deploymentState.LastTimestamp = Get-Date -AsUTC -Format 'o'
                Save-DeploymentState -DeploymentState $deploymentState
            }            
            throw
        }
    }

    # STEP 2: Verify new session hosts are available before removing old ones (safety check)
    # This prevents capacity loss if newly deployed hosts fail to register or pass health checks
    if (-not $newHostAvailability.SafeToProceed -and $newHostAvailability.TotalNewHosts -gt 0) {
        Write-LogEntry -Message "SAFETY CHECK FAILED: {0}" -StringValues $newHostAvailability.Message -Level Warning
        Write-LogEntry -Message "Skipping old host removal to preserve capacity until new hosts become available" -Level Warning
        # Don't proceed with deletion - exit the SideBySide flow here
    }
    elseif ($newHostAvailability.TotalNewHosts -gt 0) {
        Write-LogEntry -Message "SAFETY CHECK PASSED: {0}" -StringValues $newHostAvailability.Message
    }

    # STEP 3: Delete session hosts (only if safety check passed or no new hosts to verify)
    if (($newHostAvailability.SafeToProceed -or $newHostAvailability.TotalNewHosts -eq 0) -and $hostPoolReplacementPlan.PossibleSessionHostDeleteCount -gt 0 -and $hostPoolReplacementPlan.SessionHostsPendingDelete.Count -gt 0) {
        Write-LogEntry -Message "We will decommission {0} session hosts from this list: {1}" -StringValues $hostPoolReplacementPlan.SessionHostsPendingDelete.Count, ($hostPoolReplacementPlan.SessionHostsPendingDelete.SessionHostName -join ',') -Level Trace
               
        # Acquire Graph token if device cleanup is enabled
        if ($removeEntraDevice -or $removeIntuneDevice) {
            Try {
                $graphEndpoint = Get-GraphEndpoint
                $GraphToken = Get-AccessToken -ResourceUri $graphEndpoint
                
                if ([string]::IsNullOrEmpty($GraphToken)) {
                    Write-Warning "Get-AccessToken returned null or empty Graph token. Device cleanup will be skipped."
                    Write-LogEntry -Message "HINT: Ensure the managed identity has Directory.ReadWrite.All (for Entra ID) and DeviceManagementManagedDevices.ReadWrite.All (for Intune) permissions" -Level Warning
                    $GraphToken = $null
                }
            }
            catch {
                Write-Warning "Failed to acquire Graph access token: $_. Device cleanup will be skipped."
                Write-LogEntry -Message "HINT: Ensure the managed identity has Cloud Device Administrator role (for Entra ID) and DeviceManagementManagedDevices.ReadWrite.All (for Intune)" -Level Warning
                $GraphToken = $null
            }
        }
        
        # Perform deletion and log results (SideBySide mode doesn't halt on failures since name reuse isn't critical)
        $deletionResults = $null
        If ($GraphToken) {
            $deletionResults = Remove-SessionHosts -ARMToken $ARMToken -GraphToken $GraphToken -SessionHostsPendingDelete $hostPoolReplacementPlan.SessionHostsPendingDelete -RemoveEntraDevice $removeEntraDevice -RemoveIntuneDevice $removeIntuneDevice
        }
        Else {
            $deletionResults = Remove-SessionHosts -ARMToken $ARMToken -GraphToken $null -SessionHostsPendingDelete $hostPoolReplacementPlan.SessionHostsPendingDelete -RemoveEntraDevice $false -RemoveIntuneDevice $false
        }
        
        # Log results (but don't halt in SideBySide mode)
        if ($deletionResults) {
            if ($deletionResults.FailedDeletions.Count -gt 0) {
                Write-LogEntry -Message "Warning: {0} session host deletion(s) failed" -StringValues $deletionResults.FailedDeletions.Count -Level Warning
                foreach ($failure in $deletionResults.FailedDeletions) {
                    Write-LogEntry -Message "  - {0}: {1}" -StringValues $failure.SessionHostName, $failure.Reason -Level Warning
                }
            }
            if ($deletionResults.SuccessfulDeletions.Count -gt 0) {
                Write-LogEntry -Message "Deleted {0} session host(s): {1}" -StringValues $deletionResults.SuccessfulDeletions.Count, ($deletionResults.SuccessfulDeletions -join ', ')
                
                # Update pending delete list to reflect successful deletions
                $hostPoolReplacementPlan.SessionHostsPendingDelete = @($hostPoolReplacementPlan.SessionHostsPendingDelete | Where-Object { $_ -notin $deletionResults.SuccessfulDeletions })
                Write-LogEntry -Message "Updated pending delete count to {0} after removing successfully deleted hosts" -StringValues $hostPoolReplacementPlan.SessionHostsPendingDelete.Count -Level Trace
                
                # Validate complete deletion (VM, Entra ID, Intune)
                Confirm-SessionHostDeletions `
                    -ARMToken $ARMToken `
                    -GraphToken $GraphToken `
                    -DeletedHostNames $deletionResults.SuccessfulDeletions `
                    -SessionHosts $sessionHosts `
                    -RemoveEntraDevice $removeEntraDevice `
                    -RemoveIntuneDevice $removeIntuneDevice | Out-Null
            }
            if ($deletionResults.SuccessfulShutdowns.Count -gt 0) {
                Write-LogEntry -Message "Successfully shutdown {0} session host(s) for retention: {1}" -StringValues $deletionResults.SuccessfulShutdowns.Count, ($deletionResults.SuccessfulShutdowns -join ', ')
            }
        }
    }
}

# Log comprehensive metrics for monitoring dashboard (after all operations complete)
$hostsInDrainMode = ($sessionHostsFiltered | Where-Object { -not $_.AllowNewSession }).Count

# Calculate current deployment status accounting for just-submitted deployments
$currentlyDeploying = $runningDeployments.Count
$remainingToDeploy = $hostPoolReplacementPlan.PossibleDeploymentsCount
if ($deploymentResult) {
    # A deployment was just submitted this run, so it's now running
    $currentlyDeploying += $deploymentResult.SessionHostCount
    # Reduce the remaining count by what was just deployed
    $remainingToDeploy = [Math]::Max(0, $remainingToDeploy - $deploymentResult.SessionHostCount)
}

# Count VMs in shutdown retention for metrics (use count from earlier calculation to avoid stale cache issues)
$shutdownRetentionCount = if ($enableShutdownRetention -and $hostsInShutdownRetention) { $hostsInShutdownRetention.Count } else { 0 }

# Calculate actual current counts by subtracting completed deletions from initial counts
$completedDeletionsCount = if ($deletionResults -and $deletionResults.SuccessfulDeletions) { $deletionResults.SuccessfulDeletions.Count } else { 0 }
$completedShutdownsCount = if ($deletionResults -and $deletionResults.SuccessfulShutdowns) { $deletionResults.SuccessfulShutdowns.Count } else { 0 }
$currentSessionHostCount = $sessionHosts.Count - $completedDeletionsCount
$currentEnabledCount = $sessionHostsFiltered.Count - $completedDeletionsCount

# Adjust ToReplace to reflect completed deletions AND shutdowns in BOTH modes
# Once hosts are deleted OR shutdown (regardless of mode), they no longer need replacement
# - SuccessfulDeletions: Hosts fully removed (VM + devices deleted)
# - SuccessfulShutdowns: Hosts powered off for retention (effectively replaced, kept as backup)
# DeleteFirst: Deletes first, then deploys replacements with name reuse
# SideBySide: Deploys first, then deletes/shuts down old hosts (both reduce ToReplace count)
$totalReplacementOperations = $completedDeletionsCount + $completedShutdownsCount
$remainingToReplace = $hostPoolReplacementPlan.TotalSessionHostsToReplace
if ($totalReplacementOperations -gt 0) {
    $remainingToReplace = [Math]::Max(0, $hostPoolReplacementPlan.TotalSessionHostsToReplace - $totalReplacementOperations)
}

$metricsLog = @{
    TotalSessionHosts     = $currentSessionHostCount
    EnabledForAutomation  = $currentEnabledCount
    TargetCount           = if ($hostPoolReplacementPlan.TargetSessionHostCount) { $hostPoolReplacementPlan.TargetSessionHostCount } else { 0 }
    ToReplace             = $remainingToReplace
    ToReplacePercentage   = if ($hostPoolReplacementPlan.TargetSessionHostCount -gt 0) { [math]::Round(($remainingToReplace / $hostPoolReplacementPlan.TargetSessionHostCount) * 100, 1) } else { 0 }
    InDrain               = $hostsInDrainMode
    PendingDelete         = [Math]::Max(0, $hostPoolReplacementPlan.SessionHostsPendingDelete.Count - $totalReplacementOperations)
    ShutdownRetention     = $shutdownRetentionCount
    ToDeployNow           = $remainingToDeploy
    RunningDeployments    = $currentlyDeploying
    NewHostsTotal         = $newHostAvailability.TotalNewHosts
    NewHostsAvailable     = $newHostAvailability.AvailableCount
    NewHostsAvailablePct  = $newHostAvailability.AvailablePercentage
    NewHostsSafeToProceed = $newHostAvailability.SafeToProceed
    LatestImageVersion    = if ($latestImageVersion.Version) { $latestImageVersion.Version } else { "N/A" }
    LatestImageDate       = $latestImageVersion.Date
}

# Log image metadata for workbook visibility
if ($latestImageVersion.Definition -like "marketplace:*") {
    # Parse marketplace identifier: "marketplace:publisher/offer/sku"
    $marketplaceParts = $latestImageVersion.Definition -replace "^marketplace:", "" -split "/"
    Write-LogEntry -Message "IMAGE_INFO | Type: Marketplace | Publisher: {0} | Offer: {1} | Sku: {2} | Version: {3}" `
        -StringValues $marketplaceParts[0], $marketplaceParts[1], $marketplaceParts[2], $latestImageVersion.Version
}
else {
    # Parse gallery path: /subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/galleries/{galleryName}/images/{imageName}
    $galleryMatch = [regex]::Match($latestImageVersion.Definition, "/galleries/([^/]+)/images/([^/]+)")
    $galleryName = $galleryMatch.Groups[1].Value
    $imageDefinition = $galleryMatch.Groups[2].Value
    Write-LogEntry -Message "IMAGE_INFO | Type: Gallery | Gallery: {0} | ImageDefinition: {1} | Version: {2}" `
        -StringValues $galleryName, $imageDefinition, $latestImageVersion.Version
}

# Check if cycle is complete (no hosts to replace, no hosts in drain, no pending deletions, no running deployments)
# If complete, remove scaling exclusion tags from all hosts (EXCEPT shutdown retention VMs)
$cycleComplete = $metricsLog.ToReplace -eq 0 -and $metricsLog.InDrain -eq 0 -and $metricsLog.PendingDelete -eq 0 -and $metricsLog.RunningDeployments -eq 0

# In SideBySide mode with shutdown retention: also remove tags from new hosts if old hosts are in retention (even if cycle not fully complete)
# This allows scaling plan to manage new capacity while old hosts remain protected during retention period
$sideBySideRetentionTransition = $replacementMode -eq 'SideBySide' -and $enableShutdownRetention -and $shutdownRetentionCount -gt 0 -and $metricsLog.ToReplace -eq 0 -and $metricsLog.RunningDeployments -eq 0

if ($cycleComplete -or $sideBySideRetentionTransition) {
    if ($cycleComplete) {
        Write-LogEntry -Message "Update cycle complete - all hosts are up to date. Removing scaling exclusion tags (preserving tags on shutdown retention VMs)."
    }
    else {
        Write-LogEntry -Message "SideBySide mode with shutdown retention - removing scaling exclusion tags from new active hosts (preserving tags on shutdown retention VMs)."
    }
    
    $tagScalingPlanExclusionTag = Read-FunctionAppSetting Tag_ScalingPlanExclusionTag
    $resourceManagerUri = Get-ResourceManagerUri
    
    # Get list of VMs currently in shutdown retention (deallocated with retention tag)
    $shutdownRetentionVMs = @()
    if ($enableShutdownRetention) {
        $shutdownRetentionTag = Read-FunctionAppSetting Tag_ShutdownTimestamp
        foreach ($vm in $cachedVMs) {
            if ($vm.tags -and ($vm.tags.PSObject.Properties.Name -contains $shutdownRetentionTag)) {
                $vmName = $vm.name
                $shutdownRetentionVMs += $vmName
                Write-LogEntry -Message "VM $vmName has shutdown retention tag - will preserve scaling exclusion tag" -Level Trace
            }
        }
    }
    
    # Only proceed if a scaling exclusion tag is configured
    if ($tagScalingPlanExclusionTag -and $tagScalingPlanExclusionTag -ne ' ') {
        $hostsWithExclusionTag = 0
        
        foreach ($sessionHost in $sessionHostsFiltered) {
            try {
                # Get VM name from session host
                $vmName = $sessionHost.ResourceId.Split('/')[-1]
                
                # Skip if this VM is in shutdown retention
                if ($shutdownRetentionVMs -contains $vmName) {
                    Write-LogEntry -Message "Preserving scaling exclusion tag on shutdown retention VM: $vmName" -Level Trace
                    continue
                }
                
                # Use cached tags from session host object (already fetched in Get-SessionHosts)
                $vmTags = $sessionHost.Tags
                
                # If the exclusion tag exists and has the SessionHostReplacer value (function-set), remove it
                if ($vmTags.ContainsKey($tagScalingPlanExclusionTag)) {
                    $tagValue = $vmTags[$tagScalingPlanExclusionTag]
                    
                    # Only remove if the tag value is 'SessionHostReplacer' (set by this function)
                    # This prevents removing admin-set tags which typically have blank values or custom strings
                    if ($tagValue -eq 'SessionHostReplacer') {
                        Write-LogEntry -Message "Removing scaling exclusion tag from $($sessionHost.SessionHostName) (value: $tagValue)"
                        
                        # Remove the tag using Delete operation
                        $tagsUri = "$resourceManagerUri$($sessionHost.ResourceId)/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
                        $Body = @{
                            operation  = 'Delete'
                            properties = @{
                                tags = @{ $tagScalingPlanExclusionTag = '' }
                            }
                        }
                        
                        Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $tagsUri | Out-Null
                        $hostsWithExclusionTag++
                        
                        Write-LogEntry -Message "Successfully removed scaling exclusion tag from $($sessionHost.SessionHostName)" -Level Trace
                    }
                    else {
                        Write-LogEntry -Message "Skipping removal of scaling exclusion tag from $($sessionHost.SessionHostName) - appears to be admin-set (value: '$tagValue')"
                    }
                }
            }
            catch {
                Write-LogEntry -Message "Error removing scaling exclusion tag from $($sessionHost.SessionHostName): $($_.Exception.Message)" -Level Warning
            }
        }
        
        if ($hostsWithExclusionTag -gt 0) {
            Write-LogEntry -Message "Removed scaling exclusion tags from {0} session host(s)" -StringValues $hostsWithExclusionTag
        }
        else {
            Write-LogEntry -Message "No scaling exclusion tags found to remove" -Level Trace
        }
    }
    else {
        Write-LogEntry -Message "No scaling exclusion tag configured - skipping tag cleanup" -Level Trace
    }
}

Write-LogEntry -Message "METRICS | Total: {0} | Enabled: {1} | Target: {2} | ToReplace: {3} ({4}%) | InDrain: {5} | PendingDelete: {6} | ShutdownRetention: {7} | ToDeployNow: {8} | RunningDeployments: {9} | NewHosts: {10}/{11} ({12}%) Available | LatestImage: {13}" `
    -StringValues $metricsLog.TotalSessionHosts, $metricsLog.EnabledForAutomation, $metricsLog.TargetCount, $metricsLog.ToReplace, $metricsLog.ToReplacePercentage, $metricsLog.InDrain, $metricsLog.PendingDelete, $metricsLog.ShutdownRetention, $metricsLog.ToDeployNow, $metricsLog.RunningDeployments, $metricsLog.NewHostsAvailable, $metricsLog.NewHostsTotal, $metricsLog.NewHostsAvailablePct, $metricsLog.LatestImageVersion

# Update host pool status tag with current state
try {
    Update-HostPoolStatus `
        -ARMToken $ARMToken `
        -SessionHosts $sessionHostsFiltered `
        -RunningDeployments $currentlyDeploying `
        -FailedDeployments $failedDeployments `
        -HostsToReplace $metricsLog.ToReplace `
        -CachedVMs $cachedVMs
}
catch {
    Write-LogEntry -Message "Failed to update host pool status tag: $($_.Exception.Message)" -Level Warning
}

# Update deployment state with current ToReplace count for new cycle detection
if (Read-FunctionAppSetting EnableProgressiveScaleUp -AsBoolean) {
    try {
        $deploymentState = Get-DeploymentState
        $deploymentState.LastTotalToReplace = $metricsLog.ToReplace
        Save-DeploymentState -DeploymentState $deploymentState
    }
    catch {
        Write-LogEntry -Message "Failed to update LastTotalToReplace in deployment state: $($_.Exception.Message)" -Level Warning
    }
}

# Log completion timestamp for workbook visibility
Write-LogEntry -Message "SCHEDULE | Function execution completed at: {0}" -StringValues (Get-Date -AsUTC -Format 'o')