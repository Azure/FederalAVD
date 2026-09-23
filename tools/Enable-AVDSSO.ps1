# Enable AVD single sign-on target device groups through the active Microsoft Graph context.
# Connect to the correct Microsoft Graph environment before running this script.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [object[]]$DeviceGroups
)

$ErrorActionPreference = 'Stop'
$requiredScope = 'Application.ReadWrite.All'
$avdServicePrincipalAppIds = @(
    'a4a365df-50f1-4397-bc59-1a1564b8bb9c'
    '270efc09-cd0d-444b-a71f-39af4910ec45'
)

$context = Get-MgContext -ErrorAction SilentlyContinue
if (-not $context) {
    throw "No Microsoft Graph context is active. Connect to the correct environment with $requiredScope, verify Get-MgContext, and retry."
}
if (-not ($context.Scopes | Where-Object { $_ -ieq $requiredScope })) {
    throw "The active Microsoft Graph context is missing $requiredScope. Reconnect to the same environment with that delegated scope and retry."
}

foreach ($deviceGroup in $DeviceGroups) {
    if ([string]::IsNullOrWhiteSpace([string]$deviceGroup.id) -or
        [string]::IsNullOrWhiteSpace([string]$deviceGroup.displayName)) {
        throw 'Each DeviceGroups item must contain non-empty id and displayName properties.'
    }
}

Write-Host 'Using the active Microsoft Graph context:' -ForegroundColor Cyan
Write-Host "  Account: $($context.Account)" -ForegroundColor White
Write-Host "  Tenant ID: $($context.TenantId)" -ForegroundColor White
Write-Host "  Environment: $($context.Environment)" -ForegroundColor White

foreach ($appId in $avdServicePrincipalAppIds) {
    $servicePrincipals = @(
        Get-MgServicePrincipal -Filter "appId eq '$appId'" -Property 'id,appId,displayName'
    )
    if ($servicePrincipals.Count -ne 1) {
        throw "Expected one AVD service principal for application ID '$appId' but found $($servicePrincipals.Count)."
    }
    $servicePrincipal = $servicePrincipals[0]
    $configurationUri = "/v1.0/servicePrincipals/$($servicePrincipal.Id)/remoteDesktopSecurityConfiguration"

    Invoke-MgGraphRequest `
        -Method PATCH `
        -Uri $configurationUri `
        -Body @{
            '@odata.type'                   = '#microsoft.graph.remoteDesktopSecurityConfiguration'
            isRemoteDesktopProtocolEnabled = $true
        } | Out-Null

    $groupsUri = "$configurationUri/targetDeviceGroups"
    $existingResponse = Invoke-MgGraphRequest -Method GET -Uri $groupsUri
    $existingGroups = @($existingResponse.value)

    foreach ($deviceGroup in $DeviceGroups) {
        if ($existingGroups | Where-Object { $_.id -eq $deviceGroup.id }) {
            Write-Host "  [OK] $($deviceGroup.displayName) is already assigned to $($servicePrincipal.DisplayName)" -ForegroundColor Green
            continue
        }

        Invoke-MgGraphRequest `
            -Method POST `
            -Uri $groupsUri `
            -Body @{
                '@odata.type' = '#microsoft.graph.targetDeviceGroup'
                id          = [string]$deviceGroup.id
                displayName = [string]$deviceGroup.displayName
            } | Out-Null
        Write-Host "  [OK] Added $($deviceGroup.displayName) to $($servicePrincipal.DisplayName)" -ForegroundColor Green
    }
}
