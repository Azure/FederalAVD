# Shared Deployment Assets

This directory contains implementation assets consumed by multiple deployment solutions.

## Layout

- `modules/` contains reusable Bicep resource and solution-composition modules.
- `scripts/` contains PowerShell scripts embedded by Bicep templates with `loadTextContent()`.

Monitoring deployment composition is centralized in
`modules/orchestration/monitoring/monitoring.bicep` and consumed by both the standard host pool
and Shared Services deployments.

Assets used by only one add-on remain under that add-on. Interactive scripts intended for an
operator to run directly belong under `tools/`, not under `deployments/shared/`.

When changing a shared Bicep module or embedded script, rebuild every affected checked-in ARM JSON
template and run the repository Bicep-to-ARM synchronization checks.