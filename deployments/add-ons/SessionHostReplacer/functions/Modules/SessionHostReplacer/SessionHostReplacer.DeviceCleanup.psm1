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

#EndRegion Device Cleanup

# Export functions
Export-ModuleMember -Function Remove-DeviceFromDirectories, Remove-EntraDevice, Remove-IntuneDevice
