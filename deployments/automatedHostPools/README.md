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
>
> **First deployment:** Use the Automated Host Pool Template Spec portal form. The guided form
> explains conditional settings, validates compatible choices, and shows how the deployment inputs
> fit together. On **Review + create**, select **Create**. After the deployment is submitted, select
> **Download template and parameters** and save the generated parameter file for repeatable
> PowerShell or CI/CD deployments.

## Deploy

The recommended first-deployment workflow is:

1. Publish the **AVD Shared Services** and **AVD Automated Host Pool** Template Specs with
  `tools\New-TemplateSpecs.ps1`.
2. Deploy Shared Services first when a credentials Key Vault is not already available. Capture its
  `secretsKeyVaultResourceId` output.
3. Open **AVD Automated Host Pool** under **Template Specs** in the Azure portal and select the
  credentials Key Vault, subnet, image, availability model, storage, monitoring, and other optional
  capabilities.
4. On **Review + create**, select **Create**. After the deployment is submitted, select **Download
  template and parameters** and store the generated parameter file under
  `customer\parameters\automatedHostPools\`, which is intentionally excluded from git.
5. Use that validated parameter file for subsequent deployments. Avoid hand-authoring the first
  parameter file unless the Template Spec UI is unavailable.

Publishing a Template Spec makes its guided form available but does not deploy resources. See
[Detailed Deployment Instructions](#detailed-deployment-instructions) for the publication command,
prerequisite deployment, Blue Button fallback, and repeatable PowerShell workflow.

## Deployment Flow

`automatedHostPool.bicep` follows the standard host-pool orchestration model. Independent phases run
in parallel; dependencies exist only where one phase consumes another phase's resource or output:

1. Resolves names and creates the control-plane, session-host, storage, deployment-helper, and
  optional global-feed resource groups.
2. Starts Azure Virtual Desktop service-principal RBAC, the deployment helper, and FSLogix
  customer-managed-key resources as soon as their scopes exist. Independent preparation continues
  while RBAC completes.
3. After service-principal RBAC completes, creates the pooled automated host pool, application
  group, workspace association, AVD Private Link endpoints, optional global-feed workspace, and
  dynamic scaling plan as one control-plane phase.
4. Grants the host-pool managed identity access to the host, network, image, credential-vault, and
  host-pool scopes, then creates `sessionHostConfigurations/default`.
5. Creates `sessionHostManagements/default` without a provisioning request, which is the API's
  zero-host state. The API does not accept an explicit `instanceCount: 0`.
6. In parallel, deploys optional FSLogix storage, registers newly created Azure Files shares with
  an optional existing shared Recovery Services vault and policy, and deploys the policy/RBAC
  required for settings the native service does not expose. Policy definitions, assignments, and
  RBAC are deployed before VM creation; policy evaluation and guest remediation remain
  asynchronous.
7. Updates `sessionHostManagements/default` with the requested `instanceCount` only after the
  zero-host resource, storage-dependent policy inputs, and policy assignments are ready.
8. Removes the temporary deployment helper after final session-host provisioning is submitted.

Shared naming, AVD resources, FSLogix, Key Vault RBAC, and generic role-assignment modules are reused
rather than copied. Resources created by FederalAVD, including FSLogix storage, private endpoints,
customer-managed keys, and Disk Encryption Sets, use the same naming formulas as a standard host
pool with equivalent naming inputs.

For Microsoft Entra joined hosts, application-group assignments grant users access to the desktop.
The additional resource-group-level `Virtual Machine User Login` assignment used by the standard
host-pool deployment is not required for host pools using Session Host Configuration, so the
automated deployment does not create it.

## Portal VM Template Reference

The Azure portal host-pool template calculates the linked VM template from the
`nestedTemplatesLocation` parameter:

```text
vmTemplateUri = nestedTemplatesLocation + vmTemplateName + '.json'
vmTemplateName = 'managedDisks-' + toLower(vmImageType) + 'vm'
```

For the portal template version observed on 2026-08-25, the base URI is:

```text
https://wvd.hosting.portal.azure.net/wvd/Content/1.0.03511.1407/ArmTemplates/AutomatedHostpool/nestedTemplates/
```

The resulting VM template names are:

```text
managedDisks-galleryvm.json
managedDisks-customimagevm.json
```

The Gallery template was downloaded and inspected. It creates managed-disk session-host VMs,
network interfaces, the AVD DSC extension, and an optional post-deployment
`Microsoft.Compute/virtualMachines/extensions` resource using `CustomScriptExtension`.
The extension downloads the script specified by `customConfigurationScriptUrl` and runs it with
PowerShell. This is the portal's documented Custom Configuration pattern.

The portal template passes a public HTTPS artifact location to the extension. Microsoft's related
`RDS-Templates` sample likewise states that its JSON and PowerShell files must be stored in a
publicly accessible location, such as a public GitHub repository or public Azure Blob container:

<https://github.com/Azure/RDS-Templates/tree/master/wvd-sh/arm-template-customization>

This reference confirms that VM extension resources are supported by the portal's linked ARM
template pattern. It does not by itself prove that every resource type, private blob endpoint,
SAS-only URL, or `Microsoft.Compute/virtualMachines/runCommands` is supported by the newer
Session Host Configuration `customConfigurationScriptUrl` property. Those behaviors require a
controlled automated-host-pool test before being used for production scale-out readiness.

## Resource Group Placement

The portal form does not ask for resource group names. Like the standard host-pool deployment in
this repository, the automated deployment derives them from the selected naming convention:

- When creating a workspace, the host pool, application group, and workspace are deployed to the
  generated control-plane resource group. When reusing a workspace, its resource group is reused
  for the host pool and application group. Set `existingFeedWorkspaceResourceId` to the existing
  workspace resource ID for direct deployments.
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
- When VM Applications are enabled, existing application versions in an Azure Compute Gallery.
  Each selected version must be replicated to the session-host region. Azure supports at most 25
  VM Applications per VM, one version of each application, 2 GB per application package, and 50 GB
  total across all application packages. FederalAVD artifact ZIPs can be published with the
  [VM Application publishing workflow](../../docs/vm-applications.md) before this deployment.
- When Azure Files private endpoints are enabled, the private DNS zone resource ID.
- To register newly deployed FSLogix Azure Files shares for backup, an existing Recovery Services
  vault and Azure Files snapshot backup policy in the session-host region. Shared Services can
  create both and outputs `fslogixBackupVaultResourceId` and `fslogixBackupPolicyName`.
- AVD Private Link requires endpoint subnets for each selected route. Optional automatic DNS
  integration uses `privatelink.wvd.microsoft.com` and, for initial discovery, the cloud's
  `privatelink-global.wvd.microsoft.com` private DNS zone.
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
scope. Backup registration also requires permission to register the storage accounts and create
protected items in the selected Recovery Services vault.

## Identities and RBAC

The deployment uses three identities for different operations:

| Identity | Role and scope | When assigned |
| --- | --- | --- |
| Host-pool managed identity | Desktop Virtualization Virtual Machine Contributor on the session-host resource group, network resource group, selected image resource group, and host pool | Always; the image scope is added only for a Compute Gallery image |
| Host-pool managed identity | Key Vault Secrets User on the credentials Key Vault | Always |
| Azure Virtual Desktop enterprise application | Desktop Virtualization Power On Contributor, or Power On Off Contributor plus Desktop Virtualization Virtual Machine Contributor, at subscription scope | Start VM on Connect or dynamic autoscaling, respectively |
| Azure Virtual Desktop enterprise application | Key Vault Secrets User on the credentials Key Vault | Dynamic autoscaling only, for session hosts created by the scaling plan |
| Host-pool managed identity and Azure Virtual Desktop enterprise application | Reader on the selected Disk Encryption Set | Host-pool identity whenever a DES is selected; enterprise application additionally when dynamic autoscaling is enabled |
| Policy user-assigned identity | VM, network, tag, monitoring, managed-identity, and disk permissions required by the enabled post-provisioning policies | Always created; optional permissions are assigned only when their features are enabled |

The host-pool managed identity is what Azure Virtual Desktop uses for Session Host Management
operations and their credential secrets. It is required even when no scaling plan is deployed.
The tested create/delete autoscale path submitted its Compute VM creation request as this same
host-pool managed identity. The Azure Virtual Desktop enterprise application still requires the
documented scaling-plan orchestration roles, and the deployment grants its dynamic-scaling access
before the plan is enabled.

## Session Host Configuration Script

The automated-host-pool policy uses
`scripts/Initialize-SessionHost.ps1`. This deployment-owned script configures the time zone,
FSLogix, local policy, Defender exclusions, and OS partition expansion. It does not install or
register the AVD Agent because Azure Virtual Desktop performs agent provisioning for automated
session hosts. The directly managed host-pool solutions continue to use the shared initializer,
which includes AVD Agent installation and registration.

## Detailed Deployment Instructions

An automated host pool always requires a pre-existing credentials Key Vault. The preferred path for
every first deployment is the Template Spec portal UI. Its resource pickers, conditional fields,
and validation guide the administrator to a working deployment and produce the parameter file used
for subsequent PowerShell or CI/CD deployments. Do not start a first deployment by hand-authoring a
parameter file unless the Template Spec UI is unavailable.

> **Application delivery:** Prefer Compute Gallery VM Applications for software that has meaningful
> install and remove behavior. Use Session Host Customizations for provisioning-time configuration,
> bootstrap actions, or a documented exception that cannot use the VM Application lifecycle. Bake
> software into the image when it must be ready before user logon.

### First Deployment: Template Spec Portal Forms

From the repository root, connect to the target Azure Commercial subscription and publish the
Shared Services and automated host-pool Template Specs:

```powershell
Connect-AzAccount
Set-AzContext -Subscription '<subscription-id>'

.\tools\New-TemplateSpecs.ps1 `
  -Location '<region>' `
  -createSharedServices $true `
  -createNetwork $false `
  -createImageManagement $false `
  -createCustomImage $false `
  -createHostPool $false `
  -createAutomatedHostPool $true `
  -CreateAddOns $false
```

Publishing makes the guided forms available; it does not deploy either workload. In the Azure
portal, open **Template Specs** and deploy them in this order:

1. Deploy **AVD Shared Services** with the Secrets Key Vault enabled. On the form's credentials
  step, supply the VM administrator credentials and any domain-join credentials required by the
  selected join type.
2. Deploy **AVD Automated Host Pool**. Select the credentials Key Vault created in step 1, then
  select the existing subnet, image, and any optional monitoring, encryption, backup, or private
  endpoint resources.
3. On **Review + create**, select **Create**. After the deployment is submitted, select **Download
  template and parameters** and save the generated automated-host-pool parameter file under
  `customer\parameters\automatedHostPools\`; this folder is intentionally excluded from git.

The automated Template Spec is opt-in because the preview resource API is available only in Azure
Commercial. The form uses the default secret names listed in Prerequisites unless **Customize
credential secret names** is selected. Optional picker overrides submit the selected versionless
secret URI and never retrieve secret values. The deploying user needs Key Vault Reader on the
credentials vault and browser-side data-plane network access to list secret metadata. Users who
cannot reach the vault can leave the overrides disabled and use the default names.

### Blue Button (Azure Commercial Alternative)

Use this only when publishing a Template Spec is not practical. The Template Spec portal form
remains the preferred path for every first deployment because it provides a durable, versioned form
and a working parameter file for later automation.

[![Deploy to Azure](../../docs/images/deploytoazurebutton.png)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FautomatedHostPools%2FautomatedHostPool.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FFederalAVD%2Fmain%2Fdeployments%2FautomatedHostPools%2FuiFormDefinition.json)

The button targets files on the repository's `main` branch and becomes usable after this automated
host-pool feature is merged. There is no Azure Government button because the required preview API
is available only in Azure Commercial.

### Subsequent Deployments: PowerShell or CI/CD

Use the working parameter files exported from the Template Spec forms as the inputs for repeatable
deployments. Supply credentials at deployment time; do not add them to the parameter file. The
following commands also document the direct deployment sequence for environments where the
Template Spec UI is unavailable:

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

To register newly deployed FSLogix Azure Files shares for snapshot backup, set
`deployFSLogixBackupVault` to `true` in the Shared Services parameters and capture its additional
outputs:

```powershell
$fslogixBackupVaultResourceId = $sharedServicesDeployment.Outputs.fslogixBackupVaultResourceId.Value
$fslogixBackupPolicyName = $sharedServicesDeployment.Outputs.fslogixBackupPolicyName.Value
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
  -existingFilesBackupVaultResourceId $fslogixBackupVaultResourceId `
  -existingFilesBackupPolicyName $fslogixBackupPolicyName `
  -Verbose
```

Omit the two backup parameters when the Shared Services backup vault is not deployed. Backup
registration applies only to newly deployed Azure Files storage; existing storage selected for
FSLogix configuration is not modified by this deployment.

The Template Spec form and direct deployment expose the same resource selections. Network
selection is limited to the virtual network and subnet so subnet-level NSG configuration remains
authoritative. Both methods can select an existing shared Recovery Services vault and identify its
Azure Files snapshot backup policy.

Azure Files share soft delete and Azure Backup retention are separate. Soft delete retains an
accidentally deleted share for 14 days by default. The shared snapshot policy retains scheduled
recovery points according to `fslogixBackupRetentionDays`, which defaults to 30 days. Because the
current policy uses snapshot-tier backup, recovery-point data remains in the source storage account;
backup retention does not extend the period in which a deleted share can be undeleted.

The Template Spec form and entry template default newly deployed FSLogix storage to **Azure Files
Premium**. Direct deployments can select another supported service and SKU with the
`fslogixStorageService` parameter.

## Session Host Availability

Automated host pools support Availability Zones when the selected VM SKU exposes zones in the
session-host region. Where Availability Zones are unavailable or unsuitable, select **Availability
Set** to create one managed Availability Set in the dedicated session-host resource group. The
deployment uses one resource-group-scoped Azure Policy `Modify` assignment to add that set before the Compute
resource provider processes each VM creation request.

The `Modify` evaluation does not submit that creation request as the policy assignment's
user-assigned identity. Azure Policy rewrites the in-flight request, and the principal that
submitted the VM request remains the caller. Live validation showed both initial Session Host
Management and create/delete autoscale VM creation using the host-pool managed identity. The policy
identity is used for remediation operations, not creation-time request mutation. The VM-creation
principal therefore needs access to every resource referenced by the resulting VM request.

Availability Zones and managed Availability Sets are mutually exclusive. Azure supports at most 200
VMs in one Availability Set. Session Host Update creates each replacement before deleting its
original VM, so the deployment requires the initial `sessionHostCount`, or the largest ramp-up or
ramp-down maximum from dynamic scaling schedules, plus `updateMaxVmsRemoved` to be no greater than
200. For example, the default update batch of one permits at most 199 active hosts. Availability Sets
also require `deleteOriginalVm: true`; otherwise retained original VMs permanently consume set
capacity. Failed VMs retained by `failedSessionHostCleanupPolicy` consume capacity as well and should
be included in operational headroom. The policy uses a `deny` conflict effect because Availability Set
membership is immutable after VM creation; requests where Azure cannot apply the set fail instead of
silently creating a host outside it. When required capacity exceeds 200 VMs, continue using the
automated host pool and select Availability Zones when supported, or select no infrastructure
redundancy. Availability Set capacity alone does not require switching to a standard host pool.

## Feature Parity with Standard Host Pools

The automated deployment uses Session Host Configuration for native VM creation and Azure Policy
for supported settings that the preview API does not expose. The following standard host-pool
capabilities are therefore available and are not feature gaps:

| Capability | Automated implementation |
| --- | --- |
| Availability Sets | Creates one managed Availability Set and uses a creation-time `Modify` policy assignment to place every host in it. The configured maximum plus update batch must not exceed 200. |
| OS disk size and guest partition expansion | Policy modifies the VM creation request and the unified guest configuration expands the Windows partition. |
| Encryption at host and accelerated networking | Policy modifies the VM or NIC creation request. The portal form capability-gates accelerated networking against the selected VM size and gallery image. |
| Guest Attestation integrity monitoring | Policy deploys the Guest Attestation extension for Trusted Launch and Confidential VMs. |
| AVD Insights monitoring | Policy deploys Azure Monitor Agent and associates the selected DCR and optional DCE. |
| FSLogix configuration and storage | The deployment composes the shared FSLogix module before host creation, then policy configures the session hosts. |
| FSLogix Azure Files backup registration | Newly deployed shares can be registered with an existing shared-services Recovery Services vault and Azure Files snapshot backup policy. |
| Disk Encryption Set and managed-disk network isolation | The DES is created before the temporary deployment helper and directly encrypts its OS disk. Policy injects the same DES into service-created session hosts and disables managed-disk public and export access when selected. |
| Ordered private customizations | Policy attaches the artifact identity and runs provisioning-time configuration or bootstrap actions from the private artifact source in input order. This is not the preferred path for independently installable applications. |
| Compute Gallery VM Applications | Preferred runtime delivery for software with an independent lifecycle. Select up to 25 Gallery application version references and their installation order. References can pin a specific version or use `latest`. One resource-group-scoped policy assignment maintains the complete ordered array on every session host. |

The remaining feature parity gaps are explicit boundaries of the automated management model:

| Standard host-pool capability | Automated-host boundary or alternative |
| --- | --- |
| Azure Dedicated Hosts | The preview API does not expose dedicated host or host-group placement. Use the standard host-pool deployment when physical host isolation is required. |
| IPv6 NIC configuration | Azure Virtual Desktop creates the NIC and its IP configurations. Policy cannot safely add the standard template's optional IPv6 configuration. |
| Session-host VM, OS disk, and NIC naming | Native Session Host Management accepts only a VM name prefix. Azure Virtual Desktop owns the resulting VM, OS disk, and NIC names, so the standard deployment's `SHNAME` naming patterns, starting index, and index padding cannot be applied. FederalAVD-created supporting resources still use the shared naming module. |
| Personal host pools and hibernation | Automated Session Host Management is limited to pooled host pools. Use the standard deployment for personal desktops and their hibernation workflow. |
| GPU extension auto-detection | Bake GPU drivers into the image or supply the required driver installation as an ordered private customization. |

Some differences are deployment-workflow boundaries rather than missing session-host features:

| Standard deployment workflow | Automated deployment workflow |
| --- | --- |
| Create credentials or encryption Key Vaults inline | Select existing RBAC-enabled Key Vaults, typically deployed through Shared Services. |
| Create the complete monitoring stack inline | Select an existing AVD Insights DCR and optional Log Analytics workspace and DCE. |
| Create or select a Recovery Services vault and configure backup | Deploy the shared FSLogix vault and policy through Shared Services, then select them in the automated host-pool form to register newly deployed shares. Service-managed pooled VMs are replaceable and are not individually backed up by this deployment. |

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

AVD Private Link is configured separately from PaaS private endpoints. The automated deployment
supports the same route choices as the standard host pool:

- `HostPool`: private remote-session connections through the host-pool `connection` endpoint.
- `FeedAndHostPool`: adds the workspace `feed` endpoint for private feed download.
- `All`: adds or reuses the single global-feed workspace and its `global` endpoint for private
  initial feed discovery.

Host-pool and workspace public network access remain explicit controls. Private DNS-zone groups are
created when DNS integration is enabled; otherwise DNS records must be managed separately.

The managed disk network-access control separately deploys policy that disables public network and
export access for session-host managed disks. It does not control FSLogix storage networking.

For persistent OS disks, the portal form exposes the same `diskSizeGB` choices as the standard
host-pool form. The automated deployment uses Azure Policy `Modify` to inject the selected OS disk
size into each VM creation request, and the unified guest configuration expands the Windows
partition after provisioning. For Bicep or parameter-file deployments, leave `diskSizeGB` at `0`
to preserve the image default.

## Image Versions

Marketplace images require a concrete `imageVersion`. The Session Host Configuration API uses
`marketplaceInfo.exactVersion` and does not accept the `latest` sentinel supported by ordinary VM
image references. The portal form lists the versions available for the selected region, publisher,
offer, and SKU. Parameter-file deployments must provide one of those regional versions.

Compute Gallery images continue to use the selected gallery image-version resource ID.

## Ephemeral OS Disks

Set `useEphemeralOsDisk` to `true` and select `CacheDisk` or `TempDisk` with
`ephemeralOsDiskPlacement`. The Compute SKU capability reports temporary-disk support as
`ResourceDisk`, but the AVD Session Host Configuration API requires `TempDisk`; the portal form
performs this translation. The template sends `diffDiskSettings.option: Local` through Session Host
Configuration. During the AVD preview, the portal form displays a read-only Standard SSD OS disk
type and submits `StandardSSD_LRS`; it ignores persistent-disk expansion by submitting
`diskSizeGB` as `0`. The source image OS disk size, plus the 1 GiB VM guest-state reservation for
Trusted Launch or Confidential VMs, must fit the selected VM size's cache or resource-disk
capacity. Data that must survive host replacement belongs in FSLogix or another durable service.

Ephemeral OS disk session hosts cannot be deallocated. Autoscaling is optional. This solution only
offers dynamic create/delete autoscaling and does not offer a power-management-only scaling-plan
selection. Do not attach a separate power-management-only scaling plan to the host pool. If dynamic
autoscaling is used, follow Microsoft's
[Dynamic Autoscaling recommendations for ephemeral OS disks](https://learn.microsoft.com/en-us/azure/virtual-desktop/deploy/session-hosts/ephemeral-os-disks?tabs=portal#dynamic-autoscaling-recommendations):
set `deployDynamicScalingPlan` to `true`, and set both `rampUpMinimumHostsPct` and
`rampDownMinimumHostsPct` to `100` in every `dynamicScalingSchedules` entry. Together, those two
schedule settings keep the minimum percentage of active hosts at 100% in every phase, making
autoscale create and delete hosts instead of attempting to start and deallocate them.

## Dynamic Autoscaling

Provide `avdServicePrincipalObjectId` for the Azure/Windows Virtual Desktop application (application
ID `9cdead84-a844-4324-93f2-b2e6bb768d07`) when `startVMOnConnect` or
`deployDynamicScalingPlan` is enabled. Start VM on Connect assigns Desktop Virtualization Power On
Contributor. Dynamic scaling assigns Desktop Virtualization Power On Off Contributor and Desktop
Virtualization Virtual Machine Contributor.

When Disk Encryption Set enforcement is enabled, the host pool permissions deployment assigns
Reader on the selected Disk Encryption Set to the automated host pool's system-assigned identity.
When dynamic scaling is also enabled, the current deployment additionally grants the same
resource-scoped role to the Azure Virtual Desktop enterprise application. These assignments
complete before Session Host Configuration and the later request that creates the initial VMs.

Subscription-scoped Azure Virtual Desktop roles remain conditional. If dynamic scaling is added
later, redeploy this template with `deployDynamicScalingPlan` enabled so its VM, power-management,
credential-secret, and optional Disk Encryption Set permissions are granted before the scaling plan
is created. Pregranting those subscription roles for an unused future feature would violate least
privilege.

Set `deployDynamicScalingPlan` to `true` to create a scaling plan. The deployment
creates preview pooled schedules with `scalingMethod: CreateDeletePowerManage`. Each
`dynamicScalingSchedules` entry is one complete schedule and owns its selected weekdays, phase
times, load-balancing algorithms, capacity thresholds, create/delete minimum and maximum host-pool
sizes, and ramp-down behavior. Schedule names are case-insensitively unique, and a weekday can
belong to only one schedule.

The `CreateDeletePowerManage` API method can perform both capacity and power operations. Setting
the minimum active-host percentage to 100% in every phase is what prevents the plan from trying to
deallocate ephemeral OS disk hosts and limits its capacity changes to creating and deleting hosts.

Ramp-down force logoff, wait time, notification message, and stop condition are schedule-specific
and apply during that schedule's ramp-down phase. The wait and notification fields are required in
the portal only when force logoff is enabled. Editable Grid placeholders do not populate row
properties, so the template normalizes intentionally omitted dropdown values to the displayed
behavior: `BreadthFirst` during ramp-up and peak, `DepthFirst` during ramp-down and off-peak, no
forced logoff, and `ZeroSessions` for the ramp-down stop condition. If force logoff is enabled and
its dependent fields are omitted in a direct deployment, the template uses a 30-minute wait and
"Save your work and sign out. This session host is being removed by autoscale." When force logoff
is disabled, the template submits a zero-minute wait and an empty notification message. The
template does not create a schedule; schedule names, weekdays, times, percentages, and host-count
limits remain required.

The deployment creates the scaling plan and schedules in a disabled state during control-plane setup,
then enables the host-pool assignment after the policy propagation wait. No separate initial
Session Host Management provisioning request is submitted when dynamic scaling is enabled. The
active schedule owns both initial and ongoing create, delete, start, and stop decisions.
`sessionHostCount` applies only when dynamic scaling is disabled. Do not run another scaling script
against the same host pool.

Session Host Management and the scaling plan update different parts of the automated host pool:

1. Session Host Management stores the VM configuration and performs initial provisioning, image
  updates, and configuration updates. The deployment first creates it without a `provisioning`
  block, which establishes the zero-host preparation state.
2. The scaling plan and its schedules are created with the host-pool reference disabled, so they
  cannot change capacity during policy setup or initial provisioning.
3. After the policy wait, the deployment enables the scaling-plan host-pool reference. The active
  schedule then establishes initial capacity and owns ongoing capacity within its configured minimum
  and maximum sizes.
4. When dynamic scaling is disabled, the deployment instead updates Session Host Management with
  `sessionHostCount` after the policy wait.

The deployment grants the Azure Virtual Desktop enterprise application Key Vault Secrets User on
the credentials vault before the scaling plan is activated. This allows schedule-driven create and
replacement operations to resolve the configured administrator and domain credential secret URIs.

## Policy Readiness

When dynamic scaling is disabled, select the desired initial `sessionHostCount`. ARM first creates
Session Host Management without a provisioning request, which is the API's zero-host state. It then
deploys storage, policy assignments, and role assignments. A Run Command on the deployment helper VM
waits five minutes for Azure Policy and role assignments to propagate before ARM updates Session Host
Management with the requested host count. When dynamic scaling is enabled, the deployment activates
the scaling plan after the same policy wait and the active schedule determines initial capacity.
Session Host Management uses `canaryPolicy: Auto` for subsequent image and configuration updates.

Azure Policy assignment propagation is eventually consistent and ARM does not expose a separate
policy-readiness resource. The five-minute delay reduces the chance that initial hosts are created
before the assignments are effective, but it is not a policy-compliance probe. After deployment,
verify that the provisioned hosts received the required policy settings before placing the host pool
into production.

The optional VM Applications policy uses one assignment to own the complete ordered
`applicationProfile.galleryApplications` array. Updating the selected list can add, remove, reorder,
or replace application versions. It also replaces VM Applications added manually or by another
tool, so do not use another owner for this property in the dedicated session-host resource group.
The deployment does not publish applications or create policy remediation tasks. New hosts receive
the array during creation; run an Azure Policy remediation task or update an existing VM to apply a
changed list to existing hosts. Application installation remains asynchronous, so verify extension
state and application readiness before admitting users.

### Logon Availability And Asynchronous Configuration

> **Warning:** A successful automated-host-pool deployment, a successfully provisioned VM, or an
> AVD session host with status `Available` does not prove that post-provisioning Azure Policy has
> finished. `DeployIfNotExists` evaluation, identity attachment, Run Command creation, artifact
> download, and guest execution occur asynchronously for each host. A user can therefore be routed
> to a new host before its policy-deployed configuration and private customizations complete.

Private customizations run serially in the order supplied, but that ordering applies only after
Azure Policy starts the nested deployment on a host. It does not block AVD registration or user
logon, and hosts created together can reach the same customization at different times. ARM
deployment success confirms that the host-pool configuration and policy infrastructure were
submitted successfully; it is not a fleet-readiness signal.

Use private customizations for provisioning-time configuration, bootstrap actions, and documented
exceptions that cannot use a VM Application lifecycle. Do not use them as the default software
deployment mechanism. Independently installable software should provide meaningful install and
remove behavior and be published as a VM Application. Any remaining customization must tolerate a
short convergence window and have a clearly defined failure or retry procedure.

[Azure VM Applications](https://learn.microsoft.com/azure/virtual-machines/vm-applications) are
the preferred automated-host-pool mechanism for software that should remain outside the base image
and can be installed and removed independently. Publish a versioned package
to Azure Compute Gallery, then assign it to an existing VM through the VM's **Extensions +
applications** page, Azure CLI, PowerShell, REST, or ARM. VM Applications support install, update,
and remove commands, application ordering, regional package replication, and per-VM deployment
status. They provide explicit versioning and removal behavior without requiring a new image version.

Treat a direct VM Application assignment as instance-specific on an automated host pool. It does
not update Session Host Configuration, automatically target later autoscale hosts, or survive VM
replacement as an intended fleet declaration. Use Azure Policy or owned automation when every
current and future host must receive the VM Application, and validate that workflow against the
service-managed VM lifecycle. VM Application installation is also asynchronous. Setting
`treatFailureAsDeploymentFailure` reports installation failure through VM provisioning, but it does
not by itself prove that AVD will withhold the host from user routing. Apply the same readiness and
access controls used for private customizations when the application is required before logon.

### Publish and Assign FederalAVD Artifacts as VM Applications

FederalAVD can publish selected artifact ZIPs as Azure Compute Gallery VM Applications. Publication
remains separate from host-pool deployment so uploading an artifact cannot silently make it an
assigned application:

1. Run `Update-ImageArtifacts.ps1` to package and upload the artifact ZIP.
2. Declare the package, immutable version, lifecycle commands, and replication regions in
   `customer/parameters/imageManagement/vmApplications.json`.
3. Run `Publish-VMApplications.ps1`. It creates only the declared Gallery application definitions
   and versions, uses the Image Management identity for private blob access, waits for regional
   replication, and returns each application-version `packageReferenceId`.
4. Add those IDs to the automated host pool's ordered `sessionHostVmApplications` parameter and
  redeploy this solution. To track the newest eligible version, replace the final semantic version
  with `latest`, for example `<applicationResourceId>/versions/latest`. The portal form offers both
  specific versions and `latest` for each application.
5. Create an intentional Azure Policy remediation task or update existing VMs after changing the
  assignment or publishing a newer version selected through `latest`. Future hosts receive the
  policy-owned declaration during creation.

```powershell
$publishedApplications = .\deployments\Publish-VMApplications.ps1 `
    -ManifestPath '.\customer\parameters\imageManagement\vmApplications.json' `
    -GalleryResourceId '<computeGalleryResourceId>' `
    -StorageAccountResourceId '<artifactsStorageAccountResourceId>'
```

The host-pool deployment does not run the publisher and the publisher does not update
`sessionHostVmApplications`. Keep these as distinct pipeline approval stages: package, publish,
then assign. See the [end-to-end automation guide](../../docs/automation-guide.md#optional-step-3a-publish-vm-applications)
and [host-pool management strategy](../../docs/host-pool-management.md#choose-application-delivery-separately)
for the complete operating model.

Configuration-only artifacts and packages without meaningful uninstall behavior should remain
image-build or private-customization artifacts unless their VM Application lifecycle is explicitly
defined.

Do not make a critical logon prerequisite depend only on asynchronous customization unless another
control prevents user access until configuration is verified. Examples include profile-container
access, security controls required before user access, authentication dependencies, and software
without which the assigned workload cannot function.

FSLogix illustrates this boundary. This deployment provisions FSLogix storage before host creation,
but the session-host registry configuration is applied later by a policy-deployed Run Command. A
user who reaches a host before that command succeeds can encounter a blocked or inconsistent logon.
After the policy applies, this solution enables FSLogix `PreventLoginWithFailure` and
`PreventLoginWithTempProfile`, so a profile attachment failure blocks logon instead of falling back
to a temporary or local profile. Those settings protect profile integrity, but they do not prevent
an early connection attempt before asynchronous FSLogix configuration has converged.

For production environments, consider managing FSLogix and similarly critical settings through
Intune or another continuously enforced configuration-management platform. Bake stable
prerequisites into the image when practical. Intune is also asynchronous, so align device
enrollment, compliance, application assignment, and access controls with the organization's host
readiness process rather than assuming enrollment alone blocks logon.

Before enabling broad user access or treating newly created capacity as ready:

1. Confirm every expected session host is registered and healthy in AVD.
2. Confirm the relevant policy assignments report each host compliant.
3. Confirm `ConfigureSessionHost` and every required private-customization Run Command completed
  successfully on each host.
4. Review `C:\Windows\Logs\<customization-name>.log` for artifact or guest-configuration failures.
5. Define monitoring and an operational response for hosts that remain noncompliant, fail a Run
  Command, or become available before configuration converges.

The FSLogix storage template remains independently deployable. Automated session-host policy is an
internal part of this deployment and is not published or supported as a separate deployment.
