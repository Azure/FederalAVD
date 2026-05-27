# Custom RBAC Roles for FederalAVD Operators

The [quickStart](quick-start.md#required-deployer-roles-by-deployment) guide lists the minimum built-in roles for each deployment. For organizations that need tighter constraints — for example, preventing operators from creating arbitrary resources outside the AVD-specific scope — this guide provides ready-to-use custom role definitions scoped to exactly the permissions each deployment path requires.

> **Note:** Custom roles in Azure must be created at subscription or management group scope before they can be assigned. The JSON definitions below set `assignableScopes` to `"/"` as a placeholder; replace with your subscription or management group resource ID before deploying.

---

## Table of Contents

1. [imageManagement Operator](#1-imagemanagement-operator)
2. [imageBuild Operator — New RG Path](#2-imagebuild-operator--new-rg-path)
3. [imageBuild Operator — Existing RG Path](#3-imagebuild-operator--existing-rg-path)
4. [Hostpool Operator — Full Deployment](#4-hostpool-operator--full-deployment)
5. [Hostpool Operator — SessionHostsOnly](#5-hostpool-operator--sessionhostsonly)
6. [Deploying Custom Roles](#deploying-custom-roles)

---

## 1. imageManagement Operator

**Minimum scope:** Subscription (must create resource groups and assign roles on them)

### What the deployment does

| Action | Resource | Scope |
|---|---|---|
| Create resource group | Image management RG | Subscription |
| Create resource group | Image build RG (if `deployImageBuildResourceGroup = true`) | Subscription |
| Create user-assigned managed identity | Image management RG | RG |
| Create storage accounts (artifacts + logs) | Image management RG | RG |
| Assign **Storage Blob Data Reader** to managed identity | Artifacts storage account | RG |
| Assign **Storage Blob Data Contributor** to managed identity | Logs storage account | RG |
| Assign **Contributor** to managed identity | Image build RG | RG |
| Create Compute Gallery + Image Definition (optional) | Image management RG | RG |

### Custom role definition

```json
{
  "Name": "FederalAVD - imageManagement Operator",
  "Description": "Deploys the FederalAVD imageManagement template. Grants minimum permissions to create the image management resource group and pre-stage the image build resource group.",
  "AssignableScopes": ["/"],
  "Actions": [
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.Resources/subscriptions/resourceGroups/write",
    "Microsoft.Resources/deployments/*",
    "Microsoft.ManagedIdentity/userAssignedIdentities/*",
    "Microsoft.Storage/storageAccounts/*",
    "Microsoft.Compute/galleries/*",
    "Microsoft.Compute/galleries/images/*",
    "Microsoft.KeyVault/vaults/read",
    "Microsoft.KeyVault/vaults/keys/*",
    "Microsoft.Authorization/roleAssignments/write",
    "Microsoft.Authorization/roleAssignments/read",
    "Microsoft.Authorization/roleAssignments/delete",
    "Microsoft.Authorization/roleDefinitions/read",
    "Microsoft.Insights/alertRules/*",
    "Microsoft.Support/*"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": []
}
```

> **Note on `Microsoft.Authorization/roleAssignments/write`:** This permission is required at the resource group scope to assign the managed identity roles on the storage accounts and image build RG. If your organization requires a separate Role Assignment Administrator persona, those three assignments can be pre-staged manually and `deployImageBuildResourceGroup` set to `false`.

---

## 2. imageBuild Operator — New RG Path

**Minimum scope:** Subscription (creates a temporary resource group and assigns a role in it)

### What the deployment does

| Action | Resource | Scope |
|---|---|---|
| Create resource group | Temporary image build RG | Subscription |
| Assign **Contributor** to orchestration VM system identity | Image build RG | RG (newly created) |
| Deploy orchestration VM + image VM | Image build RG | RG |
| Create image definition (if not pre-existing) | Compute gallery RG | RG |
| Create image version | Compute gallery RG | RG |
| Create image version (optional) | Remote gallery RG | RG |

### Custom role definition

```json
{
  "Name": "FederalAVD - imageBuild Operator (New RG)",
  "Description": "Deploys the FederalAVD imageBuild template using a freshly created resource group. Requires subscription scope to create the temporary build RG and grant the orchestration VM identity Contributor on it.",
  "AssignableScopes": ["/"],
  "Actions": [
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.Resources/subscriptions/resourceGroups/write",
    "Microsoft.Resources/deployments/*",
    "Microsoft.Compute/virtualMachines/*",
    "Microsoft.Compute/disks/*",
    "Microsoft.Compute/images/*",
    "Microsoft.Compute/galleries/read",
    "Microsoft.Compute/galleries/images/read",
    "Microsoft.Compute/galleries/images/versions/*",
    "Microsoft.Compute/availabilitySets/read",
    "Microsoft.Compute/locations/usages/read",
    "Microsoft.Compute/locations/vmSizes/read",
    "Microsoft.Compute/skus/read",
    "Microsoft.Network/networkInterfaces/*",
    "Microsoft.Network/virtualNetworks/subnets/read",
    "Microsoft.Network/virtualNetworks/subnets/join/action",
    "Microsoft.ManagedIdentity/userAssignedIdentities/assign/action",
    "Microsoft.Authorization/roleAssignments/write",
    "Microsoft.Authorization/roleAssignments/read",
    "Microsoft.Authorization/roleAssignments/delete",
    "Microsoft.Authorization/roleDefinitions/read",
    "Microsoft.Storage/storageAccounts/blobServices/containers/read",
    "Microsoft.KeyVault/vaults/read",
    "Microsoft.Insights/alertRules/*",
    "Microsoft.Support/*"
  ],
  "NotActions": [],
  "DataActions": [
    "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read"
  ],
  "NotDataActions": []
}
```

> **Assign this role at subscription scope.** The role assignment write permission is needed only to grant the orchestration VM's system identity Contributor on the freshly created build RG during deployment; it is exercised once and removed during cleanup.

---

## 3. imageBuild Operator — Existing RG Path

**Minimum scope:** Subscription scope required for deployment submission; no subscription-level resource creation or role assignments

This is the recommended production path and the **tightest permission model available** for image builds. It is unlocked by two parameter choices:

| Parameter | Value | What it eliminates |
|---|---|---|
| `imageBuildResourceGroupId` | Existing RG resource ID | Removes `resourceGroups/write` and `roleAssignments/write` at subscription scope — the orchestration VM no longer needs a system identity with a self-assigned Contributor role |
| `imageDefinitionResourceId` | Existing image definition resource ID | Removes `Compute/galleries/images/write` on the gallery RG — only new image *versions* are written |

With **both** parameters provided, the operator needs **zero role assignment rights** anywhere. The managed identity's roles on the build RG are pre-staged by the imageManagement deployment (`deployImageBuildResourceGroup = true`), and no new RBAC is written at runtime.

> **Important:** `imageBuild.bicep` has `targetScope = 'subscription'`. Even though all resources land in resource groups, the ARM deployment object itself is created at subscription scope. The deploying identity must have `Microsoft.Resources/deployments/write` at subscription scope — it cannot be avoided without restructuring the template. No resource group creation or role assignment rights are required at subscription scope.

### What the deployment does

#### Tightest path — both `imageBuildResourceGroupId` AND `imageDefinitionResourceId` provided

| Action | Resource | Scope |
|---|---|---|
| Submit ARM deployment | Subscription (deployment object only) | Subscription |
| Deploy orchestration VM + image VM | Image build RG (pre-existing) | RG |
| Create image version | Compute gallery RG | RG |
| Create image version (optional) | Remote gallery RG | RG |

#### With existing build RG but no `imageDefinitionResourceId`

Same as above, plus:

| Action | Resource | Scope |
|---|---|---|
| Create image definition | Compute gallery RG | RG |

This adds `Microsoft.Compute/galleries/images/write` to the required actions on the gallery RG. All other rights are identical.

### Required role assignments

Assign the **same** custom role at all three scopes. The subscription-scope assignment grants only `deployments/*` and `resourceGroups/read`; the RG-scope assignments activate the actual resource creation permissions. Because custom role assignments are additive, the operator gets the union without receiving broad subscription-level resource creation rights.

| Scope | Purpose |
|---|---|
| **Subscription** | Submit the ARM deployment (`deployments/write`) |
| Image build RG | Create VMs, NICs, disks, run commands |
| Compute gallery RG | Create image version (and image definition if not pre-existing) |
| Remote gallery RG (if used) | Create remote image version |

### Custom role definition

The role below covers both variants. When `imageDefinitionResourceId` is provided the `galleries/images/write` action is unused but harmless, and you can remove it if your policy scanner flags unnecessary actions.

```json
{
  "Name": "FederalAVD - imageBuild Operator (Existing RG)",
  "Description": "Deploys the FederalAVD imageBuild template into a pre-existing resource group. No role assignment rights required. Assign at subscription scope (deployment submission only) and at the image build RG + compute gallery RG (resource creation).",
  "AssignableScopes": ["/"],
  "Actions": [
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.Resources/deployments/*",
    "Microsoft.Compute/virtualMachines/*",
    "Microsoft.Compute/disks/*",
    "Microsoft.Compute/images/*",
    "Microsoft.Compute/galleries/read",
    "Microsoft.Compute/galleries/images/read",
    "Microsoft.Compute/galleries/images/write",
    "Microsoft.Compute/galleries/images/versions/*",
    "Microsoft.Compute/availabilitySets/read",
    "Microsoft.Compute/locations/usages/read",
    "Microsoft.Compute/locations/vmSizes/read",
    "Microsoft.Compute/skus/read",
    "Microsoft.Network/networkInterfaces/*",
    "Microsoft.Network/virtualNetworks/subnets/read",
    "Microsoft.Network/virtualNetworks/subnets/join/action",
    "Microsoft.ManagedIdentity/userAssignedIdentities/assign/action",
    "Microsoft.Storage/storageAccounts/blobServices/containers/read",
    "Microsoft.KeyVault/vaults/read",
    "Microsoft.Insights/alertRules/*",
    "Microsoft.Support/*"
  ],
  "NotActions": [],
  "DataActions": [
    "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read"
  ],
  "NotDataActions": []
}
```

> **No `roleAssignments/write` anywhere.** The managed identity's Contributor role on the build RG was pre-granted by imageManagement. This is the only imageBuild operator model that requires no privilege escalation rights.
>
> **If `imageDefinitionResourceId` is always provided** (fully automated pipeline), remove `Microsoft.Compute/galleries/images/write` from the role for a strictly minimal surface.
>
> **The subscription-scope assignment is safe.** The role omits `resourceGroups/write`, `roleAssignments/write`, and all resource provider write actions at subscription scope, so the operator can only submit the deployment — not create resource groups or assign roles.

---

## 4. Hostpool Operator — Full Deployment

**Minimum scope:** Subscription (creates resource groups, assigns subscription-scoped roles to AVD service principal)

The full hostpool deployment (`SessionHostsAdd` for adding VMs only, or a full redeploy) makes role assignments at three scopes:
- **Subscription** — AVD service principal for Start VM On Connect or Scaling Plan
- **Control plane RG** — Desktop Virtualization User to Entra groups on the app group; deployment VM UAI cleanup roles
- **Hosts RG** — VM User Login (Entra-only), deployment VM UAI roles, FSLogix storage roles

Because the subscription-scoped role assignments use AVD built-in roles (not Contributor), `Microsoft.Authorization/roleAssignments/write` at subscription scope combined with a condition limiting the role definition IDs is the most constrained you can get while still using a single identity.

### Custom role definition

```json
{
  "Name": "FederalAVD - Hostpool Operator",
  "Description": "Deploys the FederalAVD hostpool template at full scope. Includes subscription-level RG creation and the ability to assign a constrained set of AVD and RBAC roles. Does not grant Key Vault data plane access (Key Vault Crypto Officer must be assigned separately if using CMK).",
  "AssignableScopes": ["/"],
  "Actions": [
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.Resources/subscriptions/resourceGroups/write",
    "Microsoft.Resources/deployments/*",
    "Microsoft.Compute/virtualMachines/*",
    "Microsoft.Compute/disks/*",
    "Microsoft.Compute/diskAccesses/*",
    "Microsoft.Compute/diskEncryptionSets/*",
    "Microsoft.Compute/galleries/read",
    "Microsoft.Compute/galleries/images/read",
    "Microsoft.Compute/galleries/images/versions/read",
    "Microsoft.Compute/availabilitySets/read",
    "Microsoft.Compute/locations/usages/read",
    "Microsoft.Compute/locations/vmSizes/read",
    "Microsoft.Compute/skus/read",
    "Microsoft.Network/networkInterfaces/*",
    "Microsoft.Network/virtualNetworks/subnets/read",
    "Microsoft.Network/virtualNetworks/subnets/join/action",
    "Microsoft.Network/privateEndpoints/*",
    "Microsoft.Network/privateDnsZones/join/action",
    "Microsoft.DesktopVirtualization/*",
    "Microsoft.ManagedIdentity/userAssignedIdentities/*",
    "Microsoft.Storage/storageAccounts/*",
    "Microsoft.Authorization/roleAssignments/write",
    "Microsoft.Authorization/roleAssignments/read",
    "Microsoft.Authorization/roleAssignments/delete",
    "Microsoft.Authorization/roleDefinitions/read",
    "Microsoft.Authorization/policyAssignments/*",
    "Microsoft.Authorization/policyDefinitions/*",
    "Microsoft.KeyVault/vaults/read",
    "Microsoft.KeyVault/vaults/keys/read",
    "Microsoft.Insights/alertRules/*",
    "Microsoft.OperationalInsights/workspaces/read",
    "Microsoft.RecoveryServices/vaults/read",
    "Microsoft.Support/*"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": []
}
```

> **CMK deployments additionally require `Key Vault Crypto Officer`** on the encryption key vault. This is a data plane role and cannot be merged into a custom role that is assigned at subscription scope without granting it across all key vaults in the subscription. Assign it separately, scoped to the specific key vault resource.

#### Recommended condition for `roleAssignments/write`

To prevent the operator identity from granting itself or others arbitrary roles, apply an [Azure ABAC condition](https://learn.microsoft.com/en-us/azure/role-based-access-control/conditions-role-assignments-portal) on the `Microsoft.Authorization/roleAssignments/write` action restricting `Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId]` to the set of role definition IDs that the hostpool deployment actually uses:

| Role | ID |
|---|---|
| Desktop Virtualization Power On Contributor | `489581de-a3bd-480d-9518-53dea7416b33` |
| Desktop Virtualization Power On Off Contributor | `40c5ff49-9181-41f8-ae61-143b0e78555e` |
| Desktop Virtualization User | `1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63` |
| Desktop Virtualization Application Group Contributor | `86240b0e-9422-4c43-887b-b61143f32ba8` |
| Role Based Access Control Administrator | `f58310d9-a9f6-439a-9e8d-f62e7b41a168` |
| Virtual Machine Contributor | `9980e02c-c2be-4d73-94e8-173b1dc7cf3c` |
| Storage Account Contributor | `17d1049b-9a84-46fb-8f53-869881c3d3ab` |
| Storage File Data Privileged Contributor | `69566ab7-960f-475b-8e7c-b3118f30c6bd` |

---

## 5. Hostpool Operator — SessionHostsOnly

**Minimum scope:** Subscription scope required for deployment submission; no subscription-level resource creation or role assignments

This is the most constrained operator model. The host pool, control plane, and all RBAC are pre-provisioned. The operator only adds new session hosts to an existing environment.

> **Important:** `hostpool.bicep` has `targetScope = 'subscription'`. Even though all resources land in resource groups, the ARM deployment object itself is created at subscription scope. The deploying identity must have `Microsoft.Resources/deployments/write` at subscription scope — it cannot be avoided without restructuring the template.

### Required role assignments

| Role | Scope |
|---|---|
| `FederalAVD - Hostpool SessionHostsOnly Operator` (below) | **Subscription** (for deployment write only) |
| Built-in: `Contributor` | Existing **hosts RG** |
| Built-in: `Desktop Virtualization Host Pool Contributor` | Existing **control plane RG** |

The subscription-scope custom role below grants only `deployments/*` and `resourceGroups/read` — no resource creation, no role assignment write.

### Custom role definition

```json
{
  "Name": "FederalAVD - Hostpool SessionHostsOnly Operator (Subscription)",
  "Description": "Grants only the subscription-level deployment submission right needed for hostpool.bicep (targetScope = subscription). Assign at subscription scope alongside Contributor on the hosts RG and Desktop Virtualization Host Pool Contributor on the control plane RG.",
  "AssignableScopes": ["/"],
  "Actions": [
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.Resources/deployments/*",
    "Microsoft.Authorization/*/read",
    "Microsoft.Insights/alertRules/*",
    "Microsoft.Support/*"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": []
}
```

There is no custom role needed for the RG-scoped assignments — the split of built-in roles already achieves least privilege:
- `Contributor` on the hosts RG is needed for VM + NIC + disk creation. No narrower built-in role covers all three resource types together.
- `Desktop Virtualization Host Pool Contributor` on the control plane RG is narrower than `Contributor` — it restricts the operator to `Microsoft.DesktopVirtualization/hostpools/*` and cannot create, delete, or modify other resource types in that RG.

---

## Deploying Custom Roles

### Azure CLI

```bash
az role definition create --role-definition @customRole.json
```

### PowerShell

```powershell
New-AzRoleDefinition -InputFile .\customRole.json
```

### Bicep / ARM

Custom roles can also be deployed as part of your subscription-scoped Bicep template:

```bicep
targetScope = 'subscription'

resource customRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, 'FederalAVD-imageBuild-ExistingRG')
  properties: {
    roleName: 'FederalAVD - imageBuild Operator (Existing RG)'
    description: 'Deploys the FederalAVD imageBuild template into a pre-existing resource group.'
    assignableScopes: [subscription().id]
    permissions: [
      {
        actions: [
          'Microsoft.Resources/subscriptions/resourceGroups/read'
          'Microsoft.Resources/deployments/*'
          // ... remaining actions
        ]
        notActions: []
        dataActions: [
          'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'
        ]
        notDataActions: []
      }
    ]
  }
}
```

### Scope the `assignableScopes` field

Replace the `"/"` placeholder in the JSON definitions above with your actual scope before deploying:

| Target | Value |
|---|---|
| Single subscription | `/subscriptions/{subscriptionId}` |
| Management group | `/providers/Microsoft.Management/managementGroups/{mgId}` |
