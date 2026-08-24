# Automated AVD Host Pool Deployment

This subscription-scoped deployment creates a pooled Azure Virtual Desktop host pool that uses
Session Host Configuration (`managementType: Automated`). Azure Virtual Desktop owns creation,
update, and replacement of the session-host virtual machines.

This is not a more automated edition of the standard template; it selects a different, immutable
Azure Virtual Desktop management approach. Use the
[host pool management decision guide](../../docs/host-pool-management.md) to compare lifecycle
ownership, supported scenarios, scaling, image updates, and the Session Host Replacer alternative.

Don't use Session Host Replacer, the standalone Session Hosts add-on, or external VM lifecycle
automation with this host pool. Change Session Host Configuration and use native Session Host
Update and autoscale instead.

> Automated host pools currently require Azure Commercial and the
> `Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview` API. Use the standard
> `deployments/hostpools` solution for sovereign clouds, personal host pools, and directly managed
> session-host VMs.

## Deployment Flow

`automatedHostPool.bicep` performs the complete ordered deployment:

1. Creates the control-plane and dedicated session-host resource groups.
2. Creates a pooled host pool with `managementType: Automated`, a desktop application group, and
   a new or existing workspace association.
3. Grants the host-pool managed identity access to the host, network, image, credential-vault, and
   host-pool scopes required by Session Host Configuration.
4. Creates `sessionHostConfigurations/default` with the selected image, network, credentials,
   security profile, managed or ephemeral OS disk, VM size, and dedicated VM resource group.
5. Creates `sessionHostManagements/default` without a provisioning request, which is the API's
  zero-host state. The API does not accept an explicit `instanceCount: 0`.
6. Optionally deploys FSLogix storage by composing `deployments/add-ons/fslogixStorage`.
7. Deploys the policy and RBAC required for settings the native service does not expose by
  composing the internal `deployments/automatedHostPools/policy` module.
8. Updates `sessionHostManagements/default` with the requested `instanceCount` only after storage
  and policy deployment complete.
9. Optionally assigns the AVD service principal roles and creates a dynamic scaling plan with a
  `CreateDeletePowerManage` pooled schedule after initial provisioning completes.

The existing standard host-pool deployment is unchanged. Shared naming, AVD resources, FSLogix,
policy, Key Vault RBAC, and generic role-assignment modules are reused rather than copied.

## Resource Group Placement

The portal form does not ask for resource group names. Like the standard host-pool deployment in
this repository, the automated deployment derives them from the selected naming convention:

- When creating a workspace, the host pool, application group, and workspace are deployed to the
  generated control-plane resource group. When reusing a workspace, its resource group is reused
  for the host pool and application group.
- Session hosts are deployed to a generated, dedicated session-host resource group. That resource
  group is also the scope for session-host policy and RBAC, so unrelated virtual machines must not
  share it.
- Newly deployed FSLogix storage uses a generated storage resource group. Its temporary deployment
  VM and identity use a separate generated deployment resource group that is removed after storage
  configuration completes.
- Existing FSLogix storage remains in its current resource group and is referenced by resource ID.

Customize the generated names with the **Tags and Naming** step. Resource-group selection is not
currently exposed as a separate portal control.

## Prerequisites

- An Azure Commercial subscription with the required resource providers registered.
- An existing session-host subnet. Associate any required NSG with the subnet through the
  networking deployment; the automated host-pool deployment does not attach an NSG to session-host
  NICs.
- An RBAC-enabled Key Vault containing `VirtualMachineAdminUserName` and
  `VirtualMachineAdminPassword`, or equivalent secrets selected as portal overrides. The host-pool
  identity receives Key Vault Secrets User on this vault. The deployment uses versionless secret
  URIs so secret rotation does not require a template update. Enable Azure Resource Manager
  template deployment on the vault. Its network settings must either disable public access while
  allowing trusted Azure services (recommended), or allow public access from all networks so Azure
  Virtual Desktop can resolve the secret references.
- For AD DS or Entra Domain Services, the vault must also contain
  `DomainJoinUserPrincipalName` and `DomainJoinUserPassword`.
- When monitoring is enabled, an existing AVD Insights Data Collection Rule and optional Data
  Collection Endpoint.
- When Azure Files private endpoints are enabled, the private DNS zone resource ID.
- Ephemeral OS disks require a VM size whose selected cache or resource disk can hold the image OS
  disk. Ephemeral OS disks are local to the VM and are recreated when Azure Virtual Desktop
  replaces the session host.
- Start VM on Connect or dynamic autoscaling requires the object ID of the Azure Virtual Desktop
  service principal. Start VM on Connect assigns Desktop Virtualization Power On Contributor.
  Dynamic autoscaling assigns Desktop Virtualization Power On Off Contributor and Desktop
  Virtual Machine Contributor at subscription scope.
- Dynamically created session hosts currently require outbound HTTPS access to
  `wvdhpustgr0prod.blob.core.windows.net` so the service can deploy the AVD Agent.

The deploying principal needs permission to create subscription deployments, resource groups,
policy definitions and assignments, managed identities, and role assignments at every referenced
scope.

## Identities and RBAC

The deployment uses three identities for different operations:

| Identity | Role and scope | When assigned |
| --- | --- | --- |
| Host-pool managed identity | Desktop Virtualization Virtual Machine Contributor on the session-host resource group, network resource group, selected image resource group, and host pool | Always; the image scope is added only for a Compute Gallery image |
| Host-pool managed identity | Key Vault Secrets User on the credentials Key Vault | Always |
| Azure Virtual Desktop enterprise application | Desktop Virtualization Power On Contributor, or Power On Off Contributor plus Desktop Virtualization Virtual Machine Contributor, at subscription scope | Start VM on Connect or dynamic autoscaling, respectively |
| Policy user-assigned identity | VM, network, tag, monitoring, storage-key, and disk permissions required by the enabled post-provisioning policies | Always created; optional permissions are assigned only when their features are enabled |

The host-pool managed identity is what Azure Virtual Desktop uses to create, update, replace, and
delete native automated session hosts and retrieve their credential secrets. It is required even
when no scaling plan is deployed. The Azure Virtual Desktop enterprise application does not
replace this identity; it is used by Start VM on Connect and autoscale, which don't support the
host-pool managed identity.

## Deploy

An automated host pool always requires a pre-existing credentials Key Vault. For the PoC path,
deploy the secrets-vault-only Shared Services starter first. Supply credentials at deployment time;
do not add them to the parameter file:

```powershell
New-Item -ItemType Directory -Force customer\parameters\sharedServices | Out-Null
Copy-Item customer-examples\parameters\sharedServices\poc.automatedHostPoolPrerequisites.sharedServices.parameters.json `
  customer\parameters\sharedServices\automated-poc.sharedServices.parameters.json

$vmAdminUserName = Read-Host 'VM administrator username' -AsSecureString
$vmAdminPassword = Read-Host 'VM administrator password' -AsSecureString
$sharedServicesDeployment = New-AzDeployment `
  -Name 'automated-poc-prerequisites' `
  -Location 'eastus' `
  -TemplateFile .\deployments\sharedServices\sharedServices.bicep `
  -TemplateParameterFile .\customer\parameters\sharedServices\automated-poc.sharedServices.parameters.json `
  -virtualMachineAdminUserName $vmAdminUserName `
  -virtualMachineAdminPassword $vmAdminPassword

$credentialsKeyVaultResourceId = $sharedServicesDeployment.Outputs.secretsKeyVaultResourceId.Value
```

Copy the automated host-pool starter into the ignored `customer` folder and replace all placeholder
values. Set `credentialsKeyVaultResourceId` to `$credentialsKeyVaultResourceId` in your deployment
automation, or paste that output into the customer parameter file:

```powershell
New-Item -ItemType Directory -Force customer\parameters\automatedHostPools | Out-Null
Copy-Item customer-examples\parameters\automatedHostPools\poc.automatedHostPool.parameters.json `
  customer\parameters\automatedHostPools\myPool.parameters.json

New-AzDeployment `
  -Location eastus `
  -TemplateFile .\deployments\automatedHostPools\automatedHostPool.json `
  -TemplateParameterFile .\customer\parameters\automatedHostPools\myPool.parameters.json `
  -credentialsKeyVaultResourceId $credentialsKeyVaultResourceId `
  -Verbose
```

Do not persist `deploymentSuffix` in saved parameter files. Its default changes for each deployment
so temporary FSLogix deployment resources and nested deployments can rerun safely.

To deploy through the Azure portal, publish the automated host-pool Template Spec and its form:

```powershell
.\tools\New-TemplateSpecs.ps1 `
  -Location eastus `
  -createHostPool $false `
  -createAutomatedHostPool $true `
  -CreateAddOns $false
```

The automated Template Spec is opt-in because the preview resource API is available only in Azure
Commercial. The portal form selects existing network, Key Vault, image, monitoring, and encryption
resources. Network selection is limited to the virtual network and subnet so subnet-level NSG
configuration remains authoritative. The form uses the default secret names listed in
Prerequisites unless **Customize credential secret names** is selected. Optional picker overrides
submit the selected versionless secret URI and never retrieve secret values. The deploying user
needs Key Vault Reader on the credentials vault and browser-side data-plane network access to list
secret metadata; users who cannot reach the vault can leave the overrides disabled and use the
default names.

## Session Host Availability

Automated host pools support Availability Zones when the selected VM SKU exposes zones in the
session-host region. Availability Sets are a feature parity gap because the preview AVD Session Host
Configuration API does not expose Availability Set placement.

Azure Policy can add one specific Availability Set to a VM creation request, but it cannot query the
number of VMs already assigned to each set. A managed Availability Set supports at most 200 VMs, and
native Session Host Management does not expose a stable VM number that policy can safely use to
distribute scale-out and replacement VMs across pre-created sets. Use Availability Zones, no
infrastructure redundancy, or the standard host-pool deployment when Availability Sets are required.

## Feature Parity with Standard Host Pools

The automated deployment uses Session Host Configuration for native VM creation and Azure Policy
for supported settings that the preview API does not expose. The following standard host-pool
capabilities are therefore available and are not feature gaps:

| Capability | Automated implementation |
| --- | --- |
| OS disk size and guest partition expansion | Policy modifies the VM creation request and the unified guest configuration expands the Windows partition. |
| Encryption at host and accelerated networking | Policy modifies the VM or NIC creation request. The portal form capability-gates accelerated networking against the selected VM size and gallery image. |
| Guest Attestation integrity monitoring | Policy deploys the Guest Attestation extension for Trusted Launch and Confidential VMs. |
| AVD Insights monitoring | Policy deploys Azure Monitor Agent and associates the selected DCR and optional DCE. |
| FSLogix configuration and storage | The deployment composes the FSLogix storage add-on before host creation, then policy configures the session hosts. |
| Disk Encryption Set and managed-disk network isolation | Policy injects the DES and disables managed-disk public and export access when selected. |
| Ordered private customizations | Policy attaches the artifact identity and runs customizations from the private artifact source in input order. |

The remaining feature parity gaps are explicit boundaries of the automated management model:

| Standard host-pool capability | Automated-host boundary or alternative |
| --- | --- |
| Availability Sets | The preview Session Host Configuration API supports Availability Zones but does not expose Availability Set placement. See [Session Host Availability](#session-host-availability). |
| Azure Dedicated Hosts | The preview API does not expose dedicated host or host-group placement. Use the standard host-pool deployment when physical host isolation is required. |
| IPv6 NIC configuration | Azure Virtual Desktop creates the NIC and its IP configurations. Policy cannot safely add the standard template's optional IPv6 configuration. |
| VM starting index and index padding | Native Session Host Management accepts a VM name prefix but does not expose the standard deployment's starting-index or padding controls. |
| Personal host pools and hibernation | Automated Session Host Management is limited to pooled host pools. Use the standard deployment for personal desktops and their hibernation workflow. |
| GPU extension auto-detection | Bake GPU drivers into the image or supply the required driver installation as an ordered private customization. |

Some differences are deployment-workflow boundaries rather than missing session-host features:

| Standard deployment workflow | Automated deployment workflow |
| --- | --- |
| Create credentials or encryption Key Vaults inline | Select existing RBAC-enabled Key Vaults, typically deployed through Shared Services. |
| Create the complete monitoring stack inline | Select an existing AVD Insights DCR and optional Log Analytics workspace and DCE. |
| Create or select a Recovery Services vault and configure backup | Configure FSLogix Azure Files backup separately through Shared Services and the supported backup workflow. Service-managed pooled VMs are replaceable and are not individually backed up by this deployment. |

See the policy module's [capability matrix](policy/README.md#capability-matrix) and
[complete parity boundary](policy/README.md#complete-parity-boundary) for implementation details.

## Encryption and Storage Network Access

The portal form follows the standard host-pool control layout: Encryption at Host is configured on
the Session Hosts page, while disk and FSLogix storage key management are configured on the Zero
Trust Configuration page. Customer-managed disk encryption deploys a Disk Encryption Set and
customer-managed FSLogix encryption configures the new Azure Files storage accounts. Both use the
same selected existing RBAC-enabled encryption Key Vault and key-rotation period.

Unlike the standard host-pool deployment, the automated deployment does not create an encryption
Key Vault inline. Deploy Shared Services first when customer-managed encryption is required, then
select its encryption Key Vault in the automated host-pool form. An existing Disk Encryption Set
can still be supplied with `diskEncryptionSetResourceId` through Bicep or a parameter file.

For newly deployed FSLogix Azure Files storage, the private endpoint and permitted IP/CIDR controls
produce the same public-access behavior as the standard deployment:

- Private endpoint enabled with no permitted IPs: public network access is disabled.
- Private endpoint enabled with permitted IPs: public access is enabled only for those ranges.
- Private endpoint disabled with permitted IPs: public access is enabled only for those ranges.
- Private endpoint disabled with no permitted IPs: public access is enabled from all networks.

The managed disk network-access control separately deploys policy that disables public network and
export access for session-host managed disks. It does not control FSLogix storage networking.

For persistent OS disks, the portal form exposes the same `diskSizeGB` choices as the standard
host-pool form. The automated deployment uses Azure Policy `Modify` to inject the selected OS disk
size into each VM creation request, and the unified guest configuration expands the Windows
partition after provisioning. For Bicep or parameter-file deployments, leave `diskSizeGB` at `0`
to preserve the image default.

## Ephemeral OS Disks

Set `useEphemeralOsDisk` to `true` and select `CacheDisk` or `ResourceDisk` with
`ephemeralOsDiskPlacement`. The template sends `diffDiskSettings.option: Local` through Session
Host Configuration. During the AVD preview, the portal form displays a read-only Standard SSD OS
disk type and submits `StandardSSD_LRS`; it ignores persistent-disk expansion by submitting
`diskSizeGB` as `0`. The source image OS disk size, plus the 1 GiB VM guest-state reservation for
Trusted Launch or Confidential VMs, must fit the selected VM size's cache or resource-disk
capacity. Data that must survive host replacement belongs in FSLogix or another durable service.

## Dynamic Autoscaling

Provide `avdServicePrincipalObjectId` when `startVMOnConnect` or `deployDynamicScalingPlan` is
enabled. Start VM on Connect assigns Desktop Virtualization Power On Contributor. Dynamic scaling
assigns Desktop Virtualization Power On Off Contributor and Desktop Virtualization Virtual Machine
Contributor.

Set `deployDynamicScalingPlan` to `true` to create a scaling plan. The deployment
creates a preview pooled schedule with `scalingMethod: CreateDeletePowerManage`. Its ramp-up and
ramp-down minimum and maximum host-pool sizes determine how many VMs the service may create and
retain; the capacity thresholds and phase times determine when it scales.

`sessionHostCount` remains the initial capacity provisioned after policy and storage are ready.
After the scaling plan is assigned, its schedule owns ongoing create, delete, start, and stop
decisions. Do not run another scaling script against the same host pool.

## Policy Readiness

Select the desired final `sessionHostCount`. ARM first creates Session Host Management without a
provisioning request, which is the API's zero-host state. It then deploys storage, policy assignments,
and role assignments before updating Session Host Management with the requested host count. Session
Host Management uses `canaryPolicy: Auto` for subsequent image and configuration updates.

Azure Policy assignment propagation is eventually consistent and ARM does not expose a separate
policy-readiness resource. After deployment, verify that the provisioned hosts received the required
policy settings before placing the host pool into production.

The FSLogix storage template remains independently deployable. Automated session-host policy is an
internal part of this deployment and is not published or supported as a separate deployment.
