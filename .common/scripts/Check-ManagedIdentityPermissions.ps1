[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$ManagedIdentityName
)

# Connect to Azure if not already connected
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) {
        throw "Not connected"
    }
    Write-Host "✓ Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
    Write-Host "  Tenant: $($context.Tenant.Id)" -ForegroundColor Gray
    Write-Host ""
}
catch {
    Write-Host "Not connected to Azure. Connecting..." -ForegroundColor Yellow
    Connect-AzAccount
    Write-Host ""
}

# Get the managed identity service principal
Write-Host "Looking for Managed Identity: $ManagedIdentityName" -ForegroundColor Cyan
$managedIdentitySP = Get-AzADServicePrincipal -DisplayName $ManagedIdentityName

if (-not $managedIdentitySP) {
    Write-Error "Managed Identity '$ManagedIdentityName' not found."
    exit 1
}

Write-Host "✓ Found Managed Identity" -ForegroundColor Green
Write-Host "  Display Name: $($managedIdentitySP.DisplayName)" -ForegroundColor Gray
Write-Host "  Object ID: $($managedIdentitySP.Id)" -ForegroundColor Gray
Write-Host "  App ID: $($managedIdentitySP.AppId)" -ForegroundColor Gray
Write-Host ""

# Get Microsoft Graph service principal
Write-Host "Getting Microsoft Graph Service Principal..." -ForegroundColor Cyan
$graphSP = Get-AzADServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

if (-not $graphSP) {
    Write-Error "Microsoft Graph Service Principal not found."
    exit 1
}

Write-Host "✓ Found Microsoft Graph SP (ID: $($graphSP.Id))" -ForegroundColor Green
Write-Host ""

# Microsoft Graph App Roles (Application Permissions) - Common ones
$graphAppRoles = @{
    "1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9" = "Application.ReadWrite.All"
    "8e8e4742-1d95-4f68-9d56-6ee75648c72a" = "DelegatedPermissionGrant.ReadWrite.All"
    "06b708a9-e830-4db3-a914-8e69da51d44f" = "AppRoleAssignment.ReadWrite.All"
    "9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30" = "Application.Read.All"
    "19dbc75e-c2e2-444c-a770-ec69d8559fc7" = "Directory.ReadWrite.All"
    "62a82d76-70ea-41e2-9197-370581804d09" = "Directory.Read.All"
    "df021288-bdef-4463-88db-98f22de89214" = "User.Read.All"
    "741f803b-c850-494e-b5df-cde7c675a1ca" = "User.ReadWrite.All"
}

# Get app role assignments for the managed identity
Write-Host "Checking assigned permissions (App Role Assignments)..." -ForegroundColor Cyan
$appRoleAssignments = Get-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentitySP.Id

# Filter for Microsoft Graph permissions
$graphPermissions = $appRoleAssignments | Where-Object { $_.ResourceId -eq $graphSP.Id }

if ($graphPermissions.Count -eq 0) {
    Write-Host "⚠ No Microsoft Graph permissions assigned to this Managed Identity" -ForegroundColor Yellow
    Write-Host ""
}
else {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "MICROSOFT GRAPH PERMISSIONS (Application Permissions)" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""
    
    foreach ($permission in $graphPermissions) {
        $appRoleId = $permission.AppRoleId
        $permissionName = if ($graphAppRoles.ContainsKey($appRoleId)) {
            $graphAppRoles[$appRoleId]
        } else {
            # Try to look up from Graph SP app roles
            $appRole = $graphSP.AppRole | Where-Object { $_.Id -eq $appRoleId }
            if ($appRole) {
                $appRole.Value
            } else {
                "Unknown Permission"
            }
        }
        
        Write-Host "✓ $permissionName" -ForegroundColor Green
        Write-Host "  App Role ID: $appRoleId" -ForegroundColor Gray
        Write-Host "  Admin Consent: Required (Application Permission)" -ForegroundColor Gray
        Write-Host "  Status: Granted" -ForegroundColor Gray
        Write-Host ""
    }
}

# Check for required permissions
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "VERIFICATION: Required Permissions for Storage Account Script" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""

$requiredPermissions = @{
    "Application.ReadWrite.All" = "1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9"
    "DelegatedPermissionGrant.ReadWrite.All" = "8e8e4742-1d95-4f68-9d56-6ee75648c72a"
}

$allRequiredPresent = $true

foreach ($permName in $requiredPermissions.Keys) {
    $roleId = $requiredPermissions[$permName]
    $hasPermission = $graphPermissions | Where-Object { $_.AppRoleId -eq $roleId }
    
    if ($hasPermission) {
        Write-Host "✓ $permName" -ForegroundColor Green
    }
    else {
        Write-Host "✗ $permName (MISSING)" -ForegroundColor Red
        $allRequiredPresent = $false
    }
}

Write-Host ""

if ($allRequiredPresent) {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    Write-Host "✓ All required permissions are assigned!" -ForegroundColor Green
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    Write-Host ""
    Write-Host "If the Storage Account script is still failing with 403 Forbidden:" -ForegroundColor Yellow
    Write-Host "  1. Restart the VM to get a fresh token with the new permissions" -ForegroundColor Yellow
    Write-Host "  2. Wait 5-10 minutes for permission propagation" -ForegroundColor Yellow
}
else {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
    Write-Host "✗ Missing required permissions!" -ForegroundColor Red
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
    Write-Host ""
    Write-Host "To grant missing permissions, run:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host '$managedIdentitySP = Get-AzADServicePrincipal -DisplayName "' + $ManagedIdentityName + '"' -ForegroundColor Cyan
    Write-Host '$graphSP = Get-AzADServicePrincipal -Filter "appId eq ''00000003-0000-0000-c000-000000000000''"' -ForegroundColor Cyan
    Write-Host ""
    
    foreach ($permName in $requiredPermissions.Keys) {
        $roleId = $requiredPermissions[$permName]
        $hasPermission = $graphPermissions | Where-Object { $_.AppRoleId -eq $roleId }
        
        if (-not $hasPermission) {
            Write-Host "# Grant $permName" -ForegroundColor Gray
            Write-Host "New-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId `$managedIdentitySP.Id -ResourceId `$graphSP.Id -AppRoleId `"$roleId`"" -ForegroundColor Cyan
            Write-Host ""
        }
    }
}
