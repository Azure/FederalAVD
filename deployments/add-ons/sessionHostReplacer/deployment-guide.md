# Deploying Session Host Replacer Updates

> **Note:** For comprehensive deployment instructions, prerequisites, permissions setup, and troubleshooting, see [README.md](README.md).

This document provides quick reference for deploying updates to an existing Session Host Replacer function and guidance for choosing deployment options.

## Scope

This guide covers updating an existing Function App deployment and reviewing its operational
settings. It does not redefine replacement behavior or duplicate the full first-deployment
parameter reference.

- Choose a mode and review parameters in [README.md](README.md#replacement-modes).
- Review execution, scaling-phase, readiness, and recovery behavior in the
  [canonical replacement flow](replacement-flow.md).

## Timer Schedule Guidance

In standard timer mode, the schedule controls lifecycle invocations; pending work may wait for the
next invocation. With `enableQueueContinuation=true`, it governs **new batch initiation**, not the
frequency of deployment/health/cleanup checks. A queue worker continues an approved batch on delayed
messages. See the [execution comparison](../../../docs/session-host-replacer.md#execution-approaches)
and [queue continuation operations](README.md#queue-continuation-operations) for rollout,
initiation-only holds, recovery and the required live pilot checks.

**Default** (Every 30 minutes):

```bicep
timerSchedule: '0 0,30 * * * *'  // Runs at :00 and :30
```

**Hourly timer schedule**:

```bicep
timerSchedule: '0 0 * * * *'  // Every hour on the hour
```

**Weekday business-hours timer schedule**:

```bicep
timerSchedule: '0 0 8-17 * * 1-5'  // 8 AM - 5 PM, Mon-Fri
```

In queue mode, approved batches may continue outside these hours. Neither approach's timer schedule
terminates an invocation already running; this is not a hard maintenance-window boundary.

**Staggered Across Multiple Deployments**:

- Deployment 1: `'0 0,30 * * * *'` (runs at :00 and :30)
- Deployment 2: `'0 15,45 * * * *'` (runs at :15 and :45)
- Staggers timer invocations; active workers and asynchronous ARM deployments can still overlap

## Quick Deployment Steps

**Enabling or updating queue continuation requires the full SHR Bicep/Template Spec deployment.**
Single-file updates do not provision the worker, identity settings or queue networking and are not
an upgrade path for this feature. The optional prebuilt package below replaces application code
only, after the full template has provisioned the infrastructure.
Upgrade only after existing work has settled, with the app stopped. Preserve deployment parameter
values for initiation holds and operation deadlines.

### Option 1: Update via Azure Portal (Fastest)

1. Navigate to your Function App in Azure Portal
2. Go to **Development Tools** → **App Service Editor**
3. Navigate to `Modules\SessionHostReplacer\SessionHostReplacer.psm1`
4. Replace the entire file content with your updated local version
5. Save the file
6. **Restart the Function App**

### Option 2: Optional Prebuilt Queue-Extension Package

**Use the normal Bicep extension bundle when it is available.** Secret and Top Secret may provide
approved local equivalents of the usual endpoints; we have not established that their bundle
mechanism is unavailable. This package is an optional alternative, not an air-gapped requirement
or proof of target-cloud support. It introduces no new Portal or Bicep parameters. This is a
code-delivery option for queue continuation, not another execution approach or replacement mode.

The [package builder](New-SessionHostReplacerPackage.ps1) produces a complete application ZIP with
both function folders and bindings, the shared engine/modules, and compiled Storage Queues
extensions with their dependencies and registration metadata. Its root host configuration omits
`extensionBundle`, disables PowerShell managed-dependency downloads, and preserves the continuation
timeout/queue visibility settings. The repository's PowerShell requirements are currently empty;
the builder rejects nonempty managed requirements rather than silently omitting those modules.

#### Download a release package

Once a release tag contains the [release workflow](../../../.github/workflows/release-shr-package.yml),
publishing that GitHub release (including a prerelease) builds the tagged source and attaches:

- `SessionHostReplacer.zip`
- `SessionHostReplacer.zip.sha256`

Use the assets from the same release as the deployed templates. Build/upload failures are visible
in GitHub Actions; release publication alone does not prove the assets are ready. The workflow does
not deploy Azure resources and does not overwrite existing assets. For a partial upload, maintainers
must deliberately remove the incomplete SHR assets before rerunning; do not replace approved
artifacts silently.

On a connected workstation with GitHub CLI:

```powershell
gh release download '<release-tag>' --repo Azure/FederalAVD `
    --pattern 'SessionHostReplacer.zip' --pattern 'SessionHostReplacer.zip.sha256' `
    --dir .\customer\packages
if ($LASTEXITCODE -ne 0) { throw 'SHR release asset download failed.' }

$zip = '.\customer\packages\SessionHostReplacer.zip'
$expected = ((Get-Content -LiteralPath "$zip.sha256" -Raw).Trim() -split '\s+')[0]
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) {
    throw 'SHR package checksum mismatch.'
}
```

The ZIP is deployment-neutral: its timer binding uses `%TimerSchedule%`. Both Bicep-deployed and
packaged code read the `TimerSchedule` app setting populated from the existing `timerSchedule`
deployment parameter. The same ZIP can therefore be used across host pools with different
schedules and time zones; `WEBSITE_TIME_ZONE` continues to come from `timeZone`. A missing or invalid
setting causes timer indexing to fail, not a fallback schedule.

#### Build outside the enclave (alternative)

Use PowerShell 7.2 or later and .NET SDK 8 or later (not just the .NET runtime). Core Tools is not
required. The builder uses a .NET 8 extension project with `Microsoft.NET.Sdk.Functions` 4.6.0 and,
by default, `Microsoft.Azure.WebJobs.Extensions.Storage.Queues` 5.3.5. The queue extension supports
identity-based connections. These are pinned build inputs, not a guarantee that every enclave
Functions host supports those versions.

If release assets are unavailable or an approved extension version/feed is required, build from
the matching source checkout. From the repository root:

```powershell
.\deployments\add-ons\sessionHostReplacer\New-SessionHostReplacerPackage.ps1 `
    -OutputPath .\customer\packages\SessionHostReplacer.zip
```

The command returns the ZIP path and SHA-256 hash. Existing ZIPs are preserved unless `-Force` is
supplied; a failed extension build does not replace an existing ZIP. `shr-package.json` inside the
ZIP records the framework, direct package versions, required schedule-setting name and build time.
Retain the approved ZIP and its hash as the release artifact; rebuild for a new code release or
extension version, not for a different timer schedule. The ZIP includes `LICENSE` and
`ThirdPartyNotices.txt` for redistribution; review dependency licenses when changing pinned versions.

GitHub's **Source code (zip)** is a source archive, not this generated runtime package. Use the
builder's ZIP or the prebuilt SHR release asset from the matching code release.
A Microsoft extension-bundle ZIP contains compiled extensions,
not the SHR application, and is not a drop-in replacement for this package.

The build restores NuGet dependencies from the workstation's configured sources. If necessary,
pass `-NuGetSource '<approved-feed-url>'` and a tested `-QueueExtensionVersion '5.x.y'`. Authenticate
to private feeds using the workstation's approved NuGet tooling; do not embed credentials in URLs.
Neither the feed configuration nor local app settings are included in the ZIP.

#### Transfer and deploy

1. First check whether the target enclave's normal bundle mechanism works. If it does, this
   prebuilt path is unnecessary.
2. Transfer the ZIP and its checksum through the approved process. Compare
   `Get-FileHash -LiteralPath '<transferred-zip>' -Algorithm SHA256` with the recorded hash or
   transferred `.sha256` file. Keep the binaries outside ARM
   and Template Specs; do not inline them into template content or upload them as image artifacts.
3. Let existing SHR operations settle and hold new initiation. Stop the app for the upgrade.
   Deploy the full SHR template using Template Specs or PowerShell with
   `enableQueueContinuation=true` and `initiationEnabled=false`. This supplies the infrastructure,
   identity, permissions, `TimerSchedule` setting and cloud-specific storage endpoints. Set
   `timerSchedule` to the desired initiation schedule; no package rebuild is needed.
4. Sign in to the target Azure cloud/subscription from a workstation that can reach the Function
   App's authorized SCM deployment endpoint. Deploy the ZIP locally, with remote building disabled.
   Use extracted ZIP deployment rather than a read-only package mount so later template code
   deployments are not blocked:

```powershell
$resourceGroup = '<shr-resource-group>'
$functionApp = '<shr-function-app>'
$package = '<transferred-zip-path>'

az functionapp config appsettings set --resource-group $resourceGroup --name $functionApp `
    --settings SCM_DO_BUILD_DURING_DEPLOYMENT=false WEBSITE_RUN_FROM_PACKAGE=0 --output none
if ($LASTEXITCODE -ne 0) { throw 'Unable to configure local ZIP deployment.' }

az functionapp deployment source config-zip --resource-group $resourceGroup --name $functionApp `
    --src $package --build-remote false
if ($LASTEXITCODE -ne 0) { throw 'SHR package deployment failed.' }

az functionapp start --resource-group $resourceGroup --name $functionApp
if ($LASTEXITCODE -ne 0) { throw 'Unable to start SHR.' }
```

5. Verify both functions index successfully without a bundle download, the packaged queue
   extension loads, and queue identity/private DNS/connectivity work. Exercise cold restart and
   worker replacement/scale-out as supported by the target plan. Confirm the timer schedule and
   complete an isolated continuation pilot before releasing the initiation hold.

**Deployment lifecycle:** a later full SHR template deployment writes the normal bundle host
configuration again. Keep initiation held and reapply the prebuilt ZIP afterward, before releasing
the hold. A schedule-only change to `TimerSchedule` through the approved app-setting process needs
no ZIP rebuild or upload; keep `timerSchedule` in the deployment parameters synchronized. App-setting
changes restart the app, so an interrupted active worker can wait for its lease to expire.
To return to the normal bundle
path, redeploy the full template and verify the bundle loads before resuming operations. Do not
mix extension versions or switch code-delivery paths during an active batch.

No bundle/CDN or NuGet restore is required by the prebuilt application at runtime. This does not
eliminate platform dependencies, prove enclave Functions/Queue availability, or replace approved
storage, Azure Resource Manager, Graph, AVD and SCM connectivity. See the
[air-gapped dependency inventory](../../../docs/air-gapped-clouds.md#shr-queue-continuation-prerequisites).
Microsoft documents [explicit extension registration](https://learn.microsoft.com/azure/azure-functions/functions-bindings-register#explicitly-install-extensions)
and [package deployment](https://learn.microsoft.com/azure/azure-functions/deployment-zip-push).

## Important: Restart Function App

After deploying, **always restart the Function App** to:

1. Clear any cached modules
2. Reload updated PowerShell modules
3. Clear token caches (if token acquisition logic changed)

## Verify Deployment

Check Application Insights for recent execution:

```kusto
traces
| where customDimensions.Category == "Function.session-host-replacer"
| where timestamp > ago(10m)
| order by timestamp desc
| take 20
```

Look for:

- ✅ Function execution started
- ✅ No module load errors
- ✅ Expected configuration values loaded
- ✅ No authentication failures

## Review or Update Existing Operational Settings

Use the repository-provided configuration command instead of editing unlabelled Function App
environment variables directly:

```powershell
.\Set-SessionHostReplacerConfiguration.ps1 `
    -FunctionAppName <function-app-name> `
    -ResourceGroupName <function-app-resource-group>
```

Supply supported setting parameters and `-WhatIf` to preview a change. The command validates
mode-specific settings, displays a diff, and preserves unrelated app settings. Replacement mode,
identity, networking, device-cleanup permissions, and infrastructure changes must still be made
through the Template Spec. The timer schedule is supplied by `timerSchedule` or its corresponding
`TimerSchedule` app setting; the configuration helper does not edit it. Keep the parameter source
synchronized because a later redeployment can overwrite direct operational changes.

## For Complete Documentation

See [README.md](README.md) for:

- Prerequisites and permissions setup
- Full configuration reference
- Troubleshooting guide
- Monitoring best practices

### Module not reloading?

- Azure Functions cache PowerShell modules
- Restart is required to reload
- Consider adding version number to module manifest for tracking
