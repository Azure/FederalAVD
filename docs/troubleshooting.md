[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Troubleshooting

## Top 5 First-Deployment Mistakes {#top-5-first-deployment-mistakes}

The most common errors on a first FederalAVD deployment. Each links to a full symptom → problem → fix section below.

> **Pre-flight tip:** Run `tools/Test-AvdVmSize.ps1 -Location <your-region>` before deploying to catch VM size availability and vCPU quota issues before they fail a 20-minute deployment. See [vCPU Quota Exhaustion](#vcpu-quota-exhaustion).

1. [Storage data-plane RBAC — 403 when uploading artifacts](#storage-blob-data-access-fails-with-403)
2. [Key Vault Crypto Officer missing — CMK deployment fails with Forbidden](#key-vault-crypto-officer-missing)
3. [timeStamp in parameter file causes stale versions or naming conflicts](#timestamp-in-parameter-file-causes-stale-image-versions)
4. [Editing `customer-examples/` instead of `customer/parameters/` — changes disappear on git pull](#editing-customerexamples-or-missing-customer-changes)
5. [Image Management deployed before AVD Shared Services — CMK encryption fails](#cmk-deployment-fails-image-management-deployed-before-key-vaults)

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

```text
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

```text
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

## Managed Identity Token Request Fails with HTTP 400

### Symptom

A private customization or artifact download fails and its log contains messages such as:

```text
Category=IdentityUnavailable; HTTP=400
Managed identity token request failed after 12 attempts.
```

### Problem

HTTP 400 from the Azure Instance Metadata Service (IMDS) is ambiguous. It can mean that the
requested user-assigned identity is not attached to the VM, the supplied client ID is wrong, or a
newly attached identity has not propagated to IMDS yet. This happens before Storage RBAC is
evaluated, so adding a Storage role does not correct an IMDS HTTP 400.

FederalAVD private customizations retry transient IMDS failures for up to 12 attempts with a
10-second delay. A failure after all attempts usually indicates an attachment or client-ID problem
rather than a short propagation delay.

### Solution

Confirm that the expected user-assigned identity is attached to the affected VM:

```powershell
az vm identity show `
    --resource-group '<session-host-resource-group>' `
    --name '<vm-name>' `
    --output json
```

Compare the attached identity's `clientId` with the customization deployment's
`UserAssignedIdentityClientId`. Also confirm that VM routing or proxy configuration does not send
the link-local IMDS address `169.254.169.254` through a proxy or virtual appliance.

For a newly attached identity, wait several minutes and rerun the failed customization or policy
remediation. If the identity is absent, correct the policy or deployment parameters that supply
`artifactsUserAssignedIdentityResourceId` and redeploy.

Customization logs are written to `C:\Windows\Logs\<customization-name>.log` on the VM.

## LinkedAuthorizationFailed for DES, DCR, or DCE

### Symptom

Deployment or Azure Policy remediation fails with `LinkedAuthorizationFailed`. The message names a
principal that can modify the target VM or association but cannot read or use a linked resource
such as a Disk Encryption Set (DES), Data Collection Rule (DCR), or Data Collection Endpoint (DCE).

### Problem

Authorization on the session-host resource group does not automatically grant access to resources
linked from a VM or monitoring association. The identity named in the error needs permission at the
linked resource scope, which can be in another resource group or subscription.

For automated host pools, the relevant identities and minimum linked-resource roles are:

| Identity | Linked resource | Required role |
| --- | --- | --- |
| Automated host-pool managed identity | Existing DES | Reader |
| Automated policy assignment identity | DCR | Reader |
| Automated policy assignment identity | DCE | Monitoring Contributor |

### Solution

Read the error's `client` or principal object ID and `linked scope`; do not assume the deployment
operator is the failing identity. Verify the assignment directly on the linked resource:

```powershell
Get-AzRoleAssignment `
    -ObjectId '<principal-object-id-from-error>' `
    -Scope '<linked-resource-id-from-error>' |
    Format-Table RoleDefinitionName, Scope
```

Redeploy the current automated host-pool template to create the expected assignments. If approved
existing resources are supplied from a scope where the deployment cannot create role assignments,
have the resource owner grant the role shown above and then rerun the failed deployment or policy
remediation.

## vCPU Quota Exhaustion

### Symptom

Deployment fails with an error similar to:

```text
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

### Automated scaling plan is absent after a failed deployment

An automated host-pool deployment can have `deployDynamicScalingPlan: true` while the overall
deployment fails on another parallel branch. Inspect deployment operations before diagnosing the
scaling configuration itself. `SkuNotAvailable` on the temporary FSLogix deployment helper, for
example, is a VM capacity failure rather than a scaling-plan failure.

Current automated templates deploy scaling as a control-plane branch after the host pool and AVD
service-principal RBAC. It does not depend on FSLogix, policy, or session-host provisioning. For
older Template Spec versions that serialized scaling after provisioning, publish the current
template and redeploy. Select an available deployment-helper size when the failed operation reports
`SkuNotAvailable`.

## Automated Hosts Remain Non-Compliant After Creation

### Symptom

New dynamically created session hosts appear in the host pool, but one or more expected settings
are temporarily absent, including monitoring associations, private customizations, managed-disk
network restrictions, or other automated-host policy settings.

### Problem

Automated host-pool policies use `AfterProvisioningSuccess` evaluation delay. Azure first completes
VM provisioning, then evaluates DeployIfNotExists or Modify assignments. Policy evaluation,
managed-identity role propagation, and remediation deployments are asynchronous, so the VM can be
visible before all settings are applied.

### Solution

In the Azure portal, open **Policy > Compliance**, select the assignment scoped to the automated
session-host resource group, and inspect the component policy state and latest deployment. Allow an
initial evaluation interval before treating the host as failed.

If the resource remains non-compliant, trigger a resource-group compliance scan:

```powershell
Start-AzPolicyComplianceScan -ResourceGroupName '<session-host-resource-group>'
```

After the scan completes, create a remediation task for the non-compliant assignment in the portal.
Inspect the nested remediation deployment before retrying; an authorization, identity attachment,
artifact download, or VM provisioning error requires correcting that cause rather than repeatedly
starting remediation.

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

```text
403 AuthorizationFailure
This request is not authorized to perform this operation using this permission.
```

or

```text
AuthorizationFailed: The client '…' does not have authorization to perform action
'Microsoft.Storage/storageAccounts/…'
```

### Problem

Azure Storage accounts in this solution have **shared key access disabled by default** (`allowSharedKeyAccess: false`). In this mode, data-plane operations (reading and writing blobs) require an explicit data-plane role. The `Owner` and `Contributor` built-in roles are **control-plane only** — they do not grant blob read/write access when shared key is disabled.

### Solution

Assign the appropriate data-plane role to the identity that runs the upload or deployment scripts:

| Operation | Required role | Scope |
| --- | --- | --- |
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

## Entra Kerberos Private-Endpoint Configuration Fails with HTTP 404

### Symptom

Azure Files storage deployment reaches NTFS permission configuration but fails with HTTP 404 when
Entra ID Kerberos and a private endpoint are enabled.

### Problem

The storage account enterprise application's identifier URIs must include the private-link FQDN
before NTFS permission configuration authenticates through that endpoint. FederalAVD updates the
application manifest before setting NTFS permissions and grants application consent afterward.

### Solution

Confirm the managed Run Commands executed in this order:

1. Storage application manifest update
2. NTFS permission configuration
3. Storage application consent grant

Review these logs on the temporary deployment VM:

```text
C:\Windows\Logs\Update-StorageAccountApplicationManifest-*.log
C:\Windows\Logs\Set-NtfsPermissionsAzureFiles-*.log
C:\Windows\Logs\Grant-StorageAccountApplicationConsent-*.log
```

If the manifest update failed, verify that the deployment identity has the documented Microsoft
Graph permissions and that the private endpoint FQDN resolves from the deployment VM. Correct that
failure and redeploy; do not run NTFS permission configuration before the manifest update succeeds.

## Dynamic Scaling Cannot Create Session Hosts

### Symptom

An automated host pool deploys successfully, but its dynamic scaling plan cannot create new session
hosts or retrieve the domain-join credentials.

### Problem

The tested create/delete autoscale path submits Compute VM creation as the host-pool managed
identity, not as the deployment operator or policy identity. The Azure Virtual Desktop enterprise
application separately needs subscription-level scaling-plan orchestration roles and Key Vault
secret access. Its application ID is `9cdead84-a844-4324-93f2-b2e6bb768d07`; its object ID is
tenant-specific and must not be copied from another tenant.

### Solution

Resolve the enterprise application's object ID in the deployment tenant:

```powershell
$avdServicePrincipalObjectId = az ad sp list `
    --filter "appId eq '9cdead84-a844-4324-93f2-b2e6bb768d07'" `
    --query '[0].id' `
    --output tsv
```

Supply that value as `avdServicePrincipalObjectId` and redeploy. For create/delete dynamic scaling,
the template assigns **Desktop Virtualization Power On Off Contributor** and **Desktop
Virtualization Virtual Machine Contributor** at subscription scope, plus **Key Vault Secrets User**
on the credentials Key Vault. Verify those assignments if host creation still fails.
Also verify that the host-pool managed identity has its resource-scoped VM, network, image, host
pool, credentials Key Vault, and optional Disk Encryption Set roles.

---

## Key Vault Crypto Officer Missing — CMK Deployment Fails with Forbidden {#key-vault-crypto-officer-missing}

### Symptom

A deployment that uses Customer-Managed Keys (CMK) fails with:

```text
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

A new image build runs but the resulting image gallery version or temporary build resource name reuses a value from a previous run. Subsequent builds may fail with a naming conflict, or image versions are not auto-incremented as expected.

### Problem

The Image Build `timeStamp` parameter is intentionally excluded from example parameter files - it is generated fresh on every build by the calling script or at deploy time. If you export an Image Build parameter file from a Template Spec UI deployment or ARM deployment history, the exported file includes the `timeStamp` value used for that run. Saving and reusing that file causes every subsequent build to supply the same fixed timestamp. Other deployment templates no longer expose this parameter.

### Solution

After generating or exporting an Image Build parameter file, **remove the `timeStamp` entry** before saving it for reuse:

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

## CMK Deployment Fails — Image Management Deployed Before AVD Shared Services {#cmk-deployment-fails-image-management-deployed-before-key-vaults}

### Symptom

The Image Management deployment (`Deploy-ImageManagement.ps1` / Step 2) fails with an error such as:

```text
Resource 'kv-avd-enc-…' was not found.
```

or Image Management storage is created without the intended CMK, or the expected gallery Disk
Encryption Set is not created, even though `keyManagementStorageAccounts` or
`keyManagementGalleryImageVersions` selects a customer-managed option.

### Problem

When using Customer-Managed Keys, Image Management needs the encryption Key Vault resource ID at
deployment time. `keyManagementStorageAccounts` applies CMK to the artifacts and build-log storage
accounts. `keyManagementGalleryImageVersions` creates the Disk Encryption Set that Image Build uses
for build VM disks and published gallery image versions. If the Key Vault does not yet exist, the
resource reference fails. Deploying Step 2 before Step 1 is the most common cause.

### Solution

Follow the documented deployment sequence when Image Management uses CMK:

```text
Step 1 (sharedServices)  →  Step 2 (imageManagement)  →  Step 3 (imageBuild, optional)  →  Step 4 (hostpool)
```

Deploy AVD Shared Services (Step 1) first, wait for it to succeed, then proceed to Image Management
(Step 2). Run Image Build (Step 3) only when publishing a custom image. If you already deployed
Image Management without CMK, deploy Step 1 and then redeploy Step 2 with the required storage or
gallery image-version key-management options.
