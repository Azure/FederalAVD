# Deploy Microsoft Azure CLI

The lifecycle script installs the only root-level `.msi` file in the package. The filename in
`downloads.json` is a stable staging name, not a script dependency; zero or multiple MSI files
stop installation.

This artifact installs or removes the Microsoft Azure CLI x64 MSI.

```powershell
.\Deploy-AzCLI.ps1 -DeploymentType Install
.\Deploy-AzCLI.ps1 -DeploymentType Uninstall
```

Install is the default. It removes an existing Azure CLI MSI before installing the staged MSI
with `msiexec`. Explicit removal discovers the registered Microsoft Azure CLI
ProductCode and runs `msiexec /x`; absence is success. The lifecycle script never downloads
software at runtime.

The `AzCli` downloads entry retrieves the official x64 MSI from
`https://aka.ms/installazurecliwindowsx64` and stages it as `azclix64.msi`. For offline packaging,
download that MSI on a connected system, transfer it through the approved process, and stage it
with the same filename before running:

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
  -StorageAccountResourceId '<artifactsStorageAccountResourceId>' `
  -SkipDownloadingNewSources
```
