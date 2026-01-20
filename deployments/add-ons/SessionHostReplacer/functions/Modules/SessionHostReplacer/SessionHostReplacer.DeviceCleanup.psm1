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
        [bool] $RemoveEntraDevice = (Read-FunctionAppSetting RemoveEntraDevice -AsBoolean),
        [Parameter()]
        [bool] $RemoveIntuneDevice = (Read-FunctionAppSetting RemoveIntuneDevice -AsBoolean),
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
        [int] $MaxWaitMinutes = 10,
        
        [Parameter()]
        [int] $PollIntervalSeconds = 30,
        
        [Parameter()]
        [bool] $RemoveEntraDevice = (Read-FunctionAppSetting RemoveEntraDevice -AsBoolean),
        
        [Parameter()]
        [bool] $RemoveIntuneDevice = (Read-FunctionAppSetting RemoveIntuneDevice -AsBoolean),
        
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
    
    # Mark Entra/Intune as confirmed if not being checked
    if (-not $GraphToken -or (-not $RemoveEntraDevice -and -not $RemoveIntuneDevice)) {
        Write-LogEntry -Message "Graph token not available or device cleanup disabled - skipping Entra ID and Intune validation" -Level Trace
        foreach ($sh in $hostsToVerify) {
            $sh.EntraIDConfirmed = $true
            $sh.IntuneConfirmed = $true
        }
    }
    elseif (-not $RemoveEntraDevice) {
        foreach ($sh in $hostsToVerify) { $sh.EntraIDConfirmed = $true }
    }
    elseif (-not $RemoveIntuneDevice) {
        foreach ($sh in $hostsToVerify) { $sh.IntuneConfirmed = $true }
    }
    
    # Build verification system list for logging
    $checkSystems = @('VM')
    if ($GraphToken -and $RemoveEntraDevice) { $checkSystems += 'Entra ID' }
    if ($GraphToken -and $RemoveIntuneDevice) { $checkSystems += 'Intune' }
    Write-LogEntry -Message "Verifying deletion for {0}..." -StringValues ($checkSystems -join ', ') -Level Trace
    
    # Poll all systems until all hosts fully confirmed or timeout
    $checkCount = 0
    $incompleteHosts = $hostsToVerify | Where-Object { -not ($_.VMConfirmed -and $_.EntraIDConfirmed -and $_.IntuneConfirmed) }
    
    while ((Get-Date) -lt $timeoutTime -and $incompleteHosts.Count -gt 0) {
        $checkCount++
        $elapsedSeconds = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)
        $remainingHosts = $incompleteHosts.Count
        Write-LogEntry -Message "Deletion verification check {0} at {1}s: {2} host(s) with incomplete deletion..." -StringValues $checkCount, $elapsedSeconds, $remainingHosts -Level Trace
        
        foreach ($sh in $incompleteHosts) {
            # Check VM deletion
            if (-not $sh.VMConfirmed) {
                try {
                    $vmCheck = Invoke-AzureRestMethod -ARMToken $ARMToken -Method Get -Uri $sh.VMUri -ErrorAction SilentlyContinue
                    
                    if ($null -eq $vmCheck -or $vmCheck.error.code -eq 'ResourceNotFound') {
                        $sh.VMConfirmed = $true
                        Write-LogEntry -Message "VM deletion confirmed: {0}" -StringValues $sh.VMName -Level Trace
                    }
                }
                catch {
                    # Exception likely means VM not found
                    $sh.VMConfirmed = $true
                    Write-LogEntry -Message "VM deletion confirmed: {0}" -StringValues $sh.VMName -Level Trace
                }
            }
            
            # Check Entra ID deletion (only if removal was enabled and Graph token available)
            if (-not $sh.EntraIDConfirmed -and $GraphToken -and $RemoveEntraDevice) {
                try {
                    $entraDevice = Invoke-GraphApiWithRetry `
                        -GraphEndpoint (Get-GraphEndpoint) `
                        -GraphToken $GraphToken `
                        -Method Get `
                        -Uri "/v1.0/devices?`$filter=displayName eq '$($sh.Name)'" `
                        -ClientId $ClientId
                    
                    if (-not $entraDevice.value -or $entraDevice.value.Count -eq 0) {
                        $sh.EntraIDConfirmed = $true
                        Write-LogEntry -Message "Entra ID deletion confirmed: {0}" -StringValues $sh.Name -Level Trace
                    }
                }
                catch {
                    Write-LogEntry -Message "Error verifying Entra ID deletion for {0}: {1}" -StringValues $sh.Name, $_.Exception.Message -Level Warning
                }
            }
            
            # Check Intune deletion (only if removal was enabled and Graph token available)
            if (-not $sh.IntuneConfirmed -and $GraphToken -and $RemoveIntuneDevice) {
                try {
                    $intuneDevice = Invoke-GraphApiWithRetry `
                        -GraphEndpoint (Get-GraphEndpoint) `
                        -GraphToken $GraphToken `
                        -Method Get `
                        -Uri "/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$($sh.Name)'" `
                        -ClientId $ClientId
                    
                    if (-not $intuneDevice.value -or $intuneDevice.value.Count -eq 0) {
                        $sh.IntuneConfirmed = $true
                        Write-LogEntry -Message "Intune deletion confirmed: {0}" -StringValues $sh.Name -Level Trace
                    }
                }
                catch {
                    Write-LogEntry -Message "Error verifying Intune deletion for {0}: {1}" -StringValues $sh.Name, $_.Exception.Message -Level Warning
                }
            }
            
            # Log per-host status after each check
            $vmStatus = if ($sh.VMConfirmed) { "✓" } else { "✗" }
            $entraStatus = if ($sh.EntraIDConfirmed) { "✓" } else { "✗" }
            $intuneStatus = if ($sh.IntuneConfirmed) { "✓" } else { "✗" }
            $fullyConfirmed = $sh.VMConfirmed -and $sh.EntraIDConfirmed -and $sh.IntuneConfirmed
            if ($fullyConfirmed) {
                Write-LogEntry -Message "Full deletion confirmed for {0}: VM={1} EntraID={2} Intune={3}" -StringValues $sh.Name, $vmStatus, $entraStatus, $intuneStatus -Level Trace
            }
        }
        
        # Recalculate incomplete hosts for next iteration
        $incompleteHosts = $hostsToVerify | Where-Object { -not ($_.VMConfirmed -and $_.EntraIDConfirmed -and $_.IntuneConfirmed) }
        
        if ($incompleteHosts.Count -gt 0 -and (Get-Date) -lt $timeoutTime) {
            Start-Sleep -Seconds $PollIntervalSeconds
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
        foreach ($sh in $incompleteHosts) {
            $failures = @()
            if (-not $sh.VMConfirmed) { $failures += "VM" }
            if (-not $sh.EntraIDConfirmed) { $failures += "EntraID" }
            if (-not $sh.IntuneConfirmed) { $failures += "Intune" }
            Write-LogEntry -Message "Warning: Incomplete deletion for {0} - unconfirmed: {1}" -StringValues $sh.Name, ($failures -join ', ') -Level Warning
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
