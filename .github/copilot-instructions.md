# GitHub Copilot Instructions — FederalAVD

This file gives GitHub Copilot context about the FederalAVD repo so it can give you accurate,
repo-aware answers in VS Code, github.com chat, and any other Copilot surface.

---

## What This Repo Does

FederalAVD provides enterprise-grade Azure Virtual Desktop (AVD) deployment automation for
**Azure Commercial, Azure Government, Azure Government Secret, and Azure Government Top Secret**
clouds. It handles the full lifecycle: networking → prerequisites → image management →
custom image builds → host pool deployment → ongoing image refresh.

---

## Deployment Sequence

The components must be deployed in this order on first deployment:

```text
Step 0 (optional): Networking      — VNet, subnets, NSGs, route tables, private DNS zones
Step 1 (optional): AVD Shared Services — Key Vaults (required before Image Management CMK and for
                                     automated host-pool credentials; optional shared resources for
                                     standard host pools) and/or a Log Analytics Workspace
                                     (optional, for diagnostic settings on Key Vaults, Image
                                     Management storage accounts, and host pool monitoring)
Step 2 (optional): Image Management — Storage account, compute gallery, managed identity for artifacts
Step 3 (optional): Image Build      — Azure Image Builder job that produces a custom image version
Step 4 (required): Host Pool        — AVD host pool, session hosts, FSLogix storage, monitoring
```

Steps 0-3 are optional depending on your scenario:

- **Standard host-pool PoC / marketplace images**: Skip to Step 4 only. A VNet and subnet are the only hard prerequisites.
- **Multiple standard host pools**: The first Step 4 deployment can create shared Key Vaults,
  monitoring, and the FSLogix backup vault/policy; later Step 4 deployments can select those
  existing resources. Step 1 is optional unless another component needs them first.
- **Automated host-pool PoC**: Steps 1 → 4. Deploy the Shared Services secrets Key Vault first and pass `secretsKeyVaultResourceId` to the automated host pool's required `credentialsKeyVaultResourceId` parameter.
- **Custom software, no CMK**: Steps 2 → (3 optional) → 4
- **Runtime artifacts + CMK**: Steps 1 → 2 → 4
- **Custom image + CMK**: Steps 1 → 2 → 3 → 4
- **Shared FSLogix profile storage**: Deploy the FSLogix Storage add-on before consuming host pools.
  If CMK, diagnostics, or Azure Files backup are selected, supply existing Key Vault, Log Analytics,
  and backup vault/policy resources; deploy Step 1 first only when those resources do not yet exist.
- **Centralized diagnostics/monitoring**: Deploy Step 1 with `deployMonitoring: true`
  first, then pass its output resource ID as `logAnalyticsWorkspaceResourceId` (Image Management)
  and `existingLogAnalyticsWorkspaceResourceId` (Host Pool) so every step shares one workspace.
- **Policy-governed subscriptions (FedRAMP High, DoD IL4/IL5, CMMC)**: Check whether Azure Policy
  initiatives with `DeployIfNotExists` diagnostic-settings policies are assigned before Step 2/4 —
  these need a target Log Analytics Workspace to exist first. Treat Step 1 (`deployMonitoring: true`)
  as a compliance prerequisite, not just a CMK prerequisite. See `docs/compliance.md`.
- **Full production with automation**: All steps + CI/CD. See `docs/automation-guide.md`.

---

## Key Concepts

### customer/ folder

All customer-specific content lives in `customer/`. This folder is excluded from git tracking so
repo updates never overwrite your files.

```text
customer/
  parameters/         ← your parameter files (one per deployment, per environment)
    hostpools/
    imageBuild/
    imageManagement/
    sharedServices/
    networking/
  artifacts/          ← your custom software packages (scripts, installers, configs)
```

Start from the example files in `customer-examples/` — copy them into `customer/parameters/` or
`customer/artifacts/` and customize. Do not edit examples directly.

### Artifact Packages

Artifacts are folders of scripts and binaries placed in `customer/artifacts/`. During an image
build, artifacts are downloaded from Azure Blob Storage to the image VM and executed.

Each artifact folder typically contains:

- An `Install-*.ps1` (or similar) script that performs the installation
- The installer binary or configuration file(s)

See `docs/artifacts-guide.md` for packaging rules and `customer-examples/artifacts/` for 20+
ready-to-use example packages.

### downloads.json

`customer/parameters/imageManagement/downloads.json` is an optional file that tells
`Update-ImageArtifacts.ps1` what software to download automatically before uploading to blob
storage. Supported download methods:

| Field | Description |
| --- | --- |
| `DownloadUrl` | Direct URL to a file |
| `GitHubRelease` | Latest release from a GitHub repo |
| `WingetId` | Microsoft Store / winget package ID |

When `WingetId` is used with `"WingetPreserveLayout": true`, the folder structure produced by
`winget download` is preserved. This is required for MSIX / UWP provisioning.

### Image Lifecycle (Ongoing Refresh)

After initial deployment, the repeating update cycle is:

1. Run `Update-ImageArtifacts.ps1` to pull new software versions → upload to blob storage
2. Trigger a new Image Build (Step 3) to bake the updated artifacts into a new image version
3. The **Session Host Replacer** add-on (`deployments/add-ons/sessionHostReplacer/`) detects the
   new gallery image version, drains existing session hosts, and replaces them automatically.

The host pool itself is NOT redeployed on image updates — only session hosts are replaced.
For manual drain-and-replace, use `deployments/TagAndDrainSessionHosts.ps1`.

---

## Folder Map

```text
deployments/
  hostpools/          ← host pool Bicep template + parameters
  imageBuild/         ← image build Bicep template + parameters
  imageManagement/    ← image management Bicep template + parameters
  sharedServices/     ← Key Vaults, monitoring, and shared FSLogix backup Bicep template
  networking/         ← networking Bicep template + parameters
  add-ons/            ← optional lifecycle automation (sessionHostReplacer, storageQuotaManager, etc.)
  Update-ImageArtifacts.ps1   ← downloads and uploads software artifacts to blob storage
  Invoke-ImageBuilds.ps1      ← triggers image build runs
  TagAndDrainSessionHosts.ps1 ← manually drains session hosts before replacement
customer/
  parameters/         ← your parameter files (git-ignored)
  artifacts/          ← your artifact packages (git-ignored)
customer-examples/
  artifacts/          ← reference artifact packages; copy to customer/artifacts/ before use
  parameters/         ← reference parameter files; copy to customer/parameters/ before use
docs/                 ← all documentation
deployments/shared/modules/orchestration/sessionHostPolicy/ ← Canonical session-host policy definitions, initiatives, assignments, and nested templates
tools/                ← utility scripts
```

---

## Common Tasks — Where to Look

| Task | Where to start |
| --- | --- |
| First deployment | `docs/quick-start.md` |
| Understanding the architecture | `docs/design.md` |
| Deploying a host pool | `docs/hostpool-deployment.md` |
| Building a custom image | `docs/image-build.md` |
| Adding software to an image | `docs/artifacts-guide.md` → `docs/update-image-artifacts.md` |
| Automating recurring image updates | `docs/automation-guide.md` |
| Compliance control mapping | `docs/compliance.md` |
| Air-gapped (Secret/Top Secret) deployment | `docs/air-gapped-clouds.md` |
| Troubleshooting errors | `docs/troubleshooting.md` |
| Parameter reference | `docs/parameters.md` |
| FSLogix with Entra ID (cloud-only) | `docs/entra-kerberos-cloud-only.md` |
| FSLogix with Entra ID (hybrid) | `docs/entra-kerberos-hybrid.md` |
| Custom RBAC roles | `docs/custom-roles.md` |
| Session Host Replacer (auto-drain/replace) | `docs/session-host-replacer.md` |
| BCDR / DR strategy | `docs/bcdr.md` |

---

## Deployment Methods

All templates support three deployment methods:

- **Blue Button (Azure Portal)** — Portal UI with guided form. Available for Azure Commercial and
  Government only. Not available in air-gapped clouds.
- **Template Specs** — Publish the Bicep template as an Azure Template Spec, then deploy from the
  Portal with a guided form. Works in all clouds including air-gapped. Recommended for generating
  parameter files for automation workflows.
- **PowerShell / Azure CLI** — Script-driven deployment using parameter files. Works in all clouds.

> For air-gapped (Secret/Top Secret) clouds, Blue Button is not available. Use Template Specs or
> PowerShell. See `docs/air-gapped-clouds.md`.

---

## Security Defaults

The solution is Zero Trust-aligned by default. Key security defaults:

- Private endpoints for Storage, Key Vault, and other PaaS services
- Customer-managed encryption keys (CMK) via Azure Key Vault Premium (HSM)
- No public IP addresses on session hosts
- Managed identities for all Azure resource authentication (no stored credentials)
- TLS 1.2 minimum for all data in transit
- Microsoft Defender for Cloud integration

See `docs/features.md` and `docs/compliance.md` for the full control mapping.

---

## Compliance Frameworks Covered

NIST SP 800-53 Rev 5 / FedRAMP High, DoD SRG IL4/IL5, CMMC 2.0 Level 2/3, HIPAA, CJIS,
StateRAMP, IRS 1075, ISO 27001, OMB M-22-09 (federal Zero Trust), CISA ZTMM.

---

## Important Notes for Copilot

- **ASCII-only in ALL `.ps1` files — NO EXCEPTIONS.** Every character must be in the range
  U+0000–U+007F. This includes string literals, Write-Log messages, comments, .SYNOPSIS blocks,
  and section headers. ARM embeds scripts as JSON strings; non-ASCII bytes corrupt the payload
  and cause runtime parse errors. Before writing any `.ps1` content, replace:
  - Em dash / en dash (`—`, `–`) with ` - `
  - Right arrow (`→`) with `->`
  - Any box-drawing, check marks, bullets, smart quotes, or other non-ASCII with plain ASCII equivalents.
  After every edit to a `.ps1` file, verify with:
  `(Get-Content file.ps1) | Where-Object { $_ -match '[^\x00-\x7E]' }`

- **Do not modify files under `deployments/`** without understanding the full template — many
  parameters have cross-solution dependencies.
- **Prefer shared-module reuse when behavior is cross-solution.** If the same capability is
  implemented in multiple deployment entry points, prefer composing or extending
  `deployments/shared/modules/orchestration/*` and `deployments/shared/modules/resourceModules/*`
  instead of duplicating orchestration under a solution folder. Keep solution-local wrappers only
  for scope adapters, sequencing differences, or API-specific workflow constraints.
- **`customer/` content is git-ignored** by design. Don't suggest committing files from
  `customer/parameters/` or `customer/artifacts/` to this repo.
- **Example files in `customer-examples/`** are reference implementations — suggest copying them
  to `customer/` rather than editing them in place.
- **Bicep templates** are in `deployments/*/` alongside `.json` (ARM) equivalents. Both are kept
  in sync. Prefer editing `.bicep` source; the `.json` is generated.
- **Parameter files** use the ARM template parameter schema. Nested `value` objects are normal.
- **`downloads.json`** entries are merged at runtime: repo-provided base entries are overlaid with
  `customer/parameters/imageManagement/downloads.json`. Customer entries win on name collision.
- you have permission to download and read any references requuired to answer questions about this repo, including Microsoft Docs, GitHub repos, and other public sources.

## References for working with file types in this repo

- [Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview)
- [ARM templates](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/overview)
- [UI form definitions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/form-view-overview) and the schema for `uiFormDefinition.json`

## AVD Insights Workbooks (authoritative KQL source)

When writing or reviewing KQL alert queries for the AVD Alerts add-on, always validate against
the official Microsoft AVD Insights workbooks:

**GitHub source:** https://github.com/microsoft/Application-Insights-Workbooks/tree/master/Workbooks/Windows%20Virtual%20Desktop

Key workbooks and their raw URLs:

- **Connection Diagnostics:** https://raw.githubusercontent.com/microsoft/Application-Insights-Workbooks/master/Workbooks/Windows%20Virtual%20Desktop/Connection%20Diagnostics.workbook
- **Host Diagnostics:** https://raw.githubusercontent.com/microsoft/Application-Insights-Workbooks/master/Workbooks/Windows%20Virtual%20Desktop/Host%20Diagnostics.workbook
- **Connection Performance:** https://raw.githubusercontent.com/microsoft/Application-Insights-Workbooks/master/Workbooks/Windows%20Virtual%20Desktop/Connection%20Performance.workbook
- **Utilization Report:** https://raw.githubusercontent.com/microsoft/Application-Insights-Workbooks/master/Workbooks/Windows%20Virtual%20Desktop/Utilization%20Report.workbook
- **User Report:** https://raw.githubusercontent.com/microsoft/Application-Insights-Workbooks/master/Workbooks/Windows%20Virtual%20Desktop/User%20Report.workbook

Alert queries that cover the same condition as a workbook query should use the workbook as the
authoritative source. Deviations are intentional and documented in
`deployments/add-ons/avdAlerts/README.md` under "Query Design and Validation".

## Notes about UIFormDefinition files

- the default value you specify for Drop Downs must reference the label not the value.
- In `deployments/hostpools/uiFormDefinition.json`, avoid complex expression-valued
  `TextBlock.options.text` (especially nested `if(...)` with quoted string branches) for
  explanatory text. This exact pattern caused Azure Portal runtime failure in
  `CustomHtmlField` with `text is not a function`.
- Prefer literal `TextBlock.options.text` for explanatory copy. If text must vary by condition,
  use separate text blocks with visibility conditions instead of computing one dynamic text
  expression.
- After changing any text binding in UI form blocks, require a live portal render smoke test of
  the affected step; JSON parse/schema validation alone is not sufficient.