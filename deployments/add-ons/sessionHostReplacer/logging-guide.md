# Session Host Replacer - Logging Guide

Use the [design overview](../../../docs/session-host-replacer.md#what-operators-see) for the monitoring
model and [Trace one replacement cycle](README.md#trace-one-replacement-cycle) for workbook navigation.

## Where Logs Go

When `logAnalyticsWorkspaceResourceId` is nonempty, SHR creates workspace-based Application
Insights and configures the Function App's `APPLICATIONINSIGHTS_CONNECTION_STRING`.
The optional workbook queries selected Application Insights resources.

```text
Both timers + shared lifecycle engine
  -> PowerShell streams -> Azure Functions host -> Application Insights
                                                -> linked Log Analytics workspace
```

SHR disables its separate Function App diagnostic setting for `FunctionAppLogs`. That table is
not the source for the current workbook. Existing diagnostic settings are not deleted by an
incremental redeployment; see [collection-path cleanup](README.md#function-app-log-collection).
Without a supplied workspace, the template does not enable this Application Insights/workbook
path. Local or streamed output is not a substitute for retained telemetry.

The examples below run in **Application Insights > Logs**, using `traces`, `exceptions` and
`requests`. In a workspace-native query, the corresponding tables are `AppTraces`,
`AppExceptions` and `AppRequests`, with different column names (for example `TimeGenerated`,
`Message` and `Properties`). Do not paste an Application Insights query unchanged into that schema.

## Normal Output Versus Diagnostics

`Write-LogEntry` maps Information to `Write-Host`, Warning to `Write-Warning`, Error to
`Write-Error`, Trace to `Write-Verbose`, and Debug to `Write-Debug`. **Host is a PowerShell
output command, not a separate SHR severity or an always-visible collection tier.**

| Level | Current purpose |
| --- | --- |
| Information | Initiation and non-idle reconciliation timer starts/outcomes, authorization, deployment submission, lease waits, host actions and the final active-pass cycle observation |
| Information dashboard records | `SETTINGS`, `IMAGE_INFO`, `METRICS` and `ACTION`; snapshots are not additional host operations |
| Information replica records | `IMAGE_REPLICA_CAP`, `IMAGE_REPLICA_BATCH`, `IMAGE_REPLICA_SUBMISSION`; live replica capacity and planned/submitted counts |
| Warning | Blockers or unexpected conditions needing investigation; a warning can defer work, not just describe a harmless issue |
| Error / native exceptions | Invocation failures and critical API, state or deployment failures; timer failures are rethrown |
| Trace / Debug | Internal checkpoints, repeated deployment observations, planning, cache and per-host diagnostics |

`Reconciling`, `Checkpoint`, `Progress` and repeated `DeploymentObserved` structured events use
Trace. Their absence from an Information-level timeline is expected. Later read-only polls of
a stopped operation report `NeedsAttention` without replaying its saved exception as a new Error
every minute. Inspect the original failed invocation; counting only recent Error rows misses
persistently stopped work.

Successful idle reconciliation ticks (no operation, or an already completed/superseded operation)
emit no routine SHR application messages, including no `SHR_TIMER` start/success pair. They still
perform the state lookup. A failed lookup emits `SHR_TIMER Failed` and rethrows even though no
start was logged. Active work, lease waits and stopped operations retain their diagnostics;
the invocation that completes a cycle still reports completion.

Azure Functions can still emit native execution traces and `requests` telemetry for idle
invocations. Explicitly enabled Trace diagnostics can also include authentication details.
This change does not filter those records, change sampling, or fix duplicate Application
Insights ingestion. Use native invocation IDs and raw records to investigate duplicates.
The workbook's timer health and frequency views use native completed invocation records,
deduplicated by native invocation identity; they do not depend on SHR idle heartbeats.

The deployed `host.json` contains only `"version": "2.0"`; SHR does not deploy an explicit
log-level or sampling policy. Verify effective host settings and app-setting overrides. Preserve
Information collection for Function logs and `Host.Results`; raising thresholds can remove
dashboard records and successful invocation telemetry.

## Cycle Correlation

- **Cycle ID:** the persisted SHR operation ID, spanning timers, invocations and authorized batches.
- **Batch:** the operation's deployment-batch number, not an invocation count.
- **Trigger:** `Initiation` or `Reconciliation`.
- **Invocation ID / native operation ID:** Azure Functions/Application Insights identifiers, not
  the SHR cycle. The workbook uses native invocation identity for drill-down; its log joins can
  fall back to native operation identity without relabeling it an invocation ID.

```text
[pool] [Cycle:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa] [Batch:2] [Trigger:Reconciliation] ACTION | Deployed:2
```

The pool remains the first bracket and the original message remains the suffix for existing
dashboard parsers. Correlation is invocation-local and cleared in `finally`. Idle reconciliation
does not attach a completed cycle to a new invocation.

### Structured events

Structured records are **JSON in trace message text**, not native `customEvents` or automatically
populated custom dimensions. Parse the suffix `SHR_TIMER | {json}` or `SHR_EVENT | {json}`.
The current contract is `SchemaVersion: 1`.

The PowerShell helper accepts `Write-ShrEvent -EventName ...`; `-Event` remains a compatibility
alias. The parameter avoids PowerShell's automatic `$Event` variable. The JSON field remains
`Event`, so workbook and alert queries do not change.

- Common fields: `Event`, `Trigger`, `CycleId`, `Batch`, `FunctionApp`, `Phase`,
  `InitiationEnabled`, `Reason`.
- Cycle snapshots can also carry `Status`, `StartedUtc`, `DeadlineUtc`, `LeaseExpiresUtc`,
  `LeaseHeld`, `ImageVersion`, `ImageDefinition`, `Target`, `DeploymentName`,
  `DeploymentResourceId`, `SupersedesCycleId`, `InDrain`, `RunningDeployments`.
- Timer events: `Started`, then `Succeeded` or `Failed` for initiation and non-idle reconciliation.
  Idle reconciliation omits both events; a failed state lookup can emit `Failed` without `Started`.
  Timer success is not cycle completion.
- Cycle events describe authorization, deployment, waiting, supersession and terminal outcomes.
  Wait reasons distinguish cleanup, deployment, readiness, scheduled authorization and drain.

Structured payloads allowlist metadata and exclude saved deployment bodies, credentials, tokens,
host-name arrays, configuration hashes and raw `LastError`. Deployment links contain validated ARM
resource paths, not query strings or a fixed cloud Portal hostname. This is not a claim that every
native error or ordinary diagnostic message is sanitized; restrict telemetry access and protect
exported logs. Telemetry adds no separate ARM/Table requests or durable-state writes.

Native timer views accept `requests.name` with or without the `Functions.` prefix. Completion
time is `timestamp + (duration * 1ms)` because `requests.duration` is in milliseconds; these records
describe completed invocations, not a live-running
invocation. Host-pool filtering maps the app/resource identity to SHR trace messages in the
selected time range. If that mapping is absent, use **All Host Pools** to see native timer rows
by Function App. Keep `Host.Results` at Information and validate these fields, mappings and
queries in the live pilot; offline contract checks do not prove ingestion or KQL execution.

## Query Both Timers

Run this in the SHR Application Insights resource. It includes both timer names and their `.User`
categories, plus native exceptions. The exact-category filter
`Category == "Function.session-host-replacer-initiator"` misses the worker and user-category records.
The prefix below also includes historical records from the legacy `session-host-replacer` name.

```kusto
union traces, exceptions
| where timestamp > ago(1d)
| where tostring(customDimensions.Category) startswith "Function.session-host-replacer"
| project timestamp, cloud_RoleName, operation_Id,
          InvocationId = tostring(customDimensions.InvocationId),
          severityLevel, Detail = coalesce(message, outerMessage, innermostMessage)
| order by timestamp desc
```

For last-reported cycle state:

```kusto
traces
| where timestamp > ago(7d)
| where message contains "SHR_EVENT |"
| extend Data = parse_json(extract(@"SHR_EVENT \| (\{.*\})$", 1, message))
| where toint(Data.SchemaVersion) == 1 and isnotempty(tostring(Data.CycleId))
| extend CycleId = tostring(Data.CycleId)
| summarize arg_max(timestamp, *) by cloud_RoleName, CycleId
| project timestamp, cloud_RoleName, CycleId, Status = tostring(Data.Status),
          Phase = tostring(Data.Phase), Reason = tostring(Data.Reason)
| order by timestamp desc
```

These queries report ingested evidence, not live state. Bound and select the time range to include
the operation's start and latest observation. No rows do not prove health. See
[suggested alerts](alerts/alerts-guide.md) for structured cycle/timer queries and response guidance.
They are documentation examples, not deployed rules; the
[legacy pack](alerts/alerts-guide.md#current-coverage-limitations) does not implement them.

Graph failure diagnostics support both PowerShell 7 HTTP response bodies and legacy response
streams. If those details cannot be read or emitted, a Trace diagnostic records that limitation;
the original HTTP failure still controls retry, endpoint fallback, and failure handling.

## Temporarily Collect Trace Diagnostics

Querying logs does not enable logging or recover records that were never emitted or ingested.
Both gates must be open:

1. Before module import, set `$global:VerbosePreference = 'Continue'` in the startup profile for
   verbose emission from nested modules. Debug output separately needs
   `$global:DebugPreference = 'Continue'`.
2. Permit Trace in the Functions host for **both** functions. Temporary app-setting overrides
   can use `AzureFunctionsJobHost__logging__logLevel__Function.session-host-replacer-initiator=Trace`
   and `AzureFunctionsJobHost__logging__logLevel__Function.session-host-replacer-worker=Trace`.
   Check for more-specific category overrides that could still filter `.User` messages.
3. Apply changes through the controlled deployment/configuration process, account for app
   restarts, then confirm a known diagnostic record reaches Application Insights. Runtime-version
   settings do not enable verbose logging.
4. Restore the normal profile and log levels after the investigation. Trace can be high-volume
   and contain sensitive diagnostics; do not leave it enabled as the production baseline.

Sampling, ingestion delay and network/private-link failures can still leave gaps. Check both timer
outcomes, cycle observation age and inventory age after a runtime/workbook upgrade in the target
cloud. Old logs are not backfilled into the structured schema.

References: [PowerShell logging in Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell#logging),
[Functions monitoring configuration](https://learn.microsoft.com/en-us/azure/azure-functions/configure-monitoring#configure-log-levels).
