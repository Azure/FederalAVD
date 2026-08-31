[**Home**](../README.md) | [**Documentation Index**](README.md) | [**Artifacts**](artifacts-guide.md) | [**Update Artifacts**](update-image-artifacts.md)

# Publish Artifact Packages as VM Applications

`Publish-VMApplications.ps1` publishes selected artifact ZIP files from the Image Management
storage account as Azure Compute Gallery VM Applications. Publication is explicit and
manifest-driven. Uploading an artifact does not automatically make it a VM Application.

## Where This Fits

VM Applications are an application-delivery choice, not a host-pool management approach. They can
keep independently versioned software outside a session-host image while the selected host-pool
model continues to own VM creation and replacement.

| Stage | FederalAVD control | Result |
| --- | --- | --- |
| Prepare | `Update-ImageArtifacts.ps1` | Downloads or uses pre-staged files, creates artifact ZIPs, and uploads them to Image Management storage. |
| Publish | `Publish-VMApplications.ps1` | Publishes only manifest-selected ZIPs as immutable, regionally replicated Gallery application versions. |
| Assign | Host-pool parameters, Azure Policy, direct assignment, or customer automation | Declares which published versions a VM or fleet should install and in what order. |
| Converge | Azure VM Applications | Runs install, optional update, and remove commands asynchronously on assigned VMs. |

These stages are intentionally independent. A pipeline may run them in sequence, but no stage
implicitly performs the next one. In particular, uploading a ZIP does not publish it, and
publishing a version does not install it on session hosts.

For an automated host pool, add the returned `packageReferenceId` values to the ordered
`sessionHostVmApplications` parameter and redeploy the host-pool solution. Its resource-group policy
assignment owns the complete `applicationProfile.galleryApplications` array. New hosts receive the
declaration during creation. Assign either a specific semantic version for a pinned rollout or an
ID ending in `/versions/latest` to resolve the newest version not marked `excludeFromLatest`.
The deployment grants the automated host-pool managed identity `Reader` on each referenced Compute
Gallery so Azure can authorize linked application-version reads during VM creation. When a gallery
is in another subscription, the deploying identity must be able to create role assignments at that
gallery scope.
Changed assignments and newly published versions selected through `latest` require an intentional
policy remediation task or VM update for existing hosts; publication alone does not update them.
Installation is asynchronous, so application readiness must be part of the pool's admission and
monitoring process.

This is the preferred automated-host-pool path for software with meaningful install and remove
behavior. Reserve private customizations for provisioning-time configuration, bootstrap actions,
or documented exceptions that cannot provide an independent VM Application lifecycle.

For a standard host pool, use direct assignment or customer-owned fleet automation. Use an image
instead when software must be ready before logon or changes with the OS baseline. Keep policy,
configuration, security onboarding, OS servicing, and shared host dependencies in their existing
image, customization, or endpoint-management workflows.

See [Choose a Host Pool Management Approach](host-pool-management.md#choose-application-delivery-separately),
the [end-to-end automation guide](automation-guide.md#optional-step-3a-publish-vm-applications), and
the [automated host-pool deployment guide](../deployments/automatedHostPools/README.md#publish-and-assign-federalavd-artifacts-as-vm-applications).

This workflow reuses the existing Image Management resources:

- `Update-ImageArtifacts.ps1` packages each artifact folder as `<folder>.zip` and uploads it to
  the `artifacts` container.
- The Image Management user-assigned identity is attached to the Compute Gallery and receives
  Storage Blob Data Contributor on the artifact storage account.
- The Gallery reads packages through managed identity by using a plain cloud-specific blob URL.
  The publisher does not create or persist SAS tokens.
- The artifact storage firewall permits trusted Azure services so the Gallery can ingest the
  package through that identity while storage otherwise remains network-restricted.

## How Much Configuration Is Required?

The workflow can involve three customer-owned JSON files, but each has a separate lifecycle and
only two are specific to application content:

| File | When needed | Responsibility |
| --- | --- | --- |
| `imageManagement/*.parameters.json` | Once per Image Management environment | Deploys the Gallery, storage, and managed identity. It is not changed for each application. |
| `imageManagement/downloads.json` | Optional | Downloads installers into artifact folders before packaging. Omit it when files are already staged. |
| `imageManagement/vmApplications.json` | When publishing VM Applications | Selects ZIPs to publish and defines version, lifecycle commands, and replication regions. |

Artifact folders are package content, not another configuration layer. Keeping publication metadata
separate from `downloads.json` is intentional: downloading or uploading a package must not silently
make it deployable to VMs. A release needs explicit install and remove behavior plus an immutable
version.

Publish only software that can be installed, updated, and removed independently from the session
host. Policy and configuration artifacts (`Configure-*`, `Set-*`, and `Apply-*`), security
onboarding, OS servicing, and shared host dependencies are not VM Applications. Continue applying
those artifacts during image builds or session-host customization. Application artifact entry
scripts use the `Deploy-*` naming convention and expose `-DeploymentType Install|Uninstall` when
they are ready for VM Application publication.

## Prerequisites

1. Deploy or redeploy Image Management so the Gallery has the managed identity, storage role, and
  trusted Azure services storage-network exception.
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

## Working MSI Example: Azure CLI

The example manifest uses the existing
`customer-examples/artifacts/Microsoft-AzCLI` package. Its PowerShell script already supports both
installation and uninstallation, waits for Windows Installer, accepts exit codes `0` and `3010`,
and looks up the installed MSI ProductCode when removing Azure CLI.

Prepare only this example package:

```powershell
Copy-Item `
  -Path '.\customer-examples\artifacts\Microsoft-AzCLI' `
  -Destination '.\customer\artifacts\Microsoft-AzCLI' `
  -Recurse `
  -Force

Copy-Item `
  -Path '.\customer-examples\parameters\imageManagement\downloads.json' `
  -Destination '.\customer\parameters\imageManagement\downloads.json' `
  -Force
```

The downloads example contains many optional applications. Remove entries you do not want and keep
`AzCli` for this walkthrough. Alternatively, place an Azure CLI x64 MSI directly in
`customer/artifacts/Microsoft-AzCLI/` and run `Update-ImageArtifacts.ps1` with
`-SkipDownloadingNewSources`.

Upload the package and verify that the resulting artifacts container contains
`Microsoft-AzCLI.zip`:

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
  -StorageAccountResourceId '<artifactsStorageAccountResourceId>'

.\deployments\Publish-VMApplications.ps1 `
  -ManifestPath '.\customer\parameters\imageManagement\vmApplications.json' `
  -ValidateOnly
```

The sample uses Gallery version `1.0.0` as a starting release number. Before production use, choose
an organizational versioning rule and increment the Gallery version whenever the ZIP contents or
lifecycle settings change. Aligning it with the packaged software version is usually easiest for
operators to understand.

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
Azure also makes the application package available to the remove command and deletes its managed
files after removal. A ZIP-based remove command should expand the package again instead of assuming
the directory extracted during installation still exists. Commands must be silent, synchronous,
and return a failing exit code when installation or removal fails.

### Familiar MSI Removal Patterns

VM Applications do not replace the packaging practices used with Configuration Manager or Intune.
The manifest simply carries the install, remove, and optional update command strings Azure runs.
For MSI packages, two familiar removal patterns are sufficient in many cases.

Remove by MSI path when the same MSI is included in the package:

```text
msiexec.exe /x ".\package\application.msi" /quiet /qn /norestart
```

Remove by a known MSI ProductCode when it is stable for that release:

```text
msiexec.exe /x "{00000000-0000-0000-0000-000000000000}" /quiet /qn /norestart
```

ProductCodes can change between MSI releases. Use the code for the packaged release, or use an
uninstall wrapper such as the Azure CLI example that discovers the installed ProductCode. In either
case, wait for `msiexec.exe`, treat reboot-required success according to the package's needs, and
propagate real failures. Detection-rule design, supersedence strategy, and vendor-specific installer
switches remain application-management concerns and are intentionally outside this guide.

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
