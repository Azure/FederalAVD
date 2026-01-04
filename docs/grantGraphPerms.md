# Grant Graph API Permissions to Managed Identity

## For SessionHostReplacer

Use the provided script:
```powershell
.\Set-GraphPermissions.ps1 -ManagedIdentityObjectId <object-id>
```

This script grants the required permissions:
- `Device.ReadWrite.All` - For Entra ID device deletion
- `DeviceManagementManagedDevices.ReadWrite.All` - For Intune device deletion

## Manual Grant (if needed)

``` powershell
Connect-MgGraph -Scopes "Application.Read.All", "AppRoleAssignment.ReadWrite.All"

$managedIdentity = Get-MgServicePrincipal -ServicePrincipalId '<managed-identity-object-id>'

$graphSPN = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

# Grant Device.ReadWrite.All
$permission = "Device.ReadWrite.All"

$appRole = $graphSPN.AppRoles |
    Where-Object Value -eq $permission |
    Where-Object AllowedMemberTypes -contains "Application"

$bodyParam = @{
    PrincipalId = $managedIdentity.Id
    ResourceId  = $graphSPN.Id
    AppRoleId   = $appRole.Id
}

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentity.Id -BodyParameter $bodyParam

# Grant DeviceManagementManagedDevices.ReadWrite.All
$permission = "DeviceManagementManagedDevices.ReadWrite.All"

$appRole = $graphSPN.AppRoles |
    Where-Object Value -eq $permission |
    Where-Object AllowedMemberTypes -contains "Application"

$bodyParam = @{
    PrincipalId = $managedIdentity.Id
    ResourceId  = $graphSPN.Id
    AppRoleId   = $appRole.Id
}

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentity.Id -BodyParameter $bodyParam
```
