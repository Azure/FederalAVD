[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Host Pool Decommissioning Guide

## Overview

This guide provides procedures for safely decommissioning Azure Virtual Desktop host pools and their associated resources when they are no longer needed. Proper decommissioning ensures clean resource removal, prevents orphaned resources, and correctly handles shared infrastructure that may be used by other host pools.

> **⚠️ Critical:** Decommissioning is a **destructive operation** that permanently removes resources and data. Always verify backups, document dependencies, and obtain stakeholder approval before beginning the decommissioning process. This guide assumes you have already migrated users to alternative resources or confirmed the host pool is no longer needed.

### When to Use This Guide

Use this guide when you need to:

- **Decommission a completed project** — Remove a temporary or project-specific host pool
- **Retire a persona or department host pool** — Permanently remove resources for a decommissioned business unit
- **Clean up proof-of-concept deployments** — Remove test or PoC environments
- **Consolidate host pools** — Remove old host pools after migrating users to new ones
- **Reduce regional footprint** — Remove host pools from regions no longer in use

### What This Guide Does NOT Cover

This guide does **not** cover:

- **User migration** — See [BCDR](bcdr.md) for cross-region failover and migration strategies
- **Session host replacement** — See [Session Host Replacer](session-host-replacer.md) for automated VM refresh
- **Scaling down** — See [Host Pool Deployment](hostpool-deployment.md) for adjusting VM counts
- **Troubleshooting failed deployments** — See [Troubleshooting](troubleshooting.md)

---

## Prerequisites

Before starting the decommissioning process, ensure you have:

### Required Permissions

| Scope | Required Role | Why |
| --- | --- | --- |
| Host pool resource groups | **Contributor** or **Owner** | Delete VMs, storage accounts, and other resources |
| Shared resource groups (Operations, Monitoring) | **Contributor** or **Owner** | Remove protected items, keys, diagnostic settings |
| Recovery Services Vault | **Backup Contributor** | Remove protected items and stop backup |
| Key Vault | **Key Vault Crypto Officer** | Delete CMK keys (if not shared) |
| Subscription or Management Group | **User Access Administrator** or **Owner** | Remove RBAC assignments |

### Required Information

Gather the following information before proceeding:

| Item | How to Find It | Why Needed |
| --- | --- | --- |
| Host pool identifier and index | Parameter files, resource names | Identify all related resource groups |
| List of all resource groups | Azure portal, Resource Graph | Ensure complete cleanup |
| Shared resource dependencies | Cost Management tags, Resource Graph | Determine if shared resources can be deleted |
| Backup retention requirements | Compliance documentation, legal holds | Determine if backups must be retained |
| CMK usage | Key Vault, Disk Encryption Sets | Identify encryption keys that may be shared |

### Pre-Decommissioning Checklist

✅ **User notification** — Users have been notified and migrated to alternative resources  
✅ **Stakeholder approval** — Business owner has approved decommissioning  
✅ **Backup verification** — Required data has been backed up or archived  
✅ **Dependency check** — No other host pools depend on this one's storage or configuration  
✅ **Compliance review** — Legal/compliance holds do not prevent deletion  
✅ **Documentation** — Host pool configuration and purpose have been documented

---

## Understanding Resource Dependencies

FederalAVD deployments organize resources into **per-host-pool** and **shared regional** resource groups. Understanding these dependencies is critical to safe decommissioning.

### Resource Group Organization

Based on the [design documentation](design.md), resources are organized as follows:

#### Per-Host-Pool Resources (Safe to Delete)

These resources are dedicated to a single host pool and can be deleted when the host pool is decommissioned:

| Resource Group | Name Pattern | Resources |
| --- | --- | --- |
| **Hosts** | `rg-{identifier}-{index}-hosts-{location}` | Virtual machines, NICs, managed disks, Disk Encryption Set, Recovery Services Vault (personal pools only) |
| **Storage** | `rg-{identifier}-{index}-storage-{location}` | FSLogix storage accounts, Azure NetApp Files volumes, storage encryption UAI, private endpoints |

**Control Plane resources** (within `rg-avd-control-plane-{location}`):
- Host pool resource
- Application group(s) associated with this host pool
- Scaling plan(s) dedicated to this host pool

#### Shared Regional Resources (Requires Dependency Check)

These resources are shared across **all host pools in a region** and require careful analysis before deletion:

| Resource Group | Name Pattern | Resources | Shared Across |
| --- | --- | --- | --- |
| **Operations** | `rg-avd-operations-{location}` | Secrets Key Vault, Encryption Key Vault, Recovery Services Vault (FSLogix backup) | All host pools in region |
| **Monitoring** | `rg-avd-monitoring-{location}` | Log Analytics workspace, Data Collection Rules, Data Collection Endpoint | All host pools in region |
| **Control Plane** | `rg-avd-control-plane-{location}` | Workspace (feed), shared application groups, shared scaling plans | All host pools in region |

#### Global Resources (Requires Dependency Check)

| Resource Group | Name Pattern | Resources | Shared Across |
| --- | --- | --- | --- |
| **Global Feed** | `rg-avd-global-feed` | Global feed workspace | All host pools in tenant |

---

## Decommissioning Sequence

Follow this sequence to safely decommission a host pool. The order is important to respect dependencies and prevent orphaned resources.

> **Timing:** Budget 2–4 hours for a complete decommissioning depending on the number of resources, protected items, and whether shared resources can be removed. Steps 1–6 can be completed in sequence; Step 7 (shared resource cleanup) may require coordination with other host pool owners.

### High-Level Sequence

1. **Drain and disconnect users** — Ensure no active sessions
2. **Stop or delete session hosts** — Remove VMs to stop compute costs immediately
3. **Remove backup protection** — Stop backup for VMs and FSLogix shares
4. **Delete per-host-pool resources** — Remove dedicated resource groups
5. **Remove control-plane resources** — Delete host pool, app groups, scaling plans
6. **Clean up encryption and storage artifacts** — Remove keys, disk encryption sets
7. **Clean up shared resources (conditional)** — Remove shared resources if no longer needed
8. **Verify complete removal** — Confirm all resources and costs are gone

---

## Step 1: Drain and Disconnect Users

Before decommissioning, ensure no users are actively connected to the host pool.

### 1.1 Enable Drain Mode on All Session Hosts

Drain mode prevents new connections while allowing existing sessions to complete naturally.

**Portal:**
1. Navigate to **Azure Virtual Desktop** > **Host pools** > `[your-host-pool]` > **Session hosts**
2. Select all session hosts
3. Click **Turn drain mode on**

**PowerShell:**
```powershell
# Set drain mode on all session hosts in a host pool
$hostPoolName = "vdpool-avd-hr-01-usgovvirginia"
$resourceGroupName = "rg-avd-control-plane-va"

$sessionHosts = Get-AzWvdSessionHost -HostPoolName $hostPoolName -ResourceGroupName $resourceGroupName

foreach ($sessionHost in $sessionHosts) {
    Update-AzWvdSessionHost `
        -HostPoolName $hostPoolName `
        -ResourceGroupName $resourceGroupName `
        -Name $sessionHost.Name.Split('/')[1] `
        -AllowNewSession:$false
}
```

**Azure CLI:**
```bash
# Set drain mode on all session hosts
hostPoolName="vdpool-avd-hr-01-usgovvirginia"
resourceGroupName="rg-avd-control-plane-va"

az desktopvirtualization sessionhost list \
    --host-pool-name $hostPoolName \
    --resource-group $resourceGroupName \
    --query "[].name" -o tsv | \
while read sessionHost; do
    sessionHostName=$(basename "$sessionHost")
    az desktopvirtualization sessionhost update \
        --host-pool-name $hostPoolName \
        --resource-group $resourceGroupName \
        --name "$sessionHostName" \
        --allow-new-session false
done
```

### 1.2 Monitor Active Sessions

Wait for existing sessions to complete, or send logoff messages to active users.

**Check active session count:**
```powershell
$sessionHosts = Get-AzWvdSessionHost -HostPoolName $hostPoolName -ResourceGroupName $resourceGroupName
$activeSessions = ($sessionHosts | Measure-Object -Property Session -Sum).Sum
Write-Host "Active sessions: $activeSessions"
```

**Send logoff message to all users** (optional, provides warning):
```powershell
$userSessions = Get-AzWvdUserSession -HostPoolName $hostPoolName -ResourceGroupName $resourceGroupName

foreach ($session in $userSessions) {
    Send-AzWvdUserSessionMessage `
        -HostPoolName $hostPoolName `
        -ResourceGroupName $resourceGroupName `
        -SessionHostName $session.Name.Split('/')[1] `
        -UserSessionId $session.Name.Split('/')[3] `
        -MessageTitle "Maintenance Notice" `
        -MessageBody "This host pool is being decommissioned. Please save your work and log off within 15 minutes."
}
```

### 1.3 Force Logoff Users (If Required)

If users do not log off voluntarily and immediate decommissioning is required:

```powershell
$userSessions = Get-AzWvdUserSession -HostPoolName $hostPoolName -ResourceGroupName $resourceGroupName

foreach ($session in $userSessions) {
    Remove-AzWvdUserSession `
        -HostPoolName $hostPoolName `
        -ResourceGroupName $resourceGroupName `
        -SessionHostName $session.Name.Split('/')[1] `
        -Id $session.Name.Split('/')[3] `
        -Force
}
```

> **⚠️ Warning:** Force logoff will immediately disconnect users and may result in unsaved work loss. Only use after providing adequate notice.

---

## Step 2: Stop or Delete Session Hosts

Stopping or deleting session hosts immediately halts compute costs. For complete decommissioning, delete the VMs. For temporary suspension, stop them.

### 2.1 Stop Session Hosts (Temporary Suspension)

If you need to temporarily suspend the host pool without full decommissioning:

**PowerShell:**
```powershell
$hostResourceGroupName = "rg-hr-01-hosts-va"

# Get all VMs in the host resource group
$vms = Get-AzVM -ResourceGroupName $hostResourceGroupName

foreach ($vm in $vms) {
    Write-Host "Stopping VM: $($vm.Name)"
    Stop-AzVM -ResourceGroupName $hostResourceGroupName -Name $vm.Name -Force
}
```

> **Note:** Stopped VMs still incur storage costs for managed disks. For full decommissioning, proceed to delete the VMs.

### 2.2 Delete Session Hosts (Full Decommissioning)

**Option 1: Delete from AVD (Recommended)**

This removes the session host from the host pool and deletes the VM:

```powershell
$sessionHosts = Get-AzWvdSessionHost -HostPoolName $hostPoolName -ResourceGroupName $resourceGroupName

foreach ($sessionHost in $sessionHosts) {
    $sessionHostName = $sessionHost.Name.Split('/')[1]
    Write-Host "Removing session host: $sessionHostName"
    
    Remove-AzWvdSessionHost `
        -HostPoolName $hostPoolName `
        -ResourceGroupName $resourceGroupName `
        -Name $sessionHostName
}
```

**Option 2: Delete entire host resource group**

The fastest method for complete cleanup:

```powershell
$hostResourceGroupName = "rg-hr-01-hosts-va"

Write-Host "Deleting host resource group: $hostResourceGroupName"
Remove-AzResourceGroup -Name $hostResourceGroupName -Force
```

> **⚠️ Warning:** Deleting the resource group removes **all resources** including VMs, disks, NICs, Disk Encryption Sets, and any personal host pool Recovery Services Vaults. Ensure backups are not needed before proceeding.

### Automated Host Pools: Reduce Instance Count First

For **automated host pools** (using Session Host Configuration), do not delete VMs directly. Instead, scale the managed instance count to zero:

**Portal:**
1. Navigate to **Host pools** > `[your-automated-host-pool]` > **Session host management**
2. Set **Instance count** to `0`
3. Save and wait for Azure Virtual Desktop to delete the VMs

**PowerShell:**
```powershell
# Scale automated host pool to zero hosts
$hostPoolName = "vdpool-avd-hr-01-usgovvirginia"
$resourceGroupName = "rg-avd-control-plane-va"

Update-AzWvdHostPoolSessionHostManagement `
    -HostPoolName $hostPoolName `
    -ResourceGroupName $resourceGroupName `
    -Name "default" `
    -InstanceCount 0
```

Wait for the managed VMs to be deleted by the service (typically 10–20 minutes) before proceeding to delete the host pool.

---

## Step 3: Remove Backup Protection

Before deleting storage or VM resources, you must remove backup protection from the Recovery Services Vault. Protected items cannot be deleted until backup is stopped and recovery points are removed.

### 3.1 Identify Protected Items

Determine which items are backed up:

**Query protected VMs** (personal host pools):
```powershell
$vaultName = "rsv-avd-va"  # Personal pool vault in hosts RG
$vaultResourceGroupName = "rg-hr-01-hosts-va"

$vault = Get-AzRecoveryServicesVault -Name $vaultName -ResourceGroupName $vaultResourceGroupName
Set-AzRecoveryServicesVaultContext -Vault $vault

$backupItems = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $vault.ID
$backupItems | Select-Object Name, ProtectionStatus, LastBackupTime
```

**Query protected FSLogix file shares** (pooled host pools):
```powershell
$sharedVaultName = "rsv-avd-va"  # Shared vault in operations RG
$sharedVaultResourceGroupName = "rg-avd-operations-va"

$sharedVault = Get-AzRecoveryServicesVault -Name $sharedVaultName -ResourceGroupName $sharedVaultResourceGroupName
Set-AzRecoveryServicesVaultContext -Vault $sharedVault

$fileShareItems = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $sharedVault.ID
$fileShareItems | Select-Object Name, FriendlyName, ProtectionStatus, LastBackupTime
```

### 3.2 Stop Backup and Delete Recovery Points

For each protected item, stop backup and delete all recovery points.

> **⚠️ Compliance Warning:** Ensure backup retention requirements are met before deleting recovery points. Some compliance frameworks require retention periods of 7 years or more. Verify with your compliance and legal teams before proceeding.

**Stop backup and delete recovery points for VMs:**
```powershell
$vault = Get-AzRecoveryServicesVault -Name $vaultName -ResourceGroupName $vaultResourceGroupName
Set-AzRecoveryServicesVaultContext -Vault $vault

$backupItems = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $vault.ID

foreach ($item in $backupItems) {
    Write-Host "Stopping backup and deleting recovery points for: $($item.Name)"
    
    # This disables backup and deletes all recovery points
    Disable-AzRecoveryServicesBackupProtection `
        -Item $item `
        -VaultId $vault.ID `
        -RemoveRecoveryPoints `
        -Force
}
```

**Stop backup and delete recovery points for FSLogix file shares:**
```powershell
$sharedVault = Get-AzRecoveryServicesVault -Name $sharedVaultName -ResourceGroupName $sharedVaultResourceGroupName
Set-AzRecoveryServicesVaultContext -Vault $sharedVault

$fileShareItems = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $sharedVault.ID

# Filter to only this host pool's shares using the cm-resource-parent tag
foreach ($item in $fileShareItems) {
    $containerName = $item.ContainerName
    $storageAccountName = ($containerName -split ';')[-1]
    
    # Get the storage account to check tags
    $storageAccount = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $storageAccountName }
    
    # Check if this storage account belongs to the host pool being decommissioned
    if ($storageAccount.Tags.'cm-resource-parent' -like "*$hostPoolName*") {
        Write-Host "Stopping backup and deleting recovery points for: $($item.FriendlyName)"
        
        Disable-AzRecoveryServicesBackupProtection `
            -Item $item `
            -VaultId $sharedVault.ID `
            -RemoveRecoveryPoints `
            -Force
    }
}
```

### 3.3 Verify Backup Removal

Confirm all protected items for this host pool have been removed:

```powershell
# Verify no protected items remain
$remainingItems = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $vault.ID
if ($remainingItems.Count -eq 0) {
    Write-Host "✓ All VM backup items removed"
} else {
    Write-Host "⚠ Warning: $($remainingItems.Count) VM backup items still protected"
}

$remainingFileShareItems = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $sharedVault.ID
Write-Host "Remaining file share backup items: $($remainingFileShareItems.Count)"
```

> **Note:** Recovery point deletion is asynchronous and may take 10–30 minutes to complete. If you attempt to delete storage accounts immediately, you may receive an error that protected items still exist. Wait and retry if this occurs.

---

## Step 4: Delete Per-Host-Pool Resources

Now that backups are stopped and VMs are deleted (or being deleted), remove the dedicated resource groups for this host pool.

### 4.1 Delete Host Resource Group

If you did not already delete this in Step 2.2:

```powershell
$hostResourceGroupName = "rg-hr-01-hosts-va"

Write-Host "Deleting host resource group: $hostResourceGroupName"
Remove-AzResourceGroup -Name $hostResourceGroupName -Force -AsJob
```

**Resources removed:**
- Virtual machines (if not already deleted)
- Network interfaces
- Managed disks
- Disk Encryption Set (if CMK was used for VM disks)
- Recovery Services Vault (personal host pools only — **not shared**)

> **Note:** The `-AsJob` parameter runs the deletion in the background. Resource group deletion can take 15–45 minutes depending on the number of resources.

### 4.2 Delete Storage Resource Group

Remove the FSLogix storage and associated resources:

```powershell
$storageResourceGroupName = "rg-hr-01-storage-va"

Write-Host "Deleting storage resource group: $storageResourceGroupName"
Remove-AzResourceGroup -Name $storageResourceGroupName -Force -AsJob
```

**Resources removed:**
- FSLogix storage account(s)
- Azure NetApp Files volumes (if used)
- Storage encryption User-Assigned Identity (if CMK was used for storage)
- Private endpoints for storage

> **⚠️ Data Loss Warning:** Deleting the storage account **permanently deletes all FSLogix profile containers**. Ensure:
> - Users have been migrated to alternative storage
> - Required profile data has been backed up or archived
> - Soft-delete and backup retention requirements are satisfied

### 4.3 Monitor Deletion Progress

Check the status of background deletion jobs:

```powershell
# Check all background jobs
Get-Job | Format-Table Id, Name, State

# Wait for all deletion jobs to complete
Get-Job | Wait-Job

# Check for any failed jobs
Get-Job | Where-Object { $_.State -eq 'Failed' } | Receive-Job
```

---

## Step 5: Remove Control-Plane Resources

Remove the AVD control-plane resources for this host pool.

### 5.1 Delete Scaling Plans (If Dedicated)

If the host pool has a dedicated scaling plan (not shared across host pools):

```powershell
$scalingPlanName = "vdscalplan-avd-hr-01-usgovvirginia"
$scalingPlanResourceGroupName = "rg-avd-control-plane-va"

Write-Host "Deleting scaling plan: $scalingPlanName"
Remove-AzWvdScalingPlan -Name $scalingPlanName -ResourceGroupName $scalingPlanResourceGroupName
```

> **Note:** If the scaling plan is **shared** across multiple host pools, do not delete it. Instead, remove only this host pool's association with the scaling plan.

### 5.2 Delete Application Groups

```powershell
$resourceGroupName = "rg-avd-control-plane-va"

# Get all application groups for this host pool
$appGroups = Get-AzWvdApplicationGroup -ResourceGroupName $resourceGroupName | 
    Where-Object { $_.HostPoolArmPath -like "*$hostPoolName*" }

foreach ($appGroup in $appGroups) {
    Write-Host "Deleting application group: $($appGroup.Name)"
    Remove-AzWvdApplicationGroup -Name $appGroup.Name -ResourceGroupName $resourceGroupName
}
```

### 5.3 Delete Host Pool

```powershell
$hostPoolName = "vdpool-avd-hr-01-usgovvirginia"
$resourceGroupName = "rg-avd-control-plane-va"

Write-Host "Deleting host pool: $hostPoolName"
Remove-AzWvdHostPool -Name $hostPoolName -ResourceGroupName $resourceGroupName
```

**For automated host pools**, ensure the instance count was reduced to zero in Step 2 before deleting the host pool. The host pool cannot be deleted while managed VMs are still being removed.

### 5.4 Delete Workspace Association (If Dedicated)

If the host pool had a dedicated workspace (not shared with other host pools):

**Check if workspace is shared:**
```powershell
$workspaceName = "vdws-avd-usgovvirginia"
$workspace = Get-AzWvdWorkspace -Name $workspaceName -ResourceGroupName $resourceGroupName

# List application group references
$workspace.ApplicationGroupReference

# If this workspace has no other application group references, it can be deleted
if ($workspace.ApplicationGroupReference.Count -eq 0) {
    Write-Host "Workspace has no remaining application groups. Safe to delete."
    Remove-AzWvdWorkspace -Name $workspaceName -ResourceGroupName $resourceGroupName
} else {
    Write-Host "⚠ Workspace is shared with other host pools. Do not delete."
}
```

---

## Step 6: Clean Up Encryption and Storage Artifacts

Remove encryption keys and storage-related artifacts that are specific to this host pool.

### 6.1 Identify CMK Keys for This Host Pool

Customer-Managed Keys (CMK) are tagged with `cm-resource-parent` pointing to the host pool resource ID.

**Query keys for this host pool:**
```powershell
$encryptionKeyVaultName = "kv-avd-enc-abc123-va"
$encryptionKeyVaultResourceGroupName = "rg-avd-operations-va"

# Get all keys in the encryption Key Vault
$keys = Get-AzKeyVaultKey -VaultName $encryptionKeyVaultName

# Filter keys tagged to this host pool
$hostPoolResourceId = "/subscriptions/{subscriptionId}/resourceGroups/{controlPlaneRG}/providers/Microsoft.DesktopVirtualization/hostPools/$hostPoolName"

$hostPoolKeys = $keys | Where-Object {
    $keyDetails = Get-AzKeyVaultKey -VaultName $encryptionKeyVaultName -Name $_.Name
    $keyDetails.Tags.'cm-resource-parent' -eq $hostPoolResourceId
}

$hostPoolKeys | Select-Object Name, @{Name='KeyType';Expression={$_.Attributes.KeyType}}
```

### 6.2 Delete CMK Keys (If Not Shared)

If the keys are **not shared** with other host pools:

```powershell
foreach ($key in $hostPoolKeys) {
    Write-Host "Deleting encryption key: $($key.Name)"
    
    # Soft-delete the key
    Remove-AzKeyVaultKey -VaultName $encryptionKeyVaultName -Name $key.Name -Force
    
    # Optionally purge immediately (if purge protection is not enabled)
    # Remove-AzKeyVaultKey -VaultName $encryptionKeyVaultName -Name $key.Name -InRemovedState -Force
}
```

> **⚠️ Purge Protection:** If purge protection is enabled on the Key Vault, deleted keys enter a soft-deleted state and cannot be purged until the retention period expires (default 90 days). The key name remains reserved during this period. If you need to reuse the key name sooner, reduce the retention period to 7 days in non-production environments.

> **🔒 Shared Key Warning:** If a key is **shared** across multiple host pools (uncommon but possible), do not delete it. Use the query above to check the `cm-resource-parent` tag before deletion.

### 6.3 Verify Key Deletion

```powershell
# List remaining keys
$remainingKeys = Get-AzKeyVaultKey -VaultName $encryptionKeyVaultName
Write-Host "Remaining keys in encryption Key Vault: $($remainingKeys.Count)"

# List soft-deleted keys
$deletedKeys = Get-AzKeyVaultKey -VaultName $encryptionKeyVaultName -InRemovedState
Write-Host "Soft-deleted keys: $($deletedKeys.Count)"
```

---

## Step 7: Clean Up Shared Resources (Conditional)

Shared resources (Recovery Services Vault, Key Vaults, Log Analytics, Workspace) are used by **all host pools in the region**. Only remove these resources if:

1. This is the **last host pool** in the region, **AND**
2. No other AVD deployments depend on these shared resources, **AND**
3. You do not plan to deploy new host pools in this region

### 7.1 Determine if Shared Resources Are Still Needed

Use the following queries to determine if other host pools still exist in the region.

**Query for remaining host pools in the region:**
```powershell
$location = "USGovVirginia"
$hostPools = Get-AzWvdHostPool | Where-Object { $_.Location -eq $location }

if ($hostPools.Count -eq 0) {
    Write-Host "✓ No remaining host pools in $location. Shared resources can be removed."
} else {
    Write-Host "⚠ Warning: $($hostPools.Count) host pool(s) still exist in $location"
    $hostPools | Select-Object Name, Location, Type
    Write-Host "Do not delete shared resources."
}
```

**Query for remaining protected items in shared Recovery Services Vault:**
```powershell
$sharedVaultName = "rsv-avd-va"
$sharedVaultResourceGroupName = "rg-avd-operations-va"

$sharedVault = Get-AzRecoveryServicesVault -Name $sharedVaultName -ResourceGroupName $sharedVaultResourceGroupName
Set-AzRecoveryServicesVaultContext -Vault $sharedVault

$remainingItems = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $sharedVault.ID

if ($remainingItems.Count -eq 0) {
    Write-Host "✓ No remaining protected items in shared vault. Vault can be deleted."
} else {
    Write-Host "⚠ Warning: $($remainingItems.Count) protected item(s) remain in shared vault"
    Write-Host "Do not delete the shared vault."
}
```

**Query for remaining keys in shared encryption Key Vault:**
```powershell
$encryptionKeyVaultName = "kv-avd-enc-abc123-va"
$keys = Get-AzKeyVaultKey -VaultName $encryptionKeyVaultName

if ($keys.Count -eq 0) {
    Write-Host "✓ No remaining keys in encryption Key Vault. Vault can be deleted."
} else {
    Write-Host "⚠ Warning: $($keys.Count) key(s) remain in encryption Key Vault"
    Write-Host "Do not delete the Key Vault until all keys are removed."
}
```

### 7.2 Delete Shared Recovery Services Vault (If Empty)

Only delete the shared Recovery Services Vault if **all protected items** have been removed:

```powershell
$sharedVaultName = "rsv-avd-va"
$sharedVaultResourceGroupName = "rg-avd-operations-va"

# Verify vault is empty
$sharedVault = Get-AzRecoveryServicesVault -Name $sharedVaultName -ResourceGroupName $sharedVaultResourceGroupName
Set-AzRecoveryServicesVaultContext -Vault $sharedVault

$remainingItems = Get-AzRecoveryServicesBackupItem -VaultId $sharedVault.ID
if ($remainingItems.Count -gt 0) {
    Write-Host "⚠ Vault still has $($remainingItems.Count) protected items. Cannot delete."
    exit
}

# Delete the vault
Write-Host "Deleting shared Recovery Services Vault: $sharedVaultName"
Remove-AzRecoveryServicesVault -Vault $sharedVault -Force
```

### 7.3 Delete Key Vaults (If Empty and No Longer Needed)

Delete the secrets and encryption Key Vaults if **all keys and secrets** have been removed and **no other host pools** exist:

```powershell
$secretsKeyVaultName = "kv-avd-sec-abc123-va"
$encryptionKeyVaultName = "kv-avd-enc-abc123-va"
$operationsResourceGroupName = "rg-avd-operations-va"

# Verify vaults are empty
$secretsCount = (Get-AzKeyVaultSecret -VaultName $secretsKeyVaultName).Count
$keysCount = (Get-AzKeyVaultKey -VaultName $encryptionKeyVaultName).Count

if ($secretsCount -eq 0 -and $keysCount -eq 0) {
    Write-Host "Deleting secrets Key Vault: $secretsKeyVaultName"
    Remove-AzKeyVault -VaultName $secretsKeyVaultName -ResourceGroupName $operationsResourceGroupName -Force
    
    Write-Host "Deleting encryption Key Vault: $encryptionKeyVaultName"
    Remove-AzKeyVault -VaultName $encryptionKeyVaultName -ResourceGroupName $operationsResourceGroupName -Force
} else {
    Write-Host "⚠ Vaults still contain secrets ($secretsCount) or keys ($keysCount). Not deleting."
}
```

> **Note:** Deleted Key Vaults enter a soft-deleted state. To reuse the vault name or permanently remove the vault, purge it:
> ```powershell
> Remove-AzKeyVault -VaultName $secretsKeyVaultName -Location $location -InRemovedState -Force
> Remove-AzKeyVault -VaultName $encryptionKeyVaultName -Location $location -InRemovedState -Force
> ```

### 7.4 Delete Log Analytics Workspace (If No Longer Needed)

The Log Analytics workspace is shared across all host pools in the region. Only delete if **no remaining host pools** use it:

```powershell
$workspaceName = "log-avd-usgovvirginia"
$monitoringResourceGroupName = "rg-avd-monitoring-va"

# Check if any remaining host pools send diagnostics to this workspace
$hostPools = Get-AzWvdHostPool | Where-Object { $_.Location -eq $location }

if ($hostPools.Count -eq 0) {
    Write-Host "Deleting Log Analytics workspace: $workspaceName"
    Remove-AzOperationalInsightsWorkspace -ResourceGroupName $monitoringResourceGroupName -Name $workspaceName -Force
} else {
    Write-Host "⚠ Host pools still exist in region. Not deleting Log Analytics workspace."
}
```

> **Data Retention:** Log Analytics data is retained according to the workspace retention policy (default 30–730 days). Deleting the workspace does **not** immediately delete historical data. If compliance requires data retention, export logs before deletion or allow the retention period to expire naturally.

### 7.5 Delete Shared Resource Groups (If Empty)

If all shared resources have been deleted, remove the empty resource groups:

```powershell
$operationsResourceGroupName = "rg-avd-operations-va"
$monitoringResourceGroupName = "rg-avd-monitoring-va"
$controlPlaneResourceGroupName = "rg-avd-control-plane-va"

# Verify resource groups are empty
$operationsResources = Get-AzResource -ResourceGroupName $operationsResourceGroupName
$monitoringResources = Get-AzResource -ResourceGroupName $monitoringResourceGroupName
$controlPlaneResources = Get-AzResource -ResourceGroupName $controlPlaneResourceGroupName

if ($operationsResources.Count -eq 0) {
    Write-Host "Deleting operations resource group: $operationsResourceGroupName"
    Remove-AzResourceGroup -Name $operationsResourceGroupName -Force
} else {
    Write-Host "⚠ Operations resource group still has $($operationsResources.Count) resources. Not deleting."
}

if ($monitoringResources.Count -eq 0) {
    Write-Host "Deleting monitoring resource group: $monitoringResourceGroupName"
    Remove-AzResourceGroup -Name $monitoringResourceGroupName -Force
} else {
    Write-Host "⚠ Monitoring resource group still has $($monitoringResources.Count) resources. Not deleting."
}

if ($controlPlaneResources.Count -eq 0) {
    Write-Host "Deleting control plane resource group: $controlPlaneResourceGroupName"
    Remove-AzResourceGroup -Name $controlPlaneResourceGroupName -Force
} else {
    Write-Host "⚠ Control plane resource group still has $($controlPlaneResources.Count) resources. Not deleting."
}
```

---

## Step 8: Verify Complete Removal

After completing the decommissioning sequence, verify all resources and costs have been removed.

### 8.1 Verify Resource Removal

**Check for remaining resources:**
```powershell
$identifier = "hr"
$index = "01"
$location = "USGovVirginia"
$locationAbbreviation = "va"

# Search for resources matching the host pool identifier
$remainingResources = Get-AzResource | Where-Object { 
    $_.Name -like "*$identifier*" -and 
    $_.Name -like "*$index*" -and 
    $_.Location -eq $location 
}

if ($remainingResources.Count -eq 0) {
    Write-Host "✓ No resources found matching host pool identifier: $identifier-$index"
} else {
    Write-Host "⚠ Warning: $($remainingResources.Count) resource(s) still exist"
    $remainingResources | Select-Object Name, ResourceType, ResourceGroupName | Format-Table
}
```

**Check for remaining resource groups:**
```powershell
$allResourceGroups = Get-AzResourceGroup
$hostPoolResourceGroups = $allResourceGroups | Where-Object { 
    $_.ResourceGroupName -like "*$identifier*" -and 
    $_.ResourceGroupName -like "*$index*" 
}

if ($hostPoolResourceGroups.Count -eq 0) {
    Write-Host "✓ No resource groups found for host pool: $identifier-$index"
} else {
    Write-Host "⚠ Warning: $($hostPoolResourceGroups.Count) resource group(s) still exist"
    $hostPoolResourceGroups | Select-Object ResourceGroupName, Location, ProvisioningState | Format-Table
}
```

### 8.2 Verify Cost Reduction

**Check Azure Cost Management:**

1. Navigate to **Cost Management + Billing** > **Cost analysis**
2. Set scope to the subscription
3. Add filter: **Resource group** contains `$identifier-$index`
4. Set date range to last 30 days
5. Verify costs drop to zero after decommissioning date

**Query cost for specific resource groups:**
```powershell
# Requires Az.CostManagement module
$scope = "/subscriptions/{subscriptionId}"
$startDate = (Get-Date).AddDays(-7).ToString("yyyy-MM-dd")
$endDate = (Get-Date).ToString("yyyy-MM-dd")

$costData = Get-AzCostManagementCostData -Scope $scope -TimePeriod (New-Object -TypeName Microsoft.Azure.PowerShell.Cmdlets.CostManagement.Models.Api20211001.QueryTimePeriod -Property @{From=$startDate; To=$endDate})

# Filter to resource groups for this host pool
$hostPoolCosts = $costData | Where-Object { $_.ResourceGroup -like "*$identifier-$index*" }

if ($hostPoolCosts.Count -eq 0) {
    Write-Host "✓ No costs found for host pool resource groups"
} else {
    Write-Host "⚠ Warning: Costs still being incurred"
    $hostPoolCosts | Format-Table ResourceGroup, Cost, Date
}
```

> **Note:** Costs may lag by 24–48 hours in Azure Cost Management. Recently stopped or deleted resources may still appear in cost reports for 1–2 days.

### 8.3 Verify Backup Removal

Confirm no protected items remain for this host pool:

```powershell
# Check personal pool vault (if it existed)
$vaultName = "rsv-avd-va"
$vaultResourceGroupName = "rg-hr-01-hosts-va"

try {
    $vault = Get-AzRecoveryServicesVault -Name $vaultName -ResourceGroupName $vaultResourceGroupName -ErrorAction Stop
    Write-Host "⚠ Warning: Personal pool Recovery Services Vault still exists"
} catch {
    Write-Host "✓ Personal pool Recovery Services Vault has been deleted"
}

# Check shared vault for file share backups
$sharedVaultName = "rsv-avd-va"
$sharedVaultResourceGroupName = "rg-avd-operations-va"

$sharedVault = Get-AzRecoveryServicesVault -Name $sharedVaultName -ResourceGroupName $sharedVaultResourceGroupName
Set-AzRecoveryServicesVaultContext -Vault $sharedVault

$remainingItems = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $sharedVault.ID | 
    Where-Object { $_.FriendlyName -like "*$identifier*$index*" }

if ($remainingItems.Count -eq 0) {
    Write-Host "✓ No remaining file share backup items for host pool"
} else {
    Write-Host "⚠ Warning: $($remainingItems.Count) file share backup item(s) still protected"
    $remainingItems | Select-Object Name, FriendlyName, ProtectionStatus
}
```

### 8.4 Verify RBAC Cleanup

Check for remaining role assignments scoped to the deleted host pool:

```powershell
$hostPoolResourceId = "/subscriptions/{subscriptionId}/resourceGroups/{controlPlaneRG}/providers/Microsoft.DesktopVirtualization/hostPools/$hostPoolName"

try {
    $roleAssignments = Get-AzRoleAssignment -Scope $hostPoolResourceId -ErrorAction Stop
    
    if ($roleAssignments.Count -gt 0) {
        Write-Host "⚠ Warning: $($roleAssignments.Count) role assignment(s) still scoped to host pool"
        $roleAssignments | Select-Object DisplayName, RoleDefinitionName, Scope | Format-Table
    } else {
        Write-Host "✓ No role assignments remain"
    }
} catch {
    Write-Host "✓ Host pool resource no longer exists (RBAC cleanup automatic)"
}
```

> **Note:** Role assignments scoped to a deleted resource are automatically removed by Azure. This check is to identify any unexpected assignments.

---

## Special Scenarios

### Decommissioning Automated Host Pools

Automated host pools require a different sequence because Azure Virtual Desktop manages the VM lifecycle:

**Modified sequence for automated host pools:**

1. **Scale to zero hosts** — Set `instanceCount` to `0` in Session Host Management
2. **Wait for VM deletion** — Azure deletes VMs automatically (10–20 minutes)
3. **Delete Session Host Configuration** — Remove the `sessionHostConfigurations/default` resource
4. **Delete Session Host Management** — Remove the `sessionHostManagements/default` resource
5. **Proceed with standard sequence** — Follow Steps 3–8 above

**PowerShell for automated host pool specific resources:**
```powershell
$hostPoolName = "vdpool-avd-hr-01-usgovvirginia"
$resourceGroupName = "rg-avd-control-plane-va"

# Scale to zero (already covered in Step 2)
Update-AzWvdHostPoolSessionHostManagement `
    -HostPoolName $hostPoolName `
    -ResourceGroupName $resourceGroupName `
    -Name "default" `
    -InstanceCount 0

# Wait for VMs to be deleted
Start-Sleep -Seconds 600  # Wait 10 minutes

# Delete Session Host Configuration
Remove-AzWvdHostPoolSessionHostConfiguration `
    -HostPoolName $hostPoolName `
    -ResourceGroupName $resourceGroupName `
    -Name "default"

# Delete Session Host Management
Remove-AzWvdHostPoolSessionHostManagement `
    -HostPoolName $hostPoolName `
    -ResourceGroupName $resourceGroupName `
    -Name "default"

# Now proceed with host pool deletion (Step 5.3)
```

### Decommissioning Personal Host Pools

Personal host pools have unique considerations:

**Differences for personal host pools:**

- **VM backup** is stored in a **per-host-pool Recovery Services Vault** in the Hosts resource group (not shared)
- Each VM typically has a **dedicated user assignment** — verify users are notified
- Users may have **local data** on the OS disk outside of FSLogix — coordinate migration

**Additional steps for personal host pools:**

1. **Export user assignments** before decommissioning:
   ```powershell
   $hostPoolName = "vdpool-avd-hr-01-usgovvirginia"
   $resourceGroupName = "rg-avd-control-plane-va"
   
   $sessionHosts = Get-AzWvdSessionHost -HostPoolName $hostPoolName -ResourceGroupName $resourceGroupName
   
   $userAssignments = @()
   foreach ($sessionHost in $sessionHosts) {
       $userAssignments += [PSCustomObject]@{
           SessionHost = $sessionHost.Name
           AssignedUser = $sessionHost.AssignedUser
       }
   }
   
   $userAssignments | Export-Csv -Path ".\personal-pool-assignments.csv" -NoTypeInformation
   ```

2. **Coordinate with users** — Personal desktops often contain local state and data
3. **Delete per-host-pool RSV** — The Recovery Services Vault is in the Hosts resource group and will be deleted with the resource group

### Decommissioning Multi-Region Deployments

For host pools deployed across multiple regions:

**Additional considerations:**

- **Independent per-region cleanup** — Each region has its own shared resources
- **Cloud Cache storage** — If using Cloud Cache, remove remote storage references from remaining regions
- **Image Gallery replication** — Update gallery image replication regions if removing all host pools from a region

**Sequence for multi-region cleanup:**

1. Identify all regions where this host pool identifier exists
2. For each region, follow the standard decommissioning sequence
3. After all regions are decommissioned, clean up global resources (Image Gallery, global feed workspace)

### Decommissioning When Using Session Host Replacer

If the host pool used Session Host Replacer, remove the replacer resources first:

**Remove Session Host Replacer:**

1. Navigate to the Session Host Replacer resource group (typically `rg-avd-session-host-replacer-{location}`)
2. Delete the Function App, Storage Account, and Application Insights
3. Delete the Logic App or workflow that triggers the replacer
4. Proceed with standard host pool decommissioning

**PowerShell:**
```powershell
$replacerResourceGroupName = "rg-avd-session-host-replacer-va"

Write-Host "Deleting Session Host Replacer resource group: $replacerResourceGroupName"
Remove-AzResourceGroup -Name $replacerResourceGroupName -Force -AsJob
```

---

## Cost Optimization During Decommissioning

If you need to decommission incrementally or defer complete removal:

### Immediate Cost Reduction (Without Full Deletion)

**Stop VMs but keep resources:**
- Reduces compute costs to zero immediately
- Retains managed disk storage costs (~$0.048/GB/month for Standard HDD)
- Retains all configuration for potential restart

**Reduce backup retention:**
- Change backup policy to minimum retention (1 day for VMs, 1 day for file shares)
- Reduces backup storage costs while maintaining compliance

**Delete snapshots:**
- Remove any manual VM snapshots not managed by backup
- Snapshots cost ~$0.05/GB/month for Standard HDD

### Cost Comparison: Stop vs. Delete

| Resource | Stopped Cost | Deleted Cost | Savings |
| --- | --- | --- | --- |
| VM (D4s v3) | $0/month | $0/month | $0 (compute only billed when running) |
| Managed Disk (128 GB Premium SSD) | $19.71/month | $0/month | $19.71/month |
| FSLogix Storage (1 TB Premium) | $180/month | $0/month | $180/month |
| Backup (100 GB) | $10/month | $0/month | $10/month |
| **Total per host** | **$209.71/month** | **$0/month** | **$209.71/month** |

> **Recommendation:** For host pools that are no longer needed, proceed with full deletion. The cost savings of full decommissioning significantly outweigh the effort of redeployment if the host pool is needed again.

---

## Rollback and Recovery

### If You Need to Recover a Decommissioned Host Pool

If decommissioning was started in error or needs to be reversed:

**Before VMs are deleted:**
- **Stop the decommissioning process immediately**
- **Restart stopped VMs**
- **Re-enable scaling plans**
- **Remove drain mode** from session hosts

**After VMs are deleted but resource groups remain:**
- **Redeploy session hosts** using the original parameter file
- Storage and control-plane resources are intact, so only VMs need recreation
- Use the **Additional Session Hosts** add-on with the original host pool resource ID

**After resource groups are deleted:**
- **Full redeployment required** using the original parameter file
- User profile data is **lost** unless backup was retained
- FSLogix profiles can be restored from backup if retention period has not expired

### Backup Recommendations Before Decommissioning

To enable recovery after decommissioning:

1. **Export parameter files** — Save all deployment parameter files to a secure location
2. **Document configuration** — Capture host pool settings, app groups, RBAC assignments
3. **Extend backup retention** — Temporarily increase backup retention before stopping protection
4. **Export FSLogix profiles** (if required) — Use `azcopy` to copy profile VHDs to archive storage:
   ```powershell
   $sourceStorageAccount = "stfslogixhr01va"
   $sourceContainer = "profiles"
   $destinationStorageAccount = "starchivehr01va"
   $destinationContainer = "archive-hr-01-profiles"
   
   # Requires azcopy installed
   azcopy copy "https://$sourceStorageAccount.blob.core.windows.net/$sourceContainer/*" `
       "https://$destinationStorageAccount.blob.core.windows.net/$destinationContainer/" `
       --recursive
   ```

---

## Compliance and Audit Considerations

### Data Retention Requirements

Before decommissioning, verify compliance with:

| Framework | Typical Retention | Consideration |
| --- | --- | --- |
| **FedRAMP High** | 90 days – 1 year logs | Ensure Log Analytics retention meets requirements before deleting workspace |
| **NIST SP 800-53 (CP-9)** | 7 years backups for financial data | Extend backup retention or archive data before stopping protection |
| **IRS Publication 1075** | 7 years | Archive all FTI-related logs and backups before deletion |
| **HIPAA** | 6 years | Retain audit logs and backup data according to policy |
| **CMMC Level 2/3** | 90 days – 1 year | Verify SIEM has ingested and retained required logs |

### Audit Trail

Maintain an audit trail of the decommissioning process:

**Log the following:**
- Decommissioning date and time
- Identity of person performing decommissioning
- Business justification for decommissioning
- List of deleted resource groups and resources
- Backup retention decisions
- Cost reduction achieved

**PowerShell audit logging example:**
```powershell
$auditLog = @{
    Date = Get-Date
    PerformedBy = (Get-AzContext).Account.Id
    HostPool = $hostPoolName
    Identifier = $identifier
    Index = $index
    ResourceGroupsDeleted = @($hostResourceGroupName, $storageResourceGroupName)
    BackupRetention = "Extended to 180 days before deletion"
    CostReductionEstimate = "$10,500/month"
    Justification = "Project completion - users migrated to new consolidated host pool"
}

$auditLog | ConvertTo-Json | Out-File -FilePath ".\decommission-audit-$(Get-Date -Format 'yyyy-MM-dd').json"
```

---

## Frequently Asked Questions

### Can I decommission part of a host pool?

No. You cannot decommission individual session hosts and keep the host pool. However, you can:
- **Scale down** by reducing the number of session hosts
- **Drain and delete** specific session hosts without removing the host pool
- For automated host pools, reduce the `instanceCount`

To fully decommission, all session hosts and the host pool must be removed.

### What happens to user profile data when I delete FSLogix storage?

User profile data is **permanently deleted** when the storage account is deleted. To preserve data:
- **Archive profile VHDs** to another storage account before decommissioning
- **Extend backup retention** to allow recovery after decommissioning
- **Enable soft delete** on the storage account (14-day retention) to allow recovery of accidentally deleted shares

> **Note:** Soft delete is automatically disabled when backup is enabled on Azure Files. If you need both soft delete and backup, reconfigure after stopping backup.

### How long do soft-deleted Key Vaults persist?

Key Vaults enter a soft-deleted state for **7–90 days** (default 90 days with purge protection). During this period:
- The vault name is **reserved** and cannot be reused
- Keys and secrets remain **recoverable**
- The vault can be **restored** or **purged**

To reuse the vault name sooner, purge the soft-deleted vault:
```powershell
Remove-AzKeyVault -VaultName $vaultName -Location $location -InRemovedState -Force
```

### Can I recover a deleted host pool?

**Partially**, depending on what was deleted:

| Scenario | Recoverable | How to Recover |
| --- | --- | --- |
| Host pool deleted, VMs intact | ✅ Yes | Recreate host pool, register existing VMs |
| VMs deleted, storage intact | ✅ Yes | Redeploy VMs, profiles preserved |
| Resource groups deleted | ⚠️ Partial | Redeploy host pool, restore profiles from backup |
| Storage deleted, backup retained | ⚠️ Partial | Redeploy host pool, restore profiles from backup |
| Storage deleted, no backup | ❌ No | Full redeployment, profiles lost |

### Do I need to remove RBAC assignments manually?

No. Role assignments scoped to deleted resources are **automatically removed** by Azure. However, role assignments scoped to:
- **Resource groups** — Persist if the resource group still exists
- **Subscriptions** — Persist and must be manually removed
- **Management groups** — Persist and must be manually removed

### What if I need to retain logs but delete the Log Analytics workspace?

**Export logs before deletion:**

```powershell
# Export logs to storage account
$workspaceName = "log-avd-usgovvirginia"
$resourceGroupName = "rg-avd-monitoring-va"
$storageAccountName = "starchivehr01va"

# Configure continuous export
Set-AzOperationalInsightsDataExport `
    -ResourceGroupName $resourceGroupName `
    -WorkspaceName $workspaceName `
    -DataExportName "archive-export" `
    -TableNames @("WVDConnections", "WVDCheckpoints", "WVDErrors", "WVDManagement") `
    -ResourceId "/subscriptions/{subscriptionId}/resourceGroups/{rgName}/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
```

Alternatively, use **Azure Data Explorer (ADX)** or **Azure Monitor Logs Archive** for long-term retention.

### How do I decommission host pools in air-gapped clouds?

Follow the same process with these considerations:
- **No portal access** — Use PowerShell or Azure CLI exclusively
- **No Blue Button** — All operations must be scripted
- **Backup retention** — Verify offline backup policies before deletion
- **Artifact cleanup** — Remove transferred artifacts from air-gapped storage accounts

---

## Summary Checklist

Use this checklist to track decommissioning progress:

- [ ] **Pre-Decommissioning**
  - [ ] Users notified and migrated
  - [ ] Stakeholder approval obtained
  - [ ] Backups verified and retention extended (if required)
  - [ ] Dependencies documented
  - [ ] Compliance requirements reviewed

- [ ] **Step 1: Drain Users**
  - [ ] Drain mode enabled on all session hosts
  - [ ] Active sessions monitored until zero
  - [ ] Users logged off or force disconnected

- [ ] **Step 2: Stop/Delete Session Hosts**
  - [ ] VMs stopped or deleted
  - [ ] Automated host pools scaled to zero instances

- [ ] **Step 3: Remove Backup Protection**
  - [ ] VM backup stopped and recovery points deleted
  - [ ] FSLogix file share backup stopped and recovery points deleted
  - [ ] Backup removal verified

- [ ] **Step 4: Delete Per-Host-Pool Resources**
  - [ ] Host resource group deleted
  - [ ] Storage resource group deleted
  - [ ] Deletion jobs monitored and completed

- [ ] **Step 5: Remove Control-Plane Resources**
  - [ ] Scaling plans deleted (if dedicated)
  - [ ] Application groups deleted
  - [ ] Host pool deleted
  - [ ] Workspace deleted (if dedicated)

- [ ] **Step 6: Clean Up Encryption**
  - [ ] CMK keys identified for this host pool
  - [ ] CMK keys deleted (if not shared)
  - [ ] Key deletion verified

- [ ] **Step 7: Clean Up Shared Resources (If Applicable)**
  - [ ] Verified no other host pools in region
  - [ ] Shared Recovery Services Vault deleted (if empty)
  - [ ] Key Vaults deleted (if empty)
  - [ ] Log Analytics workspace deleted (if no longer needed)
  - [ ] Shared resource groups deleted (if empty)

- [ ] **Step 8: Verification**
  - [ ] No remaining resources found
  - [ ] Cost reduction confirmed
  - [ ] Backup removal verified
  - [ ] RBAC cleanup confirmed
  - [ ] Audit log created

- [ ] **Post-Decommissioning**
  - [ ] Parameter files archived
  - [ ] Documentation updated
  - [ ] Stakeholders notified of completion
  - [ ] Compliance records updated

---

## Related Documentation

- [Host Pool Deployment](hostpool-deployment.md) — Deployment reference
- [Design](design.md) — Resource group organization and naming
- [BCDR](bcdr.md) — Business continuity and disaster recovery
- [Chargeback for Shared Resources](chargeback-shared-resources.md) — Cost attribution queries
- [Session Host Replacer](session-host-replacer.md) — Automated VM refresh
- [Troubleshooting](troubleshooting.md) — Common issues and solutions

---

## Feedback and Support

If you encounter issues during decommissioning or have suggestions for improving this guide:

- **Report issues:** [GitHub Issues](https://github.com/Azure/FederalAVD/issues)
- **Troubleshooting:** See [Troubleshooting Guide](troubleshooting.md)
- **Azure Support:** For Azure platform issues, open a support ticket in the Azure portal

---

**Document Version:** 1.0  
**Last Updated:** 2026-09-09  
**Applies To:** FederalAVD v1.x (Standard and Automated Host Pools)
