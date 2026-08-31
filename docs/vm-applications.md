[**Home**](../README.md) | [**Documentation Index**](README.md) | [**Artifacts**](artifacts-guide.md) | [**Update Artifacts**](update-image-artifacts.md)

# Publish Artifact Packages as VM Applications

`Publish-VMApplications.ps1` publishes selected artifact ZIP files from the Image Management
storage account as Azure Compute Gallery VM Applications. Publication is explicit and
manifest-driven. Uploading an artifact does not automatically make it a VM Application.

This workflow reuses the existing Image Management resources:

- `Update-ImageArtifacts.ps1` packages each artifact folder as `<folder>.zip` and uploads it to
  the `artifacts` container.
- The Image Management user-assigned identity is attached to the Compute Gallery and receives
  Storage Blob Data Contributor on the artifact storage account.
- The Gallery reads packages through managed identity by using a plain cloud-specific blob URL.
  The publisher does not create or persist SAS tokens.

## Prerequisites

1. Deploy or redeploy Image Management so the Gallery has the managed identity and storage role.
2. Upload the required artifact packages with `Update-ImageArtifacts.ps1`.
3. Connect Azure PowerShell to the target cloud and subscription.
4. Copy the example manifest to the customer folder and define lifecycle commands for each
   selected package:

   ```powershell
   Copy-Item `
       -Path '.\customer-examples\parameters\imageManagement\vmApplications.json' `
       -Destination '.\customer\parameters\imageManagement\vmApplications.json'
   ```

Existing artifact packages are not assumed to be valid VM Applications. Every published package
must have tested install and remove commands. An update command is optional; when omitted, Azure
runs the old version's remove command and the new version's install command during an update.

## Manifest Reference

The manifest contains an `applications` array. Each entry supports these fields:

| Field | Required | Description |
| --- | --- | --- |
| `name` | Yes | Gallery application definition name. |
| `version` | Yes | Immutable numeric `Major.Minor.Patch` version. |
| `packageBlob` | Yes | Blob path relative to the artifacts container, without a URL or SAS token. |
| `packageFileName` | No | Filename presented to lifecycle commands. Defaults to the final segment of `packageBlob` and must retain `.zip`. |
| `supportedOSType` | Yes | `Windows` or `Linux`. |
| `description` | No | Gallery application definition description. |
| `install` | Yes | Installation command, limited to 4,096 characters. |
| `remove` | Yes | Removal command, limited to 4,096 characters. |
| `update` | No | In-place update command, limited to 4,096 characters. |
| `targetRegions` | Yes | One or more Gallery replication targets. |
| `excludeFromLatest` | No | Excludes this version from `latest`; defaults to `false`. |
| `scriptBehaviorAfterReboot` | No | `None` or `Rerun`; defaults to `None`. |

Each target region requires `name`. `regionalReplicaCount` defaults to `1`, and
`storageAccountType` defaults to `Standard_LRS`.

Lifecycle commands run in Azure's VM Application package working directory. For a ZIP package,
the install or update command should expand `packageFileName` before calling scripts inside it.
Removal must target installed state that remains outside the transient package working directory
unless the package manager deliberately preserves the needed files.

## Validate and Publish

Validation parses the complete manifest before loading Azure context or making resource changes:

```powershell
.\deployments\Publish-VMApplications.ps1 `
    -ManifestPath '.\customer\parameters\imageManagement\vmApplications.json' `
    -ValidateOnly
```

Publish by using the resource IDs returned by Image Management:

```powershell
$published = .\deployments\Publish-VMApplications.ps1 `
    -ManifestPath '.\customer\parameters\imageManagement\vmApplications.json' `
    -GalleryResourceId '<computeGalleryResourceId>' `
    -StorageAccountResourceId '<artifactsStorageAccountResourceId>'

$published | ConvertTo-Json -Depth 5
```

The publisher creates missing application definitions and versions, then waits for every target
region to complete replication. Its success output contains `name`, `version`, and
`packageReferenceId`. The last value can be used directly in an automated host pool VM
application assignment.

## Idempotency and Versioning

Each version receives a `FederalAVDManifestHash` tag calculated from its package URL, lifecycle
commands, settings, and target regions. Rerunning an identical manifest is a no-op. If the same
application version exists with a different hash or without the publisher tag, publication stops.
Change the semantic version whenever package content or publication settings change.

The publisher never overwrites or deletes an existing version. This protects session-host
assignments from an apparently identical version resolving to changed content.

## Air-Gapped Clouds

VM Application publishing performs no software download. On a connected system, create packages
with `Update-ImageArtifacts.ps1 -PackageOnly`, transfer them through the approved process, and
upload them to Image Management storage in the target cloud. Then run the publisher while connected
to that cloud.

The publisher derives the blob DNS suffix from the active Az environment, so the manifest remains
environment-neutral. Do not add public URLs or SAS tokens to the manifest. Before adopting the
workflow, verify that Azure Compute Gallery VM Applications are available in the target Secret or
Top Secret environment and in every requested replication region.
