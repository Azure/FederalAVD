[**Session Host Replacer**](../README.md) | [**Logging reference**](logging-guide.md) | [**Lifecycle reference**](replacement-flow.md)

# SHR Operator Quick Guide

Use this runbook when replacements appear stuck, an invocation fails, or you need to change the
active rollout image. Applies to standard-management host pools running the current SHR code.
An upgrade does not automatically recover an existing stopped operation.

## 1. Find the blocker before changing anything

1. Open the SHR workbook. Select the pool and a time range covering the problem.
   Go to **Page > Investigation > Investigate > Cycles** and select the affected cycle.
2. Record its **status, phase/reason, batch, image, deployment link, last observation and lease
   expiry**. A cycle is one durable operation spanning many invocations.
3. Follow the timeline to the **first failure**, then select that invocation. Expand the full
   exception and inner error, not just the final `Write-LogEntry` frame.
   Use **Show technical cycle-log details** for raw records.
4. If a deployment exists, use **Open deployment**, then inspect its failed operation/error
   details in Azure. The resource-provider error is usually more useful than "deployment failed."

**Prefer the native Function App view?** Open the affected initiator or worker function's
**Monitor / Invocations** view and select the failed invocation. Read its traces and exception
details. Structured `SHR_EVENT` messages remain visible there. Also inspect later **worker**
invocations: a single invocation is not the whole rollout. In the workbook,
**Investigate > Invocations** and **Errors and Recovery** provide equivalent starting points.
See [invocation navigation](../README.md#inspect-a-current-shr-invocation).

**Missing logs or cycle?** Check the selected workspace, Application Insights component, pool,
time range and telemetry collection. Try **All Host Pools** and the native invocation view.
Use the [both-timer queries](logging-guide.md#query-both-timers) in the stated query scope;
Application Insights and workspace table/column names differ. No rows do not prove success.

### If you need the authoritative saved status

From a machine with private-endpoint connectivity, use Azure Storage Explorer signed into the
correct cloud with Microsoft Entra authentication. Find the storage account from the Function
App's `AzureWebJobsStorage__tableServiceUri`; open **Tables > shrContinuation** and filter
`PartitionKey` to `SHR`. The operation row has a 64-character hexadecimal `RowKey`; identify the
affected cycle by `State.Id`. Do not mistake `-initiation`, `-image-change` or `-superseded-...`
companion/archive rows for the operation.

Inspect `State` locally for `Status`, `LastError`, `LockExpiresUtc`, `DeadlineUtc`,
`RecoveryPolicyVersion`, `ExpansionBlocked` and `LastProgressUtc`. Table data read permission
(or Data Contributor) and network access are both required; Azure resource Reader alone is
insufficient. **Do not edit/export the rows for routine troubleshooting:** saved deployment
bodies can contain credentials and registration tokens.

## 2. Decide: wait, fix a prerequisite, or recover

| What you see | Correct response |
| --- | --- |
| Failed invocation; operation still `Running`; transport error, timeout, HTTP 408/429/500/502/503/504 | Check subsequent worker ticks. Current code keeps the operation resumable and rereads actual state before continuing. If repeated, investigate the named endpoint, DNS/routing/firewall, service health or throttling. Do not manually repeat a timed-out deployment/delete: it may have succeeded. |
| `NeedsAttention`, even though recent invocations succeed | The operation is stopped. Later successful polling does not recover it. Find the original error, fix its cause, then use the checked recovery below if its safety checks permit. A restart is not recovery. |
| Lease wait or ETag/conditional-write conflict | Refresh state and let the current owner finish. After a crash/restart, recovery may wait for the 30-minute lease to expire. Repeated conflicts beyond expiry need investigation; confirm only one SHR app manages the pool. Never clear a lease or force a write. |
| No batch, or waiting for scheduled authorization | Check `InitiationEnabled`, the initiation schedule and image eligibility. Worker ticks do not authorize new batches. Default reconciliation is every five minutes for SideBySide, every minute for DeleteFirst; initiation is separate. Do not trigger repeated manual runs. |
| Waiting for drain, sessions, readiness, scaling handoff or capacity | Check the named hosts' sessions, drain timestamps, registration, AVD health, power state and scaling-plan phase. Respect configured drain/grace periods; grace expiry can interrupt sessions. DeleteFirst freezes new destructive work before/during RampUp and during Peak. Fix unhealthy replacements or capacity, not the guard. |
| ARM deployment failed or VM created but not registered | Read the exact deployment's failed operation. Correct the specific quota, subnet IP, VM SKU, Template Spec access, extension, domain-join or AVD registration failure. For a created VM, inspect its extension status and AVD health. Do not launch an unrelated replacement deployment; preserve exact-name recovery. |
| HTTP 401/403 or private endpoint cannot be reached | Identify whether ARM, Graph, Blob or Table failed. Check the Function App identity's permissions and target-cloud endpoint, plus private DNS/routing/firewall for private services. Operator-script access uses the signed-in operator, not the app identity. Fix that principal/path; do not enable public access or use storage keys as a workaround. |
| Entra/Intune cleanup or name reuse blocked | Verify the exact VM, AVD registration and required directory records, and the managed identity's Graph permissions for the configured cleanup target. A failed read is not proof of absence. Do not disable cleanup, delete devices by display name alone, or clear recovery mappings. A pending cleanup intent is outside the repair tool's supported recovery; escalate if reconciliation cannot resolve it. |
| Protected configuration changed | Review the named changed setting against approved deployment parameters/change history. Restore the initiating configuration when appropriate, then preview recovery. Do not replace its hash. Formatting-only JSON changes are accepted after a verified baseline; actual scope/mode/policy changes are not. |
| `ExpansionBlocked=true` / `ExpansionBlockedRecovery`, or deadline expired | Check `LastProgressUtc`, the blocker and policy version. New operations default to seven days without meaningful progress, excluding schedule-only waits; existing checkpointed recovery can continue, but new expansion is blocked. Legacy operations retain their fixed deadline. After fixing the cause, explicitly renew with checked recovery below. Repeated timer ticks do not count as progress. |
| Wrong `SessionHostTemplate` / rejected first submission | Correct it to the **session-host VM** Template Spec, not the SHR infrastructure template; persist the deployment parameter too. A narrowly eligible first SideBySide rejection can replan at the next enabled initiation tick. Otherwise use the [checked template-repair procedure](../README.md#correcting-a-wrong-session-host-template-spec); not every HTTP 400 qualifies. |
| New image published but active rollout still uses the old image | Expected: active work is pinned. Use the image-request procedure below; changing image-selection settings is not the supported way to unpin a running operation. |

For detailed symptoms and prerequisites, see [troubleshooting](../README.md#troubleshooting),
[Graph permissions](../README.md#2-grant-graph-api-permissions-to-managed-identity) and
[timer schedules](deployment-guide.md#timer-schedule-guidance).

## 3. Use the supported action

Run these commands from the **repository root**, using PowerShell **7.4+**, `Az.Accounts`, the
correct signed-in cloud/subscription, and private Table connectivity. Replace placeholders:

```powershell
Connect-AzAccount -Environment '<registered-cloud-name>' -Subscription '<subscription-id>'
$shr = @{
    FunctionAppName = '<shr-name>'
    ResourceGroupName = '<shr-resource-group>'
}
$tools = '.\deployments\add-ons\sessionHostReplacer\tools'
```

For example, the registered cloud is `AzureCloud` for Commercial or `AzureUSGovernment` for
Government. Use your registered environment for an air-gapped cloud.

### Hold new batches, not existing recovery

```powershell
& "$tools\Set-SessionHostReplacerConfiguration.ps1" @shr -InitiationEnabled $false
```

Use `$true` to resume. This app-setting change restarts the app and can leave a lease wait.
Persist the matching deployment parameter. **This is not an emergency stop:** checkpointed
work and retirement may continue. Stopping the Function App stops both timers, but does not
cancel accepted ARM operations, undo deletion/drain, or stop autoscale.

### Recover after fixing the original cause

Requires Function App read/config-list/stop/start, deployment/VM/AVD/Template Spec read access,
and **Storage Table Data Contributor**. Preview is read-only:

```powershell
& "$tools\Repair-SessionHostReplacerOperation.ps1" @shr
# Review the operation, image, host names and deadline; then confirm:
& "$tools\Repair-SessionHostReplacerOperation.ps1" @shr -Apply
```

**If the deadline expired or expansion is blocked**, explicitly approve a new seven-day
window by using these commands instead, after fixing the blocker:

```powershell
& "$tools\Repair-SessionHostReplacerOperation.ps1" @shr -ExtendDeadlineHours 168
& "$tools\Repair-SessionHostReplacerOperation.ps1" @shr -ExtendDeadlineHours 168 -Apply
```

The tool stops the app, rechecks safety, makes restricted backups under
`customer/shr-recovery/`, conditionally updates the same operation, verifies it and requests
startup. The worker can resume at its next tick; it does not need a new initiation tick to
recover checkpointed work. New batches still require normal authorization.

**If preview refuses, stop:** an active lease/deployment may need time; pending cleanup,
conflicting configuration, malformed state or unsupported recovery needs owner review.
Do not delete rows, mark work completed, clear exclusions or bypass ETags.
**If Apply fails**, verify whether the app is stopped and inspect the backup/current state
before any retry or restart. Successful writes are not rolled back; the tool does not
automatically restart after an error. Keep backups private.

### Request a different image for future batches

Requires a **Running**, gallery-backed operation, an exact `major.minor.patch` version in the
same image definition, no active maintenance override, app/config and image read access,
and Table Data Reader for preview / Data Contributor for Apply:

```powershell
& "$tools\Request-SessionHostReplacerImageChange.ps1" @shr -ImageVersion '1.0.11'
& "$tools\Request-SessionHostReplacerImageChange.ps1" @shr -ImageVersion '1.0.11' -Apply
```

Submission is **not** application or deployment. SideBySide waits for the current deployment's
health and scaling handoff, but not all old-host drains; DeleteFirst finishes its destructive
batch first. A **fresh scheduled authorization** is still required for the new-image batch.
The request does not restart the app or change image selection for future operations.
An outstanding request cannot be overwritten.

Verify `ImageTargetChanged` / `LastImageChangeRequestId`, then the new batch's deployment image.
`WaitingForImageBatchAuthorization` means the target changed but the batch has not started.
`LastImageChangeRejectedId` / `ImageChangeError` explain rejection; fix eligibility before
submitting a replacement request. Transient validation failures defer rather than reject.
See the [full image-change contract](replacement-flow.md#change-the-rollout-image).

## 4. Verify recovery, not just command success

- Confirm the app starts and later worker invocations observe the **same recovered cycle**.
  Recovery success alone does not establish that its next API request will succeed.
- Confirm actual progress: deployment accepted/settled, expected hosts registered and healthy,
  scaling handoff released, or checkpointed cleanup completed. Check live resources as well
  as telemetry timestamps.
- Confirm expansion is no longer blocked when explicitly renewed; if initiation was held,
  resume only when approved. A wait for the next authorized batch can still be correct.
- At completion, verify the expected image/capacity, old-host retirement or configured
  retention, required cleanup and return to autoscale. A green invocation is not cycle completion.

**Escalate with:** UTC failure window, app/pool and deployed code version, mode, cycle/batch,
phase/reason, native invocation ID, exact deployment link/error code, last progress/lease/deadline,
and changes already attempted. Share only approved, redacted error excerpts. Do not attach full
app settings, Table state, deployment bodies, tokens or recovery backups. If evidence is
insufficient or resource identity is ambiguous, preserve state and escalate rather than guessing.
