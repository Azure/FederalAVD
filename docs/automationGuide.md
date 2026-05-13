[**Home**](../README.md) | [**Quick Start**](quickStart.md) | [**Host Pool Deployment**](hostpoolDeployment.md) | [**Image Build**](imageBuild.md) | [**Artifacts**](artifactsGuide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**BCDR**](bcdr.md)

# End-to-End Automation Guide

This guide describes how to chain the FederalAVD deployment steps together in an automated or scripted workflow. It focuses on **which outputs feed which inputs** at each step — not on any specific pipeline tool or CI/CD platform.

Each step maps to an existing script or ARM/Bicep deployment. You can wire them together in whatever automation tool you use (Azure DevOps, GitHub Actions, a shell script, a runbook, etc.).

---

## The Pipeline at a Glance

Each subgraph shows a deployment step and its outputs (rounded nodes). Arrows between steps are labelled with the **target parameter name** in the receiving step.

```mermaid
flowchart TD
    subgraph KV["🔒 Step 1 · Key Vaults  (optional — CMK / credentials)"]
        KV_RUN["keyVaults.json"]
        KV_O1(["secretsKeyVaultResourceId"])
        KV_O2(["encryptionKeyVaultResourceId"])
        KV_RUN --> KV_O1 & KV_O2
    end

    subgraph IM["📦 Step 2 · Image Management"]
        IM_RUN["Deploy-ImageManagement.ps1"]
        IM_O1(["computeGalleryResourceId"])
        IM_O2(["artifactsStorageAccountResourceId"])
        IM_O3(["artifactsBlobContainerUrl"])
        IM_O4(["managedIdentityResourceId"])
        IM_O5(["buildLogsStorageAccountResourceId"])
        IM_O6(["diskEncryptionSetResourceId"])
        IM_RUN --> IM_O1 & IM_O2 & IM_O3 & IM_O4 & IM_O5 & IM_O6
    end

    subgraph UA["⬆️ Step 3 · Upload Artifacts"]
        UA_RUN["Update-ImageArtifacts.ps1"]
        UA_DONE(["artifacts in blob storage"])
        UA_RUN --> UA_DONE
    end

    subgraph IB["🎨 Step 4 · Image Build"]
        IB_RUN["Invoke-ImageBuilds.ps1"]
        IB_O1(["imageDefinitionId"])
        IB_RUN --> IB_O1
    end

    subgraph HP["🏢 Step 5 · Host Pool"]
        HP_RUN["hostpool.json"]
        HP_O1(["hostPoolResourceId"])
        HP_O2(["virtualMachineNames"])
        HP_RUN --> HP_O1 & HP_O2
    end

    %% Key Vaults → Image Management (CMK)
    KV_O2 -->|"→ encryptionKeyVaultResourceId"| IM_RUN

    %% Key Vaults → Host Pool
    KV_O1 -->|"→ credentialsKeyVaultResourceId"| HP_RUN
    KV_O2 -->|"→ encryptionKeyVaultResourceId"| HP_RUN

    %% Image Management → Upload Artifacts
    IM_O2 -->|"→ StorageAccountResourceId"| UA_RUN

    %% Image Management → Image Build
    IM_O1 -->|"→ computeGalleryResourceId"| IB_RUN
    IM_O3 -->|"→ artifactsContainerUri"| IB_RUN
    IM_O4 -->|"→ userAssignedIdentityResourceId"| IB_RUN
    IM_O5 -->|"→ logStorageAccountResourceId"| IB_RUN
    IM_O6 -->|"→ diskEncryptionSetResourceId"| IB_RUN

    %% Upload Artifacts → Image Build (data dependency, no parameter)
    UA_DONE -.->|"artifacts ready"| IB_RUN

    %% Image Build → Host Pool
    IB_O1 -->|"→ customImageResourceId"| HP_RUN
```

---

## Step 1: Deploy Key Vaults

**Script/template:** `deployments/keyVaults/keyVaults.json`  
**When required:** Only if using Customer Managed Keys (CMK) or a pre-provisioned credentials Key Vault.

### Key outputs

| Output | Used by |
|--------|---------|
| `secretsKeyVaultResourceId` | Host pool — `credentialsKeyVaultResourceId` parameter |
| `encryptionKeyVaultResourceId` | Image Management — `encryptionKeyVaultResourceId`; Host Pool — `encryptionKeyVaultResourceId` |
| `encryptionKeyVaultUri` | Available if needed for manual key references |

### Notes

- The deploying identity needs **Key Vault Crypto Officer** on the encryption key vault before running any downstream step that creates CMK keys.
- Key Vaults are intentionally deployed separately so the same vault can be shared across multiple host pool deployments and image builds.

---

## Step 2: Deploy Image Management

**Script:** `deployments/Deploy-ImageManagement.ps1`  
**Template:** `deployments/imageManagement/imageManagement.json`

```
Inputs from Step 1 (if CMK):
  encryptionKeyVaultResourceId  →  imageManagement parameter: encryptionKeyVaultResourceId

Script invocation:
  .\Deploy-ImageManagement.ps1 -Location <region> -ParameterFilePrefix <prefix>
  # Add -UpdateArtifacts to also run Step 3 automatically
```

### Key outputs

| Output | Used by |
|--------|---------|
| `computeGalleryResourceId` | Image Build — `computeGalleryResourceId` parameter |
| `artifactsStorageAccountResourceId` | Update-ImageArtifacts.ps1 — `StorageAccountResourceId` |
| `artifactsBlobContainerUrl` | Image Build — `artifactsContainerUri` parameter |
| `managedIdentityResourceId` | Image Build — `userAssignedIdentityResourceId` parameter |
| `buildLogsStorageAccountResourceId` | Image Build — `logStorageAccountResourceId` parameter |
| `diskEncryptionSetResourceId` | Image Build — `diskEncryptionSetResourceId` parameter (only when CMK enabled) |

### Notes

- Add `-UpdateArtifacts` to the script call to roll Steps 2 and 3 into a single invocation for first-time setup.
- If `deployArtifactsStorageAccount = false` in the parameter file, the artifacts-related outputs will be empty strings — skip Step 3 and omit `artifactsContainerUri` / `userAssignedIdentityResourceId` in Step 4.

---

## Step 3: Upload Artifacts

**Script:** `deployments/Update-ImageArtifacts.ps1`  
**When required:** Every time software packages are added or updated. Skip if Step 2 was run with `-UpdateArtifacts`.

```
Inputs from Step 2:
  artifactsStorageAccountResourceId  →  -StorageAccountResourceId
  (or pass -StorageAccountName / -ResourceGroupName instead)
```

This step has **no Azure deployment outputs** — it only writes blobs to storage. The artifact container URL produced by Step 2 (`artifactsBlobContainerUrl`) is what you pass to image builds.

### Notes

- For air-gapped environments, use `-SkipDownloadingNewSources` and pre-stage files in `.common/artifacts/` manually before running.
- Use `-DeleteExistingBlobs` for a clean upload when removing old packages.
- Use `-ParameterFilePrefix` to point at a custom downloads configuration file.

---

## Step 4: Build Custom Image

**Script:** `deployments/Invoke-ImageBuilds.ps1`  
**Template:** `deployments/imageBuild/imageBuild.json`

```
Inputs from Step 2:
  computeGalleryResourceId      →  imageBuild parameter: computeGalleryResourceId
  artifactsBlobContainerUrl     →  imageBuild parameter: artifactsContainerUri
  managedIdentityResourceId     →  imageBuild parameter: userAssignedIdentityResourceId
  buildLogsStorageAccountResourceId  →  imageBuild parameter: logStorageAccountResourceId (optional)
  diskEncryptionSetResourceId →  imageBuild parameter: diskEncryptionSetResourceId (only when CMK enabled)

Script invocation:
  .\Invoke-ImageBuilds.ps1 -Location <region> -ParameterFilePrefixes @('prefix1','prefix2')
```

These values are typically pre-populated in the image build parameter files after the first imageManagement deployment.

### Key outputs

| Output | Used by |
|--------|---------|
| `imageDefinitionId` | Host Pool — `customImageResourceId` parameter |

### Notes

- `Invoke-ImageBuilds.ps1` runs all prefixes **in parallel** as Azure deployment jobs and waits for all to complete.
- The `imageDefinitionId` output points at the gallery image definition. For the host pool, pass the **latest version** resource ID or use the `/versions/latest` alias:  
  `<imageDefinitionId>/versions/latest`
- Build time is typically 45–90 minutes. Factor this into pipeline timeouts.

---

## Step 5: Deploy Host Pool

**Script:** None yet — deploy directly via ARM/PowerShell/CLI or the Azure Portal.  
**Template:** `deployments/hostpools/hostpool.json`

```
Inputs from Step 4:
  imageDefinitionId + /versions/latest  →  hostpool parameter: customImageResourceId

Inputs from Step 1 (if using pre-provisioned credentials or CMK):
  secretsKeyVaultResourceId     →  hostpool parameter: credentialsKeyVaultResourceId
  encryptionKeyVaultResourceId  →  hostpool parameter: encryptionKeyVaultResourceId

Example PowerShell invocation:
  $paramFile = "prod.hostpool.parameters.json"
  $deploymentName = [System.IO.Path]::GetFileNameWithoutExtension($paramFile)
  New-AzDeployment `
      -Location <region> `
      -TemplateFile ".\deployments\hostpools\hostpool.json" `
      -TemplateParameterFile ".\deployments\hostpools\parameters\$paramFile" `
      -Name $deploymentName
```

### Key outputs

| Output | Description |
|--------|-------------|
| `hostPoolResourceId` | Host pool resource ID — useful for Session Host Replacer add-on |
| `workspaceResourceId` | AVD workspace resource ID |
| `virtualMachineNames` | Array of deployed session host VM names |
| `fslogixLocalStorageAccountResourceIds` | Storage account(s) for FSLogix profiles |

### Notes

- If `customImageResourceId` is empty, the host pool uses the marketplace image defined by `imagePublisher` / `imageOffer` / `imageSku`.
- `deploymentType` controls scope: `Complete` deploys everything, `SessionHostsOnly` adds VMs to an existing pool.
- For repeatable redeployments (e.g., after a new image build), keep your parameter file stable and just update `customImageResourceId` to the new image version.

---

## Passing Outputs Between Steps

Because there is no single orchestration script today, outputs must be captured and passed manually between steps. Common approaches:

**Option A — Save outputs to variables in a single session**

```powershell
# Step 2
$imgMgmt = New-AzDeployment -Name "..." -Location $location -TemplateFile "..." -TemplateParameterFile "..."
$galleryId   = $imgMgmt.Outputs.computeGalleryResourceId.Value
$containerUrl = $imgMgmt.Outputs.artifactsBlobContainerUrl.Value
$identityId  = $imgMgmt.Outputs.managedIdentityResourceId.Value

# Step 3 (if not using -UpdateArtifacts)
.\Update-ImageArtifacts.ps1 -StorageAccountResourceId $imgMgmt.Outputs.artifactsStorageAccountResourceId.Value

# Step 4 — pre-populate these values in your imageBuild parameter file, or pass inline
```

**Option B — Capture outputs to a JSON file between steps**

```powershell
$imgMgmt.Outputs | ConvertTo-Json | Set-Content ".\imageManagement.outputs.json"
# Load in a later step/session
$outputs = Get-Content ".\imageManagement.outputs.json" | ConvertFrom-Json
$galleryId = $outputs.computeGalleryResourceId.Value
```

**Option C — Store outputs in an Azure Key Vault or App Configuration**  
Suitable for pipeline automation where steps run in separate jobs with no shared memory.

**Option D — Read outputs from deployment history**  
Azure stores all deployment outputs in history. You can retrieve them any time:

```powershell
$imgMgmt = Get-AzDeployment -Name "ImageManagement-basic-20260507123000"
$galleryId = $imgMgmt.Outputs.computeGalleryResourceId.Value
```

---

## Suggested Parameter File Strategy

Keep one parameter file per component per environment. Update only the fields that change between runs (typically `customImageResourceId` after a new build):

```
deployments/
  keyVaults/parameters/
    prod.keyVaults.parameters.json

  imageManagement/parameters/
    prod.imageManagement.parameters.json

  imageBuild/parameters/
    prod.imageBuild.parameters.json       ← update computeGalleryResourceId, artifactsContainerUri, etc. once
    win11-m365.imageBuild.parameters.json ← per image definition variant

  hostpools/parameters/
    prod-finance.hostpool.parameters.json ← update customImageResourceId after each build
    prod-general.hostpool.parameters.json
```

---

## Related Resources

- [Quick Start Guide](quickStart.md) — Step-by-step walkthrough with portal options
- [imageManagement README](../deployments/imageManagement/README.md) — Infrastructure parameters
- [Update-ImageArtifacts Script](updateImageArtifacts.md) — Artifact upload options
- [Image Build Guide](imageBuild.md) — Image build parameters and monitoring
- [Host Pool Deployment Guide](hostpoolDeployment.md) — Full host pool parameter reference
- [Air-Gapped Cloud Guide](airGappedClouds.md) — Secret/Top Secret cloud considerations
