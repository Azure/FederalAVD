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
| **Key Vault and RSV audit logs** | All Key Vaults and the Recovery Services Vault emit diagnostic logs (AuditEvent, resource logs) to Log Analytics when `enableMonitoring: true` (the default). | AU-2, AU-3, AU-12 |
| **AVD Insights Data Collection** | The Azure Monitor Agent (AMA) extension and AVD Insights DCR are deployed directly to each session host VM at provisioning time. The DCR collects TerminalServices session events (connect/disconnect), System events (all levels), FSLogix operational events, Application errors/warnings, and AVD-specific performance counters. Sent to Log Analytics via the Data Collection Endpoint. **Does not collect Windows Security event log** — see gap note below. | AU-2, AU-12, SI-4 |
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

> **Gap — Windows Security event log:** The AVD Insights DCR implements the [Microsoft-prescribed data sources](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights) for the AVD Insights workbook. It does **not** collect the Windows Security event log (`Security!*`). For full AU-2 / AU-3 coverage — logon/logoff events (4624/4634), privilege use (4672), account management (4720), policy change (4719) — a supplemental DCR or SIEM agent targeting `Security!*` must be deployed separately. This is typically provided by a SIEM solution (Microsoft Sentinel, Splunk, etc.) and is outside the scope of this deployment template.

| Control | Title | Implementation | Type | Parameter / Feature |
|---------|-------|---------------|------|---------------------|
| AU-2 | Event Logging | AVD Insights DCR collects TerminalServices session events (connect/disconnect via `TerminalServices-RemoteConnectionManager/Admin` and `TerminalServices-LocalSessionManager/Operational`), all System events, FSLogix operational/admin events, and Application errors/warnings. Key Vault AuditEvent logs and RSV diagnostic logs flow to Log Analytics. Windows Security event log is **not** collected — see gap note above. | Automatic (partial) | `enableMonitoring: true` (default) |
| AU-3 | Content of Audit Records | DCR records include timestamp, source channel, event ID, level, and message. TerminalServices events include user session context (session ID, user name). Key Vault audit records include caller identity, operation name, result, and client IP. Gap: Security event log records with full user-identity-and-outcome fields (required for AU-3 privileged-access coverage) are not collected at the VM layer. | Automatic (partial) | `enableMonitoring: true` (default) |
| AU-9 | Protection of Audit Information | Log Analytics workspace data is protected by Azure RBAC. Session hosts hold only the `Monitoring Metrics Publisher` role on the DCR — write-only access to their own log stream, no read access to the workspace. | Automatic | Built-in |
| AU-12 | Audit Record Generation | The AMA extension (`AzureMonitorWindowsAgent`) and DCR association (`Microsoft.Insights/dataCollectionRuleAssociations`) are deployed directly to each session host VM within the Bicep template (`virtualMachines.bicep`). No manual agent installation or policy remediation is needed for VMs deployed by this template. A supplemental `avdSessionHostMonitoring` policy initiative (in `policy/`) is provided to enforce the same configuration on VMs added to the subscription outside the deployment template. | Automatic | `enableMonitoring: true` (default) |

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
| SI-4 | System Monitoring | AVD Insights DCR collects AVD-specific performance counters (CPU, memory, disk queue depth, user input delay) and TerminalServices/FSLogix session events for the AVD Insights workbook. Azure Monitor metric alerts and log query alerts can be configured against the Log Analytics workspace. Note: threat-detection (SI-4(2)) requires a SIEM integration outside the scope of this template. | Automatic | `enableMonitoring: true` (default) |
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

## Federal Zero Trust Standards

Federal agencies are required to implement Zero Trust Architecture (ZTA) under multiple mandates. The following standards apply to AVD deployments in federal environments.

### Applicable Standards

| Standard | Issuing Body | Scope | Key Requirement |
|----------|-------------|-------|----------------|
| [OMB M-22-09](https://www.whitehouse.gov/wp-content/uploads/2022/01/M-22-09.pdf) | OMB | All federal civilian agencies | Agencies must meet specific ZT targets by end of FY2024. Establishes five ZT pillars and mandates adoption of CISA ZTMM. |
| [CISA Zero Trust Maturity Model v2.0](https://www.cisa.gov/resources-tools/resources/zero-trust-maturity-model) | CISA | All federal civilian agencies | Primary maturity framework. Five pillars (Identity, Devices, Networks, Applications & Workloads, Data) with Traditional → Initial → Advanced → Optimal maturity levels. Recommended implementation framework for M-22-09. |
| [NIST SP 800-207](https://csrc.nist.gov/pubs/sp/800/207/final) | NIST | All federal agencies | Foundational ZTA architectural guidance. Defines the core principle: "never trust, always verify" — access decisions made per-request based on identity, device, and context, not network location. |
| [DoD Zero Trust Strategy (2022)](https://dodcio.defense.gov/Portals/0/Documents/Library/ZTStrategy.pdf) | DoD CIO | DoD components | DoD-specific ZT execution roadmap. Seven pillars (User, Device, Application & Workload, Data, Network & Environment, Automation & Orchestration, Visibility & Analytics). Targets ZT "Target Level" by FY2027. |
| [DoD Zero Trust Reference Architecture v2.0](https://dodcio.defense.gov/Portals/0/Documents/Library/ZT-RA.pdf) | DoD CIO | DoD components | Detailed technical reference. Maps ZT capabilities to DoD pillars and defines 91 ZT activities and 152 target capabilities. |

### CISA Zero Trust Maturity Model — AVD Control Mapping

The CISA ZTMM v2.0 is the primary implementation framework for federal civilian agencies. This solution provides capabilities across all five pillars.

#### Pillar 1: Identity

> ZTMM principle: Strong authentication for every access request; no implicit trust based on network location; privileged access management; continuous validation.

| ZTMM Capability | Implementation | Maturity Level | Type |
|----------------|---------------|----------------|------|
| MFA for all users | Entra ID authentication for all AVD sessions. MFA enforcement via Conditional Access Policy (outside template scope, same identity plane). | Advanced | External (Entra ID CA) |
| Phishing-resistant MFA for privileged users | FIDO2 / Windows Hello for Business (supported by Entra ID). | Advanced | External (Entra ID CA) |
| Non-person entity (NPE) authentication via managed identities | All service-to-service access uses system-assigned or user-assigned managed identities. No stored credentials, API keys, or SAS tokens in code. | Optimal | Automatic |
| Privileged access management | Key Vault secrets for domain join and VM admin credentials. RBAC scoped to minimum required roles. | Advanced | Automatic |
| Continuous access evaluation | Entra ID CAE applies to AVD sessions — token revocation on risk signal takes effect without waiting for token expiry. | Advanced | Automatic (platform) |

#### Pillar 2: Devices

> ZTMM principle: Device compliance verification before access; hardware-based attestation; continuous monitoring of device health.

| ZTMM Capability | Implementation | Maturity Level | Type |
|----------------|---------------|----------------|------|
| Device inventory and compliance | Session hosts are registered as managed devices via Entra ID join or hybrid join. | Initial | Automatic |
| Hardware-based attestation | Trusted Launch enables vTPM and Secure Boot. Guest Attestation extension validates boot integrity and is deployed to every session host. | Advanced | Automatic (`securityType: TrustedLaunch`) |
| Measured boot / boot integrity monitoring | vTPM records measured boot sequence. Deviations from baseline firmware/OS state are detectable via Integrity Monitoring. | Advanced | Automatic |
| Confidential computing attestation | Confidential VMs use AMD SEV-SNP or Intel TDX with hardware attestation — the hypervisor cannot read or modify guest memory. | Optimal | Configurable (`securityType: ConfidentialVM`) |
| Encryption of device storage | OS and data disks encrypted via Disk Encryption Set + CMK. Encryption at host adds VM temp disk and cache encryption. | Optimal | Configurable (`keyManagementDisks: CustomerManaged/HSM`) |

#### Pillar 3: Networks

> ZTMM principle: Micro-segmentation; encrypted traffic; deny-by-default; no implicit trust based on network location.

| ZTMM Capability | Implementation | Maturity Level | Type |
|----------------|---------------|----------------|------|
| Network micro-segmentation | Private endpoints for all PaaS resources. Session hosts in dedicated subnet. No direct internet exposure. | Advanced | Configurable (`deployPrivateEndpoints: true`) |
| Deny by default for PaaS | `publicNetworkAccess: Disabled` on all PaaS resources when private endpoints + no permitted IPs. | Advanced → Optimal | Configurable |
| Encrypted traffic (data in transit) | All AVD session traffic over TLS 1.2+. All PaaS endpoints HTTPS-only. | Optimal | Automatic |
| DNS-based exfiltration prevention | Private DNS zones resolve PaaS FQDNs to private IP addresses. No public DNS resolution of internal resources. | Advanced | Configurable (`deployPrivateEndpoints: true`) |
| Private connectivity to AVD control plane | AVD workspace and host pool private link prevents feed URL and broker traffic traversal over public internet. | Optimal | Configurable (`hostPoolPublicNetworkAccess`, `workspaceFeedPublicNetworkAccess`) |
| Azure Monitor private link | Azure Monitor data collection traffic routed through AMPLS private link scope — no monitoring data over public internet. | Advanced | Configurable (`azureMonitorPrivateLinkScopeResourceId`) |

#### Pillar 4: Applications and Workloads

> ZTMM principle: Application-level access control; least-privilege service access; secure pipelines; no implicit trust for internal services.

| ZTMM Capability | Implementation | Maturity Level | Type |
|----------------|---------------|----------------|------|
| Managed identity for workload authentication | Automation accounts, image build pipeline, FSLogix storage RBAC, Key Vault access — all use managed identities. | Optimal | Automatic |
| Least-privilege service access | Role assignments are scoped to the minimum required resource and role. | Advanced | Automatic |
| Secure image pipeline | Image build via Azure Image Builder with managed identity; images stored in Azure Compute Gallery with private access. | Advanced | Automatic (imageBuild template) |
| Key Vault for application secrets | Domain join and VM admin credentials retrieved from Key Vault at deploy time — never stored in template or parameter files. | Optimal | Configurable (`existingCredentialsKeyVaultResourceId`) |

#### Pillar 5: Data

> ZTMM principle: Data encryption at rest and in transit; CMK control over encryption keys; classification and labeling; data access auditing.

| ZTMM Capability | Implementation | Maturity Level | Type |
|----------------|---------------|----------------|------|
| Encryption at rest — all data-bearing resources | CMK encryption on VM disks, FSLogix storage, RSV, image storage, and gallery image versions. Infrastructure double encryption always on. | Optimal (with CMK) | Configurable (`keyManagementDisks/Storage/RSV: CustomerManaged`) |
| HSM-backed key protection | Azure Key Vault Premium (FIPS 140-2 Level 3 HSM) for all CMK keys. Keys never leave the HSM. | Optimal | Configurable (`*: CustomerManagedHSM`) |
| Key lifecycle management | Key expiration policy enforced (default 180 days). Key rotation triggers re-encryption of wrapped DEKs. | Advanced | Automatic (`keyExpirationInDays`) |
| Data access auditing | Key Vault audit logs (AuditEvent) capture all key operations (wrap/unwrap/get). Sent to Log Analytics. | Advanced | Automatic (`enableMonitoring: true`) |
| Data in transit encryption | TLS 1.2+ for all data flows. Azure Files SMB 3.0 with encryption. | Optimal | Automatic |

### DoD Zero Trust Alignment

For DoD components, the [DoD ZT Strategy](https://dodcio.defense.gov/Portals/0/Documents/Library/ZTStrategy.pdf) maps to the same underlying capabilities across seven DoD pillars. The key DoD-specific additions beyond the CISA ZTMM mapping above:

| DoD Pillar | DoD-Specific Requirement | Implementation |
|------------|------------------------|----------------|
| **User** | CAC/PIV authentication for privileged access | Entra ID supports certificate-based authentication (CBA) with CAC/PIV — configured via Conditional Access Policy outside template scope |
| **Device** | Dedicated physical compute isolation for IL5 | Azure Dedicated Hosts (`deployToDedicatedHosts: true`) — mandatory in US Gov AZ/TX/VA for IL5 |
| **Data** | HSM-backed CMK for all sensitive data | `CustomerManagedHSM` on all key management parameters |
| **Visibility & Analytics** | Continuous monitoring with automated response | SIEM integration with Log Analytics workspace (Microsoft Sentinel or third-party — outside template scope) |
| **Automation & Orchestration** | Policy-driven remediation for non-compliant resources | `avdSessionHostMonitoring` and `virtualMachineMonitoring` policy initiatives in `policy/` enforce AMA and DCR association on VMs added outside the template |

---

## What This Solution Does Not Cover

The following are required for a complete authorization but are outside the scope of this deployment template. They must be documented separately in the SSP.

| Area | Requirement | Where to Address |
|------|-------------|-----------------|
| **Windows Security event log** | AU-2/AU-3 — full security audit trail (logon/logoff, privilege use, account management) | Supplemental security DCR or SIEM agent targeting `Security!*` event log |
| **MFA / Conditional Access** | IA-2(1), IA-2(2) — MFA for all privileged and non-privileged accounts | Entra ID Conditional Access Policy |
| **STIG / CIS hardening** | OS-level hardening of session host images | Image build pipeline (Custom Script Extension, DSC, or golden image) |
| **Incident Response** | IR-4, IR-5, IR-6 — detection, response, and reporting procedures | SIEM integration with Log Analytics workspace |
| **Vulnerability Management** | RA-5 — regular scanning of session hosts | Microsoft Defender for Cloud / Defender for Endpoint |
| **Network segmentation** | SC-7 deeper — NSG rules between subnets | Networking template + NSG configuration |
| **Zero Trust policy enforcement** | CISA ZTMM Optimal — continuous access evaluation, automated response | Conditional Access + Microsoft Sentinel or equivalent |
| **Personnel security** | PS controls | Organizational policy |
| **Physical security** | PE controls | Inherited from Azure platform authorization |
