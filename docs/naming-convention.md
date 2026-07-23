[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Naming Convention

This document describes how FederalAVD names every Azure resource it creates, how to configure a custom naming convention that is consistent across all solutions, and how the built-in default aligns with Microsoft's [Cloud Adoption Framework (CAF) naming guidance](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming).

---

## Contents

1. [How naming works](#how-naming-works)
2. [The built-in CAF default](#the-built-in-caf-default)
3. [The `namingConvention` parameter](#the-namingconvention-parameter)
4. [The eight naming components](#the-eight-naming-components)
5. [The `purpose` component](#the-purpose-component)
6. [Special resource-type constraints](#special-resource-type-constraints)
7. [Aligning naming across solutions](#aligning-naming-across-solutions)
8. [Add-on naming](#add-on-naming)
9. [Examples](#examples)
10. [Scenario test results](#scenario-test-results)

---

## How naming works

Every resource name in FederalAVD is assembled from an ordered list of **components**. Each component is a named slot that the engine fills with a context-specific value at deployment time:

```
[component1][delimiter][component2][delimiter]...[componentN]
```

For each resource, the engine substitutes:

| Component | Filled with |
|---------|-------------|
| `resourceType` | The resource type abbreviation (e.g., `kv`, `vm`, `vdpool`) |
| `purpose` | A per-resource differentiator (e.g., `avd-01`, `control-plane`, `sec`) |
| `location` | The region abbreviation (e.g., `use`, `usw2`, `use2`) |
| `workload` | A static solution label (e.g., `avd`) |
| `environment` | A static environment label (e.g., `prod`, `dev`) |
| `freeform1` / `freeform2` | Static free-text slots (e.g., organisation name, team) |
| `none` | Ignored — removed from the output entirely |

Empty-valued components are automatically removed before joining, so there are no leading, trailing, or doubled delimiters.

**Naming is driven by a single parameter**, `namingConvention`, passed to each solution. The default value produces CAF-aligned names. When it is supplied with custom values, all resource names across the deployment are assembled from the same ordered component array — giving you a fully consistent naming convention in one place.

---

## The built-in CAF-aligned default

When `namingConvention` is left at its default value, FederalAVD uses this pattern:

```
{resourceType}-avd-{purpose}-{location}
```

This follows the CAF recommendation of *abbreviation → workload → component → region*. It is CAF-**aligned** rather than a strict implementation: CAF does not define a `purpose` component, but FederalAVD adds it to disambiguate resources of the same type within a deployment (e.g., separate key vaults for secrets vs. encryption, or multiple host pool resource groups by identifier).

### Default name examples (identifier = `desktop`, index = `1`, region = `eastus` → `use`)

| Resource | Default name |
|----------|-------------|
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
| VM naming pattern | `vm-SHNAME` |
| OS Disk naming pattern | `osdisk-SHNAME` |
| NIC naming pattern | `nic-SHNAME` |

> The `workload` component (`avd`) and the `purpose` component (`desktop-01`) are both present in the name. When `identifier` equals the `workload` value (e.g., both are `avd`), the workload token appears twice — this is intentional and consistent.

Where `SHNAME` is the session host name token and `##` is the availability set index token, both resolved at runtime by the session host deployment module.

### Default abbreviations

All abbreviations come from [`.common/data/resourceAbbreviations.json`](../.common/data/resourceAbbreviations.json). Location abbreviations come from [`.common/data/locations.json`](../.common/data/locations.json).

Key abbreviations:

| Azure resource | Abbreviation |
|---------------|-------------|
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
  "freeform1":               "",
  "freeform2":               "",
  "vmsLocationAbbreviation": "",
  "cpLocationAbbreviation":  "",
  "fslogixStoragePrefix":    "",
  "resourceTypeCodes":       {}
}
```

### Properties

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `components` | `string[]` | Yes | Ordered array of component names. Each element must be one of the [eight component names](#the-eight-naming-components). |
| `delimiter` | `string` | Yes | Character inserted between non-empty components. Typically `-`. |
| `workload` | `string` | No | Static label for the solution workload. Fills the `workload` component. Example: `avd`. |
| `environment` | `string` | No | Static environment label. Fills the `environment` component. Example: `prod`, `dev`, `test`. |
| `freeform1` | `string` | No | First free-text slot. Use for organisation or team prefix. |
| `freeform2` | `string` | No | Second free-text slot. Use for any additional static token. |
| `vmsLocationAbbreviation` | `string` | No | Override for the session hosts (VMs) region abbreviation. Leave blank to auto-derive from the deployment location. |
| `cpLocationAbbreviation` | `string` | No | Override for the control plane region abbreviation. Leave blank to auto-derive. |
| `fslogixStoragePrefix` | `string` | No | Custom prefix for FSLogix storage accounts (≤ 13 lowercase alphanumeric characters, no hyphens). Leave blank to use the auto-derived prefix `fslogix{unique}`. |
| `resourceTypeCodes` | `object` | No | Per-resource-type abbreviation overrides. Keys must match the abbreviation file (e.g., `keyVaults`, `virtualMachines`). Values replace the default abbreviation for that type only. |

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
        "freeform1": "",
        "freeform2": ""
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
  freeform1: ''
  freeform2: ''
}
```

**Portal (Tags & Naming step):** Use the component picker in the *Tags & Naming* step. The UI assembles this object automatically and writes it to the deployment as `namingConvention`. Copy the resulting object to align other solution deployments.

---

## The eight naming components

Each element of `components` must be one of these values:

| Component name | Description | Example value |
|-------------|-------------|--------------|
| `resourceType` | Resource type abbreviation from the abbreviation table | `kv`, `vm`, `vdpool` |
| `purpose` | Per-resource differentiator — see [below](#the-purpose-component) | `avd-01`, `sec`, `control-plane` |
| `location` | Region abbreviation | `use`, `usw2`, `use2` |
| `workload` | The static `workload` property value | `avd` |
| `environment` | The static `environment` property value | `prod`, `dev` |
| `freeform1` | The static `freeform1` property value | `contoso`, `team-a` |
| `freeform2` | The static `freeform2` property value | anything |
| `none` | Placeholder that is always removed — use to hold a slot in the Portal UI without including it in the output | — |

### Minimum required components

| Component | Requirement | What happens without it |
|-----------|-------------|------------------------|
| `purpose` | **Required** | Multiple resources of the same type share an identical name → ARM conflict error. Every deployment creates several same-type resources (multiple RGs, two Key Vaults, two UAIs, etc.). The Portal UI blocks submission with an **Error** when `purpose` is absent. |
| `resourceType` | Strongly recommended | Resource names carry no type identifier, making them hard to distinguish in the portal. |
| `location` | Optional | The location abbreviation is still embedded in storage account names and added to Key Vault unique-string seeds, so cross-region deployments remain collision-free. Other resource names simply won't contain a location segment. The Portal UI shows a **Warning** (not an error) when `location` is absent. |
| `workload` | Optional | Names are scoped less tightly to your application; collisions with other deployments using the same convention become more likely. The Portal UI shows a **Warning** when `workload` is absent. |

### RT-first vs RT-last

The position of `resourceType` in the array controls the naming style for **all** resources:

| Style | Example | When to use |
|-------|---------|-------------|
| **RT-first** (prefix) | `vm-avd-prod-use` | CAF-aligned default; most Azure portal views sort by type |
| **RT-last** (suffix) | `avd-prod-use-vm` | Some organisations prefer alphabetic sorting by workload |

RT-last is detected when `resourceType` is the **last non-`none` component** in the array. Any other position (first, middle) is treated as RT-first.

> **Important for add-ons:** The Session Host Replacer, Session Hosts, and Storage Quota Manager add-ons infer RT-first/RT-last from the existing host pool name. They detect RT-last by checking whether the host pool name ends with `-vdpool` or `-hp`. They will default to RT-first for any other pattern.

---

## The `purpose` component

The `purpose` component is the most powerful part of the naming system. It is the value that makes each resource in a deployment **unique** while keeping the rest of the name components static.

### How purpose is set

You never set `purpose` manually. The Bicep engine assigns the correct purpose string for each resource automatically:

| Resource | Purpose value |
|----------|--------------|
| Host Pool | `{identifier}` (e.g., `avd-01`) |
| Desktop App Group | `{identifier}` |
| Scaling Plan | `{identifier}` |
| Workspace | *(empty — no purpose token)* |
| RG (Control Plane) | `control-plane` |
| RG (Hosts) | `{identifier}-hosts` |
| RG (Storage) | `{identifier}-storage` |
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

### Key Vault — 24-character limit

Key Vault names are capped at **24 characters**. The unique suffix is **embedded in the `purpose` slot** rather than appended after assembly. This guarantees a consistent position for the unique token in the final name regardless of the component ordering:

- RT-first default: `kv-avd-sec-d527e9-use` (unique is the 3rd component, before location)
- RT-last: `avd-sec-d527e9-use2-kv` (unique is part of the 2nd component, before location and RT)

The full name is assembled from `purpose = 'sec-{unique}'` or `'enc-{unique}'`, then capped at 24 characters with `take(name, 24)`. For short conventions (default CAF), the assembled name is ≤ 24 characters and no truncation occurs. For longer conventions (e.g., with a `freeform1` org prefix), the name may be truncated — the portal shows a warning and a live name preview.

The `uniqueString()` seed is:

- With a `location` component: `uniqueString(subscriptionId, operationsResourceGroupName)`
- Without a `location` component: `uniqueString(subscriptionId, operationsResourceGroupName, region)` — the region is added to prevent cross-region collisions when location is not in the name.

> **Parity guarantee:** The hostpool deployment's inline Key Vault names use the **same seed** as the standalone `keyVaults.bicep` deployment. Deploy `keyVaults.bicep` first, then reference its outputs — or re-run the hostpool deployment and it will find the existing vaults by name.

### Storage Account — alphanumeric only, max 24

Storage account names (FSLogix, Function App backing store) must be lowercase alphanumeric with no hyphens or special characters. The engine strips all delimiters with `stripSeps()` after assembling the name.

### Compute Gallery — underscores only

Compute Gallery names cannot contain hyphens. The engine replaces all `-` with `_` after assembling.

### VM, OS Disk, NIC — SHNAME token

Virtual machines, OS disks, and network interfaces use a **naming pattern** rather than a fixed name. The `SHNAME` token is a placeholder that the session host deployment module replaces with the actual session host name at runtime:

- RT-first: `vm-SHNAME`, `osdisk-SHNAME`, `nic-SHNAME`
- RT-last: `SHNAME-vm`, `SHNAME-osdisk`, `SHNAME-nic`

The actual VM name is `{pattern}` with `SHNAME = {sessionHostNamePrefix}{paddedIndex}`, for example `vm-avdhost001`.

### Availability Set — `##` token

The `##` token in availability set names is replaced with the padded availability set index at deployment time, for example `as-avd-01-use` for index 1.

---

## Aligning naming across solutions

To produce a **consistent naming convention** across all solutions, pass the **same `namingConvention` object** to every deployment. The segments, delimiter, and static values must be identical.

### Alignment matrix

| Solution | Parameter name | Notes |
|----------|---------------|-------|
| `hostpools/hostpool.bicep` | `namingConvention` | Full object; naming resolved in `modules/naming.bicep` |
| `keyVaults/keyVaults.bicep` | `namingConvention` | Inline naming; fixed identifier `operations` |
| `imageManagement/imageManagement.bicep` | `namingConvention` | Inline naming; fixed identifier `image-management` |
| `imageBuild/imageBuild.bicep` | `namingConvention` | Shared gallery/identity names only |
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
|----------|----------------------|----------------------|
| hostpool | `avd-01`, `avd-prod-desktop` | `avd-01`, `avd-01-hosts`, `avd-01-storage` |
| keyVaults standalone | `operations` | `sec`, `enc` |
| imageManagement | `image-management` | `image-management` |

### Cross-region deployments

When CP and VMs are in different regions, both locations appear in the name:

- Control plane resources (Host Pool, DAG, Workspace, Scaling Plan, CP RG) use `cpLocationAbbreviation`.
- VMs, disks, storage, operations RGs use `vmsLocationAbbreviation`.

If your convention omits `location`, set **both** `vmsLocationAbbreviation` and `cpLocationAbbreviation` in `namingConvention` to ensure the uniqueString seed for Key Vaults remains stable across regions.

---

## Add-on naming

The add-ons are deployed **after** the host pool exists. Session Host Replacer and Storage Quota Manager accept the same `namingConvention`, `identifier`, and `namingResourceTypeCodes` parameters as the host pool, so passing the same values produces consistent names across the entire deployment.

### Portal deployments

When deploying from the Portal, the *Advanced* step pre-populates `namingConvention` and `identifier` from tags on the host pool and its resource group (`hpNamingConvention`, `hpIdentifier`). The derived resource names are shown in a live preview. If the host pool tag is absent, the *Advanced* step surfaces override fields so you can provide explicit names.

### Parameter file / CLI deployments

Pass the same `namingConvention` object and `identifier` value used in the host pool deployment. If the host pool was deployed with the default CAF convention, omit both parameters — the add-on defaults produce CAF-aligned names automatically.

### Override parameters

When the convention-derived names need fine-tuning, each add-on exposes per-resource override parameters:

| Add-on | Override parameters |
|--------|-------------------|
| Session Host Replacer | `functionAppNameOverride`, `storageAccountNameOverride`, `storageEncryptionIdentityNameOverride`, `applicationInsightsNameOverride`, `appServicePlanNameOverride`, `virtualMachineNameConv`, `virtualMachineDiskNameConv`, `virtualMachineNicNameConv`, `availabilitySetNameConv` |
| Session Hosts | `virtualMachineNameConv`, `virtualMachineDiskNameConv`, `virtualMachineNicNameConv`, `availabilitySetNameConv` |
| Storage Quota Manager | `functionAppNameOverride`, `storageAccountNameOverride`, `storageEncryptionIdentityNameOverride`, `appServicePlanNameOverride` |

---

## Examples

### Example 1 — CAF default

Do nothing. Deploy using the Portal or parameter files without overriding `namingConvention`. With `identifier = 'desktop'`, `index = 1`, `region = 'eastus'`, resources are named:

```
vdpool-avd-desktop-01-use
rg-avd-control-plane-use
kv-avd-sec-d527e9-use
vm-SHNAME  →  vm-desktophost001
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

```
vdpool-avd-desktop-01-use
rg-avd-desktop-01-hosts-use
kv-avd-sec-d527e9-use
vm-SHNAME  →  vm-desktophost001
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

```
avd-prod-use2-vdpool
avd-prod-use2-vddag
avd-sec-75d05c-use2-kv
SHNAME-vm  →  avdhost001-vm
```

### Example 4 — Organisation prefix with freeform1

```json
{
  "components": ["freeform1", "workload", "purpose", "location", "resourceType"],
  "delimiter": "-",
  "freeform1": "contoso",
  "workload": "avd",
  "environment": ""
}
```

Results (identifier = `avd`, region = `eastus`):

```
contoso-avd-avd-use-vdpool
contoso-avd-control-plane-use-rg
contoso-avd-sec-9ef5b1-u
SHNAME-vm  →  avdhost001-vm
```

> **Note:** The KV name is truncated to 24 characters (`contoso-avd-sec-{unique}-use-kv` = 29 chars). The `location` and `resourceType` suffix are lost to truncation. If you use long org prefixes, consider keeping `location` before `resourceType` and keeping the total component length short.

### Example 5 — Underscore delimiter (no hyphens in names)

```json
{
  "components": ["resourceType", "workload", "environment", "purpose", "location"],
  "delimiter": "_",
  "workload": "avd",
  "environment": "prod"
}
```

Results (identifier = `avd`, region = `westus2`):

```
vdpool_avd_prod_avd_usw2
rg_avd_prod_control-plane_usw2
kv-avd-prod-sec-f0485a-u
vm-SHNAME  (VM/disk/NIC always use hyphens in the SHNAME pattern)
```

> **Note:** `kvSanitize()` converts underscores and dots to hyphens in Key Vault names, so the KV name always uses `-` regardless of the convention delimiter. The KV name is also truncated to 24 characters here.

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

```
vault-avd-sec-d527e9-use    ← instead of kv-avd-sec-d527e9-use
vdpool-avd-desktop-01-use   ← other types unchanged
```

---

## Scenario test results

See **[naming-convention-test-results.md](naming-convention-test-results.md)** for a full matrix of 8 scenarios run against the naming engine simulation. All scenarios pass KV name parity between the hostpool inline deployment and the standalone `keyVaults.bicep` deployment.

The 8 scenarios cover:

| # | Scenario |
|---|---------|
| 1 | CAF default, single region |
| 2 | CAF default, split CP / VMs regions |
| 3 | Custom RT-first, 4 components, workload + environment |
| 4 | Custom RT-last, 4 components |
| 5 | Custom with org prefix in `freeform1`, RT-last |
| 6 | Custom with `environment` component, underscore delimiter |
| 7 | Custom with no `location` component (tests KV seed fallback) |
| 8 | Custom with RT in mid-position (not first, not last) |

---

*Last updated: 2026-06-17*
