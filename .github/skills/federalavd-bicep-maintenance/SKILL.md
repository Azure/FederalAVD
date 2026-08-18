---
name: federalavd-bicep-maintenance
description: "Modify and validate FederalAVD Bicep templates, generated ARM JSON, parameters, and uiFormDefinition files. Use when changing deployment resources, adding parameters or outputs, synchronizing Bicep with JSON, publishing Template Specs, or debugging portal form behavior."
argument-hint: "[deployment folder or Bicep file]"
---

# FederalAVD Bicep Maintenance

Use this workflow for templates under `deployments/` and `policy/bicep/`.

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
6. When a same-name `.json` exists beside the entry Bicep, regenerate it and run:

   ```powershell
   & .github/skills/federalavd-bicep-maintenance/scripts/Test-BicepArmSync.ps1 `
     -BicepPath deployments/<component>/<component>.bicep
   ```

7. When adding or changing a user-facing parameter, review the sibling `uiFormDefinition.json`,
   example parameter files, `docs/parameters.md`, and deployment documentation.
8. Validate UI forms against the current Microsoft schema and Form View documentation. Dropdown
   `defaultValue` must match the option label, not its submitted value.
9. Review cross-solution dependencies before changing files under `deployments/`.
10. Run the narrowest deployment validation available, then inspect the focused diff for generated
    changes that are larger than expected.

See [UI form rules](./references/ui-form-rules.md) for repository-specific failure modes.
