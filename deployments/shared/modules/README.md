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

## Service-family network policies

Standard and Automated Host Pools, Image Management, and Shared Services resolve their
[typed networking intent](../../../docs/parameters.md#typed-networking-solution-rollout)
through [the shared scenario library](orchestration/networking/scenarios.bicep)
into the existing composer inputs below. Their common defaults are private endpoints and disabled
public access, with independent service overrides and allowlists.
Add-ons and Host Pool PoC expose independent Storage, Key Vault, and Function App policies only
where those families are created. Public modes default `Disabled`, and each family has
its own IP/subnet allowlists and PE flag/subnet. There are no per-resource overrides,
global inheritance, or automatic allowances for PE/outbound integration subnets.
Existing resources and customer subnet configuration remain caller-owned.

The FSLogix composer and Azure Files adapter use `storagePublicNetworkAccess`,
`storagePermittedIPs`, `storagePrivateEndpoint`, and
`storagePrivateEndpointSubnetResourceId`. Host Pool callers map their host-pool ownership
subnet into that Storage subnet input. Their existing
`storageServiceEndpointSubnetResourceIds` input is unchanged.
The Key Vault composer likewise uses `keyVaultPublicNetworkAccess`,
`keyVaultPermittedIPs`, `keyVaultPrivateEndpoint`, and
`keyVaultPrivateEndpointSubnetResourceId`. Host Pool and Shared Services callers map their shared ownership
subnet into that Key Vault subnet input. Its existing
`keyVaultServiceEndpointSubnetResourceIds` input is unchanged.
Both composers' public policies are explicit and default `Disabled`, without Auto.
The [multi-family Function App composer](orchestration/functionApp/README.md#networking-behavior)
instead requires independent app and runtime-Storage inputs. Monitoring, Recovery
Services backup, managed-disk access, and AVD controls are not governed by those policies.
Resource modules retain their resource-level inputs; see
[deployment intent and Azure-shaped inputs](../../../docs/design.md#deployment-intent-and-azure-shaped-inputs)
for the distinction between policy intent and Azure API configuration.

### Backup orchestration

The shared [FSLogix Backup composer](orchestration/recoveryServices/fslogixBackupVault.bicep)
assembles a Recovery Services vault, Azure Files snapshot policy, and optional private endpoint.
It belongs in orchestration; the vault, policy, and endpoint implementations remain resource modules.
The [personal VM Backup composer](../../hostpools/modules/hosts/modules/recoveryServices.bicep)
remains solution-local because it owns the host-pool VM policy and staged CMK workflow.

Both composers require explicit `publicNetworkAccess` (`Enabled` or `Disabled`) independently
of `privateEndpoint`. Only newly created vault networking is managed. Recovery Services vaults
do not expose Storage/Key Vault-style IP or service-endpoint subnet allowlists, so
`EnabledWithRestrictions` is not a supported Backup composer value.
Both Host Pool entries and Shared Services supply independently resolved Backup public access and
endpoint flags from their typed networking object. Restricted common intent requires an explicit
choice for newly created vaults, with no implicit public fallback. The standalone FSLogix Storage
add-on retains its existing contract: enabled vault public access without a vault private endpoint.

Direct module consumers must replace the former
`resourceModules/recoveryServices/fslogixBackupVault.bicep` reference with
`orchestration/recoveryServices/fslogixBackupVault.bicep` and pass `publicNetworkAccess`.
This relocation does not change Backup Private Link generation, DNS requirements, CMK sequencing,
policy retention, or storage registration and protection.

## Resource Modules

All resource modules are under `resourceModules`. AVD resource modules and session-host workflow
composition belong to the resource and orchestration layers, respectively.

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
| `orchestration/recoveryServices/fslogixBackupVault.bicep` | Standard host pool, automated host pool, Shared Services, FSLogix Storage add-on | Composes a Recovery Services vault, Azure Files snapshot policy, and optional private endpoint with independent public access. |
| `orchestration/monitoring/monitoring.bicep` | Standard host pool, Shared Services | Composes Log Analytics, Data Collection Endpoint, AVD Insights DCR, and optional Azure Monitor Private Link Scope linkage. |
| `orchestration/sessionHosts` | Standard host pool, Session Hosts add-on | Composes direct session-host VM deployment, customization, disk, and backup operations. |
| `orchestration/keyVaults/keyVaults.bicep` | Standard host pool, Shared Services | Composes secrets and encryption Key Vaults and their dependent resources. |
| `orchestration/naming/naming.bicep` | Standard/automated host pools, PoC, FSLogix Storage and other deployment families | Central naming library; host pools import `hostPoolNames`, standalone FSLogix imports `fslogixNames`, and new add-ons use the generic resource-type API. |
| `orchestration/customerManagedKeys/storageCmk.bicep` | Standard host pool, automated host pool, FSLogix Storage add-on | Composes customer-managed storage-key resources. |

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

Session-host policy implementation is centralized under `orchestration/sessionHostPolicy`. This
domain directory owns all related definitions, initiatives, assignment and remediation helpers,
nested templates, and reusable capability orchestration, including policies currently used only by
Automated Host Pools. Consumer-local policy entry points remain thin scope and sequencing adapters.

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
2. Place cross-solution behavior and domain-owned implementations under `orchestration`; current
  consumer count does not determine ownership.
3. Preserve resource-group and subscription scope explicitly.
4. Build every affected entry template.
5. Run the ARM synchronization check for each tracked entry template.

The end-to-end deployment dependency map is maintained in
[docs/automation-guide.md](../../../docs/automation-guide.md).
