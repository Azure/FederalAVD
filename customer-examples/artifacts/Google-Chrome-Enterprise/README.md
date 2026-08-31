# Deploy Google Chrome Enterprise

The lifecycle script installs the only root-level `.msi` file in the package. The filename in
`downloads.json` is a stable staging name, not a script dependency; zero or multiple MSI files
stop installation.

This artifact installs or removes the 64-bit Google Chrome Enterprise MSI. Copy this folder to
`customer/artifacts/Google-Chrome-Enterprise` before packaging it.

## Lifecycle Commands

```powershell
.\Deploy-GoogleChromeEnterprise.ps1 -DeploymentType Install
.\Deploy-GoogleChromeEnterprise.ps1 -DeploymentType Uninstall
```

Install is the default. Removal finds an exact `Google Chrome` MSI registration published by
Google in either native HKLM uninstall hive and runs
`msiexec.exe /x <ProductCode> /qn /norestart`. Absence is success; multiple matches stop removal.

When `DisableUpdates` is enabled during installation, the script configures Google Update policy
values. Uninstall leaves those policy values in place because they may also be managed outside this
artifact.

## Packaging

The `GoogleChromeEnterprise` downloads entry retrieves Google's official x64 enterprise MSI and
stages it as `GoogleChromeEnterprise.msi` in this folder. For offline use, download
`https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi`, transfer it
through the approved process, and stage it with that filename before running:

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
  -StorageAccountResourceId '<artifactsStorageAccountResourceId>' `
  -SkipDownloadingNewSources
```
