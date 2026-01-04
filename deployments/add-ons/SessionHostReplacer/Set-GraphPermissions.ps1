# Verify and grant Graph API permissions to SessionHostReplacer managed identity
# Run this script with Global Administrator or Privileged Role Administrator rights

param(
    [Parameter(Mandatory = $true)]
    [string]$ManagedIdentityObjectId,
    
    [Parameter(Mandatory = $false)]
    [string]$ManagedIdentityClientId,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('Global', 'USGov', 'China', 'USGovDoD', 'USSecret', 'USTopSecret')]
    [string]$Environment = 'Global'
)

# Map environment to Graph endpoint
$graphEndpoints = @{
    'Global'       = 'https://graph.microsoft.com'
    'USGov'        = 'https://graph.microsoft.us'
    'China'        = 'https://microsoftgraph.chinacloudapi.cn'
    'USGovDoD'     = 'https://dod-graph.microsoft.us'
    'USSecret'     = 'https://<graphEndpoint>' #(Fill this in from the value obtained at https://review.learn.microsoft.com/en-us/microsoft-government-secret/azure/azure-government-secret/overview/azure-government-secret-differences-from-global-azure?branch=live)
    'USTopSecret'  = 'https://<graphEndpoint>' #(Fill this in from the value obtained at https://review.learn.microsoft.com/en-us/microsoft-government-topsecret/azure/azure-government-top-secret/overview/azure-government-top-secret-differences-from-global-azure?branch=live)
}

$graphEndpoint = $graphEndpoints[$Environment]

Write-Host "Verifying Graph API permissions for managed identity..." -ForegroundColor Cyan
Write-Host "Environment: $Environment" -ForegroundColor Gray
Write-Host "Graph Endpoint: $graphEndpoint" -ForegroundColor Gray

# Connect to Microsoft Graph
try {
    Write-Host "`nConnecting to Microsoft Graph..." -ForegroundColor Yellow
    # RoleManagement.ReadWrite.Directory is required to assign directory roles
    Connect-MgGraph -Scopes "Application.Read.All", "AppRoleAssignment.ReadWrite.All", "RoleManagement.ReadWrite.Directory" -Environment $Environment -ErrorAction Stop
    Write-Host "Connected successfully" -ForegroundColor Green
    Write-Host "Note: You need Privileged Role Administrator or Global Administrator rights to assign directory roles" -ForegroundColor Gray
}
catch {
    Write-Error "Failed to connect to Microsoft Graph: $_"
    Write-Host "Please ensure you have the Microsoft.Graph PowerShell module installed:" -ForegroundColor Red
    Write-Host "  Install-Module Microsoft.Graph -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

try {
    # Get the managed identity service principal
    Write-Host "`nRetrieving managed identity details..." -ForegroundColor Yellow
    $managedIdentitySp = Get-MgServicePrincipal -ServicePrincipalId $ManagedIdentityObjectId -ErrorAction Stop
    
    Write-Host "Found managed identity:" -ForegroundColor Green
    Write-Host "  Display Name: $($managedIdentitySp.DisplayName)" -ForegroundColor White
    Write-Host "  Object ID: $($managedIdentitySp.Id)" -ForegroundColor White
    Write-Host "  App ID: $($managedIdentitySp.AppId)" -ForegroundColor White
    
    if ($ManagedIdentityClientId -and $managedIdentitySp.AppId -ne $ManagedIdentityClientId) {
        Write-Warning "WARNING: The managed identity App ID ($($managedIdentitySp.AppId)) does not match the provided Client ID ($ManagedIdentityClientId)"
        Write-Warning "Make sure you're using the correct managed identity!"
    }
    
    # Get Microsoft Graph service principal
    Write-Host "`nRetrieving Microsoft Graph service principal..." -ForegroundColor Yellow
    $graphSp = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Graph'" -ErrorAction Stop
    
    if (-not $graphSp) {
        throw "Could not find Microsoft Graph service principal"
    }
    
    Write-Host "Found Microsoft Graph service principal: $($graphSp.Id)" -ForegroundColor Green
    
    # Remove all existing Graph API permissions first to start clean
    Write-Host "`nRemoving all existing Graph API permissions..." -ForegroundColor Yellow
    $currentAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentitySp.Id -ErrorAction Stop
    $graphAssignments = $currentAssignments | Where-Object { $_.ResourceId -eq $graphSp.Id }
    
    if ($graphAssignments.Count -gt 0) {
        Write-Host "Found $($graphAssignments.Count) existing Graph permission(s) to remove:" -ForegroundColor Gray
        foreach ($assignment in $graphAssignments) {
            $roleName = ($graphSp.AppRoles | Where-Object { $_.Id -eq $assignment.AppRoleId }).Value
            Write-Host "  Removing: $roleName" -ForegroundColor Gray
            try {
                Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentitySp.Id -AppRoleAssignmentId $assignment.Id -ErrorAction Stop
                Write-Host "  ✓ Removed $roleName" -ForegroundColor Green
            }
            catch {
                Write-Warning "  ✗ Failed to remove $roleName : $_"
            }
        }
        Write-Host "`nWaiting 5 seconds for permissions to clear..." -ForegroundColor Gray
        Start-Sleep -Seconds 5
    }
    else {
        Write-Host "No existing Graph API permissions found" -ForegroundColor Gray
    }
    
    # Define required Graph API permissions
    # For Graph API calls by service principals, app permissions are required (no directory role assignments needed)
    $requiredPermissions = @(
        @{ Name = "Device.ReadWrite.All"; Id = "1138cb37-bd11-4084-a2b7-9f71582aeddb" }
        @{ Name = "DeviceManagementManagedDevices.ReadWrite.All"; Id = "243333ab-4d21-40cb-a475-36241daa0842" }
    )
    
    # Grant required permissions
    Write-Host "`nGranting required Graph API permissions..." -ForegroundColor Yellow
    
    foreach ($perm in $requiredPermissions) {
        try {
            $params = @{
                ServicePrincipalId = $managedIdentitySp.Id
                Body               = @{
                    principalId = $managedIdentitySp.Id
                    resourceId  = $graphSp.Id
                    appRoleId   = $perm.Id
                }
            }
            
            New-MgServicePrincipalAppRoleAssignment @params -ErrorAction Stop | Out-Null
            Write-Host "  ✓ Granted $($perm.Name)" -ForegroundColor Green
        }
        catch {
            Write-Error "  ✗ Failed to grant $($perm.Name): $_"
        }
    }
   
    Write-Host "`nPermissions have been updated. Wait 5-10 minutes for changes to propagate." -ForegroundColor Cyan
    Write-Host "Then restart your Function App to clear any cached tokens." -ForegroundColor Cyan

    # Summary
    Write-Host "`n=== Configuration Summary ===" -ForegroundColor Cyan
    Write-Host "Managed Identity: $($managedIdentitySp.DisplayName)" -ForegroundColor White
    Write-Host "`nGranted Graph API Permissions:" -ForegroundColor Yellow
    Write-Host "  ✓ Device.ReadWrite.All - Required for Entra ID device deletion" -ForegroundColor White
    Write-Host "  ✓ DeviceManagementManagedDevices.ReadWrite.All - Required for Intune device deletion" -ForegroundColor White
    Write-Host "`nNote: No directory role assignments are required (Cloud Device Administrator is NOT needed)" -ForegroundColor Gray
    
    Write-Host "`nNext steps:" -ForegroundColor Cyan
    Write-Host "  1. Wait 5-10 minutes for changes to propagate" -ForegroundColor White
    Write-Host "  2. Restart your Function App to clear cached tokens" -ForegroundColor White
    Write-Host "  3. Test device deletion functionality" -ForegroundColor White
    
    # Show token validation info
    Write-Host "`n=== Token Validation Info ===" -ForegroundColor Cyan
    Write-Host "When checking Function logs, verify the token 'appid' matches: $($managedIdentitySp.AppId)" -ForegroundColor White
    Write-Host "Expected token audience: $graphEndpoint" -ForegroundColor White
    Write-Host "`nEnsure your Function App has the GraphEndpoint setting:" -ForegroundColor Yellow
    Write-Host "  GraphEndpoint = $graphEndpoint" -ForegroundColor White
}
catch {
    Write-Error "An error occurred: $_"
    exit 1
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}