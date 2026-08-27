---
name: federalavd-ui-form-maintenance
description: "Create, modify, review, and validate FederalAVD uiFormDefinition.json files and Azure Portal Form View behavior. Use when changing form elements, visibility, constraints, EditableGrid columns, defaults, expressions, API controls, or output-to-Bicep parameter mappings."
argument-hint: "[uiFormDefinition.json or form behavior]"
---

# FederalAVD UI Form Maintenance

Use this workflow for `uiFormDefinition.json` files under `deployments/`. Read the current Microsoft
Form View documentation and the element-specific reference before changing a control.

For Bicep parameters, generated ARM JSON, resource definitions, or template synchronization, also
use the `federalavd-bicep-maintenance` skill.

## Procedure

1. Start from the affected form control and its corresponding output under
   `view.outputs.parameters`. Trace that output to the entry Bicep parameter before editing.
2. Read the current Microsoft reference for the exact element type. Start with the
   [Form View overview](https://learn.microsoft.com/azure/azure-resource-manager/templates/form-view-overview)
   and use the element reference linked from that documentation.
3. Validate the form against
   `https://schema.management.azure.com/schemas/2021-09-09/uiFormDefinition.schema.json`.
4. Preserve the established step, section, visibility, and naming structure. Make the smallest
   change that corrects the behavior.
5. Keep every form output aligned with an entry-template parameter name and compatible type. Remove
   stale outputs when their parameters are removed.
6. For dropdowns, set `defaultValue` to the display label rather than the submitted value.
7. For `Microsoft.Common.EditableGrid`:
   - Use only supported column controls: `TextBox`, `OptionsGroup`, and `DropDown`.
   - Use `$rowIndex` only in supported child expressions. Read the current row with
     `last(take(<grid-reference>, $rowIndex))`.
   - Do not rely on column `defaultValue` to populate a newly added row. Use placeholders for
     guidance and normalize intentionally omitted values in Bicep when the field is conditional.
   - Keep the grid column IDs aligned with every property expected by the Bicep input object.
8. Prefer literal `TextBlock.options.text`. For conditional explanatory text, use separate blocks
   with visibility conditions instead of a complex expression-valued string.
9. Keep dependent API controls, transforms, visibility expressions, and defaults gated together so
   asynchronous values do not evaluate before their dependencies exist.
10. After editing, run the narrowest available checks:
    - Parse the JSON.
    - Check schema and editor diagnostics.
    - Verify every output maps to an ARM/Bicep parameter.
    - Verify grid column IDs match the corresponding typed input object.
    - Run `git diff --check` on the changed form.
11. Run a live Azure Portal render smoke test through the affected step when an authenticated portal
    session is available. If authentication prevents the test, report that limitation explicitly;
    JSON and schema validation do not prove runtime rendering behavior.

See [UI form rules](./references/ui-form-rules.md) for repository-specific failure modes.

## Completion Checklist

- The form parses as JSON.
- Element properties match the current Microsoft reference.
- Dropdown defaults use labels.
- Conditional fields have correct visibility and requiredness.
- Editable Grid rows do not depend on unsupported defaults.
- All outputs map to entry-template parameters with compatible types.
- Related Bicep and generated ARM templates are synchronized when their contract changed.
- Portal rendering was tested or the authentication limitation was documented.