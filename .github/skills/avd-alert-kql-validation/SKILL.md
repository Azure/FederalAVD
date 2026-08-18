---
name: avd-alert-kql-validation
description: "Create and review KQL for the FederalAVD AVD Alerts add-on. Use when adding or changing scheduled query alerts, comparing alert logic with Microsoft AVD Insights workbooks, investigating query failures, or documenting intentional workbook deviations."
argument-hint: "[alert resource, KQL condition, or module]"
---

# AVD Alert KQL Validation

Use this workflow for log-based alerts under `deployments/add-ons/avdAlerts/`.

## Procedure

1. Read `deployments/add-ons/avdAlerts/README.md`, especially **Query Design and Validation**, and
   locate the corresponding operator response in `ALERT-RESPONSE.md`.
2. Identify the authoritative AVD Insights workbook for the condition. Use the official Microsoft
   workbook sources listed in [workbook sources](./references/workbook-sources.md).
3. Extract and structurally validate the repository queries:

   ```powershell
   & .github/skills/avd-alert-kql-validation/scripts/Test-AvdAlertQueries.ps1 `
     -ModulePath deployments/add-ons/avdAlerts/modules
   ```

4. To inspect standalone KQL, add `-OutputDirectory <temporary-folder>`. Do not commit generated
   extraction output.
5. Compare table selection, joins, event names or IDs, status filters, casts, deduplication, and
   aggregation with the workbook query covering the same condition.
6. Adapt interactive workbook queries for alert semantics: remove `render`, return rows suitable for
   the configured aggregation and threshold, and use a bounded time window.
7. Verify `overrideQueryTimeRange` is at least `windowSize` multiplied by
   `numberOfEvaluationPeriods` and that persistent-event behavior matches `autoMitigate`.
8. Preserve cloud compatibility. Do not introduce workspace-specific functions or preview-only KQL
   without confirming support in every target cloud.
9. Document every intentional deviation in the add-on README. The reason must describe alert
   semantics, noise suppression, cloud compatibility, or source-data behavior.
10. Build the affected Bicep entry template and update `ALERT-RESPONSE.md` when operator action,
    thresholds, or dimensions change.
