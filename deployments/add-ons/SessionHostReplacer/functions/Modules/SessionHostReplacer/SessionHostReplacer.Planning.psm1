# SessionHostReplacer Planning Module
# Contains session host planning and inventory functions

# Import Core and Deployment utilities
Import-Module "$PSScriptRoot\SessionHostReplacer.Core.psm1" -Force
Import-Module "$PSScriptRoot\SessionHostReplacer.Deployment.psm1" -Force
Import-Module "$PSScriptRoot\SessionHostReplacer.ImageManagement.psm1" -Force

#Region Session Host Planning

function Get-SessionHostReplacementPlan {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        [Parameter()]
        [array] $SessionHosts = @(),
        [Parameter()]
        $RunningDeployments,
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [Parameter()]
        [int] $TargetSessionHostCount = (Read-FunctionAppSetting TargetSessionHostCount),
        [Parameter()]
        [PSCustomObject] $LatestImageVersion,
        [Parameter()]
        [int] $ReplaceSessionHostOnNewImageVersionDelayDays = [int]::Parse((Read-FunctionAppSetting ReplaceSessionHostOnNewImageVersionDelayDays)),
        [Parameter()]
        [bool] $AllowImageVersionRollback = $false,
        [Parameter()]
        [bool] $EnableProgressiveScaleUp = [bool]::Parse((Read-FunctionAppSetting EnableProgressiveScaleUp)),
        [Parameter()]
        [int] $InitialDeploymentPercentage = [int]::Parse((Read-FunctionAppSetting InitialDeploymentPercentage)),
        [Parameter()]
        [int] $ScaleUpIncrementPercentage = [int]::Parse((Read-FunctionAppSetting ScaleUpIncrementPercentage)),
        [Parameter()]
        [int] $MaxDeploymentBatchSize = $(
            $setting = Read-FunctionAppSetting MaxDeploymentBatchSize
            if ([string]::IsNullOrEmpty($setting)) { 100 } else { [int]::Parse($setting) }
        ),
        [Parameter()]
        [int] $SuccessfulRunsBeforeScaleUp = [int]::Parse((Read-FunctionAppSetting SuccessfulRunsBeforeScaleUp)),
        [Parameter()]
        [string] $ReplacementMode = (Read-FunctionAppSetting ReplacementMode),
        [Parameter()]
        [int] $DrainGracePeriodHours = [int]::Parse((Read-FunctionAppSetting DrainGracePeriodHours)),
        [Parameter()]
        [int] $MinimumCapacityPercentage = $(
            $setting = Read-FunctionAppSetting MinimumCapacityPercentage
            if ([string]::IsNullOrEmpty($setting)) { 50 } else { [int]::Parse($setting) }
        ),
        [Parameter()]
        [int] $MaxDeletionsPerCycle = $(
            $setting = Read-FunctionAppSetting MaxDeletionsPerCycle
            if ([string]::IsNullOrEmpty($setting)) { 50 } else { [int]::Parse($setting) }
        )
    )
    
    Write-LogEntry -Message "We have $($SessionHosts.Count) session hosts (included in Automation)"
    
    # Auto-detect target count if not specified (TargetSessionHostCount = 0)
    if ($TargetSessionHostCount -eq 0) {
        # Get deployment state to check for stored target
        try {
            $deploymentState = Get-DeploymentState -HostPoolName $HostPoolName
            
            if ($deploymentState.TargetSessionHostCount -gt 0) {
                # Use previously stored target from ongoing replacement cycle
                $TargetSessionHostCount = $deploymentState.TargetSessionHostCount
                Write-LogEntry -Message "Auto-detect mode: Using stored target count of $TargetSessionHostCount from current replacement cycle"
            } else {
                # First run of a new replacement cycle - store current count as target
                $TargetSessionHostCount = $SessionHosts.Count
                $deploymentState.TargetSessionHostCount = $TargetSessionHostCount
                Save-DeploymentState -DeploymentState $deploymentState -HostPoolName $HostPoolName
                Write-LogEntry -Message "Auto-detect mode: Detected $TargetSessionHostCount session hosts - storing as target for this replacement cycle"
            }
        }
        catch {
            # If state storage fails, fall back to current count (stateless mode)
            $TargetSessionHostCount = $SessionHosts.Count
            Write-LogEntry -Message "Auto-detect mode: Unable to access deployment state storage. Using current count of $TargetSessionHostCount. Note: Managed identity needs 'Storage Table Data Contributor' role on storage account for persistent target tracking. Error: $_" -Level Warning
        }
    }
    
    # Determine which session hosts need replacement based on image version
    [array] $sessionHostsOldVersion = @()
    
    $latestImageAge = (New-TimeSpan -Start $LatestImageVersion.Date -End (Get-Date -AsUTC)).TotalDays
    Write-LogEntry -Message "Latest Image $($LatestImageVersion.Version) is $latestImageAge days old."
    if ($latestImageAge -ge $ReplaceSessionHostOnNewImageVersionDelayDays) {
            Write-LogEntry -Message "Latest Image age is older than (or equal) New Image Delay value $ReplaceSessionHostOnNewImageVersionDelayDays"
            
            # Log each session host's image version for debugging
            foreach ($sh in $sessionHosts) {
                Write-LogEntry -Message "Session host $($sh.SessionHostName) has image version: $($sh.ImageVersion)" -Level Trace
            }
            
            # Compare versions with rollback protection
            [array] $sessionHostsOldVersion = @()
            foreach ($sh in $sessionHosts) {
                if ($sh.ImageVersion -ne $LatestImageVersion.Version) {
                    # Check if image definition has changed
                    $imageDefinitionChanged = $false
                    if ($sh.ImageDefinition -and $LatestImageVersion.Definition) {
                        $imageDefinitionChanged = ($sh.ImageDefinition -ne $LatestImageVersion.Definition)
                        if ($imageDefinitionChanged) {
                            Write-LogEntry -Message "Session host $($sh.SessionHostName) has different image definition - VM: '$($sh.ImageDefinition)', Latest: '$($LatestImageVersion.Definition)'" -Level Trace
                        }
                    }
                    
                    if ($imageDefinitionChanged) {
                        # Image definition changed - this is a legitimate upgrade, not a rollback
                        $sessionHostsOldVersion += $sh
                    }
                    else {
                        # Same image definition, different version - check for rollback
                        $versionComparison = Compare-ImageVersion -Version1 $sh.ImageVersion -Version2 $LatestImageVersion.Version
                        
                        if ($versionComparison -lt 0) {
                            # VM version is older than latest - safe to replace
                            $sessionHostsOldVersion += $sh
                        }
                        elseif ($versionComparison -gt 0) {
                            # VM version is NEWER than "latest" - potential rollback scenario
                            if ($AllowImageVersionRollback) {
                                Write-LogEntry -Message "Session host $($sh.SessionHostName) has NEWER version '$($sh.ImageVersion)' than latest '$($LatestImageVersion.Version)' - will replace (AllowImageVersionRollback=true)" -Level Warning
                                $sessionHostsOldVersion += $sh
                            }
                            else {
                                Write-LogEntry -Message "Session host $($sh.SessionHostName) has NEWER version '$($sh.ImageVersion)' than latest '$($LatestImageVersion.Version)' - skipping replacement (AllowImageVersionRollback=false)" -Level Warning
                            }
                        }
                        else {
                            # Versions are functionally equal but string representation differs (shouldn't happen)
                        }
                    }
                }
            }
            
            Write-LogEntry -Message "Found $($sessionHostsOldVersion.Count) session hosts to replace due to image version. $($($sessionHostsOldVersion.SessionHostName) -Join ',')"
    }
    else {
        Write-LogEntry -Message "Latest Image age is less than New Image Delay value $ReplaceSessionHostOnNewImageVersionDelayDays - no session hosts will be replaced based on image version"
    }

    [array] $sessionHostsToReplace = $sessionHostsOldVersion | Select-Object -Property * -Unique
    Write-LogEntry -Message "Found $($sessionHostsToReplace.Count) session hosts to replace in total. $($($sessionHostsToReplace.SessionHostName) -join ',')"

    # Good hosts = not needing replacement AND not shutdown (shutdown VMs are deallocated and unavailable)
    $goodSessionHosts = $SessionHosts | Where-Object { 
        $_.SessionHostName -notin $sessionHostsToReplace.SessionHostName -and 
        -not $_.ShutdownTimestamp 
    }
    
    # Count shutdown hosts for logging
    $shutdownHostsCount = ($SessionHosts | Where-Object { $_.ShutdownTimestamp }).Count
    if ($shutdownHostsCount -gt 0) {
        $shutdownHostNames = ($SessionHosts | Where-Object { $_.ShutdownTimestamp }).SessionHostName -join ','
        Write-LogEntry -Message "Excluding $shutdownHostsCount shutdown session hosts from available capacity: $shutdownHostNames" -Level Verbose
    }
    
    # Count running deployment VMs - handle both ARM deployments (with SessionHostNames) and state-tracked deployments (with VirtualCount)
    $runningDeploymentVMCount = 0
    $runningDeploymentVMNames = @()
    foreach ($deployment in $runningDeployments) {
        if ($deployment.SessionHostNames -and $deployment.SessionHostNames.Count -gt 0) {
            $runningDeploymentVMCount += $deployment.SessionHostNames.Count
            $runningDeploymentVMNames += $deployment.SessionHostNames
        }
        elseif ($deployment.VirtualCount) {
            # Synthetic deployment from state - use virtual count
            $runningDeploymentVMCount += $deployment.VirtualCount
        }
    }
    
    $sessionHostsCurrentTotal = ([array]$goodSessionHosts.SessionHostName + [array]$runningDeploymentVMNames) | Select-Object -Unique
    Write-LogEntry -Message "We have $($sessionHostsCurrentTotal.Count) good session hosts including $runningDeploymentVMCount session hosts being deployed"
    Write-LogEntry -Message "We target having $TargetSessionHostCount session hosts in good shape"
    
    # Check if there are any running or recently submitted deployments - if so, don't submit new ones
    if ($runningDeployments -and $runningDeployments.Count -gt 0) {
        Write-LogEntry -Message "Found $($runningDeployments.Count) running or recently submitted deployment(s). Will not submit new deployments until these complete." -Level Warning
        $canDeploy = 0
    }
    else {
        # In DeleteFirst mode, calculate deployments based on what needs replacement (we'll delete first to make room)
        # In SideBySide mode, calculate based on buffer space (pool can temporarily double)
        if ($ReplacementMode -eq 'DeleteFirst') {
            # DeleteFirst: We can deploy as many as we need since we delete first
            $weNeedToDeploy = $TargetSessionHostCount - $sessionHostsCurrentTotal.Count
            
            if ($weNeedToDeploy -gt 0) {
                Write-LogEntry -Message "We need to deploy $weNeedToDeploy new session hosts"
                $canDeploy = $weNeedToDeploy
                Write-LogEntry -Message "DeleteFirst mode allows deploying $canDeploy session hosts (will delete first to make room)"
            }
            else {
                $canDeploy = 0
                Write-LogEntry -Message "We have enough session hosts in good shape."
            }
        }
        else {
            # SideBySide: Use buffer to allow pool to double
            $effectiveBuffer = $TargetSessionHostCount
            Write-LogEntry -Message "Automatic buffer: $effectiveBuffer session hosts (allows pool to double during rolling updates)"
            
            $canDeployUpTo = $TargetSessionHostCount + $effectiveBuffer - $SessionHosts.count - $runningDeploymentVMCount
            
            if ($canDeployUpTo -ge 0) {
                Write-LogEntry -Message "We can deploy up to $canDeployUpTo session hosts" 
                $weNeedToDeploy = $TargetSessionHostCount - $sessionHostsCurrentTotal.Count
                
                if ($weNeedToDeploy -gt 0) {
                    Write-LogEntry -Message "We need to deploy $weNeedToDeploy new session hosts"
                    $canDeploy = if ($weNeedToDeploy -gt $canDeployUpTo) { $canDeployUpTo } else { $weNeedToDeploy }
                    Write-LogEntry -Message "Buffer allows deploying $canDeploy session hosts"
                }
                else {
                    $canDeploy = 0
                    Write-LogEntry -Message "We have enough session hosts in good shape."
                }
            }
            else {
                Write-LogEntry -Message "Buffer is full. We can not deploy more session hosts"
                $canDeploy = 0
            }
        }
            
        # Apply progressive scale-up to both modes (if enabled)
        if ($EnableProgressiveScaleUp -and $canDeploy -gt 0) {
            Write-LogEntry -Message "Progressive scale-up is enabled"
            $deploymentState = Get-DeploymentState
            $currentPercentage = $InitialDeploymentPercentage
            
            if ($deploymentState.ConsecutiveSuccesses -ge $SuccessfulRunsBeforeScaleUp) {
                $scaleUpMultiplier = [Math]::Floor($deploymentState.ConsecutiveSuccesses / $SuccessfulRunsBeforeScaleUp)
                $currentPercentage = $InitialDeploymentPercentage + ($scaleUpMultiplier * $ScaleUpIncrementPercentage)
            }
            
            $currentPercentage = [Math]::Min($currentPercentage, 100)
            $percentageBasedCount = [Math]::Ceiling($canDeploy * ($currentPercentage / 100.0))
            $batchSizeLimit = if ($ReplacementMode -eq 'DeleteFirst') { $MaxDeletionsPerCycle } else { $MaxDeploymentBatchSize }
            $actualDeployCount = [Math]::Min($percentageBasedCount, $batchSizeLimit)
            $actualDeployCount = [Math]::Min($actualDeployCount, $canDeploy)
            
            Write-LogEntry -Message "Progressive scale-up: Using $currentPercentage% of $canDeploy needed = $actualDeployCount hosts (ConsecutiveSuccesses: $($deploymentState.ConsecutiveSuccesses), Max: $batchSizeLimit)"
            $canDeploy = $actualDeployCount
        }
    }
    
    # Calculate how many hosts can be deleted
    if ($ReplacementMode -eq 'DeleteFirst') {
        # DeleteFirst mode: Align deletions with deployments for predictable 1:1 replacement behavior
        # Progressive scale-up controls both deployment and deletion counts together
        $canDelete = $canDeploy
        
        # Safety floor: Never allow deletions that would drop below MinimumCapacityPercentage of target capacity
        # Use total hosts (not just "good" ones) to avoid blocking deletions when all hosts need replacement
        $minimumAbsoluteHosts = [Math]::Ceiling($TargetSessionHostCount * ($MinimumCapacityPercentage / 100.0))
        $currentTotalHosts = $SessionHosts.Count
        $maxSafeDeletions = $currentTotalHosts - $minimumAbsoluteHosts
        
        if ($canDelete -gt $maxSafeDeletions) {
            Write-LogEntry -Message "DeleteFirst mode: Safety floor triggered - limiting deletions from $canDelete to $maxSafeDeletions to maintain minimum $MinimumCapacityPercentage% capacity ($minimumAbsoluteHosts hosts)" -Level Warning
            $canDelete = $maxSafeDeletions
        }
        
        # Emergency brake: Respect the MaxDeletionsPerCycle limit
        if ($canDelete -gt $MaxDeletionsPerCycle) {
            Write-LogEntry -Message "DeleteFirst mode: MaxDeletionsPerCycle limit triggered - capping deletions from $canDelete to $MaxDeletionsPerCycle"
            $canDelete = $MaxDeletionsPerCycle
        }
        
        $canDelete = [Math]::Max($canDelete, 0)  # Ensure non-negative
        
        Write-LogEntry -Message "Delete-First mode: Will delete $canDelete hosts (aligned with $canDeploy deployments, current total: $currentTotalHosts, minimum: $minimumAbsoluteHosts at $MinimumCapacityPercentage%, max per cycle: $MaxDeletionsPerCycle)"
    }
    else {
        # SideBySide mode: Only delete when overpopulated (more hosts than target)
        $canDelete = $SessionHosts.Count - $TargetSessionHostCount
    }
    
    if ($canDelete -gt 0) {
        Write-LogEntry -Message "We need to delete $canDelete session hosts"
        if ($canDelete -gt $sessionHostsToReplace.Count) {
            Write-LogEntry -Message "Host pool is over populated"
            $goodSessionHostsToDeleteCount = $canDelete - $sessionHostsToReplace.Count
            Write-LogEntry -Message "We will delete $goodSessionHostsToDeleteCount good session hosts"
            
            # Lazy load power states for good hosts being considered for deletion
            $goodHostResourceIds = $goodSessionHosts | ForEach-Object { $_.ResourceId }
            $powerStates = Get-VMPowerStates -ARMToken $ARMToken -VMResourceIds $goodHostResourceIds
            
            # Enrich good hosts with power state
            foreach ($host in $goodSessionHosts) {
                $host | Add-Member -NotePropertyName PoweredOff -NotePropertyValue $powerStates[$host.ResourceId] -Force
            }
            
            # Sort by power state (prioritize powered-off VMs), then session count (idle hosts), then drain status, then name
            $selectedGoodHostsTotDelete = [array] ($goodSessionHosts | Sort-Object -Property @{Expression={-not $_.PoweredOff}; Ascending=$true}, @{Expression={$_.Sessions}; Ascending=$true}, @{Expression={$_.AllowNewSession}; Ascending=$true}, SessionHostName | Select-Object -First $goodSessionHostsToDeleteCount)
            Write-LogEntry -Message "Selected the following good session hosts to delete: $($($selectedGoodHostsTotDelete.VMName) -join ',')"
        }
        else {
            $selectedGoodHostsTotDelete = @()
            Write-LogEntry -Message "Host pool is not over populated"
        }
        
        # Lazy load power states for hosts to replace being considered for deletion
        $replaceHostResourceIds = $sessionHostsToReplace | ForEach-Object { $_.ResourceId }
        Write-LogEntry -Message "Querying power state for $($replaceHostResourceIds.Count) replacement candidate(s): $($sessionHostsToReplace.VMName -join ',')"
        $powerStates = Get-VMPowerStates -ARMToken $ARMToken -VMResourceIds $replaceHostResourceIds
        
        # Enrich hosts to replace with power state
        foreach ($host in $sessionHostsToReplace) {
            $host | Add-Member -NotePropertyName PoweredOff -NotePropertyValue $powerStates[$host.ResourceId] -Force
        }
        
        # Log power state results for visibility
        $poweredOffHosts = $sessionHostsToReplace | Where-Object { $_.PoweredOff }
        if ($poweredOffHosts) {
            Write-LogEntry -Message "Found $($poweredOffHosts.Count) powered-off host(s) among replacement candidates: $($poweredOffHosts.VMName -join ',')"
        }
        
        # Prioritize hosts for deletion: powered-off first, then idle, then draining, then fewest sessions
        # This ensures VMs that are already powered off are replaced before active ones
        $sortedHostsToReplace = $sessionHostsToReplace | Sort-Object -Property @{Expression={-not $_.PoweredOff}; Ascending=$true}, @{Expression={$_.Sessions}; Ascending=$true}, @{Expression={$_.AllowNewSession}; Ascending=$true}, SessionHostName
        $sessionHostsPendingDelete = (@($sortedHostsToReplace) + @($selectedGoodHostsTotDelete)) | Select-Object -First $canDelete
        
        # In SideBySide mode, apply progressive scale-up to deletions
        # In DeleteFirst mode, skip this - deletions are already controlled by deployment progressive scale-up (they're aligned 1:1)
        if ($ReplacementMode -ne 'DeleteFirst' -and $EnableProgressiveScaleUp -and $sessionHostsPendingDelete.Count -gt 0) {
            Write-LogEntry -Message "Progressive scale-up is enabled for deletions"
            $deploymentState = Get-DeploymentState
            $currentPercentage = $InitialDeploymentPercentage
            
            if ($deploymentState.ConsecutiveSuccesses -ge $SuccessfulRunsBeforeScaleUp) {
                $scaleUpMultiplier = [Math]::Floor($deploymentState.ConsecutiveSuccesses / $SuccessfulRunsBeforeScaleUp)
                $currentPercentage = $InitialDeploymentPercentage + ($scaleUpMultiplier * $ScaleUpIncrementPercentage)
            }
            
            $currentPercentage = [Math]::Min($currentPercentage, 100)
            $percentageBasedCount = [Math]::Ceiling($sessionHostsPendingDelete.Count * ($currentPercentage / 100.0))
            $batchSizeLimit = $MaxDeploymentBatchSize
            $actualDeleteCount = [Math]::Min($percentageBasedCount, $batchSizeLimit)
            $actualDeleteCount = [Math]::Min($actualDeleteCount, $sessionHostsPendingDelete.Count)
            
            Write-LogEntry -Message "Progressive scale-up for deletions: Using $currentPercentage% of $($sessionHostsPendingDelete.Count) pending = $actualDeleteCount hosts (ConsecutiveSuccesses: $($deploymentState.ConsecutiveSuccesses), Max: $batchSizeLimit)"
            $sessionHostsPendingDelete = $sessionHostsPendingDelete | Select-Object -First $actualDeleteCount
        }
        
        Write-LogEntry -Message "The following Session Hosts are now pending delete: $($($SessionHostsPendingDelete.SessionHostName) -join ',')"
    }
    elseif ($sessionHostsToReplace.Count -gt 0) {
        Write-LogEntry -Message "We need to delete $($sessionHostsToReplace.Count) session hosts but we don't have enough session hosts in the host pool."
    }
    else {
        Write-LogEntry -Message "We do not need to delete any session hosts"
    }
    
    # Auto-detect mode: Clear stored target when replacement cycle is complete
    $configuredTarget = Read-FunctionAppSetting TargetSessionHostCount
    if ($configuredTarget -eq 0 -and $sessionHostsToReplace.Count -eq 0 -and $sessionHostsPendingDelete.Count -eq 0) {
        # All hosts are up to date and nothing pending - clear stored target for next cycle
        try {
            $deploymentState = Get-DeploymentState -HostPoolName $HostPoolName
            if ($deploymentState.TargetSessionHostCount -gt 0) {
                Write-LogEntry -Message "Auto-detect mode: All session hosts are up to date - clearing stored target count for next replacement cycle"
                $deploymentState.TargetSessionHostCount = 0
                Save-DeploymentState -DeploymentState $deploymentState -HostPoolName $HostPoolName
            }
        }
        catch {
            Write-LogEntry -Message "Auto-detect mode: Unable to clear stored target count - will retry on next run. Error: $_" -Level Warning
        }
    }

    return [PSCustomObject]@{
        PossibleDeploymentsCount       = $canDeploy
        PossibleSessionHostDeleteCount = $canDelete
        SessionHostsPendingDelete      = $sessionHostsPendingDelete
        ExistingSessionHostNames       = ([array]$SessionHosts.SessionHostName + [array]$runningDeploymentVMNames) | Select-Object -Unique
        TargetSessionHostCount         = $TargetSessionHostCount
        TotalSessionHostsToReplace     = $sessionHostsToReplace.Count
    }
}

function Get-SessionHosts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        [Parameter()]
        [array] $CachedVMs,
        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),
        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),
        [Parameter()]
        [string] $ResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [Parameter()]
        [string] $TagIncludeInAutomation = (Read-FunctionAppSetting Tag_IncludeInAutomation),
        [Parameter()]
        [string] $TagDeployTimestamp = (Read-FunctionAppSetting Tag_DeployTimestamp),
        [Parameter()]
        [string] $TagPendingDrainTimeStamp = (Read-FunctionAppSetting Tag_PendingDrainTimestamp),
        [Parameter()]
        [string] $TagShutdownTimestamp = (Read-FunctionAppSetting Tag_ShutdownTimestamp),
        [Parameter()]
        [switch] $FixSessionHostTags = (Read-FunctionAppSetting FixSessionHostTags),
        [Parameter()]
        [bool] $IncludePreExistingSessionHosts = (Read-FunctionAppSetting IncludePreExistingSessionHosts)
    )
    
    Write-LogEntry -Message "Getting current session hosts in host pool $HostPoolName"
    $Uri = "$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts?api-version=2024-04-03"
    $sessionHostsResponse = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
    
    # Extract properties from nested structure
    $sessionHosts = $sessionHostsResponse | ForEach-Object {
        [PSCustomObject]@{
            Name            = $_.name
            ResourceId      = $_.properties.resourceId
            Sessions        = $_.properties.sessions
            AllowNewSession = $_.properties.allowNewSession
            Status          = $_.properties.status
        }
    }
    
    $result = foreach ($sh in $sessionHosts) {
        # Look up VM from cache by resource ID
        $vmResponse = $null
        if ($CachedVMs -and $CachedVMs.Count -gt 0) {
            $vmResponse = $CachedVMs | Where-Object { $_.id -eq $sh.ResourceId } | Select-Object -First 1
            if ($vmResponse) {
                Write-LogEntry -Message "Using cached VM data for $($sh.Name)" -Level Trace
            }
        }
        
        # Fall back to individual query if not in cache (without instanceView - we'll get power state lazily if needed)
        if (-not $vmResponse) {
            Write-LogEntry -Message "VM not found in cache, querying individually: $($sh.ResourceId)" -Level Trace
            $Uri = "$ResourceManagerUri$($sh.ResourceId)?api-version=2024-07-01"
            $vmResponse = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
        }
        
        # Extract properties from nested structure
        $vm = [PSCustomObject]@{
            Name           = $vmResponse.name
            TimeCreated    = $vmResponse.properties.timeCreated
            StorageProfile = $vmResponse.properties.storageProfile
            HostId         = $vmResponse.properties.host.id
            HostGroupId    = $vmResponse.properties.hostGroup.id
            Zones          = $vmResponse.zones
        }
        
        # Extract image version and definition - handle both ExactVersion (specific version) and id (image definition reference)
        $vmImageVersion = $null
        $vmImageDefinition = $null
        
        if ($vm.StorageProfile.ImageReference.id) {
            # Gallery image reference (either specific version or definition for "latest")
            $imageRef = $vm.StorageProfile.ImageReference.id
            
            # Extract the image definition path (without version)
            if ($imageRef -match '^(?<definition>.+)/versions/[^/]+$') {
                $vmImageDefinition = $Matches['definition']
            }
            elseif ($imageRef -match '^(?<definition>/subscriptions/.+/images/[^/]+)$') {
                $vmImageDefinition = $Matches['definition']
            }
            
            # Get version - prefer ExactVersion if available, otherwise extract from id
            if ($vm.StorageProfile.ImageReference.ExactVersion) {
                $vmImageVersion = $vm.StorageProfile.ImageReference.ExactVersion
            }
            elseif ($imageRef -match '/versions/(?<version>[^/]+)$') {
                $vmImageVersion = $Matches['version']
            }
        }
        elseif ($vm.StorageProfile.ImageReference.publisher) {
            # Marketplace image
            $vmImageVersion = $vm.StorageProfile.ImageReference.version
            $vmImageDefinition = "marketplace:$($vm.StorageProfile.ImageReference.publisher)/$($vm.StorageProfile.ImageReference.offer)/$($vm.StorageProfile.ImageReference.sku)"
        }
        else {
            Write-LogEntry -Message "Unable to determine VM image version from StorageProfile" -Level Warning
        }
        
        # Power state will be queried lazily only for deletion candidates to optimize performance
        # This avoids querying instanceView for all VMs when most are not being considered for deletion
        
        # Extract tags directly from VM response (no separate API call needed)
        $vmTags = @{}
        if ($vmResponse.tags) {
            $vmResponse.tags.PSObject.Properties | ForEach-Object {
                $vmTags[$_.Name] = $_.Value
            }
        }
        
        $vmDeployTimeStamp = $vmTags[$TagDeployTimestamp]
        
        try {
            $vmDeployTimeStamp = [DateTime]::Parse($vmDeployTimeStamp)
        }
        catch {
            $value = if ($null -eq $vmDeployTimeStamp) { 'null' } else { $vmDeployTimeStamp }
            Write-LogEntry -Message "VM tag $TagDeployTimestamp with value $value is not a valid date" -Level Trace
            if ($FixSessionHostTags) {
                $tagsUri = "$ResourceManagerUri$($sh.ResourceId)/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
                $Body = @{
                    properties = @{
                        tags = @{ $TagDeployTimestamp = $vm.TimeCreated.ToString('o') }
                    }
                    operation  = 'Merge'
                }
                Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 10) -Method PATCH -Uri $tagsUri | Out-Null
            }
            $vmDeployTimeStamp = $vm.TimeCreated
        }
        
        $vmIncludeInAutomation = $vmTags[$TagIncludeInAutomation]
        if ($vmIncludeInAutomation -eq "True") {
            $vmIncludeInAutomation = $true
        }
        elseif ($vmIncludeInAutomation -eq "False") {
            $vmIncludeInAutomation = $false
        }
        else {
            $value = if ($null -eq $vmIncludeInAutomation) { 'null' } else { $vmIncludeInAutomation }
            Write-LogEntry -Message "VM tag with $TagIncludeInAutomation value $value is not set to True/False" -Level Trace
            if ($FixSessionHostTags) {
                $tagsUri = "$ResourceManagerUri$($sh.ResourceId)/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
                $Body = @{
                    properties = @{
                        tags = @{ $TagIncludeInAutomation = $IncludePreExistingSessionHosts }
                    }
                    operation  = 'Merge'
                }
                $null = Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 10) -Method PATCH -Uri $tagsUri
            }
            $vmIncludeInAutomation = $IncludePreExistingSessionHosts
        }
        
        # Get drain timestamp tag
        $vmPendingDrainTimeStamp = $vmTags[$TagPendingDrainTimeStamp]
        if ($null -ne $vmPendingDrainTimeStamp) {
            try {
                # Parse as UTC time regardless of timezone indicator
                $vmPendingDrainTimeStamp = [DateTime]::Parse($vmPendingDrainTimeStamp, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            }
            catch {
                Write-LogEntry -Message "VM tag $TagPendingDrainTimeStamp could not be parsed: '$vmPendingDrainTimeStamp'" -Level Warning
                $vmPendingDrainTimeStamp = $null
            }
        }
        
        # Get shutdown timestamp tag (for shutdown retention feature)
        $vmShutdownTimestamp = $vmTags[$TagShutdownTimestamp]
        if ($null -ne $vmShutdownTimestamp) {
            try {
                # Parse as UTC time regardless of timezone indicator
                $vmShutdownTimestamp = [DateTime]::Parse($vmShutdownTimestamp, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            }
            catch {
                Write-LogEntry -Message "VM tag $TagShutdownTimestamp could not be parsed: '$vmShutdownTimestamp'" -Level Warning
                $vmShutdownTimestamp = $null
            }
        }

        $fqdn = $sh.Name -replace ".+\/(.+)", '$1'
        $sessionHostName = $fqdn -replace '\..*$', ''
        
        $hostOutput = @{
            VMName                = $vm.Name
            SessionHostName       = $sessionHostName
            FQDN                  = $fqdn
            DeployTimestamp       = $vmDeployTimeStamp
            IncludeInAutomation   = $vmIncludeInAutomation
            PendingDrainTimeStamp = $vmPendingDrainTimeStamp
            ShutdownTimestamp     = $vmShutdownTimestamp
            ImageVersion          = $vmImageVersion
            ImageDefinition       = $vmImageDefinition
            Tags                  = $vmTags
            HostId                = $vm.HostId
            HostGroupId           = $vm.HostGroupId
            Zones                 = $vm.Zones
        }
        $sh.PSObject.Properties.ForEach{ $hostOutput[$_.Name] = $_.Value }
        [PSCustomObject]$hostOutput
    }
    return $result
}

#EndRegion Session Host Planning

# Export functions
Export-ModuleMember -Function Get-SessionHostReplacementPlan, Get-SessionHosts
