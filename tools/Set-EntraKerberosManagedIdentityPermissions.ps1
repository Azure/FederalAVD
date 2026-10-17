# Verify and grant Microsoft Graph application permissions used by Entra Kerberos automation.
# Connect to the correct Microsoft Graph environment before running this script.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagedIdentityObjectId,

    [Parameter(Mandatory = $false)]
    [string]$ManagedIdentityClientId
)

$ErrorActionPreference = 'Stop'
$requiredScopes = @(
    'Application.Read.All'
    'AppRoleAssignment.ReadWrite.All'
)
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
    throw 'No Microsoft Graph context is active. Follow the connection instructions for your environment, run Connect-MgGraph with Application.Read.All and AppRoleAssignment.ReadWrite.All, verify Get-MgContext, and then rerun this script.'
}

$missingScopes = @(
    $requiredScopes | Where-Object {
        $scope = $_
        -not ($graphContext.Scopes | Where-Object { $_ -ieq $scope })
    }
)
if ($missingScopes.Count -gt 0) {
    throw "The active Microsoft Graph context is missing required delegated scopes: $($missingScopes -join ', '). Reconnect to the same environment with all required scopes and retry."
}

Write-Host 'Using the active Microsoft Graph context:' -ForegroundColor Cyan
Write-Host "  Account: $($graphContext.Account)" -ForegroundColor White
Write-Host "  Tenant ID: $($graphContext.TenantId)" -ForegroundColor White
Write-Host "  Environment: $($graphContext.Environment)" -ForegroundColor White
Write-Host 'The script will not change or disconnect this context.' -ForegroundColor Gray

try {
    $managedIdentitySp = Get-MgServicePrincipal -ServicePrincipalId $ManagedIdentityObjectId
    if ($ManagedIdentityClientId -and $managedIdentitySp.AppId -ne $ManagedIdentityClientId) {
        throw "The managed identity App ID '$($managedIdentitySp.AppId)' does not match the supplied client ID '$ManagedIdentityClientId'."
    }

    $graphServicePrincipals = @(
        Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'" -Property 'id,appId,displayName,appRoles'
    )
    if ($graphServicePrincipals.Count -ne 1) {
        throw "Expected one Microsoft Graph service principal but found $($graphServicePrincipals.Count). Verify that the active Graph context targets the intended tenant and environment."
    }
    $graphSp = $graphServicePrincipals[0]

    $permissionRoles = @{}
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
        $permissionRoles[$permissionName] = $matchingRoles[0]
    }

    $currentAssignments = @(
        Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentitySp.Id -All
    )

    Write-Host "`nEnsuring required Microsoft Graph application permissions..." -ForegroundColor Yellow
    foreach ($permissionName in $requiredPermissions) {
        $appRole = $permissionRoles[$permissionName]
        $existingAssignment = $currentAssignments | Where-Object {
            $_.ResourceId -eq $graphSp.Id -and $_.AppRoleId -eq $appRole.Id
        }

        if ($existingAssignment) {
            Write-Host "  [OK] $permissionName is already granted" -ForegroundColor Green
            continue
        }

        $bodyParameter = @{
            principalId = $managedIdentitySp.Id
            resourceId  = $graphSp.Id
            appRoleId   = $appRole.Id
        }
        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $managedIdentitySp.Id `
            -BodyParameter $bodyParameter | Out-Null
        Write-Host "  [OK] Granted $permissionName" -ForegroundColor Green
    }

    $verifiedAssignments = @(
        Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentitySp.Id -All
    )
    $missingPermissions = @(
        $requiredPermissions | Where-Object {
            $appRole = $permissionRoles[$_]
            -not ($verifiedAssignments | Where-Object {
                    $_.ResourceId -eq $graphSp.Id -and $_.AppRoleId -eq $appRole.Id
                })
        }
    )
    if ($missingPermissions.Count -gt 0) {
        throw "Permission verification failed for: $($missingPermissions -join ', ')."
    }

    Write-Host "`nRequired Entra Kerberos automation permissions are present." -ForegroundColor Cyan
    Write-Host 'No unrelated Microsoft Graph permissions were removed.' -ForegroundColor Gray
}
catch {
    throw "Failed to configure Entra Kerberos Microsoft Graph permissions. $($_.Exception.Message)"
}
