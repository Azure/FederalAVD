# Input bindings are passed in via param block.
param($Timer)

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# Set host pool name for log prefixing
Set-HostPoolNameForLogging -HostPoolName (Read-FunctionAppSetting HostPoolName)

Write-LogEntry -Message "SessionHostReplacer function started at {0}" -StringValues (Get-Date -AsUTC -Format 'o')

# Log configuration settings for workbook visibility
$enableShutdownRetention = Read-FunctionAppSetting EnableShutdownRetention
$replacementMode = Read-FunctionAppSetting ReplacementMode
$minimumDrainMinutes = Read-FunctionAppSetting MinimumDrainMinutes
$drainGracePeriodHours = Read-FunctionAppSetting DrainGracePeriodHours
$minimumCapacityPercentage = Read-FunctionAppSetting MinimumCapacityPercentage
$maxDeletionsPerCycle = Read-FunctionAppSetting MaxDeletionsPerCycle
$enableProgressiveScaleUp = Read-FunctionAppSetting EnableProgressiveScaleUp
$initialDeploymentPercentage = Read-FunctionAppSetting InitialDeploymentPercentage
$scaleUpIncrementPercentage = Read-FunctionAppSetting ScaleUpIncrementPercentage
$successfulRunsBeforeScaleUp = Read-FunctionAppSetting SuccessfulRunsBeforeScaleUp
$maxDeploymentBatchSize = Read-FunctionAppSetting MaxDeploymentBatchSize
$minimumHostIndex = Read-FunctionAppSetting MinimumHostIndex
$shutdownRetentionDays = Read-FunctionAppSetting ShutdownRetentionDays
$targetSessionHostCount = Read-FunctionAppSetting TargetSessionHostCount

# Build settings log with N/A for non-applicable values based on replacement mode
$settingsLog = @{
    ReplacementMode = $replacementMode
    MinimumDrainMinutes = $minimumDrainMinutes
    DrainGracePeriodHours = $drainGracePeriodHours
    MinimumCapacityPercent = if ($replacementMode -eq 'DeleteFirst') { "$minimumCapacityPercentage (static)" } else { 'N/A' }
    MaxDeletionsPerCycle = if ($replacementMode -eq 'DeleteFirst') { $maxDeletionsPerCycle } else { 'N/A' }
    EnableProgressiveScaleUp = $enableProgressiveScaleUp
    InitialDeploymentPercent = if($enableProgressiveScaleUp) { $initialDeploymentPercentage } else { 'N/A' }
    ScaleUpIncrementPercent = if($enableProgressiveScaleUp) { $scaleUpIncrementPercentage } else { 'N/A' }
    SuccessfulRunsBeforeScaleUp = if($enableProgressiveScaleUp) { $successfulRunsBeforeScaleUp } else { 'N/A' }
    MaxDeploymentBatchSize = if ($replacementMode -eq 'SideBySide') { $maxDeploymentBatchSize } else { 'N/A' }
    MinimumHostIndex = if ($replacementMode -eq 'SideBySide') { $minimumHostIndex } else { 'N/A' }
    EnableShutdownRetention = if ($replacementMode -eq 'SideBySide') { $enableShutdownRetention } else { 'N/A' }
    ShutdownRetentionDays = if ($replacementMode -eq 'SideBySide' -and $enableShutdownRetention -eq 'True') { $shutdownRetentionDays } else { 'N/A' }
    TargetSessionHostCount = if($targetSessionHostCount -eq 0) { 'Auto' } else { $targetSessionHostCount }
    DynamicCapacityEnabled = if ($replacementMode -eq 'DeleteFirst') { 'Yes' } else { 'N/A' }
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
# Note: $expand=instanceView requires filters and isn't supported on simple LIST operations
# Power state will be queried lazily for deletion candidates only
Write-LogEntry -Message "Fetching all VMs in resource group for caching" -Level Trace
$virtualMachinesSubscriptionId = Read-FunctionAppSetting VirtualMachinesSubscriptionId
$virtualMachinesResourceGroupName = Read-FunctionAppSetting VirtualMachinesResourceGroupName
$resourceManagerUri = Get-ResourceManagerUri
$Uri = "$resourceManagerUri/subscriptions/$virtualMachinesSubscriptionId/resourceGroups/$virtualMachinesResourceGroupName/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01"
$cachedVMs = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
Write-LogEntry -Message "Cached {0} VMs from resource group" -StringValues $cachedVMs.Count -Level Trace

# Check for and cleanup expired shutdown VMs BEFORE fetching session hosts (so the list is already clean)
if ($enableShutdownRetention) {
    Write-LogEntry -Message "Shutdown retention is enabled - checking for expired shutdown VMs"
    
    # Acquire Graph token for device cleanup if enabled
    $GraphToken = $null
    $removeEntraDevice = Read-FunctionAppSetting RemoveEntraDevice
    $removeIntuneDevice = Read-FunctionAppSetting RemoveIntuneDevice
    
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

# Check previous deployment status if progressive scale-up is enabled
$previousDeploymentStatus = $null
if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
    $deploymentState = Get-DeploymentState
    
    if (-not [string]::IsNullOrEmpty($deploymentState.LastDeploymentName)) {
        Write-LogEntry -Message "Checking status of previous deployment: {0}" -StringValues $deploymentState.LastDeploymentName
        $previousDeploymentStatus = Get-LastDeploymentStatus -DeploymentName $deploymentState.LastDeploymentName -ARMToken $ARMToken
        
        if ($previousDeploymentStatus) {
            if ($previousDeploymentStatus.Succeeded) {
                # Increment consecutive successes
                $deploymentState.ConsecutiveSuccesses++
                $deploymentState.LastStatus = 'Success'
                
                # Clear pending host mappings on successful deployment (no longer needed)
                if ($deploymentState.PendingHostMappings -and $deploymentState.PendingHostMappings -ne '{}') {
                    Write-LogEntry -Message "Clearing pending host mappings after successful deployment" -Level Trace
                    $deploymentState.PendingHostMappings = '{}'
                }
                
                # Calculate next percentage
                $successfulRunsBeforeScaleUp = [int]::Parse((Read-FunctionAppSetting SuccessfulRunsBeforeScaleUp))
                $scaleUpIncrementPercentage = [int]::Parse((Read-FunctionAppSetting ScaleUpIncrementPercentage))
                $initialDeploymentPercentage = [int]::Parse((Read-FunctionAppSetting InitialDeploymentPercentage))
                
                $scaleUpMultiplier = [Math]::Floor($deploymentState.ConsecutiveSuccesses / $successfulRunsBeforeScaleUp)
                $deploymentState.CurrentPercentage = [Math]::Min(
                    $initialDeploymentPercentage + ($scaleUpMultiplier * $scaleUpIncrementPercentage),
                    100
                )                
                Write-LogEntry -Message "Previous deployment succeeded. ConsecutiveSuccesses: $($deploymentState.ConsecutiveSuccesses), CurrentPercentage: $($deploymentState.CurrentPercentage)%"
            }
            elseif ($previousDeploymentStatus.Failed) {
                Write-LogEntry -Message "Previous deployment failed. Cleaning up partial resources before redeployment." -Level Warning
                
                # Acquire Graph token for device cleanup if enabled
                $GraphToken = $null
                $removeEntraDevice = Read-FunctionAppSetting RemoveEntraDevice
                $removeIntuneDevice = Read-FunctionAppSetting RemoveIntuneDevice
                
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
                
                # Clear pending host mappings (starting fresh)
                if ($deploymentState.PendingHostMappings -and $deploymentState.PendingHostMappings -ne '{}') {
                    Write-LogEntry -Message "Clearing pending host mappings after failed deployment cleanup" -Level Trace
                    $deploymentState.PendingHostMappings = '{}'
                }
                
                # Reset on failure
                $deploymentState.ConsecutiveSuccesses = 0
                $deploymentState.CurrentPercentage = $initialDeploymentPercentage
                $deploymentState.LastStatus = 'Failed'                
                Write-LogEntry -Message "Reset consecutive successes to 0, CurrentPercentage: $($deploymentState.CurrentPercentage)%" -Level Warning
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
Write-LogEntry -Message "Getting latest image version using Image Reference: {0}" -StringValues ($sessionHostParameters.ImageReference | Out-String)
$latestImageVersion = Get-LatestImageVersion -ARMToken $ARMToken -ImageReference $sessionHostParameters.ImageReference -Location $sessionHostParameters.Location

# Read AllowImageVersionRollback setting with default of false
$allowImageVersionRollback = Read-FunctionAppSetting AllowImageVersionRollback
if ($null -eq $allowImageVersionRollback) {
    $allowImageVersionRollback = $false
}
else {
    $allowImageVersionRollback = [bool]::Parse($allowImageVersionRollback)
}

# OPTIMIZATION: Lightweight pre-check to determine if host pool is up to date
# This avoids expensive operations (scaling plan query, full replacement plan calculation) when no work is needed
Write-LogEntry -Message "Performing lightweight up-to-date check" -Level Trace

$isUpToDate = $false
$replaceSessionHostOnNewImageVersionDelayDays = [int]::Parse((Read-FunctionAppSetting ReplaceSessionHostOnNewImageVersionDelayDays))
$latestImageAge = (New-TimeSpan -Start $latestImageVersion.Date -End (Get-Date -AsUTC)).TotalDays

# Check if there are any running or failed deployments
if ($runningDeployments.Count -eq 0 -and $failedDeployments.Count -eq 0) {
    
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
else {
    Write-LogEntry -Message "Lightweight check: Found $($runningDeployments.Count) running and $($failedDeployments.Count) failed deployments - proceeding with full processing" -Level Trace
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
    if ($replacementMode -eq 'DeleteFirst') {
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
    $hostPoolReplacementPlan = Get-SessionHostReplacementPlan -ARMToken $ARMToken -SessionHosts $sessionHostsFiltered -RunningDeployments $runningDeployments -LatestImageVersion $latestImageVersion -AllowImageVersionRollback $allowImageVersionRollback -ScalingPlanTarget $scalingPlanTarget
}

# EARLY EXIT: Check if host pool is up to date (nothing to do)
if ($hostPoolReplacementPlan.TotalSessionHostsToReplace -eq 0 -and 
    $hostPoolReplacementPlan.PossibleDeploymentsCount -eq 0 -and 
    $hostPoolReplacementPlan.PossibleSessionHostDeleteCount -eq 0 -and
    $runningDeployments.Count -eq 0 -and
    $failedDeployments.Count -eq 0) {
    
    Write-LogEntry -Message "Host pool is UP TO DATE - all session hosts are on the latest image version and no work is needed."
    
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
        TotalSessionHosts       = $sessionHosts.Count
        EnabledForAutomation    = $sessionHostsFiltered.Count
        TargetCount             = if ($hostPoolReplacementPlan.TargetSessionHostCount) { $hostPoolReplacementPlan.TargetSessionHostCount } else { 0 }
        ToReplace               = 0
        ToReplacePercentage     = 0
        InDrain                 = $hostsInDrainMode
        PendingDelete           = 0
        ShutdownRetention       = $shutdownRetentionCount
        ToDeployNow             = 0
        RunningDeployments      = 0
        LatestImageVersion      = if ($latestImageVersion.Version) { $latestImageVersion.Version } else { "N/A" }
        LatestImageDate         = $latestImageVersion.Date
        Status                  = if ($cycleComplete) { "UpToDate" } else { "Draining" }
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
    # No hosts need replacement - skip availability check
    Write-LogEntry -Message "Skipping new host availability check - no hosts need replacement" -Level Trace
    $newHostAvailability = [PSCustomObject]@{
        TotalNewHosts = 0
        AvailableCount = 0
        AvailablePercentage = 0
        SafeToProceed = $true  # Always safe when no replacements needed
        Message = "No replacement needed"
    }
}

# Check if we're starting a new update cycle and reset progressive scale-up if needed
if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
    $deploymentState = Get-DeploymentState
    $currentImageVersion = if ($latestImageVersion.Version) { $latestImageVersion.Version } else { 'N/A' }
    $totalToReplace = if ($hostPoolReplacementPlan.TotalSessionHostsToReplace) { $hostPoolReplacementPlan.TotalSessionHostsToReplace } else { 0 }
    
    # Detect if we're starting a new update cycle
    $isNewCycle = $false
    $resetReason = ''
    
    # Log current state for debugging
    Write-LogEntry -Message "New cycle detection - Current state: ImageVersion=$currentImageVersion, ToReplace=$totalToReplace, RunningDeployments=$($runningDeployments.Count)" -Level Trace
    Write-LogEntry -Message "New cycle detection - Previous state: LastImageVersion=$($deploymentState.LastImageVersion), LastTotalToReplace=$($deploymentState.LastTotalToReplace)" -Level Trace
    
    # Check if image version changed (only if we have a previous version to compare against)
    if ($deploymentState.LastImageVersion -and $deploymentState.LastImageVersion -ne $currentImageVersion -and $currentImageVersion -ne "N/A") {
        $isNewCycle = $true
        $resetReason = "Image version changed from $($deploymentState.LastImageVersion) to $currentImageVersion"
        Write-LogEntry -Message "New cycle detection - Image version changed detected" -Level Trace
    }
    
    # Check if we completed the previous cycle (no hosts to replace) and now have new hosts to replace
    # Additional safeguards:
    # - Previous cycle must have been truly complete (LastTotalToReplace was 0)
    # - No running deployments (we're not still in the middle of the previous cycle)
    # - No hosts in drain mode (cleanup phase still in progress)
    # - Must have actually had a previous cycle (LastImageVersion exists)
    $hostsInDrain = ($sessionHostsFiltered | Where-Object { -not $_.AllowNewSession }).Count
    
    Write-LogEntry -Message "New cycle detection - Cycle completion check: LastToReplace=$($deploymentState.LastTotalToReplace), CurrentToReplace=$totalToReplace, Deploying=$($runningDeployments.Count), InDrain=$hostsInDrain, HasPrevious=$($null -ne $deploymentState.LastImageVersion)" -Level Trace
    
    if ($deploymentState.LastTotalToReplace -eq 0 -and 
        $totalToReplace -gt 0 -and 
        $runningDeployments.Count -eq 0 -and 
        $hostsInDrain -eq 0 -and
        $deploymentState.LastImageVersion) {
        $isNewCycle = $true
        $resetReason = "Starting new update cycle with $totalToReplace hosts to replace (previous cycle was complete: 0 to replace, 0 deploying, 0 draining)"
    }
    
    # Reset progressive scale-up for new cycle
    if ($isNewCycle) {
        Write-LogEntry -Message "Detected new update cycle: $resetReason"
        Write-LogEntry -Message "Resetting progressive scale-up to initial percentage"
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
    
    # Check if there's a pending host mapping from a previous failed deployment
    if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
        $deploymentState = Get-DeploymentState
        if ($deploymentState.PendingHostMappings -and $deploymentState.PendingHostMappings -ne '{}') {
            try {
                $hostPropertyMapping = $deploymentState.PendingHostMappings | ConvertFrom-Json -AsHashtable
                Write-LogEntry -Message "Loaded {0} pending host mapping(s) from previous run for failed deployment recovery" -StringValues $hostPropertyMapping.Count
            }
            catch {
                Write-LogEntry -Message "Failed to parse pending host mappings: $_" -Level Warning
                $hostPropertyMapping = @{}
            }
        }
    }
    
    # SAFETY CHECK: Verify any previously deployed new hosts are available before deleting more old capacity
    # This prevents cascading capacity loss if previous deployments created VMs that didn't register properly
    if (-not $newHostAvailability.SafeToProceed -and $newHostAvailability.TotalNewHosts -gt 0) {
        Write-LogEntry -Message "SAFETY CHECK FAILED: {0}" -StringValues $newHostAvailability.Message -Level Warning
        Write-LogEntry -Message "Halting DeleteFirst mode - will not delete old hosts until existing new hosts become available" -Level Warning
        Write-LogEntry -Message "This prevents further capacity loss when previous deployments have hosts that aren't accessible" -Level Warning
        # Skip the entire delete/deploy cycle - exit DeleteFirst flow
    }
    else {
        if ($newHostAvailability.TotalNewHosts -gt 0) {
            Write-LogEntry -Message "SAFETY CHECK PASSED: {0}" -StringValues $newHostAvailability.Message
        }

    if ($hostPoolReplacementPlan.PossibleSessionHostDeleteCount -gt 0 -and $hostPoolReplacementPlan.SessionHostsPendingDelete.Count -gt 0) {
        Write-LogEntry -Message "We can decommission {0} session hosts from this list: {1}" -StringValues $hostPoolReplacementPlan.SessionHostsPendingDelete.Count, ($hostPoolReplacementPlan.SessionHostsPendingDelete.SessionHostName -join ',')
        
        # Capture the names and dedicated host properties of hosts being deleted so we can reuse them
        $deletedSessionHostNames = $hostPoolReplacementPlan.SessionHostsPendingDelete.SessionHostName
        Write-LogEntry -Message "Deleted host names will be available for reuse: {0}" -StringValues ($deletedSessionHostNames -join ',') -Level Trace
        
        # Build mapping of hostname to dedicated host properties for reuse (merge with existing from previous run)
        foreach ($sessionHost in $hostPoolReplacementPlan.SessionHostsPendingDelete) {
            if ($sessionHost.HostId -or $sessionHost.HostGroupId) {
                # Only add if not already in mapping (preserve previous mappings)
                if (-not $hostPropertyMapping.ContainsKey($sessionHost.SessionHostName)) {
                    $hostPropertyMapping[$sessionHost.SessionHostName] = @{
                        HostId      = $sessionHost.HostId
                        HostGroupId = $sessionHost.HostGroupId
                        Zones       = $sessionHost.Zones
                    }
                    Write-LogEntry -Message "Captured dedicated host properties for {0}: HostId={1}, HostGroupId={2}, Zones={3}" -StringValues $sessionHost.SessionHostName, $sessionHost.HostId, $sessionHost.HostGroupId, ($sessionHost.Zones -join ', ') -Level Trace
                }
            }
        }
        
        # Save host property mapping to deployment state BEFORE deletion attempt (for recovery if deletion succeeds but deployment fails)
        if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
            $deploymentState = Get-DeploymentState
            if ($hostPropertyMapping.Count -gt 0) {
                $deploymentState.PendingHostMappings = ($hostPropertyMapping | ConvertTo-Json -Compress)
                Write-LogEntry -Message "Saved {0} host property mapping(s) to deployment state before deletion" -StringValues $hostPropertyMapping.Count -Level Trace
            }
            else {
                $deploymentState.PendingHostMappings = '{}'
            }
            Save-DeploymentState -DeploymentState $deploymentState
        }
        
        # Decommission session hosts
        $removeEntraDevice = Read-FunctionAppSetting RemoveEntraDevice
        $removeIntuneDevice = Read-FunctionAppSetting RemoveIntuneDevice
        
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
        
        # Wait for Azure to complete resource cleanup before reusing names
        if ($deletionResults.SuccessfulDeletions.Count -gt 0) {
            Write-LogEntry -Message "Verifying deletion completion for {0} VM(s) before reusing names..." -StringValues $deletionResults.SuccessfulDeletions.Count
            
            $maxWaitMinutes = 5
            $pollIntervalSeconds = 30
            $startTime = Get-Date
            $timeoutTime = $startTime.AddMinutes($maxWaitMinutes)
            
            # Build list of VMs to verify with their URIs
            $vmsToVerify = @()
            foreach ($deletedName in $deletionResults.SuccessfulDeletions) {
                # Find the session host to get its resource ID
                $sessionHost = $sessionHosts | Where-Object { $_.SessionHostName -eq $deletedName } | Select-Object -First 1
                if (-not $sessionHost) {
                    Write-LogEntry -Message "Warning: Could not find resource ID for deleted host {0}, skipping verification" -StringValues $deletedName -Level Warning
                    continue
                }
                
                $vmName = $sessionHost.resourceId.Split('/')[-1]
                $vmUri = "$(Get-ResourceManagerUri)$($sessionHost.ResourceId)?api-version=2024-03-01"
                
                $vmsToVerify += [PSCustomObject]@{
                    Name = $vmName
                    Uri  = $vmUri
                }
            }
            
            # Poll all VMs until all are gone or timeout
            $checkCount = 0
            while ((Get-Date) -lt $timeoutTime -and $vmsToVerify.Count -gt 0) {
                $checkCount++
                $elapsedSeconds = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)
                Write-LogEntry -Message "Verification check {0} at {1}s: Checking {2} remaining VM(s)..." -StringValues $checkCount, $elapsedSeconds, $vmsToVerify.Count -Level Trace
                
                $stillExist = @()
                foreach ($vm in $vmsToVerify) {
                    try {
                        $vmCheck = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $vm.Uri -ErrorAction SilentlyContinue
                        
                        if ($null -eq $vmCheck -or $vmCheck.error.code -eq 'ResourceNotFound') {
                            Write-LogEntry -Message "VM {0} deletion confirmed" -StringValues $vm.Name -Level Trace
                        }
                        else {
                            $stillExist += $vm
                        }
                    }
                    catch {
                        # Exception likely means VM not found, which is what we want
                        Write-LogEntry -Message "VM {0} deletion confirmed" -StringValues $vm.Name -Level Trace
                    }
                }
                
                $vmsToVerify = $stillExist
                
                if ($vmsToVerify.Count -gt 0 -and (Get-Date) -lt $timeoutTime) {
                    Write-LogEntry -Message "{0} VM(s) still exist, waiting {1} seconds before next check..." -StringValues $vmsToVerify.Count, $pollIntervalSeconds -Level Trace
                    Start-Sleep -Seconds $pollIntervalSeconds
                }
            }
            
            if ($vmsToVerify.Count -gt 0) {
                $unconfirmedNames = ($vmsToVerify | ForEach-Object { $_.Name }) -join ', '
                Write-LogEntry -Message "Warning: {0} VM(s) still exist after {1} minutes - proceeding anyway but deployment may fail: {2}" -StringValues $vmsToVerify.Count, $maxWaitMinutes, $unconfirmedNames -Level Warning
            }
            else {
                Write-LogEntry -Message "All deleted VMs confirmed removed from Azure"
            }
        }
        
        # Only use successfully deleted names for reuse
        $deletedSessionHostNames = $deletionResults.SuccessfulDeletions
        
        # Only deploy as many hosts as were actually deleted (not planned)
        # If hosts were drained but not deleted yet, they're still taking up space
        if ($deletionResults.SuccessfulDeletions.Count -lt $hostPoolReplacementPlan.PossibleDeploymentsCount) {
            Write-LogEntry -Message "Delete-First mode: Reducing deployments from {0} to {1} to match actual successful deletions (some hosts are still draining)" -StringValues $hostPoolReplacementPlan.PossibleDeploymentsCount, $deletionResults.SuccessfulDeletions.Count -Level Warning
            $hostPoolReplacementPlan.PossibleDeploymentsCount = $deletionResults.SuccessfulDeletions.Count
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
        
        try {
            $deploymentResult = Deploy-SessionHosts -ARMToken $ARMToken -NewSessionHostsCount $hostPoolReplacementPlan.PossibleDeploymentsCount -ExistingSessionHostNames $existingSessionHostNames -PreferredSessionHostNames $deletedSessionHostNames -PreferredHostProperties $hostPropertyMapping
            
            # Log deployment submission immediately for workbook visibility
            Write-LogEntry -Message "Deployment submitted: {0} VMs requested, deployment name: {1}" -StringValues $deploymentResult.SessionHostCount, $deploymentResult.DeploymentName
            
            # Update deployment state for progressive scale-up tracking
            if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
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
    } # End of safety check else block
} else {
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
            if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
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
        
        # Decommission session hosts
        $removeEntraDevice = Read-FunctionAppSetting RemoveEntraDevice
        $removeIntuneDevice = Read-FunctionAppSetting RemoveIntuneDevice
        
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
                Write-LogEntry -Message "Successfully deleted {0} session host(s): {1}" -StringValues $deletionResults.SuccessfulDeletions.Count, ($deletionResults.SuccessfulDeletions -join ', ')
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

$metricsLog = @{
    TotalSessionHosts       = $sessionHosts.Count
    EnabledForAutomation    = $sessionHostsFiltered.Count
    TargetCount             = if ($hostPoolReplacementPlan.TargetSessionHostCount) { $hostPoolReplacementPlan.TargetSessionHostCount } else { 0 }
    ToReplace               = if ($hostPoolReplacementPlan.TotalSessionHostsToReplace) { $hostPoolReplacementPlan.TotalSessionHostsToReplace } else { 0 }
    ToReplacePercentage     = if ($sessionHostsFiltered.Count -gt 0) { [math]::Round(($hostPoolReplacementPlan.TotalSessionHostsToReplace / $sessionHostsFiltered.Count) * 100, 1) } else { 0 }
    InDrain                 = $hostsInDrainMode
    PendingDelete           = $hostPoolReplacementPlan.SessionHostsPendingDelete.Count
    ShutdownRetention       = $shutdownRetentionCount
    ToDeployNow             = $remainingToDeploy
    RunningDeployments      = $currentlyDeploying
    NewHostsTotal           = $newHostAvailability.TotalNewHosts
    NewHostsAvailable       = $newHostAvailability.AvailableCount
    NewHostsAvailablePct    = $newHostAvailability.AvailablePercentage
    NewHostsSafeToProceed   = $newHostAvailability.SafeToProceed
    LatestImageVersion      = if ($latestImageVersion.Version) { $latestImageVersion.Version } else { "N/A" }
    LatestImageDate         = $latestImageVersion.Date
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

# Log completion timestamp for workbook visibility
Write-LogEntry -Message "SCHEDULE | Function execution completed at: {0}" -StringValues (Get-Date -AsUTC -Format 'o')