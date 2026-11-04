# Deploying Session Host Replacer Updates

For first-deployment prerequisites, permissions and parameters, see [README.md](README.md).
The [canonical replacement flow](replacement-flow.md) owns lifecycle behavior.

## Scope

SHR has one execution model, regardless of SideBySide or DeleteFirst replacement mode:

| Function | Trigger | Responsibility |
| --- | --- | --- |
| `session-host-replacer` | Configurable `%TimerSchedule%` | Assess work and authorize new batches |
| `session-host-replacer-worker` | `0 * * * * *` | Reconcile the current authorized operation every minute |

Both use the same lifecycle engine, managed identity, Blob host storage and Table state.
The reconciler never independently selects a newer image or authorizes another batch.
Native timer triggers need no queue extension bundle or prebuilt extension package.

## Timer Schedule Guidance

`timerSchedule` controls **new batch authorization**, not deployment, health or cleanup checks.
Approved work continues outside the initiation hours. The schedule is not a hard maintenance-window
boundary and does not terminate running invocations or submitted ARM deployments.

```bicep
timerSchedule: '0 0,30 * * * *'   // Default: :00 and :30 each hour
// '0 0 * * * *'                // Hourly
// '0 0 8-17 * * 1-5'           // Weekday business hours
// '0 15,45 * * * *'            // Stagger initiation across pools
```

The existing time-zone setting applies. The reconciliation interval is fixed at one minute;
long invocations, a stopped host or a live operation lease can delay progress.

## Quick Deployment Steps

Use the complete SHR Bicep or published Template Spec release. A single-file Portal editor upload
cannot safely upgrade the function bindings, shared code and settings together.

Preserve deployment-specific parameters, including `initiationEnabled` and `continuationTimeoutHours`.
Follow [verification](#verify-deployment) before enabling production initiation.

## Dedicated Replacer Resource Group

On the Portal form's **Infrastructure** step, **Session Host Replacer Resource Group** defaults
to the session hosts resource group. Select another existing RG in the deployment subscription
to isolate this pool's replacer resources. Create that RG before opening the deployment form.
For PowerShell or Bicep deployments, set the existing `functionAppResourceGroupName` parameter.
The RG's metadata location does not change the selected session-host and Function App region.

The selected RG contains the Function App, runtime storage (including operation/recovery tables),
pool-specific Application Insights when enabled, private endpoints when enabled, the dedicated
storage-encryption identity when CMK is enabled, and a session-host Template Spec when SHR creates
one. Session-host VMs and the host pool stay in their selected RGs.

Shared resources keep their existing selections: the App Service Plan uses its independent
existing-plan or plan-RG selection; Log Analytics and the centralized workbook remain with the
selected workspace; existing networking, DNS zones, Key Vault, app identities and externally
supplied Template Specs are not relocated. For direct deployments, explicitly set
`appServicePlanResourceGroupName` or `existingAppServicePlanResourceId` to keep a shared plan outside
the replacer RG; an omitted plan RG otherwise defaults to `functionAppResourceGroupName`.

**This is a rebuild boundary, not a migration or routine upgrade requirement.** Changing the
parameter deploys resources at the new scope; it does not move or retire the previous app.
Never run two replacers for the same host pool. Prefer an in-place update when retaining state.

Before deleting a dedicated RG, hold initiation, allow authorized replacement, drain and cleanup
work to finish, resolve any stopped operation/pending hostname mappings and retained-host recovery
needs, then stop the app and confirm no live lease or in-flight deployment remains. Preserve any
required recovery evidence securely. Deleting the RG permanently removes its SHR state; do not
reconstruct an active operation by merely redeploying an empty storage account.
A recreated system-assigned identity has a new principal ID and requires its external Graph
permissions to be granted again. Review external role assignments and CMK key dependencies
through the approved cleanup process; deleting the RG is not complete cross-scope cleanup.

After changing this form, live-smoke-test **Infrastructure** and **Advanced** with the default
hosts RG and a different existing RG. Confirm parameter export, shared plan placement and custom
Function App name checks use the intended scopes. Offline schema/contract checks do not prove
Portal rendering or successful Azure deployment.

## Upgrading an Existing Deployment

This is a breaking contract change: remove `enableQueueContinuation` and the SHR-specific
`azureQueuePrivateDnsZoneResourceId` from existing SHR parameter files. Do not remove similarly named
parameters from other solutions. There is no supported switch back to direct timer execution.

1. Hold new batches with `InitiationEnabled=false` and persist `initiationEnabled=false` in the
   upgrade parameters. Record the current operation ID, image, deadline, accepted deployments and
   outstanding cleanup. Protect this information; saved operation state can contain credentials.
2. Stop the Function App using the approved operator process. Verify it is stopped and no live
   operation lease remains before updating code. An interrupted invocation may retain its lease
   for up to 30 minutes. Do not clear the lease or delete state to accelerate an upgrade.
3. If the previous app used a prebuilt ZIP, remove any run-from-package mount and obsolete SHR
   queue-extension binaries/registration through the approved code-deployment process first.
   Use the previous package manifest to identify its files. Do not broadly delete app content,
   host-storage blobs or Table entities.
4. Deploy the complete template and shared code while the app is stopped. The existing
   `session-host-replacer-worker` function is updated **in place** from queue to timer; a second
   worker name is not created. Its disabled setting is explicitly reset to `false`.
5. Before starting the app, verify both bindings, the shared engine/modules and the new native-timer
   host configuration are installed. Check that the app remained stopped throughout the update.
   Start it only after the code deployment is complete.
6. With initiation still held, verify the minute timer resumes any authorized operation with the
   same ID, pinned image, intent, target and deadline. Existing `shrContinuation` rows, companion
   authorizations and recovery tables remain valid; obsolete generation metadata is ignored.
   A `NeedsAttention` operation remains stopped until checked recovery.
7. Complete the live checks below, then resume initiation and persist the matching parameter value.

A former direct-timer app has no durable operation row. The reconciler does not invent an
authorization; the next enabled initiation tick assesses inventory and persisted deployment recovery
state before authorizing work. Previously accepted deployments and name mappings are not discarded.

**Historical queue cleanup is separate and explicit.** Incremental ARM deployment does not delete
old queue private endpoints, DNS zone groups, queue-only role assignments, queues or queued messages
merely because their declarations were removed. The new worker does not consume those messages.
After a successful pilot, inventory dependencies and use the approved cleanup process for resources
owned exclusively by the retired SHR queue transport. Never remove shared DNS zones, generic storage
roles, Blob/Table endpoints or durable operation state indiscriminately.

The shared Function App module now gates its automatic **Storage Queue Data Contributor**
assignment on `enableQueueStorage`. SHR passes `false`, so new SHR deployments receive host Blob
and deployment-state Table permissions without the queue role. Queue-enabled module callers keep
their existing queue access. Upgrading an existing SHR deployment does **not** revoke an earlier
queue-role assignment; remove that assignment explicitly only after confirming the identity and
storage-account scope are exclusive to the retired queue transport. An explicitly supplied
additional role remains caller-owned and is not filtered out by the capability switch.

## Verify Deployment

### Offline validation

From the repository root, use a compatible Pester version (validated with 4.10.1):

```powershell
az bicep build --file deployments\add-ons\sessionHosts\main.bicep `
    --outfile deployments\add-ons\sessionHosts\main.json
az bicep build --file deployments\add-ons\sessionHostReplacer\main.bicep `
    --outfile deployments\add-ons\sessionHostReplacer\main.json
& .github\skills\federalavd-bicep-maintenance\scripts\Test-BicepArmSync.ps1 `
    -BicepPath deployments\add-ons\sessionHostReplacer\main.bicep

$files = @(
    'tests\SessionHostReplacer.Tests.ps1'
    'tests\SessionHostReplacer.Continuation.Tests.ps1'
    'tests\SessionHostReplacer.Replan.Tests.ps1'
    'tests\SessionHostReplacer.Recovery.Tests.ps1'
    'tests\SessionHostReplacer.Idle.Tests.ps1'
    'tests\SessionHostReplacer.ImageSelection.Tests.ps1'
    'tests\SessionHostReplacer.Timers.Tests.ps1'
    'tests\SessionHostReplacer.Observability.Tests.ps1'
    'tests\SessionHostReplacer.Predeployment.Tests.ps1'
    'tests\TemplateSpecs.Tests.ps1'
)
Invoke-Pester -Script $files -PassThru -Show Failed,Summary
git diff --check
```

### Live pilot

Offline tests prove contracts, not Functions indexing or Azure deployment success. In an isolated
pilot, including each intended target cloud:

- Confirm exactly the two expected functions load as timer triggers, with the intended initiation
  schedule and fixed minute reconciliation schedule. Confirm there is no queue listener or bundle
  download requirement after a cold restart.
- Verify managed identity, private DNS/routing, Blob host locks and Table reads/conditional writes.
- Use a sparse initiation schedule. Verify an accepted deployment progresses through health,
  autoscale handoff and safe cleanup between initiation ticks, without an extra deployment batch.
- Verify an idle pool creates no operation and the minute timer performs only the operation lookup.
- Verify a held initiation schedule still permits authorized progress and rejects new batch authority.
- Interrupt an active invocation, retain its state and confirm safe lease-expiry recovery without a
  duplicate accepted deployment. Test concurrent initiation/reconciliation and expired authorization.
- Confirm deadline/configuration failures stay stopped, checked rejected-template recovery works,
  and the Portal configuration/networking steps render successfully with correct output types.
- Update both the runtime and workbook. Render the Operations page, select a host pool and cycle,
  and verify the summary/timeline retain that cycle across both timer roles and multiple batches.
  Run the workbook KQL against the target Application Insights resources; offline contracts and
  parser checks are not proof of query execution, permissions or cloud availability.
- Verify native invocation drill-down includes host exceptions without inventing invocation IDs.
  Check no-cycle idle ticks, held initiation, lease waits/expiry, a waiting deployment, completion
  and a stopped cycle. Check last-reported inventory age and sampling/no-data cases. Confirm
  deployment links open the existing resource in the target cloud without a deployment action.
- At normal Information logging, confirm actual actions, timer health and final cycle snapshots
  remain visible without repeated setup/per-host narration. Verify a stopped cycle stays visible
  without replaying its saved exception as a fresh Error on every minute tick. Temporarily enable
  PowerShell verbose emission and host Trace ingestion to check detailed diagnostics, then restore
  normal logging. Confirm all existing workbook configuration/inventory/action panels still populate.

## Review or Update Existing Operational Settings

Use [Set-SessionHostReplacerConfiguration.ps1](Set-SessionHostReplacerConfiguration.ps1) to preview
changes and hold or resume initiation. App-setting changes restart the app; retain the corresponding
deployment parameters so a later redeployment does not undo the hold.

Stopping the app stops both timers, not external ARM work or autoscale.
See [operations and recovery](README.md#two-timer-operations) and the
[preview-first recovery command](README.md#recover-a-stopped-operation).

## For Complete Documentation

- [Configuration and troubleshooting](README.md)
- [Lifecycle and coordination](replacement-flow.md)
- [Air-gapped platform prerequisites](../../../docs/air-gapped-clouds.md#shr-two-timer-prerequisites)
