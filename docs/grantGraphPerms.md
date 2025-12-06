# Grant Rights

``` powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All", "Directory.ReadWrite.All", "AppRoleAssignment.ReadWrite.All"

$managedIdentity = Get-MgServicePrincipal -ServicePrincipalId '0ac8e7b2-7bcd-4b53-9254-90dece8072a8'

$graphSPN = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

$permission = "Application.ReadUpdate.All"

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
