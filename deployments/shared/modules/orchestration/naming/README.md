# Shared naming

This folder implements the authoritative naming policy for convention-generated
FederalAVD resources. Change a rule in the shared policy, not in each deployment.
Callers supply context such as identifier, region, subscription and resource group;
they supply explicit customer names and existing-resource adoption decisions.

## Where to make a change

| Concern | Owner |
| --- | --- |
| Default convention, resource-type rules, role purposes, patterns and resource limits | [namingPolicy.json](../../../data/namingPolicy.json) |
| Composition, formatting, location lookup and uniqueness recipes | [naming.bicep](./naming.bicep) |
| Default resource abbreviations | [resourceAbbreviations.json](../../../data/resourceAbbreviations.json) |
| Region abbreviations | [locations.json](../../../data/locations.json) |
| Host-pool and FSLogix bundles, explicit location context and existing-workspace adoption | `hostPoolNames` and `fslogixNames` in [naming.bicep](./naming.bicep) |
| Generated Bicep parameter defaults, Portal UI-default payloads and dropdown defaults | [Sync-NamingPolicy.ps1](../../../../../tools/Sync-NamingPolicy.ps1) |
| Template Spec publishing using the same policy datasets | [New-TemplateSpecs.ps1](../../../../../tools/New-TemplateSpecs.ps1) |

Standard host pools, automated host pools and the dedicated PoC call the
`hostPoolNames` bundle directly. The FSLogix Storage add-on calls the focused
`fslogixNames` bundle and has no host-pool dependency. Shared Services, Image
Management and Session Host Replacer use the same policy implementation directly.
Networking, PoC networking, Automation add-ons and Image
Build also consume the shared policy. The publisher reads its defaults and purpose
catalog from the same datasets.

## One entry point for every deployment

[naming.bicep](./naming.bicep) is the public Bicep entry point for host pools,
Shared Services, Image Management, Image Build, networking and add-ons. Import
the functions needed by the caller; importing functions does not add a nested
Azure deployment. The optional Function App bundle is not a separate naming engine.

The canonical library owns the bundles, including role-specific names,
scope seeds and workspace adoption checks;
callers supply explicit locations and subscriptions. Replacer calls the common
Function App bundle with its host-pool identifier plus the `shr` purpose.
Private endpoint consumers use the same
`privateEndpointName` resolver, including its 36/37-character VNet boundary.

`naming.bicep` is the only supported naming import path. Do not create a
solution-local naming engine.

## Naming resources in a new add-on

Use the same resource-type interface regardless of whether the add-on includes
a Function App:

```bicep
import { resourceNameForType } from '../../shared/modules/orchestration/naming/naming.bicep'

var context = {
  subscriptionId: subscription().subscriptionId
  resourceGroupName: targetResourceGroupName
  location: location
  cloud: environment().name
}
var storageName = resourceNameForType(namingConvention, 'storageAccounts', '${identifier}-data', context)
var vaultName = resourceNameForType(namingConvention, 'keyVaults', '${identifier}-secrets', context)
```

The import path assumes an entry template in `deployments/add-ons/<name>/`.
An empty convention object uses the shared defaults. Use a distinct identifier
for multiple resources of the same type in the same scope. Callers still create
resources, apply explicit overrides and supply existing-resource IDs.

To name a resource group, use `resourceGroups` with `resourceGroupName: ''`;
its name has no hash and does not depend on that field. Do not make a group's
generated name depend on itself. For all other types, pass the owning group.

## Adding or changing a rule

Each `resourceTypes` entry owns its numeric `lengthLimit`, format and optional
constraints. The separate `limits` section holds special budgets: temporary
Windows computer names, FSLogix prefixes, Image Management prefixes/locations,
the short `uniqueSuffix` (six characters), and the generic
`defaultUniqueLength` (six characters). Types marked `globallyUnique: true`
receive an automatic hash. A globally named type can override its length with
`uniqueLength`; Key Vault uses six characters. Scope-local types omit both fields
and do not receive a hash.

Resource roles specify a resource abbreviation key and purpose parts. For example,
both host pools and Shared Services request `operationsResourceGroup`; neither
owns a separate copy of the `operations` purpose. Changing its purpose changes
both, including the group used to seed associated globally unique names.

Use `resourceNameForType` or `functionAppNames` for new identifier-based add-ons.
Role-based deployments use `resourceName`; `namePattern` handles
purpose-specific runtime patterns. Do not copy convention
defaults or invent local resource formatting/hash recipes in a caller.

### When a uniqueness hash is needed

Storage accounts, Key Vaults and Function Apps need globally unique names in
their service namespace; deterministic hashes help avoid collisions but do not
guarantee availability. Most other resources only need uniqueness within their
owning scope, so a clear purpose or identifier can be sufficient without a hash.
A hash can also disambiguate identifiers that become identical after formatting
and names whose convention omits a distinguishing component.

The established role-based interface adds uniqueness only where its recipes
require it. The identifier-based `resourceNameForType` interface adds a hash only
for Storage accounts, Key Vaults and Function Apps. Other types use the formatted
identifier and selected components without a hash; overlength names fail rather
than truncate. Callers must select distinct formatted names within the target
scope, including when identifiers normalize identically or location is omitted.
The generic Function App bundle therefore hashes its app and storage names, but
not its Insights or storage-CMK identity names. Hosting plans are named separately
with their owner's purpose, without a hash.

SHR uses the generic Function App bundle directly, without its former adapter
or hashed Insights recipe. Other production role-based recipes remain unchanged,
including build-run identities and private-endpoint VNet shortening. Changing
an already deployed name requires an explicit resource-lifecycle decision;
the common helper does not migrate resources automatically.

After editing a policy dataset:

1. Run `tools\Sync-NamingPolicy.ps1`. It updates Bicep defaults marked with
   `// naming-policy: <policy.path>` and the generated Portal UI-default controls
   and component defaults. Do not edit these generated values manually.
2. Rebuild affected entry-point ARM JSON, including embedded-template dependencies.
3. Run naming parity/propagation tests, `tools\Sync-NamingPolicy.ps1 -Check`,
   and Bicep/ARM synchronization checks.
4. Render affected Portal steps in a live Portal session. JSON/schema checks do
   not validate Portal expression evaluation or `CustomHtmlField` behavior.

Bicep defaults are generated as literals deliberately. With the current compiler,
`loadJsonContent` in a parameter default emits a `variables('$fxv#...')` reference;
ARM does not permit variables in parameter defaults. Generating literals produces
valid parameter defaults and avoids copying the whole policy into each
default. Runtime naming still uses the shared policy functions directly.

### Portal and deployment boundary

The JSON files are shared configuration, not Azure Policy definitions. Native
Bicep functions calculate deployment names; PowerShell reads the same data for
Template Spec publishing and default generation. Keeping data in JSON avoids a
second handwritten catalog for those non-Bicep consumers.

Portal forms collect convention choices, identifiers, explicit overrides and
resource selections. They do not need the deployment role catalog or uniqueness
recipes. Their hidden `federalAvdNamingPolicy` control contains only a shared
UI-default projection:

- The default convention.
- The standalone FSLogix identifier.
- Default VM, OS disk, NIC and standalone availability-set patterns.
- The resource-abbreviation dataset used by editable abbreviation controls.

This is the union of defaults used across naming forms, not a per-form deployment
policy. The generator does not include resource-role purposes, deployment length
limits, unrelated identifiers, or deployment-only patterns. Adding or changing a
role therefore does not change Portal payloads or fail the publisher's freshness
gate solely because of that role change. Changes to UI-consumed defaults still
require synchronization.

Forms cannot import local JSON or Bicep functions at runtime. The generated
payload supplies defaults for existing expressions, including adopted-host-pool
fallbacks and Key Vault length warnings; it is not another naming authority.
The publisher checks generated defaults/forms for freshness before accessing
Azure. Bicep remains responsible for deployment name composition, formatting and
resource-specific uniqueness; explicit overrides and existing-resource adoption
remain caller responsibilities.

### Common naming review and extension boundary

The source review covers all policy roles, shared helpers, host-pool naming,
Shared Services, Image Management, Image Build, networking, Automation add-ons,
Replacer, Portal consumers and the Template Spec publisher. It is not a live
Azure acceptance test or proof that arbitrary customer conventions are valid.

| Surface | Existing behavior and constraint |
| --- | --- |
| Convention composition | Shared helpers merge defaults and abbreviation overrides; role purposes remain centralized. Missing `purpose` can make same-type resources collide. |
| Host pools and Shared Services | Scoped subscription/resource-group seeds match for shared vaults; control-plane and VM regions can differ. Existing workspace adoption and explicit names must remain authoritative. |
| Storage | Image Management and FSLogix retain specialized prefix budgets. Replacer uses the common Function App storage name and requires an override if it exceeds 24 characters. |
| Function Apps and Key Vaults | The identifier-based API validates full generated lengths without truncation. Established role-based `resourceName` formatters retain their existing budgets. |
| Networking and Automation | Some roles intentionally omit a purpose or workload. These are role-specific rules, not defaults for every add-on. |
| Runtime patterns and Image Build | `SHNAME`, `TOKEN`, `##`, private-endpoint placeholders, and per-run build identities have different lifecycles from stable service names. |
| Portal | Only UI defaults are generated. Existing client-side warnings are advisory, not authoritative deployment naming validation. |
| Publisher | PowerShell composes Template Spec names from the shared data; Bicep cannot execute in the form or directly supply PowerShell values. Keep their convention semantics covered by parity tests. |

New add-ons use the identifier-based interface below for explicit validation and
length budgets. Role-based naming uses `resourceName` and the policy's role recipes.

## Adding a Function App add-on

Import one function from the shared layer. In an add-on entry template under
`deployments/add-ons/<name>/`, the call is:

```bicep
import { functionAppNames, resourceNameForType } from '../../shared/modules/orchestration/naming/naming.bicep'

var context = {
  subscriptionId: subscription().subscriptionId
  resourceGroupName: functionAppResourceGroupName
  location: location
  cloud: environment().name
}
var names = functionAppNames(namingConvention, '${identifier}-job', context, {
  functionAppName: functionAppNameOverride
  storageAccountName: storageAccountNameOverride
})
var sharedPlanName = resourceNameForType(namingConvention, 'appServicePlans', 'functions', context)
```

The snippet assumes the caller already defines the convention, identifier, target
resource-group name, location and optional explicit-name parameters. An empty convention object selects the shared
defaults; do not create another copy of them. If resources target a different
subscription, pass that actual subscription ID rather than the orchestrator's.
Use a distinct identifier for each separate add-on instance in the same scope.
No application-specific policy entry or naming-policy sync is needed.

The returned object has the exported `functionAppNamingResult` type:

| Result property | Consumer |
| --- | --- |
| `functionAppName` | Function App module parameter of the same name |
| `storageAccountName` | Runtime storage parameter of the same name |
| `applicationInsightsName` | Insights parameter of the same name |
| `storageEncryptionIdentityName` | Name for a caller-created storage CMK identity, when applicable |
| `privateEndpointNameConv` / `privateEndpointNICNameConv` | Existing private-endpoint pattern parameters |

The naming helper creates no resources. The
[Function App module](../../resourceModules/functionApp/functionApp.bicep)
still requires its complete networking, settings, monitoring, encryption and
host-pool inputs. Create/adopt the hosting plan separately and pass its resource
ID as `serverFarmId`; a generated plan name is not that ID. Likewise, creating
the storage CMK identity/key and permissions remains the caller's responsibility.

Pass `{}` as the fourth argument when no overrides are needed. The exported
`functionAppNameOverrides` type supports `functionAppName`, `storageAccountName`
and `storageEncryptionIdentityName`. Empty values generate defaults. Overrides
are applied inside the bundle, before evaluating generated names; an explicit
storage name therefore bypasses an overlength generated storage name.

The shared plan purpose is independent of the application identifier. SHR uses
`shr`, producing `asp-avd-shr-use`; a broader add-on plan can use `functions`.
If the plan targets another resource group, supply that group's context to
`resourceNameForType`. Create it only when no existing-plan resource ID is
supplied; all additional apps should pass that existing ID. A common name alone
does not discover or adopt an existing plan, and concurrent deployments must not
both claim ownership of it.

See the compiling [module-wiring fixture](../../../../../tests/fixtures/naming-function-app.bicep).
Use your add-on's purpose instead of `shr` for an unrelated application.

### Resource-type API and naming guarantees

`resourceNameForType(convention, resourceType, identifier, context)` names an
individual resource. `context` has the exported `namingContext` type, containing
`subscriptionId`, `resourceGroupName`, full Azure `location`, and `cloud`.
The shared `resourceTypes` catalog covers all 36 convention-named types in the
repository's abbreviation dataset:

| Family | Resource-type keys |
| --- | --- |
| AVD | `hostPools`, `workspaces`, `desktopApplicationGroups`, `remoteApplicationGroups`, `scalingPlans` |
| Compute | `availabilitySets`, `computeGalleries`, `diskAccesses`, `diskEncryptionSets`, `osdisks`, `virtualMachines`, `imageDefinitions` |
| Networking | `natGateways`, `networkInterfaces`, `networkSecurityGroups`, `privateEndpoints`, `publicIPAddresses`, `routeTables`, `virtualNetworks`, `subnets` |
| Monitoring | `applicationInsights`, `dataCollectionEndpoints`, `dataCollectionRules`, `logAnalyticsWorkspaces`, `privateLinkScopes` |
| Apps | `functionApps`, `appServicePlans` |
| Storage and recovery | `storageAccounts`, `netAppAccounts`, `netAppCapacityPools`, `recoveryServicesVaults` |
| Shared resources | `automationAccounts`, `keyVaults`, `userAssignedIdentities`, `resourceGroups`, `templateSpecs` |

A new add-on using these types needs no policy change. Supporting an entirely new
Azure resource type still requires defining and testing its rules centrally.
Workbook resource IDs are provider-required GUIDs, not convention-generated
display names. DNS zone names, fixed child-resource names, RBAC GUIDs and operation
IDs follow their own rules.

Both entry points:

- Resolve shared defaults and partial resource-abbreviation overrides.
- Require exactly one `purpose` component. Empty/all-`none` selections, unknown
  components and unsupported resource types fail explicitly.
- Accept an empty delimiter or up to three `-`, `_`, `.` characters. Values must
  use ASCII alphanumerics and those separators, starting/ending in an alphanumeric.
- Lowercase generated names. Hyphen-format types translate `_` and `.` to `-`;
  storage removes all three separator characters, and galleries translate hyphens
  to underscores. Key Vaults reject consecutive hyphens; vaults and Automation
  Accounts enforce their required initial letter.
- For the three globally named types only, calculate a stable `uniqueString`
  from lowercased target subscription, owning resource group, full region, cloud,
  and full application identifier, not the resource type. The default hash is
  six characters, so an application's Function App and storage share the same
  token. Full regions stay in the hash even when the convention
  omits `location`.
- For all types, retain the complete formatted identifier and selected static
  components. Fail explicitly when the full name exceeds its configured budget;
  no identifier or purpose is silently shortened. Choose a shorter convention
  or pass an explicit name through the bundle's overrides.
- For scope-local types, keep the full formatted identifier without a hash.
  Fail explicitly when the complete name exceeds the limit; shorten the
  identifier or convention values rather than silently truncating. Changing
  subscription or owning resource group does not itself change these names.
- Keep redeployments and case-only input changes stable. Without a hash,
  identifiers that normalize identically generate the same name; callers own
  disambiguation within the target scope.

The Function App bundle uses an additional `-storage-cmk` identifier purpose for
its dedicated storage identity and retains normal region/convention components.
It honors `locationAbbreviation`, then a host-pool `vmsLocationAbbreviation` tag,
then the shared region map. Private-endpoint patterns use shared placeholders;
consuming modules resolve them to final names.

Length limits are policy budgets, not a claim that every provider accepts no
longer name. DCE (44), Disk Access (64), Monitor Private Link Scope (64), and
scaling-plan (63) budgets are conservative. Source references are Microsoft's
[resource naming restrictions](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules)
and the [Azure naming module catalog](https://github.com/Azure/terraform-azurerm-naming/blob/master/resourceDefinition.json).
The generic VM rule names the Azure resource (up to 64 characters), not the
Windows computer name (15). Use the existing session-host patterns or
`deploymentVmName` for their established computer-name contracts; a new VM caller
must separately provide an OS-valid `computerName` when its resource name is longer.

These are deterministic names, not an availability reservation. Check Azure
global name availability and reserved-name restrictions. Explicit overrides are
not validated by this helper; explicit storage names are lowercased. If deliberately sharing runtime
storage between Function Apps, also review
[Functions host ID collisions](https://learn.microsoft.com/azure/azure-functions/storage-considerations#host-id-considerations);
the default bundle provides a distinct runtime-storage name per app identifier.
Changing scope, identifier, convention or central rules can change names and
requires an explicit resource-lifecycle decision.

References: Microsoft's
[resource naming restrictions](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules)
and [`uniqueString` contract](https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-functions-string#uniquestring).

## Naming rules and exceptions

- Explicit names, existing IDs, customer patterns and adopted host-pool naming
  tags remain authoritative.
- The temporary deployment helper honors explicit resource names and a supplied
  identity name pattern. Its internal identity fallback replaces `TOKEN` with
  the fixed purpose `deployment`; it does not import or evaluate the naming policy.
  VM, disk and NIC names are supplied by the caller.
- Quota/route Automation Accounts and two Template Spec publishing
  defaults intentionally omit workload. These are centralized role-specific
  rules, not additional naming engines.
- Standalone session-host/Replacer availability-set defaults are `avset-##`;
  host-pool generated availability sets include convention context. Their public
  pattern contracts are defined centrally.
- Image storage, encryption keys and per-run image-build resources use
  specialized patterns and uniqueness seeds. Resource types need not have
  identical patterns when their roles differ.
- Names follow the convention subject to resource-specific restrictions. Vault
  names convert `_` and `.` to `-` after component assembly; an empty delimiter
  remains empty. This formatting is not complete Azure name validation.
- Shared Services and host-pool vault purpose separators use the configured
  delimiter before Key Vault formatting.
- Partial abbreviation overrides merge with defaults.

Provider-required fixed names, RBAC GUIDs, lifecycle operation IDs and explicitly
supplied resource names are not convention-generated names.

## Explicit locations and naming bundles

Use `Location` consistently for new deployment and naming-context inputs.
The standard host pool accepts `controlPlaneLocation`, defaulting to the
subscription deployment's location, and `virtualMachinesLocation`, defaulting to
`controlPlaneLocation`. The form passes its selected VM location explicitly;
that selector already defaults to the control-plane location and filters VNets
to the selected location. Scripted callers must verify that the supplied VM
location matches their subnet's VNet before deployment.

The standard host pool uses `hostPoolNames` directly. The automated host pool and
PoC use that same function.
Standalone FSLogix uses `fslogixNames` for storage, private endpoints, identities
and temporary deployment-VM names; it does not request host-pool names.

Both functions receive a convention, identifier and typed context object.
`hostPoolNamingContext` includes `subscriptionId`, `cloud`,
`virtualMachinesLocation`, `controlPlaneLocation`, `globalFeedLocation`,
`existingFeedWorkspaceResourceId` and `sharedServicesSubscriptionId`; use empty
strings for absent feed/adopted workspace inputs. `fslogixNamingContext` contains
only `subscriptionId`, `cloud` and `location`. The host-pool bundle composes the
FSLogix bundle rather than duplicating its recipes.

Set both locations explicitly for split-location deployments. Empty locations
are invalid.

The FSLogix default storage prefix uses the generated storage-group name
in its seed even when the caller selects an existing group. Its SMB location token
uses the raw region abbreviation, while generated resource names can use the
convention's VM-location override. These distinctions affect generated names.

## Function contract

The library is organized into convention primitives, identifier-based naming,
image/scope recipes, the FSLogix bundle, and the host-pool bundle. Import the
documented entry points; rendering, sanitizing, full scope hashes, helper-VM
formatting, VNet tokens and storage-prefix normalization are private
implementation details. Regression tests exercise them through exported
functions rather than exposing them solely for tests.

The host-pool result contains 47 consumed properties; FSLogix returns 15 shared
properties.

Import only the functions needed by the caller:

```bicep
import { resourceName } from './naming.bicep'

var operationsName = resourceName({}, 'operationsResourceGroup', 'va', '', '')
// rg-avd-operations-va
```

For a single policy value, prefer a narrow export such as `osDiskNamePattern`.
It loads `$.patterns.osDisk` directly from the authoritative JSON with
`loadJsonContent`. Importing the whole `namingPolicy` object for one property
embeds unrelated rules in each consuming ARM template. Exporting a property of
an already-loaded object does not avoid that expansion with the current compiler.
Keep file-backed scalar exports out of parameter defaults; use the generated
literal-default workflow described above for those.

Both `buildCustomName` and `cnv` accept, in order:

1. Component-name array.
2. Delimiter, including an explicitly empty string.
3. Resource-type code.
4. Purpose.
5. Location abbreviation.
6. Freeform value 1.
7. Environment.
8. Freeform value 2.
9. Workload.

Recognized components are `resourceType`, `purpose`, `location`, `freeform1`,
`environment`, `freeform2`, and `workload`. Empty values and unknown components
are omitted. `cnv` also explicitly removes `none` components. Ordering,
duplicates, case, and nonempty whitespace are preserved.

`stripSeps` removes `-`, `_`, and `.`. `kvSanitize` replaces `_` and `.` with
`-`. Neither validates a complete Azure resource name, truncates it, changes
case, or adds uniqueness. The higher-level policy functions apply those
resource-specific rules; callers should not duplicate them.

## Validation

[Naming.Tests.ps1](../../../../../tests/Naming.Tests.ps1) compiles executable
[naming vectors](../../../../../tests/fixtures/naming.bicepparam) with Azure CLI
Bicep, compares role/storage/seed recipes against independent reference fixtures,
changes an isolated policy copy to exercise real consumer expressions and Portal
generation, verifies imports, and checks module, parameter, and output metadata.
It requires Azure CLI and its Bicep compiler already installed; it does not
deploy resources or require Azure sign-in.

[IdentifierNaming.Tests.ps1](../../../../../tests/IdentifierNaming.Tests.ps1)
executes the actual identifier-based functions through Bicep's local ARM runtime
across 504 vectors (36 types, 14 profiles), endpoint
boundaries and adapter recipes, and compiles their wiring into the shared
Function App module. Production source guards enforce the canonical import path
and prevent local copies of the naming engine. This suite was
validated with Bicep CLI 0.48.1 and requires a version supporting `local-deploy`.
It enables experimental local deployment only in an isolated temporary copy,
evaluates output-only fixtures, and removes that copy afterwards. It makes no
Azure resource changes and requires no Azure sign-in.

[NamingBundles.Tests.ps1](../../../../../tests/NamingBundles.Tests.ps1) uses the
same isolated local runtime to compare both direct bundles against
[reference outputs](../../../../../tests/fixtures/naming-bundles-legacy.json).
All 799 host-pool values (47 fields across seventeen profiles) must match the
fixture, covering all four clouds, split locations, convention/abbreviation
overrides, existing workspace adoption and separate shared-services subscriptions.
All fifteen FSLogix properties are checked against the matching
host-pool values. A source guard prevents unused result fields from accumulating.
The suite also exercises changed policy propagation and rejects cross-subscription
workspace adoption.

```powershell
Invoke-Pester -Script tests\Naming.Tests.ps1,tests\IdentifierNaming.Tests.ps1,tests\NamingBundles.Tests.ps1
```

After changing shared naming, rebuild affected entry-point ARM templates and run
their focused naming tests and Bicep/ARM synchronization checks. Successful
compilation alone does not validate generated resource names.
