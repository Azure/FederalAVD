[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$DeviceNamePrefix,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

try {
    # Check if Microsoft.Graph.DeviceManagement module is available
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.DeviceManagement)) {
        throw "Microsoft.Graph.DeviceManagement module is not installed. Please run: Install-Module Microsoft.Graph.DeviceManagement"
    }

    # Import the module
    Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop

    # Check if user is authenticated
    $context = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $context) {
        Write-Output "Not authenticated to Microsoft Graph. Please sign in..."
        Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All" -ErrorAction Stop
    }
    else {
        Write-Output "Using existing Microsoft Graph session"
        Write-Output "  User: $($context.Account)"
        Write-Output "  Tenant: $($context.TenantId)"
    }

    # Search for Intune managed devices with the specified prefix
    Write-Output ""
    Write-Output "Searching for Intune devices starting with: '$DeviceNamePrefix'"
    Write-Output "=================================================="
    
    $allDevices = @(Get-MgDeviceManagementManagedDevice -Filter "startswith(deviceName,'$DeviceNamePrefix')" -All)
    
    if ($allDevices.Count -eq 0) {
        Write-Output "No devices found with prefix '$DeviceNamePrefix'"
        return
    }
    
    Write-Output "Found $($allDevices.Count) device(s) to delete:"
    Write-Output ""
    
    # Display devices in a table format
    $allDevices | ForEach-Object {
        Write-Output "  • $($_.DeviceName)"
        Write-Output "    ID: $($_.Id)"
        Write-Output "    User: $($_.UserDisplayName)"
        Write-Output "    OS: $($_.OperatingSystem) $($_.OsVersion)"
        Write-Output "    Last Sync: $($_.LastSyncDateTime)"
        Write-Output ""
    }
    
    if ($WhatIf) {
        Write-Output "=================================================="
        Write-Output "WhatIf mode enabled - no devices will be deleted"
        Write-Output "=================================================="
        return
    }
    
    # Confirm deletion
    Write-Output "=================================================="
    Write-Warning "You are about to delete $($allDevices.Count) device(s) from Intune!"
    $confirmation = Read-Host "Type 'DELETE' to confirm deletion"
    
    if ($confirmation -ne 'DELETE') {
        Write-Output "Deletion cancelled by user"
        return
    }
    
    Write-Output ""
    Write-Output "Deleting devices..."
    Write-Output "=================================================="
    
    $successCount = 0
    $failCount = 0
    
    foreach ($device in $allDevices) {
        try {
            Write-Output "Deleting: $($device.DeviceName) (ID: $($device.Id))"
            Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $device.Id -ErrorAction Stop
            Write-Output "  Successfully deleted"
            $successCount++
        }
        catch {
            Write-Error "Failed to delete: $($_.Exception.Message)"
            $failCount++
        }
    }
    
    Write-Output ""
    Write-Output "=================================================="
    Write-Output "Deletion Summary:"
    Write-Output "  Successfully deleted: $successCount"
    if ($failCount -gt 0) {
        Write-Output "Failed: $failCount"
    }
    Write-Output "=================================================="
}
catch {
    Write-Error $_.Exception.Message
    Write-Error $_.ScriptStackTrace
    throw $_
}
