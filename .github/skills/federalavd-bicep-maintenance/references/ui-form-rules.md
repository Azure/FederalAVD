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
- Incident guardrail (standard host pools): do not use complex expression-valued
  `TextBlock.options.text` for explanatory copy when it requires nested conditionals with quoted
  string branches. In this repo, that pattern caused Azure Portal runtime failure in
  `CustomHtmlField` with `text is not a function` even though JSON and schema validation passed.
- Prefer stable literal text for explanatory blocks. If context-specific wording is required,
  simplify to low-risk visibility toggles across multiple text blocks instead of computing one
  text string expression.
- Required verification after text-binding changes: run a live portal form render test through the
  affected step and confirm the section loads without `CustomHtmlField` errors.

Example - avoid:

```json
"text": "[if(equals(steps('x').y, 'A'), 'Long quoted string A', 'Long quoted string B')]"
```

Example - preferred:

```json
"text": "Default permissions grant Authenticated Users full access. Optionally restrict access to selected groups."
```
