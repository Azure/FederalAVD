# customer/parameters

Place your environment-specific deployment parameter files here. Each subfolder corresponds to
one deployment template.

> **Git note:** Only `README.md` and `.gitkeep` files in this tree are tracked by git.
> Parameter files are intentionally excluded to avoid committing environment-specific values
> (subscription IDs, resource group names, storage account names, etc.). See `customer/README.md`
> for details.

## Subfolder map

| Subfolder | Deployment template | Sample parameters location |
|-----------|--------------------|-----------------------------|
| `hostpools/` | `deployments/hostpools/hostpool.bicep` | `deployments/hostpools/parameters/` |
| `imageBuild/` | `deployments/imageBuild/imageBuild.bicep` | `deployments/imageBuild/parameters/` |
| `imageManagement/` | `deployments/imageManagement/imageManagement.bicep` | `deployments/imageManagement/parameters/` |
| `keyVaults/` | `deployments/keyVaults/keyVaults.bicep` | (no samples; use template defaults as a guide) |
| `networking/` | `deployments/networking/networking.bicep` | `deployments/networking/parameters/` |

## Getting started

Copy a sample parameter file into the matching subfolder and edit it for your environment:

```powershell
# Image management (storage account, compute gallery, managed identity)
Copy-Item -Path "deployments\imageManagement\parameters\sample.imageManagement.parameters.json" `
          -Destination "customer\parameters\imageManagement\prod.imageManagement.parameters.json"

# Image build
Copy-Item -Path "deployments\imageBuild\parameters\sample.imageBuild.parameters.json" `
          -Destination "customer\parameters\imageBuild\win11-25h2.imageBuild.parameters.json"

# Host pool
Copy-Item -Path "deployments\hostpools\parameters\sample.hostpool.parameters.json" `
          -Destination "customer\parameters\hostpools\prod-pooled.hostpool.parameters.json"

# Networking
Copy-Item -Path "deployments\networking\parameters\sample.networking.parameters.json" `
          -Destination "customer\parameters\networking\prod.networking.parameters.json"
```

## Optional downloads file

`imageManagement/downloads.json` merges additional software downloads on top of the
auto-detected base downloads file when you run `Update-ImageArtifacts.ps1`. A ready-to-use
example covering common packages (Chrome, FSLogix, LGPO, built-in UWP apps, codec extensions,
and more) is at `customer-examples/parameters/imageManagement/downloads.json`:

```powershell
Copy-Item -Path "customer-examples\parameters\imageManagement\downloads.json" `
          -Destination "customer\parameters\imageManagement\" -Force
```

Remove or comment out entries you do not need before running the script.

## Further reading

- [Parameters Reference](../../docs/parameters.md)
- [Quick Start](../../docs/quick-start.md)
- [Update-ImageArtifacts.ps1 Script Guide](../../docs/update-image-artifacts.md)
