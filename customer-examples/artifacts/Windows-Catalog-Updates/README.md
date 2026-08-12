# Windows-Catalog-Updates

> **Before you start:** Copy this folder to `customer/artifacts/Windows-Catalog-Updates/` before running `Update-ImageArtifacts.ps1`. This artifact has no `downloads.json` entry — the patch files (`.msu`/`.cab`) must be manually staged in the folder (see [How to get the patches](#how-to-get-the-patches) below). See the [example artifacts README](../README.md) for the full workflow.

Installs Windows patches (`.msu` and `.cab`) downloaded from the
[Microsoft Update Catalog](https://www.catalog.update.microsoft.com/). The script is
fully self-contained — it requires no internet access during the image build and is designed
for air-gapped environments where WSUS is not available.

> **Tip:** If your image build environment has access to a WSUS server, prefer the native
> `updateService = 'WSUS'` parameter in the image build template instead of this artifact.
> See the [air-gapped clouds guide](../../../docs/air-gapped-clouds.md) for details.

## Folder contents

```text
Windows-Catalog-Updates/
    Install-WindowsCatalogUpdates.ps1   <- installer script (required)
    01-SSU-KB5012170-x64.msu            <- example: Servicing Stack Update
    02-CU-KB5040442-x64.msu             <- example: Cumulative Update
    SomeFeatureCAB.cab                  <- example: optional .cab package
```

The script installs every `.msu` and `.cab` file it finds alongside it. The patch files
**are not included** in this repo — you must supply them (see below).

## Installation order

Files are sorted **alphabetically by filename** before installation. Use a numeric prefix
to control order when prerequisites must be installed first:

| Filename | Installs as |
| --- | --- |
| `01-SSU-KB5012170-x64.msu` | First (Servicing Stack) |
| `02-CU-KB5040442-x64.msu` | Second (Cumulative Update) |
| `SomeFeatureUpdate.msu` | Third (no prefix — sorts after numeric-prefixed files) |

If installation order does not matter, no prefix is required.

## How to get the patches

### Option 1 — Microsoft Update Catalog (manual download)

#### Step 1: Find the current KB numbers

Use the **Windows release health** pages to identify the KB articles for the latest patches
before going to the Catalog:

- **Windows 11:** [https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)
- **Windows 10:** [https://learn.microsoft.com/en-us/windows/release-health/release-information](https://learn.microsoft.com/en-us/windows/release-health/release-information)
- **Windows Server:** [https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info](https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info)

On the release information page:

1. Find your OS version and build in the **Release history** table (e.g., Windows 11 24H2).

2. Read the **Update type** column to identify the right release. The format is
   `YYYY-MM <channel>`, where the channel letter means:

   | Channel | Meaning | Should you use it? |
   | --- | --- | --- |
   | `B` | Monthly Security Update — Patch Tuesday (2nd Tuesday) | **Yes — this is the standard monthly patch** |
   | `C` | Optional non-security preview (3rd Tuesday) | No — preview only, not yet fully tested |
   | `D` | Optional non-security preview (4th Tuesday) | No — preview only |
   | `OOB` | Out-of-band emergency fix | Only if it addresses a known critical issue you need |

   Pick the most recent row with channel `B` for your build. Note the KB number in that row
   (e.g., `2026-07 B` → `KB5058411`).

3. Click the KB number link to open the Microsoft Support article — the article will have a
   direct **Microsoft Update Catalog** download link at the bottom.

**Finding the Servicing Stack Update (SSU)**

The SSU updates the Windows Update engine itself and must be installed before the Cumulative
Update on older builds. For Windows 11 and Windows 10 21H2+, Microsoft ships a
**combined SSU+LCU** — the SSU is bundled inside the monthly CU and you do not need a
separate SSU file.

To check whether your build requires a separate SSU:

1. On the same release health page, scroll down to the **Servicing stack updates** section
   (below the quality updates table).
2. If a separate SSU is listed for your build with a date **after** your CU's release date,
   download it and prefix it `01-` so it installs first.
3. If no separate SSU is listed (common for Windows 11), the CU contains the SSU — download
   only the CU.

#### Step 2: Download from the Microsoft Update Catalog

1. Go to [https://www.catalog.update.microsoft.com/](https://www.catalog.update.microsoft.com/).
2. Enter the KB number you found above (e.g., `KB5058411`) in the search box.
3. In the results, find the row matching your OS version and architecture (e.g.,
   `Windows 11 Version 24H2 for x64-based Systems`).
4. Click **Download**, then click the `.msu` link in the popup.
5. Save the file and name it with a numeric prefix if installation order matters
   (e.g., `01-SSU-KB5012170-x64.msu`, `02-CU-KB5058411-x64.msu`).
6. Place the file(s) in this folder alongside `Install-WindowsCatalogUpdates.ps1`.

**Typical monthly patch sequence:**

| Order | Type | How to find KB |
| --- | --- | --- |
| 1 (if needed) | Servicing Stack Update (SSU) | "Servicing stack updates" section on the release health page — only required if listed separately for your build |
| 2 | Cumulative Update (CU) | Latest `B`-channel row in the release history table |
| 3 (optional) | .NET Framework CU | Search catalog for ".NET Framework" + your OS version |

> **Note:** Windows 11 and Windows 10 21H2+ ship a **combined SSU+LCU** — the servicing stack
> is bundled inside the monthly CU. Unless the release health page lists a separate SSU with a
> release date after the CU, you only need the CU.

### Option 2 — WSUS / SCCM / patch management export

If your organization manages patches via WSUS or SCCM, export the approved `.msu` or `.cab`
packages for your target OS and place them in this folder. The naming convention and numeric
prefix approach are the same.

### Option 3 — PowerShell / Windows Update module (semi-automated)

On a machine with internet access and the `PSWindowsUpdate` module installed:

```powershell
Install-Module -Name PSWindowsUpdate -Force
Get-WindowsUpdate -MicrosoftUpdate -Download -NotCategory 'Drivers' -AcceptAll
# Downloaded patches appear in C:\Windows\SoftwareDistribution\Download
```

Copy the relevant `.msu` files from the download cache to this folder.

## Uploading to blob storage

After placing patch files in the folder:

```powershell
# Connected environment
.\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"

# Air-gapped environment (skip downloading new sources)
.\Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId "<artifactsStorageAccountResourceId>" `
    -SkipDownloadingNewSources
```

There is no `downloads.json` entry for this artifact — patches must always be staged manually.

## What the script does

1. Scans `$PSScriptRoot` for `.msu` and `.cab` files, sorted alphabetically by name.
2. For each `.msu`: runs `wusa.exe "<file>" /quiet /norestart` and waits up to 10 minutes.
3. For each `.cab`: runs `dism.exe /Online /Add-Package /PackagePath:"<file>" /Quiet /NoRestart`
   and waits up to 10 minutes.
4. Skips files that are already installed (exit code `2359302` / `0x800F0805`) or not applicable
   (`2359303` / `0x800F081E`) — these are treated as success, not errors.
5. Reports a summary of any failures at the end.

## Exit codes handled

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `3010` | Success — reboot required |
| `2359302` | Already installed — skipped |
| `2359303` | Not applicable to this OS/architecture — skipped |
| Other | Warning logged; counted as a failure in the summary |

Log file: `C:\Windows\Logs\Install-WindowsCatalogUpdates-<timestamp>.log`

## Refresh cadence

Replace or add patch files each month as new Cumulative Updates are released, then re-upload
with `Update-ImageArtifacts.ps1`. The script always installs all files present in the folder
at build time — there is no version tracking. Already-installed patches are skipped cleanly
via exit code, so including superseded KBs is harmless but wastes build time.
