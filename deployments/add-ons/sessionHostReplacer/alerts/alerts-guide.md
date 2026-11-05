# Session Host Replacer - Suggested Alerts

The workbook helps an operator investigate replacement activity. Alerts should tell that
operator when attention is needed: replacement has stopped, a timer is failing, or expected
reconciliation telemetry has disappeared.

**These are recommendations and example queries, not deployed functionality.** SHR does not
deploy these alerts or configure notification recipients. The existing standalone alert pack
does not implement this design; see [Current coverage limitations](#current-coverage-limitations).

## Recommended Starting Set

| Alert | What it means | Suggested severity | Initial condition |
| --- | --- | --- | --- |
| Replacement needs intervention | SHR has stopped an operation that needs checked recovery | Sev 1 (Error) | Latest observed cycle state is `NeedsAttention` |
| Timer failures | Replacement coordination is encountering execution failures | Sev 2 (Warning) | Three reconciliation invocations fail within 15 minutes and the latest outcome is failed; for initiation, alert on the latest failed outcome |
| Reconciliation outcome missing | SHR is no longer reporting completion of its expected minute-timer invocations | Sev 2 (Warning) | No reconciliation success or failure observed for 15 minutes |

These are starting points, not service-level guarantees. A stopped replacement does not
necessarily mean desktops are unavailable. Confirm actual user impact before treating it as
a critical outage.

An initiation failure is worth reporting on its own because its next scheduled attempt may be
hours away. Reconciliation retries every minute, so its example tolerates isolated failures.

## Query and Rule Configuration

- Run the examples in the SHR **Application Insights resource's Logs view**. They use the
  Application Insights `traces` and `requests` schemas, not workspace-native `AppTraces`,
  `AppRequests` or `FunctionAppLogs`.
- Replace `<shr-function-app-name>` with the exact app identity observed in `cloud_RoleName`.
  Each example targets one app. Repeat deliberately for other apps rather than querying every
  Function App in a shared monitoring environment.
- Cycle state uses SHR's `SHR_EVENT` trace messages with `SchemaVersion: 1`; timer health
  uses native Functions invocation records in `requests`, including successful idle ticks.
  These are not Microsoft AVD Insights host/session tables. See the
  [telemetry contract](../logging-guide.md#cycle-correlation).
- Keep Information-level Function logs and `Host.Results` telemetry enabled. Idle reconciliation
  deliberately emits no `SHR_TIMER` messages; do not use their absence as an outage signal.
  Cycle `NeedsAttention` events are Information records, not native custom events.
- Each query returns **only rows requiring attention**. For a manually configured log search
  alert, use **Table rows**, **Greater than 0**, evaluation every **5 minutes**, and a **2-hour
  query lookback**, with one failing evaluation initially. Ensure the rule's effective query
  time range actually covers the full two hours; an `ago(2h)` expression cannot restore rows
  excluded by a shorter rule lookback.
- Use stateful alerting with automatic resolution. Split by `FunctionApp`, adding `Trigger`
  for timer failures. Keep cycle IDs, invocation IDs and timestamps as investigation context,
  not changing split dimensions. Resolution follows Azure Monitor's evaluation policy; it is
  not an immediate acknowledgement that the service is healthy.
- If configuring notifications later, use an approved Action Group. A query returning rows
  does not deliver a notification by itself.

The two-hour examples suit the default half-hour initiation schedule. For a sparse or
business-hours schedule, tune the initiation failure observation window and response procedure
to that schedule and the target cloud's supported alert lookback limits. Do not infer missing
initiation from a fixed elapsed-time threshold.

## 1. Replacement Needs Intervention

**Why:** An operation can remain stopped while minute-timer invocations succeed: they report
the stopped state without repeating the original exception. An Error-count rule misses this.

Select the latest observation **before** filtering its status, so an observed recovery,
completion or supersession replaces an earlier failure.

```kusto
let functionAppName = "<shr-function-app-name>";
traces
| where timestamp > ago(2h)
| where cloud_RoleName == functionAppName
| where message contains "SHR_EVENT |"
| extend Data = parse_json(extract(@"SHR_EVENT \| (\{.*\})$", 1, message))
| where toint(Data.SchemaVersion) == 1
| extend CycleId = tostring(Data.CycleId)
| where CycleId matches regex @"^[a-f0-9]{32}$"
| summarize arg_max(timestamp, Data) by FunctionApp = cloud_RoleName, CycleId
| where tostring(Data.Status) == "NeedsAttention"
| project FunctionApp, CycleId, LastObservedUtc = timestamp,
          Reason = tostring(Data.Reason), ImageVersion = tostring(Data.ImageVersion)
```

**Response:** Open the workbook's cycle and failed invocation, inspect the linked ARM deployment
and current host capacity, then correct the cause. Use the
[checked recovery procedure](../README.md#recover-a-stopped-operation); do not clear state,
leases or pending-name mappings to silence an alert.

**Expected resolution:** A later observation for that same cycle reports `Running`, `Completed`
or `Superseded`. Repeated `NeedsAttention` observations should keep the condition active.
If telemetry simply stops or ages out of the lookback, the query can also stop returning the
cycle. That is loss of evidence, not proof of recovery; check the missing-outcome alert too.

## 2. Timer Failures

**Why:** Failures can occur before an operation exists or before its state can be updated.
Monitor both `Initiation` and `Reconciliation`, independently of cycle status.

Deduplicate by native invocation identity, falling back to the native request ID if the
invocation dimension is absent. Use completed invocation records so a successful idle tick can clear
an earlier failure without adding SHR heartbeat messages. A later successful
outcome clears this condition even while older failures remain in the lookback.

```kusto
let functionAppName = "<shr-function-app-name>";
requests
| where timestamp > ago(2h)
| where cloud_RoleName == functionAppName
| extend FunctionName = replace_regex(name, @"^Functions\.", ""),
         InvocationKey = coalesce(tostring(customDimensions.InvocationId),
             tostring(customDimensions["prop__InvocationId"]), id)
| where FunctionName in ("session-host-replacer", "session-host-replacer-initiator", "session-host-replacer-worker")
| where isnotempty(InvocationKey) and isnotnull(success)
| extend Trigger = iff(FunctionName == "session-host-replacer-worker", "Reconciliation", "Initiation"),
         Outcome = iff(success, "Succeeded", "Failed"), CompletedUtc = timestamp + (duration * 1ms)
| summarize arg_max(CompletedUtc, Outcome) by FunctionApp = cloud_RoleName, Trigger, InvocationKey
| summarize FailedInvocationsIn15m = countif(Outcome == "Failed" and CompletedUtc > ago(15m)),
            arg_max(CompletedUtc, Outcome) by FunctionApp, Trigger
| where Outcome == "Failed"
| where Trigger == "Initiation" or (Trigger == "Reconciliation" and FailedInvocationsIn15m >= 3 and CompletedUtc > ago(15m))
| project FunctionApp, Trigger, LastOutcomeUtc = CompletedUtc, FailedInvocationsIn15m
```

Confirm `requests.name`, `duration`, `success` and native correlation keys in the target cloud.
These examples accept the function name with or without a `Functions.` prefix.
Rows without either key are excluded because they cannot be reliably deduplicated; do not rely
on this example until that prerequisite is verified. Duplicate ingestion must not count as
additional failed invocations.

**Response:** Investigate the latest failed invocation's native exception and correlated traces.
Check identity, storage access, network connectivity and configuration. If a cycle is also
`NeedsAttention`, fixing the underlying dependency alone does not resume it; follow checked recovery.

**Expected resolution:** The same timer has a later successful native invocation, including an
idle reconciliation with no SHR messages. Reconciliation also
falls below its condition as failures leave the 15-minute window. An old initiation failure can
age out after two hours without a new attempt; for sparse schedules, confirm the next expected
run rather than interpreting that disappearance as recovery.

## 3. Reconciliation Outcome Missing

**Why:** An app that is stopped, cannot run its timer, or cannot send telemetry may produce no
failure event. A query based only on observed failures cannot detect an entirely silent app.

Seed the expected app explicitly so the query returns a row even if it has **never** emitted
telemetry. Check outcomes, not just starts: a start with no observed completion is not success.

```kusto
let ExpectedApps = datatable(FunctionApp:string)
[
    "<shr-function-app-name>"
];
let LastObservations =
    requests
    | where timestamp > ago(2h)
    | where cloud_RoleName in (ExpectedApps)
    | extend FunctionName = replace_regex(name, @"^Functions\.", "")
    | where FunctionName == "session-host-replacer-worker" and isnotnull(success)
    | summarize LastStartedUtc = max(timestamp), LastOutcomeUtc = max(timestamp + (duration * 1ms))
        by FunctionApp = cloud_RoleName;
ExpectedApps
| join kind=leftouter LastObservations on FunctionApp
| where isnull(LastOutcomeUtc) or LastOutcomeUtc < ago(15m)
| project FunctionApp, LastStartedUtc, LastOutcomeUtc,
          Reason = iff(isnull(LastOutcomeUtc),
              "No reconciliation outcome observed in the two-hour lookback.",
              "No reconciliation outcome observed in the last 15 minutes.")
```

The 15-minute starting threshold allows for the configured ten-minute invocation timeout and
some ingestion delay. Measure actual ingestion latency and tune it; cold starts, restarts or
platform issues can take longer. A live operation lease may defer host changes, but a healthy
timer still produces native invocation telemetry. `LastStartedUtc` is the start of an observed
completed invocation, not evidence that a different invocation is currently running.

**Response:** Check whether the app was intentionally stopped, then verify its state, worker
binding, host storage access, effective log levels and Application Insights ingestion/private
connectivity. This alert cannot distinguish an automation outage from a telemetry outage.
Use current Azure resource evidence to make that distinction.

**Expected resolution:** A recent successful **or** failed native reconciliation invocation is observed.
A failed outcome restores visibility, not health; the timer-failure or stopped-cycle alert may
still need attention. `InitiationEnabled=false` does not suppress this check: reconciliation
should continue even while new replacement batches are held.

## Avoid Alerting on Expected Waiting

Do not treat these conditions alone as failures:

- No new batch while initiation is intentionally paused or outside its configured schedule.
- Waiting for scheduled authorization, a live lease, capacity or scaling-plan safety gates.
- Old hosts draining within their configured grace period.
- A new replacement that has not yet finished deployment or readiness checks.
- An idle pool without SHR application messages; native invocation telemetry is the timer signal.

Do not use a generic "cycle older than 30 minutes" or "no host actions" rule. Normal drain
periods and rollout schedules can be much longer. Route repeated warnings and detailed wait
diagnostics to the workbook before deciding whether a separate, mode-aware alert is warranted.

Suppress notifications for a deliberately stopped app during an approved upgrade using a
time-bounded maintenance process. Do not suppress missing reconciliation merely because new
batch initiation is held.

## Additional Alerts to Consider Later

**Deleted hosts with blocked recovery** deserve higher urgency when they represent real
capacity loss. The current structured events do not expose enough pending-host/available-capacity
evidence to assert that condition reliably. It needs a reviewed telemetry contract before a
recommended query; do not join unrelated warning messages to infer an outage.

Capacity and user-experience alerts should come from authoritative AVD/VM monitoring and be
correlated with SHR, not inferred from timer success or an old inventory snapshot. Routine
completion and progressive-batch milestones belong in the workbook unless operators explicitly
want informational notifications.

## Validate Before Relying on These Suggestions

The queries are documentation examples, not evidence of successful Azure query execution or
alert delivery. Validate in an isolated pilot in each target cloud:

1. Confirm current schema-version-1 cycle records and native `requests` for both functions,
   including idle reconciliation. Verify names, success, duration, invocation keys, Application
   Insights scope and actual ingestion delay/sampling. `Host.Results` must remain collected.
2. Observe `NeedsAttention`, then checked recovery/completion/supersession. The stopped-cycle
   query should return one row per stopped app/cycle and stop returning it after a later
   non-stopped observation for that cycle.
3. Check one versus three distinct reconciliation failures, duplicate records, one initiation
   failure, and a later successful idle invocation. Only the documented conditions should return rows.
4. Test no telemetry, starts without outcomes, stale outcomes and restored outcomes, including
   a `Failed` outcome. Confirm the seeded query still detects a completely silent expected app.
5. Confirm an initiation hold, a healthy idle pool, long drains and normal lease waits do not
   trigger these conditions when timer outcomes remain healthy.
6. If manually creating alert rules, verify effective lookback, row-count threshold, stable
   dimensions, firing and automatic resolution. Test Action Group delivery separately.

Do not manufacture production failures or delete recovery state to test alerts. A `Write-Host`
message from an operator shell is not a Functions invocation and does not prove end-to-end
collection, alert evaluation or notification delivery.

## Current Coverage Limitations

The legacy [Bicep alert pack](alertRules.bicep) and
[standalone deployment script](Deploy-SessionHostReplacerAlerts.ps1) remain unchanged. They
contain duplicated, historical message-based queries rather than the suggested rules above.
Known issues include:

- No equivalent structured stopped-cycle or missing-outcome coverage.
- A low-capacity rule in the Bicep pack joins separate records on identical timestamps.
- A blocked-deletions rule requires more than 60 minutes inside a one-hour query window.
- Progressive-scale-up regex escaping in Bicep does not match representative messages.

Do not assume running those deployment tools creates the recommendations in this guide.
Repairing or integrating them is a separate implementation task. No alert deployment, UI
parameter, runtime telemetry change or notification configuration is introduced here.

## References

- [SHR design and monitoring overview](../../../../docs/session-host-replacer.md#what-operators-see)
- [Logging and correlation](../logging-guide.md)
- [Trace one replacement cycle](../README.md#trace-one-replacement-cycle)
- [Create Azure Monitor log search alert rules](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule)
