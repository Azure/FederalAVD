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

> **Choose before deployment.** Azure Virtual Desktop doesn't support changing the management
> approach of an existing host pool. Moving between approaches requires a new host pool and a
> planned user and application migration.

## Quick Decision

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
   hosts according to schedule and demand.
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
