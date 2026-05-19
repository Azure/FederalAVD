# SessionHostReplacer Lifecycle Module
# Contains session host removal, shutdown retention, and drain notification functions

#Region Session Host Lifecycle

function Remove-ExpiredShutdownVMs {
    <#
    .SYNOPSIS
    Removes VMs that have been shutdown for longer than the retention period.
    
    .DESCRIPTION
    Checks for VMs tagged with shutdown timestamp and deletes them if they have exceeded
    the configured retention period. Also removes associated Entra ID and Intune devices.
    
    .PARAMETER ARMToken
    ARM access token for Azure Resource Manager API calls
    
    .PARAMETER GraphToken
    Graph access token for Entra ID and Intune API calls
    
    .PARAMETER ShutdownRetentionDays
    Number of days to retain shutdown VMs before deletion
    
    .OUTPUTS
    PSCustomObject with counts of cleaned up and retained VMs
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        [Parameter()]
        [string] $GraphToken,
        [Parameter()]
        [array] $CachedVMs,
        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),
        [Parameter()]
        [int] $ShutdownRetentionDays = (Read-FunctionAppSetting ShutdownRetentionDays),
        [Parameter()]
        [string] $TagShutdownTimestamp = (Read-FunctionAppSetting Tag_ShutdownTimestamp),
        [Parameter()]
        [string] $VirtualMachinesSubscriptionId = (Read-FunctionAppSetting VirtualMachinesSubscriptionId),
        [Parameter()]
        [string] $VirtualMachinesResourceGroupName = (Read-FunctionAppSetting VirtualMachinesResourceGroupName),
        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),
        [Parameter()]
        [string] $HostPoolResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [Parameter()]
        [bool] $RemoveEntraDevice = (Read-FunctionAppSetting RemoveEntraDevice -AsBoolean),
        [Parameter()]
        [bool] $RemoveIntuneDevice = (Read-FunctionAppSetting RemoveIntuneDevice -AsBoolean),
        [Parameter()]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )
    
    Write-LogEntry -Message "Checking for shutdown VMs exceeding retention period of $ShutdownRetentionDays days"
    
    # Use cached VMs if provided, otherwise fetch
    if ($CachedVMs -and $CachedVMs.Count -gt 0) {
        Write-LogEntry -Message "Using cached VM data for shutdown retention check" -Level Trace
        $allVMs = $CachedVMs
    }
    else {
        $Uri = "$ResourceManagerUri/subscriptions/$VirtualMachinesSubscriptionId/resourceGroups/$VirtualMachinesResourceGroupName/resources?`$filter=resourceType eq 'Microsoft.Compute/virtualMachines'&api-version=2021-04-01"
        $allVMs = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
    }
    
    # Filter to VMs with the shutdown timestamp tag
    $shutdownVMs = $allVMs | Where-Object { $_.tags -and $_.tags.PSObject.Properties.Name -contains $TagShutdownTimestamp }
    
    if (-not $shutdownVMs -or $shutdownVMs.Count -eq 0) {
        Write-LogEntry -Message "No shutdown VMs found with retention tag" -Level Trace
        return [PSCustomObject]@{
            CleanedUpCount = 0
            RetainedCount  = 0
        }
    }
    
    Write-LogEntry -Message "Found $($shutdownVMs.Count) shutdown VM(s) to evaluate"
    
    $cleanedUpCount = 0
    $retainedCount = 0
    $deletedVMNames = @()
    $currentTime = (Get-Date).ToUniversalTime()
    
    foreach ($vm in $shutdownVMs) {
        $vmName = $vm.name
        $vmId = $vm.id
        
        # Get the shutdown timestamp from tags
        $shutdownTimestampString = $vm.tags.$TagShutdownTimestamp
        
        if ([string]::IsNullOrEmpty($shutdownTimestampString)) {
            Write-LogEntry -Message "VM $vmName has shutdown tag but no timestamp value - skipping" -Level Warning
            continue
        }
        
        try {
            $shutdownTime = [DateTime]::Parse($shutdownTimestampString, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            $age = ($currentTime - $shutdownTime).TotalDays
            
            Write-LogEntry -Message "VM $vmName has been shutdown for $([Math]::Round($age, 2)) days (retention: $ShutdownRetentionDays days)" -Level Trace
            
            if ($age -ge $ShutdownRetentionDays) {
                Write-LogEntry -Message "VM $vmName has exceeded retention period - deleting..."
                
                try {
                    # Use helper function to delete VM and clean up resources
                    Remove-VirtualMachine `
                        -VMName $vmName `
                        -VMId $vmId `
                        -ARMToken $ARMToken `
                        -GraphToken $GraphToken `
                        -RemoveEntraDevice $RemoveEntraDevice `
                        -RemoveIntuneDevice $RemoveIntuneDevice `
                        -HostPoolSubscriptionId $HostPoolSubscriptionId `
                        -HostPoolResourceGroupName $HostPoolResourceGroupName `
                        -HostPoolName $HostPoolName `
                        -ClientId $ClientId
                    
                    $cleanedUpCount++
                    $deletedVMNames += $vmName
                }
                catch {
                    Write-LogEntry -Message "Failed to delete shutdown VM $vmName : $($_.Exception.Message)" -Level Error
                }
            }
            else {
                $remainingDays = [Math]::Round($ShutdownRetentionDays - $age, 1)
                Write-LogEntry -Message "VM $vmName will be retained for $remainingDays more day(s)" -Level Trace
                $retainedCount++
            }
        }
        catch {
            Write-LogEntry -Message "Failed to parse shutdown timestamp for VM $vmName : $($_.Exception.Message)" -Level Warning
        }
    }
    
    if ($cleanedUpCount -gt 0) {
        Write-LogEntry -Message "Cleanup complete: Deleted $cleanedUpCount expired shutdown VM(s), retained $retainedCount VM(s)"
    }
    else {
        Write-LogEntry -Message "No shutdown VMs exceeded retention period"
    }
    
    return [PSCustomObject]@{
        CleanedUpCount  = $cleanedUpCount
        RetainedCount   = $retainedCount
        DeletedVMNames  = $deletedVMNames
    }
}

function Remove-SessionHosts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        [Parameter()]
        [string] $GraphToken,
        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),
        [Parameter(Mandatory = $true)]
        $SessionHostsPendingDelete,
        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),
        [Parameter()]
        [string] $ResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [Parameter()]
        [int] $DrainGracePeriodHours = (Read-FunctionAppSetting DrainGracePeriodHours),
        [Parameter()]
        [int] $MinimumDrainMinutes = (Read-FunctionAppSetting MinimumDrainMinutes),
        [Parameter()]
        [string] $ReplacementMode = (Read-FunctionAppSetting ReplacementMode),
        [Parameter()]
        [string] $TagPendingDrainTimeStamp = (Read-FunctionAppSetting Tag_PendingDrainTimestamp),
        [Parameter()]
        [string] $TagShutdownTimestamp = (Read-FunctionAppSetting Tag_ShutdownTimestamp),
        [Parameter()]
        [string] $TagScalingPlanExclusionTag = (Read-FunctionAppSetting Tag_ScalingPlanExclusionTag),
        [Parameter()]
        [bool] $RemoveEntraDevice,
        [Parameter()]
        [bool] $RemoveIntuneDevice,
        [Parameter()]
        [bool] $EnableShutdownRetention = (Read-FunctionAppSetting EnableShutdownRetention -AsBoolean),
        [Parameter()]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )

    # Initialize results tracking
    $successfulDeletions = @()
    $successfulShutdowns = @()
    $failedDeletions = @()

    foreach ($sessionHost in $SessionHostsPendingDelete) {
        $drainSessionHost = $false
        $deleteSessionHost = $false

        Write-LogEntry -Message "Evaluating session host $($sessionHost.SessionHostName): Sessions=$($sessionHost.Sessions), AllowNewSession=$($sessionHost.AllowNewSession), PendingDrainTimeStamp=$($sessionHost.PendingDrainTimeStamp)" -Level Trace

        if ($sessionHost.Sessions -eq 0) {
            Write-LogEntry -Message "Session host $($sessionHost.FQDN) has no sessions."
            
            # Optimization: If VM is already powered off, skip draining and delete immediately (no point draining an offline VM)
            if ($sessionHost.PoweredOff) {
                Write-LogEntry -Message "Session host $($sessionHost.FQDN) is powered off - marking for immediate deletion without drain period (VM already shutdown)"
                $deleteSessionHost = $true
            }
            # Optimization: If MinimumDrainMinutes = 0, skip draining entirely and delete immediately
            elseif ($MinimumDrainMinutes -eq 0) {
                Write-LogEntry -Message "Session host $($sessionHost.FQDN) is idle and MinimumDrainMinutes is 0 - marking for immediate removal without drain period"
                $deleteSessionHost = $true
            }
            elseif (-Not $sessionHost.AllowNewSession) {
                Write-LogEntry -Message "Session host $($sessionHost.FQDN) is in drain mode with zero sessions."
                if ($sessionHost.PendingDrainTimeStamp) {                    
                    # In SideBySide mode, skip minimum drain time check since new capacity is already deployed
                    if ($ReplacementMode -eq 'SideBySide') {
                        $deleteSessionHost = $true
                    }
                    # If VM is powered off, skip minimum drain time check - no race condition possible
                    elseif ($sessionHost.PoweredOff) {
                        Write-LogEntry -Message "Session host $($sessionHost.FQDN) is powered off - skipping minimum drain time check (no race condition possible)"
                        $deleteSessionHost = $true
                    }
                    else {
                        $elapsedMinutes = ((Get-Date).ToUniversalTime() - $sessionHost.PendingDrainTimeStamp).TotalMinutes
                  
                        Write-LogEntry -Message "Session host $($sessionHost.FQDN) has been draining for $([Math]::Round($elapsedMinutes, 1)) minutes (minimum required: $MinimumDrainMinutes)"
                        if ($elapsedMinutes -ge $MinimumDrainMinutes) {
                            Write-LogEntry -Message "Session host $($sessionHost.FQDN) has met the minimum drain time for idle hosts."
                            $deleteSessionHost = $true
                        }
                        else {
                            Write-LogEntry -Message "Session host $($sessionHost.FQDN) has not yet met the minimum drain time."
                        }
                    }
                }
                else {
                    Write-LogEntry -Message "Session host $($sessionHost.FQDN) does not have a drain timestamp."
                    $drainSessionHost = $true
                }
            }
            else {
                Write-LogEntry -Message "Session host $($sessionHost.FQDN) is not in drain mode. Turning on drain mode."
                $drainSessionHost = $true
            }
        }
        else {
            Write-LogEntry -Message "Session host $($sessionHost.FQDN) has $($sessionHost.Sessions) sessions." 
            if (-Not $sessionHost.AllowNewSession) {
                Write-LogEntry -Message "Session host $($sessionHost.FQDN) is in drain mode."
                if ($sessionHost.PendingDrainTimeStamp) {
                    Write-LogEntry -Message "Session Host $($sessionHost.FQDN) drain timestamp is $($sessionHost.PendingDrainTimeStamp)"
                    $maxDrainGracePeriodDate = $sessionHost.PendingDrainTimeStamp.AddHours($DrainGracePeriodHours)
                    Write-LogEntry -Message "Session Host $($sessionHost.FQDN) can stay in grace period until $($maxDrainGracePeriodDate.ToUniversalTime().ToString('o'))" -Level Trace 
                    if ($maxDrainGracePeriodDate -lt (Get-Date).ToUniversalTime()) {
                        Write-LogEntry -Message "Session Host $($sessionHost.FQDN) has exceeded the drain grace period."
                        $deleteSessionHost = $true
                    }
                    else {
                        Write-LogEntry -Message "Session Host $($sessionHost.FQDN) has not exceeded the drain grace period." -Level Trace
                    }
                }
                else {
                    Write-LogEntry -Message "Session Host $($sessionHost.FQDN) does not have a drain timestamp." -Level Trace
                    $drainSessionHost = $true
                }
            }
            else {
                Write-LogEntry -Message "Session host $($sessionHost.Name) in not in drain mode. Turning on drain mode."
                $drainSessionHost = $true
            }
        }

        if ($drainSessionHost) {
            try {
                Write-LogEntry -Message "Enabling drain mode for session host $($sessionHost.SessionHostName)"
                $Uri = "$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts/$($sessionHost.FQDN)?api-version=2024-04-03"
                Invoke-AzureRestMethod -ARMToken $ARMToken -Body (@{properties = @{allowNewSession = $false } } | ConvertTo-Json) -Method 'PATCH' -Uri $Uri | Out-Null
                
                Write-LogEntry -Message "Drain mode enabled for $($sessionHost.SessionHostName)" -Level Trace
                
                $drainTimestamp = (Get-Date).ToUniversalTime().ToString('o')
                Write-LogEntry -Message "Setting drain timestamp tag on $($sessionHost.SessionHostName): $drainTimestamp"
                $Uri = "$ResourceManagerUri$($sessionHost.ResourceId)/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
                $Body = @{
                    properties = @{
                        tags = @{ $TagPendingDrainTimeStamp = $drainTimestamp }
                    }
                    operation  = 'Merge'
                }
                Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $Uri | Out-Null
                
                Write-LogEntry -Message "Successfully tagged $($sessionHost.SessionHostName) with drain timestamp"
                
                # Update in-memory session host object so timestamp is available for deletion check in same run
                $sessionHost.PendingDrainTimeStamp = [DateTime]::Parse($drainTimestamp, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                
                # Re-evaluate deletion eligibility now that we have a timestamp
                # Priority order: PoweredOff > SideBySide > MinDrain=0 > MinDrainTime
                if ($sessionHost.Sessions -eq 0) {
                    $elapsedMinutes = ((Get-Date).ToUniversalTime() - $sessionHost.PendingDrainTimeStamp).TotalMinutes
                    
                    # HIGHEST PRIORITY: If VM is already powered off, delete immediately (no point waiting - it's already offline)
                    if ($sessionHost.PoweredOff) {
                        Write-LogEntry -Message "Session host $($sessionHost.SessionHostName) is powered off - marking for immediate deletion (VM already shutdown)"
                        $deleteSessionHost = $true
                    }
                    # In SideBySide mode, allow immediate deletion since new capacity is already deployed
                    elseif ($ReplacementMode -eq 'SideBySide') {
                        Write-LogEntry -Message "Session host $($sessionHost.SessionHostName) is in SideBySide mode - marking for immediate deletion (new capacity already deployed)"
                        $deleteSessionHost = $true
                    }
                    elseif ($MinimumDrainMinutes -eq 0) {
                        Write-LogEntry -Message "Session host $($sessionHost.SessionHostName) has MinimumDrainMinutes=0 - marking for immediate deletion"
                        $deleteSessionHost = $true
                    }
                    elseif ($elapsedMinutes -ge $MinimumDrainMinutes) {
                        Write-LogEntry -Message "Session host $($sessionHost.SessionHostName) meets deletion criteria ($([Math]::Round($elapsedMinutes, 1)) minutes elapsed >= $MinimumDrainMinutes required) - marking for deletion"
                        $deleteSessionHost = $true
                    }
                    else {
                        Write-LogEntry -Message "Session host $($sessionHost.SessionHostName) must wait $([Math]::Round($MinimumDrainMinutes - $elapsedMinutes, 1)) more minutes before deletion (minimum drain time: $MinimumDrainMinutes minutes)"
                    }
                }
                
                if ($TagScalingPlanExclusionTag -ne ' ') {
                    Write-LogEntry -Message "Setting scaling plan exclusion tag on $($sessionHost.SessionHostName)" -Level Trace
                    $Body = @{
                        properties = @{
                            tags = @{ $TagScalingPlanExclusionTag = 'SessionHostReplacer' }
                        }
                        operation  = 'Merge'
                    }
                    Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $Uri | Out-Null
                    
                    Write-LogEntry -Message "Successfully set scaling plan exclusion tag with value: SessionHostReplacer" -Level Trace
                }

                Write-LogEntry -Message 'Notifying Users' -Level Trace
                Send-DrainNotification -ARMToken $ARMToken -SessionHostName ($sessionHost.FQDN)
            }
            catch {
                Write-LogEntry -Message "Error enabling drain mode for $($sessionHost.SessionHostName): $($_.Exception.Message)" -Level Error
            }
        }

        if ($deleteSessionHost) {
            try {
                # If shutdown retention is enabled, shutdown instead of delete
                if ($EnableShutdownRetention) {
                    Write-LogEntry -Message "Shutdown retention enabled - deallocating session host $($sessionHost.SessionHostName) for rollback capability..."
                    
                    # Check current power state before attempting deallocate
                    Write-LogEntry -Message "Checking power state of VM: $($sessionHost.VMName)..." -Level Trace
                    $Uri = "$ResourceManagerUri$($sessionHost.ResourceId)/instanceView?api-version=2024-07-01"
                    $instanceView = Invoke-AzureRestMethod -ARMToken $ARMToken -Method 'GET' -Uri $Uri
                    
                    # Get power state from instance view (e.g., "PowerState/running", "PowerState/deallocated")
                    $powerState = ($instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' }).code
                    Write-LogEntry -Message "Current power state: $powerState" -Level Trace
                    
                    # Only deallocate if VM is not already stopped/deallocated
                    if ($powerState -notlike 'PowerState/deallocated' -and $powerState -notlike 'PowerState/stopped') {
                        Write-LogEntry -Message "Deallocating VM: $($sessionHost.ResourceId)..." -Level Trace
                        $Uri = "$ResourceManagerUri$($sessionHost.ResourceId)/deallocate?api-version=2024-07-01"
                        [void](Invoke-AzureRestMethod -ARMToken $ARMToken -Method 'POST' -Uri $Uri)
                    }
                    else {
                        Write-LogEntry -Message "VM is already deallocated/stopped - skipping deallocate operation" -Level Trace
                    }
                    
                    # Tag with shutdown timestamp for later cleanup and ensure scaling exclusion tag is present
                    $shutdownTimestamp = (Get-Date).ToUniversalTime().ToString('o')
                    Write-LogEntry -Message "Setting shutdown timestamp tag on $($sessionHost.SessionHostName): $shutdownTimestamp" -Level Trace
                    $Uri = "$ResourceManagerUri$($sessionHost.ResourceId)/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
                    
                    # Build tags to apply: shutdown timestamp + scaling exclusion tag (if configured)
                    $tagsToApply = @{ $TagShutdownTimestamp = $shutdownTimestamp }
                    if ($TagScalingPlanExclusionTag -and $TagScalingPlanExclusionTag -ne ' ') {
                        $tagsToApply[$TagScalingPlanExclusionTag] = 'SessionHostReplacer'
                        Write-LogEntry -Message "Ensuring scaling exclusion tag is set on shutdown retention VM: $($sessionHost.SessionHostName)" -Level Trace
                    }
                    
                    $Body = @{
                        properties = @{
                            tags = $tagsToApply
                        }
                        operation  = 'Merge'
                    }
                    Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $Uri | Out-Null
                    
                    # Track successful shutdown
                    $successfulShutdowns += $sessionHost.SessionHostName
                    Write-LogEntry -Message "Successfully shutdown session host $($sessionHost.SessionHostName) - will remain in host pool for $((Read-FunctionAppSetting ShutdownRetentionDays)) days for rollback"
                }
                else {
                    # Standard delete flow - use helper function
                    Write-LogEntry -Message "Deleting session host $($SessionHost.SessionHostName)..."
                    
                    Remove-VirtualMachine `
                        -VMName $sessionHost.SessionHostName `
                        -VMId $sessionHost.ResourceId `
                        -FQDN $sessionHost.FQDN `
                        -ARMToken $ARMToken `
                        -GraphToken $GraphToken `
                        -RemoveEntraDevice $RemoveEntraDevice `
                        -RemoveIntuneDevice $RemoveIntuneDevice `
                        -HostPoolSubscriptionId $HostPoolSubscriptionId `
                        -HostPoolResourceGroupName $ResourceGroupName `
                        -HostPoolName $HostPoolName `
                        -ClientId $ClientId
                    
                    # Track successful deletion
                    $successfulDeletions += $sessionHost.SessionHostName
                }
            }
            catch {
                # Track failed deletion
                $failedDeletions += [PSCustomObject]@{
                    SessionHostName = $sessionHost.SessionHostName
                    Reason          = $_.Exception.Message
                }
                Write-Error "Failed to delete session host $($sessionHost.SessionHostName): $($_.Exception.Message)"
            }
        }
    }

    # Return results object
    return [PSCustomObject]@{
        SuccessfulDeletions = $successfulDeletions
        SuccessfulShutdowns = $successfulShutdowns
        FailedDeletions     = $failedDeletions
    }
}

function Remove-VirtualMachine {
    <#
    .SYNOPSIS
    Removes a virtual machine and cleans up associated resources.
    
    .DESCRIPTION
    Helper function to remove a VM from the host pool, clean up device records,
    and delete the VM. Used by both Remove-SessionHosts and Remove-ExpiredShutdownVMs.
    
    .PARAMETER VMName
    The name of the VM to remove
    
    .PARAMETER VMId
    The full resource ID of the VM
    
    .PARAMETER FQDN
    The FQDN of the session host (optional - will be looked up if not provided)
    
    .PARAMETER ARMToken
    ARM access token
    
    .PARAMETER GraphToken
    Graph access token for device cleanup
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $VMName,
        [Parameter(Mandatory = $true)]
        [string] $VMId,
        [Parameter()]
        [string] $FQDN,
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        [Parameter()]
        [string] $GraphToken,
        [Parameter()]
        [bool] $RemoveEntraDevice = $false,
        [Parameter()]
        [bool] $RemoveIntuneDevice = $false,
        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),
        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),
        [Parameter()]
        [string] $HostPoolResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [Parameter()]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )
    
    Write-LogEntry -Message "Deleting virtual machine $VMName" -Level Trace
    
    # If FQDN not provided, query host pool to find it
    if ([string]::IsNullOrEmpty($FQDN)) {
        Write-LogEntry -Message "FQDN not provided - querying host pool to find session host" -Level Trace
        $Uri = "$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$HostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts?api-version=2024-04-03"
        $sessionHostsInPool = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
        
        $matchingHost = $sessionHostsInPool | Where-Object { $_.name -like "*/$VMName" -or $_.properties.resourceId -eq $VMId }
        
        if ($matchingHost) {
            $FQDN = $matchingHost.name.Split('/')[-1]
            Write-LogEntry -Message "Found session host in pool: $FQDN" -Level Trace
        }
        else {
            Write-LogEntry -Message "Session host $VMName not found in host pool (may have been manually removed)" -Level Trace
        }
    }
    
    # Remove from host pool if FQDN is known
    if (-not [string]::IsNullOrEmpty($FQDN)) {
        Write-LogEntry -Message "Removing session host $FQDN from host pool $HostPoolName" -Level Trace
        $Uri = "$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$HostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts/$FQDN`?api-version=2024-04-03"
        [void](Invoke-AzureRestMethod -ARMToken $ARMToken -Method DELETE -Uri $Uri)
        Write-LogEntry -Message "Removed $VMName from host pool" -Level Trace
    }
    
    # Extract hostname from FQDN for device cleanup (Entra ID/Intune use hostname, not VM resource name)
    $deviceName = if (-not [string]::IsNullOrEmpty($FQDN)) {
        $FQDN.Split('.')[0]  # Get hostname from FQDN (e.g., "avdtest29use207" from "avdtest29use207.domain.com")
    } else {
        $VMName  # Fallback to VM name if FQDN not available
    }
    
    Write-LogEntry -Message "Using device name '$deviceName' for Entra ID/Intune cleanup" -Level Trace
    
    # Remove from identity directories
    Remove-DeviceFromDirectories -DeviceName $deviceName -GraphToken $GraphToken -RemoveEntraDevice $RemoveEntraDevice -RemoveIntuneDevice $RemoveIntuneDevice -ClientId $ClientId
    
    # Delete the VM
    Write-LogEntry -Message "Deleting VM: $VMId" -Level Trace
    $Uri = "$ResourceManagerUri$VMId`?forceDeletion=true&api-version=2024-07-01"
    [void](Invoke-AzureRestMethod -ARMToken $ARMToken -Method 'DELETE' -Uri $Uri)
    
    Write-LogEntry -Message "Successfully deleted VM $VMName"
}

function Send-DrainNotification {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ARMToken,

        [Parameter(Mandatory = $true)]
        [string] $SessionHostName,

        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),

        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),

        [Parameter()]
        [string] $ResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),

        [Parameter()]
        [int] $DrainGracePeriodHours = (Read-FunctionAppSetting DrainGracePeriodHours),

        [Parameter()]
        [string] $MessageTitle = "Automatic Session Host Maintenance",

        [Parameter()]
        [string] $MessageBody = "Your session host {0} is being replaced. Please save your work and log off. You will be disconnected in {1} hours."
    )
    
    try {       
        Write-LogEntry -Message "Getting user sessions for session host $SessionHostName"
        $SessionsUri = "$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts/$SessionHostName/userSessions?api-version=2024-04-03"
        
        $sessionsResponse = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $SessionsUri
        
        # Ensure we have an array
        $sessions = @($sessionsResponse)
        
        # Filter out any empty or invalid session objects
        $sessions = $sessions | Where-Object { $_ -and $_.name }
        
        if ($sessions.Count -eq 0) {
            Write-LogEntry -Message "No active sessions found on session host $SessionHostName"
            return
        }
        
        Write-LogEntry -Message "Found $($sessions.Count) active session(s) on session host $SessionHostName"
        
        foreach ($session in $sessions) {
            $sessionId = $session.name -replace '.+\/.+\/(.+)', '$1'
            $userPrincipalName = $session.properties.userPrincipalName
            
            if ([string]::IsNullOrWhiteSpace($sessionId)) {
                Write-LogEntry -Message "Skipping session with invalid ID: $($session.name)" -Level Warning
                continue
            }
            
            $formattedMessageBody = $MessageBody -f $SessionHostName, $DrainGracePeriodHours
            
            Write-LogEntry -Message "Sending drain notification to user $userPrincipalName on session $sessionId"
            
            $MessageUri = "$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts/$SessionHostName/userSessions/$sessionId/sendMessage?api-version=2024-04-03"
            
            $MessagePayload = @{
                messageTitle = $MessageTitle
                messageBody  = $formattedMessageBody
            } | ConvertTo-Json -Depth 10
            
            try {
                Invoke-AzureRestMethod -ARMToken $ARMToken -Method Post -Uri $MessageUri -Body $MessagePayload | Out-Null
                Write-LogEntry -Message "Successfully sent message to user $userPrincipalName"
            }
            catch {
                Write-LogEntry -Message "Failed to send message to user $userPrincipalName : $_" -Level Warning
            }
        }
    }
    catch {
        Write-LogEntry -Message "Error in Send-DrainNotification: $_" -Level Error
    }
}

function Test-NewSessionHostsAvailable {
    <#
    .SYNOPSIS
    Verifies that newly deployed session hosts are in 'Available' status before proceeding with old host removal.
    
    .DESCRIPTION
    Safety check to ensure new session hosts have successfully registered to the host pool and passed health checks
    before shutting down or deleting old hosts. This prevents capacity loss if new hosts fail to become accessible.
    
    .PARAMETER ARMToken
    ARM access token for Azure Resource Manager API calls
    
    .PARAMETER SessionHosts
    Collection of all current session hosts from the host pool
    
    .PARAMETER LatestImageVersion
    The latest image version info (Version and Definition) to identify new hosts
    
    .PARAMETER MinimumAvailableCount
    Minimum number of new hosts that must be Available before proceeding (default: 1)
    
    .PARAMETER MinimumAvailablePercentage
    Minimum percentage of new hosts that must be Available before proceeding (default: 100)
    
    .OUTPUTS
    PSCustomObject with:
    - AllAvailable: Boolean indicating if all new hosts are available
    - AvailableCount: Number of new hosts in Available status
    - TotalNewHosts: Total number of new hosts found
    - UnavailableHosts: Array of hosts not in Available status with their status
    - SafeToProceed: Boolean indicating if it's safe to remove old hosts
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        [Parameter(Mandatory = $true)]
        $SessionHosts,
        [Parameter(Mandatory = $true)]
        $LatestImageVersion,
        [Parameter()]
        [int] $MinimumAvailableCount = 1,
        [Parameter()]
        [int] $MinimumAvailablePercentage = 100
    )
    
    Write-LogEntry -Message "Verifying new session hosts are available before proceeding with old host removal"
    
    # Identify new hosts (hosts on the latest image version)
    $newHosts = $SessionHosts | Where-Object { 
        $_.ImageVersion -eq $LatestImageVersion.Version -and 
        $_.ImageDefinition -eq $LatestImageVersion.Definition 
    }
    
    if (-not $newHosts -or $newHosts.Count -eq 0) {
        Write-LogEntry -Message "No new session hosts found on latest image version - skipping availability check" -Level Trace
        return [PSCustomObject]@{
            AllAvailable      = $true
            AvailableCount    = 0
            TotalNewHosts     = 0
            UnavailableHosts  = @()
            SafeToProceed     = $true
            Message           = "No new hosts to verify"
        }
    }
    
    Write-LogEntry -Message "Found {0} new session host(s) on latest image version {1}" -StringValues $newHosts.Count, $LatestImageVersion.Version
    
    # Check status of each new host
    # Available statuses that indicate the host is working: Available, Needs Assistance (non-fatal), Upgrading, Upgrade Failed
    # Statuses that indicate the host is NOT working: Unavailable, Shutdown, NoHeartbeat, NotJoinedToDomain, DomainTrustRelationshipLost, SxSStackListenerNotReady, FSLogixNotHealthy
    $availableStatuses = @('Available', 'NeedsAssistance', 'Upgrading', 'UpgradeFailed')
    
    $availableHosts = @()
    $unavailableHosts = @()
    
    foreach ($newHost in $newHosts) {
        $hostStatus = $newHost.Status
        $hostName = $newHost.SessionHostName
        
        Write-LogEntry -Message "New host {0} status: {1}" -StringValues $hostName, $hostStatus -Level Trace
        
        if ($hostStatus -in $availableStatuses) {
            $availableHosts += $newHost
            Write-LogEntry -Message "New host {0} is accessible (Status: {1})" -StringValues $hostName, $hostStatus -Level Trace
        }
        else {
            $unavailableHosts += [PSCustomObject]@{
                SessionHostName = $hostName
                Status          = $hostStatus
                ImageVersion    = $newHost.ImageVersion
            }
            Write-LogEntry -Message "New host {0} is NOT accessible (Status: {1})" -StringValues $hostName, $hostStatus -Level Warning
        }
    }
    
    $availableCount = $availableHosts.Count
    $totalNewHosts = $newHosts.Count
    $availablePercentage = if ($totalNewHosts -gt 0) { [Math]::Round(($availableCount / $totalNewHosts) * 100, 1) } else { 0 }
    
    # Determine if safe to proceed
    $meetsMinimumCount = $availableCount -ge $MinimumAvailableCount
    $meetsMinimumPercentage = $availablePercentage -ge $MinimumAvailablePercentage
    $allAvailable = $unavailableHosts.Count -eq 0
    $safeToProceed = $meetsMinimumCount -and $meetsMinimumPercentage
    
    # Build result message
    $message = if ($allAvailable) {
        "All $totalNewHosts new session host(s) are available"
    }
    elseif ($safeToProceed) {
        "$availableCount of $totalNewHosts new session host(s) are available ($availablePercentage%) - meets minimum requirements"
    }
    else {
        "Only $availableCount of $totalNewHosts new session host(s) are available ($availablePercentage%) - does NOT meet minimum requirements (need $MinimumAvailableCount hosts and $MinimumAvailablePercentage%)"
    }
    
    Write-LogEntry -Message "NEW_HOST_VERIFICATION | Available: {0}/{1} ({2}%) | SafeToProceed: {3}" -StringValues $availableCount, $totalNewHosts, $availablePercentage, $safeToProceed
    
    if (-not $safeToProceed) {
        Write-LogEntry -Message "WARNING: New session hosts are not ready - will skip removal of old hosts to preserve capacity" -Level Warning
        foreach ($unavailable in $unavailableHosts) {
            Write-LogEntry -Message "  - {0}: Status={1}" -StringValues $unavailable.SessionHostName, $unavailable.Status -Level Warning
        }
    }
    
    return [PSCustomObject]@{
        AllAvailable         = $allAvailable
        AvailableCount       = $availableCount
        TotalNewHosts        = $totalNewHosts
        AvailablePercentage  = $availablePercentage
        UnavailableHosts     = $unavailableHosts
        SafeToProceed        = $safeToProceed
        Message              = $message
    }
}

#EndRegion Session Host Lifecycle

# Export functions
Export-ModuleMember -Function Remove-SessionHosts, Remove-VirtualMachine, Remove-ExpiredShutdownVMs, Send-DrainNotification, Test-NewSessionHostsAvailable
