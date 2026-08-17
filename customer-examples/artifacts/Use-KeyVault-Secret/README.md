
# Use Key Vault Secret from Run Command

## Overview

This example shows two supported ways to use a Key Vault secret from an Azure VM Run Command on an Azure Virtual Desktop session host.

1. The script retrieves the secret at runtime from inside the VM by using a user-assigned managed identity and the Azure Instance Metadata Service (IMDS).
2. A deployment wrapper retrieves the secret from Key Vault with Bicep and passes the value to Run Command as a protected parameter.

The runtime IMDS pattern is the better default when the VM identity should own access to the secret. The protected parameter pattern is useful when the deployment identity already has permission to read the secret and you want the script to receive only a Run Command parameter.

`UseKeyVaultSecret.ps1` uses the runtime IMDS pattern. It requests a token scoped to the correct Key Vault cloud endpoint, then calls the Key Vault REST API. This keeps the secret out of the ARM/Bicep deployment input path and works across Azure Commercial, Azure Government, DoD, and sovereign cloud environments.

The script requires only:

- A fully-qualified Key Vault URL
- The secret name  
- The UAMI client ID  

No Az modules, no external dependencies - fully REST-based and ideal for locked-down or air-gapped environments.

## Recommended pattern

Use the runtime IMDS pattern when:

- The target VM or session host should be the security boundary for secret access.
- You do not want the deployment principal to read the secret value.
- The secret might be rotated without redeploying the Run Command template.
- The vault is reachable from the VM through private endpoint or allowed network paths.

Use the protected parameter pattern when:

- The deployment principal is already allowed to read the secret.
- You want Bicep/ARM to resolve the secret before Run Command starts.
- The VM does not need direct Key Vault data-plane access.
- You accept that secret rotation requires rerunning the deployment to pass the new value.

Do not use Bicep to list secrets. Bicep should retrieve a named secret only through `getSecret()` and pass it directly into a `@secure()` module parameter. The module can then map that secure value to Run Command `protectedParameters`.

---

## Purpose

- Retrieve a Key Vault secret securely using a UAMI  
- Automatically derive the correct Key Vault resource endpoint from the vault URL  
- Support multi-cloud deployments (Commercial, Gov, DoD, sovereign)
- Provide a lightweight, dependency-free Run Command script for AVD session hosts
- Store the retrieved secret in a PowerShell variable for downstream use  

---

## Parameters

### `VaultBaseUrl`

- **Type:** String  
- **Required:** Yes  
- **Description:** Fully-qualified Key Vault base URL
- **Examples:**  
  - `https://myvault.vault.azure.net`
  - `https://myvault.vault.usgovcloudapi.net`
  - `https://myvault.vault.microsoftazure.us`
- **Purpose:** Determines both the Key Vault endpoint and the correct token resource

---

### `SecretName`

- **Type:** String  
- **Required:** Yes  
- **Description:** Name of the secret to retrieve from Key Vault  
- **Example:** `DbPassword`

---

### `UserAssignedIdentityClientId`

- **Type:** String  
- **Required:** Yes  
- **Description:** Client ID of the User Assigned Managed Identity assigned to the VM  
- **Purpose:** IMDS uses this identity to request a Key Vault-scoped token

---

## Usage Examples

### Basic Usage

```powershell
.\UseKeyVaultSecret.ps1 `
    -VaultBaseUrl 'https://myvault.vault.usgovcloudapi.net' `
    -SecretName "DbPassword" `
    -UserAssignedIdentityClientId "00000000-0000-0000-0000-000000000000"
```

### With Variables

```powershell
$vaultUrl = 'https://myvault.vault.azure.net'
$secret = 'StorageKey'
$uami = '11111111-2222-3333-4444-555555555555'

.\UseKeyVaultSecret.ps1 -VaultBaseUrl $vaultUrl -SecretName $secret -UserAssignedIdentityClientId $uami
```

### Run Command add-on with script URI

Upload `UseKeyVaultSecret.ps1` to the script storage container used by the Run Commands on VMs add-on, then pass the vault URL, secret name, and UAMI client ID as script arguments.

```powershell
$scripts = @(
    @{
        name = 'UseKeyVaultSecret'
        blobNameOrUri = 'UseKeyVaultSecret.ps1'
        arguments = '-VaultBaseUrl "https://myvault.vault.usgovcloudapi.net" -SecretName "DbPassword" -UserAssignedIdentityClientId "00000000-0000-0000-0000-000000000000"'
    }
)

New-AzResourceGroupDeployment `
    -ResourceGroupName 'rg-avd-sessionhosts-usgv' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/runCommandsOnVms/main.json' `
    -vmNames @('avd-vm-01') `
    -scripts $scripts `
    -scriptsStorageAccountName 'stscriptstoreusgv' `
    -scriptsContainerName 'scripts' `
    -scriptsUserAssignedIdentityResourceId '/subscriptions/SUB-ID/resourceGroups/rg-identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-scripts' `
    -Verbose
```

The script storage identity needs **Storage Blob Data Reader** on the script storage account. The identity passed to `UserAssignedIdentityClientId` must be assigned to the VM and must have Key Vault secret read access.

## Protected parameter alternative

Run Command supports `protectedParameters`. This lets a script receive a sensitive parameter without writing the value into normal deployment outputs or Run Command parameters.

Use a small wrapper module when you want Bicep to read a named secret from Key Vault and pass it to Run Command. The important part is that `getSecret()` is passed directly into a module parameter decorated with `@secure()`.

`runCommandWithSecret.bicep`:

```bicep
param vmName string
param location string = resourceGroup().location
param keyVaultName string
param secretName string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

module runCommand './runCommandWithProtectedSecret.bicep' = {
  params: {
    vmName: vmName
    location: location
    secretValue: keyVault.getSecret(secretName)
  }
}
```

`runCommandWithProtectedSecret.bicep`:

```bicep
param vmName string
param location string

@secure()
param secretValue string

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: vmName
}

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: vm
  name: 'UseProtectedSecret'
  location: location
  properties: {
    source: {
      script: '''
param(
    [Parameter(Mandatory = $true)]
    [string] $SecretValue
)

Write-Output "Secret received through protected parameter. Length: $($SecretValue.Length)"
'''
    }
    protectedParameters: [
      {
        name: 'SecretValue'
        value: secretValue
      }
    ]
  }
}
```

The identity that deploys `runCommandWithSecret.bicep` must have permission to read the secret. The VM does not need Key Vault secret access for this pattern because the secret is resolved before the Run Command resource is created.

You can also use the existing Run Commands on VMs add-on by passing a secure `protectedParameter` object to the template:

```powershell
$scriptContent = @'
param(
    [Parameter(Mandatory = $true)]
    [string] $SecretValue
)

Write-Output "Secret received through protected parameter. Length: $($SecretValue.Length)"
'@

$protectedParameter = @{
    name = 'SecretValue'
    value = '<secret value from your secure pipeline or Key Vault reference>'
}

New-AzResourceGroupDeployment `
    -ResourceGroupName 'rg-avd-sessionhosts-usgv' `
    -TemplateFile 'https://raw.githubusercontent.com/Azure/federalavd/main/deployments/add-ons/runCommandsOnVms/main.json' `
    -vmNames @('avd-vm-01') `
    -runCommandName 'UseProtectedSecret' `
    -scriptContent $scriptContent `
    -protectedParameter $protectedParameter `
    -Verbose
```

---

## What the Script Does

### 1. Normalizes the Key Vault URL

Ensures no trailing slash and extracts the hostname.

### 2. Derives the Correct Token Resource

Based on the Key Vault DNS suffix:

| Vault URL | Derived Resource |
| --- | --- |
| `vault.azure.net` | `https://vault.azure.net` |
| `vault.usgovcloudapi.net` | `https://vault.usgovcloudapi.net` |
| `vault.microsoftazure.us` | `https://vault.microsoftazure.us` |

This ensures the IMDS token is valid for the correct cloud.

### 3. Requests a Token from IMDS

Uses the UAMI client ID to request a Key Vault-scoped token:

```plaintext
169.254.169.254/metadata/identity/oauth2/token
```

### 4. Calls Key Vault REST API

Uses the token to retrieve the secret value:

```plaintext
GET {VaultBaseUrl}/secrets/{SecretName}?api-version=7.3
```

### 5. Stores the Secret in a Variable

The secret value is stored in:

```powershell
$SecretValue
```

---

## Script Logic Summary

```text
VaultBaseUrl -> Parse DNS suffix -> Build resource URL -> IMDS token -> Key Vault REST -> SecretValue
```

---

## Requirements

### Prerequisites

- **OS:** Windows Server, Windows 10, or Windows 11  
- **Environment:** Azure VM or AVD session host  
- **Identity:** User Assigned Managed Identity assigned to VM  
- **Permissions:** UAMI must have `get` permission on the secret when using the runtime IMDS pattern
- **Network:** Access to Key Vault endpoint for the cloud  

### Key Vault Access Policy / RBAC

The UAMI must have:

```plaintext
Microsoft.KeyVault/vaults/secrets/read
```

---

## Logging

You may optionally integrate this script with your existing logging framework in **federalavd**, such as:

```plaintext
C:\Windows\Logs\Configuration\UseKeyVaultSecret-<timestamp>.log
```

---

## Troubleshooting

### Secret Not Found

- Verify the secret name  
- Confirm the UAMI has correct permissions  
- Check Key Vault firewall settings  

### Token Retrieval Failure

- Ensure the UAMI is assigned to the VM  
- Confirm IMDS is reachable (always available inside Azure VMs)  

### Wrong Cloud Endpoint

- Ensure `VaultBaseUrl` is fully qualified  
- The script automatically derives the correct resource  

---

## Best Practices

1. Use UAMIs instead of system-assigned identities for better control
2. Store sensitive values only in memory, not on disk  
3. Validate Key Vault URLs before deployment  
4. Use RBAC instead of Access Policies when possible  
5. Keep secret names consistent across environments
