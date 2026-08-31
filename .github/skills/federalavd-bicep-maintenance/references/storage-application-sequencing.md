# Storage Application Configuration Sequencing

Use this reference when changing Azure Files with Entra ID Kerberos and private endpoints.

The storage account enterprise application must contain the private-link FQDN before NTFS
permission configuration authenticates through the private endpoint. Keep the operations in this
order:

1. Create storage accounts and file shares.
2. Create private endpoints.
3. Configure Entra Kerberos authentication.
4. Run `Update-StorageAccountApplicationManifest.ps1` to add the private-link FQDN and required
   application tags and identifier URIs.
5. Assign managed-identity RBAC.
6. Run `Set-NtfsPermissionsAzureFiles.ps1`.
7. Run `Grant-StorageAccountApplicationConsent.ps1` to create or update delegated permission
   grants.

Reversing steps 4 and 6 can produce HTTP 404 during NTFS permission configuration because the
storage enterprise application does not yet recognize the private-link FQDN.

Both scripts are loaded by the shared Azure Files orchestration and run through the common compute
Run Command module. Do not combine the manifest update and consent grant into a single operation;
NTFS permission configuration intentionally runs between them.
