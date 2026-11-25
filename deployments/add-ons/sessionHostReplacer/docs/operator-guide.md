[**Session Host Replacer**](../README.md) | [**Logging reference**](logging-guide.md) | [**Lifecycle reference**](replacement-flow.md)

# SHR Operator Quick Guide

Use this runbook when replacements appear stuck, an invocation fails, or you need to change the
active rollout image. Applies to standard-management host pools running the current SHR code.
An upgrade does not automatically recover an existing stopped operation.

**Private endpoints are recommended, not required.** Use the deployment's approved network
access model. For public endpoints, verify public network access and any firewall/IP restrictions.
For private endpoints, verify private DNS resolution and routing from the Function App and,
separately, from the operator's machine. Permissions are required in either model.

## Operator access at a glance

These are named built-in role options for the **signed-in operator**, not the Function App's
managed identity. Combine the rows needed for the task; an equivalent approved custom role
can provide narrower access.

| Task | Operator role and scope |
| --- | --- |
| Open the workbook/native logs | **Log Analytics Reader** on the workload workspace, plus **Reader** on the workbook, Application Insights component and host pool for discovery/navigation. |
| Inspect resources and deployment failures | **Reader** on the SHR, session-host VM and host-pool resource groups, plus any separately scoped gallery and session-host Template Spec. |
| Collect guest diagnostic excerpts | **Reader** on the selected VM for preview. Apply additionally requires `Microsoft.Compute/virtualMachines/runCommand/action`; **Virtual Machine Contributor** on that VM is a sufficient but privileged built-in option. |
| Inspect saved state | **Storage Table Data Reader** on the SHR storage account (or the required tables), plus **Reader** on the storage account for discovery. |
| Preview/request an image change | **Website Contributor** on the Function App for app-settings reads; **Reader** on the gallery; **Storage Table Data Reader** for preview or **Storage Table Data Contributor** for Apply on `shrContinuation`. |
| Hold/resume initiation or update supported app settings | **Website Contributor** on the Function App. |
| Preview/apply checked recovery | **Website Contributor** on the Function App and the resource **Reader** access above. Table preview needs **Storage Table Data Reader** on `shrContinuation`; Apply needs **Storage Table Data Contributor** on both `shrContinuation` and `sessionHostDeploymentState`. |

**Website Contributor can change/delete the app and read sensitive configuration**; it is a
convenient built-in option, not a read-only role. Prefer an approved narrower role for preview-only
operators. **Reader/Contributor on Azure resources do not grant Entra-authenticated Table data
access.** See [operator RBAC setup](deployment-guide.md#operator-rbac-and-access-setup) for
profiles, scopes and access checks. Network access is separate from all these role assignments.

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

From a machine that can reach the configured Table endpoint, use Azure Storage Explorer signed into the
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
| ARM deployment failed or VM created but not registered | Read `DeploymentFailed` / `DEPLOYMENT_FAILURE` diagnostics and the failing resource/code. Confirmed domain credential failures stop before cleanup; use the credential procedure below. Other failed deployments retain guarded cleanup/retry. For successful deployments with missing registration, inspect VM initialization/agent health; missing registration alone does not authorize deleting working resources. |
| HTTP 401/403 or endpoint cannot be reached | Identify whether ARM, Graph, Blob or Table failed. Check the Function App identity's permissions and target-cloud endpoint. For public endpoints, check public access/firewall/IP restrictions; for private endpoints, check private DNS/routing. Operator-script access uses the signed-in operator, not the app identity. Fix the principal/path within the approved network model; do not bypass restrictions or switch to storage keys. |
| Entra/Intune cleanup or name reuse blocked | Verify the exact VM, AVD registration and required directory records, and the managed identity's Graph permissions for the configured cleanup target. A failed read is not proof of absence. Do not disable cleanup, delete devices by display name alone, or clear recovery mappings. A pending cleanup intent is outside the repair tool's supported recovery; escalate if reconciliation cannot resolve it. |
| Protected configuration changed | Review the named changed setting against approved deployment parameters/change history. Restore the initiating configuration when appropriate, then preview recovery. Do not replace its hash. Formatting-only JSON changes are accepted after a verified baseline; actual scope/mode/policy changes are not. |
| `ExpansionBlocked=true` / `ExpansionBlockedRecovery`, or deadline expired | Check `LastProgressUtc`, the blocker and policy version. New operations default to seven days without meaningful progress, excluding schedule-only waits; existing checkpointed recovery can continue, but new expansion is blocked. Legacy operations retain their fixed deadline. After fixing the cause, explicitly renew with checked recovery below. Repeated timer ticks do not count as progress. |
| Wrong `SessionHostTemplate` / rejected first submission | Correct it to the **session-host VM** Template Spec, not the SHR infrastructure template; persist the deployment parameter too. A narrowly eligible first SideBySide rejection can replan at the next enabled initiation tick. Otherwise use the [checked template-repair procedure](../README.md#correcting-a-wrong-session-host-template-spec); not every HTTP 400 qualifies. |
| New image published but active rollout still uses the old image | Expected: active work is pinned. Use the image-request procedure below; changing image-selection settings is not the supported way to unpin a running operation. |

For detailed symptoms and prerequisites, see [troubleshooting](../README.md#troubleshooting),
[Graph permissions](../README.md#2-grant-graph-api-permissions-to-managed-identity) and
[timer schedules](deployment-guide.md#timer-schedule-guidance).

### Connectivity outage: when should I intervene?

| Situation | Expected behavior and operator action |
| --- | --- |
| Brief outage (for example, four minutes) | ARM/Graph GETs get short, bounded retries; an exhausted request fails the invocation, not automatically the rollout. A later worker tick reconciles saved work. Check later ticks after connectivity returns; do not repair a healthy `Running` operation or extend its deadline just because a request timed out. |
| Day-long outage, with more than a day left in the operation's progress window | Repeated transient failures do not exhaust a lifetime retry counter. Saved work remains resumable. After connectivity and the Functions host recover, the worker can continue the checkpointed batch. Investigate the outage immediately, but do not reset state merely because it lasted a day. |
| Outage crosses the remaining no-progress deadline | New expansion becomes blocked when the worker checks the deadline. Fix connectivity, inspect accepted deployments/host health, then consider explicit renewal below. A one-day outage can cross the deadline if the operation was already stalled for six days. |
| Table storage or host storage is unreachable | State reads/writes or the Functions host/timer may fail. Last-reported telemetry can be stale. Restore storage access and verify the host and timers recover; an interrupted owner can leave a lease wait. Do not create another app or assume the saved operation disappeared. |

These are recovery paths, not a five-minute or 24-hour recovery guarantee. A created VM's
extension/domain-join/registration can fail during the outage and need its own diagnosis.
An unstarted authorization that expired must wait for fresh initiation; it cannot start a
day-old batch. HTTP 401/403, certificate/trust failures or unrecognized exceptions must be
investigated, not assumed transient because the network was unstable. Air-gapped clouds use
the same recovery policy: check their configured endpoints and internal DNS/routes, not a
public-cloud connectivity test. See [how retries and resumption work](replacement-flow.md#connectivity-outages-and-resumption).

## 3. Use the supported action

Run these commands from the **repository root**, using PowerShell **7.4+**, `Az.Accounts`, the
correct signed-in cloud/subscription, and access to the configured Table endpoint (public or
private, as deployed). Replace placeholders:

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

**This is a guarded Resume, not an automatic root-cause repair.** Use it for `NeedsAttention`
after fixing the original problem, or for an expansion-blocked operation with explicit renewal.
It preserves the operation, image and checkpointed intent. It does not fix DNS, grant roles,
increase quota, repair unhealthy VMs or clear ambiguous cleanup. Start with a read-only preview;
it tells you whether this operation is eligible.

#### Domain-join credential failure

`FailureCategory=DomainJoinCredentials` identifies recognized password/account errors from
domain-join failure evidence, not an assumption that every join problem is a password problem.
`ERROR_PASSWORD_EXPIRED` means expired password; `ERROR_LOGON_FAILURE` means incorrect username
or password, not necessarily expiry. Disabled/locked accounts and password-change-required errors
also require correction. Unknown domain/DNS failures are reported without claiming credential expiry.

SHR stops the cycle in `NeedsAttention` **before deleting failed VMs or deployment history**.
It preserves the failed deployment/resource/code in telemetry and bounded provider evidence in
restricted operation state. Never share that raw evidence; it may contain sensitive values.

1. Inspect the identified domain-join extension and confirm the AD account's password,
   lockout/disabled state, DNS/DC reachability and join permissions as appropriate.
2. Have the authorized identity owner correct the account and credentials source. With the
   supplied session-host template, update `DomainJoinUserPassword` in the selected credentials
   Key Vault; a new deployment resolves the current secret. Do not change the pinned template,
   image or configuration hash just to rotate this secret.
3. Explicitly acknowledge the correction on **both** preview and Apply:

   ```powershell
   & "$tools\Repair-SessionHostReplacerOperation.ps1" @shr -AcknowledgeCredentialFix
   & "$tools\Repair-SessionHostReplacerOperation.ps1" @shr -AcknowledgeCredentialFix -Apply
   ```

4. Verify the resumed worker performs guarded cleanup/retry and the replacement actually joins,
   registers and becomes healthy. Acknowledgement does not prove the password was fixed.
   A new failed attempt gets a new identity and stops again on confirmed credential failure.

If its progress window also expired, add `-ExtendDeadlineHours 168` to both commands after the
deadline review below. All lease, active-deployment, configuration and cleanup guards still apply.
The repair tool neither resets AD passwords nor writes Key Vault secrets. Routine operator roles
do not grant those separate identity/secret-management privileges.

For prompt notifications, deploy the [first-failure alert](alerts-guide.md#deploy-the-first-failure-notification)
with an approved Action Group. Main SHR deployment alone does not configure notifications.

Apply requires Function App read/config-list/stop/start, deployment/VM/AVD/Template Spec read access,
and **Storage Table Data Contributor**. Preview is read-only:

```powershell
& "$tools\Repair-SessionHostReplacerOperation.ps1" @shr
# Review the operation, image, host names and deadline; then confirm:
& "$tools\Repair-SessionHostReplacerOperation.ps1" @shr -Apply
```

#### When to use the deadline extension

**Extend only an expired operation progress window, not an individual request timeout.**

| Evidence | Action |
| --- | --- |
| Request timeout, eight-minute invocation-budget yield, or 30-minute lease wait | Do not extend for that reason. Check subsequent ticks or wait for the owner/lease; investigate repeated failures. |
| `NeedsAttention`, but deadline is still valid and expansion is not blocked | Fix the original cause and preview normal repair above; renewal is not required merely to resume. |
| `ExpansionBlocked=true`, `ExpansionBlockedRecovery`, or an operation-deadline-expired error | Investigate why progress stopped. After correcting the blocker and reviewing live work, preview repair with `-ExtendDeadlineHours`. A safety refusal still applies. |

Read `ExpansionBlocked`, `LastProgressUtc` and `DeadlineUtc` in technical cycle records/native
structured messages, or the current Table state. Terminal `NeedsAttention` can replace the
displayed recovery phase; inspect the flag/error, not the phase alone. Normal preview also
explicitly reports **"The deadline expired. Explicitly approve -ExtendDeadlineHours before recovery."**
when its checks reach an expired deadline.

For a reviewed seven-day renewal, use the same option on preview and Apply:

```powershell
& "$tools\Repair-SessionHostReplacerOperation.ps1" @shr -ExtendDeadlineHours 168
& "$tools\Repair-SessionHostReplacerOperation.ps1" @shr -ExtendDeadlineHours 168 -Apply
```

This sets a new deadline **168 hours from the recovery check**, resets the progress baseline,
clears the expansion block, and sets this operation's subsequent progress windows to 168 hours.
It does not add time to the old deadline or change future operations' configuration.
Large pools can run longer than seven days while making meaningful progress; routine timer
ticks/retries are not progress, and waits solely for scheduled authorization are excluded.
Legacy fixed-deadline operations opt into the progress policy when explicitly renewed.
Pending cleanup or active deployments can still prevent the tool from applying renewal.

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

### Collect guest logs when deployment errors are generic

**Automatic:** SHR makes at most one supplemental extension instance-view GET per failure
diagnosis, with one attempt and the existing ten-second GET timeout. It selects a failed extension
inside the configured VM RG. `FailureInstanceViewOutcome` reports `Captured`, `NoStatus`,
`Unavailable` or `NotApplicable`. At most eight status entries / 2,048 characters are retained in
`State.DeploymentFailure.InstanceViewDiagnostics`, **not** emitted to telemetry.
Unavailable diagnostics warn but do not prevent normal guarded retry. Instance view can contain
stale status, so it supplements investigation; it does not override the ARM-based credential
stop decision.

**On demand:** Use [Export-SessionHostReplacerGuestDiagnostics.ps1](../tools/Export-SessionHostReplacerGuestDiagnostics.ps1)
for a VM that still exists. Supply the **VM** resource ID, not its extension/deployment ID:

```powershell
$vmId = '/subscriptions/<subscription-id>/resourceGroups/<vm-rg>/providers/Microsoft.Compute/virtualMachines/<vm-name>'
& "$tools\Export-SessionHostReplacerGuestDiagnostics.ps1" -VirtualMachineResourceId $vmId
& "$tools\Export-SessionHostReplacerGuestDiagnostics.ps1" -VirtualMachineResourceId $vmId -Apply
```

Preview only reads ARM. Apply prompts, rechecks VM identity/SHR deployment tag, then runs a
read-only payload **as SYSTEM** using action Run Command. This is privileged guest execution,
not resource Reader access. Requires PowerShell 7.4+, `Az.Accounts`, `Az.Compute`, matching
active subscription, a ready VM agent and the agent's approved cloud-specific endpoint access.
Private endpoints do not by themselves guarantee Run Command connectivity. Validate this
separately in Secret/Top Secret; do not open public egress to bypass the approved network model.

It reads only the last 64 lines of `NetSetup.log` and the newest JsonADDomainExtension log,
selects up to 12 relevant lines per source, limits line length and trims the combined UTF-8
JSON envelope to 3,500 bytes. Action Run Command only returns the last 4,096 bytes.
Credential-like assignments and URLs are redacted; **this is not comprehensive DLP**.
The report can contain identities, domains and OU paths. It is saved in a new caller-only
directory under git-ignored `customer/shr-diagnostics/`; only its location and source counts
are printed. Review it locally before sharing. Missing/unreadable logs and output-budget
omissions are explicit per-source outcomes, and incomplete collection warns.

Collection does not enable Netlogon debug logging, alter credentials, repair the VM, change SHR
state or block automatic recovery. Confirmed credential failures retain their failed VM already.
Other failures can be cleaned automatically before collection: if preservation is needed, use
the approved Function App stop process and account for in-flight work. Disabling **initiation**
alone does not stop the worker; stopping the app cannot undo an already accepted VM deletion.
After a collector timeout, inspect Run Command/agent status before retrying; the submitted
command may still be running. Do not recover/redeploy merely to make diagnostic collection work.

DNS/DC discovery errors such as `1355` / `0x54B`, DNS errors `0xA8B` / `0x232A`, and RPC errors
`0x6BF` / `0x6D9` are investigation hints, not proof of a permanent fault. A bad OU has no single
dependable extension error code: check its distinguished name, existence and delegated join
permissions using the provider details/excerpts. None of these codes alone adds a new stop guard.
See [Microsoft domain-join guidance](https://learn.microsoft.com/troubleshoot/windows-server/active-directory/active-directory-domain-join-troubleshooting-guidance)
and [Run Command limits](https://learn.microsoft.com/azure/virtual-machines/windows/run-command).

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
