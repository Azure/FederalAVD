[**Home**](../README.md) | [**Design**](design.md) | [**Get Started**](quickStart.md) | [**Limitations**](limitations.md) | [**Troubleshooting**](troubleshooting.md) | [**Parameters**](parameters.md) | [**Zero Trust Framework**](zeroTrustFramework.md)

# Entra Kerberos for Azure Files (Hybrid)

## Overview

This solution supports **Entra Kerberos** for Azure Files, allowing you to use Azure Active Directory (Entra ID) Kerberos to authenticate hybrid user identities for Azure Files access. This eliminates the need for line-of-sight to on-premises Domain Controllers for the storage account itself.

The session hosts are joined to Entra ID, and user identities are synchronized from the on-premises domain to Entra ID.

> [!IMPORTANT]
> If you wish to configure least privilege NTFS permissions or shard storage, the session host subnet (to which the deployment VM is attached) must have line-of-sight to a Domain Controller. Additionally, domain join credentials must be provided in order to configure the required NTFS permissions using the user assigned managed identity.

## Prerequisites

1.  **Identity Solution**: `identitySolution` must be set to `'EntraKerberos-Hybrid'`.
2.  **Session Hosts**: Must be Entra ID joined.
3.  **Client Devices**: Windows 10/11 Enterprise/Pro multi-session or Windows Server 2022.

### User Assigned Managed Identity (Optional)

Providing a **User Assigned Managed Identity** is **optional** but recommended. It allows the solution to fully automate the configuration of the Storage Account for Entra Kerberos, specifically the App Registration updates required for Private Link and API permissions, and to configure least privilege NTFS permissions.

The solution uses a User Assigned Managed Identity to perform the following actions against Microsoft Graph:

1. **Update App Registration**: Adds the required `identifierUris` for Private Link (e.g., `api://<storageAccountName>.file.core.windows.net`).
2. **Configure API Permissions**: Adds `User.Read`, `openid`, and `profile` permissions to the App Registration.
3. **Grant Admin Consent**: Grants admin consent for the added permissions so that the storage account can accept Kerberos tickets.

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

The solution always performs the following actions when **Entra Kerberos (Hybrid)** is selected:

1. **Storage Account Creation**: Creates the Azure Storage Account.
2. **Identity Configuration**: Enables Entra Kerberos authentication on the storage account.
3. **Session Host Configuration**: Automatically configures the session hosts to retrieve the Kerberos token from the cloud.

### With User Assigned Managed Identity (Recommended)

If you provide the Resource ID of the Managed Identity with the required permissions:

1. **Domain Name and Guid**: Added to the identity configuration for Entra Kerberos.
2. **App Registration Automation**: The solution automatically updates the App Registration associated with the Storage Account:
    * Adds Private Link URIs (e.g., `api://<storageAccountName>.privatelink.file.core.windows.net`) to `identifierUris`.
    * Adds `User.Read`, `openid`, and `profile` to `requiredResourceAccess`.
    * Grants Admin Consent for these permissions.
3. **Least Privilege NTFS Permissions**: Configures NTFS permissions on the file shares by assigning only the specified FSLogix group(s), restricting access to authorized users only.

### Without User Assigned Managed Identity

If you do **not** provide the Managed Identity:

1. **Default Permissions**: The storage account is configured with default permissions that allow **Authenticated Users** to create their user profile folders.
2. **Manual Configuration Required**: You must manually perform the following steps after deployment:
    * **Grant Admin Consent**:
        1. Navigate to **App registrations** in the Azure Portal.
        2. Select **All applications** and search for the storage account name.
        3. Select **API permissions** and click **Grant admin consent for [Tenant Name]**.
        4. See [Enable Azure Active Directory Kerberos authentication for hybrid identities on Azure Files](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable?tabs=azure-portal%2Cintune#grant-admin-consent-to-the-new-service-principal) for details.
    * **Update Manifest (Private Link)**:
        1. Navigate to **App registrations** and select the storage account application.
        2. Select **Manifest**.
        3. Locate the `identifierUris` array and add the private link URIs (e.g., `api://<storageAccountName>.privatelink.file.core.windows.net`).
        4. Save the changes.
    * **Configure NTFS Permissions**:
        1. Since the automated identity was not used, you must manually configure NTFS permissions if the default authenticated users access is insufficient.
        2. See [Configure directory and file-level permissions over SMB](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-identity-configure-file-level-permissions) for details.

## Post Deployment Manual Steps

Regardless of whether you use the Managed Identity or not, the following step is required:

* **MFA Exclusion**: The storage account application(s) must be excluded from Conditional Access policies requiring MFA.
    1. Navigate to **Entra ID > Security > Conditional Access**.
    2. Identify policies that enforce MFA for all cloud apps or specific apps.
    3. Exclude the storage account application (Service Principal) created by the deployment.
    4. See [Configure Azure AD Kerberos authentication for hybrid identities](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable?tabs=azure-portal%2Cintune#disable-multifactor-authentication-on-the-storage-account) for details.

## What is NOT Done

* **Domain Join**: The Storage Account itself is **not** joined to the on-premises domain. This is the key difference from the ADDS method.
