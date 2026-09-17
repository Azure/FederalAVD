# Zero-Trust Image Build — HashiCorp Packer Samples

This folder has two **sample** HashiCorp Packer templates that mirror the build-VM security
posture of [`deployments/imageBuild/imageBuild.bicep`](../../deployments/imageBuild/imageBuild.bicep)
as closely as Packer's execution model allows: no public IP on the build VM, TrustedLaunch/
ConfidentialVM with Secure Boot and vTPM, encryption at host, and capture straight into an Azure
Compute Gallery (Shared Image Gallery).

**If your goal is the strongest achievable zero-trust posture for Azure image builds, use
`imageBuild.bicep` — not these templates.** It executes every customization through
`Microsoft.Compute/virtualMachines/runCommands` (an ARM API call with no inbound network path ever
required), whereas Packer's `azure-arm` builder requires a WinRM connection from wherever
`packer build` runs. See "Key Security-Model Differences" below, and
`docs/image-build.md` ("Why imageBuild.bicep Instead of Packer or Azure VM Image Builder (AIB)?")
for the full side-by-side comparison against both Packer and AIB. These samples exist for teams
that have an independent reason to use Packer specifically (existing Packer tooling, multi-cloud
consistency, etc.).

**Both templates use explicit, static provisioner blocks — not a generic, data-driven list — and
the most common Packer pattern for custom software: a `file` provisioner uploads a local artifact
folder, then a `powershell` provisioner runs the script inside it.** Packer HCL2 has no construct
for generating a variable number of provisioner blocks from a runtime-length list (its `dynamic`
block only repeats *nested* blocks within a single source/provisioner, like `target_region`).
Every real-world Packer template, including HashiCorp's own reference examples, hardcodes one
explicit `file`/`powershell` pair per install step; these samples follow that convention instead of
fighting it. To add another package, copy one of the `file`/`powershell` provisioner pairs and
point it at a different artifact folder.

These are reference implementations under `customer-examples/`. Copy a folder elsewhere (or into
your own automation) and customize rather than editing it in place.

## Two Examples

| Folder | Demonstrates |
| --- | --- |
| [`software-install/`](software-install/) | FSLogix, Microsoft 365 Apps, OneDrive, and Teams (built-in software scripts, same as `imageBuild.bicep`) plus 7-Zip and Google Chrome Enterprise (generic customizers via `file` + `powershell`). |
| [`stigs/`](stigs/) | Applying DoD STIGs with `customer-examples/artifacts/DoD-STIGs/Apply-STIGsAVD.ps1` and its Packer finalizer, kept separate because of its distinct build-order and Sysprep requirements. |

Each folder is self-contained: its own `variables.pkr.hcl`, `image-build.pkr.hcl`, and
`example.pkrvars.hcl`. Run `packer` from inside the folder you want to use.

## Usage

```powershell
cd customer-examples/packer/software-install   # or .../stigs
packer init image-build.pkr.hcl
packer validate -var-file=<your>.pkrvars.hcl image-build.pkr.hcl
packer build    -var-file=<your>.pkrvars.hcl image-build.pkr.hcl
```

> **Not yet validated in this environment.** `packer` CLI was not available when these templates
> were authored, so `packer validate`/`packer build` have not actually been run against them. Run
> `packer init` + `packer validate` yourself before a real build to catch any remaining HCL issues.

## `file` + `powershell`: The Standard Pattern for Custom Software

Both examples upload a local artifact folder (script + installer payload together, e.g.
`Deploy-7-Zip.ps1` next to its `.msi` — the same convention `customer-examples/artifacts/*` already
uses) with a `file` provisioner, then run the script with a `powershell` provisioner:

```hcl
provisioner "file" {
  source      = "${var.artifacts_local_path}/7-Zip/"
  destination = "C:/Windows/Temp/7-Zip"
}

provisioner "powershell" {
  inline = ["& 'C:/Windows/Temp/7-Zip/Deploy-7-Zip.ps1'"]
}
```

Built-in software (FSLogix, M365, OneDrive, Teams) uses Packer's `script = "..."` attribute
instead, which is the same upload-then-execute mechanism condensed into one block — appropriate
here because each script is fully self-contained and downloads its own payload from a URL rather
than needing a local file alongside it.

`artifacts_local_path` must point at a local folder that already contains the artifact
subfolders — e.g. a checked-out copy of `customer/artifacts/` on whatever machine runs
`packer build` (the same way a CI pipeline checks out a repo before a build step). Copy the
relevant `customer-examples/artifacts/<name>` folder into `customer/artifacts/<name>` first, and
stage the installer file with `deployments/Update-ImageArtifacts.ps1` or manually before running
`packer build`.

## Parameter Parity Mapping (vs. `imageBuild.bicep`)

| Packer variable | Bicep parameter | Notes |
| --- | --- | --- |
| `virtual_network_name` / `virtual_network_subnet_name` / `virtual_network_resource_group_name` | `subnetResourceId` | No public IP is created in either model (`private_virtual_network_with_public_ip` defaults to `false`). |
| `security_type`, `encryption_at_host` | `imageDefinitionSecurityType`, `encryptionAtHost` | Same defaults (`TrustedLaunch`, `true`). |
| `install_fslogix`, `office365_apps_to_install`, `install_onedrive`, `install_teams` (`software-install/`) | corresponding built-in software parameters | Same scripts, same script parameters. |
| `install_7zip`, `install_chrome`, `artifacts_local_path` (`software-install/`) | `customizations` | Explicit `file` + `powershell` pairs instead of a generic array — see above. |
| `stigs_arguments`, `stigs_intended_domain_joined`, `artifacts_local_path` (`stigs/`) | `customizations` (STIG entry) | Same explicit pattern, kept in its own example due to build-order and Sysprep coupling. |
| `gallery_*` variables | Compute Gallery capture parameters | `shared_image_gallery_destination` block with `target_region` per replication region. |

### Getting `user_assigned_identity_client_id` (`software-install/` only, when pointing at private blob storage)

Packer HCL cannot look up an Azure resource's properties at plan time the way Terraform `data`
sources can. Resolve the client ID once with:

```powershell
az identity show --ids <user_assigned_identity_resource_ids[0]> --query clientId -o tsv
```

## Key Security-Model Differences From the Bicep Build

The Bicep build executes every script through `Microsoft.Compute/virtualMachines/runCommands`
(Azure Run Command over the VM guest agent channel) — an ARM API call with **no inbound network
path required at all**. Packer's `azure-arm` builder instead uses a **WinRM** communicator, which
requires whatever host runs `packer build` to have network reachability to the build VM's private
subnet. This is the main zero-trust gap versus the Bicep model and cannot be fully closed with the
`azure-arm` builder as-is. Plan for one of:

- A self-hosted build agent/VM deployed inside (or peered with) the target VNet.
- An Azure Bastion tunnel or VPN from the machine running `packer build`.

Other differences to be aware of:

- **DoD STIGs and Sysprep are linked.** `customer-examples/artifacts/DoD-STIGs/packer/Finalize-STIGsForPacker.ps1`
  restores the temporary WinRM/firewall exceptions `Apply-STIGsAVD.ps1 -ExecutionProfile Packer`
  put in place, and runs Sysprep itself — that is why `stigs/image-build.pkr.hcl` never calls the
  generic `Invoke-Sysprep.ps1`. See `customer-examples/artifacts/DoD-STIGs/packer/README.md` for
  the full build-order rationale. Do not add provisioners after the finalizer; Packer should
  proceed straight to power-off and capture.
- **Ephemeral Key Vault for WinRM certs.** By default the `azure-arm` builder creates and deletes a
  temporary Key Vault (with public network access) per build to inject a WinRM certificate. You can
  set `build_key_vault_name` / `build_key_vault_resource_group_name` to use an existing Key Vault
  instead, and it can have private endpoints with public network access denied — Packer just calls
  the vault's normal data-plane API (`https://<vault>.vault.azure.net`), which enforces whatever
  network rules the vault already has, the same as any other client. That means whatever machine
  runs `packer build` (not the build VM) must itself have network line-of-sight to the vault's
  private endpoint (VNet-joined, peered, or connected via VPN/ExpressRoute) plus correct private DNS
  resolution, and its calling identity needs data-plane access (an RBAC role or access-policy entry
  granting certificate/secret get+set). Without that, expect a `Forbidden: Client address is not
  authorized` error from Key Vault — this is a real, previously reported failure mode
  ([packer-plugin-azure#384](https://github.com/hashicorp/packer-plugin-azure/issues/384)), not a
  hypothetical one. In short: a private Key Vault removes the *ephemeral public-network* vault, but
  adds the same "control host needs private network access" burden this README already calls out
  for WinRM above — it does not avoid that burden.
- **Sysprep `AdminPassword`.** `software-install/`'s `Invoke-Sysprep.ps1` step performs a
  `LogonUser` Win32 API pre-flight check that requires a real, known local admin password. The
  `azure-arm` builder normally auto-generates a random admin password internally, which this script
  cannot use. Set `admin_username` / `admin_password` explicitly (also used for the
  `winrm_username` / `winrm_password` fields) so the sysprep pre-flight check has a working
  credential. Treat this value as a secret: pass it via `PKR_VAR_admin_password` or a secrets
  manager, not a committed vars file.
- **No managed-image target.** Only Shared Image Gallery capture is wired up (matching the Bicep
  build's Compute Gallery output). `disk_encryption_set_id` on the build VM's OS disk only takes
  effect with a Shared Image Gallery destination, per Packer's `azure-arm` builder docs.

## Required RBAC

- **Packer control-plane identity** (the `az login` session, or the service principal if
  `use_azure_cli_auth = false`) needs rights to create/manage the build VM, NIC, and (if used)
  resource group.
- **Joining the existing subnet.** `virtual_network_name`/`virtual_network_subnet_name` typically
  live in a *different* resource group than the build (`virtual_network_resource_group_name` vs.
  `build_resource_group_name` in the example vars files). Azure evaluates the join permission at
  the VNet's own scope, not the build resource group's, so the Packer control-plane identity also
  needs
  [`Microsoft.Network/virtualNetworks/read`](https://learn.microsoft.com/en-us/azure/role-based-access-control/permissions/networking#microsoftnetwork)
  and
  [`Microsoft.Network/virtualNetworks/subnets/join/action`](https://learn.microsoft.com/en-us/azure/role-based-access-control/permissions/networking#microsoftnetwork)
  scoped to `virtual_network_resource_group_name` specifically — either via
  [**Network Contributor**](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/networking#network-contributor)
  or a minimal custom role with just those two actions. This exact requirement (and the two
  actions above) is documented for Azure VM Image Builder's identical subnet-join problem in
  [Configure Azure VM Image Builder permissions — "Permission to customize images on your virtual networks"](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-permissions-cli#permission-to-customize-images-on-your-virtual-networks),
  and the same ARM `join/action` mechanics apply to any NIC creation across resource-group
  boundaries, Packer's `azure-arm` builder included.
- **`software-install/`'s user-assigned managed identity** (optional) only needs
  [**Storage Blob Data Reader**](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/storage#storage-blob-data-reader)
  if you point a built-in-software `*_uri` variable at your own blob storage instead of the public
  Microsoft download URLs used by default. If every `*_uri` stays at its default, no identity is
  needed at all. If you do attach one, the Packer control-plane identity also needs
  [**Managed Identity Operator**](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/identity#managed-identity-operator)
  and
  [**Virtual Machine Contributor**](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/compute#virtual-machine-contributor)
  to attach it to the build VM — this is stated directly in the
  [`user_assigned_managed_identities` field documentation](https://developer.hashicorp.com/packer/integrations/hashicorp/azure/latest/components/builder/arm#optional)
  for the `azure-arm` builder, not just inferred. `stigs/` needs no identity or blob storage —
  `Apply-STIGsAVD.ps1` downloads the STIG GPO package itself over plain HTTPS.

## Known Limitations / Not Yet Verified

- `packer validate` / `packer build` have not been run against this template in this environment
  (no `packer` CLI installed here). Validate the HCL yourself before first use.
- The `winrm_password` you set is expected to become the actual local admin password used by
  `Invoke-Sysprep.ps1`'s pre-flight check; this has not been confirmed against a real build.
  If sysprep's `LogonUser` check fails, this is the first thing to investigate.

