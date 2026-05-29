# Customer Content

This folder is for your organization's deployment parameter files and custom artifact packages.
It is intentionally excluded from repo updates so your files are never overwritten.

## Folder Structure

Store customer-owned content under the `parameters/` and `artifacts/` subfolders:

```text
customer/
  parameters/
    hostpools/
      prod-pooled.hostpool.parameters.json
      dev-pooled.hostpool.parameters.json
    imageBuild/
      win11-m365.imageBuild.parameters.json
    imageManagement/
      prod.imageManagement.parameters.json
    keyVaults/
      prod.keyVaults.parameters.json
    networking/
      prod.networking.parameters.json
  artifacts/
    Chrome/
      Install-Chrome.ps1
      GoogleChromeEnterpriseBundle64.msi
```

Sample files to use as starting points are in each deployment's `parameters/` folder. Copy them
into the matching child folder under `customer/parameters/` before customizing them:

- `deployments/hostpools/parameters/`
- `deployments/imageBuild/parameters/`
- `deployments/imageManagement/parameters/`
- `deployments/keyVaults/parameters/`
- `deployments/networking/parameters/`

Put your artifact packages in `customer/artifacts/`. `deployments/Update-ImageArtifacts.ps1`
stages `.common/artifacts/` first (currently empty, reserved for future repo-provided packages)
then overlays `customer/artifacts/` on top — your files always win when names match.

## Examples

Ready-to-use example artifact packages and an optional downloads file are provided under
`customer/examples/`. These are not used automatically — copy what you need into the matching
`customer/` subfolders and remove or modify entries you don't want.

```text
customer/examples/
  artifacts/                                ← copy folders into customer/artifacts/
    Adobe-Acrobat-Reader-DC/
    Amazon-Workspaces-Client/
    Configure-DesktopBackground/
    Configure-EdgePolicy/
    Configure-Office365Policy/
    Configure-OneDriveKFMPolicy/
    Configure-RemoteDesktopPolicy/
    Configure-WindowsUpdatePolicy/
    DoD-InstallRoot/
    DoD-STIGs/
    Git-for-Windows/
    Google-Chrome-Enterprise/
    LGPO/
    Microsoft-AzCLI/
    Microsoft-FSLogix/
    Microsoft-Power-BI-Desktop/
    Microsoft-PowerShell-7/
    Microsoft-VSCode/
    Notepad-PlusPlus/
    PuTTY/
  parameters/
    imageManagement/
      downloads.json                        ← copy to customer/parameters/imageManagement/downloads.json
```

**Copying examples to your customer folder:**

```powershell
# Copy a specific artifact package
Copy-Item -Recurse -Path "customer\examples\artifacts\Google-Chrome-Enterprise" `
          -Destination "customer\artifacts\"

# Copy all example artifact packages at once
Copy-Item -Recurse -Path "customer\examples\artifacts\*" -Destination "customer\artifacts\"

# Copy the optional downloads file
Copy-Item -Path "customer\examples\parameters\imageManagement\downloads.json" `
          -Destination "customer\parameters\imageManagement\" -Force
```

Each artifact folder in `customer/examples/artifacts/` pairs with an entry in
`customer/examples/parameters/imageManagement/downloads.json` — the `DestinationFolders` field
in each download entry names the artifact folder the downloaded installer is placed into before
the script zips and uploads it.

If you keep customer content outside the extracted repo zip, pass `-CustomerRootPath` to
`Update-ImageArtifacts.ps1`, `Deploy-ImageManagement.ps1`, or `Invoke-ImageBuilds.ps1` so they
read from your external customer folder instead of the repo-local `customer/` tree.

## Updating the Repo

Use robocopy to pull the latest code from the source share while preserving this folder:

```cmd
robocopy \\source\FederalAVD C:\FederalAVD /mir /xd customer
```

The `/xd customer` flag excludes this folder from the mirror operation, so your parameter files
and custom artifact packages are never deleted or overwritten by a repo update.
