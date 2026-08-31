# Deploy Adobe Acrobat Reader DC

The lifecycle script installs the only root-level `.exe` file in the package. The filename in
`downloads.json` is a stable staging name, not a script dependency; zero or multiple EXE files
stop installation.

This artifact installs or removes the 64-bit Adobe Acrobat Reader DC package. Copy this folder to
`customer/artifacts/Adobe-Acrobat-Reader-DC` before packaging it with
`Update-ImageArtifacts.ps1`.

## Lifecycle Commands

Install is the default so existing image-build and session-host customizations remain compatible:

```powershell
.\Deploy-AdobeReaderDC.ps1
.\Deploy-AdobeReaderDC.ps1 -DeploymentType Install
```

Remove the application with the same artifact entry script:

```powershell
.\Deploy-AdobeReaderDC.ps1 -DeploymentType Uninstall
```

Installation runs the packaged EXE bootstrapper. Adobe's bootstrapper installs
an MSI-backed product, so removal discovers the native HKLM uninstall registration whose publisher
is Adobe and whose ProductCode belongs to Adobe's `AC76BA86` Acrobat family. It then runs
`msiexec.exe /x <ProductCode> /qn /norestart`.

Removal fails when multiple matching registrations exist rather than choosing one arbitrarily. It
treats an application that is not installed as success.

> **Unified application:** Adobe's 64-bit application can provide Reader or paid Acrobat features
> from the same installation based on licensing. Removing this VM Application removes that shared
> installation. Do not use its remove operation on machines where a separately managed Acrobat
> installation must remain.

## Connected Packaging

The `AdobeAcrobatReaderDC` entry in
`customer-examples/parameters/imageManagement/downloads.json` downloads Microsoft Store product
`XPDP273C0XHQH2` with winget and stages it in this folder as `AcrobatRdrDCx64.exe`.

After copying this folder and the downloads manifest into `customer/`, run:

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
  -StorageAccountResourceId '<artifactsStorageAccountResourceId>'
```

## Offline Packaging

On a connected system, download the configured package with winget:

```powershell
winget download `
  --id XPDP273C0XHQH2 `
  --source msstore `
  --accept-package-agreements `
  --accept-source-agreements
```

Transfer the downloaded installer through the approved process and place it in
`customer/artifacts/Adobe-Acrobat-Reader-DC` as `AcrobatRdrDCx64.exe`. Then package the pre-staged
file without downloading a replacement:

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
  -StorageAccountResourceId '<artifactsStorageAccountResourceId>' `
  -SkipDownloadingNewSources
```
