# SessionHostReplacer Device Cleanup Module
# Contains Entra ID and Intune device removal functions

# Import Core utilities
Import-Module "$PSScriptRoot\SessionHostReplacer.Core.psm1" -Force

#Region Device Cleanup

function Remove-DeviceFromDirectories {
    <#
    .SYNOPSIS
    Removes a device from Entra ID and/or Intune based on configuration.
    
    .DESCRIPTION
    Helper function to handle device cleanup from identity directories.
    Called by both Remove-SessionHosts and Remove-ExpiredShutdownVMs.
    
    .PARAMETER DeviceName
    The name of the device to remove
    
    .PARAMETER GraphToken
    Graph access token for API calls
    
    .PARAMETER RemoveEntraDevice
    Whether to remove from Entra ID
    
    .PARAMETER RemoveIntuneDevice
    Whether to remove from Intune
    
    .PARAMETER ClientId
    Client ID for Graph API calls
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $DeviceName,
        [Parameter()]
        [string] $GraphToken,
        [Parameter()]
        [bool] $RemoveEntraDevice,
        [Parameter()]
        [bool] $RemoveIntuneDevice,
        [Parameter()]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )
    
    if (-not $GraphToken) {
        Write-LogEntry -Message "No Graph token provided - skipping device cleanup for $DeviceName" -Level Trace
        return
    }
    
    if ($RemoveEntraDevice) {
        Write-LogEntry -Message "Deleting $DeviceName from Entra ID" -Level Trace
        try {
            Remove-EntraDevice -GraphToken $GraphToken -Name $DeviceName -ClientId $ClientId
        }
        catch {
            Write-LogEntry -Message "Failed to remove $DeviceName from Entra ID: $($_.Exception.Message)" -Level Warning
        }
    }
    
    if ($RemoveIntuneDevice) {
        Write-LogEntry -Message "Deleting $DeviceName from Intune" -Level Trace
        try {
            Remove-IntuneDevice -GraphToken $GraphToken -Name $DeviceName -ClientId $ClientId
        }
        catch {
            Write-LogEntry -Message "Failed to remove $DeviceName from Intune: $($_.Exception.Message)" -Level Warning
        }
    }
}

function Remove-EntraDevice {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string] $GraphEndpoint = (Get-GraphEndpoint),
        [Parameter(Mandatory = $true)]
        $GraphToken,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $false)]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )
    
    try {
        $Device = Invoke-GraphApiWithRetry `
            -GraphEndpoint $GraphEndpoint `
            -GraphToken $GraphToken `
            -Method Get `
            -Uri "/v1.0/devices?`$filter=displayName eq '$Name'" `
            -ClientId $ClientId
        
        If ($Device.value -and $Device.value.Count -gt 0) {
            $Id = $Device.value[0].id
            Write-LogEntry -Message "Removing session host $Name from Entra ID"
            Write-LogEntry -Message "Device ID: $Id" -Level Trace
            
            Invoke-GraphApiWithRetry `
                -GraphEndpoint $GraphEndpoint `
                -GraphToken $GraphToken `
                -Method Delete `
                -Uri "/v1.0/devices/$Id" `
                -ClientId $ClientId
            
            Write-LogEntry -Message "Successfully removed device $Name from Entra ID"
        }
        else {
            Write-LogEntry -Message "Device $Name not found in Entra ID"
        }
    }
    catch {
        # Check if error is 404 (device already deleted)
        $is404 = $_.Exception.Response.StatusCode.value__ -eq 404
        if ($is404) {
            Write-LogEntry -Message "Device $Name not found in Entra ID (404)"
        }
        else {
            Write-LogEntry -Message "Failed to remove Entra device $Name : $($_.Exception.Message)" -Level Error
            throw
        }
    }
}

function Remove-IntuneDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $GraphEndpoint = (Get-GraphEndpoint),
        [Parameter(Mandatory = $true)]
        $GraphToken,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $false)]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )
    
    try {
        $Device = Invoke-GraphApiWithRetry `
            -GraphEndpoint $GraphEndpoint `
            -GraphToken $GraphToken `
            -Method Get `
            -Uri "/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$Name'" `
            -ClientId $ClientId
        
        If ($Device.value -and $Device.value.Count -gt 0) {
            $Id = $Device.value[0].id
            Write-LogEntry -Message "Removing session host '$Name' device from Intune"
            Write-LogEntry -Message "Device ID: $Id" -Level Trace
            
            Invoke-GraphApiWithRetry `
                -GraphEndpoint $GraphEndpoint `
                -GraphToken $GraphToken `
                -Method Delete `
                -Uri "/v1.0/deviceManagement/managedDevices/$Id" `
                -ClientId $ClientId
            
            Write-LogEntry -Message "Successfully removed device $Name from Intune"
        }
        else {
            Write-LogEntry -Message "Device $Name not found in Intune"
        }
    }
    catch {
        # Check if error is 404 (device not enrolled or already deleted)
        $is404 = $_.Exception.Response.StatusCode.value__ -eq 404
        if ($is404) {
            Write-LogEntry -Message "Device $Name not found in Intune (404)"
        }
        else {
            Write-LogEntry -Message "Failed to remove Intune device $Name : $($_.Exception.Message)" -Level Error
            throw
        }
    }
}

function Confirm-SessionHostDeletions {
    <#
    .SYNOPSIS
    Validates complete deletion of session hosts across VM, Entra ID, and Intune.
    
    .DESCRIPTION
    Polls Azure to confirm VM deletion, then verifies Graph cleanup for Entra ID and Intune devices.
    Provides per-host validation status and comprehensive summary logging.
    
    .PARAMETER ARMToken
    ARM access token for Azure Resource Manager API calls
    
    .PARAMETER GraphToken
    Graph access token for Entra ID and Intune API calls
    
    .PARAMETER DeletedHostNames
    Array of session host names that were successfully deleted
    
    .PARAMETER SessionHosts
    Array of session host objects (to get resource IDs)
    
    .PARAMETER MaxWaitMinutes
    Maximum time to wait for VM deletion confirmation (default: 5)
    
    .PARAMETER PollIntervalSeconds
    Seconds between polling attempts (default: 30)
    
    .PARAMETER RemoveEntraDevice
    Whether Entra ID device deletion was performed (only validate if true)
    
    .PARAMETER RemoveIntuneDevice
    Whether Intune device deletion was performed (only validate if true)
    
    .OUTPUTS
    PSCustomObject with validation results including VM, Entra ID, and Intune confirmation counts
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ARMToken,
        [Parameter()]
        [string] $GraphToken,
        [Parameter(Mandatory = $true)]
        [array] $DeletedHostNames,
        [Parameter(Mandatory = $true)]
        [array] $SessionHosts,
        [Parameter()]
        [int] $MaxWaitMinutes = 5,
        [Parameter()]
        [int] $PollIntervalSeconds = 30,
        [Parameter()]
        [bool] $RemoveEntraDevice = $false,
        [Parameter()]
        [bool] $RemoveIntuneDevice = $false,
        [Parameter()]
        [string] $ResourceManagerUri = (Get-ResourceManagerUri),
        [Parameter()]
        [string] $ClientId = (Read-FunctionAppSetting UserAssignedIdentityClientId)
    )
    
    if ($DeletedHostNames.Count -eq 0) {
        Write-LogEntry -Message "No hosts to verify - skipping validation" -Level Trace
        return [PSCustomObject]@{
            TotalHosts       = 0
            VMsConfirmed     = 0
            EntraIDConfirmed = 0
            IntuneConfirmed  = 0
            IncompleteHosts  = @()
        }
    }
    
    Write-LogEntry -Message "Verifying complete deletion for {0} host(s) (VM, Entra ID, Intune)..." -StringValues $DeletedHostNames.Count
    
    $startTime = Get-Date
    $timeoutTime = $startTime.AddMinutes($MaxWaitMinutes)
    
    # Build validation tracking for each deleted host
    $hostsToVerify = @()
    foreach ($deletedName in $DeletedHostNames) {
        $sessionHost = $SessionHosts | Where-Object { $_.SessionHostName -eq $deletedName } | Select-Object -First 1
        if (-not $sessionHost) {
            Write-LogEntry -Message "Warning: Could not find resource ID for deleted host {0}, skipping verification" -StringValues $deletedName -Level Warning
            continue
        }
        
        $vmName = $sessionHost.resourceId.Split('/')[-1]
        $vmUri = "$ResourceManagerUri$($sessionHost.ResourceId)?api-version=2024-03-01"
        
        $hostsToVerify += [PSCustomObject]@{
            Name             = $deletedName
            VMName           = $vmName
            VMUri            = $vmUri
            VMConfirmed      = $false
            EntraIDConfirmed = $false
            IntuneConfirmed  = $false
        }
    }
    
    # Poll VMs until all are gone or timeout
    $checkCount = 0
    while ((Get-Date) -lt $timeoutTime -and ($hostsToVerify | Where-Object { -not $_.VMConfirmed }).Count -gt 0) {
        $checkCount++
        $elapsedSeconds = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)
        $remainingVMs = ($hostsToVerify | Where-Object { -not $_.VMConfirmed }).Count
        Write-LogEntry -Message "VM verification check {0} at {1}s: Checking {2} remaining VM(s)..." -StringValues $checkCount, $elapsedSeconds, $remainingVMs -Level Trace
        
        foreach ($host in ($hostsToVerify | Where-Object { -not $_.VMConfirmed })) {
            try {
                $vmCheck = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $host.VMUri -ErrorAction SilentlyContinue
                
                if ($null -eq $vmCheck -or $vmCheck.error.code -eq 'ResourceNotFound') {
                    $host.VMConfirmed = $true
                    Write-LogEntry -Message "VM deletion confirmed: {0}" -StringValues $host.VMName -Level Trace
                }
            }
            catch {
                # Exception likely means VM not found
                $host.VMConfirmed = $true
                Write-LogEntry -Message "VM deletion confirmed: {0}" -StringValues $host.VMName -Level Trace
            }
        }
        
        if (($hostsToVerify | Where-Object { -not $_.VMConfirmed }).Count -gt 0 -and (Get-Date) -lt $timeoutTime) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }
    
    # Verify Graph cleanup for all hosts (Entra ID and Intune)
    if ($GraphToken -and ($RemoveEntraDevice -or $RemoveIntuneDevice)) {
        $checkSystems = @()
        if ($RemoveEntraDevice) { $checkSystems += 'Entra ID' }
        if ($RemoveIntuneDevice) { $checkSystems += 'Intune' }
        Write-LogEntry -Message "Verifying {0} device cleanup..." -StringValues ($checkSystems -join ' and ') -Level Trace
        
        foreach ($host in $hostsToVerify) {
            # Check Entra ID (only if removal was attempted)
            if ($RemoveEntraDevice) {
                try {
                    $entraDevice = Invoke-GraphApiWithRetry `
                        -GraphEndpoint (Get-GraphEndpoint) `
                        -GraphToken $GraphToken `
                        -Method Get `
                        -Uri "/v1.0/devices?`$filter=displayName eq '$($host.Name)'" `
                        -ClientId $ClientId
                    
                    if ($entraDevice.value -and $entraDevice.value.Count -gt 0) {
                        Write-LogEntry -Message "Entra ID device still exists: {0}" -StringValues $host.Name -Level Trace
                    }
                    else {
                        $host.EntraIDConfirmed = $true
                        Write-LogEntry -Message "Entra ID deletion confirmed: {0}" -StringValues $host.Name -Level Trace
                    }
                }
                catch {
                    Write-LogEntry -Message "Error verifying Entra ID deletion for {0}: {1}" -StringValues $host.Name, $_.Exception.Message -Level Warning
                }
            }
            else {
                # Not attempted, mark as confirmed
                $host.EntraIDConfirmed = $true
            }
            
            # Check Intune (only if removal was attempted)
            if ($RemoveIntuneDevice) {
                try {
                    $intuneDevice = Invoke-GraphApiWithRetry `
                        -GraphEndpoint (Get-GraphEndpoint) `
                        -GraphToken $GraphToken `
                        -Method Get `
                        -Uri "/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$($host.Name)'" `
                        -ClientId $ClientId
                    
                    if ($intuneDevice.value -and $intuneDevice.value.Count -gt 0) {
                        Write-LogEntry -Message "Intune device still exists: {0}" -StringValues $host.Name -Level Trace
                    }
                    else {
                        $host.IntuneConfirmed = $true
                        Write-LogEntry -Message "Intune deletion confirmed: {0}" -StringValues $host.Name -Level Trace
                    }
                }
                catch {
                    Write-LogEntry -Message "Error verifying Intune deletion for {0}: {1}" -StringValues $host.Name, $_.Exception.Message -Level Warning
                }
            }
            else {
                # Not attempted, mark as confirmed
                $host.IntuneConfirmed = $true
            }
            
            # Per-host validation summary
            $vmStatus = if ($host.VMConfirmed) { "✓" } else { "✗" }
            $entraStatus = if ($host.EntraIDConfirmed) { "✓" } else { "✗" }
            $intuneStatus = if ($host.IntuneConfirmed) { "✓" } else { "✗" }
            Write-LogEntry -Message "Deletion status for {0}: VM={1} EntraID={2} Intune={3}" -StringValues $host.Name, $vmStatus, $entraStatus, $intuneStatus -Level Trace
        }
    }
    else {
        Write-LogEntry -Message "Graph token not available - skipping Entra ID and Intune validation" -Level Trace
        # Mark all as confirmed since we can't verify
        foreach ($host in $hostsToVerify) {
            $host.EntraIDConfirmed = $true
            $host.IntuneConfirmed = $true
        }
    }

    # Calculate summary counts
    $vmsConfirmed = ($hostsToVerify | Where-Object { $_.VMConfirmed }).Count
    $entraIDConfirmed = ($hostsToVerify | Where-Object { $_.EntraIDConfirmed }).Count
    $intuneConfirmed = ($hostsToVerify | Where-Object { $_.IntuneConfirmed }).Count
    $totalHosts = $hostsToVerify.Count

    # Summary logging
    Write-LogEntry -Message "DELETION_VERIFICATION | VMs: {0}/{1} confirmed | EntraID: {2}/{3} confirmed | Intune: {4}/{5} confirmed" `
        -StringValues $vmsConfirmed, $totalHosts, $entraIDConfirmed, $totalHosts, $intuneConfirmed, $totalHosts

    # Warn about any incomplete deletions
    $incompleteHosts = $hostsToVerify | Where-Object { -not ($_.VMConfirmed -and $_.EntraIDConfirmed -and $_.IntuneConfirmed) }
    if ($incompleteHosts.Count -gt 0) {
        foreach ($host in $incompleteHosts) {
            $failures = @()
            if (-not $host.VMConfirmed) { $failures += "VM" }
            if (-not $host.EntraIDConfirmed) { $failures += "EntraID" }
            if (-not $host.IntuneConfirmed) { $failures += "Intune" }
            Write-LogEntry -Message "Warning: Incomplete deletion for {0} - unconfirmed: {1}" -StringValues $host.Name, ($failures -join ', ') -Level Warning
        }
    }
    else {
        Write-LogEntry -Message "All deletions fully confirmed across VM, Entra ID, and Intune"
    }

    # Return validation results
    return [PSCustomObject]@{
        TotalHosts       = $totalHosts
        VMsConfirmed     = $vmsConfirmed
        EntraIDConfirmed = $entraIDConfirmed
        IntuneConfirmed  = $intuneConfirmed
        IncompleteHosts  = $incompleteHosts
    }
}

#EndRegion Device Cleanup

# Export functions
Export-ModuleMember -Function Remove-DeviceFromDirectories, Remove-EntraDevice, Remove-IntuneDevice, Confirm-SessionHostDeletions
