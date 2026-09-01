---
name: federalavd-policy-authoring
description: "Create, modify, review, and validate FederalAVD session-host Azure Policy definitions, initiatives, assignments, remediation templates, and policy RBAC. Use when changing Modify or DeployIfNotExists policies, nested deployment templates, policy sets, policy assignment parameters, compliance conditions, or policy deployment sequencing."
argument-hint: "[policy capability or file]"
---

# FederalAVD Policy Authoring

Use this workflow for policy resources under
`deployments/shared/modules/orchestration/sessionHostPolicy/`. Read its `AUTHORING.md` before
changing policy structure. Consumer entry points such as `deployments/automatedHostPools/policy/`
adapt and sequence these canonical modules but do not own policy implementations.

## Procedure

1. Start from the policy capability and trace its complete path:

   ```text
   automatedHostPool.bicep
     -> policy/main.bicep
       -> policy definition or initiative
       -> policyAssignment.bicep
       -> remediation identity and role assignments
   ```

    Trace every affected consumer to the canonical shared orchestration. Keep one definition and
    deterministic assignment implementation; do not copy policy resources into consumer entry points.

2. Classify the behavior before editing:

   - Use `Modify` for properties changed on the evaluated VM, NIC, identity, or disk request.
   - Use `DeployIfNotExists` for related resources such as extensions, Run Commands, and data
     collection associations.
   - Use an initiative only when member policies share lifecycle, assignment scope, remediation
     identity, and sequencing.

3. Obtain current Bicep best practices and authoritative Azure resource schemas for every resource
   type being changed. For policy fields, effects, and aliases, verify current Microsoft Azure
   Policy documentation rather than inferring behavior from existing generated JSON.

4. Treat policy definition and initiative files under the shared `modules/` directory as direct deployment sources. Policy definition
   modules must declare `Microsoft.Authorization/policyDefinitions`; initiative modules must
   declare `Microsoft.Authorization/policySetDefinitions`. Do not generate standalone ARM files for
   these modules for another Bicep file to ingest.

5. For a `DeployIfNotExists` policy, maintain its nested remediation template under the shared
  `modules/templates/` directory:

   - Prefer Bicep for new remediation templates.
   - When a sibling `.bicep` exists, edit it and regenerate its adjacent `.json`; never hand-edit
     that generated JSON.
   - The policy-definition Bicep module loads the generated JSON with `loadJsonContent()` and embeds
     it under `details.deployment.properties.template`.
   - Keep any PowerShell loaded with `loadTextContent()` ASCII-only and run parser and ASCII checks.

6. Keep policy parameters aligned across every boundary:

   - Policy definition parameter declaration.
   - Policy rule references.
   - Nested deployment parameter mapping for `DeployIfNotExists`.
   - Initiative member parameter mapping, when applicable.
   - Assignment parameter envelope in `policy/main.bicep`.
   - Public automated-host-pool parameter and UI form, when user configurable.

7. Make compliance checks measure the intended end state. Run Command policies in this repository
   use successful provisioning of the named Run Command as compliance. Do not use version changes
   to force existing hosts through a new customization unless the lifecycle contract is explicitly
   changed.

8. Keep RBAC synchronized with policy behavior:

   - Every role in a policy definition's `roleDefinitionIds` must have a corresponding assignment
     for the remediation identity.
   - Grant roles at the narrowest workable scope.
   - Keep the remediation identity, artifact-download identity, and VM system-assigned identity
     responsibilities distinct.
   - Add explicit dependencies when assignment activation relies on RBAC propagation or another
     policy assignment.

9. Preserve the dedicated session-host resource group as the policy enforcement boundary. Do not
   broaden assignments for policies whose resource-type predicates rely on that isolation.

10. Build generated dependencies before their consumers. For each changed remediation Bicep file:

    ```powershell
    az bicep build `
      --file <nested-template>.bicep `
      --outfile <nested-template>.json
    ```

11. Compile the policy stage, regenerate the tracked automated-host-pool ARM template, and verify
    synchronization:

    ```powershell
    az bicep build `
      --file deployments/automatedHostPools/policy/main.bicep `
      --stdout | Out-Null

    az bicep build `
      --file deployments/automatedHostPools/automatedHostPool.bicep `
      --outfile deployments/automatedHostPools/automatedHostPool.json

    & .github/skills/federalavd-bicep-maintenance/scripts/Test-BicepArmSync.ps1 `
      -BicepPath deployments/automatedHostPools/automatedHostPool.bicep
    ```

12. Before finishing, verify:

    - Every new definition output is consumed by its intended initiative or assignment.
    - Every initiative member receives all required parameter mappings.
    - Every `roleDefinitionIds` entry is matched by deployed RBAC.
    - Conditional definitions, initiatives, assignments, and RBAC use the same feature condition.
    - Generated JSON changes are expected and `git diff --check` passes.
    - The shared `AUTHORING.md` and affected consumer documentation remain accurate.

Do not deploy policy resources as a separate repository-level stack. They are an internal stage of
the automated host-pool dependency graph.