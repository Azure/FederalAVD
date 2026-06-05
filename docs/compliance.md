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

> **SC-28 / SC-7 conflict — RSV CMK with private endpoints (Microsoft Azure platform limitation):** Azure Backup has no `AzureServices` trusted service bypass for Key Vault. When both `deployPrivateEndpoints = true` and `keyManagementRecoveryServicesVault = CustomerManaged` are set, two mandatory controls are in direct conflict:
>
> - **Option A — preserve SC-28 (CMK on RSV):** Set `encryptionKeyVaultForcePublicAccess = true`. RSV uses customer-managed keys. The encryption Key Vault’s `publicNetworkAccess` changes from Disabled to Enabled and all IP-based firewall rules are cleared — SC-7 network isolation for the Key Vault is weakened; it becomes reachable by any authenticated principal on Azure’s public network.
> - **Option B — preserve SC-7 (private-only KV):** Leave `encryptionKeyVaultForcePublicAccess = false` (default). The Key Vault remains private-only. The RSV falls back to platform-managed keys — SC-28 is not satisfied for RSV encryption.
>
> Neither option satisfies both controls simultaneously. The default behavior is Option B (RSV falls back to PMK silently rather than failing the deployment). The choice between SC-28 and SC-7 for RSV encryption is a risk decision for your ISSO and Authorizing Official. Document the selected option and formally accept the resulting control gap in your SSP.

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
| CP-7 | Alternate Processing Site | When vault storage is GeoRedundant, Cross-Region Restore (CRR) is automatically enabled, allowing personal VMs to be restored to the paired region. This satisfies CP-7 when the Contingency Plan (CP-2) documents an acceptable RPO of hours. **Azure Site Recovery (ASR) replication is not implemented** — if sub-hour RPO is required, ASR would need to be added. The built-in Azure Policy "Audit virtual machines without disaster recovery configured" (ID `0015ea4d`) will flag personal VMs as non-compliant because it checks for ASR-specific resource links, not Azure Backup. A policy exemption with documented CP-2 justification is required when using Azure Backup + CRR as the CP-7 control. See [bcdr.md](bcdr.md#azure-site-recovery-asr-is-not-implemented) for the full comparison. | Configurable | `recoveryServicesVaultStorageRedundancy: GeoRedundant` |
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
| `encryptionKeyVaultForcePublicAccess` | *risk decision — see ¹* | *risk decision — see ¹* | *risk decision — see ¹* |
| `fslogixStorageRedundancy` | `ZoneRedundant` | `ZoneRedundant` | `ZoneRedundant` |
| `recoveryServicesVaultStorageRedundancy` | `GeoRedundant` | `GeoRedundant` | `GeoRedundant` |
| `recoveryServices` | `true` | `true` | `true` |
| `deployToDedicatedHosts` | *(optional)* | *(optional)* | `true` *(US Gov AZ/TX/VA)* |
| `securityType` | `TrustedLaunch` ✅ default | `TrustedLaunch` ✅ default | `TrustedLaunch` or `ConfidentialVM` |
| `encryptionAtHost` | `true` ✅ default | `true` ✅ default | `true` ✅ default |
| `enableMonitoring` | `true` ✅ default | `true` ✅ default | `true` ✅ default |

> ¹ **`encryptionKeyVaultForcePublicAccess` — SC-28 vs. SC-7 risk decision (Microsoft Azure platform limitation).** Azure Backup has no `AzureServices` trusted service bypass for Key Vault, creating an irreconcilable conflict when both CMK on RSV and private endpoints are required:
>
> - **`true` (Option A — preserve SC-28):** RSV uses customer-managed keys. The encryption Key Vault’s `publicNetworkAccess` changes from Disabled to Enabled and all IP-based firewall rules are cleared. SC-28 satisfied for RSV; SC-7 network isolation for the Key Vault weakened — Key Vault reachable from Azure public network by any authenticated principal.
> - **`false` (Option B — preserve SC-7, default):** Key Vault remains private-only. RSV falls back to platform-managed keys silently. SC-7 satisfied; SC-28 not satisfied for RSV.
>
> Neither option satisfies both controls. The default (`false`) is Option B. This is a compliance risk decision for your ISSO and AO — not a solution default or recommendation. Document the selected option and formally accept the resulting control gap in your SSP. All other CMK consumers (disk encryption, storage encryption) are unaffected by this parameter. When using a pre-created Encryption Key Vault from the standalone Key Vaults deployment, set this at vault creation time via the **Allow public network access on Encryption Key Vault** checkbox in the portal form.

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

## CMMC 2.0 Level 2 (Defense Industrial Base / CUI)

**Reference:** [CMMC 2.0 Model](https://dodcio.defense.gov/CMMC/Model/) | [NIST SP 800-171 Rev 2](https://csrc.nist.gov/pubs/sp/800/171/r2/upd1/final)

CMMC 2.0 Level 2 is required for any DoD contractor or subcontractor that handles **Controlled Unclassified Information (CUI)**. Level 2 aligns 1:1 with NIST SP 800-171 Rev 2 (110 practices across 14 domains). Because NIST 800-171 is derived from NIST 800-53, the controls already documented in the NIST 800-53 / FedRAMP High section above apply directly. The table below maps CMMC practice IDs to the solution's implementation.

> **Assessment scope:** CMMC Level 2 requires a third-party C3PAO assessment (or self-assessment for non-prioritized acquisitions). This mapping supports the evidence narrative — it documents what the AVD infrastructure provides. The organization's System Security Plan (SSP) and Security Assessment Report (SAR) must cover all 110 practices, including organizational, personnel, and physical domains not addressed here.

| CMMC Domain | Practice | Requirement Summary | Implementation | Type |
|------------|---------|-------------------|---------------|------|
| **AC** Access Control | 3.1.1 | Limit system access to authorized users and processes | Entra ID authentication; RBAC scoped to minimum roles; no public session host ports | Automatic |
| **AC** | 3.1.2 | Limit system access to authorized transaction types | Azure RBAC enforces operation-level permissions on all resources | Automatic |
| **AC** | 3.1.12 | Monitor and control remote access sessions | All AVD session traffic brokered through control plane; private endpoints optional | Configurable (`deployPrivateEndpoints: true`) |
| **AC** | 3.1.13 | Employ cryptographic mechanisms to protect remote access | TLS 1.2+ for all AVD sessions; HTTPS-only for all PaaS endpoints | Automatic |
| **AC** | 3.1.14 | Route remote access via managed access control points | AVD control plane is the sole access path; no direct RDP internet exposure | Automatic |
| **AC** | 3.1.19 | Encrypt CUI on mobile devices and portable storage | OS disk and data disk encrypted via Disk Encryption Set + CMK | Configurable (`keyManagementDisks: CustomerManaged`) |
| **AC** | 3.1.20 | Verify and control all connections to external systems | Private endpoints prevent data flow to/from external networks for PaaS resources | Configurable (`deployPrivateEndpoints: true`) |
| **AU** Audit & Accountability | 3.3.1 | Create and retain system audit logs to enable monitoring | AMA deployed to each session host; TerminalServices, System, and FSLogix events → Log Analytics. Key Vault audit logs enabled. Note: Windows Security event log not collected — see AU gap note. | Automatic (partial) |
| **AU** | 3.3.2 | Ensure audit log actions are traceable to users | TerminalServices events include user session context; Key Vault records include caller identity | Automatic (partial) |
| **IA** Identification & Authentication | 3.5.1 | Identify all system users, processes, and devices | Entra ID provides authoritative identity for all users and managed identities for all services | Automatic |
| **IA** | 3.5.2 | Authenticate all users, processes, and devices | Entra ID MFA (via CA Policy); managed identity tokens for service-to-service | External (CA) / Automatic |
| **IA** | 3.5.3 | Use MFA for local and network access | MFA enforced via Entra ID Conditional Access (outside template scope; applies to same identity plane) | External (CA Policy) |
| **IA** | 3.5.10 | Store and transmit only cryptographically-protected passwords | Passwords stored in Azure Key Vault (encrypted at rest). Never in parameter files or environment variables. | Automatic |
| **IA** | 3.5.11 | Obscure feedback of authentication information | Entra ID and Key Vault handle credential display — no raw password exposure in template outputs | Automatic |
| **SC** System & Communications Protection | 3.13.1 | Monitor and control communications at external boundaries | Private endpoints + `publicNetworkAccess: Disabled` enforce deny-by-default at PaaS boundary | Configurable (`deployPrivateEndpoints: true`) |
| **SC** | 3.13.2 | Employ architectural designs, software development techniques, and engineering principles | Subscription-scoped Bicep templates enforce consistent deployment; no ad-hoc resource creation | Automatic |
| **SC** | 3.13.5 | Implement subnetworks for publicly accessible system components | Session hosts deploy to private VNet subnets with no public IPs | Automatic |
| **SC** | 3.13.6 | Deny network communications traffic by default | `publicNetworkAccess: Disabled` on PaaS + private DNS = deny-by-default for all PaaS traffic | Configurable |
| **SC** | 3.13.8 | Implement cryptographic mechanisms to prevent unauthorized disclosure during transmission | TLS 1.2+ for AVD sessions; HTTPS-only for storage and Key Vault | Automatic |
| **SC** | 3.13.10 | Establish and manage cryptographic keys | CMK keys in Azure Key Vault with rotation policy. HSM option (FIPS 140-2 Level 3) available. | Configurable (`keyManagementDisks/Storage/RSV: CustomerManaged`) |
| **SC** | 3.13.16 | Protect the confidentiality of CUI at rest | CMK encryption on VM disks, FSLogix storage, RSV. Infrastructure double encryption always on. | Configurable (`keyManagementDisks/Storage/RSV: CustomerManaged`) |
| **SI** System & Information Integrity | 3.14.1 | Identify, report, and correct information and information system flaws | Trusted Launch + vTPM measured boot detects firmware/OS integrity violations | Automatic |
| **SI** | 3.14.6 | Monitor organizational systems to detect attacks and indicators of potential attacks | AVD Insights DCR → Log Analytics. Azure Monitor alerts configurable. SIEM integration outside scope. | Automatic |
| **SI** | 3.14.7 | Identify unauthorized use of organizational systems | TerminalServices session events logged; Key Vault access audited. Security event log gap applies. | Automatic (partial) |

### Minimum CMMC Level 2 Parameter Set

The NIST 800-53 / FedRAMP High parameter set (see table above) satisfies CMMC Level 2 infrastructure requirements. No additional parameters are required beyond those listed in the FedRAMP High section. However, the organization must also address the non-technical CMMC domains (AT, CM, IR, MA, MP, PS, PE, RA, CA) in its SSP.

---

## HIPAA Security Rule (Healthcare)

**Reference:** [45 CFR Part 164, Subpart C — Security Standards](https://www.hhs.gov/hipaa/for-professionals/security/index.html) | [NIST SP 800-66 Rev 2 (HIPAA Implementation Guide)](https://csrc.nist.gov/pubs/sp/800/66/r2/final)

HIPAA Technical Safeguards (§164.312) govern the technology and policy that protects ePHI (electronic Protected Health Information). This solution supports a HIPAA-compliant AVD deployment for healthcare organizations, health plans, and their business associates.

> **HIPAA flexibility note:** HIPAA uses "Required" and "Addressable" specifications. Addressable specifications must be implemented if reasonable and appropriate; if not, the organization must document why and implement an equivalent measure. This table notes which specification type applies.

| §164.312 Specification | Type | Requirement | Implementation | Parameter |
|----------------------|------|------------|---------------|-----------|
| **(a)(1)** Access Control — Unique User Identification | Required | Each user must have a unique identifier | Entra ID assigns unique user identities; no shared accounts in AVD | Automatic |
| **(a)(2)(i)** Unique User ID | Required | Assign unique name/number for tracking identity | Entra ID UPN/Object ID for all users and service principals | Automatic |
| **(a)(2)(iii)** Automatic Logoff | Addressable | Terminate session after inactivity | Configured via AVD host pool idle timeout and Windows session timeout policy (outside template scope) | External (GP/Intune) |
| **(a)(2)(iv)** Encryption and Decryption | Addressable | Mechanism to encrypt and decrypt ePHI | VM disks and FSLogix profile storage encrypted with CMK. Infrastructure double encryption always on. | Configurable (`keyManagementDisks/Storage: CustomerManaged`) |
| **(b)** Audit Controls | Required | Hardware/software/procedural mechanisms that record and examine activity | AMA + DCR deployed to each session host. Key Vault audit logs to Log Analytics. Note: Windows Security event log not collected — supplemental DCR required for full ePHI access audit trail. | Automatic (partial) |
| **(c)(1)** Integrity — Electronic Mechanism | Addressable | Protect ePHI from improper alteration or destruction | Trusted Launch vTPM provides measured boot. Azure Backup (RSV) for profile and file share protection. | Automatic + Configurable (`recoveryServices: true`) |
| **(d)** Person or Entity Authentication | Required | Verify that a person seeking access is the one claimed | Entra ID authentication for all AVD sessions. MFA via Conditional Access Policy (outside template scope). | External (CA Policy) |
| **(e)(1)** Transmission Security — Integrity Controls | Addressable | Guard against unauthorized modification of ePHI in transit | TLS 1.2+ for all AVD session traffic | Automatic |
| **(e)(2)(ii)** Transmission Security — Encryption | Addressable | Encrypt ePHI in transit when deemed appropriate | TLS 1.2+ for all PaaS endpoints. Private endpoints eliminate public transit path. | Configurable (`deployPrivateEndpoints: true`) |

### HIPAA Minimum Parameter Set

```json
{
  "keyManagementDisks": { "value": "CustomerManaged" },
  "keyManagementStorage": { "value": "CustomerManaged" },
  "deployPrivateEndpoints": { "value": true },
  "recoveryServices": { "value": true },
  "enableMonitoring": { "value": true }
}
```

> **Business Associate Agreements:** Azure's [HIPAA Business Associate Agreement](https://www.microsoft.com/en-us/trust-center/compliance/hipaa) covers the Azure platform services used by this solution. The deploying organization is responsible for executing a BAA with Microsoft before using Azure to store or process ePHI.

---

## CJIS Security Policy (Law Enforcement / Criminal Justice)

**Reference:** [CJIS Security Policy v5.9.2](https://le.fbi.gov/file-repository/cjis-security-policy-v5-9-2-20221214.pdf)

The CJIS Security Policy governs access to Criminal Justice Information (CJI) and applies to all agencies and contractors with access to FBI CJIS systems. AVD is commonly used as a secure remote access mechanism for law enforcement personnel accessing CJI.

| CJIS Section | Requirement | Implementation | Type |
|-------------|------------|---------------|------|
| **5.5** Access Control | Ensure only authorized individuals access CJI | Entra ID authentication + RBAC; no public exposure of session hosts | Automatic |
| **5.6.2.1** Advanced Authentication (MFA) | MFA required for all remote access to CJI | MFA enforced via Entra ID Conditional Access Policy (outside template scope; mandatory for any CJIS-compliant deployment) | External (CA Policy) |
| **5.6.2.2** Advanced Authentication — Phishing-Resistant | FIDO2 or certificate-based auth for privileged access | Entra ID supports FIDO2 and CBA with CAC/PIV | External (CA Policy) |
| **5.8.1** Boundary Protection | Isolate CJI systems from non-CJI systems | Private endpoints, VNet isolation, dedicated subnets. No session host public IPs. | Configurable (`deployPrivateEndpoints: true`) |
| **5.8.2** Encryption — Data at Rest | Encrypt CJI at rest using FIPS-validated cryptography (AES-256) | CMK disk and storage encryption using AES-256 in Key Vault. Infrastructure double encryption always on. | Configurable (`keyManagementDisks/Storage: CustomerManaged`) |
| **5.8.3** Encryption — Data in Transit | Encrypt CJI in transit (minimum AES-128, FIPS-validated) | TLS 1.2+ (AES-256 cipher suites) for all AVD session and PaaS traffic | Automatic |
| **5.8.4** Encryption — Key Management | Keys protected from unauthorized access; stored separately from encrypted data | CMK keys in Azure Key Vault (separate from the data they encrypt). Key access audited. | Automatic |
| **5.9** Formal Audits | Log access to CJI; retain audit logs | AMA + DCR deployed to session hosts. Key Vault access logs. Note: Windows Security event log gap — supplemental DCR required for full CJI access audit. | Automatic (partial) |
| **5.10** Personnel Security | Background checks, training (organizational, outside template scope) | — | Organizational |
| **5.11** Physical Protection | Physical security of terminals accessing CJI | Azure datacenter physical security inherited from platform. End-user device policies outside scope. | Inherited / External |
| **5.12** Systems and Communications Protection | Protect CJI during storage and transmission | Private DNS zones + private endpoints = no CJI traverses public internet. TLS for all sessions. | Configurable |
| **5.13** Formal Audits — System Audit | System must generate audit records for CJI access | Key Vault audit logs + TerminalServices session events collected. Windows Security event log required separately. | Automatic (partial) |

> **CJIS audit gap:** CJIS §5.9 requires logging of CJI access events. The AVD Insights DCR captures session connect/disconnect events but **not** the Windows Security event log (logon events 4624/4634, privilege use 4672). For CJIS compliance, a supplemental DCR or SIEM agent targeting the Security event log is required.

> **CJIS channel partner / CJIS Systems Agency (CSA):** Deploying organizations must obtain a signed CJIS Security Addendum with their state CSA. The Azure Government CJIS compliance package and [FBI CJIS audit documentation](https://learn.microsoft.com/en-us/azure/compliance/offerings/offering-cjis) cover the platform layer.

---

## StateRAMP (State and Local Government)

**Reference:** [StateRAMP Security Requirements](https://stateramp.org/security-requirements/)

StateRAMP is the state and local government equivalent of FedRAMP, using the same NIST SP 800-53 control baseline. StateRAMP authorization levels map directly to FedRAMP:

| StateRAMP Level | FedRAMP Equivalent | Applicability |
|----------------|-------------------|---------------|
| StateRAMP Ready | FedRAMP Ready | Pre-authorization status |
| StateRAMP Authorized — Low | FedRAMP Low | Low-impact state systems |
| StateRAMP Authorized — Moderate | FedRAMP Moderate | Most state agency systems |
| StateRAMP Authorized — High | FedRAMP High | High-impact state systems (CJI, tax, health) |

Because StateRAMP uses the identical NIST 800-53 control baseline, the FedRAMP High parameter set documented in this page satisfies StateRAMP High requirements. StateRAMP Moderate deployments may use a subset — CMK and HSM are recommended but `CustomerManaged` (standard Key Vault) rather than `CustomerManagedHSM` is typically acceptable at Moderate.

> **StateRAMP and CJIS:** Many state/local deployments require both StateRAMP and CJIS compliance simultaneously (e.g., a state portal used for law enforcement and general government). The CJIS Advanced Authentication requirement (MFA) is an additional requirement on top of StateRAMP controls — both are addressed by Entra ID Conditional Access Policy.

---

## IRS Publication 1075 (Federal Tax Information)

**Reference:** [IRS Publication 1075 (Rev. 10-2021)](https://www.irs.gov/pub/irs-pdf/p1075.pdf)

IRS Publication 1075 (P1075) governs the handling of Federal Tax Information (FTI) by federal, state, and local agencies receiving tax data from the IRS. It is based on NIST SP 800-53 Moderate and adds IRS-specific safeguards.

| P1075 Area | Requirement | Implementation | Notes |
|-----------|------------|---------------|-------|
| **Exhibit 7** — Encryption at Rest | FTI must be encrypted at rest using FIPS 140-2 validated cryptography | CMK disk and storage encryption. Infrastructure double encryption. Key Vault (Standard = FIPS 140-2 Level 1; Premium = Level 3 HSM). | `keyManagementDisks/Storage: CustomerManaged` |
| **Exhibit 7** — Encryption in Transit | FTI must be encrypted in transit (TLS 1.2 minimum) | TLS 1.2+ on all AVD sessions and PaaS endpoints | Automatic |
| **Exhibit 7** — Access Control | Role-based access; limit FTI access to authorized individuals | Entra ID + RBAC. MFA required via CA Policy. | External (CA) + Automatic |
| **Exhibit 7** — Audit Logging | Log all access to FTI systems; retain 3+ years | Log Analytics workspace. Retention configurable (`logAnalyticsWorkspaceRetention`). Note: Windows Security event log required for full FTI access audit. | Configurable |
| **Exhibit 7** — Network Protection | Separate FTI systems from non-FTI systems | Private endpoints + VNet isolation + dedicated subnets | Configurable (`deployPrivateEndpoints: true`) |
| **Exhibit 7** — Media Protection | Protect/sanitize media containing FTI | Azure managed disk encryption + secure delete. Azure Backup with RSV for retention management. | Automatic + Configurable |
| **Section 4** — Incident Response | Report FTI incidents to IRS within 24 hours | Organizational process; SIEM integration with Log Analytics enables detection | External (IR process) |
| **Section 4** — Annual Reviews | Annual P1075 compliance review | Organizational process; this mapping supports evidence collection | Organizational |

> **P1075 log retention:** IRS P1075 requires retaining audit logs for a minimum of 3 years. The default `logAnalyticsWorkspaceRetention` of 30 days is insufficient. Set a longer retention in Log Analytics (up to 2 years in hot tier) and configure Azure Monitor Log Analytics workspace archival or export to long-term storage for the remainder.

---

## ISO/IEC 27001:2022 (International / Commercial)

**Reference:** [ISO/IEC 27001:2022](https://www.iso.org/standard/27001) | [Azure ISO 27001 compliance documentation](https://learn.microsoft.com/en-us/azure/compliance/offerings/offering-iso-27001)

ISO 27001 is an internationally recognized information security management system (ISMS) standard used by commercial organizations and international government entities. Annex A controls map closely to NIST 800-53.

> **Platform inheritance:** Microsoft Azure holds ISO/IEC 27001:2022 certification. The Azure Government regions used for federal AVD deployments are covered under Microsoft's certification scope. The deploying organization inherits platform-level controls and is responsible for workload-layer controls documented here.

| ISO 27001 Annex A Control | Title | Implementation | Type |
|--------------------------|-------|---------------|------|
| **A.5.15** Access Control | Manage access rights | Entra ID + RBAC + managed identities | Automatic |
| **A.5.33** Protection of Records | Protect records from loss, destruction, falsification | Azure Backup (RSV) for VM and file share protection | Configurable (`recoveryServices: true`) |
| **A.8.5** Secure Authentication | Secure authentication mechanisms | Entra ID MFA (CA Policy); managed identities; Key Vault for secrets | External + Automatic |
| **A.8.7** Protection Against Malware | Protection against malware | Trusted Launch Secure Boot + vTPM; Defender for Endpoint integration | Automatic |
| **A.8.9** Configuration Management | Manage configurations of hardware, software, services | Infrastructure-as-code (Bicep) enforces consistent configuration; no manual drift | Automatic |
| **A.8.10** Information Deletion | Delete information when no longer required | Soft delete on Key Vault and Storage; RSV retention policies | Configurable |
| **A.8.15** Logging | Produce, store, protect, and analyze event logs | AMA + DCR + Log Analytics + Key Vault audit logs | Automatic |
| **A.8.20** Network Security | Secure and manage networks | Private endpoints, VNet isolation, private DNS | Configurable |
| **A.8.24** Use of Cryptography | CMK + HSM; key lifecycle management | Key Vault Standard or Premium; CMK on all data-bearing resources; key expiration enforced | Configurable |
| **A.8.25** Secure Development Life Cycle | Policies for secure software development | Infrastructure-as-code in Git; image build pipeline with integrity verification | Automatic |

> **Certification path:** Achieving ISO 27001 certification requires an accredited certification body (CB) audit of the organization's ISMS, not just the technical controls. This mapping supports the technical evidence package for Annex A controls but does not substitute for the full ISMS and Statement of Applicability (SoA).

---

## What This Solution Does Not Cover

The following are required for a complete authorization but are outside the scope of this deployment template. They must be documented separately in the SSP.

| Area | Requirement | Where to Address |
|------|-------------|-----------------|
| **Windows Security event log** | AU-2/AU-3 — full security audit trail (logon/logoff, privilege use, account management) | Supplemental security DCR or SIEM agent targeting `Security!*` event log |
| **MFA / Conditional Access** | IA-2(1), IA-2(2) — MFA for all privileged and non-privileged accounts | Entra ID Conditional Access Policy |
| **STIG / CIS hardening** | OS-level hardening of session host images — CM-6, CM-7, SI-3, SI-7 | See note below |
| **Incident Response** | IR-4, IR-5, IR-6 — detection, response, and reporting procedures | SIEM integration with Log Analytics workspace |
| **Vulnerability Management** | RA-5 — regular scanning of session hosts | Microsoft Defender for Cloud / Defender for Endpoint |
| **Network segmentation** | SC-7 deeper — NSG rules between subnets | Networking template + NSG configuration |
| **Zero Trust policy enforcement** | CISA ZTMM Optimal — continuous access evaluation, automated response | Conditional Access + Microsoft Sentinel or equivalent |
| **Personnel security** | PS controls | Organizational policy |
| **Physical security** | PE controls | Inherited from Azure platform authorization |

### OS Hardening — STIG / CIS / NIST Options

Session host OS hardening (CM-6, CM-7, SI-3, SI-7) is not applied by the infrastructure templates — it must be addressed in the image or at VM runtime. Three approaches are supported, and they can be combined:

#### Option 1 — Apply-STIGsAVD.ps1 (Recommended for DoD)

A ready-to-use script is included in this repository at [`customer/examples/artifacts/DoD-STIGs/Apply-STIGsAVD.ps1`](../customer/examples/artifacts/DoD-STIGs/Apply-STIGsAVD.ps1).

The script uses Microsoft's [LGPO.exe](https://www.microsoft.com/en-us/download/details.aspx?id=55319) to apply DISA STIG GPO packages from [public.cyber.mil](https://public.cyber.mil/stigs/gpo) to the local machine. It handles:

- Windows 10 and Windows 11 STIG GPOs
- Microsoft Edge, Firewall, Defender Antivirus, Internet Explorer STIGs
- Microsoft 365 / Office / Teams STIGs (detected automatically)
- Third-party application STIGs: Adobe Acrobat Pro/Reader, Google Chrome, Mozilla Firefox
- AVD-specific exceptions (remote interactive logon rights, ECC curve SSL fix that breaks AVD, firewall settings for non-domain joined VMs)
- Version stamping to `HKLM:\Software\DoD\STIG` for upgrade detection

**Deploy in image build (recommended):** Baking STIGs into the golden image means every session host starts hardened without per-VM execution time at deployment. Follow the standard artifacts workflow:

**Step 1 — Copy the example artifact to your customer artifacts folder:**

```powershell
Copy-Item -Path "customer\examples\artifacts\DoD-STIGs" `
          -Destination "customer\artifacts\" -Recurse -Force
```

**Step 2 — Upload to blob storage using `Update-ImageArtifacts.ps1`:**

`Update-ImageArtifacts.ps1` packages `customer/artifacts/DoD-STIGs/` as `DoD-STIGs.zip` and uploads it to the artifacts storage account. It also downloads the STIG GPO package from the URL in `downloads.json` into the artifact folder before packaging. See [Artifacts Guide](artifacts-guide.md) and [Update-ImageArtifacts.ps1 guide](update-image-artifacts.md) for full instructions.

```powershell
cd C:\repos\FederalAVD\deployments
.\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
```

> **Keep the STIG GPO package URL current.** The `DoDSTIGGPOPackage` entry in `customer/parameters/imageManagement/downloads.json` contains a direct link to the quarterly STIG GPO release from DISA — for example:
> ```
> "DownloadUrl": "https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_STIG_GPO_Package_October_2025.zip"
> ```
> DISA publishes a new package quarterly (typically January, April, July, October). The filename embeds the month and year. **Update the `DownloadUrl` in your `customer/parameters/imageManagement/downloads.json` whenever a new quarterly package is released**, then re-run `Update-ImageArtifacts.ps1` and rebuild your image (or re-apply via `sessionHostCustomizations`). The latest packages are listed at [public.cyber.mil/stigs/gpo](https://public.cyber.mil/stigs/gpo). Also update the `-Version` argument in your customizations entry to match (e.g., `'2026.04'` for the April 2026 release) so the version-tracking registry key stays current and upgrade detection works correctly.

**Step 3 — Add to the `customizations` parameter in your image build parameter file:**

```json
"customizations": {
  "value": [
    {
      "blobNameOrUri": "DoD-STIGs.zip",
      "arguments": ""
    }
  ]
}
```

Pass arguments to override defaults — for example, to target only specific applications or to run in upgrade mode:

```json
{
  "blobNameOrUri": "DoD-STIGs.zip",
  "arguments": "-CloudOnly 'True' -ApplicationsToSTIG '[\"Google Chrome\",\"Mozilla Firefox\"]'"
}
```

Use `-CloudOnly 'False'` for hybrid (domain-joined) session hosts. See [`customer/examples/artifacts/DoD-STIGs/README.md`](../customer/examples/artifacts/DoD-STIGs/README.md) for all parameters.

**Deploy at VM runtime:** To apply STIGs to an existing fleet without rebuilding the image — for example, after a quarterly STIG package update — add the same artifact reference to the `sessionHostCustomizations` parameter in the host pool deployment instead of `customizations` in the image build. The mechanism is identical; only the parameter name differs.

```json
"sessionHostCustomizations": {
  "value": [
    {
      "blobNameOrUri": "DoD-STIGs.zip",
      "arguments": "-Upgrade 'True' -Version '2025.10'"
    }
  ]
}
```

**Offline / air-gapped environments:** Pre-download the LGPO tool and STIG GPO package and place them in the `customer/artifacts/DoD-STIGs/` folder before running `Update-ImageArtifacts.ps1 -SkipDownloadingNewSources`. See [`customer/examples/artifacts/DoD-STIGs/README.md`](../customer/examples/artifacts/DoD-STIGs/README.md) for the exact file names expected.

#### Option 2 — DISA STIG GPOs and Intune Policies (Group Policy / MDM)

DISA publishes the full STIG GPO package and Intune-compatible policy packages directly:

| Resource | URL | Format |
|----------|-----|--------|
| STIG GPO packages (latest quarterly release) | [public.cyber.mil/stigs/gpo](https://public.cyber.mil/stigs/gpo) | ZIP (GPO backup format) |
| STIG Viewer (for reviewing individual findings) | [public.cyber.mil/stigs/srg-stig-tools](https://public.cyber.mil/stigs/srg-stig-tools) | Java app / XCCDF |
| Intune DISA STIG policy packages | [dl.dod.cyber.mil/wp-content/uploads/stigs/zip/](https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/) | ZIP (`.intunewin` or JSON) |
| Cyber.mil STIG library (all STIGs) | [public.cyber.mil/stigs](https://public.cyber.mil/stigs) | XCCDF / SCC / ZIP |

For Entra-joined (cloud-only) AVD fleets, import the Intune policy packages into Microsoft Intune and assign them to the session host device group. For hybrid-joined fleets, use Group Policy Objects applied via Active Directory.

#### Option 3 — NIST / CIS Baselines

For non-DoD organizations using NIST or CIS benchmarks instead of DISA STIGs:

| Baseline | Publisher | URL | Notes |
|----------|----------|-----|-------|
| NIST National Checklist Program (NCP) — Windows 11 | NIST | [nvd.nist.gov/ncp/repository](https://nvd.nist.gov/ncp/repository) | SCAP/XCCDF format; DISA STIGs are listed here too |
| CIS Benchmark — Microsoft Windows 11 | CIS | [cisecurity.org/benchmark/microsoft_windows_desktop](https://www.cisecurity.org/benchmark/microsoft_windows_desktop) | PDF + GPO files (CIS member download) |
| CIS Benchmark — Microsoft Windows Server | CIS | [cisecurity.org/cis-benchmarks](https://www.cisecurity.org/cis-benchmarks) | PDF + GPO files |
| CIS Hardened Images (Azure Marketplace) | CIS | Available in Azure Marketplace | Pre-hardened VM images; use as custom image source in `customImageResourceId` |
| Microsoft Security Baselines | Microsoft | [microsoft.com/en-us/download/details.aspx?id=55319](https://www.microsoft.com/en-us/download/details.aspx?id=55319) | LGPO-based; included in Security Compliance Toolkit |
| Azure Policy guest configuration — Windows baselines | Microsoft | [learn.microsoft.com/en-us/azure/governance/policy/samples/guest-configuration-baseline-windows](https://learn.microsoft.com/en-us/azure/governance/policy/samples/guest-configuration-baseline-windows) | Azure Policy initiative; audit or enforce via policy |

> **Recommended combination for FedRAMP High / DoD:** Apply the DISA STIG GPO package via `Apply-STIGsAVD.ps1` in the image build to satisfy CM-6 / SI-7 baseline requirements. Layer CIS Level 2 or Microsoft Security Baseline on top for defense-in-depth. Use Azure Policy guest configuration to continuously audit for drift after deployment.
