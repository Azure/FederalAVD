# Deploy 7-Zip

The lifecycle script installs the only root-level `.msi` file in the package. The filename in
`downloads.json` is a stable staging name, not a script dependency; zero or multiple MSI files
stop installation.

This artifact installs or removes the 64-bit edition of 7-Zip. Copy this folder to
`customer/artifacts/7-Zip` before packaging it with `Update-ImageArtifacts.ps1`.

## Lifecycle Commands

Install is the default so existing image-build and session-host customizations remain compatible:

```powershell
.\Deploy-7-Zip.ps1
.\Deploy-7-Zip.ps1 -DeploymentType Install
```

Remove 7-Zip with the same artifact entry script:

```powershell
.\Deploy-7-Zip.ps1 -DeploymentType Uninstall
```

Removal finds the 64-bit 7-Zip MSI ProductCode under the native HKLM uninstall registry hive and
runs `msiexec.exe /x <ProductCode> /quiet /qn /norestart`. It waits for completion, accepts exit
codes `0` and `3010`, and treats an application that is not installed as success.

## Connected Packaging

The `7Zip` entry in
`customer-examples/parameters/imageManagement/downloads.json` retrieves the latest x64 MSI from the
[official 7-Zip GitHub releases](https://github.com/ip7z/7zip/releases) and stages it as
`7zip-x64.msi` in this folder.

After copying this folder and the downloads manifest into `customer/`, run:

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
  -StorageAccountResourceId '<artifactsStorageAccountResourceId>'
```

## Offline Packaging

Download the 64-bit MSI from the
[official 7-Zip download page](https://www.7-zip.org/download.html) on a connected system, transfer
it through the approved process, and place it in `customer/artifacts/7-Zip` as `7zip-x64.msi`.

Package the pre-staged file without downloading a replacement:

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
  -StorageAccountResourceId '<artifactsStorageAccountResourceId>' `
  -SkipDownloadingNewSources
```

The artifact supports the MSI package supplied by the `7Zip` downloads manifest entry.
