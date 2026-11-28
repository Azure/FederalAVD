[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Parameters Reference

Parameter documentation lives alongside each deployment template. Find the section for your solution below.

FSLogix `ShardOSS` and nonempty `fslogixOSSGroups` require supported domain-joined session hosts.
Current `EntraKerberos-Hybrid` means hybrid users on Entra-only joined hosts, so use `ShardPerms`
instead. Parameter-file and policy-remediation guards reject unsupported OSS requests explicitly.
See [the OSS identity boundary](features.md#object-specific-settings-and-session-host-identity).

The [Image Validation parameter reference](../deployments/add-ons/imageValidation/README.md#parameters)
covers explicit resource names, existing image-version and credentials inputs,
VM network/security settings, artifact customizations, and resource-type tags.
Image Validation builds its own runtime settings; it does not expose naming
conventions or an additional app-settings parameter.

---

## Core Deployments

| Solution | Parameters | Examples |
| --- | --- | --- |
| 🌐 **Networking** | [networking/README.md](../deployments/networking/README.md) | [parameter files](../deployments/networking/README.md) |
| 🧪 **Standard PoC** | [hostpoolPoc/README.md](../deployments/hostpoolPoc/README.md) | [example parameters](../customer-examples/parameters/hostpoolPoc/poc.hostpoolPoc.parameters.json) |
| 🔒 **AVD Shared Services (AVD Workspace, Feed/Global Private Link, Key Vaults, Monitoring, and FSLogix Backup)** | [sharedServices/README.md — Parameters](../deployments/sharedServices/README.md#parameters) | [shared-services examples](../customer-examples/parameters/sharedServices/) |
| 📦 **Image Management** | [imageManagement/README.md — Parameters](../deployments/imageManagement/README.md#parameters) | [imageManagement/README.md — Examples](../deployments/imageManagement/README.md#examples) |
| 🎨 **Image Build** | [imageBuild/README.md — Parameters](../deployments/imageBuild/README.md#parameters) | [imageBuild/README.md — Examples](../deployments/imageBuild/README.md#examples) |
| 🏢 **Host Pool (standard management)** | [hostpools/README.md — Parameters](../deployments/hostpools/README.md#parameters) | [hostpools/README.md — Examples](../deployments/hostpools/README.md#examples) |
| 🏢 **Automated Host Pool (Session Host Configuration)** | [automatedHostPools/README.md](../deployments/automatedHostPools/README.md) | [starter parameters](../customer-examples/parameters/automatedHostPools/example.automatedHostPool.parameters.json) |

For automated host pools, `desktopFriendlyName` is optional (default `''`, maximum 20 characters).
Leave **Session Desktop Friendly Name** blank, omit the deployment parameter, or pass an empty
string to skip renaming the session desktop.

Standard and automated host pools and the FSLogix Storage add-on accept
`domainJoinDeploymentVirtualMachine` (default `false`). For AD DS or Entra Domain Services, it
joins an otherwise-required temporary helper using existing domain information and credentials.
Host pools reuse the session-host OU; the add-on uses its deployment VM OU override or storage OU.
The add-on cannot join externally managed helpers. Azure NetApp Files retains its automatic helper
domain join. See the [standard host-pool guidance](../deployments/hostpools/README.md#deployment-vm-domain-join)
and [FSLogix Storage guidance](../deployments/add-ons/fslogixStorage/README.md#deployment).

The [FSLogix Storage backup contract](../deployments/add-ons/fslogixStorage/README.md#azure-files-snapshot-backup)
supports existing vaults or opt-in shared/dedicated vault creation with `deployFSLogixBackupVault`,
`backupVaultScope`, name overrides, `fslogixBackupRetentionDays`, and `fslogixBackupTimeZone`.
All shared FSLogix backup registration excludes `office-containers`; previously enrolled Office
shares require explicit operator removal from protection.

Standard host pools and the FSLogix Storage add-on use separate Azure Files accounts whenever
Office containers are enabled. `fslogixOfficeStorageTier` and `fslogixOfficeStorageRedundancy`
default to `Inherit`; `fslogixOfficeShareSizeInGB = 0` inherits the Profile quota. Existing Office
account arrays must be explicitly paired with Profile arrays in shard order and cannot overlap.
Generated accounts use central `fslpc` / `fsloc` prefixes; preserve explicit Profile prefixes when
updating an existing deployment. No data migration, account rename/deletion, or removal of
existing Office backup protection occurs automatically. Azure NetApp Files retains separate volumes.
See [standard host-pool storage](../deployments/hostpools/README.md#profile-and-office-account-separation)
and the [add-on role-array contract](../deployments/add-ons/fslogixStorage/README.md#profile-and-office-storage-accounts).
The disposable Standard PoC remains Profile-only.

**Breaking change:** `fslogixStorageKerberosEncryptionType` has been removed from the standard
and automated host-pool templates. Remove that entry from existing parameter files before
deploying the updated templates. New Azure Files storage always uses AES256 Kerberos tickets;
there is no encryption selector in the shared FSLogix modules. Azure NetApp Files never consumed
this parameter and separately enables AES encryption on created AD connections.
Azure Files requires encrypted SMB 3.1.1 with AES-GCM channels; only the explicit `EntraId`
storage-key path retains NTLMv2. Existing/adopted storage is not reconfigured.
See [Azure Files security and client compatibility](design.md#azure-files-security-and-client-compatibility)
for supported-client prerequisites, migration and per-shard live validation.

Azure Files media is `Standard` (HDD) or `Premium` (SSD). Billing is independently selected
with `fslogixProfileStorageBillingModel` (`Legacy`, the Bicep default, or `ProvisionedV2`)
and `fslogixOfficeStorageBillingModel` (`Inherit`, `Legacy`, or `ProvisionedV2`).
New Portal deployments default to SSD provisioned v2; omitted parameters in old files preserve
legacy behavior. V2 uses `FileStorage` with `StandardV2_LRS/ZRS` or `PremiumV2_LRS/ZRS`.
`StorageV2` does not mean provisioned-v2 billing. Cloud Cache retains existing support;
Microsoft recommends SSD. See the
[tier/billing and Cloud Cache guidance](../deployments/add-ons/fslogixStorage/README.md#profile-and-office-storage-accounts).

| Setting | Canonical input |
| --- | --- |
| Backend | `fslogixStorageService`: `AzureFiles` or `AzureNetAppFiles` |
| Profile Azure Files media | `fslogixProfileStorageTier`: `Standard` (HDD) or `Premium` (SSD) |
| Azure NetApp Files service level | `fslogixNetAppServiceLevel`: `Standard` or `Premium` |
| Profile Azure Files redundancy | `fslogixProfileStorageRedundancy`: `LocallyRedundant` or `ZoneRedundant` |
| Profile share / NetApp volume quota | `fslogixProfileShareSizeInGB`: positive integer, default 100 GiB |
| Profile account prefix | `fslogixProfileStorageAccountNamePrefix`: blank uses generated naming, including `namingConvention.fslogixProfileStoragePrefix` |

Standard and automated host pools also accept `fslogixOfficeStorageAccountNamePrefix`; the
standalone storage add-on retains its existing `officeStorageAccountNamePrefix` parameter.
Blank uses `namingConvention.fslogixOfficeStoragePrefix`, normally `fsloc` plus a unique string.
The Portal forms expose separate Profile and Office prefix controls. Office prefixes must contain
3-13 lowercase letters or numbers and differ from the effective Profile prefix. The same shard
index is appended to each role. For example:

```json
"fslogixProfileStorageAccountNamePrefix": { "value": "myprofiles" },
"fslogixOfficeStorageAccountNamePrefix": { "value": "myoffice" }
```

With starting index 1 and two shards, these produce `myprofiles01`, `myprofiles02`, `myoffice01`,
and `myoffice02`. Explicit account prefixes override the corresponding naming-convention prefix
without changing the encryption-key naming convention. Preserve both effective prefixes when
updating a deployment; changing a prefix creates different account names and does not migrate data.

These names, types and meanings are identical across standard host pools, automated host pools and
the storage add-on. Direct Bicep defaults preserve Standard media for standard/add-on deployments
and Premium media for automated host pools; all Portal forms retain Premium SSD/provisioned-v2 defaults.
Generic tuning aliases and composite backend/tier values have been removed, as have account-ID aliases
and the storage add-on's generic prefix alias. Use the canonical Profile account inputs
and tags; see [migration requirements](design.md#consumer-contract-migration-and-consistency).
Shared authentication, shard count/index and group inputs remain neutral. Backend selection remains in
`fslogixStorageService`. Profile media is ignored with NetApp; NetApp service level is ignored with
Azure Files. NetApp rejects nondefault Azure Files billing, performance, redundancy and Office
overrides. Its Profile quota remains the quota for both NetApp volumes. Explicit null values are
not accepted for these tuning inputs; use blank for generated Profile account naming.

For each role, `fslogixProfileProvisionedIops` / `fslogixOfficeProvisionedIops` and
`fslogixProfileProvisionedThroughputMiBps` / `fslogixOfficeProvisionedThroughputMiBps` default
to zero, selecting the recommendation calculated from that role's capacity. Nonzero performance
inputs require v2. V2 global limits are 32-262144 GiB, SSD 3000-102400 IOPS / 100-10340 MiB/s,
and HDD 500-50000 IOPS / 60-5120 MiB/s. Regional/account limits can be lower; validate the target
environment. Capacity and performance are billed as provisioned, not as consumed.
Existing-resource arrays do not resize, convert or migrate accounts. See the
[design compatibility contract](design.md#provisioned-v2-sizing-and-compatible-interfaces).

---

FSLogix share names are fixed by `fslogixContainerType`, not independently configurable.
Profile modes use `profile-containers`; Profile + Office modes additionally use
`office-containers`. The same selection determines Cloud Cache. SHR and additional-host templates
accept only the four canonical container values and explicit local/remote Profile and Office arrays.
Generic consumer account input aliases and legacy container labels have been removed.
The storage add-on retains its derived `fileShareNames` output. Legacy policy share-name
parameters remain accepted for compatibility but do not override the container type.
See the [container configuration contract](design.md#container-type-is-the-fslogix-configuration-source-of-truth).

## Naming Convention

Most FederalAVD deployments control resource names through the `namingConvention` parameter. The default value produces CAF-compliant names. When customized, pass the same parameter object to solutions that support it for a consistent enterprise naming strategy. Image Validation instead takes complete resource names. Azure Virtual Desktop owns automated session-host VM, OS disk, and NIC names and exposes only a VM name prefix; see [Solution Limitations](limitations.md#automated-host-pool-limitations).

See the **[Naming Convention guide](naming-convention.md)** for:

- Full `namingConvention` parameter schema and property descriptions
- How the built-in CAF default works
- The eight naming segments and how `purpose` drives per-resource uniqueness
- How to align naming across hostpool, sharedServices, imageManagement, and add-ons
- Named examples for six common conventions

The parameter uses the shared `namingConventionConfig` type; `{}` and partial
overrides are supported. Prefer `customToken1`/`customToken2` for static custom
slots. Existing `freeform1`/`freeform2` properties and component names remain
aliases; if both spellings are supplied, their values must agree. See the
[add-on quick start](naming-convention.md#add-on-developer-quick-start) for a
complete naming-only Bicep example. No named preset selector is currently provided.

Networking also accepts this typed object. Its former `nameConvResTypeAtEnd` boolean
has been removed; see the [Networking migration example](../deployments/networking/README.md#namingconvention)
for the equivalent resource-type-last component order. Explicit network resource group,
VNet and subnet names remain explicit.

---

## Standard Host-Pool Locations

| Parameter | Default | Purpose |
| --- | --- | --- |
| `controlPlaneLocation` | Subscription deployment location | AVD host pool, workspace, application groups and scaling plan |
| `virtualMachinesLocation` | `controlPlaneLocation` | Session hosts, storage, deployment helpers, monitoring, Key Vaults, backup and their naming context |

Both use Azure location names such as `eastus2` or `usgovvirginia`, not display
labels or naming abbreviations. The Portal passes both selections explicitly.
Naming-context and deployment inputs use `Location`; existing
child modules keep their public parameter contracts.

Set both parameters explicitly for split-location deployments. Empty locations
are invalid, and scripted deployments must check the VM
location against the subnet's VNet before deployment. See
[explicit deployment locations](hostpool-deployment.md#explicit-deployment-locations).

---

## AVD Private Link Portal Defaults

The standard and automated Host Pool forms retain all three private-routing
choices. When AVD Private Link is enabled and the Control Plane step selects an
existing feed workspace, routing defaults to remote session connections only
(`HostPool`) and remote session public access defaults to clients only
(`EnabledForClientsOnly`). This avoids managing the existing workspace's feed
networking unless the operator explicitly selects a feed-routing option.

For a new feed workspace, routing defaults to feed download and remote session
connections (`FeedAndHostPool`); remote session public access defaults to
`Enabled`. These are editable Portal defaults, not restrictions.

---

## PaaS Public Network Access

Standard and Automated Host Pools, Image Management, Shared Services, and Session Host Replacer use the
[typed networking contracts](#typed-networking-solution-rollout) below.
Other add-ons and Host Pool PoC retain their existing flat contracts.

FSLogix Storage, Host Pool PoC, Image Validation, and FSLogix Profile Management
use independent networking policies per service family. Each policy applies only
to resources created by the deployment, not adopted resources, AVD connection/feed
access, Recovery Services vaults, NetApp Files, or monitoring.

| Setting | Storage | Key Vault | Function App inbound |
| --- | --- | --- | --- |
| Public-access mode | `storagePublicNetworkAccess` | `keyVaultPublicNetworkAccess` | `functionAppPublicNetworkAccess` |
| IP/CIDR allowlist | `storagePermittedIPs` | `keyVaultPermittedIPs` | `functionAppPermittedIPs` |
| Deploy private endpoints | `storagePrivateEndpoint` | `keyVaultPrivateEndpoint` | `functionAppPrivateEndpoint` |
| Private endpoint subnet | `storagePrivateEndpointSubnetResourceId` | `keyVaultPrivateEndpointSubnetResourceId` | `functionAppPrivateEndpointSubnetResourceId` |

The private endpoint subnet row applies to flat service-specific entry points and native module inputs.
Typed entries use the ownership slots described below: two for Host Pools, and one shared-resource
slot for Image Management, Shared Services, and Session Host Replacer.

Only applicable families are exposed by each entry template. Storage settings apply
to all newly created accounts, including Profile/Office accounts, artifacts/logs
accounts, or Function runtime storage as appropriate. Key Vault settings apply to
all newly created credentials/encryption vaults. There are no per-instance overrides.

### Standard Host Pool typed networking

The standard Host Pool replaces eighteen flat networking inputs with three sealed typed objects.
All three parameter defaults are `{}`; omitted members are normalized explicitly in the
[shared networking library](../deployments/shared/modules/orchestration/networking/scenarios.bicep).
Unknown fields and unsupported service families are rejected. The Azure-shaped resource-module
interfaces remain unchanged.

| Object | Members |
| --- | --- |
| `paasNetworking` | Common `publicNetworkAccess` and `privateEndpoint`; optional `storage`, `keyVault`, `backup`, and `disk` configuration. |
| `privateEndpointSubnetResourceIds` | `sharedResources` and `hostPoolResources`, independently selected ownership slots. Both may reference the same subnet. |
| `privateDnsZoneResourceIds` | `file`, `vault`, `backup`, `blob`, `queue`, `avdFeed`, and `avdGlobalFeed`. Select only these applicable keys from Networking outputs. |

Common defaults are `publicNetworkAccess: 'Disabled'` and `privateEndpoint: true`.
Storage and Key Vault each accept optional overrides of those two settings, plus their own
`permittedIPs: string[]` and `serviceEndpointSubnetResourceIds: string[]`, defaulting to empty
arrays. Explicit `false` overrides are preserved. There is no cross-family allowlist merging,
automatic allowance for placement subnets, or inference of public access from the presence of rules.
Lists supplied through parameter files remain configured in all access modes.

The ordinary form offers **Private connectivity** (default), **Restricted public connectivity**,
and **Custom configuration**. The scenario is form-only intent, not another deployment parameter:

- **Private:** applicable deployment-owned PaaS private endpoints, disabled public access,
  ownership subnet selections, and applicable DNS controls.
- **Restricted public:** no PaaS private endpoints by default; separate Storage/Key Vault
  service-endpoint subnet and IP/CIDR selections. At least one allowed source is required for
  each newly created family using restricted access without a private endpoint.
- **Custom:** independently configure each family's public mode and private endpoint,
  including mixed private/restricted-public access. Unrestricted public access is an explicit
  advanced choice and still requires resource authentication.

Recovery Services has no IP/subnet ACL equivalent. `backup` therefore accepts only
`publicNetworkAccess: 'Enabled' | 'Disabled'` and `privateEndpoint: bool`.
Restricted common intent requires an explicit Backup public-access choice when a new vault is
created; the form requires a choice between private Backup connectivity and authenticated but
network-unrestricted public Backup connectivity. An adopted vault is never reconfigured.
`disk` accepts only a private-endpoint override and applies to the existing Personal-host-pool
managed-disk workflow.

For example, use restricted Storage connectivity while keeping other PaaS private:

```json
"paasNetworking": {
  "value": {
    "storage": {
      "publicNetworkAccess": "EnabledWithRestrictions",
      "privateEndpoint": false,
      "permittedIPs": ["203.0.113.0/24"],
      "serviceEndpointSubnetResourceIds": [
        "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<storage-source>"
      ]
    }
  }
}
```

The selected source subnets must already have the appropriate service endpoints; this host-pool
deployment does not modify them. Endpoint placement subnets and source allowlists are different
concepts. Missing required placement slots, or missing Backup DNS when a Backup endpoint is
requested, fail explicitly rather than falling back to public connectivity. Other existing
custom-DNS behavior is retained; validate name resolution before use.

AVD route/public-access choices and AMPLS linkage remain separate. The grouped DNS object carries
AVD zone IDs but does not enable AVD Private Link or authorize management of an existing workspace.

#### Migrating standard Host Pool parameter files

Remove the old flat inputs; there are no legacy aliases at the deployment entry:

| Former input | New object member |
| --- | --- |
| `storagePublicNetworkAccess`, `storagePrivateEndpoint` | `paasNetworking.storage.publicNetworkAccess`, `.privateEndpoint` |
| `storagePermittedIPs`, `storageServiceEndpointSubnetResourceIds` | `paasNetworking.storage.permittedIPs`, `.serviceEndpointSubnetResourceIds` |
| `keyVaultPublicNetworkAccess`, `keyVaultPrivateEndpoint` | `paasNetworking.keyVault.publicNetworkAccess`, `.privateEndpoint` |
| `keyVaultPermittedIPs`, `keyVaultServiceEndpointSubnetResourceIds` | `paasNetworking.keyVault.permittedIPs`, `.serviceEndpointSubnetResourceIds` |
| `deployBackupAndDiskPrivateEndpoints` | Separate `paasNetworking.backup.privateEndpoint` and `paasNetworking.disk.privateEndpoint` |
| `sharedResourcesPrivateEndpointSubnetResourceId` | `privateEndpointSubnetResourceIds.sharedResources` |
| `hostPoolResourcesPrivateEndpointSubnetResourceId` | `privateEndpointSubnetResourceIds.hostPoolResources` |
| `filePrivateDnsZoneResourceId`, `vaultPrivateDnsZoneResourceId`, `backupPrivateDnsZoneResourceId`, `blobPrivateDnsZoneResourceId`, `queuePrivateDnsZoneResourceId` | Corresponding `privateDnsZoneResourceIds.file`, `.vault`, `.backup`, `.blob`, `.queue` |
| `avdPrivateDnsZoneResourceId`, `globalFeedPrivateDnsZoneResourceId` | `privateDnsZoneResourceIds.avdFeed`, `.avdGlobalFeed` |

This intentionally changes omitted CLI defaults to private endpoints plus disabled public access.
To preserve earlier behavior, explicitly transfer every family's endpoint/public-access choices.
For Backup, also transfer the previously derived public choice: `Disabled` with its endpoint,
`Enabled` without it. Omission is not a compatibility mode.
Customer-owned files are not rewritten automatically. Regenerate/export parameters from the new
form or migrate a copy before deploying. The compliance evidence collector records the three
configured objects as JSON; that evidence is not proof of effective deployment or connectivity.

### Typed networking solution rollout

The same three object parameter names and form scenarios now apply to five solutions.
Each entry exposes sealed subsets containing only its supported resource families and DNS namespaces:

| Solution | Root parameter count | `paasNetworking` families | Endpoint placement | DNS namespaces |
| --- | --- | --- | --- | --- |
| Standard Host Pool | 134 | `storage`, `keyVault`, `backup`, `disk` | `sharedResources`, `hostPoolResources` | `file`, `vault`, `backup`, `blob`, `queue`, `avdFeed`, `avdGlobalFeed` |
| Automated Host Pool | 129 | `storage`, `keyVault`, `backup` | `sharedResources`, `hostPoolResources` | `file`, `vault`, `backup`, `blob`, `queue`, `avdFeed`, `avdGlobalFeed` |
| Image Management | 17 | `storage` | `sharedResources` | `blob` |
| Shared Services | 48 | `keyVault`, `backup` | `sharedResources` | `vault`, `backup`, `blob`, `queue`, `avdFeed`, `avdGlobalFeed` |
| Session Host Replacer | 108 | `storage`, `functionApp` | `sharedResources` | `blob`, `table`, `websites` |

All three root objects default to `{}`. Common omitted defaults are private endpoints and disabled
public access. Storage/Key Vault allowlists are separate arrays, and family overrides preserve
explicit `false`. Required selected private endpoint subnets never fall back to a VM subnet or public
access. Restricted public access without a private endpoint requires usable allowed sources for each
newly created applicable family. Adopted PaaS resources remain owner-managed.

Automated Host Pool has no DiskAccess private-endpoint workflow; its
`disableManagedDiskPublicNetworkAccess` policy remains separate. Shared Services keeps AVD feed/global
management separate from PaaS policy while placing selected AVD endpoints in its one shared subnet.
Image Management applies one Storage-family policy to both created artifacts and build-log accounts;
it does not change the gallery or existing encryption Key Vault.

Session Host Replacer keeps runtime Storage and operator app/SCM source lists independent.
Restricted public connectivity uses restricted public access for both families, with explicit
sources and no private endpoints. App and SCM share the same restrictions. Operators need a
reachable allowed path for code/file access; Portal RBAC alone is not sufficient. Private runtime
Storage additionally requires the separate `functionAppDelegatedSubnetResourceId` outbound
integration input. A Storage service-endpoint path must be explicitly authorized; integration
does not add an allowlist rule. See [Replacer networking and migration](../deployments/add-ons/sessionHostReplacer/README.md#4-network-requirements-for-zero-trust-networking).

**Migration from the preceding flat contracts:**

| Former root input | Replacement |
| --- | --- |
| Storage/Key Vault/Function App public mode and PE inputs (applicable families only) | `paasNetworking.storage` / `.keyVault` / `.functionApp` members `publicNetworkAccess` and `privateEndpoint` |
| Storage/Key Vault/Function App IP and service-endpoint subnet inputs | Family members `permittedIPs` and `serviceEndpointSubnetResourceIds` |
| Automated/Shared Services `deployBackupPrivateEndpoints` | `paasNetworking.backup.privateEndpoint`, plus explicit `publicNetworkAccess` to preserve former behavior |
| Image Management `storagePrivateEndpointSubnetResourceId` | `privateEndpointSubnetResourceIds.sharedResources` |
| Replacer `storagePrivateEndpointSubnetResourceId` / `functionAppPrivateEndpointSubnetResourceId` | One `privateEndpointSubnetResourceIds.sharedResources` |
| Any shared-resource ownership subnet | `privateEndpointSubnetResourceIds.sharedResources` |
| Host-pool-resource ownership subnet | `privateEndpointSubnetResourceIds.hostPoolResources` |
| Namespace-specific DNS inputs | Corresponding `privateDnsZoneResourceIds` member; use `avdFeed` / `avdGlobalFeed` for the AVD inputs |

Restricted common intent requires explicit Backup `Enabled`/`Disabled` connectivity when creating a
vault; Recovery Services has no IP/subnet ACL equivalent. Private Backup requires a Backup DNS zone.
There are no legacy aliases or automatic customer-file migrations. Regenerate form exports or migrate
a copy, including explicit old defaults where required. Select only the applicable DNS keys from the
Networking producer; do not pass its entire output into a narrower sealed object.

The forms' default scenario is **Private connectivity**; **Restricted public connectivity** exposes
separate subnet and IP inputs, and **Custom configuration** enables independent family overrides.
Unrestricted choices show a warning and still require authentication. Source/DNS IDs are cleared from
inactive families rather than leaked from retained controls. Offline tests do not prove Portal
rendering, API discovery, DNS resolution, or client connectivity.

### FSLogix module parameter alignment

The shared FSLogix composer and its Azure Files adapter use Storage-prefixed inputs.
Host Pool callers map their host-pool ownership subnet into the Storage subnet input;
single-service callers keep Storage-prefixed subnet parameters. This breaks the former internal module contract;
shared composer inputs remain separate parameters with unchanged types and defaults.
Standard and Automated Host Pools resolve their typed networking objects into those existing inputs.

| Former module input | Entry, FSLogix composer, and Azure Files adapter input | Resource-level destination |
| --- | --- | --- |
| `paasPublicNetworkAccess` | `storagePublicNetworkAccess` | `publicNetworkAccess` and `networkAcls.defaultAction` |
| `permittedIPs` | `storagePermittedIPs` | `networkAcls.ipRules` |
| `privateEndpoint` | `storagePrivateEndpoint` | Private endpoint deployment condition |
| `privateEndpointSubnetResourceId` | `storagePrivateEndpointSubnetResourceId` | Private endpoint module `subnetResourceId`, then `properties.subnet.id` |

`storageServiceEndpointSubnetResourceIds` remains unchanged and supplies
`networkAcls.virtualNetworkRules`. `filePrivateDnsZoneResourceId` remains namespace-based.
The public mode defaults to `Disabled`; its shared type is a string enumeration,
not an object. Private endpoint deployment remains independent of public access.
Resource-module interfaces, NetApp Files, and backup behavior are unchanged.
See [deployment intent and Azure-shaped inputs](design.md#deployment-intent-and-azure-shaped-inputs)
for the adapter boundary and an example of the mode-to-API translation.

### Key Vault module parameter alignment

The shared Key Vault composer uses `keyVaultPublicNetworkAccess`,
`keyVaultPermittedIPs`, `keyVaultPrivateEndpoint`, and
`keyVaultPrivateEndpointSubnetResourceId`, replacing its former
`paasPublicNetworkAccess`, `permittedIPs`, `privateEndpoint`, and
`privateEndpointSubnetResourceId` inputs respectively.
Host Pool and Shared Services callers map their shared ownership subnet into the
Key Vault subnet input; other callers retain their service-specific subnet input. Module argument keys use
the current Key Vault names. Types, defaults, DNS inputs, subnet allowlists,
and resource-module interfaces are unchanged. Settings still apply to both newly
created credential and encryption vaults, not adopted vaults.

### Host-pool subnet placement by ownership

Standard and Automated Host Pools expose exactly two private endpoint subnet ownership slots,
independently of resource type: `privateEndpointSubnetResourceIds.sharedResources` and
`.hostPoolResources`. Neither has an implicit subnet.

| Object member in either Host Pool | Consumers |
| --- | --- |
| `privateEndpointSubnetResourceIds.sharedResources` | Newly created shared credentials/encryption Key Vaults, shared FSLogix Backup, AVD workspace feed, and AVD global feed |
| `privateEndpointSubnetResourceIds.hostPoolResources` | FSLogix Azure Files accounts and AVD host-pool connections; Standard also supports Personal VM Backup and managed-disk access |

Only applicable, selected private endpoints are created. Sharing subnet placement
does not share public-access modes, IP/subnet firewall allowlists, private endpoint
flags, or DNS zone inputs. Existing/adopted PaaS resources remain owner-managed.
Existing AVD workspaces retain the documented create/update behavior.

For the earlier flat ownership-contract migration, rename `operationsPrivateEndpointSubnetResourceId` to
`sharedResourcesPrivateEndpointSubnetResourceId`. Replace the entry-level
`keyVaultPrivateEndpointSubnetResourceId`, `workspaceFeedPrivateEndpointSubnetResourceId`,
and `globalFeedPrivateEndpointSubnetResourceId` with that shared input. Replace
`storagePrivateEndpointSubnetResourceId` and
`hostPoolPrivateEndpointSubnetResourceId` (formerly
`hostpoolPrivateEndpointSubnetResourceId`) with the host-pool input.
If former inputs selected different subnets, explicitly choose one subnet per
ownership bucket; there is no override or legacy alias. For either Host Pool, then
move those IDs into the typed ownership object described above.

The Portal provides one shared-resource and one host-pool-resource subnet selection,
visible whenever a selected endpoint in that bucket requires it, including AVD-only
and Key Vault-only cases. Resource modules retain their resource-specific subnet
inputs; Host Pool entry points perform the ownership mapping.
Other deployments, including standalone FSLogix Storage, retain their own existing
subnet contracts.

### Shared Services subnet placement by ownership

Shared Services exposes exactly one private endpoint subnet input,
`privateEndpointSubnetResourceIds.sharedResources`. The object defaults to `{}`; the slot
must be supplied whenever a managed endpoint needs it.
All selected endpoints for newly created Key Vaults, shared FSLogix Backup, AVD
workspace feed, and AVD global feed use it. Public policies, firewall allowlists,
endpoint flags, and DNS zone inputs remain independent. Existing/adopted PaaS
resources and platform-managed AMPLS connectivity are not reconfigured.

**Breaking change:** replace the entry-level `keyVaultPrivateEndpointSubnetResourceId`,
`backupPrivateEndpointSubnetResourceId`, `workspaceFeedPrivateEndpointSubnetResourceId`,
and `globalFeedPrivateEndpointSubnetResourceId` with the grouped shared slot. Choose one
subnet if the former values differed; there are no aliases or per-service overrides.
Also set `deployWorkspaceFeedPrivateEndpoint = true` if the former workspace-feed
subnet was supplied. This new flag defaults to `false` and applies only when
`manageAvdWorkspace` is true, so a subnet supplied for Key Vault or Backup does not
enable feed Private Link. Global feed remains controlled by `manageGlobalAvdWorkspace`.

The Portal provides one network subscription, VNet, and nondelegated subnet selection
after the endpoint choices. Resource-module interfaces and AVD create/update behavior
are unchanged. See [Shared Services networking](../deployments/sharedServices/README.md#networking-and-diagnostics).

### Private DNS parameter names

DNS inputs identify namespaces rather than resource owners. Networking policies
remain service-prefixed and independent. This naming-only breaking change adds no
parameters and does not rename existing Azure DNS zones.

| Former name | Current name | Consumer |
| --- | --- | --- |
| `azureFilePrivateDnsZoneResourceId` / `azureFilesPrivateDnsZoneResourceId` / `storageFilePrivateDnsZoneResourceId` | `filePrivateDnsZoneResourceId` | FSLogix Azure Files |
| `azureBlobPrivateDnsZoneResourceId` / `storageBlobPrivateDnsZoneResourceId` | `blobPrivateDnsZoneResourceId` | Image Management, Function runtime Storage, Backup, or managed disks |
| `azureQueuePrivateDnsZoneResourceId` / `storageQueuePrivateDnsZoneResourceId` | `queuePrivateDnsZoneResourceId` | Function runtime Storage or Backup |
| `azureTablePrivateDnsZoneResourceId` / `storageTablePrivateDnsZoneResourceId` | `tablePrivateDnsZoneResourceId` | Function runtime Storage |
| `azureKeyVaultPrivateDnsZoneResourceId` / `keyVaultPrivateDnsZoneResourceId` | `vaultPrivateDnsZoneResourceId` | Key Vault |
| `azureFunctionAppPrivateDnsZoneResourceId` / `functionAppPrivateDnsZoneResourceId` | `websitesPrivateDnsZoneResourceId` | Function App |
| `azureBackupPrivateDnsZoneResourceId` | `backupPrivateDnsZoneResourceId` | Recovery Services Backup |

Networking also replaces `azureBlobZoneId`, `azureFilesZoneId`, `azureQueueZoneId`,
`azureTableZoneId`, `azureKeyVaultZoneId`, `azureWebAppZoneId`, and
`azureBackupZoneId` with the corresponding current names above. Its
`privateDnsZoneResourceIds` output uses `blob`, `file`, `queue`, `table`, `vault`,
`websites`, and `backup` keys. For example, pass
`privateDnsZoneResourceIds.blob` to `blobPrivateDnsZoneResourceId` in any consumer.
AVD feed/global-feed contracts and DNS creation switches are unchanged.

Private DNS zone dropdowns are searchable and automatically default to the first
matching namespace in the selected DNS subscription, using its display label rather
than its resource ID. The submitted value remains the full zone resource ID.
Cold or empty inventories show an empty-value availability option rather than
evaluating `first()` on an empty list. When multiple zones match, review the selected
zone and resource group before deployment; no zone is created by this selection.

Standard Host Pools replace `deployPrivateEndpoints` / `deployBackupAndDiskPrivateEndpoints`
with independent `paasNetworking.backup.privateEndpoint` and `paasNetworking.disk.privateEndpoint`.
Automated Host Pools and Shared Services use `paasNetworking.backup.privateEndpoint`;
Shared Services replaces its former flat subnet inputs with
`privateEndpointSubnetResourceIds.sharedResources`.
Backup enablement remains independent; subnet placement follows the ownership model above.
Use full zone resource IDs, including the correct cloud/region namespace and owning
subscription. Reusing a zone ID does not couple public-access policies.
See the [DNS namespace rationale](design.md#service-family-paas-networking).

**Breaking change:** remove the former shared `paasPublicNetworkAccess` and
`permittedIPs` parameters. Automated Host Pools also replace `fslogixPermittedIPs`
and the FSLogix-specific private endpoint inputs with the Storage inputs above.
There is no global-policy inheritance or merged cross-service allowlist.
Standalone Storage replaces `privateEndpoint` and `privateEndpointSubnetResourceId`
with the Storage-prefixed inputs. Function add-ons replace combined private
endpoint inputs with separate Storage/Function inputs; Image Validation and
Profile Management remove `endpointType`. Image Management removes
`storageNetworkAccess` in favor of independent Storage private/public settings.
Image Validation renames its validation-VM subnet to
`virtualMachineSubnetResourceId`; Profile Management removes `subnetResourceId`
because inbound client subnets and private endpoint subnets now have explicit inputs.

| Value | Public endpoint | Firewall default action |
| --- | --- | --- |
| `Disabled` | Disabled regardless of IP/subnet rules or private endpoint selection | Deny |
| `EnabledWithRestrictions` | Enabled alongside any private endpoints | Deny unmatched traffic, including with empty rule lists |
| `Enabled` | Enabled alongside any private endpoints | Allow all networks, regardless of stored allow rules |

New entry-template and Portal public modes default to `Disabled`, independently
of private endpoint deployment. Select an explicit public mode for each service.
For example, Storage can allow service-endpoint subnets while Key Vault's public
access is Disabled. A Disabled mode without a reachable private path requires operator
attention; the Portal displays a warning rather than silently enabling public access.

The Portal groups each service into three sibling sections: private endpoints,
public endpoint access, and allowed public-endpoint sources. Sections are never
nested. Allowlists appear only in restricted mode, before monitoring where the
step has monitoring controls. Existing resources are not presented as editable ACLs.

IP rules remain configured in Disabled mode and do not turn public access back on.
The Portal shows IP-rule entry only for **Enabled with restrictions**, with a short
explanation for the selected mode. Switching to Disabled or Enabled hides the grid
without explicitly clearing entered rules; the rule outputs are not gated on the
access mode. Parameter files can still supply rules in any mode.
Supplied subnet rules are retained as well. Service endpoints use the **public**
PaaS endpoint and do not provide connectivity when public access is Disabled.

Purpose-specific exceptions apply: Storage/Key Vault use
`AzureServices` bypass; restricted Function App and SCM access use the
`AzureCloud` service-tag allowance. Microsoft documents that trusted-service
exceptions can still apply to Storage and Key Vault when public access is
Disabled. Disabled is therefore not a universal private-endpoint-only guarantee.
Authentication and authorization are required in every mode.

Use the service-specific IP inputs above. An empty list deliberately allows no
ordinary IP sources; it does not inherit another service's list.

### Service endpoint subnet allowlists

Use separate allowlists for the services created by a deployment:

| Parameter | Applies to | Required endpoint on each existing subnet |
| --- | --- | --- |
| `storageServiceEndpointSubnetResourceIds` | New FSLogix Azure Files accounts, artifacts/logs storage, or Function runtime storage | `Microsoft.Storage` for compatible regional access, or `Microsoft.Storage.Global` for cross-region access where supported |
| `keyVaultServiceEndpointSubnetResourceIds` | New credential/encryption Key Vaults | `Microsoft.KeyVault` |
| `functionAppServiceEndpointSubnetResourceIds` | Function App inbound access restrictions, including SCM's main-rule setting | `Microsoft.Web` |

The arrays default to empty. Full subnet resource IDs can span subscriptions and
VNets; IDs are trimmed, validated, and deduplicated case-insensitively. A VNet ID
alone is not a valid rule. Portal selectors discover eligible subnets in the
selected subscription; parameter files can supply IDs from other subscriptions.
The deployment identity needs permission to authorize each subnet for the service.
If ARM returns a paginated VNet inventory, the Portal shows a warning: subnets on
later pages must be supplied through parameter files. Inventory also depends on
the operator's network read permissions.

The templates configure service ACLs, not existing subnets. Enable the corresponding
service endpoints first and validate cloud/region support. They do not alter adopted
storage accounts, existing Key Vaults, or NetApp Files networking. For a storage-only
FSLogix deployment, supply existing Key Vault and backup resources separately.

Choose **Enabled with restrictions** to enforce the lists. Private endpoints can
coexist with these public endpoint rules. In unrestricted Enabled mode, stored
allowlists are not an isolation boundary. Trusted-service exceptions remain as
described above. Empty lists in restricted mode deny ordinary unmatched public
traffic; there is no topology-based fallback to unrestricted access.

Function **inbound** subnet rules are independent of outbound VNet integration.
To let an integrated Function reach storage, include its outbound integration subnet
in the storage allowlist. FSLogix Profile Management's runtime-storage selector does
not authorize access to existing profile shares: their owner must allow that same
outbound subnet on every target profile account separately. Select outbound VNet
integration independently of the Function's inbound public mode and private
endpoints. Selecting integration does not implicitly authorize its subnet in the
runtime Storage allowlist.

The disposable Host Pool PoC owns its new host subnet. When restricted storage is
selected, it enables `Microsoft.Storage` on that new subnet, includes it in the
storage ACL, and creates networking before storage ACLs. Additional selected
existing subnets are never changed.

For example, authorize service endpoints without public IP rules:

```json
"storagePublicNetworkAccess": { "value": "EnabledWithRestrictions" },
"storagePrivateEndpoint": { "value": false },
"storagePermittedIPs": { "value": [] },
"storageServiceEndpointSubnetResourceIds": {
  "value": [
    "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/hosts",
    "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-operations/subnets/functions"
  ]
}
```

Before production use, render each affected Portal step, deploy to an isolated
target-cloud environment, test access from allowed and unlisted subnets, and verify
that Disabled still blocks service-endpoint access. Offline tests do not prove
Portal rendering, endpoint availability, or network reachability.
The multi-VNet inventory uses schema-supported `ArmApiControl.request.transforms`
with a JMESPath flatten projection and named `loaded`, `vnets`, `subnets`, and
`nextLink` results. Readiness uses `.transformed.loaded`, not the bare transformed
container. Service-endpoint subnet labels use `VNETName | SubnetName`, with
`Resource Group: ResourceGroupName` on the description line. Region checks do not capture an outer subnet
variable inside a nested VNet lambda. The Microsoft Learn ArmApiControl page does
not document the `.transformed` runtime binding; explicitly confirm inventory
population and cold-load reactivity during that Portal smoke test.

Run the offline networking/form checks from the repository root:

```powershell
Invoke-Pester -Path tests\ServiceEndpointContracts.Tests.ps1,tests\ServiceEndpointForms.Tests.ps1,tests\PublicNetworkAccess.Tests.ps1,tests\TemplateSpecs.Tests.ps1
```

For example, deploy private endpoints while permitting approved public addresses:

```json
"storagePrivateEndpoint": { "value": true },
"storagePublicNetworkAccess": { "value": "EnabledWithRestrictions" },
"storagePermittedIPs": { "value": ["203.0.113.10", "198.51.100.0/24"] },
"keyVaultPrivateEndpoint": { "value": true },
"keyVaultPublicNetworkAccess": { "value": "Disabled" },
"keyVaultPermittedIPs": { "value": [] }
```

Select `Disabled` with the same IP list to retain the rules without enabling the
public endpoint. Before disabling access, provide and validate the private
connectivity/DNS path for session hosts, image builders, deployment workstations,
and Function App runtime storage as applicable.

Authoritative service behavior:
[Storage default access](https://learn.microsoft.com/en-us/azure/storage/common/storage-network-security-set-default-access),
[Storage exceptions and limitations](https://learn.microsoft.com/en-us/azure/storage/common/storage-network-security-limitations),
[Key Vault networking](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security),
and [App Service access restrictions](https://learn.microsoft.com/en-us/azure/app-service/overview-access-restrictions).

---

## Add-Ons

SHR's `functionAppResourceGroupName` defaults to the session-host VM resource group name.
The Portal exposes it as **Infrastructure > Session Host Replacer Resource Group**, selecting an
existing RG in the deployment subscription. It scopes pool-specific replacer resources, not the
session-host VMs or shared dependencies. App Service Plan placement remains independently
configurable; in direct deployments an omitted plan RG defaults to the replacer RG.
See [resource placement and rebuild cautions](../deployments/add-ons/sessionHostReplacer/docs/deployment-guide.md#dedicated-replacer-resource-group).

For Session Host Replacer gallery-image pilots, `includeExcludedImageVersions` defaults to `false`.
Enable it only on pilot pools to test excluded candidates before promotion. See
[pilot selection and promotion](../deployments/add-ons/sessionHostReplacer/README.md#pilot-image-selection-and-promotion)
for numeric version ordering, safeguards, and the upgrade requirement.

SHR always uses an initiation timer and a mode-specific reconciliation timer. `initiationEnabled`
(default `true`) gates new batches and `continuationTimeoutHours` (default `168`, range `1-720`)
sets the no-progress window for new operations, excluding schedule-only waits. A timeout blocks
expansion but permits guarded completion of checkpointed recovery. Legacy operations retain their
fixed deadline until completion or checked deadline recovery. There is no execution-mode selector
or SHR queue DNS parameter.
See [two-timer execution](../deployments/add-ons/sessionHostReplacer/README.md#two-timer-execution).

SHR's existing `timerSchedule` parameter populates the `TimerSchedule` app setting referenced by
the initiation binding. Deployment derives `ContinuationTimerSchedule`: five-minute SideBySide
reconciliation staggered one minute after the initiation minute offset, or every-minute DeleteFirst
reconciliation. New authorization lasts 15 minutes for SideBySide or five minutes for DeleteFirst;
the separate 30-minute ownership lease is unchanged. Redeploy after schedule or mode changes so
both bindings and app settings stay consistent. See
[deployment updates](../deployments/add-ons/sessionHostReplacer/docs/deployment-guide.md).

| Add-On | Parameters |
| --- | --- |
| 🔄 **Session Host Replacer** | [sessionHostReplacer/README.md](../deployments/add-ons/sessionHostReplacer/README.md) |
| 🖥️ **Session Hosts** | [sessionHosts/README.md](../deployments/add-ons/sessionHosts/README.md#parameters) |
| 📊 **Storage Quota Manager** | [storageQuotaManager/README.md](../deployments/add-ons/storageQuotaManager/README.md) |
| 🔑 **Update Storage Keys** | [updateStorageAccountKeyOnSessionHosts/README.md](../deployments/add-ons/updateStorageAccountKeyOnSessionHosts/README.md) |
| 📝 **Run Commands on VMs** | [runCommandsOnVms/README.md](../deployments/add-ons/runCommandsOnVms/README.md) |

---

## Cross-Solution Output Passing

When chaining deployments, use this mapping to pass outputs from one step to the next. See the **[End-to-End Automation Guide](automation-guide.md)** for the full pipeline diagram and scripted examples.

The standard and automated host-pool entry templates are orchestrators that call Shared Services
and then directly compose their pool-specific modules. New workspaces use shared, region-level
naming by default.
A PoC uses host-pool-specific workspace naming and places its persistent host-pool, workspace,
session-host, FSLogix, monitoring, and standalone network resources in one resource group.
Production host-pool deployments retain the separate resource-group layout and create or adopt
shared resources.

When multiple host pools use one AVD workspace, serialize their deployments. Each orchestrator appends its
application-group reference while preserving the other workspace properties, and concurrent
read-modify-write updates can lose a reference. Workspace public access and feed/global Private
Link are managed only when explicitly selected; otherwise existing workspace settings are
preserved.

| Source | Output | Destination | Parameter |
| --- | --- | --- | --- |
| **sharedServices** | `secretsKeyVaultResourceId` | **hostpool** | `existingCredentialsKeyVaultResourceId` |
| **sharedServices** | `secretsKeyVaultResourceId` | **automatedHostPool** | `credentialsKeyVaultResourceId` (required) |
| **sharedServices** | `encryptionKeyVaultResourceId` | **imageManagement** | `encryptionKeyVaultResourceId` |
| **sharedServices** | `encryptionKeyVaultResourceId` | **hostpool** | `existingEncryptionKeyVaultResourceId` |
| **sharedServices** | `logAnalyticsWorkspaceResourceId` | **imageManagement** | `logAnalyticsWorkspaceResourceId` |
| **sharedServices** | `logAnalyticsWorkspaceResourceId` | **hostpool** | `existingLogAnalyticsWorkspaceResourceId` |
| **sharedServices** | `avdInsightsDataCollectionRuleResourceId` | **hostpool** | `existingAVDInsightsDataCollectionRuleResourceId` |
| **sharedServices** | `dataCollectionEndpointResourceId` | **hostpool** | `existingDataCollectionEndpointResourceId` |
| **sharedServices** | `azureMonitorPrivateLinkScopeResourceId` | **hostpool** | `azureMonitorPrivateLinkScopeResourceId` |
| **sharedServices** | `avdWorkspaceResourceId` | **hostpool / automatedHostPool** | `existingFeedWorkspaceResourceId` |
| **sharedServices** | `fslogixBackupVaultResourceId` | **hostpool** | `existingFilesBackupVaultResourceId` |
| **sharedServices** | `fslogixBackupPolicyName` | **hostpool** | `existingFilesBackupPolicyName` |
| **sharedServices** | `fslogixBackupVaultResourceId` | **fslogixStorage** | `recoveryServicesVaultResourceId` |
| **sharedServices** | `fslogixBackupPolicyName` | **fslogixStorage** | `fileSharePolicyName` |
| **fslogixStorage** | `fslogixBackupVaultResourceId` | **hostpool / automatedHostPool** | `existingFilesBackupVaultResourceId` |
| **fslogixStorage** | `fslogixBackupPolicyName` | **hostpool / automatedHostPool** | `existingFilesBackupPolicyName` |
| **fslogixStorage** | `fslogixBackupVaultResourceId` | **fslogixStorage** (later expansion) | `recoveryServicesVaultResourceId` |
| **fslogixStorage** | `fslogixBackupPolicyName` | **fslogixStorage** (later expansion) | `fileSharePolicyName` |
| **imageManagement** | `computeGalleryResourceId` | **imageBuild** | `computeGalleryResourceId` |
| **imageManagement** | `artifactsBlobContainerUrl` | **imageBuild** | `artifactsContainerUri` |
| **imageManagement** | `managedIdentityResourceId` | **imageBuild** | `userAssignedIdentityResourceId` |
| **imageManagement** | `buildLogsStorageAccountResourceId` | **imageBuild** | `logStorageAccountResourceId` |
| **imageManagement** | `imageBuildResourceGroupResourceId` | **imageBuild** | `imageBuildResourceGroupId` |
| **imageManagement** | `diskEncryptionSetResourceId` | **imageBuild** | `diskEncryptionSetResourceId` for the source/build region; use `imageVersionTargetRegions[].diskEncryptionSetResourceId` for additional regions |
| **imageBuild** | image definition resource ID | **hostpool** | `customImageResourceId` |

---

## Compliance Configuration Reference

> **For the full ISSO/AO-facing compliance reference** — including control-by-control mappings to NIST SP 800-53 Rev 5 / FedRAMP High, DoD SRG IL4, and IL5, plus always-on controls and a shared-responsibility summary — see **[Compliance Control Mapping](compliance.md)**.

The tables below are a quick developer reference for which parameters to set. All compliance-relevant settings are optional — the solution defaults to functional minimums for maximum compatibility.

### NIST SP 800-53 Rev 5 / FedRAMP High

**Reference:** [NIST SP 800-53 Rev 5](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final)

| Control | Template | Parameter | Default | Compliant Value |
| --- | --- | --- | --- | --- |
| **SC-28** Protection of Information at Rest — VM disks | `hostpool.bicep` | `keyManagementDisks` | `PlatformManaged` | `CustomerManaged` or `CustomerManagedHSM` |
| **SC-28** Protection of Information at Rest — FSLogix storage | `hostpool.bicep` | `keyManagementStorage` | `PlatformManaged` | `CustomerManaged` or `CustomerManagedHSM` |
| **SC-28** Protection of Information at Rest — Recovery Services Vault | `hostpool.bicep` | `keyManagementRecoveryServicesVault` | `PlatformManaged` | `CustomerManaged` or `CustomerManagedHSM` |
| **SC-28** Protection of Information at Rest — artifacts/build-log storage | `imageManagement.bicep` | `keyManagementStorageAccounts` | `PlatformManaged` | `CustomerManaged` or `CustomerManagedHSM` |
| **SC-28** Protection of Information at Rest — gallery image versions | `imageManagement.bicep` | `keyManagementGalleryImageVersions` | `PlatformManaged` | `CustomerManaged` or `CustomerManagedHSM` |
| **SC-28(1)** Encryption At Host *(supplemental)* | `hostpool.bicep` | `encryptionAtHost` | `true` | `true` ✅ *(already default — encrypts temp disk and host cache; not the primary IL5 disk encryption mechanism — see note below)* |
| **SC-7 / SC-5** Boundary Protection / DoS Protection | `hostpool.bicep` | `deployBackupAndDiskPrivateEndpoints` | `false` | `true` |
| **CP-9** Information System Backup — FSLogix zone resilience | `hostpool.bicep` | `fslogixProfileStorageRedundancy` | `LocallyRedundant` | `ZoneRedundant` *(zone-enabled regions)* |
| **CP-6** Alternate Storage Site — personal VM backup | `hostpool.bicep` | `recoveryServicesVaultStorageRedundancy` | `LocallyRedundant` | `GeoRedundant` |
| **SI-3 / IA-3** Trusted Launch / integrity | `hostpool.bicep` | `securityType` | `TrustedLaunch` | `TrustedLaunch` ✅ *(already default)* |

> **RSV CMK with private endpoints:** CMK on the personal host pool VM backup vault is fully compatible with `deployBackupAndDiskPrivateEndpoints = true`. Azure Backup is a [trusted Microsoft service](https://learn.microsoft.com/azure/key-vault/general/overview-vnet-service-endpoints#trusted-services) and accesses the encryption Key Vault via the firewall bypass even when `publicNetworkAccess` is `Disabled`. Set `keyManagementRecoveryServicesVault = CustomerManaged` (or `CustomerManagedHSM`) — SC-28 and SC-7 are satisfied simultaneously with no trade-off. For pooled host pools, the shared FSLogix RSV holds only snapshot scheduling metadata (actual profile data stays in the storage account, protected by `keyManagementStorage`), so CMK on that vault has low security value. See [BCDR Guide — Personal Host Pool VM Backup](bcdr.md#personal-host-pool-vm-backup) for full details.

> **Encryption At Host vs. CMK disk encryption:** `encryptionAtHost = true` encrypts the VM's temp disk and OS/data disk caches at the physical host before data reaches Azure Storage. It is a valuable supplemental control but is **not** listed as a compliant path for IL5 storage isolation in the [Azure Government IL5 guidance](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-impact-level-5#disk-encryption-for-virtual-machines). The IL5-compliant approach is **Server-Side Encryption with Customer-Managed Keys via a Disk Encryption Set**, which is exactly what `keyManagementDisks = 'CustomerManagedHSM'` applies. EAH and SSE+CMK are complementary — use both.

> **Storage double encryption:** `requireInfrastructureEncryption` is always `true` for all storage accounts in this solution. Enabling CMK (`CustomerManaged` or `CustomerManagedHSM`) on any storage parameter automatically produces double encryption — no additional configuration is required.

> **Private endpoints:** Supply pre-provisioned DNS zone IDs through the [consumer-specific DNS inputs](#private-dns-parameter-names). `deployBackupAndDiskPrivateEndpoints` controls standard Backup/disk endpoints only; Storage and Key Vault have independent switches. See [Host Pool Deployment Guide — DNS Requirements](hostpool-deployment.md#c-dns-requirements).

---

### IL5 Isolation Requirements on IL4 (Dedicated Hosts + HSM)

**Reference:** [Azure Government isolation guidelines for Impact Level 5](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-impact-level-5)

IL5 data hosted in Azure Government IL4 regions (Arizona, Texas, Virginia) requires **both** compute isolation **and** HSM-backed storage encryption. Both are mandatory per the [DoD Cloud Computing SRG](https://public.cyber.mil/dccs/dccs-documents/); compute isolation alone or encryption alone is not sufficient.

> **Dedicated Hosts are mandatory in US Gov regions.** The IL5 guidance states explicitly: *"When you deploy VMs in Azure Government regions US Gov Arizona, US Gov Texas, and US Gov Virginia, you must use Azure Dedicated Host."* This applies to all VMs including AVD session hosts. In the dedicated DoD regions (US DoD Central, US DoD East) no extra isolation configuration is required — physical separation is provided by design.
>
> **Exemptions:** If Dedicated Hosts are operationally or financially infeasible for your workload, you may request a technical exception through your Authorizing Official (AO). Exceptions must be formally documented in your System Security Plan (SSP) with compensating controls and a written risk acceptance signed by the AO.

> **Encryption At Host is not the IL5 disk encryption mechanism.** The IL5 guidance requires either Azure Disk Encryption (ADE/BitLocker) or SSE with customer-managed keys on the storage holding the disks. `keyManagementDisks = 'CustomerManagedHSM'` implements SSE+CMK via a Disk Encryption Set — this is the correct path. `encryptionAtHost = true` is an additional complementary control but does not satisfy the IL5 storage isolation requirement on its own.

Set the following parameters in addition to the NIST 800-53 values above:

| Requirement | Template | Parameter | Required Value |
| --- | --- | --- | --- |
| Compute isolation (dedicated physical hosts) | `hostpool.bicep` | `deployToDedicatedHosts` | `true` |
| Dedicated host group | `hostpool.bicep` | `dedicatedHostGroupResourceId` | Resource ID of pre-provisioned dedicated host group |
| HSM key protection — VM disks | `hostpool.bicep` | `keyManagementDisks` | `CustomerManagedHSM` |
| HSM key protection — FSLogix storage | `hostpool.bicep` | `keyManagementStorage` | `CustomerManagedHSM` |
| HSM key protection — Recovery Services Vault | `hostpool.bicep` | `keyManagementRecoveryServicesVault` | `CustomerManagedHSM` |
| HSM key protection — artifacts/build-log storage | `imageManagement.bicep` | `keyManagementStorageAccounts` | `CustomerManagedHSM` |
| HSM key protection — gallery image versions | `imageManagement.bicep` | `keyManagementGalleryImageVersions` | `CustomerManagedHSM` |

> **Pre-requisite:** At least one dedicated host must be deployed in a dedicated host group in the target Azure Government region before deploying the host pool. See [Azure Dedicated Hosts documentation](https://learn.microsoft.com/en-us/azure/virtual-machines/dedicated-hosts).

> **Key Vault:** Using `CustomerManagedHSM` deploys Azure Key Vault Premium (FIPS 140 Level 3 validated HSM). To use a pre-existing Key Vault from the security deployment, set `existingEncryptionKeyVaultResourceId` accordingly.
