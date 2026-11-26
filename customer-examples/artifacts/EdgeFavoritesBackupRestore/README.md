# Edge Favorites Backup & Restore

Creates automatic Microsoft Edge Stable favorites **HTML backups** and
**self-service selective recovery** through guided Edge HTML import.
By default, discovers all persistent browser-profile directories containing a
`Bookmarks` file under `%LOCALAPPDATA%\Microsoft\Edge\User Data`. Guest/System
profiles and directory links/junctions are excluded. Profiles not yet created,
with no persisted bookmarks file, or stored in a custom Edge user-data directory
are not discoverable. Each discovered profile has independent files, history,
24-hour gating; no profile contents are merged.
This is backup and user-directed recovery, not enterprise sync or two-way merging.
The installer runs elevated or as SYSTEM during image creation/session-host
customization; it never backs up the installer's profile.

## What it creates

- Protected code/configuration: `%ProgramData%\EdgeFavoritesBackupRestore`.
- Adjacent all-user Start-menu shortcuts under **Edge Favorites**:
  **Back Up Edge Favorites** and **Restore Edge Favorites**. Both run as the
  signed-in user, without elevation. No desktop shortcuts are created.
- All-user task: `\EdgeFavoritesBackupRestore-Logon`, delayed two minutes
  after interactive sign-in. Runs with the Users group and limited privileges.
- The worker checks backup once and exits. No per-user task, repeating trigger,
  stored password, or persistent background worker is created.
- Each task attempt has a five-minute execution limit and three failure retries
  five minutes apart. Checks require a signed-in user. Reconnection is not a new
  sign-in and does not trigger a new backup.
- Runtime log: `%LOCALAPPDATA%\EdgeFavoritesBackupRestore\Backup.log`.

The single shared task permits parallel sign-ins so each user gets a check in
their own context. A destination file lock prevents concurrent logon/manual
backups against the same directory. The task count does not grow with the number
of users who visit a host. Future users need no task registration permissions.
Already-signed-in users must sign out/in or run the worker once in their own
session. The installer does not launch tasks.
Tasks use `-WindowStyle Hidden`, but Windows PowerShell can briefly show a
console before hiding it. Logon-only checks reduce launches; they do not guarantee
a flicker-free experience. No compiled launcher or script-host wrapper is installed.

Every successful export creates UTF-8 `Latest.html` and a dated HTML file under
`History`. Defaults retain 14 dated copies, not necessarily 14 calendar days.
The default minimum backup interval is 24 elapsed hours. Check/retry times are
best-effort and do not guarantee a backup every calendar day.
This design assumes users sign out regularly, such as daily. It does not back up
at sign-out or periodically during a session. Changes made after the logon check
wait until a later eligible sign-in or an explicit **Back Up Edge Favorites** run. A sign-in
less than 24 hours after the previous export skips that export, even on a new
calendar day. Choose a smaller `BackupIntervalHours` if daily sign-ins can be
closer together. Profile loss before the next eligible check can lose those
unexported changes.
Output preserves folder nesting, identifies the toolbar by its JSON root key,
HTML-encodes names/URLs, and converts timestamps to UTC 64-bit Unix seconds.
Exports are built in memory and committed by same-directory rename/replace.
Failures do not truncate the previous latest backup; a dated copy is written
before updating it. Failed writes can leave an extra dated copy until the next
successful retention pass. The backup shortcut bypasses only the age gate; empty/invalid-source checks,
destination locking and retention still apply. Each successful forced backup consumes a
dated history slot. Source JSON must be complete, structurally valid,
and contain at least one favorite.

## Destination and recovery safeguards

**The default backup root is `$env:OneDriveCommercial`**, resolved in the
signing-in user's session, not in the elevated/SYSTEM installer's environment.
No `BackupRoot` argument is needed for the default OneDrive behavior.

With no `BackupRoot`, discovery uses the current user's `OneDriveCommercial`,
then the `UserFolder` values of configured OneDrive business accounts. Ambiguous
accounts require an explicit root. Personal OneDrive and guessed folder names
are not used. The destination root **must already exist**; only artifact-owned
subdirectories are created:

```text
<BackupRoot>\EdgeFavoritesBackupRestore\<BackupSetName>\<EdgeProfileName>\
  Latest.html
  History\Favorites-<UTC timestamp>-<unique ID>.html
  Backup.lock
```

For an explicit root, `%ENVIRONMENT_VARIABLE%` references are expanded in the
user context, not during installation. Use a user-private location with suitable
ACLs; a shared UNC root must include a per-user component. Favorites can contain
sensitive titles/URLs. Use only approved storage in the same authorized security
boundary. This artifact does not upload data or configure OneDrive, sharing,
classification transfer, encryption, or storage permissions.

OneDrive must be configured and actually syncing. A local folder's existence
does not prove upload, hydration, or cloud recovery completion. Ensure the old
backup has synchronized and is available **before** the first worker run on a
recreated profile. If it has not arrived yet, the worker cannot detect a remote
backup and may create a new local backup. Use storage versioning/retention too.
Do not treat this example as protection against delayed cloud conflict resolution.

### What happens when a profile is reset?

There is no reset detector, local recovery marker, acknowledgment command, or
manual resume step. The worker keeps checking normally:

- Missing, malformed, or **empty** favorites fail that profile's attempt without
  changing `Latest.html` or pruning dated history.
- Once the user imports favorites or creates new ones, nonempty valid favorites
  are automatically exported when the normal 24-hour age gate permits.
- A reset that leaves nonempty default favorites is not distinguishable from
  valid user data. It can replace `Latest.html` when due; use dated history to
  recover favorites from before the reset.
- If Edge uses a different directory, such as `Profile 1` instead of `Default`,
  it gets its own namespace. Old profile directories are not automatically
  matched or pruned. Import from the old directory into the intended new profile.

**Yes, dated backups remain useful even if a reset is not detected.** A new
successful export does not immediately delete every older export. However,
`HistoryCount=14` retains only the newest 14 successful exports, not a permanent
pre-reset copy or a guaranteed 14-day recovery window. After 14 later successful
exports, all earlier history can have aged out. Missing/empty/invalid sources
do not reach the history-pruning step.

Restore promptly and first copy the selected recovery file somewhere outside
`History`. Intentional favorites deletion can look like data loss, so the script
does not guess which old file to restore or silently undo user changes.
The [user restoration guide](#user-guide-restore-missing-favorites) below covers
profile resets without requiring reset detection. This is not a replacement
for FSLogix/container or storage backups.

Use a distinct `BackupSetName` for independently edited profiles/devices/pools.
Only one logical source should write each user/set/profile namespace.
OneDrive locks on separate devices are not distributed locks. This package does
not merge changes, propagate deletions, back up passwords/history, or modify live
Edge files. A failed profile is logged and other discovered
profiles are still processed. Any failure makes the overall task fail for retry.

## Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `BackupRoot` | User's business OneDrive | Omit/leave empty to resolve `OneDriveCommercial` at user runtime; optionally specify an existing per-user root |
| `BackupSetName` | `AVD` | Unique logical backup namespace |
| `EdgeProfileName` | `*` | Discover all persistent profiles, or select a directory such as `Default` or `Profile 1` |
| `BackupIntervalHours` | `24` | Minimum successful-backup age, 1-8760 hours |
| `HistoryCount` | `14` | Dated copies retained, 1-365 |

Set names are 1-64 ASCII characters: start with a letter/digit, end with
a letter/digit/underscore/hyphen, with internal spaces/dots also permitted.
Explicit profile names must be a single valid Windows directory name; arbitrary
paths, wildcards other than the standalone `*`, and traversal are not accepted.
Reinstalling updates the protected configuration and logon task and removes
legacy per-user tasks whose SID-based name and action match the installed worker.
Running legacy tasks are stopped first; backups and user profiles are not deleted.
Modified actions are left intact with a warning for operator review.
`CheckIntervalMinutes` and the worker's `-RegisterUserTask` switch have been removed:
remove these arguments from older customization/manual commands. Old configuration
files containing `CheckIntervalMinutes` are readable, but do not schedule checks.

## Stage and deploy

Copy the entire example, including `scripts`, before customizing:

The package/ZIP name, installed folder, task prefix, local logs, and backup
namespace are `EdgeFavoritesBackupRestore`. This is a new install namespace,
not a compatibility alias. Existing backups are not moved or searched
automatically. On an existing host, remove the older package's scheduled tasks
through the approved operator process before installing this version; preserve
or explicitly migrate any recovery snapshots you still need.

```powershell
Copy-Item -Recurse -Path '.\customer-examples\artifacts\EdgeFavoritesBackupRestore' `
    -Destination '.\customer\artifacts\EdgeFavoritesBackupRestore'
```

Run on an approved elevated Windows test host:

```powershell
.\customer\artifacts\EdgeFavoritesBackupRestore\Deploy-EdgeFavoritesBackupRestore.ps1

# Explicit per-user share; single quotes preserve expansion for the user worker.
.\customer\artifacts\EdgeFavoritesBackupRestore\Deploy-EdgeFavoritesBackupRestore.ps1 `
    -BackupRoot '\\files.example.test\UserBackups\%USERNAME%' -BackupSetName 'PrimaryAVD'
```

After packaging/uploading with
[Update-ImageArtifacts.ps1](../../../docs/update-image-artifacts.md), reference:

```json
{
  "name": "EdgeFavoritesBackupRestore",
  "blobNameOrUri": "EdgeFavoritesBackupRestore.zip",
  "arguments": "-BackupSetName 'PrimaryAVD' -HistoryCount 14",
  "successExitCodes": "0"
}
```

Use an image-build or session-host customization, not a VM Application. No
external payload, download command, `downloads.json` entry, third-party module,
or runtime internet download is required. Offline transfer: stage this complete
folder/approved ZIP. OneDrive still needs its supported service connectivity;
isolated networks must use an existing approved per-user local/UNC destination.
This does not make OneDrive available in Secret/Top Secret.

Requires 64-bit Windows, Windows PowerShell 5.1, the built-in ScheduledTasks
module and an elevated installer. Users do not register tasks.
WDAC/AppLocker, script-signing requirements, Task
Scheduler permissions and execution-policy enforcement may prevent operation.
The task action uses process-scoped `-ExecutionPolicy Bypass`, matching the
neighboring user-logon artifact; this does not override enforced policy. Adapt
and sign all staged scripts through the approved workflow where required.
No Windows or Edge policy settings are changed.

## Startup troubleshooting and existing installations

The shared logon task passes the installed configuration path explicitly:
`%ProgramData%\EdgeFavoritesBackupRestore\Configuration.json`. A manual worker run
without `-ConfigurationPath` resolves the JSON beside the script file after
initializing the user log. It does not resolve `$PSScriptRoot` during parameter
binding. If no script directory is available, the worker logs a clear error
rather than guessing a configuration location.

An older worker can report `Join-Path: Cannot bind argument to parameter 'Path'
because it is an empty string` at its configuration parameter, before creating
`Backup.log`. Run the actual installed script file rather than pasting/evaluating
its contents. In the affected user's normal, non-elevated session, after OneDrive
setup and any existing backup synchronization, explicitly pass the configuration:

```powershell
& "$env:ProgramData\EdgeFavoritesBackupRestore\Backup-EdgeFavorites.ps1" `
    -ConfigurationPath "$env:ProgramData\EdgeFavoritesBackupRestore\Configuration.json"
```

This attempts the normal backup immediately without registering a task.
Add `-ForceBackup` to bypass the age gate, as the backup shortcut does.
It does not change execution policy or access live Edge data as
SYSTEM. If organizational script policy blocks it, use the approved signing
workflow rather than bypassing policy.

For the permanent update, repackage this artifact and rerun its updated
installer elevated on existing hosts with the original parameter values
(no arguments if defaults were used). Updating the repository, uploaded ZIP,
or source image alone does not replace a worker already installed on a host.
The installer replaces the protected worker/configuration and updates the
logon task and removes matching legacy user tasks; it does not start a backup
in the elevated context. Reinstallation is required on each existing host to
remove task accumulation; replacing only the worker does not remove old tasks.
Test the delayed logon trigger at the next interactive sign-in.

No user log can also mean the task did not launch, ran in the wrong context,
or failed before log initialization. `2147942401` is `0x80070001` (Win32
`Incorrect function`); that code alone does not identify a OneDrive failure.
Inspect the failing task's action, principal, and Task Scheduler history, then
check `%LOCALAPPDATA%\EdgeFavoritesBackupRestore\Backup.log` in the affected user's
session. Do not create a guessed OneDrive root to mask a startup error.

## User guide: restore missing favorites

These steps can be copied into a customer user guide with its backup-set name
and help-desk contact details. No reset detection or acknowledgment is required.
It does not require the backup scheduled task to perform a restore.

### On-demand shortcuts

Open **Start > Edge Favorites > Back Up Edge Favorites** to immediately export
all configured profiles. The completion dialog reports successful file writes,
not confirmed OneDrive upload. If any profile fails, an error dialog appears;
other profiles may already have succeeded. Review
`%LOCALAPPDATA%\EdgeFavoritesBackupRestore\Backup.log` for per-profile results.
Do not use **Run as administrator**.

Open **Start > Edge Favorites > Restore Edge Favorites** to prepare recovery:

1. Make the old backups available in the configured storage first.
2. Choose a snapshot from the list. It includes `Latest.html` and dated history
   from every stored profile in the configured backup set, even when those
   browser profiles no longer exist locally. Dates are UTC; Latest shows its
   file timestamp, which synchronization can change, not a verified export time.
3. Inspect the favorite count and folder tree. Hover over a favorite for its URL.
   Check individual favorites or a whole folder to select its descendants.
   Unchecking a folder clears its descendants. A folder checkbox is not a
   tri-state summary; only checked favorites are included. Nothing is selected
   by default, and no links are opened or HTML executed.
4. Select **Prepare selected favorites**. Copy the displayed `Selected.html`
   path into Edge's file picker for the HTML import described below. Select the
   intended destination Edge profile yourself. The helper does not automate
   browser controls, replace browser files, or bypass import restrictions.
5. Verify the imported favorites. Import may add an Imported folder or duplicates;
   this helper does not compare against live favorites or deduplicate imports.

Each preparation writes a new unique directory under
`%LOCALAPPDATA%\EdgeFavoritesBackupRestore\Recovery`, containing the full selected
snapshot as `Source.html` and the selected subset as `Selected.html`. These
copies are outside rotating backup history, but remain in the local Windows
profile and can be lost with it. Preserve them in approved durable storage
when needed; they are not automatically synchronized or pruned. Preparation
uses the snapshot loaded into the form even if the original history file later
changes or is pruned. Reopen the form to refresh the snapshot list.

The helper accepts HTML produced by this package, including existing snapshots,
not arbitrary browser exports. Corrupt or unsupported files, unavailable
storage, and hydration/read failures are reported explicitly. An empty local
listing is not proof that no cloud backups exist. Helper errors and preparation
events are logged in `%LOCALAPPDATA%\EdgeFavoritesBackupRestore\Recovery.log`.
No downloads, extension, web service, or external parser is required; Windows
PowerShell 5.1 and Windows Forms are used.

### Artwork

Both shortcuts use distinct multi-resolution icons: a favorites star and browser
window with a download-to-tray badge for backup or a return-arrow badge for
restore. The restoration form uses matching Edge-inspired blue/cyan/teal/green
gradients and flowing shapes, with its own window
icon. Banner text remains actual Windows labels rather than text embedded in the
image; high-contrast mode uses system colors and omits the decorative banner.
The form keeps its existing window dimensions, with a scrollable favorites tree.

Original artwork is bundled under `scripts\assets` and staged into the protected
`%ProgramData%\EdgeFavoritesBackupRestore\assets` directory. Copy the complete package
and reinstall on existing hosts to update shortcut icons. No runtime downloads
or artwork generation are performed, including in disconnected environments.
To regenerate the PNG banner and 16/24/32/48/64/128/256-pixel ICO frames locally:

```powershell
& .\customer-examples\artifacts\EdgeFavoritesBackupRestore\scripts\assets\New-FavoritesArtwork.ps1
```

### Manual recovery without the helper

1. **Make your backups available.** Sign in to the correct work/school OneDrive
   account and let the existing backup files synchronize/download. Contact the
   help desk if they are missing; do not assume an empty local folder means
   there are no older cloud copies.
2. **Find the old browser profile's backup.** In File Explorer, open your
   organization's OneDrive folder, then `EdgeFavoritesBackupRestore\AVD`. Open the
   relevant browser-profile folder, for example `Default` or `Profile 1`.
   Your administrator may have selected a different backup root or set name.
   If several profiles exist, ask the help desk which folder contains your
   missing favorites. Display names do not reliably identify old directories.
3. **Choose and preserve a recovery file.** Use `Latest.html` if it still contains
   the desired favorites. Otherwise open `History` and select a dated HTML file
   from **before** the loss/reset. Filenames contain UTC timestamps. Copy the
   chosen file to a separate approved folder outside `History` before continuing.
   You can inspect a copy in a browser to check titles/folders; open only trusted
   links. Import one suitable recovery file, not every dated file.
4. **Select the correct Edge profile.** Open Edge and use the profile icon to
   select the profile that should receive the recovered favorites.
5. **Import the saved HTML file.** Open **Settings > Profiles > Import browser
   data**. In the import dialog, choose **Favorites or bookmarks HTML file**,
   select **Choose file**, and select the recovery copy from step 3. Wording and
   placement may vary by Edge version; the
   [Microsoft import instructions](https://support.microsoft.com/en-us/edge/import-your-favorites-and-passwords-in-microsoft-edge)
   describe the supported process. Organizational policy may restrict imports;
   contact the help desk rather than trying to bypass it.
6. **Verify the result.** Check folders and several expected favorites. Import
   adds favorites rather than reverting the whole browser and may create an
   imported folder or duplicates. Repeat only for other profiles that need
   recovery, selecting each profile's own backup.
7. **Let backups continue automatically.** No PowerShell or acknowledgment is
   needed after import. A new export occurs on the next successful scheduled
   check for which the latest backup is at least 24 hours old. Keep your separate
   recovery copy until you have confirmed a new backup contains the restored
   favorites. Ask the help desk if a new backup does not appear when expected.

No unattended HTML importer or direct Bookmarks-file replacement is used.

Microsoft confirms that
[Edge enterprise sync does not support GCC High/DoD](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-enterprise-sync).
[FSLogix Profile containers](https://learn.microsoft.com/en-us/fslogix/how-to-configure-profile-containers)
preserve the Windows profile within the same container; they do not merge
independently edited browser profiles. Microsoft documents
[HTML favorites import](https://support.microsoft.com/en-us/edge/import-your-favorites-and-passwords-in-microsoft-edge).
The separate [AD on-premises sync mechanism](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-on-premises-sync)
uses `profile.pb`, has identity/concurrency restrictions, and is not configured here.

## Validate and remove

On a representative multi-user AVD host, test two independent users, delayed
OneDrive setup, unavailable shares, profile recreation with the backup already
present, empty-profile rejection and automatic resumption after manual import,
retention, nested/non-English favorites, and daily sign-out/sign-in.
Also test both Start-menu shortcuts as a standard user: immediate backup within
the age gate, snapshot discovery after profile recreation, unavailable/unhydrated
files, folder/individual selection, preserved full snapshots, and importing the
selected subset into the intended Edge profile. Verify no unselected favorites
are imported and no existing favorites are removed. Test localized/scaled
Windows UI and policy-restricted imports; offline tests do not prove this UX.
Confirm the shared task's action, delayed logon trigger, limited Users-group
principal, LastTaskResult and each user's log. Sign in with multiple distinct
users and verify the host still has just one artifact task and no worker remains
after the check. On an upgraded host, verify matching legacy tasks were removed:

```powershell
Get-ScheduledTask -TaskName 'EdgeFavoritesBackupRestore-*'
Get-ScheduledTaskInfo -TaskName 'EdgeFavoritesBackupRestore-Logon'
```

Offline tests do not prove Task Scheduler identity delivery, Edge import, SMB
atomic replacement, cloud upload or recovery. Consult task history on failures.

To remove, first unregister the logon task and any remaining legacy tasks using their
exact inspected names (`Unregister-ScheduledTask -TaskName '<exact name>'`).
Remove the two shortcuts in the all-user Start-menu `Edge Favorites` folder.
Then remove only the staged `EdgeFavoritesBackupRestore` directory through
the approved operator process. Do not remove favorites backups unless
intentionally retiring them. Uninstall is deliberately manual.
