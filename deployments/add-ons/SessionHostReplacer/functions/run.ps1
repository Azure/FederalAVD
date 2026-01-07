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
$targetSessionHostCount = Read-FunctionAppSetting TargetSessionHostCount

Write-LogEntry -Message "SETTINGS | ReplacementMode: {0} | MinimumDrainMinutes: {1} | DrainGracePeriodHours: {2} | MinimumCapacityPercent: {3} | MaxDeletionsPerCycle: {4} | EnableProgressiveScaleUp: {5} | InitialDeploymentPercent: {6} | ScaleUpIncrementPercent: {7} | SuccessfulRunsBeforeScaleUp: {8} | MaxDeploymentBatchSize: {9} | TargetSessionHostCount: {10}" -StringValues $replacementMode, $minimumDrainMinutes, $drainGracePeriodHours, $minimumCapacityPercentage, $maxDeletionsPerCycle, $enableProgressiveScaleUp, $initialDeploymentPercentage, $scaleUpIncrementPercentage, $successfulRunsBeforeScaleUp, $maxDeploymentBatchSize, $targetSessionHostCount -Level Information

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

# Get session hosts and update tags if needed.
$sessionHosts = Get-SessionHosts -ARMToken $ARMToken
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
                    Write-LogEntry -Message "Clearing pending host mappings after successful deployment" -Level Verbose
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
                Write-LogEntry "Previous deployment succeeded. ConsecutiveSuccesses: $($deploymentState.ConsecutiveSuccesses), CurrentPercentage: $($deploymentState.CurrentPercentage)%"
            }
            elseif ($previousDeploymentStatus.Failed) {
                Write-LogEntry "Previous deployment failed. Cleaning up partial resources before redeployment." -Level Warning
                
                # Acquire Graph token for device cleanup if enabled
                $GraphToken = $null
                $removeEntraDevice = Read-FunctionAppSetting RemoveEntraDevice
                $removeIntuneDevice = Read-FunctionAppSetting RemoveIntuneDevice
                
                if ($removeEntraDevice -or $removeIntuneDevice) {
                    try {
                        $graphEndpoint = Get-GraphEndpoint
                        $GraphToken = Get-AccessToken -ResourceUri $graphEndpoint
                        
                        if ([string]::IsNullOrEmpty($GraphToken)) {
                            Write-LogEntry "Warning: Could not acquire Graph token for device cleanup" -Level Warning
                        }
                    }
                    catch {
                        Write-LogEntry "Warning: Failed to acquire Graph token for device cleanup: $_" -Level Warning
                    }
                }
                
                # Clean up the failed deployment and its partial resources
                $failedDeploymentInfo = @([PSCustomObject]@{
                    DeploymentName = $deploymentState.LastDeploymentName
                })
                
                try {
                    Remove-FailedDeploymentArtifacts -ARMToken $ARMToken -GraphToken $GraphToken -FailedDeployments $failedDeploymentInfo -RegisteredSessionHostNames $sessionHosts.SessionHostName -RemoveEntraDevice $removeEntraDevice -RemoveIntuneDevice $removeIntuneDevice
                    Write-LogEntry "Completed cleanup of failed deployment artifacts" -Level Information
                }
                catch {
                    Write-LogEntry "Error during failed deployment cleanup: $_" -Level Error
                }
                
                # Clear pending host mappings (starting fresh)
                if ($deploymentState.PendingHostMappings -and $deploymentState.PendingHostMappings -ne '{}') {
                    Write-LogEntry -Message "Clearing pending host mappings after failed deployment cleanup" -Level Verbose
                    $deploymentState.PendingHostMappings = '{}'
                }
                
                # Reset on failure
                $deploymentState.ConsecutiveSuccesses = 0
                $deploymentState.CurrentPercentage = $initialDeploymentPercentage
                $deploymentState.LastStatus = 'Failed'                
                Write-LogEntry "Reset consecutive successes to 0, CurrentPercentage: $($deploymentState.CurrentPercentage)%" -Level Warning
            }
            elseif ($previousDeploymentStatus.Running) {
                Write-LogEntry "Previous deployment is still running. Will check again on next run." -Level Warning
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

# Get running and failed deployments
$deploymentsInfo = Get-Deployments -ARMToken $ARMToken
$runningDeployments = $deploymentsInfo.RunningDeployments
$failedDeployments = $deploymentsInfo.FailedDeployments
Write-LogEntry -Message "Found {0} running deployments and {1} failed deployments" -StringValues $runningDeployments.Count, $failedDeployments.Count

# Clean up failed deployments and orphaned VMs
if ($failedDeployments.Count -gt 0) {
    Write-LogEntry -Message "Processing {0} failed deployments for cleanup" -StringValues $failedDeployments.Count
    Remove-FailedDeploymentArtifacts -ARMToken $ARMToken -FailedDeployments $failedDeployments -RegisteredSessionHostNames $sessionHostsFiltered.SessionHostName
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

# Get number session hosts to deploy
$hostPoolDecisions = Get-HostPoolDecisions -SessionHosts $sessionHostsFiltered -RunningDeployments $runningDeployments -LatestImageVersion $latestImageVersion -AllowImageVersionRollback $allowImageVersionRollback

# Check if we're starting a new update cycle and reset progressive scale-up if needed
if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
    $deploymentState = Get-DeploymentState
    $currentImageVersion = if ($latestImageVersion.Version) { $latestImageVersion.Version } else { "N/A" }
    $totalToReplace = if ($hostPoolDecisions.TotalSessionHostsToReplace) { $hostPoolDecisions.TotalSessionHostsToReplace } else { 0 }
    
    # Detect if we're starting a new update cycle
    $isNewCycle = $false
    $resetReason = ""
    
    # Log current state for debugging
    Write-LogEntry -Message "New cycle detection - Current state: ImageVersion=$currentImageVersion, ToReplace=$totalToReplace, RunningDeployments=$($runningDeployments.Count)" -Level Verbose
    Write-LogEntry -Message "New cycle detection - Previous state: LastImageVersion=$($deploymentState.LastImageVersion), LastTotalToReplace=$($deploymentState.LastTotalToReplace)" -Level Verbose
    
    # Check if image version changed (only if we have a previous version to compare against)
    if ($deploymentState.LastImageVersion -and $deploymentState.LastImageVersion -ne $currentImageVersion -and $currentImageVersion -ne "N/A") {
        $isNewCycle = $true
        $resetReason = "Image version changed from $($deploymentState.LastImageVersion) to $currentImageVersion"
        Write-LogEntry -Message "New cycle detection - Image version changed detected" -Level Verbose
    }
    
    # Check if we completed the previous cycle (no hosts to replace) and now have new hosts to replace
    # Additional safeguards:
    # - Previous cycle must have been truly complete (LastTotalToReplace was 0)
    # - No running deployments (we're not still in the middle of the previous cycle)
    # - No hosts in drain mode (cleanup phase still in progress)
    # - Must have actually had a previous cycle (LastImageVersion exists)
    $hostsInDrain = ($sessionHostsFiltered | Where-Object { -not $_.AllowNewSession }).Count
    
    Write-LogEntry -Message "New cycle detection - Cycle completion check: LastToReplace=$($deploymentState.LastTotalToReplace), CurrentToReplace=$totalToReplace, Deploying=$($runningDeployments.Count), InDrain=$hostsInDrain, HasPrevious=$($null -ne $deploymentState.LastImageVersion)" -Level Verbose
    
    if ($deploymentState.LastTotalToReplace -eq 0 -and 
        $totalToReplace -gt 0 -and 
        $runningDeployments.Count -eq 0 -and 
        $hostsInDrain -eq 0 -and
        $deploymentState.LastImageVersion) {
        $isNewCycle = $true
        $resetReason = "Starting new update cycle with $totalToReplace hosts to replace (previous cycle was complete: 0 to replace, 0 deploying, 0 draining)"
        Write-LogEntry -Message "New cycle detection - Cycle completion trigger: previous cycle complete, new hosts need replacement" -Level Verbose
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
                Write-LogEntry -Message "Loaded {0} pending host mapping(s) from previous run for failed deployment recovery" -StringValues $hostPropertyMapping.Count -Level Information
            }
            catch {
                Write-LogEntry -Message "Failed to parse pending host mappings: $_" -Level Warning
                $hostPropertyMapping = @{}
            }
        }
    }
    
    if ($hostPoolDecisions.PossibleSessionHostDeleteCount -gt 0 -and $hostPoolDecisions.SessionHostsPendingDelete.Count -gt 0) {
        Write-LogEntry -Message "We can decommission {0} session hosts from this list: {1}" -StringValues $hostPoolDecisions.SessionHostsPendingDelete.Count, ($hostPoolDecisions.SessionHostsPendingDelete.SessionHostName -join ',')
        
        # Capture the names and dedicated host properties of hosts being deleted so we can reuse them
        $deletedSessionHostNames = $hostPoolDecisions.SessionHostsPendingDelete.SessionHostName
        Write-LogEntry -Message "Deleted host names will be available for reuse: {0}" -StringValues ($deletedSessionHostNames -join ',') -Level Verbose
        
        # Build mapping of hostname to dedicated host properties for reuse (merge with existing from previous run)
        foreach ($sessionHost in $hostPoolDecisions.SessionHostsPendingDelete) {
            if ($sessionHost.HostId -or $sessionHost.HostGroupId) {
                # Only add if not already in mapping (preserve previous mappings)
                if (-not $hostPropertyMapping.ContainsKey($sessionHost.SessionHostName)) {
                    $hostPropertyMapping[$sessionHost.SessionHostName] = @{
                        HostId      = $sessionHost.HostId
                        HostGroupId = $sessionHost.HostGroupId
                        Zones       = $sessionHost.Zones
                    }
                    Write-LogEntry -Message "Captured dedicated host properties for {0}: HostId={1}, HostGroupId={2}, Zones={3}" -StringValues $sessionHost.SessionHostName, $sessionHost.HostId, $sessionHost.HostGroupId, ($sessionHost.Zones -join ', ') -Level Verbose
                }
            }
        }
        
        # Save host property mapping to deployment state BEFORE deletion attempt (for recovery if deletion succeeds but deployment fails)
        if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
            $deploymentState = Get-DeploymentState
            if ($hostPropertyMapping.Count -gt 0) {
                $deploymentState.PendingHostMappings = ($hostPropertyMapping | ConvertTo-Json -Compress)
                Write-LogEntry -Message "Saved {0} host property mapping(s) to deployment state before deletion" -StringValues $hostPropertyMapping.Count -Level Verbose
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
                    Write-LogEntry "CRITICAL ERROR: Get-AccessToken returned null or empty Graph token but device cleanup is enabled." -Level Error
                    Write-LogEntry "HINT: Ensure the managed identity has Directory.ReadWrite.All (for Entra ID) and DeviceManagementManagedDevices.ReadWrite.All (for Intune) permissions" -Level Error
                    Write-LogEntry "Delete-First mode cannot proceed without device cleanup capability - hostname reuse will fail" -Level Error
                    throw "Graph token acquisition failed but device cleanup is required in DeleteFirst mode"
                }
            }
            catch {
                Write-LogEntry "CRITICAL ERROR: Failed to acquire Graph access token but device cleanup is enabled: $_" -Level Error
                Write-LogEntry "HINT: Ensure the managed identity has Cloud Device Administrator role (for Entra ID) and DeviceManagementManagedDevices.ReadWrite.All (for Intune)" -Level Error
                Write-LogEntry "Delete-First mode cannot proceed without device cleanup capability - hostname reuse will fail" -Level Error
                throw "Graph token acquisition failed but device cleanup is required in Delete-First mode"
            }
        }
        
        # Perform deletion
        $deletionResults = Remove-SessionHosts -ARMToken $ARMToken -GraphToken $GraphToken -SessionHostsPendingDelete $hostPoolDecisions.SessionHostsPendingDelete -RemoveEntraDevice $removeEntraDevice -RemoveIntuneDevice $removeIntuneDevice
        
        # Check deletion results
        if ($deletionResults.FailedDeletions.Count -gt 0) {
            Write-LogEntry -Message "CRITICAL ERROR: {0} session host deletion(s) failed in Delete-First mode" -StringValues $deletionResults.FailedDeletions.Count -Level Error
            foreach ($failure in $deletionResults.FailedDeletions) {
                Write-LogEntry -Message "  - {0}: {1}" -StringValues $failure.SessionHostName, $failure.Reason -Level Error
            }
            Write-LogEntry -Message "Delete-First mode cannot proceed with deployments - hostname conflicts will occur if we try to reuse failed deletion names" -Level Error
            Write-LogEntry -Message "Successful deletions: {0}" -StringValues ($deletionResults.SuccessfulDeletions -join ', ') -Level Verbose
            throw "Session host deletion failures in Delete-First mode prevent safe hostname reuse"
        }
        
        Write-LogEntry -Message "Successfully deleted {0} session host(s): {1}" -StringValues $deletionResults.SuccessfulDeletions.Count, ($deletionResults.SuccessfulDeletions -join ', ')
        
        # Wait for Azure to complete resource cleanup before reusing names
        if ($deletionResults.SuccessfulDeletions.Count -gt 0) {
            Write-LogEntry -Message "Verifying deletion completion for {0} VM(s) before reusing names..." -StringValues $deletionResults.SuccessfulDeletions.Count -Level Information
            
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
                Write-LogEntry -Message "Verification check {0} at {1}s: Checking {2} remaining VM(s)..." -StringValues $checkCount, $elapsedSeconds, $vmsToVerify.Count -Level Verbose
                
                $stillExist = @()
                foreach ($vm in $vmsToVerify) {
                    try {
                        $vmCheck = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $vm.Uri -ErrorAction SilentlyContinue
                        
                        if ($null -eq $vmCheck -or $vmCheck.error.code -eq 'ResourceNotFound') {
                            Write-LogEntry -Message "VM {0} deletion confirmed" -StringValues $vm.Name -Level Verbose
                        }
                        else {
                            $stillExist += $vm
                        }
                    }
                    catch {
                        # Exception likely means VM not found, which is what we want
                        Write-LogEntry -Message "VM {0} deletion confirmed" -StringValues $vm.Name -Level Verbose
                    }
                }
                
                $vmsToVerify = $stillExist
                
                if ($vmsToVerify.Count -gt 0 -and (Get-Date) -lt $timeoutTime) {
                    Write-LogEntry -Message "{0} VM(s) still exist, waiting {1} seconds before next check..." -StringValues $vmsToVerify.Count, $pollIntervalSeconds -Level Verbose
                    Start-Sleep -Seconds $pollIntervalSeconds
                }
            }
            
            if ($vmsToVerify.Count -gt 0) {
                $unconfirmedNames = ($vmsToVerify | ForEach-Object { $_.Name }) -join ', '
                Write-LogEntry -Message "Warning: {0} VM(s) still exist after {1} minutes - proceeding anyway but deployment may fail: {2}" -StringValues $vmsToVerify.Count, $maxWaitMinutes, $unconfirmedNames -Level Warning
            }
            else {
                Write-LogEntry -Message "All deleted VMs confirmed removed from Azure" -Level Information
            }
            
            # Wait for Entra ID replication after device deletions
            if ($removeEntraDevice -or $removeIntuneDevice) {
                Write-LogEntry -Message "Waiting 1 minute for Entra ID to replicate device deletions..." -Level Information
                Start-Sleep -Seconds 60
            }
        }
        
        # Only use successfully deleted names for reuse
        $deletedSessionHostNames = $deletionResults.SuccessfulDeletions
        
        # Only deploy as many hosts as were actually deleted (not planned)
        # If hosts were drained but not deleted yet, they're still taking up space
        if ($deletionResults.SuccessfulDeletions.Count -lt $hostPoolDecisions.PossibleDeploymentsCount) {
            Write-LogEntry -Message "Delete-First mode: Reducing deployments from {0} to {1} to match actual successful deletions (some hosts are still draining)" -StringValues $hostPoolDecisions.PossibleDeploymentsCount, $deletionResults.SuccessfulDeletions.Count -Level Warning
            $hostPoolDecisions.PossibleDeploymentsCount = $deletionResults.SuccessfulDeletions.Count
        }
    }
    
    # STEP 2: Deploy replacement session hosts
    if ($hostPoolDecisions.PossibleDeploymentsCount -gt 0) {
        Write-LogEntry -Message "We will deploy {0} replacement session hosts" -StringValues $hostPoolDecisions.PossibleDeploymentsCount
        
        # In DeleteFirst mode: exclude deleted host names so they can be reused
        # Calculate existing names: all current hosts + running deployments - just deleted hosts
        $currentExistingNames = (@($sessionHosts.SessionHostName) + @($hostPoolDecisions.ExistingSessionHostNames)) | Sort-Object | Select-Object -Unique
        $existingSessionHostNames = $currentExistingNames | Where-Object { $_ -notin $deletedSessionHostNames }
        
        Write-LogEntry -Message "Excluded {0} deleted host name(s) from existing list to allow reuse" -StringValues $deletedSessionHostNames.Count -Level Verbose
        Write-LogEntry -Message "Available for reuse: {0}" -StringValues ($deletedSessionHostNames -join ',') -Level Verbose
        
        try {
            $deploymentResult = Deploy-SessionHosts -ARMToken $ARMToken -NewSessionHostsCount $hostPoolDecisions.PossibleDeploymentsCount -ExistingSessionHostNames $existingSessionHostNames -PreferredSessionHostNames $deletedSessionHostNames -PreferredHostProperties $hostPropertyMapping
            
            # Log deployment submission immediately for workbook visibility
            Write-LogEntry -Message "Deployment submitted: {0} VMs requested, deployment name: {1}" -StringValues $deploymentResult.SessionHostCount, $deploymentResult.DeploymentName -Level Information
            
            # Update deployment state for progressive scale-up tracking
            if (Read-FunctionAppSetting EnableProgressiveScaleUp) {
                $deploymentState = Get-DeploymentState               
                # Save deployment info for checking on next run
                $deploymentState.LastDeploymentName = $deploymentResult.DeploymentName
                $deploymentState.LastDeploymentCount = $deploymentResult.SessionHostCount
                $deploymentState.LastDeploymentNeeded = $hostPoolDecisions.PossibleDeploymentsCount
                $deploymentState.LastDeploymentPercentage = if ($hostPoolDecisions.PossibleDeploymentsCount -gt 0) { [Math]::Round(($deploymentResult.SessionHostCount / $hostPoolDecisions.PossibleDeploymentsCount) * 100) } else { 0 }
                $deploymentState.LastTimestamp = Get-Date -AsUTC -Format 'o'                
                Write-LogEntry "Deployment submitted: $($deploymentResult.DeploymentName). Status will be checked on next run."
                
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
} else {
    # ================================================================================================
    # SIDE-BY-SIDE MODE: Deploy new hosts first, then delete old ones
    # ================================================================================================
    Write-LogEntry -Message "Using SIDE-BY-SIDE mode: will deploy new hosts before deleting old ones"
    
    # STEP 1: Deploy new session hosts first
    $deploymentResult = $null
    if ($hostPoolDecisions.PossibleDeploymentsCount -gt 0) {
        Write-LogEntry -Message "We will deploy {0} session hosts" -StringValues $hostPoolDecisions.PossibleDeploymentsCount
        # Deploy session hosts - use SessionHostName (hostname from FQDN) not VMName (Azure VM resource name)
        $existingSessionHostNames = (@($sessionHosts.SessionHostName) + @($hostPoolDecisions.ExistingSessionHostNames)) | Sort-Object | Select-Object -Unique
        
        try {
            $deploymentResult = Deploy-SessionHosts -ARMToken $ARMToken -NewSessionHostsCount $hostPoolDecisions.PossibleDeploymentsCount -ExistingSessionHostNames $existingSessionHostNames
            
            # Log deployment submission immediately for workbook visibility
            Write-LogEntry -Message "Deployment submitted: {0} VMs requested, deployment name: {1}" -StringValues $deploymentResult.SessionHostCount, $deploymentResult.DeploymentName -Level Information
            
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
                
                Write-LogEntry "Deployment submitted: $($deploymentResult.DeploymentName). Status will be checked on next run."
                
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

    # STEP 2: Delete session hosts second
    if ($hostPoolDecisions.PossibleSessionHostDeleteCount -gt 0 -and $hostPoolDecisions.SessionHostsPendingDelete.Count -gt 0) {
        Write-LogEntry -Message "We will decommission {0} session hosts from this list: {1}" -StringValues $hostPoolDecisions.SessionHostsPendingDelete.Count, ($hostPoolDecisions.SessionHostsPendingDelete.SessionHostName -join ',') -Level Verbose
        
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
                    Write-LogEntry "HINT: Ensure the managed identity has Directory.ReadWrite.All (for Entra ID) and DeviceManagementManagedDevices.ReadWrite.All (for Intune) permissions" -Level Warning
                    $GraphToken = $null
                }
            }
            catch {
                Write-Warning "Failed to acquire Graph access token: $_. Device cleanup will be skipped."
                Write-LogEntry "HINT: Ensure the managed identity has Cloud Device Administrator role (for Entra ID) and DeviceManagementManagedDevices.ReadWrite.All (for Intune)" -Level Warning
                $GraphToken = $null
            }
        }
        
        # Perform deletion and log results (SideBySide mode doesn't halt on failures since name reuse isn't critical)
        $deletionResults = $null
        If ($GraphToken) {
            $deletionResults = Remove-SessionHosts -ARMToken $ARMToken -GraphToken $GraphToken -SessionHostsPendingDelete $hostPoolDecisions.SessionHostsPendingDelete -RemoveEntraDevice $removeEntraDevice -RemoveIntuneDevice $removeIntuneDevice
        }
        Else {
            $deletionResults = Remove-SessionHosts -ARMToken $ARMToken -GraphToken $null -SessionHostsPendingDelete $hostPoolDecisions.SessionHostsPendingDelete -RemoveEntraDevice $false -RemoveIntuneDevice $false
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
        }
    }
}

# Log completion timestamp for workbook visibility
Write-LogEntry -Message "SCHEDULE | Function execution completed at: {0}" -StringValues (Get-Date -AsUTC -Format 'o')

# Log comprehensive metrics for monitoring dashboard (after all operations complete)
$hostsInDrainMode = ($sessionHostsFiltered | Where-Object { -not $_.AllowNewSession }).Count

# Calculate current deployment status accounting for just-submitted deployments
$currentlyDeploying = $runningDeployments.Count
$remainingToDeploy = $hostPoolDecisions.PossibleDeploymentsCount
if ($deploymentResult) {
    # A deployment was just submitted this run, so it's now running
    $currentlyDeploying += $deploymentResult.SessionHostCount
    # Reduce the remaining count by what was just deployed
    $remainingToDeploy = [Math]::Max(0, $remainingToDeploy - $deploymentResult.SessionHostCount)
}

$metricsLog = @{
    TotalSessionHosts    = $sessionHosts.Count
    EnabledForAutomation = $sessionHostsFiltered.Count
    TargetCount          = if ($hostPoolDecisions.TargetSessionHostCount) { $hostPoolDecisions.TargetSessionHostCount } else { 0 }
    ToReplace            = if ($hostPoolDecisions.TotalSessionHostsToReplace) { $hostPoolDecisions.TotalSessionHostsToReplace } else { 0 }
    ToReplacePercentage  = if ($sessionHostsFiltered.Count -gt 0) { [math]::Round(($hostPoolDecisions.TotalSessionHostsToReplace / $sessionHostsFiltered.Count) * 100, 1) } else { 0 }
    InDrain              = $hostsInDrainMode
    PendingDelete        = $hostPoolDecisions.SessionHostsPendingDelete.Count
    ToDeployNow          = $remainingToDeploy
    RunningDeployments   = $currentlyDeploying
    LatestImageVersion   = if ($latestImageVersion.Version) { $latestImageVersion.Version } else { "N/A" }
    LatestImageDate      = $latestImageVersion.Date
}

# Log image metadata for workbook visibility
if ($latestImageVersion.Definition -like "marketplace:*") {
    # Parse marketplace identifier: "marketplace:publisher/offer/sku"
    $marketplaceParts = $latestImageVersion.Definition -replace "^marketplace:", "" -split "/"
    Write-LogEntry -Message "IMAGE_INFO | Type: Marketplace | Publisher: {0} | Offer: {1} | Sku: {2} | Version: {3}" `
        -StringValues $marketplaceParts[0], $marketplaceParts[1], $marketplaceParts[2], $latestImageVersion.Version `
        -Level Information
}
else {
    # Parse gallery path: /subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/galleries/{galleryName}/images/{imageName}
    $galleryMatch = [regex]::Match($latestImageVersion.Definition, "/galleries/([^/]+)/images/([^/]+)")
    $galleryName = $galleryMatch.Groups[1].Value
    $imageDefinition = $galleryMatch.Groups[2].Value
    Write-LogEntry -Message "IMAGE_INFO | Type: Gallery | Gallery: {0} | ImageDefinition: {1} | Version: {2}" `
        -StringValues $galleryName, $imageDefinition, $latestImageVersion.Version `
        -Level Information
}

# Check if cycle is complete (no hosts to replace, no hosts in drain, no pending deletions, no running deployments)
# If complete, remove scaling exclusion tags from all hosts
$cycleComplete = $metricsLog.ToReplace -eq 0 -and $metricsLog.InDrain -eq 0 -and $metricsLog.PendingDelete -eq 0 -and $metricsLog.RunningDeployments -eq 0

if ($cycleComplete) {
    Write-LogEntry -Message "Update cycle complete - all hosts are up to date. Removing scaling exclusion tags." -Level Information
    
    $tagScalingPlanExclusionTag = Read-FunctionAppSetting Tag_ScalingPlanExclusionTag
    $resourceManagerUri = Get-ResourceManagerUri
    
    # Only proceed if a scaling exclusion tag is configured
    if ($tagScalingPlanExclusionTag -and $tagScalingPlanExclusionTag -ne ' ') {
        $hostsWithExclusionTag = 0
        
        foreach ($sessionHost in $sessionHostsFiltered) {
            try {
                # Check if the VM has the exclusion tag by reading current tags
                $tagsUri = "$resourceManagerUri$($sessionHost.ResourceId)/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
                $vmTagsResponse = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $tagsUri
                
                $vmTags = @{}
                if ($vmTagsResponse.properties.tags) {
                    $vmTagsResponse.properties.tags.PSObject.Properties | ForEach-Object {
                        $vmTags[$_.Name] = $_.Value
                    }
                }
                
                # If the exclusion tag exists and has the SessionHostReplacer value (function-set), remove it
                if ($vmTags.ContainsKey($tagScalingPlanExclusionTag)) {
                    $tagValue = $vmTags[$tagScalingPlanExclusionTag]
                    
                    # Only remove if the tag value is 'SessionHostReplacer' (set by this function)
                    # This prevents removing admin-set tags which typically have blank values or custom strings
                    if ($tagValue -eq 'SessionHostReplacer') {
                        Write-LogEntry -Message "Removing scaling exclusion tag from $($sessionHost.SessionHostName) (value: $tagValue)" -Level Information
                        
                        # Remove the tag by setting it to null
                        $Body = @{
                            properties = @{
                                tags = @{ $tagScalingPlanExclusionTag = $null }
                            }
                            operation  = 'Merge'
                        }
                        
                        Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $tagsUri | Out-Null
                        $hostsWithExclusionTag++
                        
                        Write-LogEntry -Message "Successfully removed scaling exclusion tag from $($sessionHost.SessionHostName)" -Level Verbose
                    }
                    else {
                        Write-LogEntry -Message "Skipping removal of scaling exclusion tag from $($sessionHost.SessionHostName) - appears to be admin-set (value: '$tagValue')" -Level Information
                    }
                }
            }
            catch {
                Write-LogEntry -Message "Error removing scaling exclusion tag from $($sessionHost.SessionHostName): $($_.Exception.Message)" -Level Warning
            }
        }
        
        if ($hostsWithExclusionTag -gt 0) {
            Write-LogEntry -Message "Removed scaling exclusion tags from {0} session host(s)" -StringValues $hostsWithExclusionTag -Level Information
        }
        else {
            Write-LogEntry -Message "No scaling exclusion tags found to remove" -Level Verbose
        }
    }
    else {
        Write-LogEntry -Message "No scaling exclusion tag configured - skipping tag cleanup" -Level Verbose
    }
}

Write-LogEntry -Message "METRICS | Total: {0} | Enabled: {1} | Target: {2} | ToReplace: {3} ({4}%) | InDrain: {5} | ToDeployNow: {6} | RunningDeployments: {7} | LatestImage: {8}" `
    -StringValues $metricsLog.TotalSessionHosts, $metricsLog.EnabledForAutomation, $metricsLog.TargetCount, $metricsLog.ToReplace, $metricsLog.ToReplacePercentage, $metricsLog.InDrain, $metricsLog.ToDeployNow, $metricsLog.RunningDeployments, $metricsLog.LatestImageVersion `
    -Level Information