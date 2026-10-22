# Shared naming

This folder implements the authoritative naming policy for convention-generated
FederalAVD resources. Change a rule in the shared policy, not in each deployment.
Callers supply context such as identifier, region, subscription and resource group;
they retain explicit customer names and existing-resource adoption decisions.

## Where to make a change

| Concern | Owner |
| --- | --- |
| Default convention, resource-role purposes, patterns and resource limits | [namingPolicy.json](../../../data/namingPolicy.json) |
| Composition, formatting, location lookup and uniqueness recipes | [functions.bicep](./functions.bicep) |
| Default resource abbreviations | [resourceAbbreviations.json](../../../data/resourceAbbreviations.json) |
| Region abbreviations | [locations.json](../../../data/locations.json) |
| Host-pool context, outputs and existing-workspace adoption | [hostPool.bicep](./hostPool.bicep) |
| Generated Bicep parameter defaults, Portal policy payloads and dropdown defaults | [Sync-NamingPolicy.ps1](../../../../../tools/Sync-NamingPolicy.ps1) |
| Template Spec publishing using the same policy datasets | [New-TemplateSpecs.ps1](../../../../../tools/New-TemplateSpecs.ps1) |

The host-pool adapter serves standard host pools, automated host pools, the
dedicated PoC, and the FSLogix Storage add-on. Shared Services, Image Management,
and Session Host Replacer use the same policy implementation directly or through
their naming adapters. Networking, PoC networking, Automation add-ons and Image
Build also consume the shared policy. The publisher reads its defaults and purpose
catalog from the same datasets.

## Adding or changing a rule

Resource roles specify a resource abbreviation key and purpose parts. For example,
both host pools and Shared Services request `operationsResourceGroup`; neither
owns a separate copy of the `operations` purpose. Changing its purpose changes
both, including the group used to seed associated globally unique names.

Use `resourceName` for convention-generated resources and `namePattern` for
purpose-specific patterns. Do not introduce another purpose literal or a local
copy of the convention defaults in a caller, except for the fixed internal
deployment-helper fallback described below.

After editing a policy dataset:

1. Run `tools\Sync-NamingPolicy.ps1`. It updates Bicep defaults marked with
   `// naming-policy: <policy.path>` and the generated Portal policy-data controls
   and component defaults. Do not edit these generated values manually.
2. Rebuild affected entry-point ARM JSON, including embedded-template dependencies.
3. Run naming parity/propagation tests, `tools\Sync-NamingPolicy.ps1 -Check`,
   and Bicep/ARM synchronization checks.
4. Render affected Portal steps in a live Portal session. JSON/schema checks do
   not validate Portal expression evaluation or `CustomHtmlField` behavior.

Changing a deployed name is not an automatic rename or resource migration.
Review affected stateful resources before deploying a policy change.

Bicep defaults are generated as literals deliberately. With the current compiler,
`loadJsonContent` in a parameter default emits a `variables('$fxv#...')` reference;
ARM does not permit variables in parameter defaults. Generating literals retains
the original parameter contract and avoids copying the whole policy into each
default. Runtime naming still uses the shared policy functions directly.

Portal forms cannot import local JSON. Their runtime bindings read the generated
hidden data control; that payload is not another policy source. The publisher
checks generated defaults/forms for freshness before accessing Azure.

## Preserved behavior and explicit exceptions

- Explicit names, existing IDs, customer patterns and adopted host-pool naming
  tags remain authoritative.
- The temporary deployment helper honors explicit resource names and a supplied
  identity name pattern. Its internal identity fallback replaces `TOKEN` with
  the fixed purpose `deployment`; it does not import or evaluate the naming policy.
  Caller-generated VM, disk and NIC names are unchanged.
- Quota/route Automation Accounts and two legacy Template Spec publishing
  defaults intentionally omit workload. These are centralized role-specific
  rules, not additional naming engines.
- Standalone session-host/Replacer availability-set defaults remain `avset-##`;
  host-pool generated availability sets include convention context. Their public
  pattern contracts are retained centrally rather than renamed by this refactor.
- Image storage, encryption keys and per-run image-build resources retain their
  specialized patterns and uniqueness seeds. Resource types need not have
  identical patterns when their roles differ.
- Names follow the convention subject to resource-specific restrictions. Vault
  names convert `_` and `.` to `-` after component assembly; an empty delimiter
  remains empty. This formatting is not complete Azure name validation.
- Shared Services vault purpose separators now use the configured delimiter
  before Key Vault formatting, matching host pools. Default `-` names are unchanged; custom delimiters,
  notably an empty delimiter, can change existing Shared Services vault names.
  Supply explicit vault names to retain those resources in affected configurations.
- Partial abbreviation overrides merge with defaults. Empty/all-`none` selections
  no longer fail while determining resource-type placement, and delimiter-free
  Replacer storage no longer calls ARM `replace` with an empty search string.

Provider-required fixed names, RBAC GUIDs, lifecycle operation IDs and explicitly
supplied resource names are not convention-generated names.

## Why the naming deployment remains

The host-pool root resolves VM region from an existing VNet at runtime. Moving
dependent naming variables into that root previously caused Bicep to inline long
runtime expressions repeatedly. The naming module still receives the resolved
region as an input, keeping its own expressions parameter-based. Imported
functions and policy data add no new deployment resources.

## Function contract

Import only the functions needed by the caller:

```bicep
import { resourceName } from './functions.bicep'

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
Bicep, compares role/storage/seed recipes against independent legacy fixtures,
changes an isolated policy copy to exercise real consumer expressions and Portal
generation, verifies imports, and checks module, parameter, and output metadata.
It requires Azure CLI and its Bicep compiler already installed; it does not
deploy resources or require Azure sign-in.

After changing shared naming, rebuild affected entry-point ARM templates and run
their focused naming tests and Bicep/ARM synchronization checks. Successful
compilation alone does not prove that deployed resource names remain unchanged.
