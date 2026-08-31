# Deploy Amazon WorkSpaces Client

The lifecycle script installs the only root-level `.msi` file in the package. The filename in
`downloads.json` is a stable staging name, not a script dependency; zero or multiple MSI files
stop installation.

This artifact installs or removes the Amazon WorkSpaces Client machine-wide MSI. Copy it to
`customer/artifacts/Amazon-Workspaces-Client` before packaging.

```powershell
.\Deploy-AmazonWorkspacesClient.ps1 -DeploymentType Install
.\Deploy-AmazonWorkspacesClient.ps1 -DeploymentType Uninstall
```

Install is the default and uses `ALLUSERS=1`. Removal finds an `Amazon WorkSpaces*` MSI published
by Amazon Web Services in either native HKLM uninstall hive and runs
`msiexec.exe /x <ProductCode> /qn /norestart`. Absence is success; multiple matches stop removal.

When `DisableUpdates` is enabled during installation, the script sets `clientUpgradeDisabled`.
Uninstall leaves that policy value in place because it may be managed outside this artifact.

The `AmazonWorkSpacesClient` downloads entry uses winget package `Amazon.WorkSpacesClient` and
stages its WiX MSI as `Amazon-WorkSpacesClient.msi`. For offline packaging, download that MSI on a
connected system, transfer it through the approved process, and stage it with the same filename
before running `Update-ImageArtifacts.ps1 -SkipDownloadingNewSources`.
