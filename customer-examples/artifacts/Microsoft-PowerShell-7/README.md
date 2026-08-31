# Deploy PowerShell 7

The lifecycle script installs the only root-level `.msi` file in the package. The filename in
`downloads.json` is a stable staging name, not a script dependency; zero or multiple MSI files
stop installation.

This artifact installs or removes the PowerShell 7 x64 MSI. Copy it to
`customer/artifacts/Microsoft-PowerShell-7` before packaging.

```powershell
.\Deploy-PowerShell7.ps1 -DeploymentType Install
.\Deploy-PowerShell7.ps1 -DeploymentType Uninstall
```

Install is the default. Removal finds a `PowerShell 7*` MSI published by Microsoft in either native
HKLM uninstall hive and runs `msiexec.exe /x <ProductCode> /qn /norestart`. Absence is success;
multiple matches stop removal so side-by-side major versions are not removed arbitrarily.

The `PowerShell7` downloads entry retrieves the latest `*win-x64.msi` release asset from
`PowerShell/PowerShell` and stages it as `PowerShell7.msi`. For offline packaging, download that
asset on a connected system, transfer it through the approved process, and place it in this folder
with that filename before running `Update-ImageArtifacts.ps1 -SkipDownloadingNewSources`.
