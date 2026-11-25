# Deploying Session Host Replacer Updates

For first-deployment prerequisites, permissions and parameters, see [README.md](../README.md).
The [canonical replacement flow](replacement-flow.md) owns lifecycle behavior.

## Scope

SHR has one execution model, regardless of SideBySide or DeleteFirst replacement mode:

| Function | Trigger | Responsibility |
| --- | --- | --- |
| `session-host-replacer-initiator` | Configurable `%TimerSchedule%` | Assess work and authorize new batches |
| `session-host-replacer-worker` | Derived `%ContinuationTimerSchedule%` | Reconcile every five minutes for SideBySide or every minute for DeleteFirst |

Both use the same lifecycle engine, managed identity, Blob host storage and Table state.
The reconciler never independently selects a newer image or authorizes another batch.
Native timer triggers need no queue extension bundle or prebuilt extension package.

## Operator RBAC and Access Setup

Provision access for the **human/operator group** separately from the Function App's managed
identity. The runtime identity's deployment and Graph permissions do not authorize a signed-in
operator, and operator permissions do not repair the runtime identity.
The [Operator Quick Guide](operator-guide.md#operator-access-at-a-glance) maps tasks to named roles.

### Built-in role profiles

Use the following sufficient built-in combinations, scoped to this deployment. They are not a
requirement to grant broad subscription access; approved custom roles can be narrower.

| Profile | Named roles and assignment scopes |
| --- | --- |
| Troubleshooter (no resource/state changes) | **Reader** on the SHR resource group, session-host VM resource group and host-pool resource group; **Reader** on any gallery, session-host Template Spec and workbook outside those scopes; **Log Analytics Reader** on the workload workspace; **Storage Table Data Reader** on the SHR storage account or specific state tables. |
| Image-change operator | Troubleshooter access, plus **Website Contributor** on the SHR Function App to read its configuration. Preview uses **Storage Table Data Reader** on `shrContinuation`; Apply requires **Storage Table Data Contributor** on that table. |
| Recovery/configuration operator | Troubleshooter access, plus **Website Contributor** on the SHR Function App for configuration reads/writes and stop/start. Checked recovery preview uses **Storage Table Data Reader** on `shrContinuation`; Apply requires **Storage Table Data Contributor** on both `shrContinuation` and `sessionHostDeploymentState`. |
| Optional guest-log collector | **Reader** on the selected session-host VM for preview, plus `Microsoft.Compute/virtualMachines/runCommand/action` for Apply. **Virtual Machine Contributor** on that VM is a sufficient privileged option; prefer an approved narrower role when practical. No Table/app-settings access is needed for this collector. |

Table Data Contributor includes read access; it does not need a duplicate Table Data Reader
assignment at the same scope. Storage-account-level assignments cover both tables and simplify
Storage Explorer discovery; table-scoped assignments limit data access, but still pair them with
**Reader** on the storage account for resource discovery. Table roles cannot be scoped to one
SHR row: a table can contain other pools' sensitive saved requests. Use the approved storage
isolation and access-review model.

Reader on the VM and host-pool **resource groups** is intentional: recovery enumerates ARM
deployments, VMs and AVD registrations. Include separately selected scopes/subscriptions and the
gallery/Template Spec resources; access to the Function App's RG alone is not sufficient.
The workbook queries the selected **Log Analytics workspace**, so component-only monitoring
access is not a substitute. Its Application Insights components and host pools must also be
visible for discovery, and the workbook resource may live in a different RG.

**Website Contributor is privileged:** it includes `Microsoft.Web/sites/*`, allowing app
modification/deletion and access to sensitive configuration. For read-only configuration previews,
an approved custom role can instead grant `Microsoft.Web/sites/read` and
`Microsoft.Web/sites/config/list/action`. Checked recovery additionally needs
`Microsoft.Web/sites/stop/action` and `Microsoft.Web/sites/start/action`; the configuration
helper additionally needs `Microsoft.Web/sites/config/write`. Grant only the tasks approved for
the operator; do not treat preview access as harmless.

Routine troubleshooting and checked recovery do **not** require **Owner**, **User Access
Administrator**, **Virtual Machine Contributor**, or **Desktop Virtualization Contributor** on
the operator. The optional [guest-log collector](operator-guide.md#collect-guest-logs-when-deployment-errors-are-generic)
is an explicit exception: it executes a read-only payload as SYSTEM through Run Command and needs
the separate VM permission above. Resource provisioning/redeployment, assigning roles, manually changing hosts,
and Graph/Intune administration are separate tasks with separate approvals/permissions.
Azure RBAC roles do not grant Microsoft Graph application permissions or Intune access.
See [runtime identity prerequisites](../README.md#1-managed-identity-for-function-app) and
[Graph permissions](../README.md#2-grant-graph-api-permissions-to-managed-identity).

### Access acceptance check

Before handing the deployment to operators:

1. Assign/activate approved group roles (including PIM activation where applicable); allow RBAC
   propagation and refresh the sign-in if needed. Do not test solely as a subscription Owner.
2. With the operator identity, open the workbook and query the workload workspace; inspect a
   known ARM deployment and its operation details, plus the gallery and session-host Template Spec.
3. Use Entra authentication to read `shrContinuation` and, when needed,
   `sessionHostDeploymentState`. **Reader**, **Contributor** and **Storage Account Contributor**
   alone are not Entra Table data roles; do not switch to account keys to make the check pass.
4. Run the relevant tool's read-only preview against an eligible operation. A safety refusal
   (for example, an active lease) is not evidence that every later permission check passed.
   Verify recovery Apply separately in an isolated pilot; it stops/restarts the app and writes state.
5. Test connectivity from the Function App and operator workstation independently.
   Private endpoints are recommended, not required. Public deployments need permitted public
   access/firewall/IP rules; private deployments need private DNS and routing. RBAC grants
   neither network path. Validate cloud-specific role/service availability in the target environment.
6. If guest collection is approved, test it on an isolated SHR Windows VM with the intended
   operator identity, ready agent and approved agent endpoint access. Confirm restricted local
   report ACLs, source outcomes and actual Run Command delivery in each target cloud. The runtime
   identity uses `Microsoft.Compute/virtualMachines/extensions/read` for supplemental instance
   view (included in the existing VM Contributor grant); custom runtime roles need that read
   permission or diagnostics report `Unavailable`. No runtime Run Command permission is added.

Microsoft references: [Reader](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/general#reader),
[Website Contributor](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/web-and-mobile#website-contributor),
[Log Analytics Reader](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/monitor#log-analytics-reader),
[Table data authorization](https://learn.microsoft.com/azure/storage/tables/authorize-access-azure-active-directory),
[Table role scopes](https://learn.microsoft.com/azure/storage/tables/assign-azure-role-data-access)
and [workspace access](https://learn.microsoft.com/azure/azure-monitor/logs/manage-access).

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

The existing time-zone setting applies. Deployment derives `ContinuationTimerSchedule`:

| Mode | Continuation | New batch authorization |
| --- | --- | --- |
| SideBySide | Every five minutes, staggered one minute after the initiation minute offset | 15 minutes, for initial and later batches |
| DeleteFirst | Every minute (`0 * * * * *`) | Five minutes |

For `timerSchedule: '0 3,33 * * * *'`, SideBySide uses
`0 4,9,14,19,24,29,34,39,44,49,54,59 * * * *`. For the default `:00/:30` initiation,
it uses `:01, :06, :11, ... :56`. Offset `:59` wraps to `:00, :05, ... :55`.
All continuation schedules run every hour and day, even when initiation is restricted.

Portal schedules have one Start Minute and its half-hour counterpart. Custom NCRONTAB
schedules use the start of the first minute term (list, range or step); `*` starts at zero.
This determines one fixed five-minute phase, not a separate timer for every initiation time.
Arbitrary custom schedules may therefore coincide with continuation; the conditional lease
still protects ownership. An offset is not a guarantee of invocation ordering or start time.

The 30-minute worker ownership lease and eight-minute execution budget are unchanged.
Authorization permits a new batch to start; the lease controls which invocation may mutate
the operation. Longer authorization does not bypass initiation holds, maintenance expiry,
readiness or capacity checks. Long invocations, a stopped host or a live lease can delay progress.

Upgrade with the complete template so bindings, derived app settings and code agree. Redeploy
after changing `timerSchedule` or replacement mode; manually editing `TimerSchedule` alone does
not recalculate continuation. Existing saved authorizations retain their original expiry;
upgrading does not extend an in-flight authorization or reset an operation.

## Quick Deployment Steps

Use the complete SHR Bicep or published Template Spec release. A single-file Portal editor upload
cannot safely upgrade the function bindings, shared code and settings together.

Preserve deployment-specific parameters, including `initiationEnabled` and `continuationTimeoutHours`.
Follow [verification](#verify-deployment) before enabling production initiation.

For first-observed deployment/domain-join failure notifications, separately deploy the
[first-failure alert](alerts-guide.md#deploy-the-first-failure-notification) using an approved
existing Action Group. Upgrading SHR adds diagnostic/credential retry guards, not recipients.
Test the alert route and the new `-AcknowledgeCredentialFix` recovery path in the isolated pilot.

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

Before restarting an upgraded app, verify the [scaling plan exclusion contract](../README.md#scaling-plan-exclusion-contract).
An enabled plan's Exclusion tag must match SHR's configured tag name (default
`ScalingPlanExclusion`). The worker repairs blank/mismatched names on verified unshared
plans; shared mismatches still block work. Deploy the new scaling-plan custom role and
assignment, and allow RBAC propagation before testing repair.

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
   The scheduled function is now `session-host-replacer-initiator`. The template explicitly
   enables it and sets `AzureWebJobs.session-host-replacer.Disabled=true` so the previous
   scheduled function cannot remain a second active initiator. Incremental deployment does
   not delete the old child function: verify it is disabled, then remove only that legacy
   function through the approved operator process while the app is stopped. Do not remove
   shared engine/modules or operation state.
   These settings use Microsoft's [function enable/disable mechanism](https://learn.microsoft.com/azure/azure-functions/disable-function)
   and are enforced on redeployment. Use `InitiationEnabled=false` to hold new batches,
   not a function's `Disabled` setting; the reconciliation timer must remain enabled to finish
   authorized work.
5. Before starting the app, verify both bindings, the shared engine/modules and the new native-timer
   host configuration are installed. Check that the app remained stopped throughout the update.
   Start it only after the code deployment is complete.
6. With initiation still held, verify the reconciliation timer resumes any authorized operation with the
   same ID, pinned image, intent, target and deadline. Existing `shrContinuation` rows, companion
   authorizations and recovery tables remain valid; obsolete generation metadata is ignored.
   A `NeedsAttention` operation remains stopped until checked recovery.
   Existing operations without `RecoveryPolicyVersion=1` retain their original fixed deadline.
   New operations use the configured no-progress window (default 168 hours); preserve an explicitly
   selected value during deployment. Checked `-ExtendDeadlineHours 168` recovery opts an eligible
   legacy operation into the new policy. Do not edit its deadline or clear state manually.
   Deploy the updated worker before using image-change requests; an older worker will not consume them.
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

$files = @(Get-ChildItem -Path 'tests\SessionHostReplacer*.Tests.ps1' |
    ForEach-Object FullName)
$files += 'tests\TemplateSpecs.Tests.ps1'
Invoke-Pester -Script $files -PassThru -Show Failed,Summary
git diff --check
```

### Live pilot

Offline tests prove contracts, not Functions indexing or Azure deployment success. In an isolated
pilot, including each intended target cloud:

- With an enabled unshared scaling plan, verify blank and nonblank mismatches are repaired
  before replacement. Confirm legacy VM exclusions are preserved, only the plan's exclusion
  name changes, and schedules/assignments remain unchanged. Test denied writes and failed
  verification: replacement must stop rather than continue unprotected.
- Add another pool reference, including a disabled reference, and confirm a shared mismatch
  fails without plan or VM-tag writes. A matching shared plan must continue normally.
- Avoid concurrent plan/assignment edits during repair; exercise conditional failure when
  the service supplies an ETag. Offline tests do not establish atomicity for APIs without ETags.
- Replace eight old hosts, leaving sessions on one. Confirm the occupied old host is excluded
  before drain, accepts no new sessions, retains its original grace-period deadline and remains
  excluded through multiple autoscale evaluations. Remove only its SHR-owned VM exclusion tag
  in the isolated pilot and confirm retirement reconciliation restores it. Confirm existing
  administrator-owned exclusion values survive retirement and shutdown retention.
- Confirm the initiator and worker are the only enabled timer functions, with the intended initiation
  schedule and mode-specific derived reconciliation schedule. Test SideBySide `:03/:33` initiation
  with `:04, :09, ... :59` reconciliation, and DeleteFirst with every-minute reconciliation.
  A retained legacy function must remain disabled.
  Confirm there is no queue listener or bundle
  download requirement after a cold restart.
- Verify managed identity, the configured public-access/firewall rules or private DNS/routing
  as applicable, Blob host locks and Table reads/conditional writes.
- Use a sparse initiation schedule. Verify an accepted deployment progresses through health,
  autoscale handoff and safe cleanup between initiation ticks, without an extra deployment batch.
- Verify an idle pool creates no operation and the reconciliation timer performs only the operation lookup.
- Verify a held initiation schedule still permits authorized progress and rejects new batch authority.
- Interrupt an active invocation, retain its state and confirm safe lease-expiry recovery without a
  duplicate accepted deployment. Test concurrent initiation/reconciliation and expired authorization.
  For SideBySide, miss the first continuation opportunity and confirm a later pass can consume the
  authorization within 15 minutes; verify later batch authorizations use the same window and
  expired/unstarted authorizations do not start work. Existing saved five-minute authorizations
  must not be extended by upgrade. Verify the lease remains 30 minutes in both modes.
- Verify recognized transient failures leave owned work resumable, exhausted GET retries fail
  visibly, and a lost response after ARM acceptance does not create duplicate deployment authority.
  Exercise recovery with Table access unavailable and a stale lease. Include short outages and
  a simulated day-long gap in progress-window tests; these do not replace a target-cloud outage pilot.
- Confirm progress-policy expiry blocks expansion but permits guarded checkpointed recovery,
  legacy fixed deadlines and protected configuration failures remain guarded, and checked renewal
  does not bypass cleanup/lease/deployment checks. Verify rejected-template recovery and Portal
  configuration/networking steps separately.
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
  without replaying its saved exception as a fresh Error on every reconciliation tick. Temporarily enable
  PowerShell verbose emission and host Trace ingestion to check detailed diagnostics, then restore
  normal logging. Confirm all existing workbook configuration/inventory/action panels still populate.

## Review or Update Existing Operational Settings

Use [Set-SessionHostReplacerConfiguration.ps1](../tools/Set-SessionHostReplacerConfiguration.ps1) to preview
changes and hold or resume initiation. App-setting changes restart the app; retain the corresponding
deployment parameters so a later redeployment does not undo the hold.

Stopping the app stops both timers, not external ARM work or autoscale.
See [operations and recovery](../README.md#two-timer-operations) and the
[preview-first recovery command](../README.md#recover-a-stopped-operation).

## For Complete Documentation

- [Configuration and troubleshooting](../README.md)
- [Lifecycle and coordination](replacement-flow.md)
- [Air-gapped platform prerequisites](../../../../docs/air-gapped-clouds.md#shr-two-timer-prerequisites)
