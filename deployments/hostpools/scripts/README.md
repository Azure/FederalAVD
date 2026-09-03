# Standard Host Pool PowerShell Scripts

This directory contains PowerShell scripts owned by the standard Host Pool solution. Shared
session-host, FSLogix, customization, cleanup, and AVD control-plane scripts are documented in the
[shared scripts reference](../../shared/scripts/README.md).

## Confidential VM Disk Encryption

### [Set-ConfidentialVMOSDiskEncryptionKey.ps1](Set-ConfidentialVMOSDiskEncryptionKey.ps1)

Creates the exportable RSA-HSM key used for Confidential VM operating-system disk encryption when
the key doesn't already exist.

- **Used by:** The standard host pool Confidential VM CMK module
- **Parameters:** `KeyName`, `Tags`, `UserAssignedIdentityClientId`, `VaultUri`
- **Behavior:**
  - Authenticates to Azure Key Vault or Managed HSM through IMDS using the supplied managed identity.
  - Checks whether the named key already exists.
  - Creates a 4096-bit exportable RSA-HSM key with the Confidential VM secure key release policy.
  - Applies the supplied resource tags when present.
- **API:** Azure Key Vault data-plane API version `7.4`

## Conventions

- The script is embedded by Bicep with `loadTextContent()` and isn't an interactive operator utility.
- The calling identity requires the key data-plane permissions configured by the host pool template.
- This PowerShell file must remain ASCII-only because Bicep embeds it in generated ARM JSON.
