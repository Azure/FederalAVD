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

## Prerequisites

- An Azure Commercial subscription with the required resource providers registered.
- An existing session-host subnet.
- An RBAC-enabled Key Vault containing `VirtualMachineAdminUserName` and
  `VirtualMachineAdminPassword`. The host-pool identity receives Key Vault Secrets User on this
  vault, and the deployment derives versionless secret URIs from the selected vault.
- For AD DS or Entra Domain Services, the vault must also contain
  `DomainJoinUserPrincipalName` and `DomainJoinUserPassword`.
- When monitoring is enabled, an existing AVD Insights Data Collection Rule and optional Data
  Collection Endpoint.
- When Azure Files private endpoints are enabled, the private DNS zone resource ID.
- Ephemeral OS disks require a VM size whose selected cache or resource disk can hold the image OS
  disk. Ephemeral OS disks are local to the VM and are recreated when Azure Virtual Desktop
  replaces the session host.
- Dynamic autoscaling requires the object ID of the Azure Virtual Desktop service principal. The
  deployment assigns Desktop Virtualization Power On Off Contributor and Desktop Virtualization
  Virtual Machine Contributor at subscription scope.
- Dynamically created session hosts currently require outbound HTTPS access to
  `wvdhpustgr0prod.blob.core.windows.net` so the service can deploy the AVD Agent.

The deploying principal needs permission to create subscription deployments, resource groups,
policy definitions and assignments, managed identities, and role assignments at every referenced
scope.

## Deploy

Copy the starter parameters into the ignored `customer` folder and replace all placeholder values:

```powershell
New-Item -ItemType Directory -Force customer\parameters\automatedHostPools | Out-Null
Copy-Item customer-examples\parameters\automatedHostPools\poc.automatedHostPool.parameters.json `
  customer\parameters\automatedHostPools\myPool.parameters.json

New-AzDeployment `
  -Location eastus `
  -TemplateFile .\deployments\automatedHostPools\automatedHostPool.json `
  -TemplateParameterFile .\customer\parameters\automatedHostPools\myPool.parameters.json `
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
resources. It does not expose or retrieve secret values; the selected Key Vault must use the fixed
secret names listed in Prerequisites.

## Ephemeral OS Disks

Set `useEphemeralOsDisk` to `true` and select `CacheDisk` or `ResourceDisk` with
`ephemeralOsDiskPlacement`. The template sends `diffDiskSettings.option: Local` through Session
Host Configuration while retaining `diskSku` as the managed-disk definition expected by the API.
Verify that every selected VM size supports the placement and has enough local capacity for the
image. Data that must survive host replacement belongs in FSLogix or another durable service.

## Dynamic Autoscaling

Set `deployDynamicScalingPlan` to `true` and provide `avdServicePrincipalObjectId`. The deployment
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
