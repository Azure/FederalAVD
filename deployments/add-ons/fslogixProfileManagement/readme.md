# FSLogix Profile Management Add-On

## Purpose

This optional add-on runs a timer-triggered PowerShell Function App to remove expired FSLogix profiles from Azure Files. The deployed entry point is [scripts/run.ps1](scripts/run.ps1). It uses managed identity and HTTPS FileREST requests, not SMB mounts or a temporary VM.

The [template](main.bicep) accepts a `subscriptionIds` array and serializes it into the comma-separated `SubscriptionIds` Function App setting. The function validates the entire list before making requests, trims whitespace, removes duplicates, and discovers accounts in each subscription. REST request URLs provide the subscription context; no `Set-AzContext` call or Az module is needed.

## Configuration and Permissions

| Function App setting | Purpose |
| --- | --- |
| `SubscriptionIds` | Required comma-separated subscription GUIDs, for example `11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222`. |
| `FileShareName` | Required existing Azure Files share name, supplied by the `fileShareName` deployment parameter; default `profilecontainers`. Must use 3-63 lowercase letters, numbers, or single hyphens, starting and ending with a letter or number. Invalid or missing values fail before discovery or deletion. |
| `DeleteOlderThanDays` | The current script requires an integer from 1 through 2555; default `60`. The Portal slider and Bicep parameter currently permit 1-2555, but values above 2555 cause the script to fail before discovery or deletion. |
| `Cloud` | Deployment supplies `environment().name`. The script maps `AzureCloud`, `AzureUSGovernment`, and `USSEC` to Resource Manager and Graph endpoints. Other clouds have no configured script endpoint. |
| `ResourceManagerUrl` | Supplied by the template, but the current script derives its endpoint from `Cloud` rather than reading this setting. |
| `WEBSITE_TIME_ZONE` | Supplied by the template's `timeZone` parameter; default `UTC`. Controls the timer's time zone on the Windows Function App. |
| `IDENTITY_ENDPOINT`, `IDENTITY_HEADER` | Host-provided managed identity settings; do not configure or log these values manually. |

Enable the Function App's **system-assigned managed identity** and grant it **Reader** and **Storage File Data Privileged Contributor** in every target subscription. The solution creates these Azure role assignments. User-assigned identity selection and VM/IMDS authentication are not supported by the script. The separate deployment identity used for storage CMK is not used by the cleanup script.

The Storage token audience is `https://storage.azure.com/`. Resource Manager and Microsoft Graph tokens are requested separately and cached by audience. There is no deployed `GraphResourceUrl` parameter or script override; verify the `Cloud` mapping before use in another cloud or a US DoD tenant.

The host needs HTTPS connectivity to Resource Manager, Azure Files, and, for display-name enrichment, Microsoft Graph. Private storage endpoints require appropriate DNS, routing, and firewall configuration.

For private Function App networking, the portal's outbound subnet dropdown includes only subnets delegated to `Microsoft.Web/serverFarms`. It checks every delegation, ignores service-name casing, and excludes subnets with no delegations.

Private and service modes require `functionAppDelegatedSubnetResourceId` for outbound VNet integration and `subnetResourceId` for private endpoints or service-endpoint configuration. Private mode also requires the blob, Function App, and Key Vault private DNS zone IDs, with the zones linked to the integration VNet. Resource naming placeholders in the Portal form include the `fpm` purpose suffix; replace the placeholders with valid names before deployment.

**When using service endpoints, every target FSLogix storage account must trust the Function App's outbound VNet integration subnet** (`functionAppDelegatedSubnetResourceId`) in its networking configuration. Enable the appropriate Azure Storage service endpoint on that subnet and add it to the storage account's allowed virtual networks under **Networking**. Allowing only the session-host subnet or enabling the trusted Azure services exception is not a substitute for this subnet rule; managed-identity permissions alone do not bypass the storage firewall.

Monitoring is optional through `logAnalyticsWorkspaceResourceId`. The Portal form also requires an Azure Monitor Private Link Scope when monitoring is enabled in private mode; direct template deployments permit omitting it, which leaves Application Insights ingestion and query endpoints public. The [workbook](workbook/fslogix-profile-management.workbook) remains a separate import, not a deployed resource.

### Entra Display-Name Enrichment

Grant the Function App's system-assigned identity the Microsoft Graph **`User.Read.All` application permission** with administrator consent. This is an Entra application permission, not an Azure RBAC role, and the template does **not** grant it automatically.

- The script extracts a SID from the top-level profile folder name, supporting SID-first and username-first folder names.
- Entra `S-1-12-1-...` SIDs are converted to an object GUID and queried through Microsoft Graph.
- Other SIDs are matched against users' `onPremisesSecurityIdentifier`. This requires the user's AD SID to be synchronized into Entra; local-only, deleted, or otherwise unsynchronized users might not resolve.
- Results are cached by SID for the execution. The original SID is always retained when present.
- Lookup statuses are `Resolved`, `NoSid`, `NotFound`, or `Failed`. Permission, network, malformed-response, or ambiguous-match failures emit a `UserLookupFailed` record and do **not** prevent cleanup.
- Display names are descriptive metadata, not unique identifiers or deletion criteria. User lookup happens only for approved deletions; `-WhatIf` does not query Graph.

## Discovery, Schedule, and Deletion

- Set the six-field Functions NCRONTAB expression through the Portal's **Cron schedule** field or the template's `schedule` parameter. The schedule is deployed into the timer binding, not a `CronTimerSchedule` app setting. Azure Functions validates the timer expression.
- Lists all storage accounts in each configured subscription, then each account's shares. Both management-plane listings are paginated.
- Set **FSLogix profile file share name** under the Portal's **Script > Settings**, or pass the `fileShareName` deployment parameter. The default remains **`profilecontainers`**. For an ARM parameter file, add `"fileShareName": { "value": "my-profiles" }` under `parameters`; for Azure CLI, append `fileShareName=my-profiles` to `--parameters`.
- Processes only the share whose name exactly matches `FileShareName`, using the account's advertised file endpoint. The same name applies across all selected subscriptions and storage accounts; this add-on does not create or rename shares. Accounts without an Azure Files endpoint or the target share are logged and skipped. Deploy the updated template and script together so the app setting is present.
- By default, runs **daily at 21:00 UTC** (`0 0 21 * * *`). Select `timeZone` through the Portal or template to use UTC, Eastern, Central, Mountain, or Pacific Windows time zones. There is no first-week or first-Tuesday guard in the script; a manual invocation runs cleanup regardless of the date.
- Uses the newer of each disk's `LastAccessTime` and `LastWriteTime`. Expiration must be strictly earlier than execution time minus `DeleteOlderThanDays`. Missing or invalid timestamps stop execution.
- Treats each top-level directory as one profile. It deletes that directory and **all contents** only when at least one qualifying `.vhd`/`.vhdx` exists recursively and every qualifying disk is expired. Directories without qualifying disks are retained.
- `Merge.vhdx` and `RW.vhdx` do not determine expiration, but are deleted along with other contents of an expired profile folder. Expired qualifying disks at the share root are deleted individually; the share root is never removed.
- Deletes profile disks first, then other files, then nested directories deepest first, and finally the profile folder. Open handles and leases are not forcibly broken.
- A FileREST **HTTP 403 Forbidden** during listing or deletion emits an `AccountSkipped` event with `Level = Error`, the original error message, and the current subscription/account/share/profile context. The script skips the rest of that storage account and continues with the next account, including subsequent subscriptions. This also applies to `-WhatIf` inventory. The skipped account does not emit `ShareCleanupCompleted`; a later `RunCompleted` means processing finished, not that every account was cleaned.
- FileREST **HTTP 409** with `x-ms-error-code` equal to **`SharingViolation`** or **`DirectoryNotEmpty`** emits `ProfileSkipped` with `Level = Warning` and continues to the next profile in the same share. Root-level disks are skipped individually. The event includes the failed path/item type and profile context; its message records the error code, operation, request ID when supplied, and original error. Cleanup does not force-close SMB handles, break leases, retry conflicts, or delete newly discovered contents. The skipped profile does not emit `ProfileDeleted`, and its remaining contents are left untouched. This also applies to profile inventory in `-WhatIf`.
- No storage firewall changes or additional permissions are required for this handling. Resource Manager discovery failures, managed-identity token failures, unrecognized HTTP conflicts, other HTTP statuses, and non-HTTP cleanup failures still emit `RunFailed` and stop execution. A share-root listing failure has no individual profile to skip and still stops execution unless it is a 403. Deletion is not transactional; successful deletions before any failure are not rolled back. `ShareCleanupCompleted` and `RunCompleted` indicate processing finished; inspect both `AccountSkipped` and `ProfileSkipped` for incomplete cleanup.

From the add-on directory, preview with `.\scripts\run.ps1 -WhatIf` at any time. Preview still authenticates and inventories shares, but does not delete data, query Graph, or emit successful deletion events. It requires the Function App managed-identity environment; a local terminal without that environment cannot authenticate. `-WhatIf` applies only to that invocation; it does not change or disable the deployed timer.

**Run while users are signed out.** Inventory and deletion are not atomic. Maintain backups, validate timestamp behavior against actual FSLogix usage, and test against disposable shares before enabling scheduled deletion.

## Structured Logs and Reporting

Each script event is a single compressed JSON record sent through PowerShell's Information stream for Azure Functions/Application Insights. Helper return values do not contain log messages.

Records have the same base fields: `SchemaVersion`, `TimestampUtc`, `RunId`, `EventType`, `Level`, `SubscriptionId`, `StorageAccount`, `ShareName`, `ShareUri`, `ProfileFolder`, `Path`, `ItemType`, `UserSid`, `UserDisplayName`, `UserId`, `UserLookupStatus`, and `Message`. Fields not applicable to an event are null. `Level` is a JSON field; it does not change the Information stream's telemetry severity.

Deletion events are emitted **after** successful API requests: `DiskDeleted`, `FileDeleted`, `DirectoryDeleted`, and `ProfileDeleted`. Count `ProfileDeleted` for completed profile-folder removals; root-level disks instead generate `DiskDeleted`. All events for an execution share a `RunId`.

Example Application Insights query:

```kusto
traces
| where timestamp > ago(90d)
| extend Record = parse_json(message)
| where Record.SchemaVersion == 1 and Record.EventType == "ProfileDeleted"
| project timestamp,
    SubscriptionId = tostring(Record.SubscriptionId),
    StorageAccount = tostring(Record.StorageAccount),
    Folder = tostring(Record.ProfileFolder),
    UserSid = tostring(Record.UserSid),
    DisplayName = tostring(Record.UserDisplayName),
    LookupStatus = tostring(Record.UserLookupStatus),
    RunId = tostring(Record.RunId)
| order by timestamp desc
```

For workspace queries, use `AppTraces`, `TimeGenerated`, and `Message` instead of `traces`, `timestamp`, and `message`. Query results can be exported through PowerShell with `Invoke-AzOperationalInsightsQuery` and `Export-Csv`.

Preserve Information-level logs, configure appropriate retention, and exclude audit traces from sampling for meaningful counts. Folder names, SIDs, and display names can identify people; restrict log access and retention accordingly. Application Insights is operational telemetry, not a guaranteed deletion ledger or a backup of deleted profile data.

### Storage Usage and Recovery Workbook

Import [the workbook](workbook/fslogix-profile-management.workbook) through **Azure Monitor > Workbooks > New > Edit > Advanced Editor**, paste its JSON, apply, and save. Select the cleanup Function App's **Application Insights** resource (not the Log Analytics workspace) and a reporting period covering a scheduled run. The default is 90 days. Readers need query access to that resource and its backing workspace. The workbook is imported separately; the deployment does not create it.

The Application Insights picker uses Azure Resource Graph to discover components across accessible subscriptions in the current tenant, rather than relying on resources already attached to the workbook. If the picker is empty, verify the portal tenant and read permissions on the component's subscription or resource group. After updating this workbook file, replace the saved workbook's JSON in **Edit > Advanced Editor**, apply, and save; saved workbooks do not automatically reload changes from this repository.

The workbook includes cleaned profile folders, deleted root disks, logical GiB recovered, remaining profiles and storage, eligible cleanup opportunity, daily trends, latest per-share scan freshness/coverage, run health, largest observed profiles, deletion history, structured errors/warnings, and separate Function host exceptions. A completed run with skipped accounts/profiles is not considered an issue-free run. Largest-profile observations are pre-cleanup history and may include subsequently deleted profiles.

New telemetry adds:

| Event | Metrics |
| --- | --- |
| `ProfileInventoried` | `SizeBytes`, `Eligible`, `Preview`; one record per qualifying profile folder or root disk, including retained profiles and previews. |
| `DiskDeleted`, `FileDeleted` | `SizeBytes` from the listing, emitted only after successful deletion. Sum these events for recovered logical bytes, including partial cleanups. |
| `ProfileDeleted` | `SizeBytes` for all inventoried files in the removed folder; descriptive only, not added again to recovered bytes. |
| `ShareInventoryCompleted` | `InventoryComplete`, `ProfileCountBefore`, `ProfileCountAfter`, `TotalBytesBefore`, `TotalBytesAfter`, `EligibleProfiles`, `EligibleBytes`, `DeletedProfiles`, `DeletedBytes`, `Preview`. |

Profile totals count top-level folders with at least one qualifying disk plus individual qualifying root disks; empty/excluded-only folders are not counted as profiles. Total storage includes **all** enumerated files, including ancillary files and files outside qualifying profiles. File listings must contain a nonnegative `Content-Length`; missing/invalid lengths emit `RunFailed` and stop rather than inventing a size.

Snapshot "after" values subtract observed successful deletions from the scan inventory; they are not a second live scan. A profile listing conflict marks the snapshot incomplete; a 403 or fatal error produces no completed snapshot. The workbook selects the latest attempted run per share, excludes missing/incomplete snapshots from totals, and exposes coverage. All inventories remain subject to concurrent writes and the selected log retention/time range.

Sizes are **logical file lengths**, not physical allocated storage, provisioned share quota, snapshots, or billing savings. Use Azure Files capacity metrics for actual service-reported usage; deleted VHDX lengths can differ substantially from physically recovered space. Deploy the updated function code before expecting inventory/size data. Historical deletion events without `SizeBytes` leave recovery unknown, and historical runs without inventory produce no inventory totals. Preserve unsampled Information logs; the workbook deduplicates identical emitted event identities but cannot reconstruct lost telemetry.

## Validation

Run the [mocked regression tests](../../../tests/FSLogixProfileManagement.Tests.ps1) from the repository root using Pester 5.7.1:

```powershell
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester -Path .\tests\FSLogixProfileManagement.Tests.ps1 -Output Detailed
```

Tests exercise the real script functions and entry-point orchestration with mocked HTTP requests. They cover configured share selection and validation, the Portal-to-template share-name contract, expiration boundaries and invalid timestamps, recursive eligibility and deletion ordering, ARM and FileREST pagination, malformed listings, previews, inventory totals, FileREST 403 account/subscription continuation, recognized 409 profile conflicts and partial deletion, fatal failures, input validation, and best-effort Graph enrichment. They do not access Azure, Microsoft Graph, or real profiles.

Before enabling scheduled deletion, maintain verified profile backups and validate against disposable shares:

- Preview recent and expired profiles, mixed-age disks, excluded-only folders, and root-level disks; confirm that no data is deleted.
- Render the Portal Script step and verify default/custom share names reach `FileShareName`. Preview a custom-named disposable share alongside `profilecontainers` and similarly named shares; confirm only the configured share is processed.
- Verify timestamp behavior after representative FSLogix sign-in/sign-out activity, then compare a controlled cleanup with its deletion and inventory records.
- Exercise locked profiles and access-denied accounts; confirm continuation and distinguish partial cleanup from completed profile removal.
- Confirm the configured schedule and time zone in the Function host, and verify workbook queries against actual telemetry.

Offline tests do not establish deployment acceptance, timestamp behavior, or recovery of deleted profiles. See the [contribution and validation guide](../../../CONTRIBUTING.md), [add-on deployment guide](../../../docs/add-ons.md), and [quick start](../../../docs/quick-start.md).
