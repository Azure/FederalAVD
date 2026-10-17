# Configure Local Service Account

Creates or updates a Windows local service account for security scanners, monitoring tools, or
other services. The password is read from Azure Key Vault at runtime by using a user-assigned
managed identity. The password is not stored in the artifact or passed as a deployment argument.

> Use this as a **session-host customization**, not an image-build customization. Creating the
> account during image creation would bake the account and password into the shared image.

## Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `AccountName` | Yes | Local service account name |
| `KeyVaultUri` | Yes | Vault URI copied from the Azure portal, such as `https://kv-security.vault.azure.net/` |
| `SecretName` | Yes | Name of the Key Vault secret containing the account password |
| `UserAssignedIdentityClientId` | Yes | Client ID of the UAMI attached to the session host VM |
| `LocalGroups` | No | Local groups to add, such as `Administrators` |
| `Description` | No | Account description; default is `Managed local service account` |

The account and password are configured not to expire, and the account cannot change its own
password. Rerunning the artifact updates the account to the current Key Vault secret and ensures the
requested group memberships exist. Existing group memberships are not removed.

## Prerequisites

1. Create a Key Vault secret containing the service account password.
2. Attach the Key Vault access UAMI to each session host VM.
3. Grant that UAMI `Key Vault Secrets User` on the vault or secret, and pass its client ID to
  `UserAssignedIdentityClientId`.
4. Configure an artifact download UAMI with `Storage Blob Data Reader` on the artifact storage and
  supply its resource ID as `artifactsUserAssignedIdentityResourceId`.
5. Ensure the session hosts can resolve and reach the Key Vault endpoint.

The Key Vault access UAMI and artifact download UAMI can be different identities. When they are
different, both must be attached to the session host VM. This script uses only the Key Vault UAMI
client ID supplied through `UserAssignedIdentityClientId`.

The same secret can be used on every system. Use a strong password and rotate it by updating the
secret and rerunning this artifact on the session hosts.

## Add the artifact

Copy the example into the customer-owned folder:

```powershell
Copy-Item `
    -Path '.\customer-examples\artifacts\Configure-LocalServiceAccount' `
    -Destination '.\customer\artifacts\Configure-LocalServiceAccount' `
    -Recurse
```

Package and upload customer artifacts with `Update-ImageArtifacts.ps1`. No download manifest entry
is needed because this artifact contains no external files.

## Host pool example

The Key Vault URI is available on the vault's Azure portal Overview page. In this example,
`artifactsUserAssignedIdentityResourceId` identifies the UAMI that downloads the artifact from
storage. `UserAssignedIdentityClientId` identifies the UAMI that this script uses to read the Key
Vault secret. They do not have to identify the same UAMI.

```json
{
  "artifactsContainerUri": {
    "value": "https://<storage-account>.blob.core.windows.net/artifacts"
  },
  "artifactsUserAssignedIdentityResourceId": {
    "value": "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<artifact-download-identity>"
  },
  "sessionHostCustomizations": {
    "value": [
      {
        "name": "Configure-LocalServiceAccount",
        "blobNameOrUri": "Configure-LocalServiceAccount.zip",
        "arguments": "-AccountName svc-scanner -KeyVaultUri https://kv-security.vault.azure.net/ -SecretName scanner-password -UserAssignedIdentityClientId <key-vault-access-uami-client-id> -LocalGroups @('Administrators')",
        "successExitCodes": "0"
      }
    ]
  }
}
```

Specify only the groups required by the scanner or service. Group names are resolved on the target
system and may be localized.

## Rotation

1. Update the Key Vault secret.
2. Rerun the artifact on each session host.
3. Verify that the scanner or service can authenticate with the new password.

## Verification

```powershell
Get-LocalUser -Name 'svc-scanner' |
    Select-Object Name, Enabled, AccountExpires, PasswordExpires, SID

Get-LocalGroupMember -Group 'Administrators' |
    Where-Object SID -eq (Get-LocalUser -Name 'svc-scanner').SID
```

## Microsoft references

- [New-LocalUser](https://learn.microsoft.com/powershell/module/microsoft.powershell.localaccounts/new-localuser)
- [Set-LocalUser](https://learn.microsoft.com/powershell/module/microsoft.powershell.localaccounts/set-localuser)
- [Add-LocalGroupMember](https://learn.microsoft.com/powershell/module/microsoft.powershell.localaccounts/add-localgroupmember)
- [Use managed identities on a VM to acquire an access token](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token)
- [Key Vault Get Secret REST API](https://learn.microsoft.com/rest/api/keyvault/secrets/get-secret/get-secret)
