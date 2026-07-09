[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Troubleshooting

## Top 5 First-Deployment Mistakes {#top-5-first-deployment-mistakes}

The most common errors on a first FederalAVD deployment. Each links to a full symptom → problem → fix section below.

> **Pre-flight tip:** Run `tools/Test-AvdVmSize.ps1 -Location <your-region>` before deploying to catch VM size availability and vCPU quota issues before they fail a 20-minute deployment. See [vCPU Quota Exhaustion](#vcpu-quota-exhaustion).

1. [Storage data-plane RBAC — 403 when uploading artifacts](#storage-blob-data-access-fails-with-403)
2. [Key Vault Crypto Officer missing — CMK deployment fails with Forbidden](#key-vault-crypto-officer-missing)
3. [timeStamp in parameter file causes stale versions or naming conflicts](#timestamp-in-parameter-file-causes-stale-image-versions)
4. [Editing `customer-examples/` instead of `customer/parameters/` — changes disappear on git pull](#editing-customerexamples-or-missing-customer-changes)
5. [Image Management deployed before Key Vaults — CMK encryption fails](#cmk-deployment-fails-image-management-deployed-before-key-vaults)

---

## Role Assignment Failure

### Symptom

You receive an error similar to the following:

```json
{
    "status": "Failed",
    "error": {
        "code": "RoleAssignmentUpdateNotPermitted",
        "message": "Tenant ID, application ID, principal ID, and scope are not allowed to be updated."
    }
}
```

### Problem

This error means ARM attempted to PUT a role assignment resource at a specific GUID, but that GUID already exists with different immutable properties (principal ID, tenant ID, or scope). There are two common causes:

**Cause 1 — Orphaned role assignment.** A role assignment exists whose principal (user, group, service principal, or managed identity) has since been deleted. ARM uses a deterministic GUID formula (`guid(scope, principalId, roleDefinitionId)`) to name role assignments. If the managed identity was deleted and recreated, the new principal has a different object ID, which changes the deterministic GUID ARM wants to use — but the old GUID (pointing at the now-deleted principal) may still exist, and ARM cannot update its `principalId`.

**Cause 2 — Portal-created assignment at a conflicting GUID.** If someone manually created a role assignment through the portal, Azure generates a random GUID for it. If that random GUID happens to match the deterministic GUID this solution's ARM template computes for a *different* role assignment (different role, principal, or scope), ARM will try to overwrite an immutable field on the portal-created assignment and fail. More commonly, the portal assignment creates a *duplicate* for the same principal+role+scope combination, which ARM then cannot reconcile with its own resource.

### Solution

**Step 1 — Find and remove orphaned assignments** (principal no longer exists):

```powershell
$orphanedRoleAssignments = Get-AzRoleAssignment | Where-Object -Property DisplayName -eq $null
if ($orphanedRoleAssignments.Count -eq 0) {
    Write-Output "No orphaned role assignments found."
} else {
    Write-Output "Found $($orphanedRoleAssignments.Count) orphaned role assignment(s)."
    $orphanedRoleAssignments | ForEach-Object {
        Write-Output "Removing: RoleAssignmentId=$($_.RoleAssignmentName) | ObjectId=$($_.ObjectId) | Role=$($_.RoleDefinitionName) | Scope=$($_.Scope)"
        Remove-AzRoleAssignment -ObjectId $_.ObjectId -RoleDefinitionName $_.RoleDefinitionName -Scope $_.Scope
    }
}
```

**Step 2 — Find and remove portal-created duplicates** for a specific principal+role+scope:

```powershell
# Substitute the values from your failed deployment
$scope           = '/subscriptions/<subscriptionId>/resourceGroups/<resourceGroupName>'
$roleDefinition  = 'Contributor'   # e.g. Contributor, Key Vault Crypto Officer
$principalId     = '<objectId>'    # object ID of the managed identity or service principal

# List ALL assignments for this combination — there should be exactly one
Get-AzRoleAssignment -Scope $scope -RoleDefinitionName $roleDefinition -ObjectId $principalId |
    Format-List RoleAssignmentName, RoleDefinitionName, ObjectId, Scope, DisplayName

# Remove any duplicates (keep at most one, or remove all and let ARM recreate)
Get-AzRoleAssignment -Scope $scope -RoleDefinitionName $roleDefinition -ObjectId $principalId |
    ForEach-Object {
        Write-Output "Removing assignment: $($_.RoleAssignmentName)"
        Remove-AzRoleAssignment -RoleAssignmentId $_.RoleAssignmentId
    }
```

After removing the conflicting assignment(s), redeploy — ARM will recreate the assignment at its deterministic GUID.

## Redeployment

If you need to redeploy this solution due to an error or to add resources, be sure the virtual machines (aka session hosts) are turned on.  For "pooled" host pools, you must disable scaling as well.  If the virtual machines are shutdown, the deployment will fail since virtual machine extensions cannot be updated when virtual machines are in a shutdown state.

If you existing deployment resource groups, you should delete the virtual machine in this resource group in order to ensure a fresh virtual machine is used to run the deployment scripts leveraged by this solution.

## WinError 193

### Symptom

[WinError 193] %1 is not a valid Win32 application
... missing tolower

### Problem

Corrupt Bizep Install

### Solution

Reinstall Bicep by following the steps at [Bicep Installation](quick-start.md#bicep-installation)

## Encryption at Host Not Enabled

### Symptom

Deployment fails with an error similar to:

```
Encryption at host is not enabled for this subscription.
To enable it, register the 'EncryptionAtHost' feature for provider 'Microsoft.Compute'.
```

### Problem

`encryptionAtHost: true` is the default in this solution for hostpool, imageBuild, and sessionHosts deployments. This feature must be explicitly registered on the subscription before any VMs using it can be deployed. The registration is a one-time operation per subscription.

### Solution

Register the feature and wait for it to complete before redeploying:

```powershell
Register-AzProviderFeature -FeatureName EncryptionAtHost -ProviderNamespace Microsoft.Compute

# Check registration state — wait until RegistrationState is 'Registered' (can take a few minutes)
Get-AzProviderFeature -FeatureName EncryptionAtHost -ProviderNamespace Microsoft.Compute
```

Once `RegistrationState` shows `Registered`, redeploy. If you cannot enable this feature in your environment, set `encryptionAtHost: false` in your parameters file.

## Key Vault Name Conflict After Cleanup

### Symptom

Deployment fails with an error similar to:

```
A vault with the same name already exists in deleted state.
You need to either recover or purge existing key vault before creating the new one.
```

### Problem

Azure Key Vault names are globally unique and retained in soft-deleted state for 7–90 days after deletion (default is 90 days with purge protection enabled). If a previous deployment created a Key Vault with the same name and it was subsequently deleted, the name is unavailable until the soft-deleted vault is purged.

### Solution

Recover or purge the soft-deleted vault before redeploying:

```powershell
# List soft-deleted Key Vaults
Get-AzKeyVault -InRemovedState

# Option 1: Recover the vault (restores it to the original resource group)
Undo-AzKeyVaultRemoval -VaultName 'kv-avd-enc-abc123-va' -ResourceGroupName 'rg-avd-operations-va' -Location 'usgovvirginia'

# Option 2: Purge the vault permanently (irreversible — use only if recovery is not needed)
Remove-AzKeyVault -VaultName 'kv-avd-enc-abc123-va' -InRemovedState -Location 'usgovvirginia' -Force
```

> **Note:** Purging a Key Vault is irreversible. All keys, secrets, and certificates in the vault are permanently deleted. Only purge if you are certain the vault contents are no longer needed.

### Prevention

In test or development environments, set the retention period to the minimum (7 days) so that a deleted vault's name becomes purgeable sooner. Set `secretsKeyVaultRetentionInDays: 7` and `encryptionKeyVaultRetentionInDays: 7` in your parameters file. Keep the default of `90` in production.

## RBAC Propagation Delay

### Symptom

A deployment that succeeds on subsequent runs fails on the first run with a 403 or `AuthorizationFailed` error, typically during a Run Command or storage access step shortly after role assignments are created.

### Problem

Azure role assignments can take several minutes to propagate through the authorization system after being created. This solution creates managed identity role assignments early in the deployment (e.g., Storage Blob Data Contributor, Key Vault Crypto Officer) and then immediately uses those identities in later stages. In some environments — particularly fresh subscriptions or subscriptions with slow RBAC replication — the propagation window exceeds the deployment stage gap.

### Solution

Simply redeploy. The role assignments are already in place from the first run and will be fully propagated by the time the second deployment reaches the failing stage. No changes to parameters are needed.

If the failure recurs consistently, check that the managed identity being used is the correct one — a mismatch between the identity expected by the deployment and the one that holds the role is a common cause of persistent 403 errors.

## vCPU Quota Exhaustion

### Symptom

Deployment fails with an error similar to:

```
Operation could not be completed as it results in exceeding approved Total Regional Cores quota.
Location: usgovvirginia, Current Limit: 10, Current Usage: 8, Additional Required: 4.
```

### Problem

Azure subscriptions, particularly in government cloud environments, have per-region vCPU quotas that may be lower than commercial defaults. Deploying multiple session hosts, a deployment VM, or a high-vCPU image build VM can exhaust the available quota.

### Quick check before deploying

Run `tools/Test-AvdVmSize.ps1` to check availability, zone restrictions, and vCPU quota in about 30 seconds — before committing to a full deployment run:

```powershell
# From the repo root, with an active Azure session
.\tools\Test-AvdVmSize.ps1 -Location '<your-region>'

# Override defaults to match your parameter file
.\tools\Test-AvdVmSize.ps1 -VmSize Standard_D8ads_v5 -Location usgovvirginia -SessionHostCount 5
```

The script checks the VM family quota and the total regional vCPU quota and prints `[PASS]` / `[FAIL]` / `[WARN]` for each check. If any check fails it prints the exact remediation options.

### Solution

Check current usage and submit a quota increase request:

```powershell
# Check current vCPU usage and limits for a region
Get-AzVMUsage -Location 'usgovvirginia' |
    Where-Object { $_.Name.Value -like '*cores*' -or $_.Name.Value -like '*vCPUs*' } |
    Select-Object @{n='Name';e={$_.Name.LocalizedValue}}, CurrentValue, Limit |
    Format-Table -AutoSize
```

To request a quota increase, go to **Azure Portal → Subscriptions → [your subscription] → Usage + quotas**, filter by the region and VM family, and select **Request Increase**. In government cloud, quota increase requests may require coordination with your cloud broker or sponsor.

As a short-term workaround, reduce `sessionHostCount` or switch to a smaller `virtualMachineSize` that uses fewer vCPUs per VM. Run `tools/Get-AvailableVMSkus.ps1 -Region <location>` to see all VM sizes available in the region.

## Host Pool Registration Token Expired

### Symptom

Session hosts deploy successfully but never appear as **Available** in the host pool — they remain in an **Unavailable** or **Needs Assistance** state. The AVD agent on the VM may log errors indicating the registration token is invalid or expired.

### Problem

The host pool registration token embedded in the deployment has a maximum validity of 27 days. If the token was generated well before deployment started, or if the deployment ran slowly and the token expired mid-deployment, session hosts will fail to register with the host pool broker.

### Solution

Generate a fresh registration token and redeploy the session hosts:

```powershell
# Generate a new token valid for 2 hours
$expiry = (Get-Date).ToUniversalTime().AddHours(2).ToString('yyyy-MM-ddTHH:mm:ssZ')
New-AzWvdRegistrationInfo -ResourceGroupName 'rg-avd-control-plane-va' `
    -HostPoolName 'vdpool-avd-01-va' `
    -ExpirationTime $expiry

# Retrieve the new token value
(Get-AzWvdHostPoolRegistrationToken -ResourceGroupName 'rg-avd-control-plane-va' `
    -HostPoolName 'vdpool-avd-01-va').Token
```

Pass the new token in your parameters file as `hostPoolRegistrationToken` and redeploy only the session hosts (use the session hosts add-on rather than a full host pool redeployment to avoid recreating control plane resources).

## Run Commands Stuck or Blocking Redeployment

### Symptom

A deployment fails with a conflict or overwrite error on a Run Command resource, or redeployment of the `runCommandsOnVms` add-on or session hosts add-on fails because a Run Command with the same name already exists on one or more VMs.

### Problem

Azure VM Run Commands are persistent ARM resources (`Microsoft.Compute/virtualMachines/runCommands`). If a deployment failed or was interrupted, the Run Command resource remains on the VM in a `Running`, `Failed`, or `Succeeded` state. ARM uses the Run Command name as a unique key per VM, so re-deploying the same command while the resource still exists causes a conflict. Each VM also has a per-VM limit on the total number of Run Commands (~25); repeated deployments without cleanup can exhaust this limit.

### Solution

Remove the Run Command resources before redeploying. The VM does not need to be running to delete a Run Command ARM resource.

**PowerShell (Az module):**

```powershell
# List all run commands on a VM
Get-AzVMRunCommand -ResourceGroupName 'rg-avd-sessionhosts' -VMName 'avd-vm-01'

# Remove a specific run command by name
Remove-AzVMRunCommand -ResourceGroupName 'rg-avd-sessionhosts' -VMName 'avd-vm-01' -RunCommandName 'DoD-STIGs-202604'

# Remove ALL run commands from a single VM
Get-AzVMRunCommand -ResourceGroupName 'rg-avd-sessionhosts' -VMName 'avd-vm-01' |
    ForEach-Object {
        Remove-AzVMRunCommand -ResourceGroupName 'rg-avd-sessionhosts' -VMName 'avd-vm-01' -RunCommandName $_.Name
    }

# Remove all run commands from multiple VMs
$resourceGroupName = 'rg-avd-sessionhosts'
$vmNames = @('avd-vm-01', 'avd-vm-02', 'avd-vm-03')
foreach ($vmName in $vmNames) {
    Get-AzVMRunCommand -ResourceGroupName $resourceGroupName -VMName $vmName |
        ForEach-Object {
            Remove-AzVMRunCommand -ResourceGroupName $resourceGroupName -VMName $vmName -RunCommandName $_.Name
        }
}
```

**Azure CLI:**

```bash
# List all run commands on a VM
az vm run-command list --resource-group rg-avd-sessionhosts --vm-name avd-vm-01

# Remove a specific run command
az vm run-command delete --resource-group rg-avd-sessionhosts --vm-name avd-vm-01 --name DoD-STIGs-202604 --yes

# Remove all run commands from a VM
az vm run-command list --resource-group rg-avd-sessionhosts --vm-name avd-vm-01 \
  --query '[].name' -o tsv | \
  xargs -I{} az vm run-command delete \
    --resource-group rg-avd-sessionhosts --vm-name avd-vm-01 --name {} --yes
```

**Azure portal:**

1. Navigate to the VM in the Azure portal.
2. Under **Operations**, select **Run command**.
3. Select the **Managed** tab to view persistent Run Command resources.
4. Click the run command to open it, then select **Delete**.

---

## Storage Blob Data Access Fails with 403 {#storage-blob-data-access-fails-with-403}

### Symptom

Running `Update-ImageArtifacts.ps1` or `Deploy-ImageManagement.ps1` (or any script that uploads to the artifacts or build-logs storage account) fails with:

```
403 AuthorizationFailure
This request is not authorized to perform this operation using this permission.
```

or

```
AuthorizationFailed: The client '…' does not have authorization to perform action
'Microsoft.Storage/storageAccounts/…'
```

### Problem

Azure Storage accounts in this solution have **shared key access disabled by default** (`allowSharedKeyAccess: false`). In this mode, data-plane operations (reading and writing blobs) require an explicit data-plane role. The `Owner` and `Contributor` built-in roles are **control-plane only** — they do not grant blob read/write access when shared key is disabled.

### Solution

Assign the appropriate data-plane role to the identity that runs the upload or deployment scripts:

| Operation | Required role | Scope |
|---|---|---|
| Upload artifacts (`Update-ImageArtifacts.ps1`) | **Storage Blob Data Contributor** | Artifacts storage account |
| Image build log collection | **Storage Blob Data Contributor** | Build logs storage account |
| Image build reads artifacts | **Storage Blob Data Reader** | Artifacts storage account |

```powershell
# Example: grant Storage Blob Data Contributor on the artifacts storage account to your user
$storageAccountId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>'
$principalId      = (Get-AzADUser -UserPrincipalName (Get-AzContext).Account.Id).Id

New-AzRoleAssignment -ObjectId $principalId `
    -RoleDefinitionName 'Storage Blob Data Contributor' `
    -Scope $storageAccountId
```

After assigning the role, wait a few minutes for RBAC propagation (see [RBAC Propagation Delay](#rbac-propagation-delay)) then retry.

---

## Key Vault Crypto Officer Missing — CMK Deployment Fails with Forbidden {#key-vault-crypto-officer-missing}

### Symptom

A deployment that uses Customer-Managed Keys (CMK) fails with:

```
Forbidden: The user, group, or application does not have keys get/wrapKey/unwrapKey permission
on key vault '…'.
```

or similar 403/Forbidden errors against Key Vault key operations.

### Problem

Key Vault operates a **data-plane permission model separate from Azure RBAC control-plane**. `Owner` and `Contributor` grant management rights over the Key Vault resource itself but do **not** grant permission to perform key operations (Get, WrapKey, UnwrapKey) on keys stored inside the vault when the vault uses Azure RBAC authorization (`enableRbacAuthorization: true`, which is the default in this solution).

### Solution

Add the **`Key Vault Crypto Officer`** role to the deploying identity (or the managed identity performing encryption) scoped to the encryption Key Vault:

```powershell
$keyVaultId  = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>'
$principalId = (Get-AzADUser -UserPrincipalName (Get-AzContext).Account.Id).Id

New-AzRoleAssignment -ObjectId $principalId `
    -RoleDefinitionName 'Key Vault Crypto Officer' `
    -Scope $keyVaultId
```

For service principals or managed identities used in automation pipelines, assign the same role to the identity performing the deployment.

---

## timeStamp in Parameter File Causes Stale Image Versions {#timestamp-in-parameter-file-causes-stale-image-versions}

### Symptom

A new image build or host pool deployment runs but the resulting image gallery version or deployment resource name reuses a value from a previous run. Subsequent deployments may fail with a naming conflict, or image versions are not auto-incremented as expected.

### Problem

The `timeStamp` parameter is intentionally excluded from example parameter files — it is generated fresh on every deployment run by the calling script or at deploy time. If you export a parameter file from a Template Spec UI deployment or from an ARM deployment history, the exported file includes the `timeStamp` value that was used in that specific run. Saving and reusing that file causes every subsequent deployment to supply the same fixed timestamp.

### Solution

After generating or exporting a parameter file, **remove the `timeStamp` entry** before saving it for reuse:

1. Open the parameter file in a text editor.
2. Delete the line that contains `"timeStamp"` (and its associated `"value"` pair).
3. Save the file. On the next deployment the value will be auto-generated.

```json
// Remove this block from your saved parameters file:
"timeStamp": {
    "value": "2026.0210.1435"
}
```

---

## Editing customer-examples/ Instead of customer/ — Changes Missing or Overwritten {#editing-customerexamples-or-missing-customer-changes}

### Symptom

- You edited a parameter file or artifact and the changes are gone after a `git pull`.
- A parameter file you modified does not appear in `git status`.
- You committed and pushed, but the file you changed is not in the remote repo.

### Problem

The `customer/` folder is **git-ignored by design** (via `.gitignore`). It is intended to hold your environment-specific, potentially sensitive configuration that should never be committed to the shared repo. However, `customer-examples/` *is* tracked — it contains the reference examples shipped with the solution. If you edit files inside `customer-examples/` directly, those changes **will** be overwritten the next time the repo is updated.

### Solution

Always copy example files into the appropriate `customer/` subfolder before editing:

```powershell
# Copy a host pool parameter example to your working location
Copy-Item customer-examples/parameters/hostpools/hostpool.parameters.example.json `
          customer/parameters/hostpools/myenv.parameters.json
```

- Edit only files under `customer/parameters/`, `customer/artifacts/`, etc.
- Do not edit files under `customer-examples/` unless you are intentionally updating the reference example for others (rare).
- If you need to version-control your customer files, manage that in a separate private repo and reference it alongside this repo.

---

## CMK Deployment Fails — Image Management Deployed Before Key Vaults {#cmk-deployment-fails-image-management-deployed-before-key-vaults}

### Symptom

The Image Management deployment (`Deploy-ImageManagement.ps1` / Step 2) fails with an error such as:

```
Resource 'kv-avd-enc-…' was not found.
```

or the compute gallery or storage account is created without CMK encryption even though `customerManagedKeys: true` was set in the parameters.

### Problem

When using Customer-Managed Keys, the Image Management template needs the Key Vault resource ID at deployment time to configure encryption on the compute gallery and storage account. If the Key Vault does not yet exist, the resource reference fails. Deploying Step 2 before Step 1 is the most common cause.

### Solution

Follow the documented deployment sequence when using CMK:

```
Step 1 (keyVaults)  →  Step 2 (imageManagement)  →  Step 3 (imageBuild, optional)  →  Step 4 (hostpool)
```

Deploy Key Vaults (Step 1) first, wait for it to succeed, then proceed to Image Management (Step 2). If you have already deployed Image Management without CMK and want to enable it, redeploy Image Management after Step 1 is complete — the template is idempotent and will update the encryption settings.
