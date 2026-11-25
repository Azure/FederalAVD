# User Certificate Backup & Restore

A self-contained FederalAVD application supporting **image-build/session-host
customization and Azure VM Application installation, update, and removal**.
The root deployment script installs the PowerShell Forms tools silently under
an elevated administrator or SYSTEM account. It never opens a form, reads user
certificates, or prompts for a PFX password during deployment.

## Why this application exists

### The user problem

On an Entra-joined AVD/FSLogix session host without an Active Directory dependency,
a user can import a software certificate with its private key, successfully use
it, then lose access to the private key after signing out and back in. The public
certificate may still appear in **Current User > Personal**, while applications
can no longer sign, decrypt, or authenticate using its key. Certificate presence
alone is therefore not a sufficient health check.

### The documented FSLogix behavior

Microsoft's [profile-container exclusions documentation](https://learn.microsoft.com/en-us/fslogix/concepts-container-types#redirection-based-exclusions)
lists these automatic redirections outside the profile container:

- `%USERPROFILE%\AppData\Roaming\Microsoft\Protect`
- `%USERPROFILE%\AppData\Roaming\Microsoft\Credentials`
- `%USERPROFILE%\AppData\Local\Microsoft\Credentials`

FSLogix redirects that content to `C:\Users\local_%username%`, which is deleted
at sign-out. The profile can consequently retain certificate metadata while
credential/protection material needed by a private key does not survive the
session. This behavior is consistent with the reported symptom, but is **not
proof of the root cause on every host**: key-provider behavior, permissions,
machine binding, and other certificate failures must be investigated separately.

The application deliberately does not alter these exclusions or try to repair
DPAPI. Microsoft [documents RoamIdentity=0 as recommended](https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings#roamidentity)
and says not to enable RoamIdentity on Entra-joined or Intune-managed devices.
Windows [Credential Manager persistence flags](https://learn.microsoft.com/en-us/windows/win32/api/wincred/ns-wincred-credentialw#members)
do not override FSLogix's redirection/deletion of credential files. The application
does not rely on Credential Manager to remember PFX passwords across sessions.

### How backup and restore address it

1. **Back up while the key still works.** After enrollment or renewal, the user
   explicitly selects approved, accessible, exportable software certificates.
   The backup form writes one versioned, password-encrypted PFX containing the
   complete selection, plus a validated-selection manifest.
2. **Keep the backup somewhere durable and private.** Use a per-user folder that
   survives sign-out, such as an appropriate profile-container location or an
   approved UNC share. Do not put the backup in the excluded locations above.
   Central folder policies configure paths, not storage permissions or retention.
3. **Recreate usable user keys at every sign-in.** The restore form opens in the
   signed-in user's session, requests the PFX password, validates the selected
   bundle, and reimports it into **Current User > Personal**. It verifies actual
   private-key signing and store read-back before reporting success.
4. **Repeat after later sign-ins.** The portable encrypted backup, rather than
   an assumption that the previous session's key remains accessible, is the
   recovery source. The user may need to restart applications that cache keys.

Backup is preventive, not recovery of an already lost key: **without a usable
private key or a valid private-key backup, this tool cannot reconstruct one**.
New non-exportable/hardware-protected keys cannot be backed up by this helper.
The backup file and its password must remain available; passwords are not stored
by the application. An unattended secret-service integration is not implemented.

### Intended use and limits

This is a user-context software-certificate continuity workaround for approved
Windows/AVD/FSLogix deployments. It is not a virtual smart card, CSP/KSP, hardware
security boundary, enrollment service, Windows/Entra sign-in mechanism, or trust
chain repair. It does not weaken private-key export policy or install trusted
roots. Administrators must approve portable private-key backups and their storage.
An approved host pilot must confirm the original symptom, backup/export
eligibility, same-host and cross-host restore, and the consuming application's
behavior. A successfully signed test challenge does not establish certificate
trust or application authorization.

## Artifact layout

```text
UserCertificateBackupRestore\
  Deploy-UserCertificateBackupRestore.ps1
  README.md
  scripts\
    CertificateSignIn.ps1
    CertificateSignIn.Core.psm1
    CertificateBackup.ps1
    CertificateBackup.Core.psm1
    Set-FileZone.ps1
    assets\
      certificate-banner.png
      certificate-backup-banner.png
      certificate-restore.ico
      certificate-backup.ico
      New-CertificateArtwork.ps1
    policy\
      UserCertificateBackupRestore.admx
      en-US\
        UserCertificateBackupRestore.adml
```

There is exactly **one root `.ps1`**, as required by the FederalAVD ZIP runner.
Keep all supporting scripts in `scripts`; never place the interactive Forms
scripts beside the root deployment script. The artwork generator is optional
development tooling, not run during deployment.

## Stage, configure, and deploy

From the FederalAVD repository root, copy the complete example before customizing:

```powershell
Copy-Item -Recurse -Path '.\customer-examples\artifacts\UserCertificateBackupRestore' `
    -Destination '.\customer\artifacts\UserCertificateBackupRestore'
```

On an approved elevated Windows test host, run the **64-bit Windows PowerShell
5.1** deployment script. No STA or interactive desktop is needed for deployment:

```powershell
.\customer\artifacts\UserCertificateBackupRestore\Deploy-UserCertificateBackupRestore.ps1

# Explicitly configure the shared backup/restore folder without expanding it
# in the administrator/SYSTEM deployment context.
.\customer\artifacts\UserCertificateBackupRestore\Deploy-UserCertificateBackupRestore.ps1 `
    -CertificateFolder '{Documents}\CertificateBackups'

# Validate the package and intended operation without installing it.
.\customer\artifacts\UserCertificateBackupRestore\Deploy-UserCertificateBackupRestore.ps1 -WhatIf

# Configure local computer GPO; template installation is implied.
.\customer\artifacts\UserCertificateBackupRestore\Deploy-UserCertificateBackupRestore.ps1 `
    -ConfigureLocalGpo `
    -CertificateFolder '{Documents}\CertificateBackups' `
    -ExpiryWarningDays 60
```

| Deployment parameter | Default | Behavior |
| --- | --- | --- |
| `DeploymentType` | `Install` | `Install` installs/reinstalls/updates; `Uninstall` removes known application files and all-user shortcuts |
| `RemovePolicySettings` | Off | Uninstall only: explicitly remove the two application policy values from local computer GPO and 64-bit HKLM |
| `RemovePolicyTemplates` | Off | Uninstall only: remove local ADMX/ADML only if they match this package |
| `DefaultInputPath` | `{Documents}\CertificateBackups` | Uses the interactive user's redirected Documents known folder; does not create or replace registry policy |
| `InputPath` | Omitted | Optional shortcut override over saved preferences; managed policy still wins |
| `CertificateFolder` | Omitted | Shared backup/restore path becomes authoritative through local GPO, or directly through 64-bit HKLM when `ConfigureLocalGpo` is absent |
| `ExpiryWarningDays` | Omitted | Optional managed warning window for both forms, 1-365 days; runtime default is 30 |
| `ConfigureLocalGpo` | Off | Merge supplied settings into computer `Registry.pol`, update `gpt.ini`, and install bundled ADMX/ADML; implies `InstallPolicyTemplates` |
| `InstallPolicyTemplates` | Off | Independently install bundled ADMX/ADML into local `PolicyDefinitions`; does not itself configure local GPO |

Omitted policy parameters **preserve existing values**. Environment references
are stored literally as `REG_EXPAND_SZ` and expand only when users launch the
tools. Re-running deployment refreshes the same runtime files and shortcuts;
it does not create duplicates or delete backup versions. A failure is reported
with a nonzero exit code; deployment is not transactional, so inspect and retry
after a partially completed installation.

With `-ConfigureLocalGpo`, no separate `-InstallPolicyTemplates` is needed.
Only explicitly supplied settings are merged; unrelated and omitted policies
are preserved. This mode does not directly write live HKLM values or run
`gpupdate`. Settings become effective after computer policy refresh or the next
host startup, and the forms read them at their next launch. Without
`-ConfigureLocalGpo`, supplied settings retain the direct-HKLM behavior.

Package/upload using the repository's
[Update-ImageArtifacts.ps1 workflow](../../../docs/update-image-artifacts.md).
Reference the resulting ZIP in an image-build or session-host customization:

```json
{
  "name": "UserCertificateBackupRestore",
  "blobNameOrUri": "UserCertificateBackupRestore.zip",
  "arguments": "-CertificateFolder '{Documents}\\CertificateBackups'",
  "successExitCodes": "0"
}
```

Omit `arguments` to retain existing policy and use the standard fallback where
no managed values exist. No reboot is initiated or required by this artifact.
Application identities consistently use `UserCertificateBackupRestore`:

| Surface | Name/path |
| --- | --- |
| Artifact, ZIP, VM Application | `UserCertificateBackupRestore` |
| Installed application folder | `%ProgramFiles%\UserCertificateBackupRestore` |
| Administrative templates | `UserCertificateBackupRestore.admx` / `UserCertificateBackupRestore.adml` |
| Policy namespace/category ID | `UserCertificateBackupRestore.Policies` / `UserCertificateBackupRestore` |
| Machine policy key | `HKLM\Software\Policies\UserCertificateBackupRestore` |
| User preference key | `HKCU\Software\UserCertificateBackupRestore` |
| Read-only JSON fallback | `%APPDATA%\UserCertificateBackupRestore\settings.json` |
| Per-user Run value | `UserCertificateBackupRestore` |
| Displayed application/policy category | **User Certificate Backup & Restore** |

The shared backup-data default remains **`{Documents}\CertificateBackups`**;
it is not the installed application folder. Runtime helper names such as
`CertificateSignIn.ps1` and the PFX/manifest filename format are implementation
names, not alternate application or policy identities. There is no migration
step for this new application.

### Azure VM Application lifecycle

The sample `customer-examples\parameters\imageManagement\vmApplications.json`
defines install, update, and remove commands. Each command expands
`UserCertificateBackupRestore.zip` in Azure's package working directory before invoking
`Deploy-UserCertificateBackupRestore.ps1`. Update reuses `-DeploymentType Install`.
Removal re-expands the package rather than depending on a prior extraction.
Commands run silently and synchronously, fail on extraction/deployment errors,
and do not change or bypass execution policy. Sign/approve the scripts through
your organization's application-control process before deployment.

Merge the **UserCertificateBackupRestore application entry** into your existing
`customer\parameters\imageManagement\vmApplications.json`; do not overwrite other
applications. The example version is `1.0.0` and region is `eastus2`. Set your
actual region (for example, `usgovvirginia` in Azure Government) and increment the
version whenever the payload or lifecycle commands change.

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId '<artifactsStorageAccountResourceId>' `
    -SkipDownloadingNewSources

.\deployments\Publish-VMApplications.ps1 `
    -ManifestPath '.\customer\parameters\imageManagement\vmApplications.json' `
    -ValidateOnly

.\deployments\Publish-VMApplications.ps1 `
    -ManifestPath '.\customer\parameters\imageManagement\vmApplications.json' `
    -GalleryResourceId '<computeGalleryResourceId>' `
    -StorageAccountResourceId '<artifactsStorageAccountResourceId>'
```

Use the returned version `packageReferenceId` for your VM/host-pool assignment
as documented in [VM Applications](../../../docs/vm-applications.md).
The sample lifecycle manages **application files and shortcuts only**.
Keep HKLM/local-GPO settings under image customization or your policy manager:
the VM Application commands intentionally omit policy configuration and cleanup
switches. Do not use competing image and VM Application owners for the installed
application files. Drain affected hosts and close the forms before update/removal;
the script does not terminate users' processes, and locked files fail explicitly.

No external payload, download command, `downloads.json` entry, third-party
module, or runtime internet download is required. Source is the complete
reviewed example folder, including its original artwork. For offline transfer,
stage this exact complete folder or its approved `UserCertificateBackupRestore.zip`,
not another artifact's helpers or the entire low-side package output.
Use approved local/UNC storage within the authorized boundary. The artifact
does not provision shares or transfer certificates between security boundaries.

See the [FederalAVD artifact guide](../../../docs/artifacts-guide.md) for
packaging, customization arguments, and connected/air-gapped handoff.

## User application

A Windows PowerShell 5.1 Forms application that restores a user's software certificate at **each interactive sign-in** on Windows/FSLogix hosts. No AD dependency, application EXE, C# source, compilation, package restore, or PowerShell 7 installation is required.

This is a **reimport workaround**, not a custom CSP/KSP or a repair of FSLogix/DPAPI roaming. It can restore backed-up software certificates on Entra-joined hosts without AD, but it does **not** emulate a smart card, provide a PIN/token interface, add hardware-backed protection, or implement Entra/Windows sign-in authentication. A visible certificate does not prove its private key is accessible. The script imports again, signs a challenge, and verifies the identity read back from Current User > Personal.

## Requirements and files

- Windows PowerShell **5.1** (`powershell.exe`) and **.NET Framework 4.8 or newer**.
- An interactive desktop and STA execution. PowerShell 7 is deliberately not the application target.
- Keep the runtime scripts together: `CertificateSignIn.ps1`, `CertificateSignIn.Core.psm1`, `CertificateBackup.ps1`, `CertificateBackup.Core.psm1`, and `Set-FileZone.ps1`. Also include both banner PNGs and both ICO files in `assets`, and the administrative templates in `policy`.
- Backup requires Windows' built-in PKI cmdlets `Get-PfxData` and `Export-PfxCertificate` with AES256_SHA256 support. The helper does not install packages or enroll certificates itself.
- `Add-Type -AssemblyName` only loads Windows' existing Forms/Drawing assemblies. There is no `Add-Type -TypeDefinition`, generated C#, or compiled application code.
- Normal use runs as the signed-in user without elevation. Administrator privileges are needed only for all-user deployment.

The scripts are **unsigned**. Switching from EXE to PowerShell does not eliminate signing or application-control requirements. Use your organization's approved code-signing/deployment process for the script, module, helper, and installer. Do not unblock files, change execution policy, or add an execution-policy bypass. Hidden startup hides the PowerShell console, not the password form. For first-run diagnostics, omit `-WindowStyle Hidden` so policy/loading errors remain visible.

## Run

For a manual user launch from the artifact folder:

```powershell
powershell.exe -NoProfile -STA -File ".\scripts\CertificateSignIn.ps1" -InputPath "C:\UserCertificates"
```

The shared folder is filled automatically and a backup is discovered when the form opens. Both tools use **managed HKLM `CertificateFolder` > explicit `-InputPath` > HKCU `InputPath` > legacy JSON `InputPath` > `-DefaultInputPath`**. There are no separate backup/restore folder settings. The fallback defaults to `{Documents}\CertificateBackups` and resolves the signed-in user's current Windows Documents known folder. No backup is created automatically; the backup helper creates the destination folder only after the user explicitly submits a valid selection/password.

To use the standard default, omit `-InputPath`. To change only the fallback without overriding a saved folder:

```powershell
powershell.exe -NoProfile -STA -File ".\scripts\CertificateSignIn.ps1" -DefaultInputPath '%USERPROFILE%\MyCertificateBackups'
```

The built-in default follows the Windows Documents known folder, including OneDrive KFM or network redirection. Explicit profile-relative paths remain literal choices and do not automatically follow Documents redirection.

1. Check the prefilled backup folder, or use **Browse...** to choose another.
2. The file dropdown lists `.pfx` and `.p12` files in this folder only, newest UTC last-write time first, with ordinal filename ordering for timestamp ties. It defaults to the manifest's **last validated complete bundle**, even if an unrelated file has a newer timestamp. Without a manifest, it defaults to the newest file. **Find newest** refreshes the list and resets that default; subfolders are not searched.
   You can select another file without changing the shared folder. The file
   choice is not saved; opening the form or selecting Find newest restores the
   default selection.
   A file without matching manifest metadata displays a warning and requires
   confirmation before restore. Its saved hash and complete identity set cannot
   be checked; an older backup may omit current identities. Password, bundle,
   private-key signing, and store read-back checks still apply.
   A current manifest-backed file with a hash mismatch is always rejected, even
   with manual selection. Malformed manifests remain errors, not an automatic
   fallback. If the current backup is missing/corrupt but its manifest is valid,
   the dropdown remains available for explicitly selecting a different file.
3. Enter the selected file's password and select **Restore certificate**. Blank passwords are supported. Import happens in a background PowerShell runspace so the form stays responsive.
4. Wait for success with subject, thumbprint, expiration, and signing/store read-back verification. Expired/not-yet-valid certificates are imported but flagged.
5. Review the result, then select **Continue** to close the form. Restart the certificate-consuming application if it caches certificates/keys.
6. **Remember folder** retains an unmanaged folder in HKCU for both backup and restore. Managed folders are read-only with browsing disabled; remembering a folder cannot override policy. During manual setup, optionally enable **Start at sign-in for this user** before saving. With a managed restore folder this button saves only the startup option.

### Remembering a user-selected folder

When no corresponding administrative folder value applies, type a local or UNC
folder or select **Browse...**, then **Remember folder** in either form. This
saves one shared preference, not separate backup and restore preferences:

| Key | Value | Type |
| --- | --- | --- |
| `HKCU\Software\UserCertificateBackupRestore` | `InputPath` | `REG_EXPAND_SZ` |

Only the folder is stored: no password, certificate, or private key. Environment
references such as `%USERPROFILE%` and `%USERNAME%` remain unexpanded in the
registry and expand when the signed-in user next opens a form. Existing
`REG_SZ` values are also accepted. This is an ordinary application preference,
**not** an administrative-template policy.

The editable folder box preserves `%NAME%` tokens; it does not replace them with
the current host's expanded path when you select **Remember folder**. File
discovery and backup/restore expand them only when accessing files. Browsing
selects an ordinary concrete path and saves that path as selected; the tool
does not guess which prefix should become `%USERPROFILE%`.

Keep this unexpanded value as the editable source of truth. Do not expand it for
editing and then try to reconstruct a token from the edited absolute path:
different environment variables can resolve to the same or overlapping locations.
The discovered restore file and successful backup status show the actual resolved
file path without changing the saved folder template.

For work OneDrive, an example deployment fallback is:

```powershell
.\Deploy-UserCertificateBackupRestore.ps1 `
    -DefaultInputPath '%OneDriveCommercial%\CertificateBackups'
```

The application expands this using the environment of the signed-in user's
application process. Work OneDrive must already be configured for that user and
the variable must identify the intended organization's local sync root. The tool
does not guess a tenant folder, fall back to personal OneDrive, or configure the
OneDrive client. Verify the variable and folder on the target host; an existing
process may not see environment changes until launched from a refreshed session.

If a variable remains unresolved, backup/restore reports an error instead of
using a literal `%OneDriveCommercial%` directory or choosing another destination.
An unavailable variable does not prevent storing its raw HKCU preference for
later use. Managed folder values retain their existing strict launch validation.

After explicit selection of certificates, a valid password, and submission,
backup creates the destination **including missing parent folders** before writing
the encrypted bundle. Remember folder, discovery, and renewal checks do not create
directories. Creation does not grant permissions: access denied, an unavailable
share, or an unwritable destination fails the backup explicitly. Folder creation
can remain after a later export failure; it is not proof of a successful backup.

Writing a verified local backup in a OneDrive folder does **not** prove upload or
availability on another host. Confirm OneDrive sync has completed before sign-out
or host replacement, and that the PFX and matching manifest are locally available
before restore. Review whether cloud storage of password-encrypted private-key
backups is permitted by your organization's security requirements.

Both tools identify the current folder source in their folder headings and
guidance: **organization-managed**, **saved (HKCU)**, **legacy settings**,
**deployment default**, or **launch-supplied**. Editing an unmanaged folder
changes the heading to **not remembered**; a successful save changes it to
**saved (HKCU)**. Managed folders remain read-only, with Remember folder disabled
in backup/sign-in mode; a manually launched managed restore form instead offers
**Save startup option**. An explicit launch path remains called out as an
override even after a user saves a preference.

### Redirected Documents and KFM readiness

`{Documents}` is an **application token**, supported only at the start of a path.
It is not a Windows environment variable. The forms and HKCU/policy/shortcut
values retain `{Documents}\CertificateBackups` literally. File operations resolve
it in the interactive user's context with
`Environment.GetFolderPath(SpecialFolder.MyDocuments, SpecialFolderOption.DoNotVerify)`.
The installer never resolves it in the administrator/SYSTEM profile.

The [Windows known-folder API](https://learn.microsoft.com/en-us/windows/win32/shell/known-folders)
honors configured redirection; the tool does not read or rewrite shell registry
keys directly. [DoNotVerify](https://learn.microsoft.com/en-us/dotnet/api/system.environment.specialfolderoption)
does not create Documents or require it to exist during lookup. Missing or invalid
known-folder results cause an explicit error, never a fallback to
`%USERPROFILE%\Documents`. Backup still creates the selected destination after
the user submits a valid backup.

**A successful known-folder lookup does not prove KFM has finished.** It may
still return the old local Documents path while OneDrive starts. For `{Documents}`
paths, the tool checks effective 64-bit
`HKLM\Software\Policies\Microsoft\OneDrive` policy:

- A valid `KFMSilentOptIn` tenant GUID with no Desktop/Documents/Pictures selectors
  means all three folders are expected to move.
- When any selector exists, Documents is expected only if
  `KFMSilentOptInDocuments` is DWORD `1`. Desktop/Pictures-only policies do not
  make Documents wait. Malformed effective policy raises an explicit error.
- When Documents is expected, its normalized known-folder path must be under the
  existing work OneDrive root identified by `OneDriveCommercial`.
  Each retry rereads the current user's environment value
  (`HKCU\Environment`) through the documented .NET API; the inherited process
  value is used only if that user value is absent. Neither is modified.
  Otherwise the operation stops with **Waiting for Documents
  redirection** guidance before creating a destination.
- There is no fixed sleep, automatic timeout bypass, or fallback folder.
  Complete work OneDrive sign-in/KFM, then select **Find newest** or **Check
  renewals** and retry. A managed token path can fail at launch during policy
  validation; relaunch the tool after OneDrive is ready.

This matches the policy intent in
[`Configure-OneDrivePolicy`](../Configure-OneDrivePolicy/README.md) and
[Microsoft's silent KFM documentation](https://learn.microsoft.com/en-us/sharepoint/use-group-policy#silently-move-windows-known-folders-to-onedrive).
`SilentAccountConfig`, `KFMBlockOptOut`, and the existence of a OneDrive folder
alone are not treated as proof of completed Documents redirection. No undocumented
KFM completion/status registry bits are used.

The check establishes **local redirection readiness only**: it does not prove
that all old files moved, uploads finished, or that `OneDriveCommercial` belongs
to the policy's tenant. Validate multi-business-account sessions; use an explicit
approved path if the variable does not identify the intended root.
Apply and refresh OneDrive machine policy **before** launching these tools:
the application cannot anticipate a policy that has not arrived yet.
Explicit non-token paths remain explicit and are not subject to this KFM guard.

**Updating existing installations:** redeploy to refresh old shortcut fallbacks.
Existing HKCU/JSON preferences and policy values are not automatically rewritten.
Change any old `%USERPROFILE%\Documents\CertificateBackups` setting to
`{Documents}\CertificateBackups` if it should follow redirection, using its current
owner (user preference or administrative policy). Do not move/delete existing
backups automatically; verify their location and migrate through an approved process.

### Deployment defaults and environment-variable syntax

`-DefaultInputPath` is a deployment parameter, defaulting to
`'{Documents}\CertificateBackups'`. It is stored in shortcut arguments,
not seeded into HKCU. With no policy, explicit override, HKCU preference, or legacy
JSON preference, both forms use this fallback. Changing it during deployment
does not overwrite a user's saved choice.

Pass environment references as **literal percent tokens in PowerShell**:

```powershell
.\Deploy-UserCertificateBackupRestore.ps1 `
    -DefaultInputPath '{Documents}\CertificateBackups'
```

| PowerShell argument | Result |
| --- | --- |
| `'{Documents}\CertificateBackups'` | Application token; follows the user's current Documents known folder and KFM readiness guard |
| `'%USERPROFILE%\CertificateBackups'` | Preserved token; expanded later for each interactive user |
| `"$env:USERPROFILE\CertificateBackups"` | PowerShell expands it before deployment, fixing it to the deploying account's path |
| `'$env:USERPROFILE\CertificateBackups'` | Literal PowerShell expression, not a supported environment token; do not use |
| `'C:\CertificateBackups'` | Fixed path for every user; ensure appropriate user isolation and permissions |

There is **no automatic translation** from `$env:USERPROFILE` or an expanded
profile path back to `%USERPROFILE%`, and the forms never evaluate PowerShell
expressions entered into their text boxes. The same percent-token convention
applies to `-InputPath`, managed folder parameters, and prepopulated HKCU values.
Do not invoke these deployment examples through a wrapper that expands the
percent tokens in the administrator/SYSTEM environment first.

### Prepopulating and retaining a user preference

To prepopulate the preference, run the following in the **intended user's**
64-bit PowerShell session on 64-bit Windows, not as SYSTEM or another administrator:

```powershell
$preference = 'HKCU:\Software\UserCertificateBackupRestore'
New-Item -Path $preference -Force | Out-Null
New-ItemProperty -Path $preference -Name InputPath -PropertyType ExpandString `
    -Value '{Documents}\CertificateBackups' -Force | Out-Null
```

Use persistent storage private to that user, with access on every applicable
host. Remembering a path does not create its folder, grant access, or copy backups.
Saving a backup does not automatically remember its destination.

Close and reopen the other form to reload a changed preference. An explicit
`-InputPath` still overrides the preference on launch; use `-DefaultInputPath`
for a customizable fallback instead. Opening the backup helper from an unmanaged
restore form intentionally passes the restore form's current folder as an
explicit path. The already-open restore form keeps its current folder.

Optional `%APPDATA%\UserCertificateBackupRestore\settings.json` files remain read-only
fallbacks when HKCU `InputPath` is absent. New saves write HKCU only and do not
delete or rewrite legacy JSON. Removing HKCU `InputPath` therefore exposes a
legacy preference if one remains; without either, the deployment fallback applies.
A present but blank or wrong-type HKCU value raises a settings error rather
than silently falling back. Correct it in the user's registry or launch with
an explicit valid `-InputPath` and select **Remember folder**.

The managed HKLM `CertificateFolder` locks the shared folder in both forms.
Policy changes do not erase the user's preference; removing this managed value
makes the normal explicit/user/default precedence available at the next launch.
Invalid managed values produce an error, never a user-preference bypass.
The elevated installer never seeds HKCU for users; install, update, and ordinary
uninstall preserve existing per-user preferences.

## Centrally managed shared folder

Configure this shared value through Intune, an approved management script, or equivalent host-management tooling:

| Registry setting | Purpose |
| --- | --- |
| `HKLM\SOFTWARE\Policies\UserCertificateBackupRestore\CertificateFolder` | Shared folder read by restore and written by backup |

Use **REG_EXPAND_SZ** or **REG_SZ**. The application reads the **64-bit registry view** on 64-bit Windows, even when launched from 32-bit PowerShell. Paths expand in the interactive user's context, not the management agent's context.

Example for approved elevated deployment, not needed to run the development tests:

```powershell
$policy = 'HKLM:\SOFTWARE\Policies\UserCertificateBackupRestore'
New-Item -Path $policy -Force | Out-Null
New-ItemProperty -Path $policy -Name CertificateFolder -PropertyType ExpandString -Value '{Documents}\CertificateBackups' -Force | Out-Null
```

Run management scripts in 64-bit PowerShell on 64-bit hosts. A UNC path such as `'\\fileserver\certificates\%USERNAME%'` is also supported; each user's folder must have appropriate private permissions.

An absent value leaves the parameter/saved-folder/default behavior intact for both tools. The application and installer **do not write policy defaults**: an initial deployment can use the fallback, then a centrally written value takes precedence on the next launch without reinstalling shortcuts. Removing it restores unmanaged fallback behavior for both tools.

A present value is authoritative and locks both forms' folder controls. Empty, wrong-type, relative, invalid, or unresolved-variable policy values produce an explicit error instead of silently using another folder. Policy is read at launch; close/relaunch to apply subsequent management changes. Users cannot override it through the forms, HKCU preferences, legacy JSON, or `-InputPath`; this is application configuration, not a security boundary against users running other tools.

### Group Policy administrative templates

The package includes `scripts\policy\UserCertificateBackupRestore.admx` and
`scripts\policy\en-US\UserCertificateBackupRestore.adml`. The installer stages them at
`%ProgramFiles%\UserCertificateBackupRestore\policy`. The root deployment script also
copies them into `%WINDIR%\PolicyDefinitions` and its `en-US` subdirectory when
`-ConfigureLocalGpo` or `-InstallPolicyTemplates` is supplied.
**`-ConfigureLocalGpo` implies template installation**; specifying both switches
is unnecessary. `-InstallPolicyTemplates` remains available for installing the
templates without configuring local GPO. Neither option changes registry
permissions or runs `gpupdate`.

An administrator can copy the ADMX into `%WINDIR%\PolicyDefinitions` and the
ADML into `%WINDIR%\PolicyDefinitions\en-US` on an approved management/test host.
For domain Group Policy, distribute the same pair through the domain's
administrative-template Central Store, preserving the `en-US` subdirectory.
Use the matching ADMX/ADML versions together. No templates are installed on this
development machine.

In the policy editor, open **Computer Configuration > Administrative Templates >
User Certificate Backup & Restore**:

- **Set the managed certificate backup and restore folder** writes `CertificateFolder`.
- **Set the certificate expiry warning period** writes `ExpiryWarningDays`
  as a DWORD from 1 to 365 days, overriding both forms' default 30-day window.

The single folder policy is a computer-scoped, required expandable-string setting for the existing
HKLM policy key. Enabling it supplies the path to both forms; disabling it removes
the shared folder setting. Not Configured does not enforce a value through that
GPO, but another management tool or deployment can still supply the registry
value. Fallbacks apply only when the shared registry value is absent.
Do not configure conflicting owners for the same value.

Standard users cannot edit these HKLM settings under normal Windows permissions.
The artifact does not grant users write access to policy keys. Users can change
the shared unmanaged preference only while no managed folder value exists.

This is an application-defined policy, not a built-in Windows certificate policy.
The bundled ADMX/ADML define its mapping; the expandable text element
uses Microsoft's [ADMX TextElement schema](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/policy/element-1-text).
No OneDrive or Windows certificate-policy mapping is changed.

Entra join alone does **not** deliver domain GPOs. On Entra-only AVD hosts, use
approved Local Group Policy deployment, supported Intune custom ADMX import, or
the existing centrally managed registry deployment. Validate ADMX import and
assignment support in the target management environment; templates do not make
domain Group Policy available without the required domain connectivity/join.
Relaunch the forms after policy refresh. XML references and registry mappings
are tested locally; actual policy-editor import/application remains a host pilot.

## Blue theme and sign-in experience

Both native forms use the Microsoft-blue color palette (`#0078D4`) with original action-specific artwork. Restore shows a certificate document, open padlock, and return arrow; backup shows a certificate document, downward arrow, and archive box. These are not Microsoft product branding, hardware-backed protection, or an actual virtual smart card. Fields stay on a plain, high-contrast surface. Windows high-contrast mode omits the decorative images and uses system text/background colors.

`scripts\assets\New-CertificateArtwork.ps1` regenerates both PNGs and both ICOs using Windows' existing System.Drawing APIs, with no downloads or application compilation. It is a development tool, not needed on deployed hosts. Native labels are drawn over the banners' reserved left-hand areas for legible, accessible text.

The restore and backup Start Menu shortcuts and form windows use matching
`certificate-restore.ico` and `certificate-backup.ico` icons. Each ICO includes
32-bit PNG frames at **16, 24, 32, 48, 64, 128, and 256 pixels** so Windows can
select the appropriate size. The sign-in shortcut uses the restore icon.
Re-running deployment refreshes shortcut icon locations; Windows may cache a
previously displayed icon until the shell refreshes.

With `-Startup`, the PowerShell console is hidden by the installed startup command, and the form's minimize/maximize/close controls are hidden. Alt+F4/normal closing is blocked until a successful, nonempty import result has passed private-key and store read-back verification. Failures keep retry and folder selection available; **Remember folder** alone does not unlock closing. After success, the primary button becomes **Continue**. The per-user startup checkbox is hidden in this host/sign-in workflow.

Manual launches without `-Startup` retain the close button for setup/support, except while an import is active. This is a workflow guard, not a security boundary: it cannot prevent Task Manager/process termination or enforce certificate use by other applications, and it does not block Windows shutdown/logoff. Administrators need an out-of-band support path if no usable backup/password is available. The form requests activation but does not force itself permanently above other apps.

Passwords are never saved to settings, startup arguments, logs, or disk. The masked textbox is cleared at import start. The worker receives a SecureString, disposed when the operation finishes. .NET Framework's collection importer requires a brief plain-string conversion at the import boundary; the unmanaged conversion buffer is zeroed and freed immediately. The textbox and importer still use managed strings that cannot reliably be erased in process memory; this is not a hardened credential vault.

Imports use Current User > Personal (`Cert:\CurrentUser\My`) and `UserKeySet | PersistKeySet`, without requesting exportability or machine storage. Provider policy ultimately determines key behavior. Preflight checks use ephemeral keys before persistence, reject public-only bundles and CA private keys, and verify RSA/ECDSA signing. Roots/intermediates without private keys are not installed; deploy trust chains separately through an approved administrative process.

Supported: `.pfx` / `.p12` bundles with RSA or ECDSA software private keys, up to 32 MB. Not supported: `.cer`, `.crt`, `.p7b`, standalone PEM/key pairs, DSA, hardware tokens, CA private keys, PINs, or password vaulting. Discovery does not silently fall back to an older file when the managed/latest backup is invalid.

## Back up certificates after enrollment or renewal

Use **Back up certificates** in the restore form, **Start > User Certificate Backup & Restore > Back up certificates** after all-user installation, or launch the separate helper:

```powershell
powershell.exe -NoProfile -STA -File ".\scripts\CertificateBackup.ps1" -InputPath "{Documents}\CertificateBackups"
```

1. Complete certificate enrollment while the user's private key is accessible on that host.
2. Check the destination folder. If unmanaged, type/browse to your chosen folder and optionally select **Remember folder** to reuse it for backup and restore. Review the Current User > Personal list and remembered identities available in the existing managed backup. The picker excludes public-only, CA, and unsupported-algorithm certificates. It does not export keys merely by listing them.
3. Explicitly check the complete set of software identities to retain. Previously approved thumbprints are remembered; possible replacement/renewal certificates remain unchecked until approved. Uncheck superseded identities if you want to replace them in the managed set.
4. Enter and confirm a **12-character minimum** password. When retaining identities from the existing managed backup, enter **that backup's current password** so the helper can unlock and reuse them. Separate old/new password fields and password rotation for retained identities are not provided. Confirmation is case-sensitive. Prefer a long, unique passphrase; the length minimum is not a guarantee of password strength.
5. Select **Back up certificates**. All checked identities are exported into **one AES256/SHA256-encrypted PFX**, validated through ephemeral import/signing, and checked for every selected thumbprint.
6. Review the success status, full path, last backup time, and warnings. All previous PFX versions remain intact. **Done** closes the helper; it does not unlock the restore form until restore itself succeeds.

The CA supplies the certificate, not a portable copy of a private key generated during enrollment. A newly selected key must be accessible and exportable under its issuing template/enrollment/provider policy. Non-exportable new keys are rejected by the export operation; this application does not weaken stored-key policy, bypass hardware protection, or reconstruct a private key from a `.cer`.

Previously approved identities can instead be reused from their existing password-encrypted PFX, including when the restored store key is non-exportable or missing. The helper validates that bundle and loads exportable **ephemeral copies of already-backed-up keys**; it never changes the export policy of keys in Personal. This allows a renewed identity and unchanged identities to form one complete new bundle. An incorrect existing-backup password produces an explicit failure and leaves the prior selection intact.

Each version is named `CertificateSignIn-<UTC time>-<random identifier>.pfx`. `CertificateSignIn.backup.json` records the last validated version, SHA256 hash, selected thumbprints, identity-matching metadata, certificate validity dates, and backup time. It contains **no password or private key**. Treat subject/issuer metadata as private and protect the folder against other users' reads/writes.

The final PFX is published only after validation. The manifest is staged and atomically replaced; a later manifest failure is explicitly reported, and earlier versions are not deleted. The filesystem/share must support atomic replacement. A newly saved but unreferenced PFX may remain after a manifest-publication failure; it is not silently promoted as the managed restore source.

Windows .NET Framework cannot directly choose AES for a multi-identity collection export. The implementation creates a short-lived, password-encrypted legacy-format staging PFX, then uses the Windows PKI cmdlet to re-encrypt the complete bundle as AES256/SHA256. No plaintext key file is written. All staging names end in `.pending`/`.pending.json`, are excluded from restore discovery, and are removed on normal completion/failure. Process termination or host failure can leave encrypted staging files; investigate and remove those exact files through approved tooling.

Managed restore verifies the file hash again and checks the bytes actually read plus the expected identity set before key persistence. A hash is a corruption check, **not a digital signature**: someone able to modify both PFX and manifest can change both. Folder permissions and a strong password remain essential. Missing, corrupt, or malformed managed metadata causes an explicit error, not an automatic fallback. The manual backup helper can show the current store and create a fresh explicitly approved backup when old metadata is damaged; retain prior versions for deliberate recovery.

Backup does not install trusted roots/intermediates or alter certificate trust. Multiple identities in one bundle remain multiple software certificates after restore. Old certificates and keys in the user store are not deleted when a selection changes. No automatic retention pruning is performed; review old versions under your organization's retention policy.

### OneDrive offline availability after backup

After the PFX has been verified, its manifest published, and encrypted staging
files cleaned up, the helper requests **Always keep on this device** for backups
under the signed-in user's recognized work OneDrive root. It uses the same
`attrib +p -u` mechanism as
[`Configure-OneDrivePinnedFolders`](../Configure-OneDrivePinnedFolders/README.md),
but does **not** install that artifact, create a scheduled task, or change
OneDrive policy. No executable payload or public-endpoint download is added;
OneDrive may download the user's own pinned backup files.

- The new PFX and matching manifest are explicitly pinned.
- A dedicated folder named `CertificateBackups` is also pinned, along with its
  retained application-named PFX versions, **only** when its immediate contents
  contain nothing except the manifest and generated backup versions. Subfolders,
  unrelated files, or linked entries disqualify folder-wide pinning. Future files
  added to a pinned dedicated folder can inherit OneDrive's keep-on-device
  behavior; do not repurpose it as a general document folder.
- The OneDrive root and current Documents root are **never** folder-pinned,
  regardless of their names. Other/custom folder names and mixed-content folders
  get pin requests for the new PFX and manifest **only**. No recursive wildcard
  operation is used.
- Ordinary local folders, UNC shares, mapped network drives, and paths outside
  the recognized work OneDrive root are not pinned. Recognition reuses the fresh
  User/Process `OneDriveCommercial` lookup described above; it does not guess
  `Business1`, discover other tenants, or treat a similarly prefixed sibling as
  part of the sync root.
- Directory junctions/symbolic links and linked backup files are not followed.
  Normal OneDrive cloud reparse points are allowed; their metadata must already
  be visible locally. This is not a remote cloud-file inventory.

Review the completion message. **Requested** means the pin attributes were
accepted and checked, **not** that downloads or cloud upload have completed.
OneDrive, connectivity, available disk space, and client policy still determine
hydration/synchronization. Retained versions can consume additional local disk
space. Verify OneDrive's status before sign-out or relying on another host for
recovery; pinning does not repair missing metadata or make uncached content
readable during an outage.

Pin requests share a 30-second native-command budget. An attribute error or
timeout produces **Backup succeeded; offline pinning failed**, with details,
while preserving the valid PFX, manifest, and earlier versions. Other targets
are still attempted while time remains; partial pin requests are not undone.
The helper does not unpin existing content or automatically repeat the backup.
After correcting OneDrive/disk/policy issues, use OneDrive's **Always keep on
this device** action on the backup files (or the dedicated backup folder), then
verify availability. A destination identified as local/network rather than work
OneDrive reports that pinning was not requested. Malformed/unreadable OneDrive
root metadata instead produces a pinning warning because classification failed.

For automation, the single backup result retains `Path`, `Count`, and
`CreatedUtc`, and adds `OfflinePinStatus` (`Requested`, `NotApplicable`, `Failed`),
`OfflinePinScope` (`None`, `Files`, `FolderAndFiles`), and `OfflinePinMessage`.
Scope describes the selected request targets, not a guarantee that every request
succeeded. Pinning warnings are returned explicitly rather than written to the
worker error stream as an export failure.

### Renewal and expiry checks

The helper remembers the approved thumbprints and an identity fingerprint derived from exact subject/issuer distinguished names, template-extension data, and EKUs. A newer certificate with the same fingerprint and a different thumbprint is a **possible renewal**, not an automatically approved key. Changes in issuer, subject, template data/version, or EKUs may require manual selection rather than automatic matching.

Warnings cover missing previously selected identities, possible renewals, and certificates expiring within **30 days** or already expired. The restore form checks backup health when it discovers the source. The helper's **Check renewals** button refreshes the list and warnings. It does not export automatically.

Your existing enrollment/renewal workflow can invoke:

```powershell
powershell.exe -NoProfile -STA -File "C:\Program Files\UserCertificateBackupRestore\CertificateBackup.ps1" -CheckRenewals -InputPath "{Documents}\CertificateBackups"
```

`-CheckRenewals` opens the helper only when attention is needed; a current, healthy managed selection returns without opening a form. It still requires explicit approval and a password to export. `-ExpiryWarningDays` can change the helper's warning window (1-365 days; default 30). Managed `ExpiryWarningDays` overrides the helper parameter and the restore form's default 30-day window.

**No enrollment hook or scheduled task is registered automatically.** The issuing/enrollment mechanism is not known here. Connect the command to its successful-enrollment/renewal step while the private key still works, before first sign-out. A periodic check may be added through approved deployment tooling as a secondary safeguard, running as the user in an interactive session—not SYSTEM. A sign-in-only backup can be too late for the FSLogix key-persistence issue.

There is no PIN or stored-password mechanism. Do not put a short PIN on a PFX or store its password alongside it. Fully unattended backups require a separately reviewed, approved credential-storage design; this version intentionally prompts.

## Startup for one user

Run from a stable location, enable the startup checkbox, and save. This sets:

`HKCU\Software\Microsoft\Windows\CurrentVersion\Run\UserCertificateBackupRestore`

The command invokes Windows PowerShell with `-NoProfile -STA -WindowStyle Hidden -File "<script>" -Startup -DefaultInputPath "<fallback>"`, without a policy override. Custom fallback parameters are retained when saving per-user startup. A newly remembered folder lives in `HKCU\Software\UserCertificateBackupRestore\InputPath`; only the folder is stored. Optional JSON folder settings in this application's AppData folder remain a read-only fallback as described above.

Uncheck and save to disable per-user startup. Moving the script requires saving again.

## Startup for every user on an FSLogix host

Deploy to each Entra-joined/FSLogix session host using your approved administrative tooling. `Deploy-UserCertificateBackupRestore.ps1` directly copies the five runtime scripts, both banners/icons, and policy templates into `%ProgramFiles%\UserCertificateBackupRestore`; there is no separate installation script. It creates/replaces `User Certificate Backup & Restore.lnk` in the common Windows Startup folder for **every interactive sign-in**, plus **Restore certificates** and **Back up certificates** under the all-users **Start > User Certificate Backup & Restore** folder, with action-specific icons. The manual shortcuts use hidden-console STA PowerShell without `-Startup`, so their forms can close normally when idle. The backup helper is not automatically run at sign-in. Development does not install these shortcuts on this shared machine.

| Shortcut location/name | Script under `%ProgramFiles%\UserCertificateBackupRestore` | Sign-in mode |
| --- | --- | --- |
| Common Startup: `User Certificate Backup & Restore.lnk` | `CertificateSignIn.ps1` | `-Startup` |
| Common Programs: `User Certificate Backup & Restore\Restore certificates.lnk` | `CertificateSignIn.ps1` | No |
| Common Programs: `User Certificate Backup & Restore\Back up certificates.lnk` | `CertificateBackup.ps1` | No |

All three target `%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe`,
with the quoted `.ps1` path in their `-File` arguments and
`%ProgramFiles%\UserCertificateBackupRestore` as their working directory. Seeing
**powershell.exe** in shortcut properties is correct: it is the script host,
not the retired application executable. No current shortcut launches
`CertificateSignIn.exe`. That name remains only in legacy migration/cleanup
guidance and ownership checks. Re-run deployment on existing hosts to refresh
their shortcuts; source changes alone do not update previously installed links.

Install and uninstall also remove old `Certificate Sign-In` and
`Certificate Restore & Backup` shortcuts only when they target this application's
scripts/legacy EXE. Unrelated shortcuts are preserved with a warning, and old Start Menu folders are removed only when
empty. This prevents duplicate startup registrations after the rename without
removing user-customized menu contents.

Install using the standard default backup folder:

```powershell
powershell.exe -NoProfile -File ".\Deploy-UserCertificateBackupRestore.ps1"
```

Use `-DefaultInputPath` to supply a different fallback while allowing saved folder preferences. Use `-InputPath` to set the deployment folder over saved preferences; a managed registry value still takes precedence:

```powershell
powershell.exe -NoProfile -File ".\Deploy-UserCertificateBackupRestore.ps1" -InputPath 'C:\UserCertificates\%USERNAME%'
```

The shortcut runs Windows PowerShell as the interactive user, not SYSTEM. Single quotes preserve `%USERNAME%` for expansion in each user's session. UNC example: `'\\fileserver\certificates\%USERNAME%'`. Paths must not contain quotes/newlines or end with a backslash; use `C:\.` for a drive root.

**Manual alternative:** copy the runtime scripts and complete `assets` folder into an administrator-protected folder. Create a shortcut in `%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup` targeting:

```text
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
```

Arguments:

```text
-NoProfile -STA -WindowStyle Hidden -File "C:\Program Files\UserCertificateBackupRestore\CertificateSignIn.ps1" -Startup -DefaultInputPath "{Documents}\CertificateBackups"
```

Use the actual Windows directory if different. Keep the script, module, helper, artwork, and shortcuts administrator-writable only. Give each user read/write access only to their own backup folder and appropriate read access to the restore folder. A common shortcut's explicit `-InputPath` overrides that user's saved folder, but not managed registry policy; its `-DefaultInputPath` does not override saved preferences. Remembering a folder in sign-in mode never modifies startup registration. The per-user checkbox cannot disable administrator-installed common startup. Avoid enabling both mechanisms; a session-local user-specific mutex suppresses simultaneous duplicate prompts.

When replacing a deployed EXE installation, replace the common shortcut and remove only the old `CertificateSignIn.exe` and `.exe.config` after it is closed. The installer does not delete deployed binaries automatically. This workspace no longer contains the EXE version.

### Uninstallation

```powershell
.\customer\artifacts\UserCertificateBackupRestore\Deploy-UserCertificateBackupRestore.ps1 `
    -DeploymentType Uninstall -WhatIf

.\customer\artifacts\UserCertificateBackupRestore\Deploy-UserCertificateBackupRestore.ps1 `
    -DeploymentType Uninstall
```

Uninstall removes only the eleven known installed runtime/assets/template files
and three all-user shortcuts. It removes application directories only when empty,
never recursively deletes them, and rejects redirected application directories.
Unknown files (including PFX backups saved under the application directory) are
preserved. Missing files are harmless, so repeated removal is supported. Errors
such as locked files are fatal; removal is not transactional, so inspect and retry
after a partial failure.

Owned legacy shortcuts are also cleaned up during removal as described above;
unrelated legacy shortcuts remain untouched.

Certificates, private keys, PFX backups, user preferences, per-user Run entries,
HKLM/local-GPO settings, and shared PolicyDefinitions templates remain by default.
Any previously enabled per-user startup should be disabled through that user's
settings/management before removal; uninstall does not enumerate or load user
hives. It does not repair FSLogix/DPAPI or remove Azure Gallery versions.

Only when this deployment owns the settings/templates, explicitly request cleanup:

```powershell
.\customer\artifacts\UserCertificateBackupRestore\Deploy-UserCertificateBackupRestore.ps1 `
    -DeploymentType Uninstall -RemovePolicySettings -RemovePolicyTemplates
```

`RemovePolicySettings` removes only `CertificateFolder` and `ExpiryWarningDays`
(including local-GPO deletion markers), preserves other
policy entries and registry values, and updates the computer GPO version if needed.
It does not run `gpupdate`, remove other GPOs, or prevent another policy manager
from reapplying values. `RemovePolicyTemplates` removes only the application's
matching local ADMX/ADML; a different version fails explicitly rather than
deleting another deployment's templates. Shared template directories remain.
Installation parameters cannot be combined with Uninstall, and cleanup switches
cannot be used with Install.

## Maintenance and tests

Source changes need no build. Keep the scripts/tests/docs in a private organization-owned repository, review changes, run Windows PowerShell tests, sign approved releases, and deploy versioned packages with rollback. Never commit user PFX files, passwords, or signing keys. Any edit invalidates the corresponding script signature.

The repository includes a focused Pester 5 suite outside the deployable artifact.
Run it from the repository root in an approved Windows PowerShell 5.1 session
and in PowerShell 7 when available:

```powershell
Invoke-Pester -Path '.\tests\UserCertificateFolderSettings.Tests.ps1' -Output Detailed
```

The suite covers shared HKCU storage, registry types, environment references
through display/save/reopen, legacy JSON fallback, precedence, shared managed
folder policy, invalid values, write denial, source-specific wording, shortcut definitions
and launch arguments, Documents token resolution, silent KFM folder-scope/readiness
guards, conservative OneDrive pin-target selection, mocked attribute failures,
single-result/completion-message contracts, restore-file ordering/defaults,
manifest validation, explicit unverified-file confirmation, and the forms'
Remember folder/edit handlers. Native pinning is mocked; tests never pin real OneDrive content. Registry fixtures
use a uniquely named temporary HKCU test subtree and are removed afterward.
The suite does not write production application preferences, policy, or startup
entries, show Forms, or import/export certificates. It does not validate the full
backup/restore cryptography, installer lifecycle, or effective Windows policy.
The historical external `Test-Certificate*.ps1` developer scripts are not included
in this repository and their results are not repository validation.

In FederalAVD, also run the repository's artifact-authoring validator:

```powershell
& .\.github\skills\federalavd-artifact-authoring\scripts\Test-ArtifactPackage.ps1 `
    -ArtifactPath '.\customer-examples\artifacts\UserCertificateBackupRestore'
```

A no-external-payload download warning is expected. Full installation and
reinstallation under image-build SYSTEM, locked-folder behavior for two users,
all-user Start Menu/Startup delivery, and actual FSLogix sign-in cycles must be
validated on an approved representative host before broad deployment.

If Windows blocks an unsigned or downloaded script on your hosts, it must be
signed/approved through your organization's process before runtime validation.
Do not treat parser, XML, or handler checks as evidence of working native Forms.

## FSLogix pilot and limitations

1. Make a non-production PFX/P12 available on a persistent, user-protected folder/share across hosts.
2. Sign in, run/import, verify the consuming application, sign out, then sign in and reimport again.
3. Repeat across hosts/container reattachments. Confirm the app prompts each sign-in and the consuming application regains access.
4. If a network folder is initially unavailable, wait for connectivity and use **Find newest** to retry.
5. With no managed folder, remember a user-selected path in each form and relaunch
   both standalone shortcuts. Verify the shared choice follows that user across
   hosts and does not affect a second user. Check the 64-bit HKCU `InputPath`.
6. Apply `CertificateFolder`, relaunch, and verify both folder controls are
   locked to the same location. Remove it, relaunch, and confirm the shared
   remembered preference returns for both tools.
   Repeat after profile reattachment and an install/update/uninstall cycle.
7. Check the source heading and guidance for default, launch-supplied, legacy,
   HKCU, edited, and managed folders. Verify long hints wrap at supported DPI,
   percent tokens survive Remember folder, and both installed Start Menu links
   and the sign-in link run the correct script with no old application EXE target.
8. With effective silent KFM policy, start before Documents redirection completes:
   confirm `{Documents}` operations show waiting guidance and do not create an old
   local Documents backup folder. Complete work OneDrive setup/KFM, retry, and
   verify backup creates the redirected destination. Repeat with Desktop-only
   selection and no KFM policy to verify ordinary Documents is not incorrectly
   blocked. Test first-sign-in policy sequencing, stale process environment, and
   multi-business-account sessions separately.
9. Back up into a dedicated redirected `CertificateBackups` folder and verify
   the folder, new PFX, manifest, and retained versions request **Always keep on
   this device**. Repeat in Documents itself, the OneDrive root, a custom-named
   folder, and a mixed-content `CertificateBackups` folder: only the new PFX and
   manifest should be requested. Confirm local/UNC/mapped-network destinations
   are skipped. In an approved failure test, confirm pinning denial/timeout
   leaves a successful, usable backup and shows the separate warning. Verify
   OneDrive upload completion and placeholder hydration separately, including
   available disk space and an offline sign-in; a successful attribute request
   alone is not evidence that content is synchronized or offline-ready.
10. Verify the restore dropdown selects the latest validated bundle rather than
    a newer unrelated file, or the newest PFX/P12 when no manifest exists.
    Explicitly select an older/external file and check the warning and default-No
    confirmation. Cancel and confirm no import occurs. Change the selection and
    verify the password is cleared. Confirm managed folder locking still permits
    file selection within that folder, hash mismatches cannot be bypassed, and
    Find newest resets selection without silently falling back after an error.

An RSA/ECDSA signing test does not prove chain trust, EKU, revocation status, remote acceptance, or application compatibility. Unsupported PFX encryption can fail even with the right password. Expired identities are flagged, not silently accepted as valid.

Existing identities, old private-key containers, ACLs, DPAPI master keys, and FSLogix exclusions are not deleted or rewritten. Repeated imports may leave old key containers; automatic cleanup risks breaking other consumers and is not attempted. A multi-identity bundle can leave a partial import if a later provider/store operation fails.

If reimport still fails with keyset, access, or DPAPI errors, investigate the host/profile/provider configuration. Do not treat a visible certificate as success. The real FSLogix sign-out/sign-in environment is not available in this workspace.
