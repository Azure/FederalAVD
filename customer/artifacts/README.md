# customer/artifacts

Place your custom artifact packages here. Each subfolder becomes a single `.zip` file that
`Update-ImageArtifacts.ps1` uploads to the artifacts blob container for use during image builds
and session host deployments.

> **Git note:** Only `README.md` and `.gitkeep` files in this tree are tracked by git.
> Artifact folders, scripts, and installers are intentionally excluded to avoid committing
> environment-specific or large binary files. See `customer/README.md` for details.

## What goes here

Each subfolder should contain:

- A PowerShell script named `Install-<AppName>.ps1` (the entry point executed by `Invoke-Customization.ps1`)
- The application installer or supporting files required by the script (optional — omit if the script downloads them at runtime)

```text
customer/artifacts/
    Google-Chrome-Enterprise/
        Install-Chrome.ps1
        GoogleChromeEnterpriseBundle64.msi
    Microsoft-FSLogix/
        Install-FSLogix.ps1
        FSLogix.zip                         <- placed here when air-gapped; downloaded automatically otherwise
    BuiltIn-UWP-Apps/
        Install-BuiltinUwpApps.ps1
        Calculator\                         <- populated by Update-ImageArtifacts.ps1 via winget
        ...
        SharedDependencies\                 <- created by Update-ImageArtifacts.ps1 (dedup pool)
```

## How Update-ImageArtifacts.ps1 uses this folder

1. Stages `.common/artifacts/` as the base layer (reserved for repo-provided packages; currently empty)
2. Overlays `customer/artifacts/` on top — your files always win when names match
3. Compresses each subfolder into a `.zip` file (e.g., `Google-Chrome-Enterprise/` -> `Google-Chrome-Enterprise.zip`)
4. Uploads all zips to the `artifacts` blob container in the image management storage account

Root-level files (not in a subfolder) are uploaded as-is, without compression.

## Ready-to-use examples

`customer-examples/artifacts/` contains example packages for common software. Copy any folder
directly into this directory:

```powershell
# Copy a specific example
Copy-Item -Recurse -Path "customer-examples\artifacts\Google-Chrome-Enterprise" `
          -Destination "customer\artifacts\"

# Copy all examples at once
Copy-Item -Recurse -Path "customer-examples\artifacts\*" -Destination "customer\artifacts\"
```

Each example pairs with a matching entry in `customer-examples/parameters/imageManagement/downloads.json`.

## Further reading

- [Artifacts and Image Management Guide](../../docs/artifacts-guide.md)
- [Update-ImageArtifacts.ps1 Script Guide](../../docs/update-image-artifacts.md)
