# Configure Edge Favorites Backup

Creates scheduled, per-user Microsoft Edge Stable favorites **HTML backups**.
By default, discovers all persistent browser-profile directories containing a
`Bookmarks` file under `%LOCALAPPDATA%\Microsoft\Edge\User Data`. Guest/System
profiles and directory links/junctions are excluded. Profiles not yet created,
with no persisted bookmarks file, or stored in a custom Edge user-data directory
are not discoverable. Each discovered profile has independent files, history,
24-hour gating; no profile contents are merged.
This is backup and manual recovery, not enterprise sync or two-way merging.
The installer runs elevated or as SYSTEM during image creation/session-host
customization; it never backs up the installer's profile.

## What it creates

- Protected code/configuration: `%ProgramData%\EdgeFavoritesBackup`.
- All-user task: `\EdgeFavoritesBackup-Logon`, delayed two minutes
  after interactive sign-in. Runs with the Users group and limited privileges.
- On sign-in, the worker registers/updates
  `\EdgeFavoritesBackup-<user SID>` with that user's interactive token,
  checks backup immediately, and schedules another check every hour (60 minutes).
  The repeating trigger has no end date. No password is stored.
- Each task attempt has a five-minute execution limit and three failure retries
  five minutes apart. Checks require a signed-in user; missed runs may execute
  when the user session becomes available. A disconnected but signed-in session
  can still run. Reconnection is not a new sign-in.
- Runtime log: `%LOCALAPPDATA%\EdgeFavoritesBackup\Backup.log`.

The per-user task ignores overlapping instances. A destination file lock also
prevents concurrent bootstrap/manual backups against the same directory.
The bootstrap permits parallel users rather than picking one interactive user
for a machine-wide daily trigger. No background PowerShell process stays alive
between checks. Future users initialize at their next interactive sign-in.
Already-signed-in users must sign out/in or run the worker with
`-RegisterUserTask` in their own session. The installer does not launch tasks.
Tasks use `-WindowStyle Hidden`, but Windows PowerShell can briefly show a
console before hiding it. Hourly checks reduce launches; they do not guarantee
a flicker-free experience. No compiled launcher or script-host wrapper is installed.

Every successful export creates UTF-8 `Latest.html` and a dated HTML file under
`History`. Defaults retain 14 dated copies, not necessarily 14 calendar days.
The default minimum backup interval is 24 elapsed hours. Check/retry times are
best-effort and do not guarantee a backup every calendar day.
Output preserves folder nesting, identifies the toolbar by its JSON root key,
HTML-encodes names/URLs, and converts timestamps to UTC 64-bit Unix seconds.
Exports are built in memory and committed by same-directory rename/replace.
Failures do not truncate the previous latest backup; a dated copy is written
before updating it. Failed writes can leave an extra dated copy until the next
successful retention pass. Source JSON must be complete, structurally valid,
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
<BackupRoot>\EdgeFavoritesBackup\<BackupSetName>\<EdgeProfileName>\
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
| `CheckIntervalMinutes` | `60` | Per-user scheduled check interval in minutes, 5-1440 |

Set names are 1-64 ASCII characters: start with a letter/digit, end with
a letter/digit/underscore/hyphen, with internal spaces/dots also permitted.
Explicit profile names must be a single valid Windows directory name; arbitrary
paths, wildcards other than the standalone `*`, and traversal are not accepted.
Reinstalling updates the protected configuration and logon task. Existing user
tasks read updated backup settings on their next run; check intervals update on
the next sign-in/`-RegisterUserTask`.

## Stage and deploy

Copy the entire example, including `scripts`, before customizing:

```powershell
Copy-Item -Recurse -Path '.\customer-examples\artifacts\Configure-EdgeFavoritesBackup' `
    -Destination '.\customer\artifacts\Configure-EdgeFavoritesBackup'
```

Run on an approved elevated Windows test host:

```powershell
.\customer\artifacts\Configure-EdgeFavoritesBackup\Configure-EdgeFavoritesBackup.ps1

# Explicit per-user share; single quotes preserve expansion for the user worker.
.\customer\artifacts\Configure-EdgeFavoritesBackup\Configure-EdgeFavoritesBackup.ps1 `
    -BackupRoot '\\files.example.test\UserBackups\%USERNAME%' -BackupSetName 'PrimaryAVD'
```

After packaging/uploading with
[Update-ImageArtifacts.ps1](../../../docs/update-image-artifacts.md), reference:

```json
{
  "name": "Configure-EdgeFavoritesBackup",
  "blobNameOrUri": "Configure-EdgeFavoritesBackup.zip",
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
module, an elevated installer, and permission for users to register their own
limited interactive tasks. WDAC/AppLocker, script-signing requirements, Task
Scheduler permissions and execution-policy enforcement may prevent operation.
The task action uses process-scoped `-ExecutionPolicy Bypass`, matching the
neighboring user-logon artifact; this does not override enforced policy. Adapt
and sign both staged scripts through the approved workflow where required.
No Windows or Edge policy settings are changed.

## User guide: restore missing favorites

These steps can be copied into a customer user guide with its backup-set name
and help-desk contact details. No reset detection or acknowledgment is required.
It does not require the backup scheduled task to perform a restore.

1. **Make your backups available.** Sign in to the correct work/school OneDrive
   account and let the existing backup files synchronize/download. Contact the
   help desk if they are missing; do not assume an empty local folder means
   there are no older cloud copies.
2. **Find the old browser profile's backup.** In File Explorer, open your
   organization's OneDrive folder, then `EdgeFavoritesBackup\AVD`. Open the
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
retention, nested/non-English favorites,
and an existing signed-in session across the 24-hour boundary. Confirm each
user task's action, repeating trigger, interactive SID, LastTaskResult and log:

```powershell
Get-ScheduledTask -TaskName 'EdgeFavoritesBackup-*'
Get-ScheduledTaskInfo -TaskName "EdgeFavoritesBackup-$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"
```

Offline tests do not prove Task Scheduler identity delivery, Edge import, SMB
atomic replacement, cloud upload or recovery. Consult task history on failures.

To remove, first unregister the logon task and the per-user tasks using their
exact inspected names (`Unregister-ScheduledTask -TaskName '<exact name>'`).
Then remove only the staged `EdgeFavoritesBackup` directory through
the approved operator process. Do not remove favorites backups unless
intentionally retiring them. Uninstall is deliberately manual.
