# Session Host Replacer - Logging Guidelines

## Logging Levels

The SessionHostReplacer uses `Write-LogEntry` with Information, Warning, Error, Trace and Debug
output. Timer health and operational cycle summaries use Information; internal cycle diagnostics use Trace.

- **Information**: Important status messages for tracking progress
- **Trace**: Detailed diagnostic information written to the PowerShell verbose stream
- **Debug**: Diagnostic information written to the PowerShell debug stream
- **Warning**: Issues that don't stop execution
- **Error**: Failures that impact functionality

## Cycle correlation

Start with the [workbook tracing procedure](README.md#trace-one-replacement-cycle), rather than
treating every Function invocation as a complete replacement cycle.

- **Cycle ID** is the durable operation's ID. It spans initiation, reconciliation and authorized
  batches until terminal completion, supersession or checked recovery.
- **Batch** is the operation's deployment-batch number, not an invocation count.
- **Trigger** is `Initiation` or `Reconciliation`.
- **Invocation ID** and **native operation ID** come from Azure Functions/Application Insights.
  They are distinct from the SHR cycle ID. The workbook uses the native invocation ID when
  available and falls back to native operation identity only for log joins; it never labels that
  fallback as an invocation ID.

An ordinary correlated message looks like:

```text
[pool] [Cycle:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa] [Batch:2] [Trigger:Reconciliation] ACTION | Deployed:2
```

The host pool remains the first bracket and the original message remains the suffix, preserving
existing metrics/action parsers. Correlation is invocation-local, refreshed at checkpoints and
cleared in `finally`, including failed invocations. Idle reconciliation of absent or terminal
operations does not attach an old cycle ID to minute-timer heartbeats.

### Structured events

Structured messages end with `SHR_TIMER | {json}` or `SHR_EVENT | {json}`.
The JSON contract has `SchemaVersion: 1`:

- Common fields: `Event`, `Trigger`, `CycleId`, `Batch`, `FunctionApp`, `Phase`,
  `InitiationEnabled` and a safe `Reason`.
- Cycle snapshots additionally allow `Status`, `StartedUtc`, `DeadlineUtc`, `LeaseExpiresUtc`,
  `LeaseHeld`, `ImageVersion`, `ImageDefinition`, `Target`, `DeploymentName`,
  `DeploymentResourceId`, `SupersedesCycleId`, `InDrain` and `RunningDeployments`.
- Timer events record `Started` and `Succeeded` or `Failed`; failures are rethrown, not hidden.
- Cycle events cover initiation/authorization, supersession, checkpoints, deployment submission/
  observation, reconciliation, lease waits, progress and terminal outcomes.

### Normal output versus diagnostics

Normal Information output retains timer starts/outcomes, initiation and batch authorization,
new deployment submissions, lease waits, actual host actions and a final cycle snapshot for
each active reconciliation pass. `SETTINGS`, `IMAGE_INFO`, `METRICS` and `ACTION` records remain
at Information because existing workbook configuration, inventory and action panels consume them.
These dashboard records are not additional host operations.

Repeated engine startup/completion banners, VM caching, planner arithmetic, image enumeration,
unchanged per-host sessions/drain timing and duplicate action narration use Trace. Internal
`Reconciling`, `Checkpoint`, `Progress` and repeated `DeploymentObserved` snapshots also use Trace;
progress counts still feed the final Information-level snapshot. Detailed checkpoint events are
therefore diagnostic, not guaranteed rows in the normal workbook timeline.

An actual invocation failure still surfaces its error and is rethrown. Later read-only polls of
that stopped operation report `NeedsAttention` without replaying its saved exception as a new
Error every minute; the saved detail is diagnostic. Host-availability blockers have one
mode-specific warning rather than repeating the same warning in multiple layers and listing
every unavailable host at Warning. Per-host details remain available at Trace.

No persistent deduplication cache, new state writes, global sampling or blanket warning/error
suppression is used. Each timer remains visible, and the final cycle observation keeps workbook
freshness honest even when the underlying wait is unchanged.

The structured payload excludes saved deployment bodies, credentials, configuration hashes,
host-name arrays, tokens and raw `LastError`. Stop reasons use fixed descriptions, not exception
text. Deployment links include only a validated ARM deployment resource path, never its query
string or a hard-coded Portal hostname. Detailed errors remain in existing/native logs under
the normal telemetry access controls; the workbook joins traces and exceptions by native
invocation identity, with empty join keys excluded.

Waiting phases distinguish cleanup, ARM deployment, host availability, next scheduled
authorization, draining and other progress checks. `NeedsAttention` and terminal states override
old progress counts. `AuthorizationExpired` is distinct from a successfully completed batch.
Lease ownership is last-reported, so the workbook also shows expiry and observation age.

These are telemetry snapshots, not live Table reads. The workbook bounds cycle summaries and
chronological timelines/logs, honors the selected time range and distinguishes timer heartbeats
from inventory observations. Sampling, ingestion delays or a narrow time range can hide events.
No data is not proof of health. Redeploy both runtime and workbook to use this schema; old logs
are not backfilled. Observability adds no ARM/Table requests or durable-state writes.

## Enabling Verbose Mode

### Option 1: Information-level operational tracing

Timer health, key lifecycle events and final cycle summaries do not need verbose mode. Preserve Information-level Function logging in the
deployed host configuration and verify Application Insights ingestion. Changing
`FUNCTIONS_WORKER_RUNTIME_VERSION` selects a runtime; it does not enable verbose logging.

### Option 2: host.json Configuration
Edit `host.json` in your function app root:

```json
{
  "version": "2.0",
  "logging": {
    "logLevel": {
      "default": "Information",
      "Function": "Information",
      "Host.Results": "Information"
    },
    "console": {
      "isEnabled": true
    }
  }
}
```

### Option 3: Local Development with VSCode
For temporary diagnostics, set the runspace-wide preference before importing the modules
(for example, in the deployed startup profile), so nested modules can write their verbose stream:

```powershell
$global:VerbosePreference = 'Continue'
```

For Azure capture, also configure Function host logging to admit Trace rather than Information.
Both PowerShell stream emission and host ingestion must permit the messages; changing only a
workbook query cannot recover filtered diagnostics. Revert the temporary preference/log-level
changes after troubleshooting and retain the normal Information-level dashboard records.

### Option 4: Query Application Insights
Verbose logs are captured in Application Insights. Query them with:

```kusto
traces
| where timestamp > ago(1d)
| where tostring(customDimensions.Category) startswith "Function.session-host-replacer"
| where severityLevel == 0
| order by timestamp desc
```

## Current Logging Strategy

### Host Level (Always Visible)

- Function start/stop
- Token acquisition status
- Session host counts
- Deployment decisions and submission
- Deletion decisions
- Major state transitions

### Information Level (Default)

- Deployment state tracking
- Previous deployment status checks
- Image version detection
- State persistence operations

### Verbose Level (Diagnostic)

- Individual session host details
- VM tag operations
- Image version enumeration
- API response details
- Cache operations

### Warning Level

- Non-critical failures (Graph token, device cleanup)
- Unexpected conditions that don't stop execution
- Previous deployment still running

### Error Level  

- Token acquisition failures
- Deployment submission errors
- Critical API failures
- State persistence errors

## Recommended Changes

To reduce log noise while maintaining visibility, the following logs should be changed from Host/Information to Verbose:

### In run.ps1:

- Subscription IDs → Verbose
- Token acquisition success → Verbose (keep failure as Host)
- Image reference details → Verbose
- Running deployment count → Verbose

### In SessionHostReplacer.psm1:

- Individual session host processing → Verbose
- VM tag operations → Verbose
- Image version details → Verbose
- Template spec version resolution → Verbose
- State table creation → Verbose
- Individual drain operations → Verbose

### Keep as Host/Information:

- Overall session host counts
- Deployment decisions (how many to deploy/delete)
- Deployment submission results
- Progressive scale-up status
- Previous deployment outcome
- Critical errors
