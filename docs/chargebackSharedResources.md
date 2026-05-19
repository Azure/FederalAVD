# Chargeback Approaches for Shared AVD Resources

This document covers cost attribution strategies for shared infrastructure resources in the FederalAVD deployment. All approaches use tagging already present in the deployment — no code changes are required.

---

## 1. Recovery Services Vault

The RSV is shared across host pools. Backup storage cost is billed to the vault itself, not to individual protected items.

### What is tagged

| Resource | Tag | Set by |
|---|---|---|
| `protectedItems` (VM) | `cm-resource-parent: <hostPoolResourceId>` | `vmBackupItems.bicep` |
| `protectionContainers` (file share) | `cm-resource-parent: <hostPoolResourceId>` | `fslogixBackupItems.bicep` |
| `protectedItems` (file share) | `cm-resource-parent: <hostPoolResourceId>` | `fslogixBackupItems.bicep` |

Tags on protected items are ARM metadata only — they do **not** redirect charges in Azure Cost Management. The vault resource itself bears all cost.

### Chargeback approach: Azure Backup Reports + Resource Graph

The RSV diagnostic settings are wired to the Log Analytics workspace when `enableMonitoring = true`. The `AddonAzureBackupStorage` table contains storage consumed per protected item.

**Combined VM and Azure Files backup query:**

```kql
let vmBackup = AddonAzureBackupStorage
    | where BackupItemType == "VM"
    | extend vmName = tolower(extract(@'iaasvmcontainerv2;[^;]+;([^/]+)', 1, BackupItemUniqueId))
    | summarize LatestStorageMB = arg_max(TimeGenerated, StorageConsumedInMBs) by vmName
    | join kind=leftouter (
        arg("").resources
        | where type == "microsoft.compute/virtualmachines"
        | project vmName = tolower(name), hostPool = tags['cm-resource-parent']
    ) on vmName
    | project hostPool, StorageMB = LatestStorageMB, Type = "VM";
let fileShareBackup = AddonAzureBackupStorage
    | where BackupItemType == "AzureFileShare"
    | extend saName = tolower(extract(@'storagecontainer;Storage;[^;]+;([^/]+)', 1, BackupItemUniqueId))
    | summarize LatestStorageMB = arg_max(TimeGenerated, StorageConsumedInMBs) by saName
    | join kind=leftouter (
        arg("").resources
        | where type == "microsoft.storage/storageaccounts"
        | project saName = tolower(name), hostPool = tags['cm-resource-parent']
    ) on saName
    | project hostPool, StorageMB = LatestStorageMB, Type = "FileShare";
union vmBackup, fileShareBackup
| summarize TotalBackupStorageMB = sum(StorageMB) by hostPool, Type
| order by hostPool asc
```

> **Note:** The Azure Files query assumes 1:1 storage account to host pool. If this changes, the join would need to be reworked.

### Alternative: Azure Cost Management cost allocation rules

If query-based attribution is too granular, Cost Management supports splitting the RSV's cost across subscriptions or resource groups by ratio. This is coarse-grained but zero-maintenance.

---

## 2. Azure Monitor (Log Analytics Workspace)

The Log Analytics workspace is shared. Ingestion and retention charges are billed to the workspace.

### What is tracked

Session host telemetry flows into the workspace from every host pool via shared regional Data Collection Rules (DCRs). The DCRs are not tagged per host pool — they are shared infrastructure, one set per region. There is no ARM-level hook to split ingestion cost per host pool.

### Chargeback approach: Usage table by table/source

The `Usage` table in Log Analytics records data volume ingested per solution/table per day:

```kql
Usage
| where TimeGenerated > ago(30d)
| summarize IngestedGB = sum(Quantity) / 1024 by DataType, bin(TimeGenerated, 1d)
| order by TimeGenerated desc
```

To break down by host pool, use the `_ResourceId` column available in most AVD-related tables:

```kql
WVDConnections
| where TimeGenerated > ago(30d)
| extend hostPool = tostring(split(_ResourceId, '/')[8])
| summarize Sessions = count() by hostPool, bin(TimeGenerated, 1d)
```

Use this session volume as a proxy to split the workspace's total ingestion cost proportionally across host pools — the workspace doesn't expose per-host-pool ingestion cost natively.

### Alternative: Dedicated workspace per host pool

The cleanest chargeback model. Each host pool deployment accepts `existingLogAnalyticsWorkspaceResourceId`, so separate workspaces are supported with no code changes. Cost is then directly attributable with no query needed.

---

## 3. Key Vault

Key Vaults may be shared (a single vault holds keys for multiple host pools). The vault itself has a fixed tier cost; the **operations** cost is per cryptographic operation.

### What is tagged

Keys get `cm-resource-parent: <hostPoolResourceId>` via `parentTag` in `customerManagedKeys.bicep`. This flows onto:

| Key type | Tag source |
|---|---|
| Disk CMK (RSA / RSA-HSM) | `diskCmk.bicep` → `customerManagedKeys.bicep` → `parentTag` |
| Storage CMK (FSLogix) | `storageCmk.bicep` → `customerManagedKeys.bicep` → `parentTag` |
| CVM disk key | `cvmDiskCmk.bicep` → `customerManagedKeys.bicep` → `parentTag` |

### Chargeback approach: Resource Graph on keys

Because keys are tagged, you can enumerate them and attribute fixed vault tier cost proportionally:

```kql
// Azure Resource Graph
resources
| where type == "microsoft.keyvault/vaults/keys"
| extend hostPool = tags['cm-resource-parent']
| where isnotempty(hostPool)
| summarize KeyCount = count() by hostPool
```

Use key count per host pool as a proxy ratio to split the vault's monthly cost.

### Key Vault operations cost

Operations are billed at ~$0.03 per 10,000 for Standard tier, ~$1.00 per 10,000 for Premium/HSM. In practice, CMK encryption operations are low-volume (one per disk read/write cache flush, not per I/O) and the operations cost is typically negligible compared to the resources being encrypted. It is generally not worth attributing per host pool.

---

## 4. Key Vault Secrets

### Do secrets cost anything?

**No per-secret cost.** Secrets are included in the Key Vault tier cost (Standard or Premium). The only charge is per-operation — each `GetSecret` call is ~$0.03 per 10,000 operations at Standard tier.

In this deployment, secrets (domain join credentials, VM admin passwords) are read once per session host deployment batch. For a 50-VM deployment that is a handful of operations — fractions of a cent. **Secrets are not worth tracking for chargeback.**

---

## Summary

| Shared Resource | Tags Present | Recommended Chargeback Method | Effort |
|---|---|---|---|
| Recovery Services Vault | Yes — on protected items and containers | LA query joining ARG (`AddonAzureBackupStorage` + Resource Graph) | Low |
| Log Analytics Workspace | Yes — on DCRs (indirectly) | Session volume proxy via `WVDConnections` | Medium |
| Key Vault (keys) | Yes — `cm-resource-parent` on each key | Resource Graph key count ratio | Low |
| Key Vault (secrets) | N/A | No attribution needed — negligible cost | None |
