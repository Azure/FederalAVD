[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Add-Ons**](add-ons.md) | [**Host Pool Management**](host-pool-management.md) | [**Automation**](automation-guide.md)

# Session Host Replacer Add-On

**The Session Host Replacer (SHR) automates moving an Azure Virtual Desktop host pool onto a newer
desktop image.** After you build and test an image - for example, with monthly Windows and
application updates - it replaces session-host VMs running the previous image with new VMs built
from that image. It does not build the image, patch the existing machines or rebuild the host pool.

The challenge is replacing machines people are using without removing too much desktop capacity
at once. SHR works through the fleet in limited batches, manages session draining and user
notifications, checks replacement readiness, and tracks deployment and cleanup through completion.

**Use it only with standard-management host pools.** Automated host pools use native Session
Host Update instead. Deploy one replacer per host pool; never run two against the same pool.
See [Choose a Host Pool Management Approach](host-pool-management.md).

## The Design in One Minute

Replacing a desktop VM affects both the people using it and the capacity available to everyone
else. SHR manages that transition in small, checked batches rather than replacing the fleet at once:

1. **Find hosts that need the new image.** SHR checks image eligibility and identifies participating
   hosts that need replacement. Each rollout stays on one exact image version.
2. **Replace a limited number at a time.** With SideBySide, SHR creates and checks new hosts before
   retiring old ones. With DeleteFirst, it removes a capacity-safe group first and reuses their names
   for replacements, avoiding the need to run both generations together.
3. **Manage users and available capacity.** Old hosts stop accepting new sessions, users receive
   notifications, and existing sessions get the configured time to finish. Readiness and capacity
   checks control when hosts can be removed and when replacement can advance.
4. **Verify and finish the transition.** SHR checks replacement registration and readiness, returns
   validated hosts to autoscale, and completes old-host and required device-record cleanup. It saves
   progress so a restart or failed deployment does not lose track of hosts still needing recovery.

**SideBySide creates replacements before retiring old hosts**, requiring temporary extra capacity.
**DeleteFirst removes a capacity-safe batch before recreating it**, conserving resources but
temporarily reducing capacity. Neither guarantees uninterrupted sessions or proves that the new
image's applications work. Image approval, batch sizes and session-grace settings remain deliberate
operator decisions.

## Choose the Capacity Trade-Off

| | SideBySide | DeleteFirst |
| --- | --- | --- |
| Order | Deploy and validate replacements, then retire old hosts | Retire a capacity-safe batch, then replace it |
| Temporary resources | Up to twice the target host count; plan subnet space, quota and cost | Avoids pool doubling, but temporarily reduces capacity |
| Hostnames | Uses available names; does not preserve old-to-new names | Reuses exact names and dedicated-host placement |
| Availability protection | Readiness and online-capacity gates before retirement | Online-capacity floor and recovery gates before further deletion |
| Rollback | Optional retention of deallocated old hosts | No shutdown-retention rollback |
| Best fit | Availability-first deployments with spare capacity | Constrained resources or exact-name replacement |

Neither mode guarantees uninterrupted sessions or application correctness. Normal replacement
drains hosts, notifies users, and observes minimum-drain and session-grace settings. **A grace
period is not indefinite protection:** an old host can be removed after it expires even if sessions
remain. Choose those settings as an explicit user-impact decision.

In SideBySide, a later scheduled batch can deploy after earlier replacements are ready and handed
back to autoscale, while their old hosts continue draining. Long drains therefore need not stall
all new deployment. Batch limits and the twice-target ceiling still apply.

DeleteFirst will not start another destructive batch while earlier replacements remain unresolved.
It preserves at least one online healthy host, so normal exact-name replacement is blocked for a
one-host target. New destructive batches also pause during the 60 minutes before RampUp, RampUp,
and Peak. Recovery already in flight continues.

### One-Time Maintenance Override

An existing DeleteFirst replacer can accept a separately authorized request for an exact image
and UTC window. This is not a third deployment mode. It requires autoscale to be disabled and
explicit forced-sign-out permission; a one-host or zero-capacity batch also requires full-outage
permission.

SHR notifies sessions, waits the configured delay, calls AVD logoff, verifies zero sessions, then
replaces the batch with the same names. No new destructive batch starts after the window closes;
recovery of already draining or deleted hosts continues. Normal replacement resumes after the
request completes or expires.

Use the [maintenance scheduling form](../deployments/add-ons/sessionHostMaintenance/README.md)
or the [guarded PowerShell command](../deployments/add-ons/sessionHostReplacer/Start-SessionHostMaintenanceReplacement.ps1).
Do not redeploy SHR while a request is active.

## Why the Rollout Is Guarded

| Design concern | Safeguard |
| --- | --- |
| A published image is not necessarily ready | Image eligibility includes replication, exclusion, rollout-age and rollback rules. The selected version stays pinned. |
| A successful ARM deployment is not a usable desktop | Registration and exact-image readiness checks gate progress; availability, health, power state and session acceptance are evaluated as applicable to scaling state. |
| Replacing too much at once increases risk | Mode-specific batch ceilings, optional progressive scale-up, capacity floors and a live regional gallery-replica ceiling constrain planning. The replica ceiling is per pool, not a shared reservation. |
| Autoscale and replacement can compete | SHR protects work with its own scaling exclusions, preserves administrator-owned exclusions and hands validated hosts back to autoscale. |
| Reusing a name can collide with old resources | VM, AVD registration and required directory cleanup must be verified before deployment. Failed or ambiguous reads block reuse. |
| A restart must not lose deleted-host recovery | Deployment intent and pending-name mappings are checkpointed. Later invocations reconcile accepted deployments instead of blindly submitting duplicates. |
| An unsafe operation should stop visibly | Deadline, protected-configuration or unrecoverable failures can stop the operation as `NeedsAttention`; checked recovery is required. |

Native Entra joined hosts require Entra cleanup, and Intune cleanup when enrolled. Directory
cleanup remains optional for AD DS and hybrid-joined machines. Required Graph permissions must
be granted before rollout; cleanup is not merely best effort when hostname safety depends on it.

These are infrastructure safeguards, **not an image acceptance test**. Validate applications,
sign-in, profiles and user experience in a representative pilot pool before production promotion.
The [Monthly Image Operations guide](monthly-image-operations.md) owns that release workflow.

## What Operators See

When a Log Analytics workspace is supplied, the deployment creates workspace-based Application
Insights for the Function App. Function telemetry goes through Application Insights; SHR does
not create the separate Function App diagnostic setting that collects `FunctionAppLogs`.
The optional shared workbook queries the primary workload workspace directly, filtering its
Application Insights telemetry by component IDs automatically discovered for the selected host
pool. Operators choose **Host Pool** and **Time Range**; no Application Insights selection is
required. Discovery uses the components' `cm-resource-parent` tags, so native idle invocations
can be mapped without recent SHR application messages. Central policy exports are unchanged.
Its default **Operations** page puts inventory KPIs, freshness and image consistency before
compact cycle status and timer health. **Investigation** separates cycle timelines/logs, native
invocations (including idle runs), and errors/recovery. Cycle filters do not constrain Operations.

Read monitoring as three separate signals:

1. **Timer health:** are initiation and reconciliation running and reporting outcomes?
2. **Cycle progress:** which image and batch are authorized, and what is progressing or waiting?
3. **Inventory freshness:** when was the host fleet actually observed?

A successful timer invocation does not mean a rollout completed or refresh host inventory.
Successful idle reconciliation omits routine SHR application logs; native Functions invocation
telemetry supplies timer health, including idle ticks. The workbook shows last-reported telemetry, not live Table state;
ingestion delay, sampling, filtering and the selected time range can hide evidence.

Use the **Cycle ID** to follow an operation across both timers and the native **Invocation ID**
to investigate a particular failure. Information-level logs contain initiation/non-idle timer outcomes, key actions
and final active-pass cycle snapshots. Internal checkpoints and repeated diagnostics use Trace,
which needs temporary PowerShell and host-log configuration to be collected.

See the [logging guide](../deployments/add-ons/sessionHostReplacer/logging-guide.md) for collection,
query scope and diagnostics, and [Trace one replacement cycle](../deployments/add-ons/sessionHostReplacer/README.md#trace-one-replacement-cycle)
for the workbook procedure. The [suggested alerts](../deployments/add-ons/sessionHostReplacer/alerts/alerts-guide.md)
describe stopped replacements, timer failures and missing reconciliation outcomes, with example
queries and response guidance. They are not deployed by SHR; the legacy standalone alert pack
does not implement these recommendations.

## How Execution Is Coordinated

The configurable initiation timer controls when SHR can start another replacement batch. A second
timer checks approved replacements every minute, so deployment monitoring, readiness checks and
old-host retirement do not have to wait for the next initiation time. Both run in one Function App.

The initiation schedule is **not a hard maintenance window**: replacement and recovery already
started can continue outside it. One-minute reconciliation is a polling cadence, not a guarantee
that a deployment, drain or recovery step finishes within a minute.

Each operation records its exact image, target host count and deadline. Table-backed checkpoints
record deployment intent and recovery names; a conditional per-pool lease prevents overlapping
invocations from owning the same operation. This supports resuming replacement safely across
invocations and restarts. It is not an Azure Durable Functions orchestration or a queue workflow.

## Operate and Recover Safely

- **Hold new work:** set `initiationEnabled=false`. Existing authorized work continues.
- **Stop everything:** stopping the Function App stops both timers; it does not cancel submitted
  ARM deployments. Use this deliberately, not as the normal rollout hold.
- **Change settings:** use the [configuration command](../deployments/add-ons/sessionHostReplacer/Set-SessionHostReplacerConfiguration.ps1)
  for supported operational settings. Keep authoritative deployment parameters aligned; a later
  redeployment can overwrite direct changes.
- **Recover a stopped operation:** inspect correlated logs and deployment state, fix the cause,
  then use [checked recovery](../deployments/add-ons/sessionHostReplacer/README.md#recover-a-stopped-operation).
  Do not delete state or clear leases to force a fresh start.
- **Roll back retained hosts:** rollback is operator initiated, not automatic. The
  [rollback command](../deployments/add-ons/sessionHostReplacer/Invoke-SessionHostRollback.ps1)
  restores retained capacity and pins the pool to the restored image; unsafe unfinished work can
  require restore-only operation with SHR left stopped.
- **Upgrade:** deploy the complete supported template/code release using the
  [upgrade procedure](../deployments/add-ons/sessionHostReplacer/deployment-guide.md#upgrading-an-existing-deployment).
  Do not upload one module or ZIP the source folder as a substitute for the deployed app layout.

## Deployment and Detailed References

Template Specs are the recommended guided deployment path. Review prerequisites, identity/RBAC,
networking, image source and monitoring before enabling initiation. Azure Commercial, Government,
Secret and Top Secret deployments still require target-cloud service/connectivity validation;
offline source checks do not prove a successful rollout.

| Need | Reference |
| --- | --- |
| Prerequisites, deployment and parameter reference | [Add-on README](../deployments/add-ons/sessionHostReplacer/README.md#prerequisites) |
| Detailed sequencing, readiness and safety invariants | [Canonical replacement flow](../deployments/add-ons/sessionHostReplacer/replacement-flow.md) |
| Upgrades and historical resource cleanup | [Deployment update guide](../deployments/add-ons/sessionHostReplacer/deployment-guide.md) |
| Telemetry collection and diagnostic queries | [Logging guide](../deployments/add-ons/sessionHostReplacer/logging-guide.md) |
| Pilot approval and production image promotion | [Monthly Image Operations](monthly-image-operations.md) |

The canonical flow owns detailed lifecycle behavior; this page is the design overview.
