---
name: federalavd-air-gapped-readiness
description: "Review FederalAVD deployments and image artifacts for Azure Government Secret or Top Secret air-gapped readiness. Use when auditing downloads.json, finding public network dependencies, preparing transfer inventories, validating pre-staged files, or checking that image builds and host pools avoid internet runtime downloads."
argument-hint: "[parameter file, artifact folder, or deployment component]"
---

# FederalAVD Air-Gapped Readiness

Use this workflow for Azure Government Secret and Top Secret deployment reviews.

## Procedure

1. Read `docs/air-gapped-clouds.md`, then identify the target cloud and whether the management
   workstation itself has access to approved software distribution endpoints.
2. Identify every build-time and runtime network dependency in the requested deployment path.
   Include scripts, extensions, agents, policy templates, installers, package managers, and APIs.
3. Review the cloud-selected base downloads manifest and the customer overlay separately. Customer
   entries override base entries with the same name.
4. Treat `WingetId` as incompatible with air-gapped download execution. Replace it with an approved
   internal `DownloadUrl` or manually pre-stage the complete package layout.
5. For `DownloadUrl`, `APIUrl`, `WebSiteUrl`, and `GitHubRepo`, determine whether the endpoint is
   reachable from the management system. If not, record the exact source, output filename, artifact
   folder, transfer step, and internal hosting location.
6. Run the bundled inventory helper:

   ```powershell
   & .github/skills/federalavd-air-gapped-readiness/scripts/Test-AirGappedDownloads.ps1 `
     -DownloadsPath customer/parameters/imageManagement/downloads.json `
     -ArtifactsRoot customer/artifacts `
     -FailOnIncompatible
   ```

7. Verify image-build parameters disable downloading latest Microsoft content and point required
   content at the artifacts storage account.
8. Verify host-pool agent and boot-loader sources are valid for the target cloud or internally hosted.
9. Confirm Blue Button is not proposed for Secret or Top Secret. Use Template Specs or PowerShell.
10. Produce a transfer manifest grouped into automatically reachable, internally hosted, manually
    staged, and unresolved items. Do not claim readiness while unresolved items remain.
11. Update `docs/air-gapped-clouds.md` and the artifact README when a reusable dependency or staging
    procedure changes.

Use the [review checklist](./references/review-checklist.md) for the final assessment.
