# Session Host Policy Authoring

This guide defines the source-of-truth and validation workflow for FederalAVD session-host Azure
Policy. All policy definitions, initiatives, assignment helpers, remediation helpers, and nested
policy deployment templates live in this directory, even when a capability currently has only one
consumer.

Deployment entry points remain responsible for adapting their public inputs and sequencing shared
policy capabilities. The Automated Host Pool adapter is
`deployments/automatedHostPools/policy/main.bicep`; the standalone selective adapter is
`deployments/add-ons/sessionHostPolicy/main.bicep`.

## Deployment Model

Policy definitions and initiatives are authored as Bicep resources under `modules/` and deployed
directly by a consuming orchestration. They are not compiled to standalone ARM files and then
loaded by another Bicep deployment.

Some `DeployIfNotExists` definitions embed an ARM deployment template in
`policyRule.then.details.deployment`. Those nested templates follow this path:

```text
Nested remediation Bicep
  -> adjacent generated ARM JSON
  -> loadJsonContent() in a policy-definition module
  -> embedded in the policy definition
  -> executed by Azure Policy when remediation is required
```

The complete automated-host-pool chain is:

```text
automatedHostPool.bicep
  -> automatedHostPools/policy/main.bicep
    -> shared sessionHostPolicy definitions and initiatives
    -> shared policyAssignment.bicep
    -> shared capability orchestration where applicable
    -> remediation identity and required role assignments
```

## Directory Layout

```text
sessionHostPolicy/
  AUTHORING.md
  vmApplications.bicep
  monitoring.bicep
  guestAttestation.bicep
  managedDiskNetworkAccess.bicep
  modules/
    *.policyDefinition.bicep
    *.policySetDefinition.bicep
    policyAssignment.bicep
    remediation.bicep
    templates/
      AssignUAI/
      Associations/
      Extensions/
      RunCommand/
```

Top-level capability modules provide reusable composition. Files under `modules/` provide the
canonical definitions, initiatives, assignments, remediation helpers, RBAC helpers, and nested
policy templates. A capability does not need multiple current consumers to belong here; policy
ownership is organized by the session-host governance domain rather than consumer count.

## Source Of Truth

- Policy definitions and initiatives under `modules/` directly declare
  `Microsoft.Authorization/policyDefinitions` or
  `Microsoft.Authorization/policySetDefinitions` and are the only source for those resources.
- A nested deployment template with both Bicep and JSON uses Bicep as its source. Regenerate the
  adjacent JSON after every Bicep change.
- `modules/policyAssignment.bicep` is the assignment wrapper for every custom or built-in policy
  assignment in this domain. It records deterministic ownership metadata.
- Top-level capability modules own reusable assignment, RBAC, ownership, and remediation behavior.
- Consumer adapters own input translation and consumer-specific sequencing. They must not contain
  duplicate policy definitions or nested policy templates.

## Choosing A Policy Effect

Use `Modify` when policy must alter fields on the evaluated VM, NIC, identity, or disk request.
Use `DeployIfNotExists` when compliance requires a related resource such as an extension, Run
Command, or data-collection association. Use an initiative only when member policies share a
lifecycle, assignment scope, remediation identity, and sequencing.

## Adding Or Changing A Policy

1. Add or update `<capability>.policyDefinition.bicep` under `modules/`.
2. Declare `targetScope = 'subscription'` and use the current policy-definition API version.
3. Use the `Azure Virtual Desktop` category and the established session-host governance metadata.
4. Include `Disabled` when a definition can remain in an initiative while its behavior is off.
5. Output `policyDefinitionResourceId`.
6. For `DeployIfNotExists`, maintain the nested deployment under `modules/templates/`, regenerate
   its adjacent JSON, and keep definition, nested-template, initiative, and assignment parameters
   aligned.
7. For `Modify`, verify every operation uses an available modifiable alias and an appropriate
   conflict effect.
8. Wire the definition output into its intended initiative or assignment; do not reconstruct a
   definition resource ID when a module exposes it.
9. Grant every role listed in `roleDefinitionIds` to the remediation identity at the narrowest
   workable scope.
10. Preserve deterministic definition, initiative, assignment, and remediation names unless a
    reviewed replacement is intended.

## Assignments And Ownership

Assignments are scoped to a dedicated session-host resource group. This scope is a security and
correctness boundary because several definitions intentionally use broad resource-type predicates.
Do not assign them to a resource group containing unrelated VMs, NICs, or managed disks.

Use `modules/policyAssignment.bicep` for assignments. Pass a stable `ownerId` so assignment metadata
identifies the owning deployment. The standalone add-on also protects its resource-group boundary
with the `FederalAVD-SessionHostPolicy-Owner` tag. Use explicit dependencies when enforcement relies
on RBAC propagation or another assignment being present first.

## Nested Templates And Build Order

Build changed nested templates before any definition that loads their JSON. Current generated pairs
are:

| Bicep source | Generated ARM JSON |
| --- | --- |
| `modules/templates/RunCommand/ConfigureSessionHost.bicep` | Adjacent `ConfigureSessionHost.json` |
| `modules/templates/RunCommand/PrivateCustomization.bicep` | Adjacent `PrivateCustomization.json` |
| `modules/templates/Extensions/AzureMonitorWindowsAgent.bicep` | Adjacent `AzureMonitorWindowsAgent.json` |
| `modules/templates/Extensions/GuestAttestation.bicep` | Adjacent `GuestAttestation.json` |
| `modules/templates/Associations/DataCollectionAssociation.bicep` | Adjacent `DataCollectionAssociation.json` |

After building nested templates, compile each affected adapter. Regenerate a tracked entry-point ARM
JSON whenever its Bicep source or a transitive module changes.

For Automated Host Pools:

```powershell
az bicep build `
  --file deployments/shared/modules/orchestration/sessionHostPolicy/modules/templates/RunCommand/PrivateCustomization.bicep `
  --outfile deployments/shared/modules/orchestration/sessionHostPolicy/modules/templates/RunCommand/PrivateCustomization.json

az bicep build `
  --file deployments/automatedHostPools/policy/main.bicep `
  --stdout | Out-Null

az bicep build `
  --file deployments/automatedHostPools/automatedHostPool.bicep `
  --outfile deployments/automatedHostPools/automatedHostPool.json
```

For the standalone add-on, regenerate `deployments/add-ons/sessionHostPolicy/main.json` from its
Bicep entry point.

## Managed Identity Responsibilities

Keep these identities distinct:

- The policy assignment identity deploys remediation resources.
- The artifact user-assigned identity retrieves private customization artifacts.
- The VM system-assigned identity authenticates Azure Monitor Agent.

Private customization receives Managed Identity Operator only on the artifact identity. Its nested
VM update unions the artifact identity with existing VM identities so the system-assigned identity
and any other user-assigned identities remain intact.

## Validation Checklist

Before submitting a policy change:

1. Build every changed nested-template Bicep file to its adjacent JSON.
2. Build every affected shared capability and consumer adapter.
3. Regenerate tracked entry-point ARM JSON files.
4. Run the Bicep/ARM synchronization checks.
5. Confirm each definition output is consumed by the intended initiative or assignment.
6. Confirm every `roleDefinitionIds` entry has a matching role assignment.
7. Confirm conditional definitions, assignments, RBAC, and remediations use compatible conditions.
8. Confirm no policy definitions or nested templates remain under consumer-specific directories.
9. Run focused Pester tests, PowerShell parser and ASCII checks, Markdown checks, and
   `git diff --check`.

PowerShell loaded with `loadTextContent()` must remain ASCII-only.

## Common Mistakes

- Adding a policy implementation under a consumer adapter instead of this domain directory.
- Loading a remediation Bicep file with `loadJsonContent()` instead of its generated JSON.
- Editing generated nested-template JSON directly.
- Building a consumer before rebuilding a changed nested template.
- Adding a role to `roleDefinitionIds` without granting it to the assignment identity.
- Using a broad policy predicate outside a dedicated session-host resource group.
- Treating asynchronous policy deployment as proof that guest configuration has converged.
