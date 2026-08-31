# Deploy Git for Windows

The lifecycle script installs the only root-level `.exe` file in the package. The filename in
`downloads.json` is a stable staging name, not a script dependency; zero or multiple EXE files
stop installation.

This artifact installs, upgrades, or removes Git for Windows x64.

```powershell
.\Deploy-GitforWindows.ps1 -DeploymentType Install
.\Deploy-GitforWindows.ps1 -DeploymentType Uninstall
```

Install is the default. It first removes an existing machine-wide Git installation, writes the
repository's unattended setup configuration, and installs the staged EXE. Removal runs
`%ProgramFiles%\Git\unins000.exe /VERYSILENT /NORESTART`; a missing uninstaller is success. Upgrade
and explicit removal use the same function, so their behavior cannot drift.

The `GitForWindows` downloads entry retrieves the latest `*64-bit.exe` asset from
`git-for-windows/git` and stages it as `Git-64-bit.exe`. The lifecycle script never downloads
software at runtime. For offline packaging, transfer that release asset through the approved
process and stage it with the same filename before running:

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
  -StorageAccountResourceId '<artifactsStorageAccountResourceId>' `
  -SkipDownloadingNewSources
```
