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
`customer-examples/`. These are not used automatically — copy what you need into the matching
`customer/` subfolders and remove or modify entries you don't want.

```text
customer-examples/
  artifacts/                                ← copy folders into customer/artifacts/
    Adobe-Acrobat-Reader-DC/
    Amazon-Workspaces-Client/
    BuiltIn-UWP-Apps/
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
Copy-Item -Recurse -Path "customer-examples\artifacts\Google-Chrome-Enterprise" `
          -Destination "customer\artifacts\"

# Copy all example artifact packages at once
Copy-Item -Recurse -Path "customer-examples\artifacts\*" -Destination "customer\artifacts\"

# Copy the optional downloads file
Copy-Item -Path "customer-examples\parameters\imageManagement\downloads.json" `
          -Destination "customer\parameters\imageManagement\" -Force
```

Each artifact folder in `customer-examples/artifacts/` pairs with an entry in
`customer-examples/parameters/imageManagement/downloads.json` — the `DestinationFolders` field
in each download entry names the artifact folder the downloaded installer is placed into before
the script zips and uploads it.

If you keep customer content outside the extracted repo zip, pass `-CustomerRootPath` to
`Update-ImageArtifacts.ps1`, `Deploy-ImageManagement.ps1`, or `Invoke-ImageBuilds.ps1` so they
read from your external customer folder instead of the repo-local `customer/` tree.

## Source Control for Customer Content

The `customer/` tree is excluded from git tracking by the root `.gitignore` (only `README.md`
and `.gitkeep` placeholder files are committed). This prevents customer-specific values —
subscription IDs, resource group names, storage account names, and installer binaries — from
being accidentally committed back to the upstream repo.

How you track your own changes depends on your workflow:

---

### Recommended: Separate git repo + `-CustomerRootPath`

Keep FederalAVD as an upstream source you never commit to. Maintain your parameter files and
artifact packages in a **separate git repository** at a different path (e.g.,
`C:\repos\FederalAVD-Config`). Point all scripts at it using `-CustomerRootPath`:

```powershell
.\Update-ImageArtifacts.ps1 `
    -StorageAccountName "<name>" `
    -ResourceGroupName "<rg>" `
    -CustomerRootPath "C:\repos\FederalAVD-Config"

.\Deploy-ImageManagement.ps1 `
    -CustomerRootPath "C:\repos\FederalAVD-Config"

.\Invoke-ImageBuilds.ps1 `
    -CustomerRootPath "C:\repos\FederalAVD-Config"
```

The scripts expect `<CustomerRootPath>\artifacts\` and `<CustomerRootPath>\parameters\` as the
customer content locations — mirror the structure of this `customer/` folder.

**Why this is the recommended approach:**

- Your customer content has its own clean git history, branching, and pull request workflow
- FederalAVD framework updates (git pull or robocopy) never touch your content
- No gitignore rules to manage or override
- Works naturally with pipelines: check out both repos independently, pass `-CustomerRootPath`
  as a pipeline variable

---

### Alternative: Fork + track customer content in-repo

If you have forked FederalAVD into your own GitHub organization or Azure DevOps project and
want to track `customer/` content in the same repository, remove the `customer/` block from
the root `.gitignore`:

```gitignore
# Remove or comment out these lines in .gitignore to start tracking customer/ content:
# customer/artifacts/**
# !customer/artifacts/**/
# ...
```

Your fork can then commit parameter files and artifact scripts normally. When pulling upstream
changes from Azure/FederalAVD, watch for `.gitignore` conflicts — the upstream file will
re-add the ignore rules and you will need to resolve the conflict in your favor each time.

---

### No source control (default behavior)

If you manage parameter files out-of-band (a pipeline that injects them, a secrets manager,
or a shared file server), the default `.gitignore` behavior is fine — just run the scripts
directly against this folder and ignore git for the customer tree.

---

## Updating the Repo

### Using git

If you are working directly from the Azure/FederalAVD repository:

```powershell
git -C C:\repos\FederalAVD pull
```

The `customer/` folder is gitignored from the perspective of the upstream repo, so a pull will
never overwrite your files. If you have forked the repo, pull from the upstream remote:

```powershell
git -C C:\repos\FederalAVD remote add upstream https://github.com/Azure/FederalAVD
git -C C:\repos\FederalAVD fetch upstream
git -C C:\repos\FederalAVD merge upstream/main
```

### Using robocopy (ZIP/share distribution)

If you received FederalAVD as a ZIP or file share copy rather than a git clone, use robocopy
to pull the latest code while preserving this folder:

```cmd
robocopy \\source\FederalAVD C:\FederalAVD /mir /xd customer
```

The `/xd customer` flag excludes this folder from the mirror operation, so your parameter files
and custom artifact packages are never deleted or overwritten by a repo update.
