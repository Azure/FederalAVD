# SessionHostReplacer Monitoring Module
# Contains host pool status tagging function

#Region Monitoring

function Update-HostPoolStatus {
    <#
    .SYNOPSIS
    Updates the host pool with a status tag indicating SessionHostReplacer progress.
    
    .DESCRIPTION
    Creates a composite status tag on the host pool showing overall status and metrics.
    Format: "Status: X/Y up-to-date | N draining | M shutdown"
    
    Status values:
    - Complete: All hosts up-to-date, no pending work
    - Updating: Active deployments or deletions in progress
    - Recovery: Failed deployments detected
    - Draining: Hosts in drain mode waiting for grace period
    
    .PARAMETER ARMToken
    ARM access token for API calls
    
    .PARAMETER SessionHosts
    Collection of all session hosts in the pool
    
    .PARAMETER RunningDeployments
    Count of active deployments
    
    .PARAMETER FailedDeployments
    Collection of failed deployments
    
    .PARAMETER HostsToReplace
    Count of hosts needing replacement
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),
        [Parameter(Mandatory = $true)]
        $SessionHosts,
        [Parameter()]
        [int] $RunningDeployments = 0,
        [Parameter()]
        $FailedDeployments = @(),
        [Parameter()]
        [int] $HostsToReplace = 0,
        [Parameter()]
        [array] $CachedVMs,
        [Parameter()]
        [string] $HostPoolSubscriptionId = (Read-FunctionAppSetting HostPoolSubscriptionId),
        [Parameter()]
        [string] $HostPoolResourceGroupName = (Read-FunctionAppSetting HostPoolResourceGroupName),
        [Parameter()]
        [string] $HostPoolName = (Read-FunctionAppSetting HostPoolName),
        [Parameter()]
        [string] $TagShutdownTimestamp = (Read-FunctionAppSetting Tag_ShutdownTimestamp)
    )
    
    try {
        # Calculate metrics using the same math as the METRICS log
        $totalHosts = $SessionHosts.Count
        $drainingHosts = ($SessionHosts | Where-Object { -not $_.AllowNewSession }).Count
        
        # Count shutdown hosts (VMs with shutdown timestamp tag) - these are old hosts awaiting deletion
        $shutdownHosts = 0
        try {
            # Use cached VMs if provided, otherwise fetch
            if ($CachedVMs -and $CachedVMs.Count -gt 0) {
                Write-LogEntry -Message "Using cached VM data for shutdown host count" -Level Trace
                $allVMs = $CachedVMs
            }
            else {
                $vmSubscriptionId = Read-FunctionAppSetting VirtualMachinesSubscriptionId
                $vmResourceGroupName = Read-FunctionAppSetting VirtualMachinesResourceGroupName
                $Uri = "$ResourceManagerUri/subscriptions/$vmSubscriptionId/resourceGroups/$vmResourceGroupName/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01"
                $allVMs = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $Uri
            }
            $shutdownVMs = $allVMs | Where-Object { $_.tags -and $_.tags.PSObject.Properties.Name -contains $TagShutdownTimestamp }
            $shutdownHosts = if ($shutdownVMs) { $shutdownVMs.Count } else { 0 }
        }
        catch {
            Write-LogEntry -Message "Could not query shutdown hosts: $($_.Exception.Message)" -Level Trace
        }
        
        # Up-to-date hosts calculation:
        # - Start with total hosts in host pool
        # - Subtract shutdown hosts (old hosts awaiting deletion, not actively serving users)
        # - Subtract hosts that need replacement (out-of-date active hosts)
        # Result: Active hosts on the latest image version
        $activeHosts = $totalHosts - $shutdownHosts
        $upToDateHosts = $activeHosts - $HostsToReplace
        
        # Determine status (prioritize completion when all hosts are up-to-date)
        $status = if ($FailedDeployments.Count -gt 0) {
            "Recovery"
        }
        elseif ($upToDateHosts -eq $activeHosts -and $shutdownHosts -eq 0 -and $RunningDeployments -eq 0 -and $HostsToReplace -eq 0) {
            # All active hosts up-to-date, no shutdown hosts, no deployments, no replacements needed = complete
            # Draining hosts (manually drained by admin) don't block completion status
            "Complete"
        }
        elseif ($RunningDeployments -gt 0 -or $HostsToReplace -gt 0) {
            "Updating"
        }
        elseif ($drainingHosts -gt 0) {
            "Draining"
        }
        else {
            "Updating"
        }
        
        # Build composite status string - show active hosts (excluding shutdown) in the ratio
        $statusParts = @("$status`: $upToDateHosts/$activeHosts up-to-date")
        
        if ($drainingHosts -gt 0) {
            $statusParts += "$drainingHosts draining"
        }
        
        if ($shutdownHosts -gt 0) {
            $statusParts += "$shutdownHosts shutdown"
        }
        
        if ($RunningDeployments -gt 0) {
            $statusParts += "$RunningDeployments deploying"
        }
        
        $statusValue = $statusParts -join " | "
        
        Write-LogEntry -Message "Updating host pool status tag: $statusValue" -Level Trace
        
        # Update host pool tags
        $Uri = "$ResourceManagerUri/subscriptions/$HostPoolSubscriptionId/resourceGroups/$HostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
        $Body = @{
            properties = @{
                tags = @{ 
                    'SessionHostReplacerStatus' = $statusValue
                    'SessionHostReplacerLastRun' = (Get-Date -AsUTC -Format 'o')
                }
            }
            operation  = 'Merge'
        }
        
        Invoke-AzureRestMethod -ARMToken $ARMToken -Body ($Body | ConvertTo-Json -Depth 5) -Method PATCH -Uri $Uri | Out-Null
        
        Write-LogEntry -Message "Successfully updated host pool status tag"
    }
    catch {
        Write-LogEntry -Message "Failed to update host pool status tag: $($_.Exception.Message)" -Level Warning
    }
}

#EndRegion Monitoring

# Export function
Export-ModuleMember -Function Update-HostPoolStatus
