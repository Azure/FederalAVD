[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Naming Convention

This document describes how FederalAVD names every Azure resource it creates, how to configure a custom naming convention that is consistent across all solutions, and how the built-in default aligns with Microsoft's [Cloud Adoption Framework (CAF) naming guidance](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming).

## Add-on developer quick start

Use one of these complete entry-template examples in `deployments/add-ons/<name>/main.bicep`:

- **Any combination of supported resource types:** call `resourceNameForType` once per resource, then pass the resolved names to your resource modules. The Automation Account example combines an account and a Log Analytics workspace in a local `names` object.
- **A predefined bundle, when useful:** call `functionAppNames` for Function App infrastructure, then pass the bundle's properties to the shared Function App module.

`resourceNameForType` returns one name per call, not one resource type per add-on.
Pass the official Azure resource type without an API version, such as
`Microsoft.RecoveryServices/vaults`, rather than an internal abbreviation key.
For example, the same add-on can name an Automation Account, a Log Analytics
workspace, storage accounts, identities and a Key Vault with separate calls using the same convention. You can
group those results in a local `names` object or mix direct calls with a predefined
bundle. Bundles are optional conveniences, not a requirement or a limit on which
supported resource types an add-on can use; no new adapter is needed for other combinations.

Both expose `param namingConvention namingConventionConfig = {}`. An empty object
uses the centralized defaults; customers can pass the same convention object used
by their other FederalAVD deployments. An empty name-override parameter generates
a name; a nonempty override takes precedence.

**What is `context`?** It is a local object describing the resources' actual destination,
not another customer parameter:

| Field | Supply |
| --- | --- |
| `subscriptionId` | Subscription that will own the resources |
| `resourceGroupName` | Resource group that will own the resources |
| `location` | Full Azure region where the resources will be deployed |
| `cloud` | Azure environment name, from `environment().name` |

These examples deploy at resource-group scope, so their context uses the current
subscription and resource group. If your orchestrator deploys modules elsewhere,
set the module's `scope` and the naming context to that same destination.

**Before deploying:** replace `'<purpose>'` with your add-on's short, stable purpose.
The angle brackets are documentation placeholders, not valid naming characters.
Use distinct purposes for multiple resources of the same type in the same scope.
Explicit name overrides must satisfy Azure's resource naming rules; an override
does not automatically adopt or rename an existing resource.

<details>
<summary>Automation Account: combine an account and workspace with optional overrides</summary>

An Automation Account can be combined with other supported resource types:

| Companion resource | Typical use |
| --- | --- |
| Log Analytics workspace | Collect Automation job logs and streams |
| Storage account | Store runbook inputs, reports or processing results |
| Key Vault | Hold secrets or certificates needed by the workload |
| User-assigned managed identity | Provide an identity for workloads that support it |

This example **creates and connects the first pair**: it reuses the
[Log Analytics workspace module](../deployments/shared/modules/resourceModules/operationalInsights/workspaces/deploy.bicep)
and the [AVD Alerts Automation Account module](../deployments/add-ons/avdAlerts/modules/automationAccount.bicep).
Both names use the same convention and context, with independent optional overrides.
The workspace module's resource ID output is passed to the Automation module for
diagnostic settings; Bicep orders the deployments through that dependency.

The Automation module also creates a system-assigned identity and Automation
variables. Its storage-collector runbook and schedule remain disabled because no
storage accounts are supplied. The storage, vault and user-assigned identity rows
above are other possible combinations, not extra resources in this example.
Naming those resources alone would not wire their integrations, attach identities
or grant permissions. For a different workload, use your own resource modules
with the same name-parameter pattern.

```bicep
targetScope = 'resourceGroup'

import { namingConventionConfig, resourceNameForType } from '../../shared/modules/orchestration/naming/naming.bicep'

param namingConvention namingConventionConfig = {}
param location string = resourceGroup().location
param deploymentTime string = utcNow()

@description('Optional. Complete Automation Account name. Leave empty to generate.')
param automationAccountNameOverride string = ''

@description('Optional. Complete Log Analytics workspace name. Leave empty to generate.')
param logAnalyticsWorkspaceNameOverride string = ''

var context = {
  subscriptionId: subscription().subscriptionId
  resourceGroupName: resourceGroup().name
  location: location
  cloud: environment().name
}

var names = {
  automationAccountName: !empty(automationAccountNameOverride)
    ? automationAccountNameOverride
    : resourceNameForType(namingConvention, 'Microsoft.Automation/automationAccounts', '<purpose>', context)
  logAnalyticsWorkspaceName: !empty(logAnalyticsWorkspaceNameOverride)
    ? logAnalyticsWorkspaceNameOverride
    : resourceNameForType(namingConvention, 'Microsoft.OperationalInsights/workspaces', '<purpose>', context)
}

module workspace '../../shared/modules/resourceModules/operationalInsights/workspaces/deploy.bicep' = {
  params: {
    name: names.logAnalyticsWorkspaceName
    location: location
    diagnosticSettings: null
  }
}

module automationAccount '../avdAlerts/modules/automationAccount.bicep' = {
  params: {
    automationAccountName: names.automationAccountName
    location: location
    resourceManagerUri: environment().resourceManager
    logAnalyticsWorkspaceResourceId: workspace.outputs.resourceId
    deploymentTime: deploymentTime
  }
}

output generatedNames object = names
output automationAccountResourceId string = automationAccount.outputs.resourceId
output logAnalyticsWorkspaceResourceId string = workspace.outputs.resourceId
```

Each override is selected **before** its naming-helper call. The resource modules
receive finished names; they do not rebuild the convention. The local `names`
object simply groups two direct calls for different resource types; it is not a
new shared adapter or a separate naming engine.

</details>

<details>
<summary>Function App: a names bundle and optional overrides</summary>

This example calls the existing [shared Function App module](../deployments/shared/modules/resourceModules/functionApp/functionApp.bicep).
Before deployment, supply:

- An existing compatible Windows App Service plan in the target region.
- An existing host pool resource ID for traceability tags and a Log Analytics workspace.
- A delegated Function App integration subnet, a private-endpoint subnet, and the
  blob, queue, table and Function App private DNS zones for your target cloud.
- An existing Azure Monitor Private Link Scope with its network/DNS connectivity
  already configured for private Application Insights access.

The example creates Function App infrastructure, runtime storage, Application
Insights, private endpoints and storage RBAC. It disables public app/storage access
and uses **platform-managed storage encryption** to keep the naming example focused.
The plan, networking, DNS zones and monitoring prerequisites are not created here.
Function code deployment is separate. If your deployment requires CMK, provision
the storage encryption identity, Key Vault key and permissions before calling the
module; a generated identity name alone does not provision them.

```bicep
targetScope = 'resourceGroup'

import { namingConventionConfig, functionAppNames } from '../../shared/modules/orchestration/naming/naming.bicep'

param namingConvention namingConventionConfig = {}
param location string = resourceGroup().location
param serverFarmId string
param hostPoolResourceId string
param logAnalyticsWorkspaceResourceId string
param privateLinkScopeResourceId string
param functionAppDelegatedSubnetResourceId string
param privateEndpointSubnetResourceId string
param azureBlobPrivateDnsZoneResourceId string
param azureQueuePrivateDnsZoneResourceId string
param azureTablePrivateDnsZoneResourceId string
param azureFunctionAppPrivateDnsZoneResourceId string

@description('Optional. Complete Function App name. Leave empty to generate.')
param functionAppNameOverride string = ''

var context = {
  subscriptionId: subscription().subscriptionId
  resourceGroupName: resourceGroup().name
  location: location
  cloud: environment().name
}
var names = functionAppNames(namingConvention, '<purpose>', context, {
  functionAppName: functionAppNameOverride
})

module app '../../shared/modules/resourceModules/functionApp/functionApp.bicep' = {
  params: {
    functionAppName: names.functionAppName
    storageAccountName: names.storageAccountName
    applicationInsightsName: names.applicationInsightsName
    privateEndpointNameConv: names.privateEndpointNameConv
    privateEndpointNICNameConv: names.privateEndpointNICNameConv
    location: location
    serverFarmId: serverFarmId
    hostPoolResourceId: hostPoolResourceId
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    enableApplicationInsights: true
    privateLinkScopeResourceId: privateLinkScopeResourceId
    functionAppDelegatedSubnetResourceId: functionAppDelegatedSubnetResourceId
    privateEndpoint: true
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    azureTablePrivateDnsZoneResourceId: azureTablePrivateDnsZoneResourceId
    azureFunctionAppPrivateDnsZoneResourceId: azureFunctionAppPrivateDnsZoneResourceId
    paasPublicNetworkAccess: 'Disabled'
    keyManagementStorageAccounts: 'PlatformManaged'
    encryptionKeyName: ''
    encryptionKeyVaultResourceId: ''
    functionAppAppSettings: []
    tags: {}
  }
}

output functionAppName string = app.outputs.functionAppName
output storageAccountName string = names.storageAccountName
```

The bundle accepts its own overrides object. For example, setting
`functionAppNameOverride` to `func-contoso-custom` uses that app name while
storage and Insights still use the convention. The module consumes the returned
names and endpoint patterns; it does not rebuild the convention.

</details>

To check either example without deploying, save it in the entry-template location
above and run:

```powershell
az bicep build --file deployments\add-ons\<name>\main.bicep --outfile "$env:TEMP\addon-naming-example.json"
```

Replace `<name>` with your add-on folder. Compilation checks the module contracts;
it does not verify Azure resource availability, permissions, networking or successful
deployment. These module calls create resources when deployed; naming helpers alone do not.

**No new adapter file, resource role or policy edit is required for a supported
resource type.** A deployment bundle is simply an optional thin adapter: it
chooses purposes and supplies context to the same naming engine. It does not
reimplement formatting, validation or hashing. Explicit overrides and resource
creation/adoption remain the deployment's responsibility.

For another layout, pass explicit component overrides in `namingConvention`.

---

## Contents

1. [How naming works](#how-naming-works)
2. [The built-in CAF-aligned default](#the-built-in-caf-aligned-default)
3. [The `namingConvention` parameter](#the-namingconvention-parameter)
4. [The eight naming components](#the-eight-naming-components)
5. [The `purpose` component](#the-purpose-component)
6. [Special resource-type constraints](#special-resource-type-constraints)
7. [Aligning naming across solutions](#aligning-naming-across-solutions)
8. [Add-on naming](#add-on-naming)
9. [Examples](#examples)
10. [Maintaining the shared naming policy](#maintaining-the-shared-naming-policy)

---

## How naming works

Every resource name in FederalAVD is assembled from an ordered list of **components**. Each component is a named slot that the engine fills with a context-specific value at deployment time:

```text
[component1][delimiter][component2][delimiter]...[componentN]
```

For each resource, the engine substitutes:

| Component | Filled with |
| --- | --- |
| `resourceType` | The resource type abbreviation (e.g., `kv`, `vm`, `vdpool`) |
| `purpose` | A per-resource differentiator (e.g., `avd-01`, `control-plane`, `sec`) |
| `location` | The region abbreviation (e.g., `use`, `usw2`, `use2`) |
| `workload` | A static solution label (e.g., `avd`) |
| `environment` | A static environment label (e.g., `prod`, `dev`) |
| `customToken1` / `customToken2` | Optional static tokens at any position (legacy aliases: `freeform1` / `freeform2`) |
| `none` | Ignored — removed from the output entirely |

Empty-valued top-level components are removed before joining. Separators inside component values are not removed by this step.

Convention-generated names are driven by the shared naming policy and the `namingConvention` parameter. The policy owns defaults, role purposes, patterns, constraints and uniqueness recipes; the parameter supplies customer overrides. Explicit names, existing-resource IDs, provider-required names and lifecycle identifiers are not automatically rewritten.

Portal forms provide naming controls, validation and explicit overrides. Names are resolved at deployment time.

### One scope, one hash

The readable purpose says **what** a resource does. The hash says **where** it
belongs: subscription + resource group + full Azure region, all lowercased.
Cloud, purpose, host-pool identifier and resource type are not hash inputs.
Cloud still selects the region-abbreviation map. The default suffix is six characters.

For example, the shared secrets and encryption vaults in the same scope use:

```text
kv-avd-sec-abc123-use
kv-avd-enc-abc123-use
```

`abc123` is illustrative. Both vaults share the real computed hash, regardless
of whether the consuming host pool is `finance` or `hr`. A different region is
a different scope, even within the same resource group. Storage and Function
Apps use this same scope rule; scope-local resource types do not need an
automatic hash.

> **Existing deployments:** This replaces earlier hash recipes; generated vault,
> storage and Function App names can change. Azure resources are not renamed or
> migrated automatically. Before redeployment, use existing-resource IDs or
> supported complete-name overrides to retain resources, and review Azure
> what-if output. For FSLogix, retaining the old explicit storage prefix retains
> its account naming. Image Management has no per-account name override: plan
> migration of artifacts, access and downstream references before redeploying an
> existing stack with this recipe. Do not assume it will rediscover old names.

Standard and automated Host Pool and Shared Services forms select the delimiter
from **Hyphen (-)** or **Underscore (_)**, defaulting to Hyphen. Image Management
uses a text box supporting one to three hyphens, underscores or dots.
All four forms initially populate Workload Value with `avd`. These are generated
literal defaults from the shared policy, not runtime references to hidden form
controls; operators can still change the selected delimiter and workload.

**Names follow the naming convention subject to resource-specific restrictions.**
The delimiter controls component assembly, but it is not necessarily preserved in
the final resource name. For example, Key Vault formatting converts underscores
and dots to hyphens, while storage account formatting removes separators.

---

## The built-in CAF-aligned default

When `namingConvention` is left at its default value, FederalAVD uses this pattern:

```text
{resourceType}-avd-{purpose}-{location}
```

This follows the CAF recommendation of *abbreviation → workload → component → region*. It is CAF-**aligned** rather than a strict implementation: CAF does not define a `purpose` component, but FederalAVD adds it to disambiguate resources of the same type within a deployment (e.g., separate key vaults for secrets vs. encryption, or multiple host pool resource groups by identifier).

### Default name examples (identifier = `desktop`, index = `1`, region = `eastus` → `use`)

| Resource | Default name |
| --- | --- |
| Resource Group (Control Plane) | `rg-avd-control-plane-use` |
| Resource Group (Hosts) | `rg-avd-desktop-01-hosts-use` |
| Resource Group (Operations) | `rg-avd-operations-use` |
| Host Pool | `vdpool-avd-desktop-01-use` |
| Desktop Application Group | `vddag-avd-desktop-01-use` |
| AVD Workspace | `vdws-avd-use` |
| Scaling Plan | `vdscaling-avd-desktop-01-use` |
| Log Analytics Workspace | `law-avd-use` |
| Key Vault (Secrets) | `kv-avd-sec-{unique}-use` |
| Key Vault (Encryption) | `kv-avd-enc-{unique}-use` |
| Global Feed Workspace | `ws-avd-global-feed` |
| Availability Set | `as-avd-desktop-01-use-##` |
| VM naming pattern | `SHNAME` |
| OS Disk naming pattern | `SHNAME-osdisk` |
| NIC naming pattern | `SHNAME-nic` |

> The `workload` component (`avd`) and the `purpose` component (`desktop-01`) are both present in the name. When `identifier` equals the `workload` value (e.g., both are `avd`), the workload token appears twice — this is intentional and consistent.

Where `SHNAME` is the session host name token and `##` is the availability set index token, both resolved at runtime by the session host deployment module.

### Default abbreviations

All abbreviations come from [`deployments/shared/data/resourceAbbreviations.json`](../deployments/shared/data/resourceAbbreviations.json). Location abbreviations come from [`deployments/shared/data/locations.json`](../deployments/shared/data/locations.json).

Key abbreviations:

| Azure resource | Abbreviation |
| --- | --- |
| Resource Group | `rg` |
| Host Pool | `vdpool` |
| Desktop App Group | `vddag` |
| AVD Workspace | `vdws` |
| Scaling Plan | `vdscaling` |
| Virtual Machine | `vm` |
| OS Disk | `osdisk` |
| Network Interface | `nic` |
| Availability Set | `as` |
| Key Vault | `kv` |
| Storage Account | `sa` |
| Log Analytics Workspace | `law` |
| Recovery Services Vault | `rsv` |
| Disk Encryption Set | `des` |
| Disk Access | `da` |
| User-Assigned Identity | `uai` |
| Compute Gallery | `gal` |
| Function App | `fa` |
| App Service Plan | `asp` |
| Application Insights | `appi` |
| Private Endpoint | `pe` |
| Network Interface (PE) | `nic` |

---

## The `namingConvention` parameter

### Parameter shape

```json
{
  "components":              ["resourceType", "workload", "purpose", "location"],
  "delimiter":               "-",
  "workload":                "avd",
  "environment":             "prod",
  "customToken1":            "",
  "customToken2":            "",
  "locationAbbreviation":    "",
  "imageManagementStoragePrefix": "",
  "vmsLocationAbbreviation": "",
  "cpLocationAbbreviation":  "",
  "fslogixStoragePrefix":    "",
  "fslogixOfficeStoragePrefix": "",
  "resourceTypeCodes":       {}
}
```

### Properties

| Property | Type | Required | Description |
| --- | --- | --- | --- |
| `components` | `string[]` | No | Ordered array of supported [component names](#the-eight-naming-components). Omit to use the default layout. |
| `delimiter` | `string` | No | Character inserted between non-empty components. Defaults to `-`; an empty string is supported. |
| `workload` | `string` | No | Static label for the solution workload. Fills the `workload` component. Example: `avd`. |
| `environment` | `string` | No | Static environment label. Fills the `environment` component. Example: `prod`, `dev`, `test`. |
| `customToken1` | `string` | No | First optional static token, for example an organisation or team. Its position is selected in `components`, not fixed as a prefix. |
| `customToken2` | `string` | No | Second optional static token at any selected position. |
| `freeform1` / `freeform2` | `string` | No | Backward-compatible aliases for the corresponding custom token, both as properties and component names. |
| `locationAbbreviation` | `string` | No | Override for the deployment region abbreviation in Shared Services, Image Management, and the Template Spec publishing script. Leave blank to auto-derive. |
| `imageManagementStoragePrefix` | `string` | No | Shared prefix for Image Management artifacts and build-logs storage accounts. Use 1-5 lowercase letters or numbers. The generated names append `imgassets` or `imglogs`, a deterministic 6-character uniqueness token, and the location abbreviation. When this prefix is used, a custom location abbreviation cannot exceed 4 characters. Leave blank to derive names from the standard Image Management storage naming pattern. |
| `vmsLocationAbbreviation` | `string` | No | Override for the session hosts (VMs) region abbreviation. Leave blank to auto-derive from the deployment location. |
| `cpLocationAbbreviation` | `string` | No | Override for the control plane region abbreviation. Leave blank to auto-derive. |
| `fslogixStoragePrefix` | `string` | No | Custom prefix for Profile storage accounts (≤ 13 lowercase alphanumeric characters, no hyphens). Leave blank to use `fslpc{unique}`. Preserve the original prefix when redeploying existing accounts. |
| `fslogixOfficeStoragePrefix` | `string` | No | Custom prefix for separate Office storage accounts (≤ 13 lowercase alphanumeric characters, no hyphens). Leave blank to use `fsloc{unique}` with the same scope seed as Profile accounts. It must differ from the Profile prefix. |
| `resourceTypeCodes` | `object` | No | Per-resource-type abbreviation overrides. Keys must match the abbreviation file (e.g., `keyVaults`, `virtualMachines`). Values replace the default abbreviation for that type only. |

Deployment parameters and the public API use the shared `namingConventionConfig`
Bicep type. Every property is optional; partial abbreviation overrides remain
supported. Wrong types, unknown top-level properties and unsupported component
names are rejected by the typed deployment schema. Runtime validation checks
selected tokens, delimiters, purposes and type-specific name budgets.

Old parameter files and Portal outputs using `freeform1`/`freeform2` still work.
Either component spelling reads the same token. If both property spellings are
supplied, their values must agree, including explicit empty strings; conflicting
values fail rather than silently selecting one. Renaming aliases alone does not
change generated names. Existing Portal labels and stored host-pool tags do not
need to be rewritten.

### Passing the parameter

**ARM / JSON parameter file:**

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "namingConvention": {
      "value": {
        "components": ["resourceType", "workload", "purpose", "location"],
        "delimiter": "-",
        "workload": "avd",
        "environment": "",
        "customToken1": "",
        "customToken2": ""
      }
    }
  }
}
```

**Bicep parameter file (`.bicepparam`):**

```bicep
param namingConvention = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
  environment: ''
  customToken1: ''
  customToken2: ''
}
```

**Portal (Tags & Naming step):** Use the component picker in the *Tags & Naming* step. The UI assembles this object automatically and writes it to the deployment as `namingConvention`. Copy the resulting object to align other solution deployments.

**Template Spec publishing script:**

```powershell
$namingConvention = @{
  components = @('customToken1', 'workload', 'purpose', 'environment', 'location', 'resourceType')
  delimiter = '-'
  workload = 'avd'
  environment = 'prod'
  customToken1 = 'contoso'
  locationAbbreviation = 'use2'
  resourceTypeCodes = @{
    resourceGroups = 'rg'
    templateSpecs = 'ts'
  }
}

.\tools\New-TemplateSpecs.ps1 `
  -Location 'eastus2' `
  -NamingConvention $namingConvention
```

The publishing script uses `purpose = operations` for its default resource group and a distinct
purpose for each Template Spec. Its `components` array must include `purpose`; otherwise multiple
Template Specs would resolve to the same name. Supplying `-ResourceGroupName` overrides
resource-group name generation without changing Template Spec names. Omitting
`-NamingConvention` uses the default object declared in the script's parameter block.
Partial objects retain the defaults for omitted properties.
The publisher reuses the resolved resource group when it exists and automatically creates it
when missing; no creation flag is needed. This also applies to an explicit
`-ResourceGroupName` override. `-WhatIf` previews these operations without Azure writes.

Publishing a new add-on requires registration as well as infrastructure naming:
add its publishing purpose under `templateSpecs` in the shared naming policy and
an entry in the publisher's `$addOns` catalog using that purpose and the add-on's
folder name. The publisher expects the compiled `main.json` and
`uiFormDefinition.json` in that folder. This publishing metadata is separate from
resource-role recipes; supported resource types still need no add-on-specific
naming role. A missing publishing purpose is an error, not an empty name or a
fallback. The standalone Session Hosts package uses `templateSpecs.sessionHosts`.

---

## The eight naming components

Each element of `components` must be one of these values:

| Component name | Description | Example value |
| --- | --- | --- |
| `resourceType` | Resource type abbreviation from the abbreviation table | `kv`, `vm`, `vdpool` |
| `purpose` | Per-resource differentiator — see [below](#the-purpose-component) | `avd-01`, `sec`, `control-plane` |
| `location` | Region abbreviation | `use`, `usw2`, `use2` |
| `workload` | The static `workload` property value | `avd` |
| `environment` | The static `environment` property value | `prod`, `dev` |
| `customToken1` (alias `freeform1`) | First static custom token | `contoso`, `team-a` |
| `customToken2` (alias `freeform2`) | Second static custom token | `01` |
| `none` | Placeholder that is always removed — use to hold a slot in the Portal UI without including it in the output | — |

In the Portal naming forms, selecting **None (stop here)** hides subsequent component
controls. Hidden controls can return null or empty values rather than their displayed
defaults, so the form output normalizes empty optional component slots to `none`.
Leaving the default four-component layout unchanged must not submit an empty component
name: `""` is not a valid component identifier.

### Minimum required components

| Component | Requirement | What happens without it |
| --- | --- | --- |
| `purpose` | **Required** | Multiple resources of the same type share an identical name → ARM conflict error. Every deployment creates several same-type resources (multiple RGs, two Key Vaults, two UAIs, etc.). The Portal UI blocks submission with an **Error** when `purpose` is absent. |
| `resourceType` | Strongly recommended | Resource names carry no type identifier, making them hard to distinguish in the portal. |
| `location` | Optional | The full region always participates in the scope hash, even when the location component is omitted. Image storage also retains its readable location token. Scope-local names still need distinct formatted purposes across regions. The Portal UI shows a **Warning** (not an error) when `location` is absent. |
| `workload` | Optional | Names are scoped less tightly to your application; collisions with other deployments using the same convention become more likely. The Portal UI shows a **Warning** when `workload` is absent. |

### RT-first vs RT-last

The position of `resourceType` in the array controls the naming style for **all** resources:

| Style | Example | When to use |
| --- | --- | --- |
| **RT-first** (prefix) | `vm-avd-prod-use` | CAF-aligned default; most Azure portal views sort by type |
| **RT-last** (suffix) | `avd-prod-use-vm` | Some organisations prefer alphabetic sorting by workload |

RT-last is detected when `resourceType` is the **last non-`none` component** in the array. Any other position (first, middle) is treated as RT-first.

Networking uses this same typed `namingConvention` object, not a separate resource-type-at-end
switch. Its Portal form offers these two layouts; parameter files accept the full convention.
To migrate an old `nameConvResTypeAtEnd: true` setting, remove that parameter and set
`components` to `["workload", "purpose", "location", "resourceType"]`. The default and
equivalent resource-type-last settings preserve the existing network names. Explicit
resource group, VNet and subnet names are not rewritten; see the
[Networking parameter reference](../deployments/networking/README.md#namingconvention).

> **Important for add-ons:** The Session Host Replacer, Session Hosts, and Storage Quota Manager add-ons infer RT-first/RT-last from the existing host pool name. They detect RT-last by checking whether the host pool name ends with `-vdpool` or `-hp`. They will default to RT-first for any other pattern.

---

## The `purpose` component

The `purpose` component is the most powerful part of the naming system. It is the value that makes each resource in a deployment **unique** while keeping the rest of the name components static.

### How purpose is set

You never set `purpose` manually. The Bicep engine assigns the correct purpose string for each resource automatically:

| Resource | Purpose value |
| --- | --- |
| Host Pool | `{identifier}` (e.g., `avd-01`) |
| Desktop App Group | `{identifier}` |
| Scaling Plan | `{identifier}` |
| Workspace | *(empty — no purpose token)* |
| RG (Control Plane) | `control-plane` |
| RG (Hosts) | `{identifier}-hosts` |
| RG (Storage) | `{identifier}-storage` |
| RG (Standalone shared FSLogix storage) | `fslogix-storage` by default |
| RG (Operations) | `operations` |
| RG (Monitoring) | `monitoring` |
| Key Vault (Secrets) | `sec-{unique}` — the 6-char `uniqueString()` is **embedded in the purpose slot** |
| Key Vault (Encryption) | `enc-{unique}` — same; e.g., `enc-d527e9` |

> **Why embed in purpose?** Embedding the unique suffix in the purpose slot ensures it always appears in a predictable position relative to the other components — before the `location` component in RT-first convention, before the `resourceType` suffix in RT-last. This matches the expected reading order of the name.
| Availability Set | `{identifier}-##` |
| Disk Encryption Set | `{identifier}-customer-keys` / `{identifier}-platform-and-customer-keys` |
| RSV (VMs) | `{identifier}` |
| RSV (Files) | `files` |
| Log Analytics WS | *(empty)* |
| DCE | *(empty)* |
| UAI | `{identifier}-{role}` |

### The `identifier` variable

`identifier` is derived from the `identifier` parameter. It is the stable name for this host pool or resource group that makes it distinct from others in the same subscription. For example, with `identifier = 'desktop'` and `index = 1`, the base name becomes `desktop-01`.

---

## Special resource-type constraints

Some Azure resource types impose naming constraints that override the standard component assembly:

### Key Vault — permitted characters and 24-character limit

[Azure Key Vault naming rules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules#microsoftkeyvault)
require globally unique names of 3–24 alphanumeric or hyphen characters, starting
with a letter and ending with a letter or number, without consecutive hyphens.
Hyphens are the only permitted punctuation; using no delimiter is also valid.

The shared engine first assembles components and purpose parts using the
configured delimiter, then converts `_` and `.` to `-` and applies the length
limit. Thus `-`, `_`, and `.` conventions produce hyphen-separated vault names;
an empty delimiter produces joined components without inserted separators.
Generated vault names reject invalid characters and consecutive hyphens.
Complete name overrides must independently satisfy Azure's rules.

Generated Key Vault names must fit within **24 characters**; overlength names fail deployment instead of being shortened. The unique suffix is **embedded in the `purpose` slot** rather than appended after assembly. This guarantees a consistent position for the unique token in the final name regardless of the component ordering:

- RT-first default: `kv-avd-sec-d527e9-use` (unique is the 3rd component, before location)
- RT-last: `avd-sec-d527e9-use2-kv` (unique is part of the 2nd component, before location and RT)

The purpose joins `sec` or `enc` with the unique token using the configured delimiter (`sec-{unique}` or `enc-{unique}` with the default `-`). The full name is assembled, normalized for Key Vault, then checked against the 24-character limit. Conventions that previously depended on silent truncation must be shortened or given explicit names before redeployment; generated names are not automatically migrated. When a portal naming convention would exceed 24 characters, the form requires complete Secrets and Encryption Key Vault name overrides for the vaults being deployed. ARM/Bicep deployments can set `secretsKeyVaultNameOverride` and `encryptionKeyVaultNameOverride` directly. Overrides are applied before generating the vault name, so they bypass an overlength default. The portal validates override syntax and global availability with the Key Vault `checkNameAvailability` API. An existing name fails validation; select the existing Key Vault instead of deploying a new one.

Both purposes use the same scope hash:

```bicep
take(uniqueString(
  toLower(subscriptionId),
  toLower(operationsResourceGroupName),
  toLower(location)
), 6)
```

This rule does not change when the convention omits `location`. Standalone
Shared Services, inline host-pool vaults and `resourceNameForType` produce the
same vault names for the same convention and target scope. A consolidated
Shared Services deployment uses its effective consolidated group. A host-pool
identifier never participates. This is parity between current entry points,
not compatibility with names generated by an older release.

### Storage Account — alphanumeric only, max 24

Storage account names (FSLogix, Function App backing store) must be lowercase alphanumeric with no hyphens or special characters. The engine strips all delimiters with `stripSeps()` after assembling the name.

Image Management uses compact storage-specific patterns rather than the full
component list. Its six-character scope hash immediately follows the purpose
(`imgassets` or `imglogs`), before the location and any trailing resource-type code:

| Pattern | Example with illustrative hash `abc123` |
| --- | --- |
| Resource type first | `saimgassetsabc123use2` |
| Resource type last | `imgassetsabc123use2sa` |
| Custom prefix `corp` | `corpimgassetsabc123use2` |

Both accounts keep the same scope-hash inputs and 24-character length limit.
FSLogix and Function App storage naming are unchanged.

> **Existing Image Management deployments:** Moving the hash before the location
> changes generated storage account names, including custom-prefix names. Existing
> accounts are not renamed or migrated; redeployment targets different accounts.
> Review what-if before redeploying, and plan artifact/log data migration and
> updates to consuming image-build storage references when adopting the new names.

### Compute Gallery — underscores only

Compute Gallery names cannot contain hyphens. The engine replaces all `-` with `_` after assembling.

### VM, OS Disk, NIC — SHNAME token

Virtual machines, OS disks, and network interfaces use a **naming pattern** rather than a fixed name. The `SHNAME` token is a placeholder that the session host deployment module replaces with the actual session host name at runtime:

- VM: `SHNAME`
- OS disk: `SHNAME-osdisk`
- NIC: `SHNAME-nic`

The actual VM name is `{pattern}` with `SHNAME = {sessionHostNamePrefix}{paddedIndex}`, for example `avdhost001`. These defaults intentionally do not use the virtual machine, OS disk, or network interface resource-type abbreviations or their position in the broader naming convention. This keeps the VM name equal to the session host name and derives the related resources from that stable name.

Use `virtualMachineNameConvOverride`, `virtualMachineDiskNameConvOverride`, and `virtualMachineNicNameConvOverride` to override these defaults.

In the standard Host Pool Portal form, the **Tags & Naming** step hides these three
pattern boxes until **Customize VM, OS disk, and NIC naming** is checked. Leaving
it unchecked uses the shared defaults above, even if custom values were entered
before unchecking it. Checking it reveals the policy-backed defaults and
`SHNAME` validation. The add-on forms inherit patterns from host resource-group
tags. Automated host pools do not expose these three overrides because
AVD owns their VM, disk and NIC names.

### Availability Set — `##` token

The `##` token in availability set names is replaced with the padded availability set index at deployment time, for example `as-avd-01-use` for index 1.

---

## Aligning naming across solutions

To produce a **consistent naming convention** across all solutions, pass the **same `namingConvention` object** to every deployment. The segments, delimiter, and static values must be identical.

### Alignment matrix

| Solution | Parameter name | Notes |
| --- | --- | --- |
| `hostpools/hostpool.bicep` | `namingConvention` | Full object; imports `hostPoolNames` from the canonical naming library with explicit VM/control-plane locations |
| `sharedServices/sharedServices.bicep` | `namingConvention` | Inline naming; fixed identifiers `operations` (Key Vaults) and `monitoring` (Log Analytics Workspace) |
| `imageManagement/imageManagement.bicep` | `namingConvention` | Inline naming; fixed identifier `image-management` |
| `imageBuild/imageBuild.bicep` | `namingConvention` | Shared gallery/identity names only |
| `add-ons/fslogixStorage/main.bicep` | `namingConvention`, `identifier` | Shared storage defaults to fixed identifier `fslogix`; persona-specific storage uses the matching host-pool persona |
| `add-ons/sessionHostReplacer/main.bicep` | `namingConvention`, `identifier`, `namingResourceTypeCodes` | Pass same values as host pool; Portal pre-fills from host pool tags |
| `add-ons/sessionHosts/main.bicep` | *(none)* | VM/disk/NIC patterns via per-resource params; no top-level convention object |
| `add-ons/storageQuotaManager/main.bicep` | `namingConvention`, `identifier`, `namingResourceTypeCodes` | Pass same values as host pool; Portal pre-fills from host pool tags |

### Shared parameter file pattern

The recommended approach is to define the naming convention once in a shared parameter fragment and reference it in each deployment:

**`customer/parameters/shared-naming.json`** (create this file):

```json
{
  "namingConvention": {
    "value": {
      "components": ["resourceType", "workload", "purpose", "location"],
      "delimiter": "-",
      "workload": "avd",
      "environment": "prod",
      "freeform1": "",
      "freeform2": ""
    }
  }
}
```

Then merge this into each solution's parameter file or pass it as a parameter file alongside the solution-specific parameter file in your deployment pipeline.

### Identifier mapping across solutions

The `identifier` (or equivalent) parameter creates the **per-deployment unique token** placed in the `purpose` slot. Use these values to produce names that cross-reference each other clearly:

| Solution | Recommended identifier | Example purpose tokens |
| --- | --- | --- |
| hostpool | `avd-01`, `avd-prod-desktop` | `avd-01`, `avd-01-hosts`, `avd-01-storage` |
| keyVaults standalone | `operations` | `sec`, `enc` |
| imageManagement | `image-management` | `image-management` |

### Cross-region deployments

When CP and VMs are in different regions, both locations appear in the name:

- Control plane resources (Host Pool, DAG, Workspace, Scaling Plan, CP RG) use `cpLocationAbbreviation`.
- VMs, disks, storage, shared Operations/Monitoring RGs, Key Vaults, Log Analytics,
  DCR/DCE and backup vaults use `vmsLocationAbbreviation`.

The hash always uses the full target region, not its display abbreviation.
Changing `vmsLocationAbbreviation` or `cpLocationAbbreviation` does not replace
that region input. Changing an abbreviation can still change a generated
resource-group name, which in turn changes its scope hash.

---

## Add-on naming

The add-ons are deployed **after** the host pool exists. Session Host Replacer and Storage Quota Manager accept the same `namingConvention`, `identifier`, and `namingResourceTypeCodes` parameters as the host pool, so passing the same values produces consistent names across the entire deployment.

### Portal deployments

When deploying from the Portal, the *Advanced* step pre-populates `namingConvention` and `identifier` from tags on the host pool and its resource group (`hpNamingConvention`, `hpIdentifier`). If the host pool tag is absent, the *Advanced* step surfaces override fields so you can provide explicit names.

### Parameter file / CLI deployments

Pass the same `namingConvention` object and `identifier` value used in the host pool deployment. If the host pool was deployed with the default CAF convention, omit both parameters — the add-on defaults produce CAF-aligned names automatically.

### Override parameters

When the convention-derived names need fine-tuning, each add-on exposes per-resource override parameters:

| Add-on | Override parameters |
| --- | --- |
| Session Host Replacer | `functionAppNameOverride`, `storageAccountNameOverride`, `storageEncryptionIdentityNameOverride`, `appServicePlanNameOverride`, `virtualMachineNameConv`, `virtualMachineDiskNameConv`, `virtualMachineNicNameConv`, `availabilitySetNameConv` |
| Session Hosts | `virtualMachineNameConv`, `virtualMachineDiskNameConv`, `virtualMachineNicNameConv`, `availabilitySetNameConv` |
| Storage Quota Manager | `functionAppNameOverride`, `storageAccountNameOverride`, `storageEncryptionIdentityNameOverride`, `appServicePlanNameOverride` |

---

## Examples

### Example 1 — CAF default

Do nothing. Deploy using the Portal or parameter files without overriding `namingConvention`. With `identifier = 'desktop'`, `index = 1`, `region = 'eastus'`, resources are named:

```text
vdpool-avd-desktop-01-use
rg-avd-control-plane-use
kv-avd-sec-d527e9-use
SHNAME  →  desktophost001
```

### Example 2 — Standard custom convention, RT-first

Four segments, RT first, workload `avd`, environment `prod`:

```json
{
  "components": ["resourceType", "workload", "purpose", "location"],
  "delimiter": "-",
  "workload": "avd",
  "environment": "prod"
}
```

Results (identifier = `desktop`, index = `1`, region = `eastus`):

```text
vdpool-avd-desktop-01-use
rg-avd-desktop-01-hosts-use
kv-avd-sec-d527e9-use
SHNAME  →  desktophost001
```

### Example 3 — RT-last convention

```json
{
  "components": ["workload", "purpose", "location", "resourceType"],
  "delimiter": "-",
  "workload": "avd",
  "environment": ""
}
```

Results (identifier = `prod`, region = `eastus2`):

```text
avd-prod-use2-vdpool
avd-prod-use2-vddag
avd-sec-75d05c-use2-kv
SHNAME  →  avdhost001
```

### Example 4 — Organisation token with explicit vault names

```json
{
  "components": ["customToken1", "workload", "purpose", "location", "resourceType"],
  "delimiter": "-",
  "customToken1": "contoso",
  "workload": "avd",
  "environment": "",
  "secretsKeyVaultNameOverride": "contoso-sec-use",
  "encryptionKeyVaultNameOverride": "contoso-enc-use"
}
```

Results (identifier = `avd`, region = `eastus`):

```text
contoso-avd-avd-use-vdpool
contoso-avd-control-plane-use-rg
contoso-sec-use
SHNAME  →  avdhost001
```

> **Note:** The generated vault name exceeds 24 characters (`contoso-avd-sec-{unique}-use-kv` = 29 chars). This example supplies complete overrides; generated names are never shortened. Replace illustrative explicit names with globally available names.

### Example 5 — Underscore delimiter with resource-specific exceptions

```json
{
  "components": ["resourceType", "workload", "environment", "purpose", "location"],
  "delimiter": "_",
  "workload": "avd",
  "environment": "prod"
}
```

Results (identifier = `avd`, region = `westus2`):

```text
vdpool_avd_prod_avd_usw2
rg_avd_prod_control-plane_usw2
kv-avd-prod-sec-f0485a-u
SHNAME, SHNAME-osdisk, SHNAME-nic
```

> **Note:** `kvSanitize()` converts underscores and dots to hyphens in generated Key Vault names. An empty convention delimiter remains empty. Complete overrides must independently satisfy Azure Key Vault naming rules.

### Example 6 — Abbreviation override

Override `keyVaults` abbreviation to `vault` for an organisation standard:

```json
{
  "components": ["resourceType", "workload", "purpose", "location"],
  "delimiter": "-",
  "workload": "avd",
  "resourceTypeCodes": {
    "keyVaults": "vault"
  }
}
```

Results:

```text
vault-avd-sec-d527e9-use    ← instead of kv-avd-sec-d527e9-use
vdpool-avd-desktop-01-use   ← other types unchanged
```

---

## Maintaining the shared naming policy

The authoritative rule catalog is the internal `namingPolicy` object in
[`internal.bicep`](../deployments/shared/modules/orchestration/naming/internal.bicep).
The public [`naming.bicep`](../deployments/shared/modules/orchestration/naming/naming.bicep)
interface exports the shared `namingConventionConfig` type and six functions: `resourceNameForType`, `functionAppNames`,
`hostPoolNames`, `fslogixNames`, `sharedServicesNames` and `imageManagementNames`.
Deployment bundles own location lookup and uniqueness seeds. Shared Services and
Image Management pass deployment context instead of constructing region codes
and hash seeds locally. Existing specialized callers and resource modules use
internal role adapters; these are not an extension API for new add-ons. Roles and
type-based calls share composition, convention validation and type-budget checks.
Role rules retain established casing/delimiters and intentional empty-purpose or
workload-free patterns. Invalid configurations that previously produced an empty,
malformed or overlength name now fail. Explicit resource-name patterns and
temporary-computer-name fragments have separate lifecycle contracts.
Host pools import `hostPoolNames` directly; standalone FSLogix imports
`fslogixNames`, not a host-pool module. The standard host pool accepts
`virtualMachinesLocation`, defaulting to `controlPlaneLocation` (which defaults
to the deployment location). Supply the intended locations explicitly for
split-location deployments; see the
[location and bundle contract](../deployments/shared/modules/orchestration/naming/README.md#explicit-locations-and-naming-bundles).
Abbreviations and region mappings remain in shared JSON so Bicep and PowerShell
can consume the same configuration.

For example, both host pools and Shared Services request the
`operationsResourceGroup` role. Change that role's purpose once to affect both;
do not edit their deployment templates separately. A default workload change
also reaches Image Management, Replacer, networking and workload-bearing
Automation Accounts. Some roles intentionally omit workload.

Bicep parameter defaults and Portal controls use **explicit literal defaults**.
There is no synchronization script or hidden Portal policy snapshot. After changing
the native policy, update any corresponding literals and run the drift checks:

```powershell
Invoke-Pester -Path tests\Naming.Tests.ps1,tests\NamingBundles.Tests.ps1,tests\IdentifierNaming.Tests.ps1
```

Tests evaluate the exported policy with Bicep, then check component order,
delimiter, workload, editable abbreviations, session-host pattern fallbacks,
the shared FSLogix identifier and Bicep parameter defaults. ARM parameter defaults
remain literals because they cannot reference variables. Forms retain user choices
and host-pool inheritance without reading an uninitialized hidden control.

The Template Spec publisher has explicit naming defaults and purpose tokens,
validated against the compiled policy by Pester. It does not import the policy or
run a synchronization gate. Review publisher name changes deliberately: a changed
name can target a different Template Spec rather than update an existing one.

Rebuild affected ARM JSON and run the naming regression and synchronization
checks. Test the affected steps in a live Azure Portal session after changing
form bindings; static validation cannot prove Portal rendering behavior.
The Template Spec publisher still reads the shared abbreviation and location catalogs.
See the [maintainer reference](../deployments/shared/modules/orchestration/naming/README.md)
for implementation boundaries and tests.

### Resource naming interface

Use the same interface regardless of deployment family:

```bicep
import { resourceNameForType } from '../../shared/modules/orchestration/naming/naming.bicep'

var storageName = resourceNameForType(namingConvention, 'Microsoft.Storage/storageAccounts', '${identifier}-data', context)
var vaultName = resourceNameForType(namingConvention, 'Microsoft.KeyVault/vaults', 'sec', context)
```

The resource type is case-insensitive and must omit `@apiVersion`. Internal keys
such as `storageAccounts` and `keyVaults` are not accepted by this function.
For ambiguous resource types, supply an explicit `context.namingVariant`:

| Official resource type | Required naming variant |
| --- | --- |
| `Microsoft.Web/sites` | `functionapp` (web-app naming is not supported) |
| `Microsoft.DesktopVirtualization/applicationGroups` | `Desktop` or `RemoteApp` |

For example:

```bicep
var functionName = resourceNameForType(namingConvention, 'Microsoft.Web/sites', identifier, union(context, { namingVariant: 'functionapp' }))
var desktopGroupName = resourceNameForType(namingConvention, 'Microsoft.DesktopVirtualization/applicationGroups', identifier, union(context, { namingVariant: 'Desktop' }))
var remoteGroupName = resourceNameForType(namingConvention, 'Microsoft.DesktopVirtualization/applicationGroups', identifier, union(context, { namingVariant: 'RemoteApp' }))
```

Variants are case-insensitive. Missing or unsupported variants, variants on
unambiguous types, unsupported resource types, and legacy type keys fail explicitly.
Bundles supply their known variants internally. The API change does not change
generated names, uniqueness seeds, or the existing `resourceTypeCodes` override keys.

The example import is relative to an add-on entry template. `context` supplies
the actual target subscription, owning resource group, location and cloud. To
name a subscription-scoped resource group, pass `resourceGroupName: ''`; that
field does not affect its unhashed name, avoiding circular naming dependencies.
Use distinct formatted purposes for multiple same-type resources in one scope.
For shared resources, use a shared purpose such as `sec`, not the consuming
host-pool identifier.

For new add-ons, use the
[identifier-based shared interface](../deployments/shared/modules/orchestration/naming/README.md#adding-a-function-app-add-on)
instead of adding an application-specific resource role. `functionAppNames`
returns per-application names and private-endpoint patterns from
one identifier, convention, actual target context and explicit overrides. Name
shared hosting plans separately using their owning purpose. `resourceNameForType`
handles all 36 convention-named types in the abbreviation catalog, not just
Function App resources. Neither requires a customer-chosen
uniqueness suffix or a policy update for each add-on.

The interface adds a deterministic hash only for globally named Storage accounts,
Key Vaults and Function Apps (`globallyUnique: true` in the policy). Hashes are
six characters by default. Their seed includes only the lowercased subscription,
owning resource group and full region. Cloud is used for region-abbreviation
lookup, not hashing. Different purposes and resource
types in that scope share one token. Names preserve the full formatted
identifier and static components.
Scope-local types have no automatic hash and retain the full formatted identifier;
overlength names fail with an instruction to shorten the identifier or convention.
Callers must distinguish names within their scope, including identifiers that
normalize identically or conventions that omit location. For example, `inv_app`
and `inv-app` produce the same formatted Function App name and the same scope
hash; use genuinely distinct purposes such as `inventory` and `cleanup`.
The generic Function
App bundle leaves Insights and storage-CMK identity names unhashed. Shared plans
also have no hash. SHR uses this same bundle with `${hostPoolIdentifier}-shr`,
not a separate compatibility recipe. Its plan uses the shared `shr` purpose;
an existing hosting-plan resource ID still bypasses plan creation.

For example, identifier `finance`, region `use` and illustrative hash `abc123`
produce `fa-avd-finance-shr-abc123-use`, `saavdfinanceshrabc123use`,
`appi-avd-finance-shr-use`, and `uai-avd-finance-shr-storage-cmk-use`.
The shared plan is `asp-avd-shr-use`. Generated storage must fit 24 characters;
provide `storageAccountNameOverride` if the complete name is too long. Bundle
overrides are applied before default generation, so this escape path does not
evaluate an invalid default. Image Management and generated FSLogix prefixes
use the common scope hash too, while retaining their specialized readable
patterns. Per-build IDs and private-endpoint VNet shortening have separate
lifecycles and are not stable service-scope hashes.

VM resource names and OS computer names are distinct: the generic API supports
a 64-character resource name, while Windows computer-name patterns have a
15-character limit.
Workbook GUIDs and provider-required literal names are not ordinary
convention names. See the [complete type coverage and exceptions](../deployments/shared/modules/orchestration/naming/README.md#resource-type-api-and-naming-guarantees).

Role-specific patterns are explicit in the policy, including
workload-free quota/route Automation Accounts, standalone `avset-##` patterns,
specialized image storage and key names, and per-run image-build identities.
Customer overrides and stored host-pool naming tags take precedence.

Last updated: 2026-10-28
