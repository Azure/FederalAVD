# Deploy PuTTY

The lifecycle script installs the only root-level `.msi` file in the package. The filename in
`downloads.json` is a stable staging name, not a script dependency; zero or multiple MSI files
stop installation.

This artifact installs or removes the PuTTY x64 MSI. Copy it to `customer/artifacts/PuTTY` before
packaging.

```powershell
.\Deploy-PuTTY.ps1 -DeploymentType Install
.\Deploy-PuTTY.ps1 -DeploymentType Uninstall
```

Install is the default. Removal finds a `PuTTY release *` MSI published by Simon Tatham in either
native HKLM uninstall hive and runs `msiexec.exe /x <ProductCode> /qn /norestart`. Absence is
success; multiple matches stop removal.

The `PuTTY` downloads entry uses winget package `PuTTY.PuTTY` and stages the payload as
`PuTTY.msi`. For offline packaging, download the x64 MSI on a connected system, transfer it through
the approved process, and place it in this folder with that filename before running
`Update-ImageArtifacts.ps1 -SkipDownloadingNewSources`.
