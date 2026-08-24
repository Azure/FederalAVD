# Automated Session Host Policy

This add-on configures Azure Virtual Desktop session hosts created by the Session Host
Configuration management approach (`managementType: Automated`). It is intended for settings that
the service-managed VM configuration cannot express or cannot deliver through a private,
managed-identity-based path.

> This feature is under active development on the `feature/automated-hostpool-policy` branch.

## Problem

Session Host Configuration manages the creation, update, and deletion of pooled session hosts, but
its VM configuration exposes only a subset of the underlying virtual machine properties. Its custom
configuration script also requires a URL resolvable from the public internet. Those constraints do
not provide the same private artifact delivery and post-deployment configuration available to the
standard FederalAVD host pool deployment.

The add-on must support the following outcomes without taking ownership of the session host VM
lifecycle:

- Preserve the standard host-pool defaults for encryption at host, accelerated networking,
  integrity monitoring, and time zone.
- Optionally install Azure Monitor Agent and associate each session host with a DCR and DCE.
- Optionally configure FSLogix after independently provisioned profile storage is available.
- Run ordered customizations from a private artifact location by using managed identities.
- Optionally create or reuse a Disk Encryption Set and assign it when service-managed hosts are
   created.
- Optionally disable managed-disk public network access with `networkAccessPolicy: DenyAll`.
- Apply only to the intended session host resource group and avoid unrelated Windows VMs.

## Proposed Deployment Boundaries

### FSLogix Storage Add-On

A separate `fslogixStorage` add-on provisions Azure Files or Azure NetApp Files before the host pool
creates session hosts. It reuses the existing FSLogix storage modules and accepts the deployment VM
required for domain registration, Entra Kerberos application updates, and NTFS initialization.

Required outputs are:

- Storage account resource IDs or Azure NetApp Files SMB server FQDNs.
- File share or volume names.
- Private endpoint and DNS dependencies.
- Identity and RBAC information required by the selected identity solution.
- Values consumed by the FSLogix configuration policy assignment.

### Automated Session Host Policy Add-On

The policy add-on deploys policy definitions at subscription scope and assigns
them to the dedicated session host resource group. The assignment must exist before Session Host
Configuration creates VMs so new hosts are evaluated immediately. Existing hosts are reported as
noncompliant but are not remediated by this add-on.

The assignments use a user-assigned managed identity with the roles required by the selected
policies. Resource-group scope is the enforcement boundary, so the target resource group must be
dedicated to session hosts governed by one automated host-pool configuration. Azure requires the
Session Host Configuration VM resource group to exist before the configuration references it. The
same existing resource group must be selected as this add-on's policy assignment scope.

The portal requires selecting the associated pooled host pool. Its resource ID is applied as the
`cm-resource-parent` tag to the existing dedicated session-host resource group and to taggable
resources created by this add-on: a new policy resource group, the policy remediation identity, the
disk-encryption key, and the Disk Encryption Set. Existing tags on the session-host resource group
are preserved. A built-in inheritance policy copies the tag to service-created VMs, NICs, and
managed disks. Policy definitions, policy assignments, and role assignments do not support tags.

All custom policy definitions and nested deployment templates used by this add-on are owned under
`modules/policy`. They are deployed only through this add-on; there is no separate repository-level
policy deployment stack.

### VM CMK Ownership

This add-on supports three disk-encryption modes:

- Platform-managed keys, which do not deploy or assign a Disk Encryption Set.
- Create a Disk Encryption Set by creating a key in an existing RBAC-enabled Key Vault, creating
   the DES in the policy resource group, granting its system-assigned identity key-scoped Key Vault
   Crypto Service Encryption User, and configuring key rotation.
- Reuse an existing Disk Encryption Set.

HSM modes require an existing Premium Key Vault. The Key Vault can be deployed by AVD Shared
Services or managed externally. The add-on intentionally does not create another Key Vault.
Create mode exposes both the Key Vault key name and Disk Encryption Set name in the portal; the
defaults can be replaced with names that meet the respective Azure naming rules.

## Portal Deployment

Use `uiFormDefinition.json` with the subscription-scoped `main.bicep` template. The form discovers
pooled host pools, existing resource groups, Disk Encryption Sets, Data Collection Rules, Data
Collection Endpoints, artifact storage accounts, and managed identities from the selected
subscription.

The required deployment order is:

1. Deploy required shared prerequisites. If creating a DES, deploy or select the encryption Key
   Vault. If monitoring is enabled, deploy the DCR and optional DCE.
2. Create a dedicated resource group for the service-managed session host VMs. Do not place
   unrelated VMs in this resource group because it is also the policy enforcement boundary.
3. Create the pooled host pool with `managementType: Automated` and its Session Host Configuration.
   Select the dedicated resource group as the VM resource group and keep the desired session host
   count at zero.
4. If FSLogix is enabled, deploy the standalone `fslogixStorage` add-on, select the new host pool as
   the existing associated host pool, and retain its `fslogixConfiguration` output.
5. Deploy this policy add-on to the same dedicated session-host resource group. Select the same host
   pool and use the standalone storage output to complete the FSLogix fields in the form.
6. Confirm the storage deployment, policy assignments, managed identities, role assignments, and
   optional DES deployment have succeeded. Allow Azure Policy assignment propagation before
   creating session hosts.
7. Increase the desired session host count.

FSLogix supports up to two local and two remote Azure Files storage accounts in this flow. Storage
account key retrieval and Storage Account Key Operator role assignments are used only when
`identitySolution` is `EntraId`. Entra Kerberos and domain services modes use the account names to
build UNC paths but do not retrieve, pass, or grant access to storage account keys.

Selecting the host pool in the two add-ons associates their newly created resources with that host
pool for cost allocation. The add-on tags the dedicated session-host resource group with
`cm-resource-parent`, then assigns the built-in resource-group tag-inheritance policy so VMs, NICs,
and managed disks receive the same ownership tag when created or updated. Session Host
Configuration `vmTags` remains available for additional VM-only tags.

The DES policy uses the Azure Policy `Modify` effect to add or replace the VM OS disk
`diskEncryptionSet.id` during the VM create request. Although the other remediation policies use
`DeployIfNotExists`, DES assignment is not a DINE deployment because the target is a property on the
VM request rather than a related child resource. Existing running VMs are outside the initial
remediation contract because changing encryption on an attached OS disk can require deallocation.

## Capability Matrix

| Capability | Policy approach | Standard host-pool equivalent | Status |
| --- | --- | --- | --- |
| Encryption at host | Inject `securityProfile.encryptionAtHost` with `Modify` | `encryptionAtHost` | Implemented; enabled by default |
| OS disk size | Inject a nonzero requested size with `Modify`, then expand the guest OS partition in the unified configuration Run Command | `diskSizeGB` | Implemented |
| Accelerated networking | Set the NIC property with `Modify` | `enableAcceleratedNetworking` | Implemented; enabled by default |
| Guest Attestation | Deploy the extension to Trusted Launch and Confidential VMs | `integrityMonitoring` | Implemented; enabled by default |
| Session host configuration | Run one post-provisioning command for the Windows time zone, time zone redirection, optional FSLogix, and guest OS partition expansion | Unified custom policy definition | Implemented |
| VM monitoring identity | Add a system-assigned identity while preserving existing user-assigned identities | VM system-assigned identity | Implemented |
| Azure Monitor Agent | Assign the Microsoft built-in Windows AMA policy for VM system-assigned identity | Built-in policy `ca817e41-e85a-4783-bc7f-dc532d36235e` | Implemented |
| DCR association | Associate each VM with the selected AVD Insights DCR | Built-in policy `244efd75-0d92-453c-b9a3-7d73ca36ed52` | Implemented |
| DCE association | Assign the same built-in association policy in DCE mode | Built-in policy `244efd75-0d92-453c-b9a3-7d73ca36ed52` | Implemented |
| Ownership tags | Inherit `cm-resource-parent` from the dedicated resource group | Built-in policy `cd3aa116-8754-49c9-a813-ad46512ece54` | Implemented |
| FSLogix registry settings | Configure FSLogix conditionally within the unified session-host configuration Run Command | `configureFSLogix` and `fslogixConfiguration` | Implemented |
| Private customizations | Preserve existing VM identities, attach the artifact UAI, and deploy Run Commands serially | `sessionHostCustomizations` | Implemented with input order preserved |
| Disk Encryption Set | Create a key and DES or reuse an existing DES, then inject its resource ID into each VM creation request | `keyManagementDisks` | Implemented |
| Managed-disk public access | Set `publicNetworkAccess: Disabled` and `networkAccessPolicy: DenyAll`; no Disk Access resource is used | `disableManagedDiskPublicNetworkAccess` | Implemented |

## Complete Parity Boundary

Session Host Configuration directly owns the creation-time settings it exposes: pooled host-pool
lifecycle, image, VM size, availability zones, security type, Secure Boot, vTPM, disk SKU or
ephemeral disk, boot diagnostics, subnet and NSG, Entra ID or AD domain join, administrator
credentials, and VM tags. Configure those values on the session host configuration itself.

This add-on owns the settings Session Host Configuration does not expose or cannot deliver from a
private artifact source: encryption at host, optional OS disk sizing and guest partition expansion,
accelerated networking, Guest Attestation, time zone, AMA/DCR/DCE, FSLogix registry settings,
ordered private customizations, optional DES injection, and managed-disk network isolation. Time
zone, time zone redirection, optional FSLogix, and partition expansion run through one policy
deployed Run Command, matching the standard session-host initialization flow.

The following standard-deployment options have no safe equivalent for automated pooled hosts and
are explicit platform boundaries rather than silent policy gaps:

| Standard option | Automated-host boundary |
| --- | --- |
| Availability sets and Dedicated Hosts | Session Host Configuration supports availability zones, not these placement models. |
| IPv6 NIC configuration | The service creates the NIC and its IP configurations; Policy cannot safely add an IPv6 IP configuration. The standard default is disabled. |
| Hibernation | Automated management supports pooled hosts; the standard option is applicable to personal hosts. |
| Personal-session-host VM backup | Automated management supports pooled hosts whose lifecycle is service-managed. Protect FSLogix profile storage instead. |
| Inline FSLogix storage, Key Vault, private endpoints, and backup vaults | Deploy these shared prerequisites before the policy assignment, using `fslogixStorage`, Shared Services, or existing resources. The policy add-on can create the disk key and DES in an existing Key Vault. |
| GPU extension auto-detection | Bake drivers into the image or include the required driver as an ordered private customization. |

## Design Rules

1. Prefer current Microsoft built-in policies and initiatives when they support the target Azure
   clouds and required resource scope.
2. Do not copy a built-in policy into this repository solely to change assignment parameters.
3. Run Command policies determine compliance from the successful state of the named Run Command.
   They configure newly created hosts once and do not use version changes to target existing hosts.
4. Customization artifacts must be reachable without public network access and authenticated by a
   managed identity. SAS tokens, storage keys, and embedded credentials are not permitted.
5. The policy assignment identity deploys remediation resources; the VM identity retrieves private
   artifacts and authenticates Azure Monitor Agent. These identities and their role assignments
   must remain distinct in the design.
   The customization deployment unions the artifact UAI into the VM's existing identity map so the
   system-assigned identity and any other UAIs are preserved.
6. The DES assignment must be deployed before host creation. Existing-host DES remediation is a
   separate maintenance workflow and must not run automatically.
7. Policy definitions, assignments, and role assignments must be deployable independently of the
   automated host pool.
8. Built-in policy availability must be validated per Azure cloud. Unsupported built-ins need an
   explicit deployment blocker or a reviewed custom equivalent.

## Implementation Phases

1. Validate Session Host Configuration resource APIs, VM tagging behavior, and built-in policy
   availability in each supported Azure cloud.
2. Extract the FSLogix storage deployment into a standalone add-on with stable outputs.
3. Deploy the VM system-assigned identity, AMA, DCR, and optional DCE policy assignments with the
   roles declared by their policies.
4. Deploy the FSLogix policy from a source-controlled Bicep definition with successful Run Command
   compliance and identity-based storage authentication.
5. Deploy private customizations as one serial policy deployment after granting the artifact UAI
   read access to the private blob container.
6. Validate the DES `Modify` policy against VM creation by Session Host Configuration and verify the
   resulting managed disk encryption state.

Private customizations use the same `name`, `blobNameOrUri`, and
optional `arguments` object shape as `sessionHostCustomizations` in the host pool and session hosts
add-on. Relative artifact names resolve against `artifactsContainerUri`; full HTTPS URIs are used as
provided. The supplied array order is preserved with serial nested deployments.

The add-on does not create remediation tasks. Existing hosts that lack a successful named Run
Command are reported as noncompliant during periodic evaluation but are not changed automatically.
Use the `runCommandsOnVms` add-on for intentional updates or reruns on existing hosts.

## Authoritative References

- [Deploy Azure Virtual Desktop](https://learn.microsoft.com/azure/virtual-desktop/create-host-pool)
- [Use Azure Policy to install Azure Monitor Agent](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-policy)
- [Azure Policy remediation](https://learn.microsoft.com/azure/governance/policy/how-to/remediate-resources)
