[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Design

This Azure Virtual Desktop (AVD) solution will deploy fully operational AVD hostpool(s) to an Azure subscription.

This page describes the Azure resource topology. See [Secure Endpoint Architecture](secure-endpoint-architecture.md)
for the control-layer, shared-responsibility, lifecycle, evidence, and AI access model implemented
through that topology.

## Shared module contracts

Shared Bicep files under `deployments/shared/modules/` describe their purpose with
`metadata name` and `metadata description`. Parameter and output descriptions
document their input requirements, resource ownership, collection shapes, and
returned values. These descriptions are also emitted into compiled ARM templates.
A parameter without a default remains a required Bicep input even when its
associated feature is optional; pass an empty value only when its description
allows it. Descriptions do not replace type constraints or deployment validation.

- **Resource modules** deploy or update a resource and its closely related children.
  Their descriptions identify existing parent resources and other caller-owned
  dependencies. A resource-group-scoped module does not create its deployment
  resource group unless explicitly documented.
- **Orchestration modules** compose resources, cross-scope deployments, role
  assignments, and sequencing for a capability. Read their input contracts before
  invoking lower-level resource modules directly.
- **Type and function libraries** provide shared contracts or helpers rather than
  independently deploying a capability.

For capability-level composition, start with the orchestration entry points:

| Capability | Shared entry point |
| --- | --- |
| Workspace and application-group composition | [AVD workspace](../deployments/shared/modules/orchestration/avdWorkspace/avdWorkspace.bicep) |
| Customer-managed encryption dependencies | [Customer-managed keys](../deployments/shared/modules/orchestration/customerManagedKeys/customerManagedKeys.bicep) |
| Profile storage | [FSLogix](../deployments/shared/modules/orchestration/fslogix/fslogix.bicep) |
| Credentials and encryption vaults | [Key Vaults](../deployments/shared/modules/orchestration/keyVaults/keyVaults.bicep) |
| Host monitoring resources | [Monitoring](../deployments/shared/modules/orchestration/monitoring/monitoring.bicep) |
| Session host deployment | [Session hosts](../deployments/shared/modules/orchestration/sessionHosts/sessionHosts.bicep) |
| Session host policy internals | [Policy authoring contract](../deployments/shared/modules/orchestration/sessionHostPolicy/AUTHORING.md) |

Use the [shared naming contract](../deployments/shared/modules/orchestration/naming/README.md)
for generated names and the
[Function App composition contract](../deployments/shared/modules/resourceModules/functionApp/README.md)
for plan ownership, app infrastructure, and function-code deployment.

When adding a shared module, include its purpose, deployment scope, important
prerequisites, and descriptions for every parameter and output. Preserve these
contracts when changing a module. Prefer detailed explanations, examples, and
sequencing guidance in Bicep source comments, which are not transpiled into ARM.
Keep emitted module metadata and parameter/output descriptions concise while
retaining the information needed to use the interface correctly. Run
`Invoke-Pester -Script tests\ModuleMetadata.Tests.ps1` to compile all shared modules
and check their emitted metadata; Azure CLI and Bicep must already be installed.
No Azure sign-in or deployment is required. Rebuild affected tracked ARM templates
after changing descriptions, including nested templates embedded by policy modules.

### Generated-template size budgets

Check size after changing shared modules: their content can appear in multiple
nested deployments in the transpiled ARM. Microsoft documents an
[ARM template limit of 4 MB](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/best-practices#template-limits)
and a separate [Template Spec content limit of approximately 2 MB](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/template-specs).
The Template Spec budget must include the main template, attached Portal form,
any packaged linked templates, and publishing metadata/envelope.

`tools/New-TemplateSpecs.ps1` keeps the full documentation in Bicep source and
tracked ARM files. Only the temporary publication copy omits nested-template
parameter/output/type descriptions and Bicep compiler provenance. It retains
top-level interface descriptions (including linked-template entry points),
module names and summaries, other interface metadata and validation constraints,
resource/policy metadata, and the entire Portal form. Developers and Copilot
should use the repository sources to understand and reuse module contracts, not
reconstruct them from a published Template Spec.

The publisher uses the normal Az.Resources packaging engine to stage the filtered
copy, including linked artifacts, and still publishes with `New-AzTemplateSpec`.
It does not depend on input minification or change SDK serialization settings.
Before any resource creation or publication, every selected package is measured
using the installed Az.Resources SDK's normal version-request serializer, including
the main template, linked artifacts, Portal form, and location envelope. A
16,384-byte (16 KiB) safety margin reserves room for additional publishing metadata;
it is not data appended to the template. Output separates the measured request,
reserved margin, total checked, and remaining headroom against the 2,000,000-byte
budget. Staging files are removed on success or failure.

Run `Invoke-Pester -Script tests\TemplateSpecs.Tests.ps1,tests\HostPoolOrchestratorSize.Tests.ps1`
after changes affecting publication. These offline checks require Az.Resources,
cover all current template/form pairs, enforce the publication budget and a
4,000,000-byte tracked ARM file budget, and verify annotation filtering preserves
deployment content. They do not require Azure sign-in and do not prove service
acceptance. ARM also applies expanded-template and per-resource limits that raw
file measurements cannot prove.

### Experimental deduplicated Template Spec publisher

#### Why packaging happens after Bicep compilation

Bicep remains the source of truth for deployment resources, module contracts and
dependencies. Its normal compiler output embeds modules as nested ARM templates;
there is no documented build option that emits those modules as separate files
with `templateLink.relativePath` references for a single Template Spec package.
Referencing separately published Template Specs from Bicep is a different model:
it introduces independently published resources and version dependencies rather
than bundling child templates into one version.

For this approach, keep the existing Bicep module structure and compiler-generated
ARM files. Treat extraction and deduplication as a publication-only transformation
of an in-memory copy, not as a second hand-maintained ARM implementation. Do not
hand-edit tracked ARM output or duplicate Bicep deployment logic to reduce package
size. The generated package must preserve deployment behavior, including parameter
passing, outputs, dependencies, conditions, loops, scope and relative-link origin.

Microsoft documents the linked-template packaging mechanism, but the automatic
extraction, SHA-256 naming and deduplication algorithm are FederalAVD-specific.
The authoritative references are:

- [Bicep modules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/modules):
  normal compilation produces a single ARM template with nested templates.
- [Create a template spec with linked templates](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/template-specs-create-linked):
  `templateLink.relativePath` is relative to the template declaring the link.
  A root template references `artifacts/<hash>.json`; a linked artifact in that
  directory references its sibling as `<hash>.json`.
- [Template Spec version resource schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.resources/2021-05-01/templatespecs/versions):
  a version contains `mainTemplate`, `linkedTemplates` entries with `path` and
  `template`, and an optional `uiFormDefinition`.

#### Implementation and validation

`tools/New-TemplateSpecs-Deduplicated.ps1` is an opt-in testing copy; the standard
publisher above remains unchanged. It preserves the same deployment selections and
naming defaults and adds `-TemplateSpecNameSuffix` for isolated test names and
`-WhatIf` for preflight without Azure writes. Without a suffix it targets the same
names as the standard publisher. Version incrementing remains enabled by default;
disabling it overwrites version `1.0.0`.
The experimental publisher retrieves existing versions by omitting `-Version`
from `Get-AzTemplateSpec`, reads each version's `Name` from the returned
`.Versions` collection, and increments the largest numeric major version.
`-Version '*'` is not a supported version-listing operation. Non-numeric version
names and version-read failures stop publication rather than silently selecting
`1.0.0`.

The experimental path filters the same publication-only annotations, identifies
byte-identical JSON bodies with SHA-256, and extracts only static deployment
templates with explicitly declared inner expression scope. It traverses both
symbolic resource objects and resource arrays, including nested deployments, but
does not rewrite templates carried as variable/default/output data for later
runtime use. Unique inner-scope ancestors of extracted duplicates are also linked
artifacts: a relative link must be declared directly in the main template or a
linked artifact, never beneath an inline deployment boundary. Otherwise ARM loses
the template origin and deployment fails with `InvalidTemplateSpec`, even when
started from the Portal using the Template Spec version.

Outer/default-scope templates and their complete descendant subtrees remain
inline, because extracting those ancestors would change expression scope.
Pre-existing relative
template links are rejected explicitly; the current tracked inputs are
self-contained. Existing URI/Template Spec ID links remain unchanged.

Generated linked artifacts are stored once inside the same Template Spec version,
not on a public URL. The complete request includes the main template, every linked
artifact and the unmodified Portal form. It is serialized with the normal SDK
settings, checked against the same budget and reserve, then submitted using the
documented Template Spec REST API through `Invoke-AzRestMethod -Path`. This avoids
the native packager's failure to discover links in symbolic resource objects.
The active Azure context selects the management endpoint; no Commercial endpoint,
public artifact download or separate template-storage account is introduced.

For an isolated standard host-pool test, sign in to the intended cloud and run:

```powershell
$test = @{
    ResourceGroupName = 'rg-avd-template-tests'
    Location = '<region>'
    TemplateSpecNameSuffix = 'dedup-test'
    createHostPool = $true
    createCustomImage = $false
    CreateAddOns = $false
}
.\tools\New-TemplateSpecs-Deduplicated.ps1 @test -WhatIf
# After reviewing the context, names and complete-request size:
.\tools\New-TemplateSpecs-Deduplicated.ps1 @test
```

Run `Invoke-Pester -Script tests\DeduplicatedTemplateSpecs.Tests.ps1` for offline
artifact-resolution (including link-origin boundaries), restoration-equivalence
and request-budget tests. These do
not prove Azure service acceptance. Test publication, Portal rendering and actual
deployments (including cross-scope, optional-feature and CMK paths) before adopting
the experimental publisher. Confirm API and linked-artifact availability in the
target Secret/Top Secret enclave; do not substitute public hosting if unavailable.

After updating the publisher, publish a new version and deploy that version by
Template Spec ID (or its Portal Deploy action). Existing published versions are
not repaired by updating the local script. Do not deploy the packaged main
template as local JSON; its relative links require the complete Template Spec.
See Microsoft's [linked Template Spec guidance](https://learn.microsoft.com/azure/azure-resource-manager/templates/template-specs-create-linked)
for relative-path resolution.

## Naming and resource topology

The deployment utilizes the Cloud Adoption Framework naming conventions and organizes resources and resource groups in accordance with several available parameters:

- Persona Identifier (***identifier***): This parameter is used to uniquely identify the persona of the host pool(s). Each persona, or each group of users with distinct business functions and technical requirements, would require a specific host-pool configuration and thus we use the persona term to identify the host pool. For more information about personas see [User Personas | AVD Cloud Adoption Framework](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/scenarios/azure-virtual-desktop/migrate-assess#user-personas).

- Host Pool Index (***index***): This *optional* parameter is used when we must shard the unique persona across multiple host pools. For more information, see [Sharding Pattern](https://docs.microsoft.com/en-us/azure/architecture/patterns/sharding).

- Naming Convention (`namingConvention`): An optional object parameter that controls how every resource in the deployment is named. The default value produces CAF-aligned names (`resourceType-avd-purpose-location`). The `purpose` component is a FederalAVD addition with no direct CAF equivalent — it disambiguates resources of the same type within a deployment. When customized, the engine assembles names from an ordered array of components (resourceType, purpose, location, workload, environment, freeform1, freeform2). See the **[Naming Convention guide](naming-convention.md)** for the full parameter schema, examples, and cross-solution alignment.

The diagram below highlights how the resource groups are created based on the parameters.

```mermaid
graph TB
    subgraph Tenant["Azure Tenant"]
        
        subgraph Region1["USGovVirginia<br/>"]
            direction TB
            MON1[Monitoring<br/>rg-avd-monitoring-va<br/>Log Analytics, DCR, DCE]
            OPS1[Operations<br/>rg-avd-operations-va<br/>Secrets KV, Encryption KV, Recovery Services Vault]
            CP1[Control Plane<br/>rg-avd-control-plane-va<br/>Workspace, App Groups, Host Pools]
            
            subgraph HP1["Host Pool 1 (Identifier: hr, Index: 01)"]
                direction LR
                HOSTS1[Hosts<br/>rg-hr-01-hosts-va<br/>VMs, Disk Encryption Set]
                STORAGE1[Storage<br/>rg-hr-01-storage-va<br/>Storage Accounts, NetApp, Encryption UAI]
            end
            
            subgraph HP2["Host Pool 2 (Identifier: hr, Index: 02)"]
                direction LR
                HOSTS2[Hosts<br/>rg-hr-02-hosts-va<br/>VMs, Disk Encryption Set]
                STORAGE2[Storage<br/>rg-hr-02-storage-va<br/>Storage Accounts, NetApp, Encryption UAI]
            end
            
            HP1 -.located in.-> CP1
            HP2 -.located in.-> CP1
            CP1 -.diagnostics.-> MON1
            HOSTS1 -.logs and performance data.-> MON1
            HOSTS2 -.logs and performance data.-> MON1
            OPS1 -.encryption keys.-> HOSTS1
            OPS1 -.encryption keys.-> HOSTS2
            OPS1 -.encryption keys.-> STORAGE1
            OPS1 -.encryption keys.-> STORAGE2
            STORAGE1 -.diagnostics.-> MON1
            STORAGE2 -.diagnostics.-> MON1
        end
        
        subgraph Region2["USGovTexas<br/>"]
            direction TB
            MON2[Monitoring<br/>rg-avd-monitoring-tx<br/>Log Analytics, DCR, DCE]
            OPS2[Operations<br/>rg-avd-operations-tx<br/>Secrets KV, Encryption KV, Recovery Services Vault]
            CP2[Control Plane<br/>rg-avd-control-plane-tx<br/>Workspace, App Groups, Host Pools]
            
            subgraph HP3["Host Pool 3 (Identifier: finance, Index: 01)"]
                direction LR
                HOSTS3[Hosts<br/>rg-finance-01-hosts-tx<br/>VMs, Disk Encryption Set]
                STORAGE3[Storage<br/>rg-finance-01-storage-tx<br/>Storage Accounts, NetApp, Encryption UAI]
            end
            
            HP3 -.located in.-> CP2
            CP2 -.diagnostics.-> MON2
            HOSTS3 -.logs and performance data.-> MON2
            OPS2 -.encryption keys.-> HOSTS3
            OPS2 -.encryption keys.-> STORAGE3
            STORAGE3 -.diagnostics.-> MON2
        end
    end
    
    %% Define styles for different resource group types
    classDef globalFeed fill:#4fc3f7,stroke:#0288d1,stroke-width:3px,color:#000
    classDef monitoring fill:#ffb74d,stroke:#f57c00,stroke-width:3px,color:#000
    classDef operations fill:#ba68c8,stroke:#7b1fa2,stroke-width:3px,color:#fff
    classDef controlPlane fill:#81c784,stroke:#388e3c,stroke-width:3px,color:#000
    classDef hosts fill:#e57373,stroke:#c62828,stroke-width:3px,color:#000
    classDef storage fill:#aed581,stroke:#689f38,stroke-width:3px,color:#000
    classDef hostPool fill:#64b5f6,stroke:#1976d2,stroke-width:3px,color:#000
    classDef region fill:#e0e0e0,stroke:#616161,stroke-width:3px,color:#000
    classDef tenant fill:#f5f5f5,stroke:#424242,stroke-width:4px,color:#000
    
    %% Apply styles to nodes
    class GF globalFeed
    class MON1,MON2 monitoring
    class OPS1,OPS2 operations
    class CP1,CP2 controlPlane
    class HOSTS1,HOSTS2,HOSTS3 hosts
    class STORAGE1,STORAGE2,STORAGE3 storage
    class HP1,HP2,HP3 hostPool
    class Region1,Region2 region
    class Tenant tenant
    
    %% Style connectors - make them darker and more visible
    linkStyle default stroke:#333,stroke-width:2px,color:#000
```

The diagram illustrates the following resource group distribution. In the table below, the example names are utilizing the following parameter values:

- **identifier**: 'hr'
- **index**: '01', '02'
- locationVirtualMachines (determined by **virtualMachineSubnetResourceId** location): 'USGovVirginia'
- **locationControlPlane**: 'USGovVirginia'
- **namingConvention**: *(default — CAF convention)*

| Purpose | Resources | Example Name | Notes |
| ------- | :-------: | ------------ | ----- |
| Global Feed | global feed workspace | rg-avd-global-feed | One per Tenant |
| Monitoring | Log Analytics Workspace<br>AVD Insights Data Collection Rule<br>Data Collection Endpoint | rg-avd-monitoring-va | One per region |
| Operations | Secrets Key Vault<br>Encryption Key Vault<br>Recovery Services Vault (Azure Files backup, pooled host pools) | rg-avd-operations-va | One per region. AVD Shared Services owns the shared FSLogix vault and Azure Files backup policy. Host pools and standalone FSLogix storage deployments register their own shares as protected items. Inline host-pool creation remains a compatibility fallback. VM backup vaults for personal host pools remain per-host-pool resources in the Hosts resource group. |
| Control Plane | feed workspace<br>application groups<br>hostpools<br>scaling plans | rg-avd-control-plane-va | One per region |
| Hosts | virtual machines<br>disk encryption set<br>Recovery Services Vault (VM backup, personal host pools only) | rg-hr-01-hosts-va<br>rg-hr-02-hosts-va | One per identifier or per index (if specified). Disk Encryption Set is created here when CMK is used for VM disks. Recovery Services Vault for VM backup is deployed here when `recoveryServices = true` on a personal host pool — one vault per host pool, not shared. |
| Storage | NetApp Storage Accounts<br>Storage Account(s)<br>function app<br>storage encryption UAI | rg-hr-01-storage-va<br>rg-hr-02-storage-va | One per identifier or per index (if specified). Storage encryption User-Assigned Identity is created here when CMK is used for FSLogix storage. |

Standard and automated production host pools use the same regional Control Plane resource group
for all personas that share the control-plane subscription and naming convention. The persona
identifier distinguishes host pools, application groups, and scaling plans inside that group; it
does not appear in the group's purpose component. The dedicated PoC is the exception: its
resources remain in one persona-specific consolidated resource group.

When `existingFeedWorkspaceResourceId` is supplied, its resource group takes precedence over
the generated regional name. Both production deployments reuse that group without creating or
retagging it. Its subscription must match the target control-plane subscription: for standard
host pools, set `controlPlaneSubscriptionId` when it differs from the deployment subscription;
automated host pools use the deployment subscription. Keep the selected control-plane region
consistent with the workspace region.

> **Existing deployments using per-persona Control Plane resource groups:** Correcting the naming
> does not relocate existing resources. Plan migration before redeploying those pools with the
> corrected templates; a different resource group produces different resource IDs and can create
> a second pool instead of updating the existing one.

Because the Monitoring and Operations resource groups are shared across all host pools in a region, costs for Log Analytics, Recovery Services Vaults, and Key Vaults cannot be attributed per host pool through Azure Cost Management alone. See [Chargeback for Shared Resources](chargeback-shared-resources.md) for query-based approaches that use the `cm-resource-parent` tags stamped on keys, protected items, and VMs.

The code is idempotent, allowing you to scale storage and sessions hosts, but the core management resources will persist and update for any subsequent deployments. Some of those resources are the host pool, application group, and log analytics workspace.

Both a personal or pooled host pool can be deployed with this solution. Either option will deploy a desktop application group with a role assignment. You can also deploy the required resources and configurations to fully enable FSLogix. This solution also automates many of the [features](features.md) that are usually enabled manually after deploying an AVD host pool.

## Naming Convention Internals

> **Audience:** contributors extending or debugging the naming logic. Operators deploying the template only need the parameter descriptions and the table above. For the full naming reference, see [Naming Convention](naming-convention.md).

All resource names are assembled from an ordered array of **components** — named slots that the engine fills with resource-type abbreviations, location abbreviations, static labels, and per-resource differentiators. The active convention is controlled by the `namingConvention` parameter object.

### Key concepts

| Concept | Description |
| --- | --- |
| components array | Ordered list of component names (esourceType\, `purpose`, \location\, \workload\, \nvironment\, \reeform1\, \reeform2\, one\) |
| purpose | Per-resource differentiator (e.g., \vd-01\, \sec\, \control-plane\) — set automatically by the engine for each resource; no direct CAF equivalent |
| RT-first | esourceType\ is the first non-one\ component — produces \dpool-avd-use\ style names |
| RT-last | esourceType\ is the last non-one\ component — produces \vd-use-vdpool\ style names |

### CAF-aligned default

The default `namingConvention` value produces names following `{resourceType}-avd-{purpose}-{location}` via the same `cnv()` user-defined function used for all resources. This is CAF-aligned but not a strict CAF implementation: CAF does not define a `purpose` component.

### Custom naming path

The `cnv()` user-defined function maps each component name to its value, filters out empty values, and joins with the configured delimiter. The same function is called for every resource, with only the `purpose` argument varying per resource.

### Add-on convention inference

The three add-ons (Session Host Replacer, Session Hosts, Storage Quota Manager) infer the naming convention from the existing host pool name. They detect RT-last when the host pool name ends with -vdpool or -hp, and default to RT-first otherwise.

### Implementation location

The host-pool naming engine lives in [deployments/shared/modules/orchestration/naming/hostPool.bicep](../deployments/shared/modules/orchestration/naming/hostPool.bicep) and is shared by standard host pools, automated host pools, and standalone FSLogix storage. AVD Shared Services and Image Management use the same convention shape in their solution-specific naming logic.
