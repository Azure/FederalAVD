---
name: federalavd-artifact-authoring
description: "Create, update, and validate FederalAVD image artifacts and software download definitions. Use when adding customer-example artifacts, editing downloads.json, packaging installers, documenting download sources, or preparing artifacts for connected or air-gapped image builds."
argument-hint: "[artifact folder or software name]"
---

# FederalAVD Artifact Authoring

Use this workflow for content under `customer-examples/artifacts/` and entries in
`customer-examples/parameters/imageManagement/downloads.json`.

## Procedure

1. Read `docs/artifacts-guide.md` and `docs/update-image-artifacts.md`.
2. Inspect a neighboring artifact that uses the same installer or package type.
3. Keep customer-specific content out of the example. Tell users to copy examples into the
   git-ignored `customer/artifacts/` folder before customization.
4. Select the source supported by `deployments/Update-ImageArtifacts.ps1`:
   `DownloadUrl`, `APIUrl`, `GitHubRepo`, or `WingetId`.
5. Make `DestinationFileName` match the filename consumed by the installation script.
6. Set every `DestinationFolders` value to the exact artifact folder name. An empty destination
   is allowed only when the package is intentionally copied to the artifact root.
7. Document the authoritative source, exact connected download command, `-OutFile` filename,
   expected folder, and offline transfer procedure in the artifact README.
8. For public endpoints or runtime downloads, review `docs/air-gapped-clouds.md` and document
   the pre-staging alternative. Do not use `WingetId` as an air-gapped strategy.
9. Keep every `.ps1` file ASCII-only.
10. Run the bundled validator from the repository root:

   ```powershell
   & .github/skills/federalavd-artifact-authoring/scripts/Test-ArtifactPackage.ps1 `
     -ArtifactPath customer-examples/artifacts/<ArtifactFolder>
   ```

11. Run the narrowest behavior test available for the changed installer or packaging path.
12. Report source URLs that could not be verified and files that must be manually staged.

See the [review checklist](./references/review-checklist.md) before completing the change.
