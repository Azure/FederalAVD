[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Parameters Reference

Parameter documentation lives alongside each deployment template. Find the section for your solution below.

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

---

## Naming Convention

FederalAVD-created resource names across solutions are controlled by the `namingConvention` parameter. The default value produces CAF-compliant names. When customized, the same parameter object should be passed to every solution for a consistent enterprise naming strategy. Azure Virtual Desktop owns automated session-host VM, OS disk, and NIC names and exposes only a VM name prefix; see [Solution Limitations](limitations.md#automated-host-pool-limitations).

See the **[Naming Convention guide](naming-convention.md)** for:

- Full `namingConvention` parameter schema and property descriptions
- How the built-in CAF default works
- The eight naming segments and how `purpose` drives per-resource uniqueness
- How to align naming across hostpool, sharedServices, imageManagement, and add-ons
- Named examples for six common conventions

---

## PaaS Public Network Access

Shared Services, Image Management, standard/automated Host Pools, FSLogix Storage,
and Session Host Replacer accept `paasPublicNetworkAccess`. One choice applies to
the Storage accounts, Key Vaults, or Function App infrastructure that the selected
deployment creates; it does not reconfigure adopted resources, AVD connection/feed
access, Recovery Services vaults, NetApp Files, or monitoring.

| Value | Public endpoint | Firewall default action |
| --- | --- | --- |
| `Disabled` | Disabled regardless of IP/subnet rules or private endpoint selection | Deny |
| `EnabledWithRestrictions` | Enabled alongside any private endpoints | Deny unmatched traffic, including with empty rule lists |
| `Enabled` | Enabled alongside any private endpoints | Allow all networks, regardless of stored allow rules |
| `Auto` (parameter-file compatibility default) | Historical private-endpoint/IP/subnet inference | Historical behavior |

The Portal exposes only the first three choices. Its initial choice is Disabled
with private endpoints and Enabled otherwise. Image Management's Service Endpoint
option initially selects Enabled with restrictions so subnet restrictions remain
effective. These are defaults, not constraints linking public access to private
endpoint creation.

IP rules remain configured in Disabled mode and do not turn public access back on.
The Portal shows IP-rule entry only for **Enabled with restrictions**, with a short
explanation for the selected mode. Switching to Disabled or Enabled hides the grid
without explicitly clearing entered rules; the rule outputs are not gated on the
access mode. Parameter files can still supply rules in any mode.
Image Management also retains supplied subnet rules; service endpoints use the
**public** storage endpoint and do not provide connectivity when public access is
Disabled.

Existing purpose-specific exceptions are unchanged: Storage/Key Vault retain
`AzureServices` bypass; restricted Function App and SCM access retain the
`AzureCloud` service-tag allowance. Microsoft documents that trusted-service
exceptions can still apply to Storage and Key Vault when public access is
Disabled. Disabled is therefore not a universal private-endpoint-only guarantee.
Authentication and authorization are required in every mode.

Use `permittedIPs` for the shared allowlist (`storagePermittedIPs` in Image
Management). Automated Host Pools also accept the existing `fslogixPermittedIPs`
parameter: those entries are combined with `permittedIPs` for Azure Files only,
preserving the previous contract. Omitted new parameters preserve existing
parameter-file behavior. A Portal-generated parameter file explicitly selects a mode.

For example, deploy private endpoints while permitting approved public addresses:

```json
"paasPublicNetworkAccess": { "value": "EnabledWithRestrictions" },
"permittedIPs": { "value": ["203.0.113.10", "198.51.100.0/24"] }
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
| **SC-7 / SC-5** Boundary Protection / DoS Protection | `hostpool.bicep` | `deployPrivateEndpoints` | `false` | `true` |
| **CP-9** Information System Backup — FSLogix zone resilience | `hostpool.bicep` | `fslogixStorageRedundancy` | `LocallyRedundant` | `ZoneRedundant` *(zone-enabled regions)* |
| **CP-6** Alternate Storage Site — personal VM backup | `hostpool.bicep` | `recoveryServicesVaultStorageRedundancy` | `LocallyRedundant` | `GeoRedundant` |
| **SI-3 / IA-3** Trusted Launch / integrity | `hostpool.bicep` | `securityType` | `TrustedLaunch` | `TrustedLaunch` ✅ *(already default)* |

> **RSV CMK with private endpoints:** CMK on the personal host pool VM backup vault is fully compatible with `deployPrivateEndpoints = true`. Azure Backup is a [trusted Microsoft service](https://learn.microsoft.com/azure/key-vault/general/overview-vnet-service-endpoints#trusted-services) and accesses the encryption Key Vault via the firewall bypass even when `publicNetworkAccess` is `Disabled`. Set `keyManagementRecoveryServicesVault = CustomerManaged` (or `CustomerManagedHSM`) — SC-28 and SC-7 are satisfied simultaneously with no trade-off. For pooled host pools, the shared FSLogix RSV holds only snapshot scheduling metadata (actual profile data stays in the storage account, protected by `keyManagementStorage`), so CMK on that vault has low security value. See [BCDR Guide — Personal Host Pool VM Backup](bcdr.md#personal-host-pool-vm-backup) for full details.

> **Encryption At Host vs. CMK disk encryption:** `encryptionAtHost = true` encrypts the VM's temp disk and OS/data disk caches at the physical host before data reaches Azure Storage. It is a valuable supplemental control but is **not** listed as a compliant path for IL5 storage isolation in the [Azure Government IL5 guidance](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-impact-level-5#disk-encryption-for-virtual-machines). The IL5-compliant approach is **Server-Side Encryption with Customer-Managed Keys via a Disk Encryption Set**, which is exactly what `keyManagementDisks = 'CustomerManagedHSM'` applies. EAH and SSE+CMK are complementary — use both.

> **Storage double encryption:** `requireInfrastructureEncryption` is always `true` for all storage accounts in this solution. Enabling CMK (`CustomerManaged` or `CustomerManagedHSM`) on any storage parameter automatically produces double encryption — no additional configuration is required.

> **Private endpoints:** Setting `deployPrivateEndpoints = true` requires pre-provisioned private DNS zones. Use the networking template to create them, or provide existing zone resource IDs to the relevant `azure*PrivateDnsZoneResourceId` parameters. See [Host Pool Deployment Guide — DNS Requirements](hostpool-deployment.md#c-dns-requirements).

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
