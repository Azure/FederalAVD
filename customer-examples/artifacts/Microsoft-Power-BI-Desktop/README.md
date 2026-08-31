# Deploy Microsoft Power BI Desktop

The lifecycle script installs the only root-level `.exe` file in the package. The filename in
`downloads.json` is a stable staging name, not a script dependency; zero or multiple EXE files
stop installation.

This artifact installs or removes Microsoft Power BI Desktop x64.

```powershell
.\Deploy-PowerBIDesktop.ps1 -DeploymentType Install
.\Deploy-PowerBIDesktop.ps1 -DeploymentType Uninstall
```

Install is the default and runs the staged EXE silently. Removal finds a
Microsoft-published `Microsoft Power BI Desktop*` machine uninstall registration and invokes its
registered `QuietUninstallString` directly. Absence is success; missing quiet metadata, missing
cached uninstallers, or multiple matches stop removal.

The `PowerBIDesktop` downloads entry uses winget package `Microsoft.PowerBI` and stages the payload
as `PowerBIDesktop64.exe`. For offline packaging, transfer that installer through the approved
process and stage it with the same filename before running
`Update-ImageArtifacts.ps1 -SkipDownloadingNewSources`.
