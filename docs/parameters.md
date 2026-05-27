[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**BCDR**](bcdr.md)

# Parameters Reference

Parameter documentation lives alongside each deployment template. Find the section for your solution below.

---

## Core Deployments

| Solution | Parameters | Examples |
|----------|-----------|---------|
| 🌐 **Networking** | [networking/README.md](../deployments/networking/README.md) | [parameter files](../deployments/networking/README.md) |
| 🔒 **Key Vaults** | [keyVaults/uiFormDefinition.json](../deployments/keyVaults/uiFormDefinition.json) *(see Quick Start Step 1)* | — |
| 📦 **Image Management** | [imageManagement/README.md — Parameters](../deployments/imageManagement/README.md#parameters) | [imageManagement/README.md — Examples](../deployments/imageManagement/README.md#examples) |
| 🎨 **Image Build** | [imageBuild/README.md — Parameters](../deployments/imageBuild/README.md#parameters) | [imageBuild/README.md — Examples](../deployments/imageBuild/README.md#examples) |
| 🏢 **Host Pool** | [hostpools/README.md — Parameters](../deployments/hostpools/README.md#parameters) | [hostpools/README.md — Examples](../deployments/hostpools/README.md#examples) |

---

## Add-Ons

| Add-On | Parameters |
|--------|-----------|
| 🔄 **Session Host Replacer** | [sessionHostReplacer/README.md](../deployments/add-ons/sessionHostReplacer/README.md) |
| 🖥️ **Session Hosts** | [sessionHosts/README.md](../deployments/add-ons/sessionHosts/README.md#parameters) |
| 📊 **Storage Quota Manager** | [storageQuotaManager/README.md](../deployments/add-ons/storageQuotaManager/README.md) |
| 🔑 **Update Storage Keys** | [updateStorageAccountKeyOnSessionHosts/README.md](../deployments/add-ons/updateStorageAccountKeyOnSessionHosts/README.md) |
| 📝 **Run Commands on VMs** | [runCommandsOnVms/README.md](../deployments/add-ons/runCommandsOnVms/README.md) |

---

## Cross-Solution Output Passing

When chaining deployments, use this mapping to pass outputs from one step to the next. See the **[End-to-End Automation Guide](automation-guide.md)** for the full pipeline diagram and scripted examples.

| Source | Output | Destination | Parameter |
|--------|--------|-------------|-----------|
| **keyVaults** | `secretsKeyVaultResourceId` | **hostpool** | `existingCredentialsKeyVaultResourceId` |
| **keyVaults** | `encryptionKeyVaultResourceId` | **imageManagement** | `encryptionKeyVaultResourceId` |
| **keyVaults** | `encryptionKeyVaultResourceId` | **hostpool** | `existingEncryptionKeyVaultResourceId` |
| **imageManagement** | `computeGalleryResourceId` | **imageBuild** | `computeGalleryResourceId` |
| **imageManagement** | `artifactsBlobContainerUrl` | **imageBuild** | `artifactsContainerUri` |
| **imageManagement** | `managedIdentityResourceId` | **imageBuild** | `userAssignedIdentityResourceId` |
| **imageManagement** | `buildLogsStorageAccountResourceId` | **imageBuild** | `logStorageAccountResourceId` |
| **imageManagement** | `imageBuildResourceGroupResourceId` | **imageBuild** | `imageBuildResourceGroupId` |
| **imageManagement** | `diskEncryptionSetResourceId` | **imageBuild** | `diskEncryptionSetResourceId` |
| **imageBuild** | image definition resource ID | **hostpool** | `customImageResourceId` |
