# Shared Modules

This directory contains reusable Bicep modules used by standard host pools, automated host pools,
Shared Services, and add-ons.

## Organization

The directory has two kinds of modules:

- **Resource modules** create or configure one Azure resource family. These remain under
  `resourceModules`, with categories such as `compute`, `storage`, `network`, `authorization`,
  `managedIdentity`, `recoveryServices`, or `desktopVirtualization`.
- **Orchestration modules** compose multiple resource modules into a reusable cross-solution
  capability. These are under `orchestration`.

A module belongs here when its behavior is reusable across deployment entry points and does not
encode one solution's deployment workflow. Solution-specific sequencing, API workarounds, and scope
adapters remain under their owning deployment directory.

## Resource Modules

All resource modules are under `resourceModules`. The AVD resource modules are separated from
session-host workflow composition so the folder name no longer implies that every AVD-related file
is a resource leaf.

| Category | Purpose |
| --- | --- |
| `resourceModules/authorization` | Reusable role-assignment modules for subscription, resource-group, and management-group scopes. |
| `resourceModules/compute` | Virtual machines, galleries, images, disk encryption sets, disk access, and compute extensions. |
| `resourceModules/desktopVirtualization` | AVD host pools, application groups, workspaces, scaling plans, and session-host API resources. |
| `resourceModules/extensions` | Guest extensions such as domain join, Entra login, Azure Monitor Agent, GPU drivers, and Guest Attestation. |
| `resourceModules/functionApp` | Function Apps, hosting plans, and function code resources used by add-ons. |
| `resourceModules/insights`, `monitoring`, `operationalInsights` | Scheduled query rules, DCR/DCE resources, AVD Insights configuration, and Log Analytics workspaces. |
| `resourceModules/keyVault` | Key Vaults, secrets, keys, and their role assignments. |
| `resourceModules/managedIdentity` | User-assigned identity resources and role assignments. |
| `resourceModules/netApp` | Azure NetApp Files accounts, capacity pools, and volumes. |
| `resourceModules/network` | VNets, subnets, private endpoints, private DNS, route tables, NSGs, NAT gateways, and public IPs. |
| `resourceModules/privateLinkScope` | Azure Monitor Private Link Scope resources and scoped-resource operations. |
| `resourceModules/recoveryServices` | Recovery Services vaults, backup policies, and protected-item resources. |
| `resourceModules/resources` | Resource groups and Template Specs. |
| `resourceModules/storage` | Storage accounts and blob, file, queue, table, share, lifecycle, and access modules. |
| `resourceModules/types` | Shared user-defined types used by resource and orchestration modules. |

Resource modules should normally use a noun/resource-family path with `deploy.bicep` for a leaf
resource operation. They should not depend on standard or automated host-pool entry points.

## Orchestration Modules

| Module | Consumers | Responsibility |
| --- | --- | --- |
| `orchestration/deploymentHelper` | Standard host pool, automated host pool, FSLogix Storage add-on | Creates and cleans up the temporary deployment VM, identity, and required role assignments. |
| `orchestration/avdServicePrincipalRbac.bicep` | Standard host pool, automated host pool | Assigns the Azure Virtual Desktop service principal the roles required for Start VM on Connect and dynamic scaling. |
| `orchestration/customerManagedKeys/diskCmk.bicep` | Standard host pool, automated policy | Composes customer-managed disk-key resources. |
| `orchestration/fslogix/fslogix.bicep` | Standard host pool, automated host pool, FSLogix Storage add-on | Routes FSLogix storage to Azure Files or Azure NetApp Files and optionally registers Azure Files backup items. |
| `orchestration/sessionHosts` | Standard host pool, Session Hosts add-on | Composes direct session-host VM deployment, customization, disk, and backup operations. |
| `orchestration/keyVaults/keyVaults.bicep` | Standard host pool, Shared Services | Composes secrets and encryption Key Vaults and their dependent resources. |
| `orchestration/naming/hostPool.bicep` | Standard host pool, automated host pool, FSLogix Storage add-on | Resolves shared host-pool naming conventions. |
| `orchestration/customerManagedKeys/storageCmk.bicep` | Standard host pool, automated host pool, FSLogix Storage add-on | Composes customer-managed storage-key resources. |
| `orchestration/avdServicePrincipalRbac.bicep` | Standard host pool, automated host pool | Assigns the Azure Virtual Desktop service principal the roles required for Start VM on Connect and dynamic scaling. |

Orchestration modules may call resource modules, but resource modules must not call orchestration
modules. This keeps the dependency direction easy to follow:

```text
Deployment entry point
  -> solution-local orchestration / scope adapters
    -> shared orchestration modules
      -> shared resource modules
```

## Deployment-Specific Orchestration

Standard and automated host pools intentionally retain local orchestration because their workflows
are different:

```text
hostpools/hostpool.bicep
  -> modules/control-plane
  -> modules/hosts
  -> modules/monitoring
  -> shared/orchestration and shared resource modules

automatedHostPools/automatedHostPool.bicep
  -> modules/controlPlane
  -> modules/permissions
  -> modules/sessionHostConfiguration
  -> modules/sessionHostManagement
  -> policy/main.bicep
  -> shared/orchestration and shared resource modules

add-ons/*/main.bicep
  -> add-on-specific modules when the add-on owns unique behavior
  -> shared/orchestration and shared resource modules
```

The automated `sessionHostConfiguration.bicep` and `sessionHostManagement.bicep` files are scope
adapters around shared AVD API modules. Keep them local because their subscription-scoped wrapper
is required to bridge runtime resource-group names and automated-host sequencing.

The automated `policy` directory is also intentionally local. Its policy definitions and policy
orchestration implement the automated session-host provisioning boundary and should not be treated
as generic resource modules.

## Naming Rules

- Use the shared `orchestration/naming` modules for reusable naming behavior.
- Keep add-on-specific naming modules under their owning add-on when their outputs and purpose tokens are unique.
- Use resource-family paths for resource modules and `orchestration` for composed capabilities.
- Keep scope adapters beside the deployment that needs the API or deployment-scope workaround.
- Do not create a second module with equivalent behavior under a solution directory.
- Treat the Bicep source as authoritative and regenerate a sibling ARM JSON template after changing
  a tracked entry template.

## Dependency Review

When adding or moving a module:

1. Search all Bicep callers before changing its path.
2. Confirm the module is reusable across at least two deployment surfaces before placing it under
   `orchestration`.
3. Preserve resource-group and subscription scope explicitly.
4. Build every affected entry template.
5. Run the ARM synchronization check for each tracked entry template.

The end-to-end deployment dependency map is maintained in
[docs/automation-guide.md](../../../docs/automation-guide.md).
