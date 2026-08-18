# UI Form Rules

- Review the current Form View documentation and schema before editing a form.
- The schema is `https://schema.management.azure.com/schemas/2021-09-09/uiFormDefinition.schema.json`.
- The top-level key is `view`; deployment parameters are under `view.outputs.parameters`.
- A dropdown `defaultValue` matches its label, not its submitted value.
- Keep dependent publisher, offer, SKU API, transform, and default expressions gated together.
- In an `EditableGrid`, use `$rowIndex` only in expression locations where the portal supports it.
- Avoid wrapping asynchronous API-control values in `coalesce(..., [])` when that prevents later
  population.
- Ensure `outputs` is in the schema-defined location; misplaced outputs can evaluate as blank
  without an obvious rendering error.
- Validate every form output against the Bicep parameter name and expected type.
