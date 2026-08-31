# Deploy Visual Studio Code

The lifecycle script installs the only root-level `.exe` file in the package. The filename in
`downloads.json` is a stable staging name, not a script dependency; zero or multiple EXE files
stop installation.

This artifact installs or removes the machine-wide Visual Studio Code x64 system installer.

```powershell
.\Deploy-VSCode.ps1 -DeploymentType Install
.\Deploy-VSCode.ps1 -DeploymentType Uninstall
```

Install is the default and requires exactly one staged EXE. The lifecycle script never downloads
software at runtime. It installs with `/VERYSILENT /NORESTART /MERGETASKS=!runcode` and removes the
application with `%ProgramFiles%\Microsoft VS Code\unins000.exe /VERYSILENT /NORESTART`. A missing
uninstaller is treated as success.

When `DisableUpdates` is enabled during installation, the script sets the machine policy
`HKLM:\SOFTWARE\Policies\Microsoft\VSCode\UpdateMode` to `none`. Uninstall leaves that policy value
in place because it may be managed outside this artifact.

## Packaging

The `VSCode` downloads entry retrieves the official stable x64 system installer and stages it as
`VSCodesetup.exe`. For offline packaging, download
`https://code.visualstudio.com/sha/download?build=stable&os=win32-x64`, transfer it through the
approved process, and stage it with that filename before running:

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
  -StorageAccountResourceId '<artifactsStorageAccountResourceId>' `
  -SkipDownloadingNewSources
```
