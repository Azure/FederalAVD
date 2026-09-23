# Compatibility wrapper for enabling AVD single sign-on for one target device group.
# Connect to the correct Microsoft Graph environment before running this script.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DeviceGroupId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DeviceGroupDisplayName
)

$deviceGroups = @(
    @{
        id          = $DeviceGroupId
        displayName = $DeviceGroupDisplayName
    }
)

& (Join-Path $PSScriptRoot 'Enable-AVDSSO.ps1') -DeviceGroups $deviceGroups
