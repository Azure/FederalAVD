# Automated Session Host Policy

This internal deployment stage configures Azure Virtual Desktop session hosts created by the Session Host
Configuration management approach (`managementType: Automated`). It is intended for settings that
the service-managed VM configuration cannot express or cannot deliver through a private,
managed-identity-based path.

See [Automated Host-Pool Policy Authoring](AUTHORING.md) for the contributor workflow, directory
layout, source-of-truth rules, and validation commands.

> This feature is under active development on the `feature/automated-hostpool-policy` branch.

## Problem

Session Host Configuration manages the creation, update, and deletion of pooled session hosts, but
its VM configuration exposes only a subset of the underlying virtual machine properties. Its custom
configuration script also requires a URL resolvable from the public internet. Those constraints do
not provide the same private artifact delivery and post-deployment configuration available to the
standard FederalAVD host pool deployment.

The policy stage must support the following outcomes without taking ownership of the session host VM
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

## Deployment Boundaries

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

### Policy Stage

The policy module deploys policy definitions at subscription scope and assigns
them to the dedicated session host resource group. The assignment must exist before Session Host
Management provisions VMs so new hosts are evaluated immediately. Existing hosts are reported as
noncompliant but are not remediated by this module.

The assignments use a user-assigned policy remediation identity with the roles required by the selected
policies. Resource-group scope is the enforcement boundary, so the target resource group must be
dedicated to resources governed by one automated host-pool configuration. Azure requires the
Session Host Configuration VM resource group to exist before the configuration references it. The
same resource group contains the service-managed session hosts, policy remediation identity, and
optional Disk Encryption Set.

The policy remediation identity follows the host pool naming convention with the purpose component
`<host-pool>-policy-remediation`. A custom `Modify` policy enables system-assigned identity on every
session host create request while preserving any existing user-assigned identities. Azure Monitor
Agent uses that system-assigned identity for authentication.

Azure Policy exposes `identity.type` as a modifiable field but does not expose the VM
`identity.userAssignedIdentities` map through a modifiable alias. Private customization therefore
uses one post-provisioning VM update to union the selected artifact identity into the existing map.
The policy remediation identity receives Managed Identity Operator directly on that artifact
identity, and the customization assignment depends on the role assignment. This preserves the
creation-time system identity and prevents competing full identity updates.

The parent deployment supplies the associated pooled host pool. Its resource ID is applied as the
`cm-resource-parent` tag to the existing dedicated session-host resource group and to taggable
resources created by this module: the policy remediation identity, disk-encryption key, and Disk
Encryption Set. Existing tags on the session-host resource group are
preserved. A built-in inheritance policy copies the tag to service-created VMs, NICs, and managed
disks. Policy definitions, policy assignments, and role assignments do not support tags.

All custom policy definitions and nested deployment templates used by this module are owned under
`modules/policy`. They are deployed only through the automated host-pool deployment; there is no separate repository-level
policy deployment stack.

### Why Custom Policies and Initiatives

Session Host Configuration creates virtual machines through the Azure Virtual Desktop service. Its
VM create request does not always contain persisted properties such as
`storageProfile.osDisk.osType`. The built-in Azure Monitor Agent and data-collection association
policies use that field in request-time image predicates, so they can miss the create request and
cannot reliably deploy the required child resources automatically. The custom monitoring policies
match the VM resource type at the dedicated session-host resource-group scope instead. This scope
is the operating-system and workload boundary that makes the broader request-time predicate safe.

Custom `Modify` policies are also required for creation settings that Session Host Configuration
does not expose directly, including encryption at host, OS disk sizing, Disk Encryption Set,
system-assigned identity, accelerated networking, and managed-disk network access. Applying these
settings to the initial VM, NIC, or disk request avoids a post-provisioning replacement workflow.

The creation-settings and monitoring initiatives group policies that share a lifecycle, assignment
scope, and remediation identity. This reduces assignment and propagation overhead while retaining
member-level effects for optional capabilities. Creation-settings policy resources use the
`avdSessionHost*` name family and the following shared metadata so they can be discovered together
without depending on the repository name or deployment method:

- `category: Azure Virtual Desktop`
- `solution: AVD Session Host Governance`
- `component: Creation Settings`

The creation initiative is assigned by the automated host-pool deployment as
`avd-sh-creation-settings`. Its resource-type predicates require assignment to a dedicated session-host
resource group, whether the hosts are service-created, portal-created, or deployed through another
workflow. Monitoring and post-provisioning policies retain automated-host-pool metadata because their
request-shape and sequencing assumptions have not been generalized.

### VM CMK Ownership

This module supports three disk-encryption modes:

- Platform-managed keys, which do not deploy or assign a Disk Encryption Set.
- Create a Disk Encryption Set by creating a key in an existing RBAC-enabled Key Vault, creating
   the DES in the session-host resource group, granting its system-assigned identity key-scoped Key Vault
   Crypto Service Encryption User, and configuring key rotation.
- Reuse an existing Disk Encryption Set.

HSM modes require an existing Premium Key Vault. The Key Vault can be deployed by AVD Shared
Services or managed externally. The module intentionally does not create another Key Vault.
Create mode accepts both the Key Vault key name and Disk Encryption Set name from the parent
deployment; the defaults can be replaced with names that meet the respective Azure naming rules.

## Integrated Deployment

The required deployment order is:

1. Deploy required shared prerequisites. If creating a DES, deploy or select the encryption Key
   Vault. If monitoring is enabled, deploy the DCR and optional DCE.
2. Create a dedicated resource group for the service-managed session host VMs. Do not place
   unrelated VMs in this resource group because it is also the policy enforcement boundary.
3. Create the pooled host pool with `managementType: Automated` and its Session Host Configuration.
   Select the dedicated resource group as the VM resource group and keep the desired session host
   count at zero.
4. If FSLogix is enabled, deploy the `fslogixStorage` module and retain its
   `fslogixConfiguration` output.
5. Deploy this policy module to the dedicated session-host resource group using the host pool and
   FSLogix outputs supplied by the parent deployment.
6. Update Session Host Management with the requested host count only after storage, policy,
   managed identities, role assignments, and optional DES deployment have succeeded.

FSLogix supports up to two local and two remote Azure Files storage accounts in this flow. All
supported identity modes use identity-based SMB authentication. The policy uses storage account
names to build UNC paths and does not retrieve, pass, or grant access to storage account keys.

The parent deployment associates newly created resources with the host pool for cost allocation.
The policy module tags the dedicated session-host resource group with
`cm-resource-parent`, then assigns the built-in resource-group tag-inheritance policy so VMs, NICs,
and managed disks receive the same ownership tag when created or updated. Session Host
Configuration `vmTags` remains available for additional VM-only tags.

The DES member of the creation-settings initiative uses the Azure Policy `Modify` effect to add or
replace the VM OS disk `diskEncryptionSet.id` during the VM create request. Unlike the remediation
policies that use `DeployIfNotExists`, this member is not a DINE deployment because the target is a
property on the VM request rather than a related child resource. Existing running VMs are outside the initial
remediation contract because changing encryption on an attached OS disk can require deallocation.

The creation-settings initiative uses one assignment for compute settings, Disk Encryption Set,
system-assigned identity, accelerated networking, and managed-disk network access. Disk Encryption
Set and managed-disk network access use member-level effects. Accelerated networking also uses a
member-level effect so `enableAcceleratedNetworking: false` leaves the NIC property unmanaged.
Within the compute member, `encryptionAtHost: false` skips only that operation; a nonzero OS disk
size remains enforceable independently.

## Capability Matrix

| Capability | Policy approach | Standard host-pool equivalent | Status |
| --- | --- | --- | --- |
| Encryption at host | Inject `securityProfile.encryptionAtHost` with `Modify` when enabled; leave the property unmanaged when disabled | `encryptionAtHost` | Implemented; enabled by default |
| OS disk size | Inject a nonzero requested size with `Modify`, then expand the guest OS partition in the unified configuration Run Command | `diskSizeGB` | Implemented |
| Accelerated networking | Set the NIC property with `Modify` when enabled; disable the initiative member otherwise | `enableAcceleratedNetworking` | Implemented; enabled by default |
| Guest Attestation | Deploy the extension to Trusted Launch and Confidential VMs | `integrityMonitoring` | Implemented; enabled by default |
| Session host configuration | Run one post-provisioning command for the Windows time zone, time zone redirection, optional FSLogix, and guest OS partition expansion | Unified custom policy definition | Implemented |
| VM identity | Enable system-assigned identity during creation while preserving existing user-assigned identities | Custom `Modify` policy modeled on built-in policy `17b3de92-f710-4cf4-aa55-0e7859f1ed7b` | Implemented |
| Azure Monitor Agent | Deploy AMA after the system-assigned identity `Modify` policy applies | Custom monitoring initiative and AMA policy definition | Implemented |
| DCR association | Associate each VM with the selected AVD Insights DCR | Custom monitoring initiative and association policy definition | Implemented |
| DCE association | Reference the association policy a second time in optional DCE mode | Custom monitoring initiative and association policy definition | Implemented |
| Ownership tags | Inherit `cm-resource-parent` from the dedicated resource group | Built-in policy `cd3aa116-8754-49c9-a813-ad46512ece54` | Implemented |
| FSLogix registry settings | Configure FSLogix conditionally within the unified session-host configuration Run Command | `configureFSLogix` and `fslogixConfiguration` | Implemented |
| Private customizations | Union the artifact UAI into the existing VM identity map, then deploy Run Commands serially | `sessionHostCustomizations` | Implemented with input order preserved and resource-scoped Managed Identity Operator |
| Disk Encryption Set | Create a key and DES or reuse an existing DES, then inject its resource ID into each VM creation request | `keyManagementDisks` | Implemented |
| Managed-disk public access | Set `publicNetworkAccess: Disabled` and `networkAccessPolicy: DenyAll`; no Disk Access resource is used | `disableManagedDiskPublicNetworkAccess` | Implemented |

## Complete Parity Boundary

Session Host Configuration directly owns the creation-time settings it exposes: pooled host-pool
lifecycle, image, VM size, availability zones, security type, Secure Boot, vTPM, disk SKU or
ephemeral disk, boot diagnostics, subnet and NSG, Entra ID or AD domain join, administrator
credentials, and VM tags. Configure those values on the session host configuration itself.

The parent automated host-pool deployment can also attach an AVD dynamic scaling plan. Dynamic
create/delete behavior belongs to the scaling plan and its pooled schedule, not to this policy
stage.

This policy stage owns the settings Session Host Configuration does not expose or cannot deliver from a
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
| Inline FSLogix storage, Key Vault, private endpoints, and backup vaults | Deploy these shared prerequisites before the policy assignment, using `fslogixStorage`, Shared Services, or existing resources. The policy module can create the disk key and DES in an existing Key Vault. |
| GPU extension auto-detection | Bake drivers into the image or include the required driver as an ordered private customization. |

## Design Rules

1. Prefer current Microsoft built-in policies and initiatives when they support the target Azure
   clouds and required resource scope.
2. Do not copy a built-in policy into this repository solely to change assignment parameters.
3. Run Command policies determine compliance from the successful state of the named Run Command.
   They configure newly created hosts once and do not use version changes to target existing hosts.
4. Customization artifacts must be reachable without public network access and authenticated by a
   managed identity. SAS tokens, storage keys, and embedded credentials are not permitted.
5. The policy assignment identity deploys remediation resources; the artifact UAI retrieves private
   artifacts, and the VM system-assigned identity authenticates Azure Monitor Agent. These
   identities and their role assignments must remain distinct in the design.
   The customization deployment unions the artifact UAI into the VM's existing identity map so the
   system-assigned identity and any other identities are preserved.
   Managed Identity Operator is granted to the policy assignment identity at the artifact identity
   resource scope, not at subscription or resource-group scope.
6. The DES assignment must be deployed before host creation. Existing-host DES remediation is a
   separate maintenance workflow and must not run automatically.
7. Policy definitions, assignments, and role assignments are deployed as an internal stage of the
   automated host-pool dependency graph.
8. Built-in policy availability must be validated per Azure cloud. Unsupported built-ins need an
   explicit deployment blocker or a reviewed custom equivalent.

The automated host-pool deployment currently blocks non-Commercial clouds. The custom monitoring
initiative is therefore deployed only where its Azure Monitor Agent extension and association
resources are confirmed available. Azure Monitor Agent VM extensions are not supported in
air-gapped clouds; enabling automated host pools there requires a separately reviewed MSI-based
monitoring design.

## Implementation Phases

1. Validate Session Host Configuration resource APIs, VM tagging behavior, and built-in policy
   availability in each supported Azure cloud.
2. Extract the FSLogix storage deployment into a standalone add-on with stable outputs.
3. Deploy the creation-settings initiative, then deploy the custom AMA, DCR, and optional DCE
   monitoring initiative with the roles declared by its policies.
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

The policy module does not create remediation tasks. Existing hosts that lack a successful named Run
Command are reported as noncompliant during periodic evaluation but are not changed automatically.
Use the `runCommandsOnVms` add-on for intentional updates or reruns on existing hosts.

## Authoritative References

- [Deploy Azure Virtual Desktop](https://learn.microsoft.com/azure/virtual-desktop/create-host-pool)
- [Use Azure Policy to install Azure Monitor Agent](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-policy)
- [Azure Policy remediation](https://learn.microsoft.com/azure/governance/policy/how-to/remediate-resources)
