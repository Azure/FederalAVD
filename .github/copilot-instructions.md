# GitHub Copilot Instructions — FederalAVD

This file gives GitHub Copilot context about the FederalAVD repo so it can give you accurate,
repo-aware answers in VS Code, github.com chat, and any other Copilot surface.

---

## What This Repo Does

FederalAVD provides enterprise-grade Azure Virtual Desktop (AVD) deployment automation for
**Azure Commercial, Azure Government, Azure Government Secret, and Azure Government Top Secret**
clouds. It handles the full lifecycle: networking → security prerequisites → image management →
custom image builds → host pool deployment → ongoing image refresh.

---

## Deployment Sequence

The components must be deployed in this order on first deployment:

```
Step 0 (optional): Networking      — VNet, subnets, NSGs, route tables, private DNS zones
Step 1 (optional): Key Vaults      — Required only when using Customer-Managed Keys (CMK) with custom images
Step 2 (optional): Image Management — Storage account, compute gallery, managed identity for artifacts
Step 3 (optional): Image Build      — Azure Image Builder job that produces a custom image version
Step 4 (required): Host Pool        — AVD host pool, session hosts, FSLogix storage, monitoring
```

Steps 0-3 are optional depending on your scenario:
- **PoC / marketplace images**: Skip to Step 4 only. A VNet and subnet are the only hard prerequisites.
- **Custom software, no CMK**: Steps 2 → (3 optional) → 4
- **Custom software + CMK**: Steps 1 → 2 → (3 optional) → 4
- **Full production with automation**: All steps + CI/CD. See `docs/automation-guide.md`.

---

## Key Concepts

### customer/ folder

All customer-specific content lives in `customer/`. This folder is excluded from git tracking so
repo updates never overwrite your files.

```
customer/
  parameters/         ← your parameter files (one per deployment, per environment)
    hostpools/
    imageBuild/
    imageManagement/
    keyVaults/
    networking/
  artifacts/          ← your custom software packages (scripts, installers, configs)
```

Start from the example files in `customer/examples/` — copy them into `customer/parameters/` or
`customer/artifacts/` and customize. Do not edit examples directly.

### Artifact Packages

Artifacts are folders of scripts and binaries placed in `customer/artifacts/`. During an image
build, artifacts are downloaded from Azure Blob Storage to the image VM and executed.

Each artifact folder typically contains:
- An `Install-*.ps1` (or similar) script that performs the installation
- The installer binary or configuration file(s)

See `docs/artifacts-guide.md` for packaging rules and `customer/examples/artifacts/` for 20+
ready-to-use example packages.

### downloads.json

`customer/parameters/imageManagement/downloads.json` is an optional file that tells
`Update-ImageArtifacts.ps1` what software to download automatically before uploading to blob
storage. Supported download methods:

| Field | Description |
|---|---|
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

```
deployments/
  hostpools/          ← host pool Bicep template + parameters
  imageBuild/         ← image build Bicep template + parameters
  imageManagement/    ← image management Bicep template + parameters
  keyVaults/          ← key vault Bicep template + parameters
  networking/         ← networking Bicep template + parameters
  add-ons/            ← optional lifecycle automation (sessionHostReplacer, storageQuotaManager, etc.)
  Update-ImageArtifacts.ps1   ← downloads and uploads software artifacts to blob storage
  Invoke-ImageBuilds.ps1      ← triggers image build runs
  TagAndDrainSessionHosts.ps1 ← manually drains session hosts before replacement
customer/
  examples/           ← reference implementations; copy to customer/ before use
  parameters/         ← your parameter files (git-ignored)
  artifacts/          ← your artifact packages (git-ignored)
docs/                 ← all documentation
policy/               ← Azure Policy definitions and assignments
tools/                ← utility scripts
```

---

## Common Tasks — Where to Look

| Task | Where to start |
|------|---------------|
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

- **Do not modify files under `deployments/`** without understanding the full template — many
  parameters have cross-solution dependencies.
- **`customer/` content is git-ignored** by design. Don't suggest committing files from
  `customer/parameters/` or `customer/artifacts/` to this repo.
- **Example files in `customer/examples/`** are reference implementations — suggest copying them
  to `customer/` rather than editing them in place.
- **Bicep templates** are in `deployments/*/` alongside `.json` (ARM) equivalents. Both are kept
  in sync. Prefer editing `.bicep` source; the `.json` is generated.
- **Parameter files** use the ARM template parameter schema. Nested `value` objects are normal.
- **`downloads.json`** entries are merged at runtime: repo-provided base entries are overlaid with
  `customer/parameters/imageManagement/downloads.json`. Customer entries win on name collision.
