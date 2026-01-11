# SessionHostReplacer Lifecycle Module
# Contains session host removal, shutdown retention, and drain notification functions

# Import Core and DeviceCleanup utilities
Import-Module "$PSScriptRoot\SessionHostReplacer.Core.psm1" -Force
Import-Module "$PSScriptRoot\SessionHostReplacer.DeviceCleanup.psm1" -Force

#Region Session Host Lifecycle

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
        [int] $DrainGracePeriodHours = [int]::Parse((Read-FunctionAppSetting DrainGracePeriodHours)),
        [Parameter()]
        [int] $MinimumDrainMinutes = [int]::Parse((Read-FunctionAppSetting MinimumDrainMinutes)),
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
        [bool] $EnableShutdownRetention = $(
            $setting = Read-FunctionAppSetting EnableShutdownRetention
            if ([string]::IsNullOrEmpty($setting)) { $false } else { [bool]::Parse($setting) }
        ),
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
            
            # Optimization: If MinimumDrainMinutes = 0, skip draining entirely and delete immediately
            if ($MinimumDrainMinutes -eq 0) {
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
                
                # Re-evaluate deletion eligibility now that we have a timestamp (allows immediate deletion when MinimumDrainMinutes = 0 or SideBySide mode)
                if ($sessionHost.Sessions -eq 0) {
                    $elapsedMinutes = ((Get-Date).ToUniversalTime() - $sessionHost.PendingDrainTimeStamp).TotalMinutes
                    # In SideBySide mode, allow immediate deletion since new capacity is already deployed
                    if ($ReplacementMode -eq 'SideBySide' -or $elapsedMinutes -ge $MinimumDrainMinutes) {
                        Write-LogEntry -Message "Session host $($sessionHost.SessionHostName) meets deletion criteria ($([Math]::Round($elapsedMinutes, 1)) minutes elapsed, mode: $ReplacementMode), marking for immediate deletion"
                        $deleteSessionHost = $true
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
                    Write-LogEntry -Message "Successfully shutdown session host $($sessionHost.SessionHostName) - will remain in host pool for $([int]::Parse((Read-FunctionAppSetting ShutdownRetentionDays))) days for rollback"
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
        [int] $ShutdownRetentionDays = [int]::Parse((Read-FunctionAppSetting ShutdownRetentionDays)),
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
        [bool] $RemoveEntraDevice = [bool]::Parse((Read-FunctionAppSetting RemoveEntraDevice)),
        [Parameter()]
        [bool] $RemoveIntuneDevice = [bool]::Parse((Read-FunctionAppSetting RemoveIntuneDevice)),
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

#EndRegion Session Host Lifecycle

# Export functions
Export-ModuleMember -Function Remove-SessionHosts, Remove-VirtualMachine, Remove-ExpiredShutdownVMs, Send-DrainNotification
