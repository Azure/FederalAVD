
# **Get-KeyVaultSecret.ps1**

## Overview

This PowerShell script retrieves a secret from Azure Key Vault using a **User Assigned Managed Identity (UAMI)** inside an Azure Virtual Machine or Azure Virtual Desktop session host. It uses **Azure Instance Metadata Service (IMDS)** to request a token scoped to the correct Key Vault cloud endpoint, ensuring compatibility across **Azure Commercial**, **Azure Government**, **DoD**, and sovereign cloud environments.

The script requires only:

- A fully‑qualified Key Vault URL  
- The secret name  
- The UAMI client ID  

No Az modules, no external dependencies — fully REST‑based and ideal for locked‑down or air‑gapped environments.

---

## Purpose

- Retrieve a Key Vault secret securely using a UAMI  
- Automatically derive the correct Key Vault resource endpoint from the vault URL  
- Support multi‑cloud deployments (Commercial, Gov, DoD, sovereign)  
- Provide a lightweight, dependency‑free Run Command script for AVD session hosts  
- Store the retrieved secret in a PowerShell variable for downstream use  

---

## Parameters

### `VaultBaseUrl`

- **Type:** String  
- **Required:** Yes  
- **Description:** Fully‑qualified Key Vault base URL  
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
- **Purpose:** IMDS uses this identity to request a Key Vault‑scoped token

---

## Usage Examples

### Basic Usage

```powershell
.\Get-KeyVaultSecret.ps1 `
    -VaultBaseUrl "https://myvault.vault.usgovcloudapi.net" `
    -SecretName "DbPassword" `
    -UserAssignedIdentityClientId "00000000-0000-0000-0000-000000000000"
```

### With Variables

```powershell
$vaultUrl = "https://myvault.vault.azure.net"
$secret = "StorageKey"
$uami = "11111111-2222-3333-4444-555555555555"

.\Get-KeyVaultSecret.ps1 -VaultBaseUrl $vaultUrl -SecretName $secret -UserAssignedIdentityClientId $uami
```

---

## What the Script Does

### 1. Normalizes the Key Vault URL

Ensures no trailing slash and extracts the hostname.

### 2. Derives the Correct Token Resource

Based on the Key Vault DNS suffix:

| Vault URL | Derived Resource |
|----------|------------------|
| `vault.azure.net` | `https://vault.azure.net` |
| `vault.usgovcloudapi.net` | `https://vault.usgovcloudapi.net` |
| `vault.microsoftazure.us` | `https://vault.microsoftazure.us` |

This ensures the IMDS token is valid for the correct cloud.

### 3. Requests a Token from IMDS

Uses the UAMI client ID to request a Key Vault‑scoped token:

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
VaultBaseUrl → Parse DNS suffix → Build resource URL → IMDS token → Key Vault REST → SecretValue
```

---

## Requirements

### Prerequisites

- **OS:** Windows Server, Windows 10, or Windows 11  
- **Environment:** Azure VM or AVD session host  
- **Identity:** User Assigned Managed Identity assigned to VM  
- **Permissions:** UAMI must have `get` permission on the secret  
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
C:\Windows\Logs\Configuration\Get-KeyVaultSecret-<timestamp>.log
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

1. Use UAMIs instead of system‑assigned identities for better control  
2. Store sensitive values only in memory, not on disk  
3. Validate Key Vault URLs before deployment  
4. Use RBAC instead of Access Policies when possible  
5. Keep secret names consistent across environments