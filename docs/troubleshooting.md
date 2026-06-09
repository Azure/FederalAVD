[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Troubleshooting

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

As a short-term workaround, reduce `sessionHostCount` or switch to a smaller `virtualMachineSize` that uses fewer vCPUs per VM.

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
