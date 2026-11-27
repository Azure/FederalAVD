# Function App orchestration

These resource-group-scoped modules separate infrastructure ownership from
function code. Current callers are Session Host Replacer, Image Validation, and
FSLogix Profile Management. They can compose
with a caller-created plan or an existing compatible plan; they do not require
that every deployment create all three resource types.

| Module | Owns | Caller supplies |
| --- | --- | --- |
| [Hosting-plan resource module](../../resourceModules/web/serverfarms/deploy.bicep) | App Service plan | Name, region, operating-system selector, SKU, zone setting, and resource-type-keyed tags |
| [functionApp.bicep](./functionApp.bicep) | Windows PowerShell Function App, runtime storage, storage data-role assignments, optional Application Insights and private endpoints | Compatible plan ID, networking/DNS, monitoring IDs when selected, optional app identity, and pre-provisioned storage CMK dependencies when selected |
| [Function resource module](../../resourceModules/web/sites/functions/deploy.bicep) | Timer-triggered child function and its function-level code files | Existing parent app name in the deployment resource group, child name, schedule, and file-name/content mapping |

The module and parameter descriptions are the detailed input contracts. A
parameter without a default is a required Bicep input even if its feature is
optional: pass an empty string, array, or object only where its description
allows that.

## Composition and sequencing

1. Create the hosting plan with the plan module, or obtain an existing compatible
   plan ID. The caller may scope the plan module to a separate resource group.
   Sharing requires the caller to own capacity, lifecycle, and compatibility
   decisions; the app module does not validate or resize an existing plan.
2. When storage uses CMK, provision its dedicated user-assigned encryption
   identity, Key Vault key, and key permissions first. This identity is separate
   from the optional Function App identity.
3. Deploy the app module with `serverFarmId` set to the selected plan ID.
   For a new plan, use `hostingPlanId` from the plan module output.
4. Deploy the function definition only after the parent app exists. Use an app
   module output or an explicit dependency when deploying both together;
   an `existing` resource declaration does not itself deploy or sequence the
   parent.

The function module deploys a child function, not an app-level package or
`host.json` by itself. A caller can include shared files in the supplied mapping,
but must own their contents and sequence multiple function deployments that write
to the same shared paths. The caller owns dependency availability and trigger
configuration. Application settings use an array of name/value objects; tags
use an object keyed by Azure resource type.

## Why plan and function deployment stay separate

The app module composes runtime storage, the app, identities/RBAC, monitoring, and
private connectivity, so it belongs to shared orchestration. The plan and child
function modules each own a single `Microsoft.Web` resource and stay in that
resource family.

All three callers can adopt an existing plan without changing it. Session Host
Replacer can create a plan in a different resource group from its app; keeping the
plan separate preserves that scope and its independently shared capacity/lifecycle.
Embedding it would require additional scope and create/adopt inputs in the composer.

Function deployments have a separate code lifecycle. Session Host Replacer creates
an initiator and worker with different schedules, and deploys shared files once
before the worker. Keeping the child module separate preserves this explicit
serialization and allows code updates without coupling them to app infrastructure.
Combining functions into the composer would require a collection and sequencing
contract without removing these responsibilities. The relocation changes no
resource names, parameters, APIs, defaults, or deployment dependencies.

Application Insights and resource-log forwarding are independent. When
`enableApplicationInsights` is true, the app receives its Application Insights
connection string for invocation telemetry. `enableFunctionAppDiagnosticSettings`
defaults to true and forwards `FunctionAppLogs` when a workspace is provided.
Session Host Replacer passes false to avoid this additional log collection path.
Disabling this option does not remove an existing `diag-<functionAppName>`
setting during incremental deployment. See the
[SHR logging migration procedure](../../../../add-ons/sessionHostReplacer/README.md#function-app-log-collection).

## Function binding contract

The child function module deploys a native `timerTrigger` with input binding name
`Timer`. Its required `schedule` accepts a Functions NCRONTAB expression or a
supported app-setting reference. Empty or whitespace-only schedules fail template
evaluation; the Functions runtime validates the actual schedule and settings.
The PowerShell entry point must accept `Timer`.

The app's optional queue-storage settings remain an independent infrastructure
capability; enabling them does not change the timer function into a queue trigger.
Compilation does not prove that the deployed host can resolve private endpoints,
authenticate to runtime storage, or execute its timers.

## Hosting behavior

`planPricing` selects the actual tier and SKU, for example `PremiumV3_P0v3`.
These are Dedicated App Service SKUs, not Functions Elastic Premium `EP` SKUs.
The `hostingPlanType` input controls `maximumElasticWorkerCount`:
values containing `Consumption` omit it, `FunctionsPremium` sets it to 20,
and other values set it to 1. This selector does not change the SKU family.

The plan currently requests one worker, or three when `zoneRedundant` is true.
The app separately sets `functionAppScaleLimit` to 200. These settings are
documented here as existing behavior, not a capacity recommendation or proof
that a particular SKU honors every setting. Verify SKU, cloud, region, and
scale-unit capabilities before deployment.

## Networking behavior

`paasPublicNetworkAccess` applies one public-access mode to runtime storage and the app, separately
from private endpoint creation:

| Mode | Public endpoint | App/SCM unmatched action and storage firewall |
| --- | --- | --- |
| `Disabled` | Disabled even with IP rules | Deny; supplied rules remain configured |
| `EnabledWithRestrictions` | Enabled even without private endpoints | Deny, including with an empty IP list |
| `Enabled` | Enabled even with private endpoints | Allow; stored allow rules do not restrict access |
| `Auto` (default) | Legacy inference below | Preserves existing caller behavior |

For `Auto`, the current `privateEndpoint` and `permittedIPs` combination is preserved:

| Private endpoints | Permitted IPs | Public endpoint behavior |
| --- | --- | --- |
| Enabled | Empty | Disabled for storage and the app |
| Enabled | Nonempty | Enabled with restrictions alongside private endpoints |
| Disabled | Nonempty | Enabled with restrictions |
| Disabled | Empty | Enabled without these network restrictions |

These are not interchangeable with a private-only guarantee. App restrictions
also allow the `AzureCloud` service tag, storage retains `AzureServices` bypass,
and SCM uses the main app restrictions when configured. Storage trusted-service bypass can still
apply when public network access is Disabled. Do not assume an IP list alone satisfies a
customer's approved-public-access guardrail. Network reachability does not grant
storage authorization.

Private endpoint subnet/DNS connectivity and outbound app VNet integration are
separate inputs. The caller must provide the appropriate private path and DNS
zones for the selected cloud.

Storage private-endpoint names are resolved into a shared array before the resource loop.
The endpoints and their DNS zone groups use that array so Bicep's indexed-parent expansion
does not emit an unqualified imported naming-function call. This preserves existing names
and custom patterns; it does not change public access or DNS zone selection.

The explicit modes do not change hosting limits, module boundaries, outbound VNet routing, or
monitoring access. The caller must establish a usable runtime-storage path before choosing
Disabled or a restricted configuration. See the
[shared access-mode contract](../../../../../docs/parameters.md#paas-public-network-access).
