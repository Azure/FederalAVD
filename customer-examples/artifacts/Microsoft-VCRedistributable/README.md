# Microsoft-VCRedistributable

> **Before you start:** Copy this folder to `customer/artifacts/Microsoft-VCRedistributable/` before running `Update-ImageArtifacts.ps1`. Add the `VCRedistributableX64` entry (and optionally `VCRedistributableX86`) from [`customer-examples/parameters/imageManagement/downloads.json`](../../../customer-examples/parameters/imageManagement/downloads.json) to your `customer/parameters/imageManagement/downloads.json`. See the [example artifacts README](../README.md) for the full workflow.

Installs the latest **Microsoft Visual C++ Redistributable (Visual Studio 2015–2022)** silently.
The aka.ms URLs always redirect to the current release, so no URL maintenance is required.

The x64 package is required on virtually every Windows image. The x86 package is only needed
if you deploy 32-bit applications that link against the VC++ runtime.

## Parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `Architecture` | `string` | `x64` | Which runtime(s) to install. Accepts `x64`, `x86`, or `Both`. |
| `SuccessExitCodes` | `int[]` | `0, 3010, 1638` | Exit codes treated as success. `1638` means a newer version is already installed and is skipped cleanly. |

## Folder contents

```plaintext
Microsoft-VCRedistributable/
    Install-MicrosoftVCRedistributable.ps1   <- installer script (required)
    vc_redist.x64.exe                        <- pre-staged x64 installer (optional; required for air-gapped)
    vc_redist.x86.exe                        <- pre-staged x86 installer (optional)
```

The installer files are optional for **connected** image builds — the script downloads them
automatically from Microsoft's aka.ms URLs if no matching file is found in the folder. For
**air-gapped** builds the EXE(s) must be pre-staged (see below).

## How to get the installer

### Option 1 — Update-ImageArtifacts.ps1 (recommended for connected environments)

Add the following entries to `customer/parameters/imageManagement/downloads.json`. The x86
entry is optional — include it only if your image requires 32-bit VC++ runtime support.

```json
"VCRedistributableX64": {
    "Description": "Microsoft Visual C++ Redistributable (latest) x64 installer.",
    "DownloadUrl": "https://aka.ms/vs/17/release/vc_redist.x64.exe",
    "DestinationFileName": "vc_redist.x64.exe",
    "DestinationFolders": [
        "Microsoft-VCRedistributable"
    ]
},
"VCRedistributableX86": {
    "Description": "Optional: Microsoft Visual C++ Redistributable (latest) x86 installer. Only needed for 32-bit application support.",
    "DownloadUrl": "https://aka.ms/vs/17/release/vc_redist.x86.exe",
    "DestinationFileName": "vc_redist.x86.exe",
    "DestinationFolders": [
        "Microsoft-VCRedistributable"
    ]
}
```

Then run:

```powershell
.\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
```

### Option 2 — Manual download (connected, no automation)

Download directly from the aka.ms permanent URLs (always the latest release):

```powershell
Invoke-WebRequest 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile 'vc_redist.x64.exe'
Invoke-WebRequest 'https://aka.ms/vs/17/release/vc_redist.x86.exe' -OutFile 'vc_redist.x86.exe'
```

Place the downloaded file(s) in this folder before uploading to blob storage.

### Option 3 — Air-gapped / manual pre-staging

1. On a machine with internet access, download the EXE(s) using the commands in Option 2.
2. Copy them into this folder alongside the install script.
3. Transfer the folder to the air-gapped network, then upload to blob storage:

   ```powershell
   .\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
   ```

   The script auto-detects the environment and selects the correct base downloads file. Add
   `-SkipDownloadingNewSources` only if network downloads are not reachable from your management
   system.

When a matching `vc_redist.<arch>.exe` file is present in the folder, the install script uses
it directly and skips the download entirely — no internet access is required during the image
build.

## What the script does

1. For each requested architecture (`x64`, `x86`, or both):
   a. Looks for a `vc_redist.<arch>.exe` file in `$PSScriptRoot`.
   b. If not found, downloads it from `https://aka.ms/vs/17/release/vc_redist.<arch>.exe`.
   c. Runs: `vc_redist.<arch>.exe /install /quiet /norestart`
   d. Waits up to 10 minutes for the installer to complete.
2. Reports a failure summary if any architecture fails.

## Exit codes handled

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `3010` | Success - reboot required |
| `1638` | A higher or equal version is already installed - skipped cleanly |
| Other | Installer error - review log |

Log file: `C:\Windows\Logs\Install-MicrosoftVCRedistributable-<timestamp>.log`

## Refresh cadence

Microsoft does **not** publish a version number or release schedule on the
[VC++ Redistributable download page](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170).
The `aka.ms` permalink always serves the current version, but there is no changelog or Patch
Tuesday cadence to watch.

The recommended approach is to re-download on every image build run rather than trying to
detect whether a new version is available:

- Re-run `Update-ImageArtifacts.ps1` (or repeat the manual download step) before each image
  build so the staged file is always the latest available from the permalink.
- Because `1638` is treated as a success exit code, the installer exits cleanly if the image
  already has a newer release — there is no harm in running it every time.

If you need to compare versions manually (e.g., to decide whether to trigger an unplanned
image build), right-click the downloaded `vc_redist.x64.exe`, choose **Properties > Details**,
and compare **File version** against the installed version shown in **Apps & Features** under
*Microsoft Visual C++ 2015-2026 Redistributable (x64)*.
