[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Standard Host Pool**](hostpool-deployment.md) | [**Automated Host Pool**](../deployments/automatedHostPools/README.md) | [**Session Host Replacer**](session-host-replacer.md)

# Choose a Host Pool Management Approach

Azure Virtual Desktop has two host pool management approaches. FederalAVD provides a separate
deployment for each approach:

| FederalAVD deployment | Microsoft management approach | Who manages session-host VMs? |
| --- | --- | --- |
| **AVD Host Pool** (`deployments/hostpools`) | **Standard management** | You manage the VM lifecycle with FederalAVD, your existing automation, or the Session Host Replacer add-on. |
| **AVD Automated Host Pool** (`deployments/automatedHostPools`) | **Session host configuration management** | The Azure Virtual Desktop service creates, updates, scales, and deletes the VMs from a persistent configuration. |

Both deployments create an Azure Virtual Desktop host pool. In this documentation, **standard host
pool** and **automated host pool** distinguish who owns the session-host VM lifecycle; they do not
describe different AVD control-plane resource types.

This is separate from deciding whether hosts are maintained individually or replaced from a
controlled image. A standard host pool supports either operating model:

- **Image-managed fleet:** Treat hosts as replaceable capacity. Publish a new gallery image, then
  replace hosts manually, with existing automation, or with Session Host Replacer.
- **Persistent hosts:** Keep individual VMs for longer periods and update them in place with
  Intune, Configuration Manager, Azure Update Manager, scripts, or another management system.

An automated host pool is always configuration-managed rather than a collection of individually
maintained hosts. Azure Virtual Desktop creates and reconciles hosts from Session Host
Configuration and performs replacement through Session Host Update.

> **Choose before deployment.** Azure Virtual Desktop doesn't support changing the management
> approach of an existing host pool. Moving between approaches requires a new host pool and a
> planned user and application migration.

## Quick Decision

### Choose Pooled or Personal First

Choose **pooled** when users can share session-host capacity, lower cost and higher density are
important, users might connect to a different host each time, or the workload requires RemoteApp.
Store profiles outside the VM with FSLogix and operate the hosts as a consistent fleet.

Choose **personal** when a user needs dedicated VM resources, stronger workload or data separation,
predictable one-to-one assignment, or local state that persists on that user's VM. Personal pools
usually cost more per user and require a standard host pool in FederalAVD.

Do not use job title alone to make this choice. Classify users by application resource demand,
concurrency, profile and local-state requirements, isolation, performance expectations, and whether
applications support multi-session Windows. A heavy user can still use a pooled host when the pool
is sized and isolated appropriately; a dedicated desktop is an architectural requirement, not a
synonym for an important user.

Use these public Microsoft references when recording the decision:

- [Azure Virtual Desktop terminology](https://learn.microsoft.com/azure/virtual-desktop/terminology)
  is the authoritative comparison of pooled and personal host pools, including assignment,
  scaling, updates, profile storage, cost efficiency, and RemoteApp support.
- [Session host VM sizing guidelines](https://learn.microsoft.com/windows-server/remote/remote-desktop-services/session-host-virtual-machine-sizing-guidelines)
  maps light, medium, heavy, and power workloads to single-session and multi-session capacity
  assumptions. Use it as a starting point, then validate with a pilot or workload simulation.
- [Personal desktop assignment](https://learn.microsoft.com/azure/virtual-desktop/configure-host-pool-personal-desktop-assignment-type)
  explains automatic and direct one-to-one assignment and when dedicated resources improve
  resource-intensive workloads.
- [Enterprise-scale support for Azure Virtual Desktop](https://learn.microsoft.com/azure/cloud-adoption-framework/scenarios/azure-virtual-desktop/enterprise-scale-landing-zone)
  is the current Cloud Adoption Framework reference for landing-zone, governance, networking,
  storage, automation, and regional prerequisites. It supplements, but does not replace, the AVD
  product guidance for choosing pooled or personal.

After choosing pooled or personal, choose who owns the VM lifecycle:

Choose a **standard host pool** when any of these statements is true:

- You deploy to Azure Government, Azure Government Secret, or Azure Government Top Secret.
- You need a personal host pool.
- Your organization already manages VMs with pipelines, scripts, Terraform, or other tooling.
- You need direct control of VM creation, naming, extensions, replacement timing, or rollback.
- You need capabilities exposed by the mature FederalAVD host-pool template that aren't available
  through Session Host Configuration.
- You want FederalAVD's **Session Host Replacer** to detect new gallery image versions and perform
  controlled rolling replacement.

Choose an **automated host pool** when all of these statements are true:

- You deploy a pooled host pool in Azure Commercial and accept the preview API dependency.
- You want Azure Virtual Desktop to own creation, update, scaling, and deletion of session hosts.
- A persistent, service-managed VM configuration is preferable to maintaining your own VM
  deployment and replacement automation.
- You can stop using external tools that create, register, replace, or delete VMs in this host pool.

If you are uncertain, use a standard host pool. It supports the broadest cloud and workload set and
preserves direct control. Choose automated management intentionally when reducing customer-owned VM
lifecycle automation is more important than that flexibility.

## Record the Decisions Before Deployment

Complete this record before publishing or deploying the component Template Specs. The answers
determine prerequisites, which forms to publish, deployment order, and the ongoing operating model.

| Decision | Record the answer | Deployment effect |
| --- | --- | --- |
| Target cloud | Commercial, Government, Secret, or Top Secret | Automated host pools are Commercial-only; Secret and Top Secret also require air-gapped dependency planning. |
| Pool type | Pooled or personal | Personal requires a standard host pool. |
| VM lifecycle owner | Azure Virtual Desktop, FederalAVD, or existing customer tooling | Selects the automated or standard host-pool deployment. |
| Host maintenance model | Image-managed replaceable fleet or persistent hosts updated in place | Determines whether recurring image builds and host replacement are part of operations. |
| Image source | Marketplace image, existing Compute Gallery image, or FederalAVD-built image | A FederalAVD-built image requires Image Management and Image Build; an existing image does not. |
| Artifact delivery | No runtime packages, existing artifact source, or FederalAVD Image Management | Image Management can host scripts and installers for session-host customizations without deploying Image Build. |
| Shared resource seed | AVD Shared Services, the first standard Host Pool, or approved existing resources | Step 1 must seed automated credentials and Image Management CMK. For standard-only deployments, the first Step 4 can create shared Key Vaults, monitoring, and FSLogix backup resources for later pools to reuse. |
| FSLogix storage ownership | Host-pool-specific storage, existing storage, or independently deployed shared storage | Step 4 can deploy storage for its host pool or use existing storage. Use the FSLogix Storage add-on before Step 4 when profile storage is shared across host pools. The add-on requires existing Key Vault, monitoring, and backup resources for those selected capabilities. |
| Standard-pool replacement method | Session Host Replacer, manual drain and replace, or existing automation | Session Host Replacer is a post-host-pool add-on; manual and existing automation require an owned runbook or pipeline. |
| Capacity management | Fixed/manual count, AVD power-management scaling, or dynamic create/delete scaling | Dynamic create/delete scaling requires an automated host pool; standard scaling plans start and stop existing VMs. |
| Runtime configuration owner | Image, Intune, policy, configuration management, or FederalAVD customizations | Determines whether software must be baked into the image and which runtime endpoints and identities are required. |
| Existing prerequisites | VNet/subnet, private DNS, Key Vault, Log Analytics, Compute Gallery, and artifact storage | Existing approved services can replace optional FederalAVD Steps 0-2 when their resource IDs and permissions are available. |
| Security requirements | CMK, private endpoints, centralized monitoring, backup, and compliance policy prerequisites | Can make Shared Services and Networking prerequisites even when the image path alone would not require them. |

Use the resulting operating model to select the deployment path:

| Operating model | Deploy initially | Ongoing image or host operation |
| --- | --- | --- |
| Standard + marketplace or existing image + persistent hosts | Standard Host Pool; add prerequisites required by the architecture | Patch and configure hosts with the selected endpoint-management system. Replace manually when required. |
| Standard + custom image + manual replacement | Image Management -> Image Build -> Standard Host Pool | Publish an image, drain hosts, and replace them with the documented manual process. |
| Standard + custom image + Session Host Replacer | Image Management -> Image Build -> Standard Host Pool -> Session Host Replacer | Publish an image version; the replacer performs the controlled rollout. |
| Standard + existing customer automation | Standard Host Pool plus only the image services that automation consumes | The customer pipeline creates, registers, updates, drains, and replaces hosts. |
| Automated + marketplace, existing, or custom image | Shared Services -> Automated Host Pool; add Image Management and Image Build only when FederalAVD must create the image | Update Session Host Configuration and use native Session Host Update. Dynamic autoscale can own initial and ongoing capacity. |

Do not leave the replacement method undecided for an image-managed production fleet. Building a new
image does not update existing session hosts by itself.

## Capability Comparison

| Decision area | Standard host pool | Automated host pool |
| --- | --- | --- |
| Cloud availability | Commercial, Government, Secret, and Top Secret | Commercial only in FederalAVD |
| API status | Generally available APIs | Preview `2025-11-01-preview` API |
| Pool types | Pooled and personal | Pooled only |
| Source of VM configuration | Parameters supplied whenever FederalAVD or another tool deploys VMs | Persistent Session Host Configuration attached to the host pool |
| Add capacity | Deploy VMs and register them with a host-pool registration token | Increase the managed instance count or let dynamic autoscale create VMs |
| Power scaling | AVD power-management scaling plan | AVD power-management or dynamic create/delete/power-manage scaling |
| Image and configuration updates | Replace VMs with your process or Session Host Replacer | Update Session Host Configuration and use native Session Host Update |
| Fleet consistency | Enforced by your deployment pipeline and operational controls | Reconciled by Azure Virtual Desktop from the persistent configuration |
| External VM lifecycle tools | Supported | Not supported for creating, updating, scaling, or deleting managed hosts |
| FederalAVD Session Host Replacer | Supported and recommended for recurring custom-image refresh | Not supported; native Session Host Update owns replacement |
| Air-gapped operation | Supported with pre-staged dependencies | Not supported by the current preview service/API |

## Standard Host Pool with Session Host Replacer

A standard host pool doesn't mean that image lifecycle work must be manual. FederalAVD's
[Session Host Replacer](session-host-replacer.md) is an Azure Function add-on that watches a Compute
Gallery image, drains outdated hosts, deploys replacements, verifies that the new hosts are
available, and then removes or retains the old hosts according to the selected strategy.

Use this combination when you want automation while retaining ownership of the VM lifecycle:

- **SideBySide** creates and validates replacements before removing old hosts. It favors
  availability and can retain old, deallocated hosts temporarily for rollback.
- **DeleteFirst** removes eligible hosts before creating replacements. It reduces temporary cost
  and quota requirements but temporarily reduces capacity.
- Progressive rollout, drain grace periods, image-version detection, device cleanup, and
  multi-cloud support remain under your control.

The replacer can coexist with a standard AVD scaling plan that starts and stops VMs. The scaling
plan controls running capacity; the replacer controls image-driven VM replacement. Don't attach the
replacer or the standalone Session Hosts add-on to an automated host pool because Azure Virtual
Desktop must be the only system managing those VMs.

## Automated Host Pool Lifecycle

An automated host pool stores the desired VM shape in Session Host Configuration: image, VM size,
OS disk, network, identity join, credentials, security profile, location, and related settings.
Session Host Management defines how hosts are created and updated. FederalAVD also deploys internal
policy remediation for settings that the preview configuration doesn't expose.

For ongoing operations:

1. Change the Session Host Configuration when the image or VM configuration changes.
2. Use Session Host Update to roll that desired state across the pool.
3. Optionally use dynamic autoscale with `CreateDeletePowerManage` to let AVD create and delete
  hosts according to schedule and demand. Define one or more named schedules and assign each day
  to at most one schedule, grouping days only when they share the same times and capacity limits.
4. Don't deploy VMs with a registration token or run Session Host Replacer against this pool.

This approach removes the need to operate a separate replacement Function App, but it also moves
the VM lifecycle boundary into the Azure Virtual Desktop service.

## Examples

| Scenario | Recommended approach | Why |
| --- | --- | --- |
| Pooled production workload in Azure Commercial with a standard gallery image and minimal custom lifecycle requirements | Automated | Native configuration, update, and create/delete autoscale reduce customer-operated automation. |
| Pooled regulated workload in Azure Government using recurring custom images | Standard + Session Host Replacer | Automated management isn't available; the replacer provides controlled image rollout. |
| Personal desktops in any cloud | Standard | Session Host Configuration supports pooled host pools only. |
| Existing enterprise VM deployment pipeline with custom extensions and approval gates | Standard | Existing tools retain ownership of creation and replacement. |
| Air-gapped Secret or Top Secret deployment | Standard | The automated preview service and its runtime dependencies aren't available. |
| New Commercial pooled deployment where VM count should expand and contract with demand | Automated + dynamic autoscale | AVD can create, delete, start, and stop hosts from the persistent configuration. |

## Next Steps

- Deploy [a standard host pool](hostpool-deployment.md).
- Deploy [an automated host pool](../deployments/automatedHostPools/README.md).
- Add image lifecycle automation to a standard pool with
  [Session Host Replacer](session-host-replacer.md).
- Review Microsoft's authoritative
  [Host pool management approaches](https://learn.microsoft.com/azure/virtual-desktop/host-pool-management-approaches).
