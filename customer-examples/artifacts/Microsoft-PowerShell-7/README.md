# Deploy PowerShell 7

This artifact deploys the official stable x64 PowerShell 7 ZIP for image builds or Azure Compute
Gallery VM Applications. Copy this folder to `customer/artifacts/Microsoft-PowerShell-7` before
packaging. There are no runtime downloads, Store dependencies, or per-user MSIX registration.

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Deploy-PowerShell7.ps1 -DeploymentType Install
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Deploy-PowerShell7.ps1 -DeploymentType Uninstall
```

Run under elevated **64-bit Windows PowerShell 5.1**, including Azure's SYSTEM execution context.
Do not invoke from `pwsh`: installation and removal replace PowerShell 7 itself. The Windows AppX
and DISM cmdlets must be available. Install is the default; exactly one root-level `.zip` is
required. The script expands and checks the complete payload, Microsoft signature, and stable
x64 runtime before removing existing installations.

If an older package fails with `The staged application smoke test failed (exit code ).`,
the blank status can be caused by Windows PowerShell 5.1 losing the child process exit code,
not by a failing PowerShell 7 runtime. The script retains the process handle before waiting
and rejects unavailable exit codes explicitly. Update the customer copy of the script, repackage
and upload the artifact with `Update-ImageArtifacts.ps1 -SkipDownloadingNewSources` using your
usual storage-account arguments, then start a new image build. A local script edit does not
update the ZIP already in blob storage.

## Script structure

The main script owns the PowerShell-specific matching rules, package identities, installation
paths, required payload files, runtime validation command, and install/remove sequencing.
Supporting functions take explicit parameters rather than reading product-specific script state.
For example, `Get-InstalledApplications -Name <pattern> -Publisher <pattern>` supports wildcard
names or `-RegEx`, with `-WindowsInstaller` to select MSI registrations. AppX discovery/removal,
directory discovery, payload validation, shortcuts, machine PATH, and Installed Apps registration
are likewise reusable operations. The functions remain embedded in this single root script so
image builds, VM Applications, and the copied uninstall script do not need a separate module.

## Removal and migration

Both install and uninstall remove **stable and preview PowerShell 7**:

- Registered EXE installer bundles first, using their registered quiet uninstall command with
  `/norestart`. The executable must exist and match `BundleCachePath`; missing cache files,
  native failures, or remaining bundle registrations stop migration rather than being ignored.
  A bundle can own an underlying MSI, so MSI registrations are rediscovered after bundle removal.
- Microsoft PowerShell 7 MSI ProductCodes in both machine uninstall hives, using native MSI removal.
  MSI detection requires both `WindowsInstaller=1` and a matching ProductCode-shaped subkey;
  a GUID-named EXE bundle is not treated as an MSI.
  Multiple matching architectures/versions are removed; other products and major versions are
  excluded. MSI busy failures are retried with a bound; errors and remaining registrations fail.
- Exactly `Microsoft.PowerShell` and `Microsoft.PowerShellPreview` AppX identities, removing
  registered packages for all users and provisioned entries. Bundles are removed before remaining
  main packages. Other AppX applications are untouched.
- Recognized PowerShell 7 directories directly under the native/x86 `Program Files\PowerShell`
  folders (`7`, `7-preview`, or `7.*`/`7-*`), identified by Microsoft's version-7 `pwsh.exe`.
  Arbitrary portable ZIP locations outside these roots are not searched or removed.
- This artifact's machine PATH entry, all-users shortcut, and uninstall registration.

**Back up machine-wide profiles and custom modules inside the installation folders first.**
Recognized ZIP folders are removed in full, including these files. User-profile content outside
those folders is not removed. Residual files left by native MSI removal are not deleted blindly:
if they occupy the new target, installation fails and asks you to back up/relocate them.
Reparse points are rejected. Running `pwsh` processes stop the operation without being killed.
Missing installations are success. Windows PowerShell 5.1 is preserved.

Install is destructive replacement, not an atomic upgrade or rollback mechanism. Stage/validation
failure leaves old installations intact; failures after removal are reported but do not restore
the old product. MSI reboot-required success is logged; the script does not reboot the VM.
Drain existing VM Application hosts and close PowerShell 7 sessions before replacement.

## Installed integration

The new installation is `%ProgramFiles%\PowerShell\7`. An existing matching machine PATH entry
keeps its position and spelling during ZIP replacement; if absent, the directory is prepended.
Comparison ignores case, expands environment variables, and tolerates trailing backslashes.
Uninstall removes the matching entry. User PATH entries are unchanged. An all-users
installation directory is created fresh and the validated payload is copied into it, inheriting
destination permissions rather than retaining the staging directory's Temp ACLs. The all-users
`PowerShell 7` Start Menu shortcut launches in the user's home directory. New processes/sign-ins
pick up machine PATH changes. The Installed Apps entry `PowerShell 7 (x64, ZIP)` provides a Windows
PowerShell-based native uninstall command for the ZIP, using the uninstall registry key
`HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PowerShell7.Zip`.

The official bundled `RegisterManifest.ps1` registers event logging; recognized ZIP removal
unregisters it before deleting the instrumentation DLL. This retains the previous MSI defaults
for PATH, shortcuts, and event registration. Explorer context-menu entries, `.ps1` default
associations, PowerShell remoting activation, and automatic update enrollment are **not added**.
ZIP servicing is owned by image refresh or immutable VM Application versions, not Microsoft Update.

## Connected download and offline staging

The `PowerShell7` entry in
[`downloads.json`](../../parameters/imageManagement/downloads.json) selects the latest stable
`PowerShell-7.*-win-x64.zip` asset from the official
[PowerShell releases](https://github.com/PowerShell/PowerShell/releases) and stages `PowerShell7.zip`.
This uses the existing GitHub downloader without changes. When migrating an existing artifact
folder, manually remove previously staged MSI/MSIX payloads and any other root-level ZIPs before
packaging; keep the deployment script, README, and `PowerShell7.zip`. The updater does not clean
old payloads from single-file download destinations.
See the [GitHub download rules](../../../docs/update-image-artifacts.md#4-github-releases).

For an exact connected download, run from the repository root:

```powershell
$asset = (Invoke-RestMethod https://api.github.com/repos/PowerShell/PowerShell/releases/latest).assets |
    Where-Object name -Like 'PowerShell-7.*-win-x64.zip'
if (@($asset).Count -ne 1) { throw 'Expected exactly one stable x64 ZIP asset.' }
$outFile = 'customer\artifacts\Microsoft-PowerShell-7\PowerShell7.zip'
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $outFile -UseBasicParsing
if ($asset.digest -notmatch '^sha256:([0-9A-Fa-f]{64})$') { throw 'Expected a published SHA256 digest.' }
if ((Get-FileHash -LiteralPath $outFile -Algorithm SHA256).Hash -ne $Matches[1]) { throw 'SHA256 mismatch.' }
```

For air-gapped use, obtain the approved ZIP on a connected system, verify its hash, and transfer
the complete selected artifact folder through the approved process. Pre-stage it under
`customer/artifacts/Microsoft-PowerShell-7` and use `Update-ImageArtifacts.ps1
-SkipDownloadingNewSources`. There is no need to run WinGet or contact GitHub on the image VM.

## VM Application lifecycle and live validation

Use `powershell.exe` lifecycle commands that expand the artifact ZIP before calling this script
with `-DeploymentType Install` or `Uninstall`, following the
[VM Applications guide](../../../docs/vm-applications.md). Publish/assign this application separately
from uploading artifacts. Do not also bake it into an image assigned the same VM Application unless
you intend that application's removal to remove the baked installation.

On an isolated target Windows build, validate:

1. Clean-image install, Sysprep/capture, first standard-user logon and execution, all-users shortcut, machine PATH, actual
   `pwsh` version/architecture, SYSTEM execution, and event-provider registration.
2. Replacement of existing stable/preview MSI, EXE-bundle-plus-MSI, and provisioned/registered
   AppX installations, including missing cached bundle uninstallers.
3. Repeated install/removal, no-package uninstall, and removal through Installed Apps.
4. VM Application install/update/remove after host draining; running-process failures, locked-file
   failures, reboot-required native removal, and residual customer files.
5. Preservation of Windows PowerShell 5.1, unrelated AppX packages, and user profiles.

Offline tests do not prove effective application-control approval, target-Windows behavior, or
Azure image/VM Application deployment success. See the
[ZIP installation guidance](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows#install-the-zip-package)
and the [MSIX gap tracker](https://github.com/PowerShell/PowerShell/issues/27565) for the format decision.
