---
name: federalavd-deployment-dependency-review
description: "Validate FederalAVD deployment sequencing and output-to-input dependencies across Networking, AVD Shared Services, Image Management, Image Build, Host Pool, and add-ons. Use when planning deployment order, wiring deployment outputs into parameter files, reusing shared resources, or diagnosing missing resource IDs."
argument-hint: "[scenario and parameter files]"
---

# FederalAVD Deployment Dependency Review

## Procedure

1. Read `docs/automation-guide.md` and identify the requested scenario: marketplace or custom
   image, CMK or platform keys, shared monitoring, existing networking, and applicable add-ons.
2. Reduce the plan to only required steps:
   Networking -> AVD Shared Services -> Image Management -> Image Build -> Host Pool.
   Optional steps may be skipped only when their outputs are not consumed downstream.
3. For CMK, deploy AVD Shared Services before Image Management or Host Pool and grant the
   deploying identity the documented Key Vault data-plane role.
4. Record each required output with its producing deployment, consuming parameter, and whether an
   empty conditional output is valid. Use [dependency map](./references/dependency-map.md).
5. Run deterministic checks across the parameter files available for the scenario:

   ```powershell
   & .github/skills/federalavd-deployment-dependency-review/scripts/Test-DeploymentDependencies.ps1 `
     -ParameterPath <image-management-parameters>,<image-build-parameters>,<host-pool-parameters>
   ```

6. Resolve conflicting values across files before deployment. Resource IDs must reference the
   intended subscription, resource group, cloud, and region where applicable.
7. Confirm artifacts are uploaded after Image Management and before Image Build whenever the build
   consumes artifact blob names.
8. Confirm the Image Build output `customImageResourceId` is supplied to Host Pool only for custom
   image deployment. Image refresh replaces session hosts; it does not require host-pool redeployment.
9. For policy-governed subscriptions, determine whether monitoring must be deployed first to satisfy
   diagnostic-settings policy assignments.
10. Return exactly one ordered deployment plan plus an output-to-input table and unresolved blockers.
