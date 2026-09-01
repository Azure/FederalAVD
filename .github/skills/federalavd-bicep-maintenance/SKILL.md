---
name: federalavd-bicep-maintenance
description: "Modify and validate FederalAVD Bicep templates, generated ARM JSON, and deployment parameters. Use when changing Azure resources, module contracts, parameters or outputs, synchronizing Bicep with ARM JSON, publishing Template Specs, or diagnosing Bicep compilation failures."
argument-hint: "[deployment folder or Bicep file]"
---

# FederalAVD Bicep Maintenance

Use this workflow for templates under `deployments/`, including all session-host policy definitions
and nested templates under `deployments/shared/modules/orchestration/sessionHostPolicy/`.

For automated host-pool policy definitions, initiatives, assignments, nested remediation templates,
or policy RBAC, also use the `federalavd-policy-authoring` skill.

For `uiFormDefinition.json`, Azure Portal controls, Form View expressions, or form output mappings,
also use the `federalavd-ui-form-maintenance` skill.

## Procedure

1. Read the complete entry template and the nearest module that directly controls the behavior.
2. Before editing Bicep, obtain current Bicep best practices and the authoritative resource type
   schema for each resource being changed. Do not rely on old generated ARM JSON as a schema.
3. Trace affected parameters, outputs, module calls, example parameter files, documentation, and
   deployment scripts. Preserve existing public parameter names unless a breaking change is
   explicitly required.
4. Make the smallest source change in `.bicep`. Do not hand-edit generated ARM JSON.
5. Build the changed Bicep immediately and resolve new errors. Known repository warnings must be
   distinguished from warnings introduced by the change.
6. When a same-name `.json` exists beside the entry Bicep, always regenerate the tracked ARM JSON
    with Azure CLI before running the sync test. The sync test only builds a temporary comparison
    file; it does not update the tracked JSON.

    Build generated-template dependencies before the entry points that load them. Known required
    orderings are:

   - `shared/modules/orchestration/sessionHostPolicy/modules/templates/RunCommand/PrivateCustomization.bicep` before
       `automatedHostPools/automatedHostPool.bicep`.
    - `add-ons/sessionHosts/main.bicep` before `add-ons/sessionHostReplacer/main.bicep`.

   ```powershell
    az bicep build `
       --file deployments/<component>/<component>.bicep `
       --outfile deployments/<component>/<component>.json

   & .github/skills/federalavd-bicep-maintenance/scripts/Test-BicepArmSync.ps1 `
     -BicepPath deployments/<component>/<component>.bicep
   ```

7. When adding or changing a user-facing parameter, use the `federalavd-ui-form-maintenance` skill
   to review the sibling `uiFormDefinition.json`. Also review example parameter files,
   `docs/parameters.md`, and deployment documentation.
8. Review cross-solution dependencies before changing files under `deployments/`.
9. Run the narrowest deployment validation available, then inspect the focused diff for generated
    changes that are larger than expected.

See [Secret source alignment notes](./references/secret-source-alignment-notes.md) for the postponed standard-vs-automated credential secret sourcing alignment plan.
See [FSLogix form parity notes](./references/fslogix-form-parity.md) before aligning the standard
host-pool and standalone storage forms.
See [storage application sequencing](./references/storage-application-sequencing.md) before changing
Entra Kerberos, private endpoint, or NTFS permission orchestration.
