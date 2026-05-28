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

Repo-provided artifact packages stay in `.common/artifacts/`. Put customer-specific packages or
customer overrides in `customer/artifacts/`. `deployments/Update-ImageArtifacts.ps1` stages both
locations together, with `customer/artifacts/` overlaying matching files or folders from
`.common/artifacts/`.

## Updating the Repo

Use robocopy to pull the latest code from the source share while preserving this folder:

```cmd
robocopy \\source\FederalAVD C:\FederalAVD /mir /xd customer
```

The `/xd customer` flag excludes this folder from the mirror operation, so your parameter files
and custom artifact packages are never deleted or overwritten by a repo update.
