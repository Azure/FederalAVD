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

- Install Azure Monitor Agent and associate each session host with the required DCR and DCE.
- Configure FSLogix after independently provisioned profile storage is available.
- Run approved customizations from a private artifact location by using managed identities.
- Assign the required Disk Encryption Set when service-managed hosts are created.
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

The policy add-on deploys policy definitions or initiatives at subscription scope and assigns
them to the dedicated session host resource group. The assignment must exist before Session Host
Configuration creates VMs so new hosts are evaluated immediately. Existing hosts are reported as
noncompliant but are not remediated by this add-on.

The assignment should use a user-assigned managed identity with only the roles required by the
selected policies. A tag-based selector should be available as defense in depth, but resource-group
scope is the primary boundary.

### VM CMK Prerequisite

The VM customer-managed key resources must exist before the policy assignment. This prerequisite
deployment creates or references the Key Vault key, creates the Disk Encryption Set, grants its
managed identity access to the key, and outputs the Disk Encryption Set resource ID.

## Portal Deployment

Use `uiFormDefinition.json` with the subscription-scoped `main.bicep` template. The form discovers
existing resource groups, Disk Encryption Sets, Data Collection Rules, Data Collection Endpoints,
artifact storage accounts, and managed identities from the selected subscription.

The required deployment order is:

1. Deploy the VM CMK and Disk Encryption Set and any monitoring resources.
2. Deploy the standalone `fslogixStorage` add-on and retain its `fslogixConfiguration` output.
3. Create the automated host pool and Session Host Configuration with a desired host count of zero.
4. Deploy this policy add-on to the dedicated future session-host resource group, using the
   standalone storage output to complete the FSLogix fields in the form.
5. Increase the Session Host Configuration desired host count.

The DES policy uses the Azure Policy `Modify` effect to add or replace the VM OS disk
`diskEncryptionSet.id` during the VM create request. Although the other remediation policies use
`DeployIfNotExists`, DES assignment is not a DINE deployment because the target is a property on the
VM request rather than a related child resource. Existing running VMs are outside the initial
remediation contract because changing encryption on an attached OS disk can require deallocation.

## Capability Matrix

| Capability | Initial approach | Source | Status |
| --- | --- | --- | --- |
| Azure Monitor Agent | Assign the Microsoft built-in Windows AMA and DCR initiative | Built-in policy set `0d1b56c6-6d1f-4a5d-8695-b15efbea6b49` | Implemented |
| DCR association | Pass the existing AVD Insights DCR resource ID to the built-in initiative | Existing monitoring deployment output | Implemented |
| DCE association | Assign the initiative's built-in association policy separately in DCE mode | Built-in policy `eab1f514-22e3-42e3-9a1f-e1dc9199355c` | Implemented |
| FSLogix registry settings | Deploy a VM Run Command policy using the existing FederalAVD FSLogix script | Custom policy definition | Implemented |
| Private customizations | Preserve existing VM identities, attach the artifact UAI, and deploy Run Commands | Custom policy definition | Implemented |
| Disk Encryption Set | Inject the precreated DES resource ID into each VM creation request | Custom `Modify` policy | Implemented |

## Design Rules

1. Prefer current Microsoft built-in policies and initiatives when they support the target Azure
   clouds and required resource scope.
2. Do not copy a built-in policy into this repository solely to change assignment parameters.
3. Run Command policies determine compliance from the successful state of the named Run Command.
   They configure newly created hosts once and do not use version changes to target existing hosts.
4. Customization artifacts must be reachable without public network access and authenticated by a
   managed identity. SAS tokens, storage keys, and embedded credentials are not permitted.
5. The policy assignment identity deploys remediation resources; the VM identity retrieves private
   artifacts. These identities and their role assignments must remain distinct in the design.
   The customization deployment unions the artifact UAI into the VM's existing identity map so the
   AMA monitoring identity and any other UAIs are preserved.
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
3. Deploy the AMA and DCR built-in initiative assignment with the roles declared by its policies.
4. Deploy the FSLogix policy from a source-controlled Bicep definition with successful Run Command
   compliance and identity-based storage authentication.
5. Deploy private customizations as individual policy assignments after granting the
   artifact UAI read access to the private blob container.
6. Validate the DES `Modify` policy against VM creation by Session Host Configuration and verify the
   resulting managed disk encryption state.

Private customization assignments are independent and use the same `name`, `blobNameOrUri`, and
optional `arguments` object shape as `sessionHostCustomizations` in the host pool and session hosts
add-on. Relative artifact names resolve against `artifactsContainerUri`; full HTTPS URIs are used as
provided. Execution order is not guaranteed, so combine dependent steps into one artifact package.

The add-on does not create remediation tasks. Existing hosts that lack a successful named Run
Command are reported as noncompliant during periodic evaluation but are not changed automatically.
Use the `runCommandsOnVms` add-on for intentional updates or reruns on existing hosts.

## Open Decisions

- Which tag or immutable VM property can identify hosts belonging to a specific automated host pool?
- Should FSLogix configuration move from Run Command to Azure Machine Configuration after comparing
   sovereign cloud availability, update behavior, and operational cost?
- Should the VM CMK prerequisite be a standalone add-on or an optional module in the policy add-on?
- Which capabilities are required in Azure Government Secret and Top Secret where built-in policy
  versions and external service endpoints can differ?

## Authoritative References

- [Deploy Azure Virtual Desktop](https://learn.microsoft.com/azure/virtual-desktop/create-host-pool)
- [Use Azure Policy to install Azure Monitor Agent](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-policy)
- [Azure Policy remediation](https://learn.microsoft.com/azure/governance/policy/how-to/remediate-resources)
