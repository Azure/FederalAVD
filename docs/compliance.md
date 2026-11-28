[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Compliance Control Mapping

This page maps Federal AVD solution capabilities to security control requirements across common federal compliance frameworks. It is engineering implementation guidance — a starting point for documenting control implementation in a System Security Plan (SSP) or for review by an ISSO/AO, not an attestation or authorization.

> **Scope:** This mapping covers workload-layer capabilities available in this solution's Bicep templates. Platform-level controls may be inherited from the applicable Azure cloud and service authorization package; verify the service's audit scope and shared responsibilities rather than assuming every deployment inherits the same Azure Government baseline. See [Azure compliance documentation](https://learn.microsoft.com/en-us/azure/compliance/).

See [Secure Endpoint Architecture](secure-endpoint-architecture.md) for the control-layer,
shared-responsibility, lifecycle, and evidence model behind these mappings. Neither that architecture
nor this mapping establishes compliance without organization-specific configuration, validation,
evidence, assessment, and authorization.

---

## How Controls Are Implemented

The implementation types describe capabilities in the selected deployment path, not proof that an entire control is satisfied:

| Category | Meaning |
| --- | --- |
| **Automatic** | Applied by the relevant deployment path without an additional feature switch; verify that the resource and path are actually used. |
| **Configurable** | Applied when the relevant feature and parameters are selected. Defaults are deployment choices, not a determination of compliance with a framework. |
| **Partial** | Provides some implementation evidence; additional technical or organizational controls are needed. |
| **External / Organizational** | Requires configuration or procedures outside these templates. |
| **Inherited** | Relies on the applicable platform control and its authorization evidence. |

---

## Built-In and Default Security Capabilities

The following capabilities apply to the relevant resources and deployment paths. Monitoring,
credential storage, private connectivity, and VM security features can be conditional or configurable.
Adopted resources require separate configuration evidence; their existence does not prove these settings.

| Capability | What It Does | Relevant Controls |
| --- | --- | --- |
| **Infrastructure encryption** | Where `requireInfrastructureEncryption: true` is configured, Azure Storage adds an independent infrastructure encryption layer to service-level encryption. This is separate from selecting CMK and from managed-disk double encryption. | SC-28, SC-28(1) |
| **Managed Identities (no stored credentials)** | All Azure service-to-service access (image build, FSLogix storage RBAC, Key Vault access, automation) uses system-assigned or user-assigned managed identities. No passwords or connection strings are stored in code or parameter files. | IA-5(1), IA-5(7) |
| **Key Vault for secrets** | Key Vault credential paths keep domain join and VM admin credentials out of parameter values. Other supported credential paths require separate handling and evidence. | IA-5(1), SC-12 |
| **Scoped RBAC assignments** | Resource, key, share, resource-group, and subscription scopes are used according to the workflow. Some orchestration paths require Contributor or RBAC administration roles; review the exact grants rather than assuming every assignment is resource-level least privilege. | AC-3, AC-6 |
| **Trusted Launch (default)** | Session host VMs default to `securityType: TrustedLaunch` — enables vTPM, Secure Boot, and integrity monitoring. Prevents boot-level rootkits and unauthorized firmware modifications. | SI-3, SI-7 |
| **Encryption at Host** | `encryptionAtHost: true` is the default. Encrypts the VM temp disk and OS/data disk host cache at the physical host before data reaches Azure Storage. | SC-28(1) |
| **Key Vault and RSV audit logs** | All Key Vaults and the Recovery Services Vault emit diagnostic logs (AuditEvent, resource logs) to Log Analytics when `enableMonitoring: true` (the default). | AU-2, AU-3, AU-12 |
| **AVD Insights Data Collection** | The Azure Monitor Agent (AMA) extension and AVD Insights DCR are deployed directly to each session host VM at provisioning time. The DCR collects TerminalServices session events (connect/disconnect), System events (all levels), FSLogix operational events, Application errors/warnings, and AVD-specific performance counters. Sent to Log Analytics via the Data Collection Endpoint. **Does not collect Windows Security event log** — see gap note below. | AU-2, AU-12, SI-4 |
| **TLS in transit** | All AVD session traffic uses RDP over TLS 1.2+. All Azure PaaS endpoints (storage, Key Vault) enforce HTTPS-only. | SC-8, SC-8(1) |
| **Private DNS Zones** | Private DNS supports resolution of private endpoint addresses when zones, links, and client resolvers are configured correctly. It does not by itself prevent DNS exfiltration or implement DNSSEC. | SC-20, SC-21 (partial) |

---

## Encryption Requirements, Policy Mappings, and Configuration Choices

Keep three layers separate when selecting encryption settings:

1. **Framework controls:** NIST SP 800-53 Rev. 5 SC-12, SC-13, and SC-28 address
   key management and cryptographic protection using organization-defined requirements.
   They do not universally mandate Azure customer-managed keys, double encryption, or a
   particular Key Vault SKU. Applicable baselines, contracts, and authorization conditions
   can impose additional requirements.
2. **Microsoft mappings:** Defender for Cloud and Azure Policy map specific Azure
   configuration checks to broader controls. A mapped recommendation is not the literal
   text of the control, and a policy compliance result is only part of the evidence.
3. **Assigned policy behavior:** Findings and enforcement depend on the assigned initiative
   version, cloud, scope, parameters, effect, and exemptions. A recommendation's existence
   does not mean that it is enabled or required for every workload.

Managed disks and Azure Storage are encrypted at rest with platform-managed keys by default.
CMK provides customer control of key management; choose CMK, double encryption, and HSM
protection according to the applicable requirements or a deliberate security design.
Do not assume either that CMK is universally mandatory or that platform-managed keys satisfy
every applicable authorization or policy.

For example, policy **"Managed disks should be double encrypted with both platform-managed
and customer-managed keys"** (`ca91455f-eace-4f96-be59-e6e2c35b4816`) checks
`Microsoft.Compute/diskEncryptionSets/encryptionType` for
`EncryptionAtRestWithPlatformAndCustomerKeys`. It does not inspect every managed disk or
establish full encryption compliance. The reviewed NIST SP 800-53 Rev. 5 and FedRAMP High
built-in definitions map it to **SC-12** and default its effect to **Audit**; the actual
assignment may differ. Confidential VM encryption types do not satisfy this double-encryption
check merely by using HSM-backed CMK; review applicability and any approved exemption separately.

**Sources checked 2026-11-28:** [NIST control catalog](https://csrc.nist.gov/projects/risk-management/sp800-53-controls),
[Microsoft's NIST mapping guidance](https://learn.microsoft.com/en-us/azure/compliance/offerings/offering-nist-800-53),
[Defender data recommendations](https://learn.microsoft.com/en-us/azure/defender-for-cloud/recommendations-reference-data),
[disk double-encryption policy](https://github.com/Azure/azure-policy/blob/master/built-in-policies/policyDefinitions/Compute/DoubleEncryptionRequired_Deny.json),
[NIST initiative](https://github.com/Azure/azure-policy/blob/master/built-in-policies/policySetDefinitions/Regulatory%20Compliance/NIST_SP_800-53_R5.json),
and [FedRAMP High initiative](https://github.com/Azure/azure-policy/blob/master/built-in-policies/policySetDefinitions/Regulatory%20Compliance/FedRAMP_H_audit.json).
Recheck the assigned definitions and deployed resources when preparing assessment evidence.

---

> **⚠️ Log Analytics Workspace may be a compliance prerequisite, not just a CMK prerequisite.** Government/commercial subscriptions under FedRAMP High, DoD IL4/IL5, or CMMC governance frequently have management-group-level Azure Policy initiatives assigned that include **`DeployIfNotExists`** diagnostic-settings policies — for example, the built-in [*Deploy Diagnostic Settings for Key Vault to Log Analytics workspace*](https://portal.azure.com/#blade/Microsoft_Azure_Policy/PolicyDetailBlade/definitionId/%2Fproviders%2FMicrosoft.Authorization%2FpolicyDefinitions%2Fbef3f64c-5290-43b7-85b0-9b254eef4c47) policy (ID `bef3f64c-5290-43b7-85b0-9b254eef4c47`) and its newer replacement, [*Enable logging by category group for Key vaults ... to Log Analytics*](https://portal.azure.com/#blade/Microsoft_Azure_Policy/PolicyDetailBlade/definitionId/%2Fproviders%2FMicrosoft.Authorization%2FpolicyDefinitions%2F6b359d8f-f88d-4052-aa7c-32015963ecc1) (ID `6b359d8f-f88d-4052-aa7c-32015963ecc1`). These policies require a **target Log Analytics Workspace resource ID** to be specified as a policy assignment parameter before they can remediate (auto-configure diagnostic settings on) newly created Key Vaults, storage accounts, and other resources. If no workspace exists yet when this solution's Key Vaults or storage accounts are created, policy remediation either fails or leaves the resource flagged non-compliant until someone manually re-runs remediation against the correct workspace.
>
> **Recommendation:** In any workload subscription with these policy initiatives assigned, deploy [AVD Shared Services](../deployments/sharedServices/README.md) with `deployMonitoring: true` **first**, then supply its `logAnalyticsWorkspaceResourceId` output to your policy assignment parameters. By default monitoring uses the operations subscription; set `logAnalyticsWorkspaceSubscriptionId` when the target workspace must live in a centralized monitoring subscription. This turns Step 1 from an optional CMK-only step into an effective compliance prerequisite for policy-governed environments.

**IL6/IL7 posture:** For Azure Government Secret and Top Secret, deploy AVD Shared Services as
the default baseline even when it is not a hard template dependency. Its centralized logging,
monitoring, secrets, and key-management capabilities support implementation evidence for AU-2,
AU-3, AU-12, SI-4, IA-5, and SC-12. Omit the deployment only when approved shared services provide
equivalent capabilities and the responsible control owners have documented that coverage. This
recommendation is implementation guidance, not an authorization or certification determination.

---

## NIST SP 800-53 Rev 5 / FedRAMP High

**Reference:** [NIST SP 800-53 Rev 5](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final) | [FedRAMP High Baseline](https://www.fedramp.gov/assets/resources/documents/FedRAMP_High_Security_Controls.xlsx)

### Access Control (AC)

| Control | Title | Implementation | Type | Parameter / Feature |
| --- | --- | --- | --- | --- |
| AC-3 | Access Enforcement | RBAC role assignments scoped to minimum required resources (Storage File Data SMB Share Contributor, Key Vault Crypto Service Encryption User, etc.) | Automatic | Built-in |
| AC-6 | Least Privilege | Workflow-specific RBAC assignments provide access-control evidence. Review resource-group and subscription grants, including deployment-helper Contributor/RBAC administration permissions, against the approved least-privilege design. | Automatic (partial) | Built-in role assignments; selected orchestration path |
| AC-17 | Remote Access | AVD session traffic is brokered through Azure Virtual Desktop control plane — direct RDP port exposure to session hosts is not required. Combined with private endpoints, no session host ports need to be internet-accessible. | Configurable | AVD Private Link inputs; independent of Backup/disk endpoints |

### Audit and Accountability (AU)

> **Gap — Windows Security event log:** The AVD Insights DCR implements the [Microsoft-prescribed data sources](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights) for the AVD Insights workbook. It does **not** collect the Windows Security event log (`Security!*`). For full AU-2 / AU-3 coverage — logon/logoff events (4624/4634), privilege use (4672), account management (4720), policy change (4719) — a supplemental DCR or SIEM agent targeting `Security!*` must be deployed separately. This is typically provided by a SIEM solution (Microsoft Sentinel, Splunk, etc.) and is outside the scope of this deployment template.

| Control | Title | Implementation | Type | Parameter / Feature |
| --- | --- | --- | --- | --- |
| AU-2 | Event Logging | AVD Insights DCR collects TerminalServices session events (connect/disconnect via `TerminalServices-RemoteConnectionManager/Admin` and `TerminalServices-LocalSessionManager/Operational`), all System events, FSLogix operational/admin events, and Application errors/warnings. Key Vault AuditEvent logs and RSV diagnostic logs flow to Log Analytics. Windows Security event log is **not** collected — see gap note above. | Automatic (partial) | `enableMonitoring: true` (default) |
| AU-3 | Content of Audit Records | DCR records include timestamp, source channel, event ID, level, and message. TerminalServices events include user session context (session ID, user name). Key Vault audit records include caller identity, operation name, result, and client IP. Gap: Security event log records with full user-identity-and-outcome fields (required for AU-3 privileged-access coverage) are not collected at the VM layer. | Automatic (partial) | `enableMonitoring: true` (default) |
| AU-9 | Protection of Audit Information | Log Analytics workspace data is protected by Azure RBAC. Session hosts hold only the `Monitoring Metrics Publisher` role on the DCR — write-only access to their own log stream, no read access to the workspace. | Automatic | Built-in |
| AU-12 | Audit Record Generation | Standard session hosts receive the AMA extension (`AzureMonitorWindowsAgent`) and DCR association (`Microsoft.Insights/dataCollectionRuleAssociations`) directly from `virtualMachines.bicep`. For service-managed hosts, the automated host-pool policy stage enables the VM system-assigned identity and assigns built-in AMA and DCR/DCE policies to the dedicated session-host resource group. | Automatic | `enableMonitoring: true` (default) |

### Identification and Authentication (IA)

| Control | Title | Implementation | Type | Parameter / Feature |
| --- | --- | --- | --- | --- |
| IA-2 | Identification and Authentication | AVD user authentication is handled by Entra ID (all identity solutions). MFA enforcement is a conditional access policy outside the scope of this solution but applies to the same identity plane. | Automatic | Identity solution selection |
| IA-3 | Device Identification | Session hosts are Entra ID joined or hybrid joined and registered as managed devices. Trusted Launch vTPM provides hardware-based device attestation. | Automatic | `securityType: TrustedLaunch` (default) |
| IA-5(1) | Authenticator Management — Password-Based | VM admin and domain join credentials are stored in Key Vault, not in parameter files. Credentials are retrieved at deployment time via Key Vault secret reference. | Configurable | `virtualMachineAdminPasswordKvSecretName` |
| IA-5(7) | Authenticator Management — No Embedded Credentials | All Azure service-to-service authentication uses managed identities. No connection strings, storage account keys, or SAS tokens are embedded in code or configuration. | Automatic | Built-in |

### System and Communications Protection (SC)

| Control | Title | Implementation | Type | Parameter / Feature |
| --- | --- | --- | --- | --- |
| SC-7 | Boundary Protection | Deploy private endpoints and independently disable ordinary public endpoint access for each created service family. Storage/Key Vault retain documented trusted-service exceptions; verify client DNS and connectivity rather than treating private endpoint creation as a public-access restriction. | Configurable | `paasNetworking.privateEndpoint: true`, `paasNetworking.publicNetworkAccess: Disabled`, with explicit family overrides where needed; see [networking inputs](parameters.md#paas-public-network-access). |
| SC-7(5) | Boundary Protection — Deny by Default | An explicit family public mode of `Disabled` resolves to `publicNetworkAccess: Disabled` and firewall `defaultAction: Deny`, independently of private endpoint flags and stored IP/subnet rules. Trusted-service exceptions remain applicable. | Configurable | `paasNetworking.storage.publicNetworkAccess: Disabled`, `paasNetworking.keyVault.publicNetworkAccess: Disabled`, as applicable. |
| SC-8 | Transmission Confidentiality | All AVD session traffic uses TLS 1.2+. AVD workspace and host pool can be configured with private link to prevent feed URL traversal over public internet. | Configurable | `hostPoolPublicNetworkAccess`, `workspaceFeedPublicNetworkAccess` |
| SC-8(1) | Cryptographic Protection | All Azure PaaS endpoints enforce HTTPS-only. Storage accounts reject HTTP. Key Vaults enforce TLS. | Automatic | Built-in |
| SC-12 | Cryptographic Key Establishment and Management | Ordinary CMK paths configure Key Vault rotation and expiry policies (`keyExpirationInDays`, default 180 days). Confidential VM secure-release keys have a separate lifecycle and do not receive that automatic rotation policy. Platform-managed key lifecycle evidence is inherited from Azure. | Inherited + Configurable | Key management selection, `keyExpirationInDays`, confidential disk encryption configuration |
| SC-20 | Secure Name/Address Resolution | Private DNS supports private endpoint name resolution within linked networks. It does not by itself provide DNSSEC or all name-resolution authenticity requirements. | Configurable (partial) | Applicable endpoint settings + [consumer-specific DNS inputs](parameters.md#private-dns-parameter-names) |
| SC-28 | Protection of Information at Rest — VM disks | Managed disks use platform-managed encryption by default. Optional CMK uses a Disk Encryption Set; double-encryption modes add an independent infrastructure layer. Select the mode against actual authorization and policy requirements, not the NIST/FedRAMP label alone. Confidential VMs do not support the double-encryption modes; see [encryption and policy distinctions](#encryption-requirements-policy-mappings-and-configuration-choices). | Inherited + Configurable | `keyManagementDisks`: `PlatformManaged`, CMK, or supported double-encryption mode |
| SC-28 | Protection of Information at Rest — FSLogix storage | Azure Files is encrypted at rest with platform-managed keys by default. Optional CMK provides customer key control. Storage infrastructure encryption is a separate setting, not proof that CMK is required. | Inherited + Configurable | `keyManagementStorage`: `PlatformManaged`, `CustomerManaged`, or `CustomerManagedHSM` |
| SC-28 | Protection of Information at Rest — Recovery Services Vault (personal host pool VM backup) | Azure Backup provides encryption at rest. When CMK is selected, the personal host pool vault uses a host-pool-scoped key and its system-assigned identity. Verify the selected backup and key configuration. | Inherited + Configurable | `recoveryServices: true`; applicable `keyManagementRecoveryServicesVault` selection |
| SC-28 | Protection of Information at Rest — shared FSLogix snapshot vault (pooled host pools) | For snapshot-tier Azure Files backup, profile data and snapshots remain in the storage account and use its encryption configuration; the operations vault holds backup metadata. This is not proof that SC-28 is fully satisfied, nor a blanket exemption for vault metadata. Vaulted Azure Files backup has a different data location and must be assessed separately. | Configurable; assess data and metadata separately | Storage encryption, backup tier, and applicable vault requirements |
| SC-28(1) | Cryptographic Protection — supplemental | Encryption at host encrypts temp disk and disk caches at the physical host. Infrastructure double encryption adds a second platform-managed encryption layer on all storage. | Automatic | `encryptionAtHost: true` (default) |

### System and Information Integrity (SI)

| Control | Title | Implementation | Type | Parameter / Feature |
| --- | --- | --- | --- | --- |
| SI-3 | Malicious Code Protection | Trusted Launch enables Secure Boot and vTPM. Microsoft Defender for Endpoint can be deployed via Custom Script Extension. | Automatic | `securityType: TrustedLaunch` (default) |
| SI-4 | System Monitoring | AVD Insights DCR collects AVD-specific performance counters (CPU, memory, disk queue depth, user input delay) and TerminalServices/FSLogix session events for the AVD Insights workbook. Azure Monitor metric alerts and log query alerts can be configured against the Log Analytics workspace. Note: threat-detection (SI-4(2)) requires a SIEM integration outside the scope of this template. | Automatic | `enableMonitoring: true` (default) |
| SI-7 | Software, Firmware, and Information Integrity | Trusted Launch vTPM provides measured boot — any modification to boot firmware or early-stage OS components is detected and logged. Confidential VMs add hardware-level attestation. | Configurable | `securityType: TrustedLaunch` (default) or `ConfidentialVM` |

### Contingency Planning (CP)

| Control | Title | Implementation | Type | Parameter / Feature |
| --- | --- | --- | --- | --- |
| CP-6 | Alternate Storage Site | Recovery Services Vault storage redundancy can be set to GeoRedundant to replicate backup data to a paired region. | Configurable | `recoveryServicesVaultStorageRedundancy: GeoRedundant` |
| CP-7 | Alternate Processing Site | Supported cross-region backup restore can contribute to alternate-site planning, but does not establish an alternate processing site or satisfy CP-7 by itself. Validate restore capacity, dependencies, data locations, and measured RPO/RTO against the contingency plan. **Azure Site Recovery (ASR) is not implemented**; any assigned ASR-specific policy and proposed exemption must be reviewed separately. See [bcdr.md](bcdr.md#azure-site-recovery-asr-is-not-implemented). | Configurable (partial) | Backup/restore configuration and contingency-plan evidence |
| CP-9 | Information System Backup — FSLogix profiles | Azure Backup snapshot policy protects FSLogix Azure Files shares (pooled) or VM disks (personal). | Configurable | `recoveryServices: true` |
| CP-9 | Information System Backup — zone resilience | Azure Files storage can be deployed with Zone Redundant Storage to survive an availability zone failure without restore. | Configurable | `fslogixProfileStorageRedundancy: ZoneRedundant` |

---

## DoD Cloud Computing SRG — Impact Level 4 (IL4)

**Reference:** [DoD Cloud Computing SRG](https://public.cyber.mil/dccs/dccs-documents/) | [Azure Government IL4 documentation](https://learn.microsoft.com/en-us/azure/compliance/offerings/offering-dod-il4)

The DoD SRG uses FedRAMP baselines with additional requirements. A FedRAMP High platform
authorization does not by itself authorize the mission owner's IL4 workload. Confirm the applicable
SRG requirements, service scope, contract, and authorization conditions.

| Requirement | Implementation | Type | Parameter / Feature |
| --- | --- | --- | --- |
| Data must reside in US Government regions | Deploy to `usgovvirginia`, `usgovarizona`, or `usgovtexas` (or US DoD regions). The solution supports all Azure Government regions. | Configurable | `location` parameter |
| Encryption in transit for all data flows | TLS enforced on all PaaS endpoints. AVD session traffic encrypted. Storage accounts reject HTTP. | Automatic | Built-in |
| Encryption and customer key control | CMK can provide owner key control for disks, FSLogix storage, and personal VM backup. Select it according to the workload's authorization requirements, organizational policies, or security design. IL4 and NIST/FedRAMP labels alone do not establish a blanket CMK or disk double-encryption mandate. Assess snapshot data and vault metadata separately. | Inherited + Configurable | Applicable `keyManagementDisks`, `keyManagementStorage`, and `keyManagementRecoveryServicesVault` selections |
| Restricted network exposure | Configure private endpoints and public access restrictions for the relevant services; endpoint creation alone does not disable public access. | Configurable | `paasNetworking`, `privateEndpointSubnetResourceIds`, and separate AVD Private Link inputs |
| Audit logging | Log Analytics workspace + AVD Insights DCR active. Key Vault and RSV diagnostic logs enabled. | Automatic | `enableMonitoring: true` (default) |
| MFA for all administrative access | Enforced via Entra ID Conditional Access Policy — outside this solution's scope but applies to the same identity plane. | External | Entra ID CA Policy |

---

## DoD Cloud Computing SRG — Impact Level 5 (IL5)

**Reference:** [Azure Government IL5 documentation](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-impact-level-5)

IL5 adds separation requirements. Microsoft's documented cryptographic-separation approach
uses owner-managed keys held in FIPS-validated HSMs; its applicability depends on the service,
region, and authorized design. This is an IL5-specific implementation requirement, not a
universal requirement for every government workload.

> **Dedicated Hosts are mandatory in US Gov regions.** Per the DoD SRG and [Azure Government IL5 guidance](https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-impact-level-5#virtual-machines): *"When you deploy VMs in Azure Government regions US Gov Arizona, US Gov Texas, and US Gov Virginia, you must use Azure Dedicated Host."* In the dedicated DoD regions (US DoD Central, US DoD East) physical separation is provided by design and Dedicated Hosts are not required.
>
> **Unsupported configurations:** If the required isolation cannot be provided, consult the AO and cloud provider about approved alternatives. Do not assume that cost or an internal risk acceptance overrides the platform authorization's conditions.

| Requirement | Implementation | Type | Parameter / Feature |
| --- | --- | --- | --- |
| Compute isolation — dedicated physical hosts (US Gov AZ/TX/VA) | Standard session hosts can use pre-provisioned Azure Dedicated Host(s) or a Dedicated Host Group. Verify the selected host SKU, region, and placement. | Configurable | `dedicatedHostResourceId` or `dedicatedHostGroupResourceId` |
| HSM-backed CMK for cryptographic separation | Use owner-managed, HSM-protected keys for resources within the documented cryptographic-separation scope. This solution creates RSA-HSM keys in Premium Key Vaults when an HSM mode is selected. Verify current FIPS validation evidence for the target cloud and service. Disk double encryption is a separate policy/design choice, and snapshot vault metadata needs its own applicability assessment. | Configurable | Applicable `CustomerManagedHSM` or supported `PlatformManagedAndCustomerManagedHSM` selections |
| HSM keys for image pipeline resources in scope | Select HSM-backed CMK for storage accounts and gallery image versions where required by the authorized image pipeline design. Do not infer a requirement for every logging or metadata resource solely from the IL5 label. | Configurable | `keyManagementStorageAccounts: CustomerManagedHSM`, `keyManagementGalleryImageVersions: CustomerManagedHSM` |
| Disk encryption and owner key control | This solution offers managed-disk SSE with a CMK-backed Disk Encryption Set. Microsoft documents other encryption paths too; validate the selected mechanism against the current authorization requirements. Encryption at host complements disk encryption but does not provide customer key control by itself. Require double encryption only where the applicable policy or design calls for it. | Configurable | `keyManagementDisks: CustomerManagedHSM` or supported `PlatformManagedAndCustomerManagedHSM`; `encryptionAtHost` |
| VM private disk export/import access (optional) | A Disk Access private endpoint provides private disk export/import connectivity. Verify the disk's network access policy and public access settings separately; an endpoint alone does not block every public path. | Configurable | `paasNetworking.disk.privateEndpoint: true`, private endpoint placement, and personal host pool disk configuration |

### Example IL5-Oriented Settings — Not a Complete Authorization Baseline

These are illustrative **standard host-pool** settings for a design using dedicated compute,
HSM-backed CMK, private connectivity, and backup. They are not universally required values or
a complete parameter file. Replace placeholder IDs, supply the remaining deployment inputs,
and review the applicable authorization and policy assignments. For Confidential VMs, use a
supported CMK mode rather than the double-encryption example.

```json
{
  "dedicatedHostGroupResourceId": { "value": "/subscriptions/.../dedicatedHostGroups/dhg-avd-prod" },
  "keyManagementDisks": { "value": "PlatformManagedAndCustomerManagedHSM" },
  "keyManagementStorage": { "value": "CustomerManagedHSM" },
  "keyManagementRecoveryServicesVault": { "value": "CustomerManagedHSM" },
  "paasNetworking": { "value": { "publicNetworkAccess": "Disabled", "privateEndpoint": true } },
  "privateEndpointSubnetResourceIds": {
    "value": {
      "sharedResources": "/subscriptions/.../virtualNetworks/vnet-avd/subnets/pe-shared",
      "hostPoolResources": "/subscriptions/.../virtualNetworks/vnet-avd/subnets/pe-hostpool"
    }
  },
  "recoveryServicesVaultStorageRedundancy": { "value": "GeoRedundant" },
  "fslogixProfileStorageRedundancy": { "value": "ZoneRedundant" },
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
| --- | --- | --- |
| Hardware-isolated VM execution | Confidential VMs use AMD SEV-SNP or Intel TDX to encrypt VM memory in hardware. The hypervisor cannot read guest memory. | `securityType: ConfidentialVM` |
| Confidential OS disk encryption | Optional confidential OS disk encryption uses a secure-release key and attestation policy; VM type and HSM selection alone do not enable it. | `securityType: ConfidentialVM`, `confidentialVMOSDiskEncryption: true`, and supported CMK configuration |
| Key release policy | Secure-release keys are exportable only to an attested environment matching their release policy. Do not describe these keys as never leaving the HSM or receiving ordinary CMK automatic rotation. Validate policy/cloud compatibility and manage their lifecycle separately. | Confidential OS disk encryption path; see [Key Vault key release and attestation](https://learn.microsoft.com/en-us/azure/key-vault/keys/secure-keys#key-release-and-attestation) |

---

## Summary: Configuration Choices to Review

No fixed parameter set establishes NIST, FedRAMP, or DoD compliance. Review these choices
against the approved system boundary, assigned policies, service availability, and recovery
requirements. The names below are standard host-pool entry inputs; other solutions can expose
different subsets.

| Parameter | Configuration Choice | Applicability |
| --- | --- | --- |
| `keyManagementDisks` | Platform-managed, CMK, or supported double-encryption mode | Customer key control, authorization conditions, and enabled disk policies; Confidential VM restrictions apply |
| `keyManagementStorage` | Platform-managed or CMK, with optional HSM protection | Storage key-control requirements and applicable policies |
| `keyManagementRecoveryServicesVault` | Platform-managed or CMK, with optional HSM protection | Personal VM backup vault; assess snapshot-tier data and metadata separately |
| `paasNetworking` | Secure default: public access `Disabled`, private endpoints enabled; explicit family overrides supported | Connectivity and boundary-protection design, not a framework-wide private-endpoint mandate |
| `privateEndpointSubnetResourceIds` | `sharedResources` and `hostPoolResources` placement IDs | Required for the selected private endpoint deployment paths |
| `privateDnsZoneResourceIds` | Applicable service namespace IDs, where reusing zones | Client resolution, zone links, and resolver configuration |
| `fslogixProfileStorageRedundancy` | Locally redundant, zone redundant, or other supported option | Availability and recovery design; zone redundancy is not a universal framework mandate |
| `recoveryServicesVaultStorageRedundancy` | Supported local, zone, or geo-redundancy option | Backup availability, permitted data locations, and restore requirements |
| `recoveryServices` | Enable when this deployment supplies the required backup capability | Alternative approved backup arrangements require their own evidence |
| `dedicatedHostResourceId` / `dedicatedHostGroupResourceId` | Existing dedicated compute placement | Applicable IL5 region/VM isolation requirements; not required by every framework |
| `securityType` | `TrustedLaunch` default or supported `ConfidentialVM` configuration | Boot integrity and confidential-computing design |
| `encryptionAtHost` | `true` default | Host cache/temp-disk protection; does not select CMK |
| `enableMonitoring` | `true` default | Verify diagnostic coverage, collection, retention, alerting, and external SIEM requirements |

---

## Federal Zero Trust Standards

Federal agencies are required to implement Zero Trust Architecture (ZTA) under multiple mandates. The following standards apply to AVD deployments in federal environments.

### Applicable Standards

| Standard | Issuing Body | Scope | Key Requirement |
| --- | --- | --- | --- |
| [OMB M-22-09](https://www.whitehouse.gov/wp-content/uploads/2022/01/M-22-09.pdf) | OMB | All federal civilian agencies | Agencies must meet specific ZT targets by end of FY2024. Establishes five ZT pillars and mandates adoption of CISA ZTMM. |
| [CISA Zero Trust Maturity Model v2.0](https://www.cisa.gov/resources-tools/resources/zero-trust-maturity-model) | CISA | All federal civilian agencies | Primary maturity framework. Five pillars (Identity, Devices, Networks, Applications & Workloads, Data) with Traditional → Initial → Advanced → Optimal maturity levels. Recommended implementation framework for M-22-09. |
| [NIST SP 800-207](https://csrc.nist.gov/pubs/sp/800/207/final) | NIST | All federal agencies | Foundational ZTA architectural guidance. Defines the core principle: "never trust, always verify" — access decisions made per-request based on identity, device, and context, not network location. |
| [DoD Zero Trust Strategy (2022)](https://dodcio.defense.gov/Portals/0/Documents/Library/ZTStrategy.pdf) | DoD CIO | DoD components | DoD-specific ZT execution roadmap. Seven pillars (User, Device, Application & Workload, Data, Network & Environment, Automation & Orchestration, Visibility & Analytics). Targets ZT "Target Level" by FY2027. |
| [DoD Zero Trust Reference Architecture v2.0](https://dodcio.defense.gov/Portals/0/Documents/Library/ZT-RA.pdf) | DoD CIO | DoD components | Detailed technical reference. Maps ZT capabilities to DoD pillars and defines 91 ZT activities and 152 target capabilities. |

### CISA Zero Trust Maturity Model — AVD Control Mapping

The CISA ZTMM v2.0 is an implementation framework for federal civilian agencies. This solution
provides capabilities across all five pillars. The maturity labels below indicate potential
alignment, not an assessed maturity level or a claim that CMK, HSM, or any single feature achieves
Advanced/Optimal maturity. Validate the complete capability and organizational implementation.

#### Pillar 1: Identity

> ZTMM principle: Strong authentication for every access request; no implicit trust based on network location; privileged access management; continuous validation.

| ZTMM Capability | Implementation | Maturity Level | Type |
| --- | --- | --- | --- |
| MFA for all users | Entra ID authentication for all AVD sessions. MFA enforcement via Conditional Access Policy (outside template scope, same identity plane). | Advanced | External (Entra ID CA) |
| Phishing-resistant MFA for privileged users | FIDO2 / Windows Hello for Business (supported by Entra ID). | Advanced | External (Entra ID CA) |
| Non-person entity (NPE) authentication via managed identities | All service-to-service access uses system-assigned or user-assigned managed identities. No stored credentials, API keys, or SAS tokens in code. | Optimal | Automatic |
| Privileged access management | Key Vault secrets for domain join and VM admin credentials. RBAC scoped to minimum required roles. | Advanced | Automatic |
| Continuous access evaluation | CAE requires participating clients and resource services. These templates do not establish that identity/token revocation terminates an existing AVD desktop session; validate supported client/service behavior and session revocation controls separately. See [CAE guidance](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-continuous-access-evaluation). | Advanced (potential alignment) | External (identity, client, and service configuration) |

#### Pillar 2: Devices

> ZTMM principle: Device compliance verification before access; hardware-based attestation; continuous monitoring of device health.

| ZTMM Capability | Implementation | Maturity Level | Type |
| --- | --- | --- | --- |
| Device inventory and compliance | Session hosts are registered as managed devices via Entra ID join or hybrid join. | Initial | Automatic |
| Hardware-based attestation | Trusted Launch enables vTPM and Secure Boot. Guest Attestation extension validates boot integrity and is deployed to every session host. | Advanced | Automatic (`securityType: TrustedLaunch`) |
| Measured boot / boot integrity monitoring | vTPM records measured boot sequence. Deviations from baseline firmware/OS state are detectable via Integrity Monitoring. | Advanced | Automatic |
| Confidential computing attestation | Confidential VMs use AMD SEV-SNP or Intel TDX with hardware attestation — the hypervisor cannot read or modify guest memory. | Optimal | Configurable (`securityType: ConfidentialVM`) |
| Encryption of device storage | OS and data disks encrypted via Disk Encryption Set + CMK with a platform-managed infrastructure encryption layer (double encryption). Encryption at host adds VM temp disk and cache encryption. | Optimal | Configurable (`keyManagementDisks: PlatformManagedAndCustomerManaged/HSM`) |

#### Pillar 3: Networks

> ZTMM principle: Micro-segmentation; encrypted traffic; deny-by-default; no implicit trust based on network location.

| ZTMM Capability | Implementation | Maturity Level | Type |
| --- | --- | --- | --- |
| Network micro-segmentation | Private endpoints for all PaaS resources. Session hosts in dedicated subnet. No direct internet exposure. | Advanced | Configurable (service-specific private endpoint inputs) |
| Deny by default for PaaS | `publicNetworkAccess: Disabled` on all PaaS resources when private endpoints + no permitted IPs. | Advanced → Optimal | Configurable |
| Encrypted traffic (data in transit) | All AVD session traffic over TLS 1.2+. All PaaS endpoints HTTPS-only. | Optimal | Automatic |
| Private endpoint name resolution | Private DNS zones resolve PaaS FQDNs to private addresses when linked networks and client resolvers are configured. Exfiltration prevention requires additional network and DNS controls. | Advanced (potential alignment) | Configurable (service-specific DNS inputs) |
| Private connectivity to AVD control plane | AVD workspace and host pool private link prevents feed URL and broker traffic traversal over public internet. | Optimal | Configurable (`hostPoolPublicNetworkAccess`, `workspaceFeedPublicNetworkAccess`) |
| Azure Monitor private link | Azure Monitor data collection traffic routed through a network-managed AMPLS private link scope — no monitoring data over public internet. | Advanced | Reuse existing (`azureMonitorPrivateLinkScopeResourceId`) |

#### Pillar 4: Applications and Workloads

> ZTMM principle: Application-level access control; least-privilege service access; secure pipelines; no implicit trust for internal services.

| ZTMM Capability | Implementation | Maturity Level | Type |
| --- | --- | --- | --- |
| Managed identity for workload authentication | Automation accounts, image build pipeline, FSLogix storage RBAC, Key Vault access — all use managed identities. | Optimal | Automatic |
| Least-privilege service access | Role assignments are scoped to the minimum required resource and role. | Advanced | Automatic |
| Secure image pipeline | Image build executes customizations via `Microsoft.Compute/virtualMachines/runCommands` (outbound-only ARM API calls) with managed identity — **not** Azure VM Image Builder, which requires WinRM/SSH to the build VM, a service-managed staging resource group with an unfirewalled storage account, and Key Vaults with public network access enabled. Images stored in Azure Compute Gallery with private access. See [Image Build — Why `imageBuild.bicep` Instead of Packer or Azure VM Image Builder (AIB)?](image-build.md#why-imagebuildbicep-instead-of-packer-or-azure-vm-image-builder-aib) | Advanced | Automatic (imageBuild template) |
| Key Vault for application secrets | Domain join and VM admin credentials retrieved from Key Vault at deploy time — never stored in template or parameter files. | Optimal | Configurable (`existingCredentialsKeyVaultResourceId`) |

#### Pillar 5: Data

> ZTMM principle: Data protection at rest and in transit; appropriate cryptographic key management; classification and labeling; data access auditing.

| ZTMM Capability | Implementation | Maturity Level | Type |
| --- | --- | --- | --- |
| Encryption at rest | Azure provides platform-managed encryption for managed disks and storage; CMK and infrastructure/disk double encryption are separate configurable choices. CMK alone does not establish Optimal maturity. | Requires assessment | Inherited + Configurable (applicable key-management inputs) |
| HSM-backed key protection | HSM modes create RSA-HSM keys in Premium Key Vaults. Verify the actual FIPS-validated module for the target service/cloud. Confidential secure-release keys can leave the HSM only under their attestation policy. | Requires assessment | Configurable (applicable HSM selections) |
| Key lifecycle management | Ordinary CMK paths configure rotation/expiry policies; services must adopt new key versions. Confidential secure-release keys need separate lifecycle management. Rotation does not necessarily re-encrypt all underlying data. | Advanced (potential alignment) | Configurable (`keyExpirationInDays`, selected key path) |
| Data access auditing | Key Vault audit logs (AuditEvent) capture all key operations (wrap/unwrap/get). Sent to Log Analytics. | Advanced | Automatic (`enableMonitoring: true`) |
| Data in transit encryption | TLS 1.2+ for all data flows. Azure Files SMB 3.0 with encryption. | Optimal | Automatic |

### DoD Zero Trust Alignment

For DoD components, the [DoD ZT Strategy](https://dodcio.defense.gov/Portals/0/Documents/Library/ZTStrategy.pdf) maps to the same underlying capabilities across seven DoD pillars. The key DoD-specific additions beyond the CISA ZTMM mapping above:

| DoD Pillar | DoD-Specific Requirement | Implementation |
| --- | --- | --- |
| **User** | CAC/PIV authentication for privileged access | Entra ID supports certificate-based authentication (CBA) with CAC/PIV — configured via Conditional Access Policy outside template scope |
| **Device** | Applicable IL5 compute isolation | Existing Azure Dedicated Host placement (`dedicatedHostResourceId` or `dedicatedHostGroupResourceId`) for applicable US Gov AZ/TX/VA VM deployments |
| **Data** | Key control and cryptographic separation where required | HSM-backed CMK for resources in the applicable IL5 separation scope; do not treat it as a blanket requirement for all DoD sensitive data |
| **Visibility & Analytics** | Continuous monitoring with automated response | SIEM integration with Log Analytics workspace (Microsoft Sentinel or third-party — outside template scope) |
| **Automation & Orchestration** | Policy-driven remediation for non-compliant resources | The automated host-pool policy stage assigns VM identity, AMA, DCR/DCE, configuration, encryption, and tagging policies to the dedicated service-managed session-host resource group |

---

## CMMC 2.0 Level 2 (Defense Industrial Base / CUI)

**Reference:** [CMMC 2.0 Model](https://dodcio.defense.gov/CMMC/Model/) | [NIST SP 800-171 Rev 2](https://csrc.nist.gov/pubs/sp/800/171/r2/upd1/final)

CMMC Level 2 addresses **Controlled Unclassified Information (CUI)** using NIST SP 800-171
Rev. 2 requirements. Applicability, required assessment level, and timing depend on the
solicitation/contract and phased implementation; see the [official CMMC rollout guidance](https://www.defensesbirsttr.mil/Education/CMMC-Draft/).
Crosswalks to NIST SP 800-53 support evidence reuse but do not automatically transfer a FedRAMP
implementation or establish that every CMMC requirement is satisfied.

> **Assessment scope:** Follow the contract's required Level 2 self-assessment or C3PAO assessment. This mapping supports the evidence narrative; the organization's SSP and assessment evidence must cover all applicable requirements, including organizational, personnel, and physical requirements not addressed here.

| CMMC Domain | Practice | Requirement Summary | Implementation | Type |
| --- | --- | --- | --- | --- |
| **AC** Access Control | 3.1.1 | Limit system access to authorized users and processes | Entra ID authentication; RBAC scoped to minimum roles; no public session host ports | Automatic |
| **AC** | 3.1.2 | Limit system access to authorized transaction types | Azure RBAC enforces operation-level permissions on all resources | Automatic |
| **AC** | 3.1.12 | Monitor and control remote access sessions | All AVD session traffic brokered through control plane; private endpoints optional | Configurable (AVD Private Link inputs) |
| **AC** | 3.1.13 | Employ cryptographic mechanisms to protect remote access | TLS 1.2+ for all AVD sessions; HTTPS-only for all PaaS endpoints | Automatic |
| **AC** | 3.1.14 | Route remote access via managed access control points | AVD brokers user sessions. Verify NSGs, routes, and any permitted direct management access separately; brokering alone does not establish that it is the only access path. | Automatic (partial) + External |
| **AC** | 3.1.19 | Encrypt CUI on mobile devices and portable storage | Session-host disk encryption does not configure client mobile devices or portable media. Enforce and assess their encryption separately. | External (endpoint/media controls) |
| **AC** | 3.1.20 | Verify and control all connections to external systems | Private endpoints provide private service access. Independently configure public access, trusted-service exceptions, egress controls, and approval of external connections; endpoint creation alone does not block external data flow. | Configurable (partial) + External |
| **AU** Audit & Accountability | 3.3.1 | Create and retain system audit logs to enable monitoring | AMA deployed to each session host; TerminalServices, System, and FSLogix events → Log Analytics. Key Vault audit logs enabled. Note: Windows Security event log not collected — see AU gap note. | Automatic (partial) |
| **AU** | 3.3.2 | Ensure audit log actions are traceable to users | TerminalServices events include user session context; Key Vault records include caller identity | Automatic (partial) |
| **IA** Identification & Authentication | 3.5.1 | Identify all system users, processes, and devices | Entra ID provides authoritative identity for all users and managed identities for all services | Automatic |
| **IA** | 3.5.2 | Authenticate all users, processes, and devices | Entra ID MFA (via CA Policy); managed identity tokens for service-to-service | External (CA) / Automatic |
| **IA** | 3.5.3 | Use MFA for local and network access | MFA enforced via Entra ID Conditional Access (outside template scope; applies to same identity plane) | External (CA Policy) |
| **IA** | 3.5.10 | Store and transmit only cryptographically-protected passwords | Passwords stored in Azure Key Vault (encrypted at rest). Never in parameter files or environment variables. | Automatic |
| **IA** | 3.5.11 | Obscure feedback of authentication information | Entra ID and Key Vault handle credential display — no raw password exposure in template outputs | Automatic |
| **SC** System & Communications Protection | 3.13.1 | Monitor and control communications at external boundaries | Private endpoints + `publicNetworkAccess: Disabled` enforce deny-by-default at PaaS boundary | Configurable (service-specific private endpoint and public-access inputs) |
| **SC** | 3.13.2 | Employ architectural designs, software development techniques, and engineering principles | Subscription-scoped Bicep templates enforce consistent deployment; no ad-hoc resource creation | Automatic |
| **SC** | 3.13.5 | Implement subnetworks for publicly accessible system components | Session hosts deploy to private VNet subnets with no public IPs | Automatic |
| **SC** | 3.13.6 | Deny network communications traffic by default | `publicNetworkAccess: Disabled` on PaaS + private DNS = deny-by-default for all PaaS traffic | Configurable |
| **SC** | 3.13.8 | Implement cryptographic mechanisms to prevent unauthorized disclosure during transmission | TLS 1.2+ for AVD sessions; HTTPS-only for storage and Key Vault | Automatic |
| **SC** | 3.13.10 | Establish and manage cryptographic keys | CMK keys in Azure Key Vault with rotation policy. HSM option (FIPS 140-2 Level 3) available. | Configurable (`keyManagementDisks/Storage/RSV: CustomerManaged`) |
| **SC** | 3.13.16 | Protect the confidentiality of CUI at rest | Azure encryption at rest with platform-managed keys or selected CMK provides implementation evidence. Validate the cryptographic protection and key management against applicable requirements; CMK and double encryption are not prescribed by this practice alone. | Inherited + Configurable (applicable key-management inputs) |
| **SI** System & Information Integrity | 3.14.1 | Identify, report, and correct information and information system flaws | Trusted Launch + vTPM measured boot detects firmware/OS integrity violations | Automatic |
| **SI** | 3.14.6 | Monitor organizational systems to detect attacks and indicators of potential attacks | AVD Insights DCR → Log Analytics. Azure Monitor alerts configurable. SIEM integration outside scope. | Automatic |
| **SI** | 3.14.7 | Identify unauthorized use of organizational systems | TerminalServices session events logged; Key Vault access audited. Security event log gap applies. | Automatic (partial) |

### CMMC Level 2 Configuration and Evidence

Use the [configuration choices above](#summary-configuration-choices-to-review) as engineering
inputs, not a CMMC minimum or compliance guarantee. Determine the applicable contract
requirements and assessment scope, then collect deployed-resource, endpoint, logging,
cryptographic-module, procedural, and SSP evidence. A template parameter set alone cannot
satisfy all Level 2 technical or organizational requirements.

---

## HIPAA Security Rule (Healthcare)

**Reference:** [45 CFR Part 164, Subpart C — Security Standards](https://www.hhs.gov/hipaa/for-professionals/security/index.html) | [NIST SP 800-66 Rev 2 (HIPAA Implementation Guide)](https://csrc.nist.gov/pubs/sp/800/66/r2/final)

HIPAA Technical Safeguards (§164.312) govern the technology and policy that protects ePHI (electronic Protected Health Information). This solution supports a HIPAA-compliant AVD deployment for healthcare organizations, health plans, and their business associates.

> **HIPAA flexibility note:** HIPAA uses "Required" and "Addressable" specifications. Addressable specifications must be implemented if reasonable and appropriate; if not, the organization must document why and implement an equivalent measure. This table notes which specification type applies.

| §164.312 Specification | Type | Requirement | Implementation | Parameter |
| --- | --- | --- | --- | --- |
| **(a)(1)** Access Control — Unique User Identification | Required | Each user must have a unique identifier | Entra ID assigns unique user identities; no shared accounts in AVD | Automatic |
| **(a)(2)(i)** Unique User ID | Required | Assign unique name/number for tracking identity | Entra ID UPN/Object ID for all users and service principals | Automatic |
| **(a)(2)(iii)** Automatic Logoff | Addressable | Terminate session after inactivity | Configured via AVD host pool idle timeout and Windows session timeout policy (outside template scope) | External (GP/Intune) |
| **(a)(2)(iv)** Encryption and Decryption | Addressable | Mechanism to encrypt and decrypt ePHI | Managed disks and Azure Files provide encryption at rest with platform-managed keys; optional CMK provides customer key control. Select and document the mechanism through the HIPAA risk analysis, not a blanket CMK requirement. | Inherited + Configurable (applicable key-management inputs) |
| **(b)** Audit Controls | Required | Hardware/software/procedural mechanisms that record and examine activity | AMA + DCR deployed to each session host. Key Vault audit logs to Log Analytics. Note: Windows Security event log not collected — supplemental DCR required for full ePHI access audit trail. | Automatic (partial) |
| **(c)(1)** Integrity — Electronic Mechanism | Addressable | Protect ePHI from improper alteration or destruction | Trusted Launch vTPM provides measured boot. Azure Backup (RSV) for profile and file share protection. | Automatic + Configurable (`recoveryServices: true`) |
| **(d)** Person or Entity Authentication | Required | Verify that a person seeking access is the one claimed | Entra ID authentication for all AVD sessions. MFA via Conditional Access Policy (outside template scope). | External (CA Policy) |
| **(e)(1)** Transmission Security — Integrity Controls | Addressable | Guard against unauthorized modification of ePHI in transit | TLS 1.2+ for all AVD session traffic | Automatic |
| **(e)(2)(ii)** Transmission Security — Encryption | Addressable | Encrypt ePHI in transit when deemed appropriate | TLS 1.2+ for all PaaS endpoints. Private endpoints eliminate public transit path. | Configurable (service-specific private endpoint inputs) |

### Example HIPAA-Oriented Security Settings

This is an optional hardened profile, not a HIPAA-prescribed minimum or a complete parameter
file. Assess the applicable safeguards and supply private endpoint placement and other required
inputs for the selected deployment. CMK and private endpoints are implementation choices, not
universal HIPAA requirements.

```json
{
  "keyManagementDisks": { "value": "CustomerManaged" },
  "keyManagementStorage": { "value": "CustomerManaged" },
  "paasNetworking": { "value": { "publicNetworkAccess": "Disabled", "privateEndpoint": true } },
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
| --- | --- | --- | --- |
| **5.5** Access Control | Ensure only authorized individuals access CJI | Entra ID authentication + RBAC; no public exposure of session hosts | Automatic |
| **5.6.2.1** Advanced Authentication (MFA) | MFA required for all remote access to CJI | MFA enforced via Entra ID Conditional Access Policy (outside template scope; mandatory for any CJIS-compliant deployment) | External (CA Policy) |
| **5.6.2.2** Advanced Authentication — Phishing-Resistant | FIDO2 or certificate-based auth for privileged access | Entra ID supports FIDO2 and CBA with CAC/PIV | External (CA Policy) |
| **5.8.1** Boundary Protection | Isolate CJI systems from non-CJI systems | Private endpoints, VNet isolation, dedicated subnets. No session host public IPs. | Configurable (service-specific private endpoint inputs) |
| **5.8.2** Encryption — Data at Rest | Encrypt CJI at rest using FIPS-validated cryptography (AES-256) | Azure disk/storage services perform data encryption; optional CMK in Key Vault controls the wrapping keys, not an AES data-encryption operation performed in Key Vault. Verify the approved cryptographic module, algorithm, and key-management configuration for the applicable policy version. | Inherited + Configurable (applicable key-management inputs) |
| **5.8.3** Encryption — Data in Transit | Encrypt CJI in transit (minimum AES-128, FIPS-validated) | TLS 1.2+ (AES-256 cipher suites) for all AVD session and PaaS traffic | Automatic |
| **5.8.4** Encryption — Key Management | Keys protected from unauthorized access; stored separately from encrypted data | Platform-managed key controls require Azure evidence; selected CMK paths use Key Vault access controls and configurable audit logging. A CMK label alone does not prove the key-management requirements. | Inherited + Configurable |
| **5.9** Formal Audits | Log access to CJI; retain audit logs | AMA + DCR deployed to session hosts. Key Vault access logs. Note: Windows Security event log gap — supplemental DCR required for full CJI access audit. | Automatic (partial) |
| **5.10** Personnel Security | Background checks, training (organizational, outside template scope) | — | Organizational |
| **5.11** Physical Protection | Physical security of terminals accessing CJI | Azure datacenter physical security inherited from platform. End-user device policies outside scope. | Inherited / External |
| **5.12** Systems and Communications Protection | Protect CJI during storage and transmission | Private endpoints support private PaaS connectivity; verify public access settings and actual client, session, management, and data routes. Private DNS and PaaS endpoints alone do not prove that no CJI traverses public internet. | Configurable (partial) |
| **5.13** Formal Audits — System Audit | System must generate audit records for CJI access | Key Vault audit logs + TerminalServices session events collected. Windows Security event log required separately. | Automatic (partial) |

> **CJIS audit gap:** CJIS §5.9 requires logging of CJI access events. The AVD Insights DCR captures session connect/disconnect events but **not** the Windows Security event log (logon events 4624/4634, privilege use 4672). For CJIS compliance, a supplemental DCR or SIEM agent targeting the Security event log is required.

**CJIS channel partner / CJIS Systems Agency (CSA):** Deploying organizations must obtain a signed CJIS Security Addendum with their state CSA. The Azure Government CJIS compliance package and [FBI CJIS audit documentation](https://learn.microsoft.com/en-us/azure/compliance/offerings/offering-cjis) cover the platform layer.

---

## StateRAMP (State and Local Government)

**Reference:** [StateRAMP Security Requirements](https://stateramp.org/security-requirements/)

StateRAMP is the state and local government equivalent of FedRAMP, using the same NIST SP 800-53 control baseline. StateRAMP authorization levels map directly to FedRAMP:

| StateRAMP Level | FedRAMP Equivalent | Applicability |
| --- | --- | --- |
| StateRAMP Ready | FedRAMP Ready | Pre-authorization status |
| StateRAMP Authorized — Low | FedRAMP Low | Low-impact state systems |
| StateRAMP Authorized — Moderate | FedRAMP Moderate | Most state agency systems |
| StateRAMP Authorized — High | FedRAMP High | High-impact state systems (CJI, tax, health) |

StateRAMP uses NIST-based controls, but a FedRAMP-oriented parameter profile does not establish
StateRAMP authorization or satisfy every requirement. Verify the applicable program baseline,
assessment evidence, organization-defined requirements, and assigned policies. Do not infer
mandatory CMK/HSM or acceptability of a Key Vault tier solely from a Moderate/High label.

> **StateRAMP and CJIS:** Many state/local deployments require both StateRAMP and CJIS compliance simultaneously (e.g., a state portal used for law enforcement and general government). The CJIS Advanced Authentication requirement (MFA) is an additional requirement on top of StateRAMP controls — both are addressed by Entra ID Conditional Access Policy.

---

## IRS Publication 1075 (Federal Tax Information)

**Reference:** [IRS Publication 1075 (Rev. 10-2021)](https://www.irs.gov/pub/irs-pdf/p1075.pdf)

IRS Publication 1075 (P1075) governs the handling of Federal Tax Information (FTI) by federal, state, and local agencies receiving tax data from the IRS. It is based on NIST SP 800-53 Moderate and adds IRS-specific safeguards.

| P1075 Area | Requirement | Implementation | Notes |
| --- | --- | --- | --- |
| **Exhibit 7** — Encryption at Rest | FTI must be encrypted at rest using FIPS 140-2 validated cryptography | Azure disk/storage encryption provides data protection; optional CMK supports customer key control. Validate the actual cryptographic modules and accepted FIPS evidence against the applicable P1075 requirements. Key Vault SKU, CMK, or double encryption alone is not a compliance determination. | Applicable `keyManagementDisks` / `keyManagementStorage` selection and cryptographic-module evidence |
| **Exhibit 7** — Encryption in Transit | FTI must be encrypted in transit (TLS 1.2 minimum) | TLS 1.2+ on all AVD sessions and PaaS endpoints | Automatic |
| **Exhibit 7** — Access Control | Role-based access; limit FTI access to authorized individuals | Entra ID + RBAC. MFA required via CA Policy. | External (CA) + Automatic |
| **Exhibit 7** — Audit Logging | Log all access to FTI systems; retain 3+ years | Log Analytics workspace. Retention configurable (`logAnalyticsWorkspaceRetention`). Note: Windows Security event log required for full FTI access audit. | Configurable |
| **Exhibit 7** — Network Protection | Separate FTI systems from non-FTI systems | Private endpoints + VNet isolation + dedicated subnets | Configurable (service-specific private endpoint inputs) |
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
| --- | --- | --- | --- |
| **A.5.15** Access Control | Manage access rights | Entra ID + RBAC + managed identities | Automatic |
| **A.5.33** Protection of Records | Protect records from loss, destruction, falsification | Azure Backup (RSV) for VM and file share protection | Configurable (`recoveryServices: true`) |
| **A.8.5** Secure Authentication | Secure authentication mechanisms | Entra ID MFA (CA Policy); managed identities; Key Vault for secrets | External + Automatic |
| **A.8.7** Protection Against Malware | Protection against malware | Trusted Launch Secure Boot + vTPM; Defender for Endpoint integration | Automatic |
| **A.8.9** Configuration Management | Manage configurations of hardware, software, services | Bicep defines repeatable desired configuration. Drift detection, change control, and remediation require separate policy or operational evidence. | Automatic (partial) + External |
| **A.8.10** Information Deletion | Delete information when no longer required | Soft delete on Key Vault and Storage; RSV retention policies | Configurable |
| **A.8.15** Logging | Produce, store, protect, and analyze event logs | AMA + DCR + Log Analytics + Key Vault audit logs | Automatic |
| **A.8.20** Network Security | Secure and manage networks | Private endpoints, VNet isolation, private DNS | Configurable |
| **A.8.24** Use of Cryptography | Appropriate cryptography and key management | Azure encryption at rest plus optional CMK/HSM and ordinary CMK lifecycle policies support the organization's cryptographic policy. Validate requirements through the ISMS and Statement of Applicability; this mapping does not mandate CMK/HSM on every resource. | Inherited + Configurable |
| **A.8.25** Secure Development Life Cycle | Policies for secure software development | Infrastructure-as-code in Git; image build pipeline with integrity verification | Automatic |

> **Certification path:** Achieving ISO 27001 certification requires an accredited certification body (CB) audit of the organization's ISMS, not just the technical controls. This mapping supports the technical evidence package for Annex A controls but does not substitute for the full ISMS and Statement of Applicability (SoA).

---

## What This Solution Does Not Cover

The following are required for a complete authorization but are outside the scope of this deployment template. They must be documented separately in the SSP.

| Area | Requirement | Where to Address |
| --- | --- | --- |
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

A ready-to-use script is included in this repository at [`customer-examples/artifacts/DoD-STIGs/Apply-STIGsAVD.ps1`](../customer-examples/artifacts/DoD-STIGs/Apply-STIGsAVD.ps1).

The script uses Microsoft's [LGPO.exe](https://www.microsoft.com/en-us/download/details.aspx?id=55319) to apply DISA STIG GPO packages from [public.cyber.mil](https://public.cyber.mil/stigs/gpo) to the local machine. It handles:

- Windows 10 and Windows 11 STIG GPOs, including correct handling of Windows Enterprise multi-session SKU 175
- Windows Server 2022 and 2025 Member Server STIG GPOs; Windows Server 2016/2019 and domain controllers are rejected, and Domain Controller GPO backups are excluded
- Microsoft Edge, Firewall, Defender Antivirus, Internet Explorer STIGs
- Microsoft 365 / Office / Teams STIGs (detected automatically)
- Third-party application STIGs: Adobe Acrobat Pro/Reader, Google Chrome, Mozilla Firefox
- AVD-specific exceptions (remote interactive logon rights, ECC curve SSL fix that breaks AVD, firewall settings for non-domain joined VMs)
- Individual STIG release stamping to `HKLM:\Software\DoD\STIG` for deployment evidence

For Windows Server, the script reads each GPO backup's `Backup.xml` metadata and applies only the
matching Member Server computer/user GPOs from the mixed MS/DC package. Server stamps include the
role (for example, `DoD WinSvr 2022 MS = v2r9`). Supplemental Windows 11 V-ID remediations do not
run on Server and are not claimed as Server compliance. A review of Server 2022 V2R10 and Server
2025 V1R3 identified additional non-GPO checks for Server features, event-log file ACLs, physical
wireless/Bluetooth devices, certificate files and stores, software/update status, account
governance, and other organization-specific evidence. The artifact README documents the current
automation and intentional AVD deviations. It removes prohibited Simple TCP/IP, Telnet, TFTP,
SMBv1, and PowerShell 2.0 Server features and disables physical Wi-Fi and Bluetooth on Server 2025.
Do not treat application of the GPO package or these supplemental actions alone as evidence that
every manual Server finding is satisfied.

**Deploy in image build (recommended):** Baking STIGs into the golden image means every session host starts hardened without per-VM execution time at deployment. Follow the standard artifacts workflow:

**Step 1 — Copy the example artifact to your customer artifacts folder:**

```powershell
Copy-Item -Path "customer-examples\artifacts\DoD-STIGs" `
          -Destination "customer\artifacts\" -Recurse -Force
```

**Step 2 — Upload to blob storage using `Update-ImageArtifacts.ps1`:**

`Update-ImageArtifacts.ps1` packages `customer/artifacts/DoD-STIGs/` as `DoD-STIGs.zip` and uploads it to the artifacts storage account. It also downloads the STIG GPO package from the URL in `downloads.json` into the artifact folder before packaging. See [Artifacts Guide](artifacts-guide.md) and [Update-ImageArtifacts.ps1 guide](update-image-artifacts.md) for full instructions.

```powershell
cd C:\repos\FederalAVD\deployments
.\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
```

> **Keep the STIG GPO package URL current.** The `DoDSTIGGPOPackage` entry in `customer/parameters/imageManagement/downloads.json` contains a direct link to the quarterly STIG GPO release from DISA — for example:
>
> ```json
> "DownloadUrl": "https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_STIG_GPO_Package_October_2025.zip"
> ```
>
> DISA publishes a new package quarterly (typically January, April, July, October). The filename embeds the month and year. **Update the `DownloadUrl` in your `customer/parameters/imageManagement/downloads.json` whenever a new quarterly package is released**, then re-run `Update-ImageArtifacts.ps1` and build and validate a clean image. The latest packages are listed at [public.cyber.mil/stigs/gpo](https://public.cyber.mil/stigs/gpo). The script detects each applicable STIG's `v<major>r<revision>` release directly from the extracted package folder name; no package-level version argument is required.

**Step 3 — Add to the `customizations` parameter in your image build parameter file:**

```json
"customizations": {
  "value": [
    {
      "name": "DoD-STIGs",
      "blobNameOrUri": "DoD-STIGs.zip",
      "arguments": ""
    }
  ]
}
```

Pass arguments to override defaults — for example, to target only specific applications:

```json
{
  "name": "DoD-STIGs",
  "blobNameOrUri": "DoD-STIGs.zip",
  "arguments": "-ApplicationsToSTIG @('Google Chrome','Mozilla Firefox') -SearchForApplications"
}
```

For PowerShell artifacts, use native PowerShell values in the `arguments` string: `@()` for string
arrays, `$true` or `$false` for booleans, and a parameter name without a value for a switch.
`Invoke-Customization.ps1` converts these values to typed named parameters before invoking the
artifact. See [`customer-examples/artifacts/DoD-STIGs/README.md`](../customer-examples/artifacts/DoD-STIGs/README.md) for all parameters.

**Deploy at VM runtime:** To apply the current STIG package to an existing fleet, add the same artifact reference to the `sessionHostCustomizations` parameter in the host pool deployment instead of `customizations` in the image build. The mechanism is identical; only the parameter name differs. For a new STIG release, prefer building and validating a clean image because incremental application does not guarantee that settings removed from the newer release are deleted.

```json
"sessionHostCustomizations": {
  "value": [
    {
      "name": "DoD-STIGs",
      "blobNameOrUri": "DoD-STIGs.zip",
      "arguments": "-ExecutionProfile SessionHost"
    }
  ]
}
```

**Offline / air-gapped environments:** Pre-download the LGPO tool and STIG GPO package and place them in the `customer/artifacts/DoD-STIGs/` folder before running `Update-ImageArtifacts.ps1`. The script will package the pre-staged files without attempting to download them (LGPO and STIG packages are not in the air-gapped base downloads files). See [`customer-examples/artifacts/DoD-STIGs/README.md`](../customer-examples/artifacts/DoD-STIGs/README.md) for the exact file names expected.

#### Option 2 — DISA STIG GPOs and Intune Policies (Group Policy / MDM)

DISA publishes the full STIG GPO package and Intune-compatible policy packages directly:

| Resource | URL | Format |
| --- | --- | --- |
| STIG GPO packages (latest quarterly release) | [public.cyber.mil/stigs/gpo](https://public.cyber.mil/stigs/gpo) | ZIP (GPO backup format) |
| STIG Viewer (for reviewing individual findings) | [public.cyber.mil/stigs/srg-stig-tools](https://public.cyber.mil/stigs/srg-stig-tools) | Java app / XCCDF |
| Intune DISA STIG policy packages | [dl.dod.cyber.mil/wp-content/uploads/stigs/zip/](https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/) | ZIP (`.intunewin` or JSON) |
| Cyber.mil STIG library (all STIGs) | [public.cyber.mil/stigs](https://public.cyber.mil/stigs) | XCCDF / SCC / ZIP |

For Entra-joined (cloud-only) AVD fleets, import the Intune policy packages into Microsoft Intune and assign them to the session host device group. For hybrid-joined fleets, use Group Policy Objects applied via Active Directory.

#### Option 3 — NIST / CIS Baselines

For non-DoD organizations using NIST or CIS benchmarks instead of DISA STIGs:

| Baseline | Publisher | URL | Notes |
| --- | --- | --- | --- |
| NIST National Checklist Program (NCP) — Windows 11 | NIST | [nvd.nist.gov/ncp/repository](https://nvd.nist.gov/ncp/repository) | SCAP/XCCDF format; DISA STIGs are listed here too |
| CIS Benchmark — Microsoft Windows 11 | CIS | [cisecurity.org/benchmark/microsoft_windows_desktop](https://www.cisecurity.org/benchmark/microsoft_windows_desktop) | PDF + GPO files (CIS member download) |
| CIS Benchmark — Microsoft Windows Server | CIS | [cisecurity.org/cis-benchmarks](https://www.cisecurity.org/cis-benchmarks) | PDF + GPO files |
| CIS Hardened Images (Azure Marketplace) | CIS | Available in Azure Marketplace | Pre-hardened VM images; use as custom image source in `customImageResourceId` |
| Microsoft Security Baselines | Microsoft | [microsoft.com/en-us/download/details.aspx?id=55319](https://www.microsoft.com/en-us/download/details.aspx?id=55319) | LGPO-based; included in Security Compliance Toolkit |
| Azure Policy guest configuration — Windows baselines | Microsoft | [learn.microsoft.com/en-us/azure/governance/policy/samples/guest-configuration-baseline-windows](https://learn.microsoft.com/en-us/azure/governance/policy/samples/guest-configuration-baseline-windows) | Azure Policy initiative; audit or enforce via policy |

> **Recommended combination for FedRAMP High / DoD:** Apply the DISA STIG GPO package via `Apply-STIGsAVD.ps1` in the image build to satisfy CM-6 / SI-7 baseline requirements. Layer CIS Level 2 or Microsoft Security Baseline on top for defense-in-depth. Use Azure Policy guest configuration to continuously audit for drift after deployment.
