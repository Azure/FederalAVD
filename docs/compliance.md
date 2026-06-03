[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Compliance Control Mapping

This page maps Federal AVD solution capabilities to security control requirements across common federal compliance frameworks. It is intended as an authorization artifact — a starting point for documenting control implementation in a System Security Plan (SSP) or for review by an ISSO/AO.

> **Scope:** This mapping covers workload-layer controls implemented by this solution's Bicep templates. Azure platform-level controls (physical security, hypervisor isolation, SOC 2 / FedRAMP platform authorization) are inherited from Microsoft's Azure Government authorization package and are not repeated here. See [Azure compliance documentation](https://learn.microsoft.com/en-us/azure/compliance/) for the platform inheritance baseline.

---

## How Controls Are Implemented

Controls fall into two categories:

| Category | Meaning |
|----------|---------|
| **Automatic** | Implemented unconditionally — no parameter configuration required. Active in every deployment of this solution. |
| **Configurable** | Implemented when specific parameters are set. The default value is a functional minimum; the compliant value must be explicitly set for the target framework. |

---

## Always-On Controls (No Configuration Required)

The following security capabilities are active in every deployment regardless of parameter values.

| Capability | What It Does | Relevant Controls |
|------------|-------------|-------------------|
| **Infrastructure double encryption** | All storage accounts are deployed with `requireInfrastructureEncryption: true` — data is encrypted at rest with two independent encryption layers using platform-managed keys at the infrastructure level. | SC-28, SC-28(1) |
| **Managed Identities (no stored credentials)** | All Azure service-to-service access (image build, FSLogix storage RBAC, Key Vault access, automation) uses system-assigned or user-assigned managed identities. No passwords or connection strings are stored in code or parameter files. | IA-5(1), IA-5(7) |
| **Key Vault for secrets** | Domain join credentials and VM admin credentials are stored in Azure Key Vault, not in parameter files or environment variables. | IA-5(1), SC-12 |
| **RBAC least-privilege assignments** | Role assignments are scoped to the minimum required resource (storage share, Key Vault key, resource group). No Owner or broad Contributor assignments are made by the solution. | AC-3, AC-6 |
| **Trusted Launch (default)** | Session host VMs default to `securityType: TrustedLaunch` — enables vTPM, Secure Boot, and integrity monitoring. Prevents boot-level rootkits and unauthorized firmware modifications. | SI-3, SI-7 |
| **Encryption at Host** | `encryptionAtHost: true` is the default. Encrypts the VM temp disk and OS/data disk host cache at the physical host before data reaches Azure Storage. | SC-28(1) |
| **Diagnostic settings** | All Key Vaults and the Recovery Services Vault emit audit logs to Log Analytics when `enableMonitoring: true` (the default). | AU-2, AU-3, AU-12 |
| **AVD Insights Data Collection** | Session host performance counters and Windows Event logs are collected via DCR/DCE and associated with the Log Analytics workspace. | AU-2, AU-12, SI-4 |
| **TLS in transit** | All AVD session traffic uses RDP over TLS 1.2+. All Azure PaaS endpoints (storage, Key Vault) enforce HTTPS-only. | SC-8, SC-8(1) |
| **Private DNS Zones** | When private endpoints are deployed, DNS resolution for all PaaS resources is handled through private DNS zones rather than public DNS — preventing data exfiltration via DNS. | SC-20, SC-21 |

---

## NIST SP 800-53 Rev 5 / FedRAMP High

**Reference:** [NIST SP 800-53 Rev 5](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final) | [FedRAMP High Baseline](https://www.fedramp.gov/assets/resources/documents/FedRAMP_High_Security_Controls.xlsx)

### Access Control (AC)

| Control | Title | Implementation | Type | Parameter / Feature |
|---------|-------|---------------|------|---------------------|
| AC-3 | Access Enforcement | RBAC role assignments scoped to minimum required resources (Storage File Data SMB Share Contributor, Key Vault Crypto Service Encryption User, etc.) | Automatic | Built-in |
| AC-6 | Least Privilege | No broad Contributor or Owner assignments. All identities receive only the roles required for their specific function. | Automatic | Built-in |
| AC-17 | Remote Access | AVD session traffic is brokered through Azure Virtual Desktop control plane — direct RDP port exposure to session hosts is not required. Combined with private endpoints, no session host ports need to be internet-accessible. | Configurable | `deployPrivateEndpoints: true` |

### Audit and Accountability (AU)

| Control | Title | Implementation | Type | Parameter / Feature |
|---------|-------|---------------|------|---------------------|
| AU-2 | Event Logging | AVD Insights DCR collects Windows Security, System, and Application event logs from session hosts. Key Vault and RSV diagnostic logs flow to Log Analytics. | Automatic | `enableMonitoring: true` (default) |
| AU-3 | Content of Audit Records | Log Analytics records include timestamp, source, event type, user identity, and outcome fields. AVD Insights DCR captures the full WEF/WEC event payload. | Automatic | `enableMonitoring: true` (default) |
| AU-9 | Protection of Audit Information | Log Analytics workspace data is protected by Azure RBAC. The workspace and DCR are deployed as dedicated resources; session hosts have write-only access via DCR association. | Automatic | Built-in |
| AU-12 | Audit Record Generation | Data Collection Rules are associated with each session host at deployment time, ensuring continuous log collection without manual agent configuration. | Automatic | `enableMonitoring: true` (default) |

### Identification and Authentication (IA)

| Control | Title | Implementation | Type | Parameter / Feature |
|---------|-------|---------------|------|---------------------|
| IA-2 | Identification and Authentication | AVD user authentication is handled by Entra ID (all identity solutions). MFA enforcement is a conditional access policy outside the scope of this solution but applies to the same identity plane. | Automatic | Identity solution selection |
| IA-3 | Device Identification | Session hosts are Entra ID joined or hybrid joined and registered as managed devices. Trusted Launch vTPM provides hardware-based device attestation. | Automatic | `securityType: TrustedLaunch` (default) |
| IA-5(1) | Authenticator Management — Password-Based | VM admin and domain join credentials are stored in Key Vault, not in parameter files. Credentials are retrieved at deployment time via Key Vault secret reference. | Configurable | `virtualMachineAdminPasswordKvSecretName` |
| IA-5(7) | Authenticator Management — No Embedded Credentials | All Azure service-to-service authentication uses managed identities. No connection strings, storage account keys, or SAS tokens are embedded in code or configuration. | Automatic | Built-in |

### System and Communications Protection (SC)

| Control | Title | Implementation | Type | Parameter / Feature |
|---------|-------|---------------|------|---------------------|
| SC-7 | Boundary Protection | Private endpoints restrict PaaS access to the virtual network. No public internet path to storage accounts or Key Vaults when `deployPrivateEndpoints: true` and no `permittedIPs` are specified. | Configurable | `deployPrivateEndpoints: true` |
| SC-7(5) | Boundary Protection — Deny by Default | When private endpoints are deployed with no permitted IPs, `publicNetworkAccess: Disabled` is set on all PaaS resources — deny-by-default posture. | Configurable | `deployPrivateEndpoints: true`, no `permittedIPs` |
| SC-8 | Transmission Confidentiality | All AVD session traffic uses TLS 1.2+. AVD workspace and host pool can be configured with private link to prevent feed URL traversal over public internet. | Configurable | `hostPoolPublicNetworkAccess`, `workspaceFeedPublicNetworkAccess` |
| SC-8(1) | Cryptographic Protection | All Azure PaaS endpoints enforce HTTPS-only. Storage accounts reject HTTP. Key Vaults enforce TLS. | Automatic | Built-in |
| SC-12 | Cryptographic Key Establishment | Encryption keys are stored in Azure Key Vault (Standard or Premium/HSM). Key rotation policy is enforced with configurable expiration period (`keyExpirationInDays`, default 180 days). | Automatic | `keyExpirationInDays` |
| SC-20 | Secure Name/Address Resolution | Private DNS zones resolve PaaS hostnames to private IP addresses within the VNet, preventing public DNS resolution of internal resources. | Configurable | `deployPrivateEndpoints: true` + DNS zone parameters |
| SC-28 | Protection of Information at Rest — VM disks | Session host OS and data disks are encrypted using a Disk Encryption Set with customer-managed keys in Key Vault. | Configurable | `keyManagementDisks: CustomerManaged` or `CustomerManagedHSM` |
| SC-28 | Protection of Information at Rest — FSLogix storage | Azure Files storage accounts are encrypted with customer-managed keys. Infrastructure double encryption is always on. | Configurable | `keyManagementStorage: CustomerManaged` or `CustomerManagedHSM` |
| SC-28 | Protection of Information at Rest — Recovery Services Vault | Personal host pool RSV is encrypted with a host-pool-scoped customer-managed key using the vault's system-assigned identity. | Configurable | `keyManagementRecoveryServicesVault: CustomerManaged` or `CustomerManagedHSM` |
| SC-28(1) | Cryptographic Protection — supplemental | Encryption at host encrypts temp disk and disk caches at the physical host. Infrastructure double encryption adds a second platform-managed encryption layer on all storage. | Automatic | `encryptionAtHost: true` (default) |

### System and Information Integrity (SI)

| Control | Title | Implementation | Type | Parameter / Feature |
|---------|-------|---------------|------|---------------------|
| SI-3 | Malicious Code Protection | Trusted Launch enables Secure Boot and vTPM. Microsoft Defender for Endpoint can be deployed via Custom Script Extension. | Automatic | `securityType: TrustedLaunch` (default) |
| SI-4 | System Monitoring | AVD Insights DCR collects performance counters and event logs. Azure Monitor alerts can be configured against the Log Analytics workspace. | Automatic | `enableMonitoring: true` (default) |
| SI-7 | Software, Firmware, and Information Integrity | Trusted Launch vTPM provides measured boot — any modification to boot firmware or early-stage OS components is detected and logged. Confidential VMs add hardware-level attestation. | Configurable | `securityType: TrustedLaunch` (default) or `ConfidentialVM` |

### Contingency Planning (CP)

| Control | Title | Implementation | Type | Parameter / Feature |
|---------|-------|---------------|------|---------------------|
| CP-6 | Alternate Storage Site | Recovery Services Vault storage redundancy can be set to GeoRedundant to replicate backup data to a paired region. | Configurable | `recoveryServicesVaultStorageRedundancy: GeoRedundant` |
| CP-9 | Information System Backup — FSLogix profiles | Azure Backup snapshot policy protects FSLogix Azure Files shares (pooled) or VM disks (personal). | Configurable | `recoveryServices: true` |
| CP-9 | Information System Backup — zone resilience | Azure Files storage can be deployed with Zone Redundant Storage to survive an availability zone failure without restore. | Configurable | `fslogixStorageRedundancy: ZoneRedundant` |

---

## DoD Cloud Computing SRG — Impact Level 4 (IL4)

**Reference:** [DoD Cloud Computing SRG](https://public.cyber.mil/dccs/dccs-documents/) | [Azure Government IL4 documentation](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-impact-level-4)

IL4 builds on FedRAMP High. All NIST 800-53 / FedRAMP High controls above apply. The following are additional or modified requirements.

| Requirement | Implementation | Type | Parameter / Feature |
|-------------|---------------|------|---------------------|
| Data must reside in US Government regions | Deploy to `usgovvirginia`, `usgovarizona`, or `usgovtexas` (or US DoD regions). The solution supports all Azure Government regions. | Configurable | `location` parameter |
| Encryption in transit for all data flows | TLS enforced on all PaaS endpoints. AVD session traffic encrypted. Storage accounts reject HTTP. | Automatic | Built-in |
| Customer-managed encryption keys | All data-bearing resources (VM disks, FSLogix storage, RSV) must use CMK. | Configurable | `keyManagementDisks`, `keyManagementStorage`, `keyManagementRecoveryServicesVault` → `CustomerManaged` |
| No public internet exposure for sensitive workloads | Private endpoints deployed for storage, Key Vault, RSV, and AVD workspace/host pool. | Configurable | `deployPrivateEndpoints: true` |
| Audit logging | Log Analytics workspace + AVD Insights DCR active. Key Vault and RSV diagnostic logs enabled. | Automatic | `enableMonitoring: true` (default) |
| MFA for all administrative access | Enforced via Entra ID Conditional Access Policy — outside this solution's scope but applies to the same identity plane. | External | Entra ID CA Policy |

---

## DoD Cloud Computing SRG — Impact Level 5 (IL5)

**Reference:** [Azure Government IL5 documentation](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-impact-level-5)

IL5 adds compute isolation and HSM requirements on top of IL4. All IL4 controls above apply.

> **Dedicated Hosts are mandatory in US Gov regions.** Per the DoD SRG and [Azure Government IL5 guidance](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-impact-level-5#virtual-machines): *"When you deploy VMs in Azure Government regions US Gov Arizona, US Gov Texas, and US Gov Virginia, you must use Azure Dedicated Host."* In the dedicated DoD regions (US DoD Central, US DoD East) physical separation is provided by design and Dedicated Hosts are not required.
>
> **Exemptions:** If Dedicated Hosts are operationally or financially infeasible, request a technical exception through your AO. Exceptions must be documented in the SSP with compensating controls and a risk acceptance signed by the AO.

| Requirement | Implementation | Type | Parameter / Feature |
|-------------|---------------|------|---------------------|
| Compute isolation — dedicated physical hosts (US Gov AZ/TX/VA) | Session host VMs are deployed to pre-provisioned Azure Dedicated Host(s) in a Dedicated Host Group. | Configurable | `deployToDedicatedHosts: true`, `dedicatedHostGroupResourceId` |
| HSM-backed encryption keys (FIPS 140-2 Level 3) | Deploys Azure Key Vault Premium. All CMK keys are generated in and never leave the HSM. Applies to VM disks, FSLogix storage, RSV, and image management resources. | Configurable | `keyManagementDisks: CustomerManagedHSM` `keyManagementStorage: CustomerManagedHSM` `keyManagementRecoveryServicesVault: CustomerManagedHSM` |
| HSM keys for image pipeline storage | Build log storage accounts and Compute Gallery image versions are encrypted with HSM-backed CMK. | Configurable | `keyManagementStorageAccounts: CustomerManagedHSM` `keyManagementGalleryImageVersions: CustomerManagedHSM` *(imageManagement.bicep)* |
| Disk encryption via SSE + CMK (not EAH alone) | Server-Side Encryption with a Disk Encryption Set + CMK is the IL5-compliant mechanism. `encryptionAtHost` is a complementary control but does not satisfy IL5 storage isolation on its own. | Configurable | `keyManagementDisks: CustomerManagedHSM` |
| VM private disk access (optional deep isolation) | Disk Access resource with private endpoint prevents any direct internet access to managed disk URIs. Deployed automatically for personal host pools when `deployPrivateEndpoints: true`. | Automatic (when applicable) | `deployPrivateEndpoints: true` + personal host pool |

### Complete IL5 Parameter Set

Apply these in addition to the IL4 values above:

```json
{
  "deployToDedicatedHosts": { "value": true },
  "dedicatedHostGroupResourceId": { "value": "/subscriptions/.../dedicatedHostGroups/dhg-avd-prod" },
  "keyManagementDisks": { "value": "CustomerManagedHSM" },
  "keyManagementStorage": { "value": "CustomerManagedHSM" },
  "keyManagementRecoveryServicesVault": { "value": "CustomerManagedHSM" },
  "deployPrivateEndpoints": { "value": true },
  "recoveryServicesVaultStorageRedundancy": { "value": "GeoRedundant" },
  "fslogixStorageRedundancy": { "value": "ZoneRedundant" },
  "recoveryServices": { "value": true }
}
```

And for image management:

```json
{
  "keyManagementStorageAccounts": { "value": "CustomerManagedHSM" },
  "keyManagementGalleryImageVersions": { "value": "CustomerManagedHSM" }
}
```

---

## Confidential Computing (Optional Deep Isolation)

For workloads requiring hardware-level memory encryption and attestation (beyond IL5 compute isolation):

| Capability | Implementation | Parameter |
|------------|---------------|-----------|
| Hardware-isolated VM execution | Confidential VMs use AMD SEV-SNP or Intel TDX to encrypt VM memory in hardware. The hypervisor cannot read guest memory. | `securityType: ConfidentialVM` |
| Confidential OS disk encryption | OS disk encrypted using a key that is bound to the vTPM attestation state — the key is only released after successful platform attestation. | `securityType: ConfidentialVM` + `keyManagementDisks: CustomerManagedHSM` |
| Key release policy | The CMK key release policy enforces that the key is only released to a VM that has passed Azure confidential computing attestation. Implemented via `cvmKeyReleasePolicy` in the customerManagedKeys module. | Automatic when `ConfidentialVM` |

---

## Summary: Minimum Parameter Set by Framework

| Parameter | FedRAMP High | IL4 | IL5 |
|-----------|-------------|-----|-----|
| `keyManagementDisks` | `CustomerManaged` | `CustomerManaged` | `CustomerManagedHSM` |
| `keyManagementStorage` | `CustomerManaged` | `CustomerManaged` | `CustomerManagedHSM` |
| `keyManagementRecoveryServicesVault` | `CustomerManaged` | `CustomerManaged` | `CustomerManagedHSM` |
| `deployPrivateEndpoints` | `true` | `true` | `true` |
| `fslogixStorageRedundancy` | `ZoneRedundant` | `ZoneRedundant` | `ZoneRedundant` |
| `recoveryServicesVaultStorageRedundancy` | `GeoRedundant` | `GeoRedundant` | `GeoRedundant` |
| `recoveryServices` | `true` | `true` | `true` |
| `deployToDedicatedHosts` | *(optional)* | *(optional)* | `true` *(US Gov AZ/TX/VA)* |
| `securityType` | `TrustedLaunch` ✅ default | `TrustedLaunch` ✅ default | `TrustedLaunch` or `ConfidentialVM` |
| `encryptionAtHost` | `true` ✅ default | `true` ✅ default | `true` ✅ default |
| `enableMonitoring` | `true` ✅ default | `true` ✅ default | `true` ✅ default |

---

## What This Solution Does Not Cover

The following are required for a complete authorization but are outside the scope of this deployment template. They must be documented separately in the SSP.

| Area | Requirement | Where to Address |
|------|-------------|-----------------|
| **MFA / Conditional Access** | IA-2(1), IA-2(2) — MFA for all privileged and non-privileged accounts | Entra ID Conditional Access Policy |
| **STIG / CIS hardening** | OS-level hardening of session host images | Image build pipeline (Custom Script Extension, DSC, or golden image) |
| **Incident Response** | IR-4, IR-5, IR-6 — detection, response, and reporting procedures | SIEM integration with Log Analytics workspace |
| **Vulnerability Management** | RA-5 — regular scanning of session hosts | Microsoft Defender for Cloud / Defender for Endpoint |
| **Network segmentation** | SC-7 deeper — NSG rules between subnets | Networking template + NSG configuration |
| **Personnel security** | PS controls | Organizational policy |
| **Physical security** | PE controls | Inherited from Azure platform authorization |
