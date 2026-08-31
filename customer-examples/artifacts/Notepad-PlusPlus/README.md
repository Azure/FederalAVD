# Deploy Notepad++

The lifecycle script installs the only root-level `.exe` file in the package. The filename in
`downloads.json` is a stable staging name, not a script dependency; zero or multiple EXE files
stop installation.

This artifact installs or removes the 64-bit Notepad++ application.

```powershell
.\Deploy-NotepadPlusPlus.ps1 -DeploymentType Install
.\Deploy-NotepadPlusPlus.ps1 -DeploymentType Uninstall
```

Install is the default and runs the staged EXE with `/S /noUpdater`. Removal runs
the installed `%ProgramFiles%\Notepad++\uninstall.exe` with `/S`; a missing uninstaller is success.

The `NotepadPlusPlus` downloads entry retrieves the latest `*x64.exe` GitHub release asset and
stages it as `NotepadPlusPlus.exe`. For offline packaging, transfer that asset through the approved
process and stage it with the same filename before running
`Update-ImageArtifacts.ps1 -SkipDownloadingNewSources`.
