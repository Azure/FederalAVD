[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Parameters Reference

Parameter documentation lives alongside each deployment template. Find the section for your solution below.

---

## Core Deployments

| Solution | Parameters | Examples |
|----------|-----------|---------|
| 🌐 **Networking** | [networking/README.md](../deployments/networking/README.md) | [parameter files](../deployments/networking/README.md) |
| 🔒 **Key Vaults** | [keyVaults/uiFormDefinition.json](../deployments/keyVaults/uiFormDefinition.json) *(see Quick Start Step 1)* | — |
| 📦 **Image Management** | [imageManagement/README.md — Parameters](../deployments/imageManagement/README.md#parameters) | [imageManagement/README.md — Examples](../deployments/imageManagement/README.md#examples) |
| 🎨 **Image Build** | [imageBuild/README.md — Parameters](../deployments/imageBuild/README.md#parameters) | [imageBuild/README.md — Examples](../deployments/imageBuild/README.md#examples) |
| 🏢 **Host Pool** | [hostpools/README.md — Parameters](../deployments/hostpools/README.md#parameters) | [hostpools/README.md — Examples](../deployments/hostpools/README.md#examples) |

---

## Naming Convention

All resource names across solutions are controlled by the `namingConvention` parameter. The default value produces CAF-compliant names. When customized, the same parameter object should be passed to every solution for a consistent enterprise naming strategy.

See the **[Naming Convention guide](naming-convention.md)** for:
- Full `namingConvention` parameter schema and property descriptions
- How the built-in CAF default works
- The eight naming segments and how `purpose` drives per-resource uniqueness
- How to align naming across hostpool, keyVaults, imageManagement, and add-ons
- Named examples for six common conventions
- [Scenario test results](naming-convention-test-results.md) for 8 scenarios across all solutions

---

## Add-Ons

| Add-On | Parameters |
|--------|-----------|
| 🔄 **Session Host Replacer** | [sessionHostReplacer/README.md](../deployments/add-ons/sessionHostReplacer/README.md) |
| 🖥️ **Session Hosts** | [sessionHosts/README.md](../deployments/add-ons/sessionHosts/README.md#parameters) |
| 📊 **Storage Quota Manager** | [storageQuotaManager/README.md](../deployments/add-ons/storageQuotaManager/README.md) |
| 🔑 **Update Storage Keys** | [updateStorageAccountKeyOnSessionHosts/README.md](../deployments/add-ons/updateStorageAccountKeyOnSessionHosts/README.md) |
| 📝 **Run Commands on VMs** | [runCommandsOnVms/README.md](../deployments/add-ons/runCommandsOnVms/README.md) |

---

## Cross-Solution Output Passing

When chaining deployments, use this mapping to pass outputs from one step to the next. See the **[End-to-End Automation Guide](automation-guide.md)** for the full pipeline diagram and scripted examples.

| Source | Output | Destination | Parameter |
|--------|--------|-------------|-----------|
| **keyVaults** | `secretsKeyVaultResourceId` | **hostpool** | `existingCredentialsKeyVaultResourceId` |
| **keyVaults** | `encryptionKeyVaultResourceId` | **imageManagement** | `encryptionKeyVaultResourceId` |
| **keyVaults** | `encryptionKeyVaultResourceId` | **hostpool** | `existingEncryptionKeyVaultResourceId` |
| **imageManagement** | `computeGalleryResourceId` | **imageBuild** | `computeGalleryResourceId` |
| **imageManagement** | `artifactsBlobContainerUrl` | **imageBuild** | `artifactsContainerUri` |
| **imageManagement** | `managedIdentityResourceId` | **imageBuild** | `userAssignedIdentityResourceId` |
| **imageManagement** | `buildLogsStorageAccountResourceId` | **imageBuild** | `logStorageAccountResourceId` |
| **imageManagement** | `imageBuildResourceGroupResourceId` | **imageBuild** | `imageBuildResourceGroupId` |
| **imageManagement** | `diskEncryptionSetResourceId` | **imageBuild** | `diskEncryptionSetResourceId` |
| **imageBuild** | image definition resource ID | **hostpool** | `customImageResourceId` |

---

## Compliance Configuration Reference

> **For the full ISSO/AO-facing compliance reference** — including control-by-control mappings to NIST SP 800-53 Rev 5 / FedRAMP High, DoD SRG IL4, and IL5, plus always-on controls and a shared-responsibility summary — see **[Compliance Control Mapping](compliance.md)**.

The tables below are a quick developer reference for which parameters to set. All compliance-relevant settings are optional — the solution defaults to functional minimums for maximum compatibility.

### NIST SP 800-53 Rev 5 / FedRAMP High

**Reference:** [NIST SP 800-53 Rev 5](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final)

| Control | Template | Parameter | Default | Compliant Value |
|---------|----------|-----------|---------|----------------|
| **SC-28** Protection of Information at Rest — VM disks | `hostpool.bicep` | `keyManagementDisks` | `PlatformManaged` | `CustomerManaged` or `CustomerManagedHSM` |
| **SC-28** Protection of Information at Rest — FSLogix storage | `hostpool.bicep` | `keyManagementStorage` | `PlatformManaged` | `CustomerManaged` or `CustomerManagedHSM` |
| **SC-28** Protection of Information at Rest — Recovery Services Vault | `hostpool.bicep` | `keyManagementRecoveryServicesVault` | `PlatformManaged` | `CustomerManaged` or `CustomerManagedHSM` — **see SC-28/SC-7 conflict note below** |
| **SC-28** Protection of Information at Rest — artifacts/build-log storage | `imageManagement.bicep` | `keyManagementStorageAccounts` | `PlatformManaged` | `CustomerManaged` or `CustomerManagedHSM` |
| **SC-28** Protection of Information at Rest — gallery image versions | `imageManagement.bicep` | `keyManagementGalleryImageVersions` | `PlatformManaged` | `CustomerManaged` or `CustomerManagedHSM` |
| **SC-28(1)** Encryption At Host *(supplemental)* | `hostpool.bicep` | `encryptionAtHost` | `true` | `true` ✅ *(already default — encrypts temp disk and host cache; not the primary IL5 disk encryption mechanism — see note below)* |
| **SC-7 / SC-5** Boundary Protection / DoS Protection | `hostpool.bicep` | `deployPrivateEndpoints` | `false` | `true` |
| **CP-9** Information System Backup — FSLogix zone resilience | `hostpool.bicep` | `fslogixStorageRedundancy` | `LocallyRedundant` | `ZoneRedundant` *(zone-enabled regions)* |
| **CP-6** Alternate Storage Site — personal VM backup | `hostpool.bicep` | `recoveryServicesVaultStorageRedundancy` | `LocallyRedundant` | `GeoRedundant` |
| **SI-3 / IA-3** Trusted Launch / integrity | `hostpool.bicep` | `securityType` | `TrustedLaunch` | `TrustedLaunch` ✅ *(already default)* |

> **SC-28 / SC-7 conflict — RSV CMK with private endpoints (RSV = Personal host pool VM backup vault only):** When `deployPrivateEndpoints = true` and `keyManagementRecoveryServicesVault = CustomerManaged`, two controls conflict. Azure Backup cannot reach a private-only Key Vault, creating an irreconcilable choice:
> - **Preserve SC-28 (CMK on RSV):** Set `encryptionKeyVaultForcePublicAccess = true`. The encryption Key Vault's `publicNetworkAccess` is set to Enabled and all IP-based firewall rules are cleared — SC-7 network isolation for that Key Vault is weakened.
> - **Preserve SC-7 (private-only KV):** Leave `encryptionKeyVaultForcePublicAccess = false` (default). The RSV silently falls back to platform-managed keys — SC-28 is not satisfied for RSV encryption.
>
> Neither option satisfies both controls. This is a **Microsoft Azure platform limitation**. For pooled host pools, CMK on the RSV has low security value — the RSV holds only backup scheduling metadata; actual FSLogix data remains in the storage account (encrypted via `keyManagementStorage`). For personal host pools with VM backup, the RSV holds full VM recovery points and CMK has meaningful SC-28 value. The choice is a risk decision for your ISSO and AO — document the selected option and formally accept the control gap in your SSP. See [BCDR Guide — Personal Host Pool VM Backup](bcdr.md#personal-host-pool-vm-backup) for the full Option A/B comparison.

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
|-------------|----------|-----------|---------------|
| Compute isolation (dedicated physical hosts) | `hostpool.bicep` | `deployToDedicatedHosts` | `true` |
| Dedicated host group | `hostpool.bicep` | `dedicatedHostGroupResourceId` | Resource ID of pre-provisioned dedicated host group |
| HSM key protection — VM disks | `hostpool.bicep` | `keyManagementDisks` | `CustomerManagedHSM` |
| HSM key protection — FSLogix storage | `hostpool.bicep` | `keyManagementStorage` | `CustomerManagedHSM` |
| HSM key protection — Recovery Services Vault | `hostpool.bicep` | `keyManagementRecoveryServicesVault` | `CustomerManagedHSM` |
| HSM key protection — artifacts/build-log storage | `imageManagement.bicep` | `keyManagementStorageAccounts` | `CustomerManagedHSM` |
| HSM key protection — gallery image versions | `imageManagement.bicep` | `keyManagementGalleryImageVersions` | `CustomerManagedHSM` |

> **Pre-requisite:** At least one dedicated host must be deployed in a dedicated host group in the target Azure Government region before deploying the host pool. See [Azure Dedicated Hosts documentation](https://learn.microsoft.com/en-us/azure/virtual-machines/dedicated-hosts).

> **Key Vault:** Using `CustomerManagedHSM` deploys Azure Key Vault Premium (FIPS 140 Level 3 validated HSM). To use a pre-existing Key Vault from the security deployment, set `existingEncryptionKeyVaultResourceId` accordingly.
