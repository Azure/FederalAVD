# Automated Host-Pool Policy Authoring

This guide explains how the automated host-pool policy stage is organized and how contributors
should add or change policy definitions, initiatives, remediation templates, assignments, and role
assignments.

## Deployment Model

Policy definitions are authored as Bicep resources and deployed directly by
`policy/main.bicep`. They are not compiled to standalone ARM files and then loaded by another
Bicep deployment.

Some `DeployIfNotExists` policies need an ARM deployment template in
`policyRule.then.details.deployment`. Those nested remediation templates follow a separate path:

```text
Nested remediation Bicep
  -> generated ARM JSON
  -> loadJsonContent() in a policy-definition Bicep module
  -> embedded in the policy definition
  -> executed by Azure Policy when remediation is required
```

The complete deployment chain is:

```text
automatedHostPool.bicep
  -> policy/main.bicep
    -> custom policy-definition Bicep modules
    -> policy-set-definition Bicep modules
    -> policyAssignment.bicep
    -> remediation identity and required role assignments
```

## Directory Layout

```text
policy/
  main.bicep                         Orchestrates definitions, initiatives, assignments, and RBAC
  modules/
    policyAssignment.bicep           Deploys a resource-group-scoped policy assignment
    policy/
      bicep/                         Deployable policy and policy-set definitions
        *.policyDefinition.bicep
        *.policySetDefinition.bicep
      templates/                     Nested DeployIfNotExists remediation templates
        Associations/
        Extensions/
        RunCommand/
```

The empty `modules/policy/definitions/` directory is not part of the active deployment path. Do
not place new policy definitions there.

## Source Of Truth

Use the following ownership rules:

- Files under `modules/policy/bicep/` are the source of truth for custom policy definitions and
  initiatives. They directly declare `Microsoft.Authorization/policyDefinitions` or
  `Microsoft.Authorization/policySetDefinitions`.
- A remediation template with both `.bicep` and `.json` files uses the `.bicep` file as its source
  of truth. Regenerate the adjacent JSON after every Bicep change.
- `Extensions/AzureMonitorWindowsAgent.json` and
  `Associations/DataCollectionAssociation.json` are currently JSON-only remediation templates.
  Edit them as structured JSON until they gain Bicep sources.
- `policy/main.bicep` owns composition and sequencing. It passes definition resource IDs into
  initiatives, assigns definitions or initiatives, provisions the remediation identity, and grants
  required roles.
- `modules/policyAssignment.bicep` is the shared assignment wrapper. Reuse it instead of declaring
  policy assignments independently.

## Choosing A Policy Effect

Use `Modify` when the policy must alter fields on the evaluated resource request, such as VM,
network-interface, identity, disk-encryption, or managed-disk properties. A `Modify` policy does
not contain a nested remediation deployment template.

Use `DeployIfNotExists` when compliance requires a related resource, such as a VM extension, Run
Command, or data-collection association. Its policy definition must embed an ARM deployment
template under `details.deployment`.

Use an initiative when several policies share one lifecycle, assignment scope, remediation
identity, and deployment sequence. Keep independently optional or differently sequenced behavior
as a separate assignment.

## Adding A Modify Policy

1. Add `<capability>.policyDefinition.bicep` under `modules/policy/bicep/`.
2. Declare `targetScope = 'subscription'` and a
   `Microsoft.Authorization/policyDefinitions@2024-05-01` resource.
3. Use the `Azure Virtual Desktop` category and metadata consistent with the owning policy group.
4. Include a `Disabled` effect so the definition can remain in an initiative while its behavior is
   turned off.
5. Output `policyDefinitionResourceId`.
6. Instantiate the module from `policy/main.bicep`.
7. Add it to the appropriate policy-set definition, or assign it separately when its lifecycle or
   role requirements differ.
8. Grant the remediation identity only the roles required by the policy operations.

## Adding A DeployIfNotExists Policy

1. Create the nested remediation template under the appropriate `templates/` subdirectory.
2. Prefer Bicep for a new template. Keep its generated JSON adjacent to it because
   `loadJsonContent()` runs while the policy-definition module is compiled.
3. Add `<capability>.policyDefinition.bicep` under `modules/policy/bicep/`.
4. Load the generated template JSON with `loadJsonContent()` and assign it to
   `details.deployment.properties.template`.
5. Keep the policy parameters and nested-template parameters aligned explicitly in the
   `details.deployment.properties.parameters` mapping.
6. Define an `existenceCondition` that measures the actual desired state. For Run Commands, this
   repository treats a successful provisioning state as compliance.
7. Include the required `roleDefinitionIds` in the policy definition and grant corresponding roles
   to the assignment identity in `policy/main.bicep`.
8. Add the definition to an initiative or create a separate assignment through
   `policyAssignment.bicep`.

## Initiatives And Assignments

Initiative modules accept policy-definition resource IDs as parameters and emit
`policySetDefinitionResourceId`. Do not reconstruct definition IDs by name when the creating module
already exposes the ID.

Assignments are scoped to the dedicated session-host resource group. This scope is a security and
correctness boundary because several policies intentionally use broad resource-type predicates.
Do not assign these policies to a resource group containing unrelated virtual machines.

Assignment parameters use the Azure Policy parameter envelope:

```bicep
parameters: {
  effect: {
    value: 'Modify'
  }
}
```

Use explicit `dependsOn` entries when policy enforcement depends on RBAC propagation or another
assignment being present first. Keep policy definition, initiative, assignment, and role-assignment
names stable because changing them can replace governance resources.

## Build Order

Build changed nested remediation templates before compiling a policy definition that loads their
JSON. For example:

```powershell
az bicep build `
  --file deployments/automatedHostPools/policy/modules/policy/templates/RunCommand/ConfigureSessionHost.bicep `
  --outfile deployments/automatedHostPools/policy/modules/policy/templates/RunCommand/ConfigureSessionHost.json

az bicep build `
  --file deployments/automatedHostPools/policy/main.bicep `
  --stdout | Out-Null

az bicep build `
  --file deployments/automatedHostPools/automatedHostPool.bicep `
  --outfile deployments/automatedHostPools/automatedHostPool.json
```

The known generated remediation pairs are:

| Bicep source | Generated ARM JSON |
| --- | --- |
| `templates/RunCommand/ConfigureSessionHost.bicep` | `templates/RunCommand/ConfigureSessionHost.json` |
| `templates/RunCommand/PrivateCustomization.bicep` | `templates/RunCommand/PrivateCustomization.json` |
| `templates/Extensions/GuestAttestation.bicep` | `templates/Extensions/GuestAttestation.json` |

`PrivateCustomization.bicep` must be rebuilt before the top-level automated host-pool template
because its generated JSON is loaded transitively during that build.

## Validation Checklist

Before submitting a policy change:

1. Build every changed remediation Bicep file to its adjacent JSON file.
2. Build `policy/main.bicep` to catch definition, initiative, parameter, and scope errors.
3. Rebuild the tracked `automatedHostPool.json` from `automatedHostPool.bicep`.
4. Run the Bicep/ARM synchronization check:

   ```powershell
   & .github/skills/federalavd-bicep-maintenance/scripts/Test-BicepArmSync.ps1 `
     -BicepPath deployments/automatedHostPools/automatedHostPool.bicep
   ```

5. Confirm every definition or initiative output is consumed by the intended assignment.
6. Confirm every `roleDefinitionIds` entry has a matching assignment for the policy remediation
   identity at the narrowest workable scope.
7. Verify assignment ordering for creation-time settings, monitoring, configuration, and private
   customization.
8. Run `git diff --check` and inspect generated JSON changes for unexpected churn.

For PowerShell files embedded through `loadTextContent()`, keep all content ASCII-only and run the
repository-required ASCII and parser checks after every edit.

## Common Mistakes

- Loading a remediation `.bicep` file with `loadJsonContent()` instead of its generated JSON.
- Editing generated remediation JSON when a sibling Bicep source exists.
- Rebuilding the top-level template before rebuilding a changed nested remediation template.
- Adding a policy definition without wiring its output into an initiative or assignment.
- Declaring a role in `roleDefinitionIds` without granting it to the assignment identity.
- Using a broad policy predicate outside the dedicated session-host resource-group boundary.
- Treating `Modify` and `DeployIfNotExists` as interchangeable. They run at different points and
  solve different resource-shape problems.
