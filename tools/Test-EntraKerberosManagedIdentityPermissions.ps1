# Verify Microsoft Graph application permissions used by Entra Kerberos automation.
# Connect to the correct Microsoft Graph environment before running this script.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagedIdentityObjectId
)

$ErrorActionPreference = 'Stop'
$requiredScope = 'Application.Read.All'
$requiredPermissions = @(
    'Application.ReadWrite.All'
    'DelegatedPermissionGrant.ReadWrite.All'
)

try {
    $graphContext = Get-MgContext
}
catch {
    throw "Unable to read the Microsoft Graph context. Install the Microsoft.Graph PowerShell module, connect to the correct environment, and retry. $($_.Exception.Message)"
}

if ($null -eq $graphContext -or [string]::IsNullOrWhiteSpace($graphContext.Account)) {
    throw "No Microsoft Graph context is active. Connect to the correct environment with $requiredScope, verify Get-MgContext, and retry."
}
if (-not ($graphContext.Scopes | Where-Object { $_ -ieq $requiredScope })) {
    throw "The active Microsoft Graph context is missing the required delegated scope '$requiredScope'. Reconnect to the same environment and retry."
}

Write-Host 'Using the active Microsoft Graph context:' -ForegroundColor Cyan
Write-Host "  Account: $($graphContext.Account)" -ForegroundColor White
Write-Host "  Tenant ID: $($graphContext.TenantId)" -ForegroundColor White
Write-Host "  Environment: $($graphContext.Environment)" -ForegroundColor White

$managedIdentitySp = Get-MgServicePrincipal -ServicePrincipalId $ManagedIdentityObjectId
$graphServicePrincipals = @(
    Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'" -Property 'id,appRoles'
)
if ($graphServicePrincipals.Count -ne 1) {
    throw "Expected one Microsoft Graph service principal but found $($graphServicePrincipals.Count)."
}
$graphSp = $graphServicePrincipals[0]
$assignments = @(
    Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentitySp.Id -All
)

$missingPermissions = @()
foreach ($permissionName in $requiredPermissions) {
    $matchingRoles = @(
        $graphSp.AppRoles | Where-Object {
            $_.Value -eq $permissionName -and
            $_.IsEnabled -and
            $_.AllowedMemberTypes -contains 'Application'
        }
    )
    if ($matchingRoles.Count -ne 1) {
        throw "Expected one enabled application role named '$permissionName' but found $($matchingRoles.Count) in the active Microsoft Graph environment."
    }

    $assignment = $assignments | Where-Object {
        $_.ResourceId -eq $graphSp.Id -and $_.AppRoleId -eq $matchingRoles[0].Id
    }
    if ($assignment) {
        Write-Host "[OK] $permissionName" -ForegroundColor Green
    }
    else {
        Write-Host "[MISSING] $permissionName" -ForegroundColor Red
        $missingPermissions += $permissionName
    }
}

if ($missingPermissions.Count -gt 0) {
    throw "The managed identity is missing required permissions: $($missingPermissions -join ', ')."
}

Write-Host 'All required Entra Kerberos automation permissions are present.' -ForegroundColor Cyan
