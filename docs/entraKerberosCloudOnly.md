[**Home**](../README.md) | [**Design**](design.md) | [**Features**](features.md) | [**Get Started**](quickStart.md)

# Entra Kerberos for Azure Files (Cloud-Only Identities) [Preview]

## Overview

This solution supports using **Entra Kerberos** for authentication to Azure Files for cloud-only identities. This allows you to use FSLogix with Azure Files without requiring an on-premises Active Directory or Entra Domain Services.

The session hosts are Entra ID joined, and users are cloud-only identities in Entra ID.

## Prerequisites

1.  **Identity Solution**: `identitySolution` must be set to `'EntraKerberos-CloudOnly'`.
2.  **Session Hosts**: Must be Entra ID joined.
3.  **Client Devices**: Windows 10/11 Enterprise/Pro multi-session or Windows Server 2022.

### User Assigned Managed Identity (Optional)

Providing a **User Assigned Managed Identity** is **optional** but recommended. It allows the solution to fully automate the configuration of the Storage Account for Entra Kerberos, specifically the App Registration updates required for Private Link, tag for including Entra groups in security identifiers, and API permissions.

The solution uses a User Assigned Managed Identity to perform the following actions against Microsoft Graph:
1.  **Update App Registration**: Adds the required tag `kdc_enable_cloud_group_sids` and `identifierUris` for Private Link (e.g., `api://<storageAccountName>.file.core.windows.net`).
2.  **Configure API Permissions**: Adds `User.Read`, `openid`, and `profile` permissions to the App Registration.
3.  **Grant Admin Consent**: Grants admin consent for the added permissions so that the storage account can accept Kerberos tickets.

#### Required Permissions

The User Assigned Managed Identity requires the following **Application** permissions (not Delegated) in Microsoft Graph:

| Permission | Type | Reason |
| :--- | :--- | :--- |
| `Application.ReadWrite.All` | Application | Required to search for and update the App Registration created by the Storage Account, including adding `identifierUris` and `requiredResourceAccess`. |
| `DelegatedPermissionGrant.ReadWrite.All` | Application | Required to grant Admin Consent (`oauth2PermissionGrants`) for the API permissions. |

#### Creating the Identity and Assigning Permissions

You can use the following PowerShell script to create the User Assigned Managed Identity and assign the required Graph permissions.

> [!IMPORTANT]
> You must run this script as a user with **Global Administrator** or **Privileged Role Administrator** rights in the tenant to grant the Graph permissions.

```powershell
# Parameters
$SubscriptionId = "<Your Subscription ID>"
$ResourceGroupName = "<Your Resource Group Name>"
$IdentityName = "id-avd-storage-automation"
$Location = "<Region>"

# Connect to Azure
Connect-AzAccount
Set-AzContext -SubscriptionId $SubscriptionId

# 1. Create the User Assigned Managed Identity
$identity = Get-AzUserAssignedIdentity -ResourceGroupName $ResourceGroupName -Name $IdentityName -ErrorAction SilentlyContinue
if (-not $identity) {
    New-AzUserAssignedIdentity -ResourceGroupName $ResourceGroupName -Name $IdentityName -Location $Location
    $identity = Get-AzUserAssignedIdentity -ResourceGroupName $ResourceGroupName -Name $IdentityName
}
Write-Host "Identity Created: $($identity.Name)"

# 2. Assign Graph Permissions
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All", "Application.Read.All"

$sp = Get-MgServicePrincipal -Filter "AppId eq '$($identity.ClientId)'"
$graphSPN = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

# List of required permissions
$permissions = @(
    "Application.ReadWrite.All",
    "DelegatedPermissionGrant.ReadWrite.All"
)

foreach ($permName in $permissions) {
    $appRole = $graphSPN.AppRoles | Where-Object { $_.Value -eq $permName -and $_.AllowedMemberTypes -contains "Application" }
    
    if ($appRole) {
        try {
            New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $sp.Id -ResourceId $graphSPN.Id -AppRoleId $appRole.Id
            Write-Host "Assigned $permName" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to assign $permName (it might already exist): $($_.Exception.Message)"
        }
    } else {
        Write-Error "Permission $permName not found in Graph Service Principal."
    }
}
```

## What the Solution Does

The solution always performs the following actions when **Entra ID (Cloud-Only)** is selected:

1.  **Storage Account Creation**: Creates the Azure Storage Account.
2.  **Identity Configuration**: Enables Entra Kerberos authentication on the storage account.
3.  **RBAC Assignments**: Assigns the `Storage File Data SMB Share Contributor` role to the specified FSLogix user groups.

### With User Assigned Managed Identity (Recommended)

If you provide the Resource ID of the Managed Identity with the required permissions:

1.  **App Registration Automation**: The solution automatically updates the App Registration associated with the Storage Account:
    *   Adds Private Link URIs (e.g., `api://<storageAccountName>.privatelink.file.core.windows.net`) to `identifierUris`.
    *   Adds `User.Read`, `openid`, and `profile` to `requiredResourceAccess`.
    *   Grants Admin Consent for these permissions.
    *   **Cloud Group Support**: Updates the application tags to include `kdc_enable_cloud_group_sids`, enabling support for Entra groups (mandatory for cloud-only identities).
2.  **Least Privilege NTFS Permissions**: Configures NTFS permissions on the file shares by assigning only the specified FSLogix group(s), restricting access to authorized users only.

### Without User Assigned Managed Identity

If you do **not** provide the Managed Identity:

1.  **Default Permissions**: The storage account is configured with default permissions that allow **Authenticated Users** to create their user profile folders.
2.  **Manual Configuration Required**: You must manually perform the following steps after deployment:
    *   **Grant Admin Consent**: Go to the App Registration in Entra ID and grant admin consent for the API permissions.
    *   **Update Manifest**: If using Private Link, manually update the App Registration manifest to include the private link URIs.
    *   **Enable Cloud Groups**: Manually update the App Registration manifest to include `"tags": [ "kdc_enable_cloud_group_sids" ]`.
