# AVD Image Build Samples — Azure VM Image Builder (AIB)

This folder has two **sample** Azure VM Image Builder (AIB) templates, mirroring the two Packer
samples in [`customer-examples/packer/zero-trust-image-build/`](../packer/zero-trust-image-build/):

**If your goal is the strongest achievable zero-trust posture for Azure image builds, use
[`deployments/imageBuild/imageBuild.bicep`](../../deployments/imageBuild/imageBuild.bicep) — not
these templates.** `imageBuild.bicep` executes every customization through
`Microsoft.Compute/virtualMachines/runCommands`, an outbound-only ARM API call with no inbound
network path to the build VM ever required. AIB, by contrast, depends on WinRM/SSH between an
AIB-managed process and the build VM — Microsoft's own documentation states plainly: "Don't disable
these settings as part of the build." AIB also creates its own **staging resource group** per
build, containing a storage account with **no firewall** (a documented prerequisite, not a bug) and
requires any Key Vault it touches to have **public network access enabled** — a hard conflict with a
FedRAMP High/IL4/IL5-style policy requiring Key Vaults to disable public network access. See
"Zero Trust Considerations" and "Policy Considerations" below for the full, cited detail, and
`docs/image-build.md` ("Why imageBuild.bicep Instead of Packer or Azure VM Image Builder (AIB)?")
for the side-by-side comparison. These samples exist for teams that have an independent reason to
use AIB specifically (existing AIB tooling/pipelines, a requirement for AIB's native
`WindowsUpdate`/`WindowsRestart` customizers, etc.).

| Folder | Demonstrates |
| --- | --- |
| [`software-install/`](software-install/) | FSLogix, Microsoft 365 Apps, OneDrive, and Teams (built-in software scripts, same as `imageBuild.bicep`) plus 7-Zip and Google Chrome Enterprise (generic customizers via blob storage + managed identity). |
| [`stigs/`](stigs/) | Applying DoD STIGs with `customer-examples/artifacts/DoD-STIGs/Apply-STIGsAVD.ps1` under its `AzureVMImageBuilder` execution profile. |

AIB is Microsoft's managed image-build service (`Microsoft.VirtualMachineImages/imageTemplates`).
You deploy a Bicep/ARM resource describing the source image, customizations, and distribution
target; Azure runs the actual build in a service-managed staging resource group. There is no local
CLI step analogous to `packer build` — deploying the template (with `autoRun.state: 'Enabled'`, set
in both samples here) starts the build automatically.

## How Files Reach the Build VM (Read This First)

**This is genuinely different from Packer, not just a syntax change.** AIB has no live connection
from your machine to the build VM the way Packer's WinRM communicator does, so there is nothing to
"upload a local folder" to. AIB's `customize` array supports exactly three ways to get content onto
the build VM:

1. **`inline`** — literal PowerShell/Shell commands written directly in the template.
2. **`scriptUri`** — download one script from a URI (public, or Azure Storage with an MSI-based
   read grant) and run it, **but this mode has no way to pass named parameters to the script.**
3. **`File`** — download exactly *one* file from a URI to a path on the VM (again public or MSI-based
   storage access). No folders — a multi-file package must be zipped and unzipped after download.

Both samples in this folder solve this the same way `imageBuild.bicep` already does, because it
turns out to be the best fit for AIB too:

- **Orchestration scripts are embedded directly in the Bicep template at compile time**, using
  `loadTextContent()` — exactly like `deployments/imageBuild/modules/customizeImage.bicep` already
  embeds `Install-FSLogix.ps1` and friends into its `Microsoft.Compute/virtualMachines/runCommands`
  resources. Each sample writes the embedded script to a file on the build VM via a PowerShell
  here-string, then invokes it **with real named parameters** (working around the `scriptUri`
  limitation above without needing any external hosting at all).
- **Actual software payloads** (the FSLogix/Office/OneDrive/Teams/Chrome/7-Zip installers
  themselves) are downloaded by those embedded scripts from blob storage using the **build VM's
  managed identity** — the same `deployments/shared/scripts/Invoke-Customization.ps1` and
  `Install-*.ps1` scripts `imageBuild.bicep` uses, completely unmodified. This is the blob +
  identity model, not a Packer-style local upload.

One genuine advantage over the Packer samples: Bicep can read a user-assigned identity's client ID
directly off the resource (`buildVmIdentity.properties.clientId`) with an `existing` resource
reference. Packer HCL has no equivalent, so its samples require you to run
`az identity show --ids ... --query clientId` and paste the value into a variable by hand.

## Generalize/Sysprep Is Automatic

Unlike Packer, AIB always runs its own generalize/Sysprep step automatically after the last
customizer — you do not add one yourself. `software-install/` relies on this default behavior.
`stigs/` overrides it: `Apply-STIGsAVD.ps1 -ExecutionProfile AzureVMImageBuilder` copies
`azure-vm-image-builder/DeprovisioningScript.ps1` to the fixed path `C:\DeprovisioningScript.ps1`,
and AIB automatically invokes that exact path as its hidden final customizer instead of the default
Sysprep script. See `customer-examples/artifacts/DoD-STIGs/azure-vm-image-builder/README.md`.

## Key Differences From the Packer Samples

- **No WinRM.** AIB's build VM communication is managed entirely by the Azure Image Builder service
  itself, not a network connection from wherever you run a CLI command. There is still a real VM
  with a network identity during the build (see `vmProfile.vnetConfig.subnetId` below), but you
  never configure or reason about a communicator the way Packer requires.
- **No public IP**, same as the Packer samples: set `vmProfile.vnetConfig.subnetId` to an existing
  subnet resource ID and AIB does not create one.
- **No client-host network dependency for customization.** Because there's no WinRM/control-host
  concept, you don't need a build agent or Bastion tunnel with private network reachability to run
  a build — you just need `az`/Bicep deployment permissions and network reachability *from the
  build VM* to whatever storage account or gallery it needs to reach. The image template resource
  itself needs Contributor on its resource group and the destination gallery, via
  `imageTemplateIdentityResourceId`.
- **Native `WindowsUpdate` and `WindowsRestart` customizer types.** No custom script needed for
  Windows Update or a plain restart — AIB has first-class support built in.

## Required RBAC

- **`imageTemplateIdentityResourceId`** (the identity in the template's own `identity` block) needs
  Contributor on the resource group the template deploys into and on the destination Compute
  Gallery, per
  [Microsoft's identity documentation](https://learn.microsoft.com/en-us/azure/virtual-machines/image-builder-permissions-cli).
- **`buildVmIdentityResourceId`** (attached to the build VM via `vmProfile.userAssignedIdentities`)
  needs
  [**Storage Blob Data Reader**](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/storage#storage-blob-data-reader)
  on the artifacts container. The identity that creates/owns `imageTemplateIdentityResourceId` also
  needs
  [**Managed Identity Operator**](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/identity#managed-identity-operator)
  on `buildVmIdentityResourceId` to attach it to the build VM — per the same identity documentation
  link above ("For the Image Builder Build VM to have permissions to authenticate with other
  services... the user assigned identity for Azure Image Builder must have the 'Managed Identity
  Operator' role assignment on all the user assigned identities").
- **Joining the existing subnet.** `subnetResourceId` typically lives in a *different* resource
  group than `imageTemplateIdentityResourceId`'s resource group (a separate networking RG, as in
  the example parameters files). Azure evaluates the join permission at the VNet's own scope, so
  `imageTemplateIdentityResourceId` additionally needs, scoped to **the VNet's resource group
  specifically** (not the image template's resource group):

  ```text
  Microsoft.Network/virtualNetworks/read
  Microsoft.Network/virtualNetworks/subnets/join/action
  ```

  This is documented verbatim, including these exact two actions, in
  [Configure Azure VM Image Builder permissions — "Permission to customize images on your virtual networks"](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-permissions-cli#permission-to-customize-images-on-your-virtual-networks):
  "You don't need to grant the user-assigned managed identity Contributor rights on the resource
  group to deploy a VM to an existing virtual network. However, the user-assigned managed identity
  needs the following Azure Actions permissions on the virtual network resource group." Use
  [**Network Contributor**](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/networking#network-contributor)
  or a minimal custom role with just those two actions (Microsoft publishes a
  [sample `aibRoleNetworking.json`](https://github.com/azure/azvmimagebuilder/blob/master/solutions/12_Creating_AIB_Security_Roles/aibRoleNetworking.json)
  for exactly this).
- **`containerInstanceSubnetResourceId`**, if you set it, needs this same join permission granted
  separately — the identity needs `Microsoft.Network/virtualNetworks/subnets/join/action` scoped to
  *its* resource group too, per
  [`vnetConfig.containerInstanceSubnetId`](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-json#containerinstancesubnetid-optional).
  That subnet must also be delegated to the Azure Container Instance service, be on the same VNet
  as `subnetResourceId`, and allow the specific inbound/outbound ports the same doc lists (443 and
  445 outbound to the internet, plus 22/5986 to and from `subnetResourceId`).

## Staging Resource Group

Every AIB build deploys its actual working resources (build VM, NIC, and — depending on network
config — a storage account, VNet/NSG, or Azure Container Instance) into a **staging resource
group**, separate from the resource group this template deploys into. By default AIB creates and
deletes this automatically (named `IT_<templateResourceGroup>_<templateName>_<guid>`); you don't
see it unless you go looking, and it can conflict with policy-governed subscriptions (see
**Zero Trust Considerations** and **Policy Considerations** below).

This is documented in
[Properties: stagingResourceGroup](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-json#properties-stagingresourcegroup)
and the
[troubleshooting guide's Prerequisites section](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-troubleshoot#prerequisites).
Both samples here expose a `stagingResourceGroupResourceId` parameter (left empty by default, which
preserves the automatic ephemeral behavior). If you set it to an existing resource group's resource
ID, Microsoft's documented requirements are:

- The resource group must be **empty** (no resources inside) and in the **same region** as the
  image template.
- It must **not already be associated with another image template**.
- `imageTemplateIdentityResourceId` must already have **Contributor or Owner** on it *before* you
  deploy — this is a separate, third RBAC scope beyond the two already listed above (the image
  template's own resource group, and the VNet's resource group).
- AIB tags it with `usedBy`, `imageTemplateName`, and `imageTemplateResourceGroupName` and validates
  those tags on every run; if you (or a policy) strip or change them, the build fails.
- Unlike the ephemeral `IT_*` case, AIB does **not** delete a pre-existing staging resource group
  when the image template is deleted — only the resources it put inside it.

Supplying your own staging resource group is the only way to get a predictable, taggable,
policy-assignable resource group for AIB's temporary build resources instead of an
auto-generated `IT_*` one that appears and disappears per build. Both samples also expose a
`managedResourceTags` parameter (applied to whatever AIB creates inside the staging resource group,
whether ephemeral or pre-created) for satisfying tag-based Azure Policy requirements without
necessarily needing a custom staging resource group at all.

## Zero Trust Considerations

Two AIB behaviors are **documented, unconfigurable service constraints** that genuinely deviate from
the private-endpoint-everywhere posture the rest of this repo defaults to. These aren't bugs in
these samples — they're how the AIB service works today, confirmed by Microsoft's own docs:

- **The staging resource group's internal storage account has no firewall.** Microsoft's
  troubleshooting guide lists, as a build prerequisite to plan around: "Create a storage account
  without a firewall." ([source](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-troubleshoot#prerequisites)).
  This storage account holds the `packerlogs` container (customization/validation logs) and, for VHD
  distribution, the output VHD itself. It is not the artifacts storage account you control in
  `artifactsContainerUri` — it's created and deleted by the AIB service itself, and you cannot put a
  private endpoint or network ACL on it.
- **AIB does not support Key Vaults with public network access disabled.** Microsoft's
  troubleshooting guide documents this exact failure: a policy requiring "Azure Key Vault should
  disable public network access" blocks the build with `RequestDisallowedByPolicy`, and the
  documented solution is unambiguous: "You must create the key vault with public access enabled."
  ([source](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-troubleshoot#template-deployment-failed-because-of-a-policy-violation)).
  Neither sample here creates or references a Key Vault directly, but if your subscription has a
  Deny-type policy requiring Key Vaults to disable public network access (a common FedRAMP
  High/IL4/IL5 control, and one this repo assigns elsewhere — see `docs/compliance.md`), **that
  policy will block AIB's own internal build process**, not just your resources. You need a policy
  exemption scoped narrowly (ideally to the staging resource group from the section above, not the
  whole subscription).
- **WinRM/SSH is fundamental to the build, not optional.** Confirmed by the same troubleshooting
  guide: "VM Image Builder communicates to the build VM by using WinRM or SSH. *Don't* disable these
  settings as part of the build." A customization script that hardens WinRM/SSH out from under the
  build (plausible with some STIG-style scripts) will break the build itself, not just the resulting
  image — this is why `stigs/` applies `Apply-STIGsAVD.ps1` as a customizer that runs *during* the
  build rather than something that could disable remote management first.

**Isolated Image Builds** (Microsoft's current default behavior, not something you opt into) does
meaningfully improve on the above for network isolation specifically: build customization now runs
in an Azure Container Instance deployed **into your own subscription's staging resource group**
(instead of on AIB's shared multi-tenant backend), and all WinRM/SSH traffic between that ACI and
the build VM stays inside your VNet when `containerInstanceSubnetResourceId` is set — no Private
Link tunnel back to Microsoft's backend is needed in that configuration. See
[Isolated Image Builds for Azure VM Image Builder](https://learn.microsoft.com/en-us/azure/virtual-machines/security-isolated-image-builds-image-builder).
This doesn't change the Key Vault or storage-account-firewall constraints above, though — those are
independent of Isolated Image Builds.

## Policy Considerations

If this subscription (or a management group above it) has Azure Policy initiatives assigned —
especially the kind documented in `docs/compliance.md` for FedRAMP High/DoD IL4/IL5/CMMC — verify
none of the following would block an AIB build, per Microsoft's own troubleshooting guidance
([source](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-troubleshoot#prerequisites),
[Isolated Image Builds backward compatibility](https://learn.microsoft.com/en-us/azure/virtual-machines/security-isolated-image-builds-image-builder#backward-compatibility)):

- **Deny policies on Key Vault public network access** and **Storage account network restriction**
  — both block resources AIB creates *inside its own staging resource group* (see Zero Trust
  Considerations above), not resources you control. Scope any needed exemption to the staging
  resource group, not the whole subscription.
- **Deny policies on Azure Container Instance deployment** — would break Isolated Image Builds
  entirely, since ACI is now how AIB runs customization scripts. Microsoft explicitly calls this out:
  "make sure there are no Azure Policies in your subscription that deny deployment of ACI resources."
- **Deny policies on temporary VNet/NSG/Private Endpoint creation in the staging resource group** —
  only relevant if you don't set `containerInstanceSubnetResourceId`; AIB then deploys its own
  temporary VNet/NSG/Private Endpoint/Load Balancer inside the staging resource group to broker
  ACI-to-build-VM traffic. Setting `containerInstanceSubnetResourceId` (an existing, ACI-delegated
  subnet in your own VNet) avoids this entirely, which is generally the better fit for a
  policy-governed subscription.
- **Deny policies on DDoS protection plan association for new VNets** — same avoidance path:
  specifying `containerInstanceSubnetResourceId` means AIB never creates a new VNet, so this doesn't
  apply.
- **Modify/DeployIfNotExists policies that tag or extension-inject VMs and resource groups** —
  Microsoft's own guidance: "Ensure that Azure Policy does not install unintended features on the
  build VM or other staging resources, such as Azure extensions or tag modifications." A policy that
  overwrites AIB's own `usedBy`/`imageTemplateName`/`imageTemplateResourceGroupName` tags on a
  customer-supplied staging resource group (see **Staging Resource Group** above) will break AIB's
  own validation of that resource group on the next build.
- **Guest Configuration / extension-based compliance policies targeting the build VM** — the build
  VM only exists for the duration of the build and is deleted afterward; policies that expect a
  persistent VM (for example, requiring a specific extension be present within N hours of creation)
  can create noise or false non-compliance records without actually blocking the build. Consider
  excluding the staging resource group's subscription/resource-group scope from VM-targeted
  initiatives if this becomes noisy.

## Usage

```powershell
az deployment group create `
  --resource-group <imageManagementResourceGroup> `
  --template-file software-install/imageTemplate.bicep `
  --parameters software-install/imageTemplate.parameters.json
```

With `autoRun.state: 'Enabled'` (set in both samples), the build starts automatically once the
template resource is created — no separate `Run` action needed. To track progress:

```powershell
az resource show --ids <imageTemplateResourceId> --query "properties.lastRunStatus" -o json
```

> **Not yet validated in this environment.** Neither template has been deployed against a real
> Azure subscription. `bicep build`/`az deployment group what-if` should be run before a real build
> to catch any remaining issues; this environment did not have connectivity to validate an actual
> AIB run end to end.
