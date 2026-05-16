# Customer Parameter Files

This folder is for your organization's parameter files. It is intentionally excluded from
repo updates so your files are never overwritten.

## Folder Structure

Mirror the `deployments/` structure for whichever deployments you use:

```
customer/
  hostpools/
    parameters/
      prod-pooled.hostpool.parameters.json
      dev-pooled.hostpool.parameters.json
  imageBuild/
    parameters/
      win11-m365.imageBuild.parameters.json
  imageManagement/
    parameters/
      prod.imageManagement.parameters.json
  keyVaults/
    parameters/
      prod.keyVaults.parameters.json
  networking/
    parameters/
      prod.networking.parameters.json
```

Sample files to use as starting points are in each deployment's `parameters/` folder:

- `deployments/hostpools/parameters/`
- `deployments/imageBuild/parameters/`
- `deployments/imageManagement/parameters/`

## Updating the Repo

Use robocopy to pull the latest code from the source share while preserving this folder:

```cmd
robocopy \\source\FederalAVD C:\FederalAVD /mir /xd customer
```

The `/xd customer` flag excludes this folder from the mirror operation, so your parameter
files are never deleted or overwritten by a repo update.
