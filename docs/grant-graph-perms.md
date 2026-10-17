[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Grant Graph API Permissions to Managed Identity

## For SessionHostReplacer

First connect to the correct Microsoft Graph environment with these delegated scopes:

- `Application.Read.All`
- `AppRoleAssignment.ReadWrite.All`

For Azure Government Secret and Azure Government Top Secret, follow the Microsoft Graph connection
instructions available inside the environment or from the environment support team. Do not use the
public cloud labels as restricted Graph environment names. This repository intentionally does not
publish or infer restricted environment names or endpoints.

Verify the active context:

```powershell
Get-MgContext |
    Select-Object Account, TenantId, Environment, Scopes
```

Then use the provided script:

```powershell
.\deployments\add-ons\sessionHostReplacer\Set-GraphPermissions.ps1 `
    -ManagedIdentityObjectId <object-id> `
    -DeviceCleanupTarget Entra
```

The script uses the existing Graph context. It does not connect, select an environment, or
disconnect. Select only the cleanup targets enabled in the deployment:

- `-DeviceCleanupTarget Entra` grants `Device.ReadWrite.All`.
- `-DeviceCleanupTarget Intune` grants `DeviceManagementManagedDevices.ReadWrite.All`.
- `-DeviceCleanupTarget Entra, Intune` grants both.

Intune is not currently available in Azure Government Secret or Azure Government Top Secret. Use
`-DeviceCleanupTarget Entra` only in those environments unless your environment support team
confirms Intune availability. The helper does not look up or grant the Intune permission unless
`Intune` is explicitly selected.

## Manual Grant (if needed)

``` powershell
# Connect to the correct Graph environment before running this code.
if (-not (Get-MgContext)) {
    throw 'Connect to the correct Microsoft Graph environment before continuing.'
}

$managedIdentity = Get-MgServicePrincipal -ServicePrincipalId '<managed-identity-object-id>'

$graphSPN = Get-MgServicePrincipal `
    -Filter "appId eq '00000003-0000-0000-c000-000000000000'" `
    -Property 'id,appRoles'

# Add DeviceManagementManagedDevices.ReadWrite.All only where Intune is available and Intune
# cleanup is enabled.
$permissions = @('Device.ReadWrite.All')
foreach ($permission in $permissions) {
    $appRole = $graphSPN.AppRoles |
        Where-Object {
            $_.Value -eq $permission -and
            $_.IsEnabled -and
            $_.AllowedMemberTypes -contains 'Application'
        }

    $bodyParam = @{
        PrincipalId = $managedIdentity.Id
        ResourceId  = $graphSPN.Id
        AppRoleId   = $appRole.Id
    }

    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $managedIdentity.Id `
        -BodyParameter $bodyParam
}
```

## For Entra Kerberos Azure Files Automation

The application-update managed identity used by standard host pools, automated host pools, and the
FSLogix Storage add-on requires:

- `Application.ReadWrite.All`
- `DelegatedPermissionGrant.ReadWrite.All`

Connect to the correct Microsoft Graph environment with `Application.Read.All` and
`AppRoleAssignment.ReadWrite.All`, verify `Get-MgContext`, and then run:

```powershell
.\tools\Set-EntraKerberosManagedIdentityPermissions.ps1 `
    -ManagedIdentityObjectId <object-id> `
    -ManagedIdentityClientId <client-id>

.\tools\Test-EntraKerberosManagedIdentityPermissions.ps1 `
    -ManagedIdentityObjectId <object-id>
```

Both tools use the existing Graph context, discover application roles from that environment, and
do not select or disconnect the environment.

## Other Operator-Run Graph Tools

These tools also require an existing Microsoft Graph context:

- `tools/Enable-AVDSSO.ps1` requires delegated `Application.ReadWrite.All`. Pass one or more
  objects containing `id` and `displayName` for the target device groups.
- `tools/Enable-RDPAADAuth.ps1` is a single-group compatibility wrapper for
  `tools/Enable-AVDSSO.ps1` and uses the same active context and permission.
- `tools/Remove-IntuneDevicesByPrefix.ps1` requires delegated
  `DeviceManagementManagedDevices.ReadWrite.All`. Do not use it in Azure Government Secret or
  Azure Government Top Secret because Intune is not currently available there.

Example AVD SSO invocation after connecting to the correct Graph environment:

```powershell
$deviceGroups = @(
    @{
        id = '<device-group-object-id>'
        displayName = '<device-group-display-name>'
    }
)

.\tools\Enable-AVDSSO.ps1 -DeviceGroups $deviceGroups
```

Before using an operator tool in a restricted environment, verify that the corresponding Microsoft
Graph API and service are available there. The tools do not fall back to a public endpoint.
