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
3. For Image Management CMK, deploy AVD Shared Services first so the encryption Key Vault exists
   before artifact/build-log storage CMK or gallery image-version DES creation. A standard Host
   Pool can instead create its own Key Vault and CMK resources inline. Grant the deploying identity
   the documented Key Vault data-plane role in either path.
4. Determine the FSLogix storage ownership model. A standard Host Pool can deploy storage dedicated
   to that pool or consume existing storage. For storage shared across host pools, deploy the
   FSLogix Storage add-on before the consuming pools. The add-on only consumes existing encryption
   Key Vault, Log Analytics workspace, and backup vault/policy resources; deploy AVD Shared Services
   first only when those capabilities are selected and approved existing resource IDs are not
   already available.
5. For multiple standard host pools, allow the first Host Pool deployment to create shared Key
   Vaults, monitoring, and FSLogix backup resources for later pools to select as existing resources.
   Do not require AVD Shared Services unless a consumer needs those resources before the first host
   pool is deployed.
6. Record each required output with its producing deployment, consuming parameter, and whether an
   empty conditional output is valid. Use [dependency map](./references/dependency-map.md).
7. Run deterministic checks across the parameter files available for the scenario:

   ```powershell
   & .github/skills/federalavd-deployment-dependency-review/scripts/Test-DeploymentDependencies.ps1 `
     -ParameterPath <image-management-parameters>,<image-build-parameters>,<host-pool-parameters>
   ```

8. Resolve conflicting values across files before deployment. Resource IDs must reference the
   intended subscription, resource group, cloud, and region where applicable.
9. Confirm artifacts are uploaded after Image Management and before any Image Build or session-host
   runtime customization that consumes artifact blob names. Image Management may be used for
   artifact hosting without running Image Build.
10. Confirm the Image Build output `customImageResourceId` is supplied to Host Pool only for custom
   image deployment. Image refresh replaces session hosts; it does not require host-pool redeployment.
11. For policy-governed subscriptions, determine whether monitoring must be deployed first to satisfy
   diagnostic-settings policy assignments.
12. Return exactly one ordered deployment plan plus an output-to-input table and unresolved blockers.
