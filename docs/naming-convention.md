[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Naming Convention

This document describes how FederalAVD names every Azure resource it creates, how to configure a custom naming convention that is consistent across all solutions, and how the built-in default aligns with Microsoft's [Cloud Adoption Framework (CAF) naming guidance](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming).

---

## Contents

1. [How naming works](#how-naming-works)
2. [The built-in CAF default](#the-built-in-caf-default)
3. [The `customNamingConvention` parameter](#the-customnamingconvention-parameter)
4. [The eight naming segments](#the-eight-naming-segments)
5. [The `purpose` component](#the-purpose-component)
6. [Special resource-type constraints](#special-resource-type-constraints)
7. [Aligning naming across solutions](#aligning-naming-across-solutions)
8. [Add-on naming — brownfield inference](#add-on-naming--brownfield-inference)
9. [Examples](#examples)
10. [Scenario test results](#scenario-test-results)

---

## How naming works

Every resource name in FederalAVD is assembled from an ordered list of **segments**. Each segment is a named slot that the engine fills with a context-specific value at deployment time:

```
[segment1][delimiter][segment2][delimiter]...[segmentN]
```

For each resource, the engine substitutes:

| Segment | Filled with |
|---------|-------------|
| `resourceType` | The resource type abbreviation (e.g., `kv`, `vm`, `vdpool`) |
| `purpose` | A per-resource differentiator (e.g., `avd-01`, `control-plane`, `sec`) |
| `location` | The region abbreviation (e.g., `use`, `usw2`, `use2`) |
| `workload` | A static solution label (e.g., `avd`) |
| `environment` | A static environment label (e.g., `prod`, `dev`) |
| `freeform1` / `freeform2` | Static free-text slots (e.g., organisation name, team) |
| `none` | Ignored — removed from the output entirely |

Empty-valued segments are automatically removed before joining, so there are no leading, trailing, or doubled delimiters.

**Naming is driven by a single parameter**, `customNamingConvention`, passed to each solution. When the parameter is omitted (or left as `{}`), the built-in CAF default is used. When it is supplied, all resource names across the deployment are assembled from the same ordered segment array — giving you a fully consistent naming convention in one place.

---

## The built-in CAF default

When `customNamingConvention` is not set, FederalAVD uses this pattern:

```
{resourceType}-avd-{purpose}-{location}
```

This follows the CAF recommendation: *abbreviation → workload → component → region*.

### Default name examples (identifier = `avd`, region = `eastus` → `use`)

| Resource | Default name |
|----------|-------------|
| Resource Group (Control Plane) | `rg-avd-control-plane-use` |
| Resource Group (Hosts) | `rg-avd-avd-hosts-use` |
| Resource Group (Operations) | `rg-avd-operations-use` |
| Host Pool | `vdpool-avd-use` |
| Desktop Application Group | `vddag-avd-use` |
| AVD Workspace | `vdws-avd-use` |
| Scaling Plan | `vdscaling-avd-use` |
| Log Analytics Workspace | `law-avd-use` |
| Key Vault (Secrets) | `kv-avd-sec-use-{6-char suffix}` |
| Key Vault (Encryption) | `kv-avd-enc-use-{6-char suffix}` |
| Availability Set | `as-avd-##-use` |
| VM naming pattern | `vm-SHNAME` |
| OS Disk naming pattern | `osdisk-SHNAME` |
| NIC naming pattern | `nic-SHNAME` |

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

## The `customNamingConvention` parameter

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
| `components` | `string[]` | Yes | Ordered array of segment names. Each element must be one of the [eight segment names](#the-eight-naming-segments). |
| `delimiter` | `string` | Yes | Separator inserted between non-empty segments. Typically `-`. |
| `workload` | `string` | No | Static label for the solution workload. Fills the `workload` segment. Example: `avd`. |
| `environment` | `string` | No | Static environment label. Fills the `environment` segment. Example: `prod`, `dev`, `test`. |
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
    "customNamingConvention": {
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
param customNamingConvention = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
  environment: ''
  freeform1: ''
  freeform2: ''
}
```

**Portal (Custom Naming step):** Use the six-slot segment picker in the *Tags & Naming* step. The UI assembles this object automatically and writes it to the deployment as `customNamingConvention`. Copy the resulting object to align other solution deployments.

---

## The eight naming segments

Each element of `components` must be one of these values:

| Segment name | Description | Example value |
|-------------|-------------|--------------|
| `resourceType` | Resource type abbreviation from the abbreviation table | `kv`, `vm`, `vdpool` |
| `purpose` | Per-resource differentiator — see [below](#the-purpose-component) | `avd-01`, `sec`, `control-plane` |
| `location` | Region abbreviation | `use`, `usw2`, `use2` |
| `workload` | The static `workload` property value | `avd` |
| `environment` | The static `environment` property value | `prod`, `dev` |
| `freeform1` | The static `freeform1` property value | `contoso`, `team-a` |
| `freeform2` | The static `freeform2` property value | anything |
| `none` | Placeholder that is always removed — use to hold a slot in the Portal UI without including it in the output | — |

### Minimum required segments

A valid `components` array must include at least:

- **`resourceType`** — required. Without it, resources of different types produce identical names.
- **`purpose`** — strongly recommended. Without it, multiple resources of the same type in the same deployment collide.

A warning is shown in the Portal UI if `workload` or `location` are omitted, because those are the most common differentiators between environments and regions.

### RT-first vs RT-last

The position of `resourceType` in the array controls the naming style for **all** resources:

| Style | Example | When to use |
|-------|---------|-------------|
| **RT-first** (prefix) | `vm-avd-prod-use` | CAF default; most Azure portal views sort by type |
| **RT-last** (suffix) | `avd-prod-use-vm` | Some organisations prefer alphabetic sorting by workload |

RT-last is detected when `resourceType` is the **last non-`none` segment** in the array. Any other position (first, middle) is treated as RT-first.

> **Important for add-ons:** The Session Host Replacer, Session Hosts, and Storage Quota Manager add-ons infer RT-first/RT-last from the existing host pool name. They detect RT-last by checking whether the host pool name ends with `-vdpool` or `-hp`. They will default to RT-first for any other pattern.

---

## The `purpose` component

The `purpose` segment is the most powerful part of the naming system. It is the value that makes each resource in a deployment **unique** while keeping the rest of the name segments static.

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
| Key Vault (Secrets) | `sec` |
| Key Vault (Encryption) | `enc` |
| KV unique suffix | 6-char `uniqueString()` appended after assembly |
| Availability Set | `{identifier}-##` |
| Disk Encryption Set | `{identifier}-customer-keys` / `{identifier}-platform-and-customer-keys` |
| RSV (VMs) | `{identifier}` |
| RSV (Files) | `files` |
| Log Analytics WS | *(empty)* |
| DCE | *(empty)* |
| UAI | `{identifier}-{role}` |

### The `identifier` variable

`identifier` is derived from the `hostPoolIdentifier` (hostpool deployment) or equivalent parameter. It is the stable "name" for this host pool or resource group that makes it distinct from others in the same subscription. For example, with `hostPoolIdentifier = 'desktop'` and `index = 1`, `identifier = desktop-01`.

---

## Special resource-type constraints

Some Azure resource types impose naming constraints that override the standard segment assembly:

### Key Vault — 24-character limit

Key Vault names are capped at **24 characters**. The engine uses a two-step approach to balance uniqueness with name length:

1. Assembles the base name from the convention (e.g., `kv-avd-sec-use`).
2. **If the base name is ≤ 20 characters:** appends a 6-character `uniqueString()` suffix separated by `-` (e.g., `kv-avd-sec-use-a3b4c5`), then truncates to 24 characters with `take(name, 24)` — guaranteeing at least 3 unique characters.
3. **If the base name is 21–24 characters:** uses the base name as-is (no suffix) to avoid truncating to fewer than 3 meaningful unique characters. A portal warning is shown.
4. **If the base name is > 24 characters:** the base is still truncated to 24 characters, and a portal error blocks deployment.

The `uniqueString()` seed is:

- With a `location` segment: `uniqueString(subscriptionId, resourceGroupName)`
- Without a `location` segment: `uniqueString(subscriptionId, resourceGroupName, region)` — the region is added to prevent cross-region collisions when location is not in the name.

> **Parity guarantee:** The hostpool deployment's inline Key Vault names use the **same seed** as the standalone `keyVaults.bicep` deployment when the `identifier` is `operations`. Deploy `keyVaults.bicep` first, then reference its outputs — or re-run the hostpool deployment and it will find the existing vaults by name.

### Storage Account — alphanumeric only, max 24

Storage account names (FSLogix, Function App backing store) must be lowercase alphanumeric with no hyphens or special characters. The engine strips all separators with `stripSeps()` after assembling the name.

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

To produce a **consistent naming convention** across all solutions, pass the **same `customNamingConvention` object** to every deployment. The segments, delimiter, and static values must be identical.

### Alignment matrix

| Solution | Parameter name | Notes |
|----------|---------------|-------|
| `hostpools/hostpool.bicep` | `customNamingConvention` | Full object |
| `keyVaults/keyVaults.bicep` | `customNamingConvention` | Use `identifier = 'operations'` |
| `imageManagement/imageManagement.bicep` | `customNamingConvention` | Use `identifier = 'image-management'` |
| `imageBuild/imageBuild.bicep` | `customNamingConvention` | Shared gallery/identity names only |
| Add-ons (SHR, SH, SQM) | *(none — auto-inferred)* | Names inferred from HP name; override per-resource if needed |

### Shared parameter file pattern

The recommended approach is to define the naming convention once in a shared parameter fragment and reference it in each deployment:

**`customer/parameters/shared-naming.json`** (create this file):

```json
{
  "customNamingConvention": {
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

If your convention omits `location`, set **both** `vmsLocationAbbreviation` and `cpLocationAbbreviation` in `customNamingConvention` to ensure the uniqueString seed for Key Vaults remains stable across regions.

---

## Add-on naming — brownfield inference

The three add-ons (Session Host Replacer, Session Hosts, Storage Quota Manager) are deployed **after** the host pool exists. They do not accept a `customNamingConvention` parameter; instead they infer the naming convention from the existing host pool name:

### Convention detection

The add-on reads the host pool resource name and checks:

1. **Ends with `-vdpool`** (e.g., `avd-prod-use-vdpool`) → RT-last convention.
2. **Ends with `-hp`** (e.g., `avd-prod-use-hp`) → RT-last convention.
3. **Any other pattern** (e.g., `vdpool-avd-prod-use`) → RT-first convention (default).

### Base name extraction

Once the convention direction is known:

| Direction | HP name example | Base name |
|-----------|----------------|-----------|
| RT-first | `vdpool-avd-prod-use` | `avd-prod` (drop first + last segment) |
| RT-last | `avd-prod-use-vdpool` | `avd-prod` (drop last two segments) |

### Derived add-on resource names

Using the extracted base name and location abbreviation, each add-on generates:

| Resource | RT-first example | RT-last example |
|----------|-----------------|-----------------|
| Function App | `fa-{base}-shr-{unique}-{loc}` | `{base}-shr-{unique}-{loc}-fa` |
| Storage Account | base+token+loc, hyphens stripped, lowercase | same logic |
| Encryption UAI | `uai-{base}-shr{unique}-encryption-{loc}` | `{base}-shr{unique}-encryption-{loc}-uai` |
| VM naming pattern | `vm-SHNAME` | `SHNAME-vm` |
| OS Disk pattern | `osdisk-SHNAME` | `SHNAME-osdisk` |
| NIC pattern | `nic-SHNAME` | `SHNAME-nic` |

### Custom overrides

When the inferred names are wrong (non-standard HP name, or deliberately different), each add-on exposes direct override parameters:

| Add-on | Override parameters |
|--------|-------------------|
| Session Host Replacer | `functionAppNameOverride`, `storageAccountNameOverride`, `storageEncryptionIdentityNameOverride`, `applicationInsightsNameOverride`, `virtualMachineNameConvOverride`, `diskNameConvOverride`, `networkInterfaceNameConvOverride`, `availabilitySetNameConvOverride` |
| Session Hosts | `virtualMachineNameConv`, `osDiskNameConv`, `networkInterfaceNameConv`, `availabilitySetNameConv` |
| Storage Quota Manager | `functionAppNameOverride`, `storageAccountNameOverride`, `storageEncryptionIdentityNameOverride` |

The add-on Portal UIs show a **live preview** of the inferred names in the *Advanced* step before you enable custom overrides, so you can verify correctness before proceeding.

---

## Examples

### Example 1 — CAF default (no customNamingConvention)

Do nothing. Deploy using the Portal or parameter files without setting `customNamingConvention`. Resources are named:

```
vdpool-avd-use
rg-avd-control-plane-use
kv-avd-sec-use-{unique}
vm-SHNAME  →  vm-avdhost001
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

Results (identifier = `desktop-01`, region = `eastus`):

```
vdpool-avd-desktop-01-use
rg-avd-desktop-01-hosts-use
kv-avd-sec-use-{unique}
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
avd-sec-use2-kv-{unique}
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
contoso-avd-sec-use-kv
SHNAME-vm  →  avdhost001-vm
```

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
kv_avd_prod_sec_usw2_{unique}
vm-SHNAME  (VM/disk/NIC always use hyphens in the SHNAME pattern)
```

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
vault-avd-sec-use-{unique}    ← instead of kv-avd-sec-use-{unique}
vdpool-avd-use                ← other types unchanged
```

---

## Scenario test results

See **[naming-convention-test-results.md](naming-convention-test-results.md)** for a full matrix of 8 scenarios run against the naming engine simulation. All scenarios pass KV name parity between the hostpool inline deployment and the standalone `keyVaults.bicep` deployment.

The 8 scenarios cover:

| # | Scenario |
|---|---------|
| 1 | CAF default, single region |
| 2 | CAF default, split CP / VMs regions |
| 3 | Custom RT-first, 4 segments, workload + environment |
| 4 | Custom RT-last, 4 segments |
| 5 | Custom with org prefix in `freeform1`, RT-last |
| 6 | Custom with `environment` segment, underscore delimiter |
| 7 | Custom with no `location` segment (tests KV seed fallback) |
| 8 | Custom with RT in mid-position (not first, not last) |

---

*Last updated: 2026-06-16*
