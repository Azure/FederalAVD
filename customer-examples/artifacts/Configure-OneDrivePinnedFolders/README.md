# Configure OneDrive Pinned Folders

Installs an **embedded user-logon script** that requests OneDrive "Always available"
pinning for selected folders. An **all-user sign-in scheduled task** launches it
without elevation in the signing-in user's context. The artifact installer runs
elevated or as SYSTEM; it does not pin folders in the installer's profile.

## What it creates

- Script: `$env:ProgramData\Scripts\Pin-OneDriveFolders.ps1`.
- Scheduled task: `\OneDrivePinnedFolders`.
- Per-user runtime log: `$env:TEMP\OneDrivePinnedFolders.log`.

The log uses the signing-in user's temp directory. Whether that directory is
outside the profile disk depends on the host's temp redirection and profile
configuration; temporary files are not guaranteed to be cleaned automatically.

The task is triggered at **every interactive sign-in**, including future users:

- **Delay:** 60 seconds after sign-in, subject to Task Scheduler availability.
- **Execution limit:** 30 minutes per attempt, not including the initial delay.
- **Failure retries:** up to three retries, one minute apart (four attempts total).
- **Identity:** built-in Users group (`S-1-5-32-545`), limited privileges, no stored
  password. The logon trigger does not specify a particular user.
- **Concurrent sessions:** parallel instances allow different AVD users to run
  without blocking each other; this does not suppress overlapping runs for the
  same user.

The installer does not start the task immediately. Reconnecting to an existing
session is not a fresh sign-in trigger. Retries require an available user session.
Task Scheduler, enterprise policy, WDAC/AppLocker and PowerShell enforcement can
still prevent execution. The action retains `-WindowStyle Hidden`; a scheduled
task does not guarantee there will be no console flash. No WScript/CScript launcher
is used. Validate behavior with your actual AVD shell.

## Parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `Folders` | `string[]` | Required | Nonempty folder paths relative to the user's OneDrive for Business root; nested paths are supported |
| `WaitTimeoutSeconds` | `int` | `900` | Wait for the root, and separately for each folder; 1-86400 seconds |
| `RetryIntervalSeconds` | `int` | `10` | Readiness polling interval; 1-300 seconds |

Absolute paths, traversal (`..`), wildcards and invalid Windows path components
are rejected. Parameter values are written directly into the generated script's
`param` block as readable defaults, without JSON or Base64 encoding. Single quotes
in folder names are escaped so the names remain literal strings, not executable
code. Non-ASCII characters use `[char]` expressions to keep the script ASCII-only.
Do not pass secrets. The generated script also accepts these named parameters for
a manual per-user test, overriding the staged defaults.

On each sign-in, the script:

1. Checks the user's `OneDriveCommercial` environment value and then the
   `UserFolder` value under `HKCU\Software\Microsoft\OneDrive\Accounts\Business1`.
2. Polls until a usable OneDrive root exists, including when account setup was
   incomplete at sign-in. It rechecks the registry rather than relying solely on
   an environment variable that may not be refreshed in the running process.
3. Waits for each requested folder to exist; it does not create missing folders.
4. Runs `attrib +p -u` on the folder and, when nonempty, `attrib +p -u <folder>\* /s /d`
   on its existing contents. Pinning can trigger downloads and consume local disk.
5. Logs the outcome. A readiness timeout or failed command throws a terminating
   error, giving Task Scheduler a failed PowerShell exit code for failure retries.
   Download completion is asynchronous.

The root and each folder have separate 15-minute readiness waits by default, but
the task's **30-minute overall execution limit takes precedence**. A failure stops
that attempt, so a later folder is not processed after a timeout. Scheduler-forced
termination may prevent a final log entry; inspect task history as well as the
user log. Each retry starts the script from the beginning. Manual script execution
does not have the scheduler's 30-minute cap or automatic retries.

## Prerequisites and staging protection

- A supported 64-bit Windows session host with Windows PowerShell 5.1, the built-in
  ScheduledTasks module, and the Task Scheduler service enabled.
- OneDrive installed, Files On-Demand enabled, and a business account configured
  for the user. This does not install OneDrive, sign users in, sync new libraries,
  or target personal accounts. Registry fallback selects `Business1` only.
- An elevated installer or SYSTEM execution. No user files are pinned during the
  image build or SYSTEM customization.

The installer creates `ProgramData\Scripts` with SYSTEM/Administrators full control
and Users read/execute. If it already exists, the installer **does not change its
ACL**: it requires SYSTEM/Administrators ownership and no write/delete/control
permissions for other principals. It rejects junctions, symbolic links and unsafe
existing staged files. Correct an unsafe shared directory deliberately before
retrying; do not make a logon script writable by ordinary users.

Reapplying the artifact updates the same script and scheduled task with new parameters;
already-running user-script processes retain their previous configuration.
After successful task registration, the installer removes only the legacy HKLM
Run values `OneDrivePinnedFolders` and `FederalAVD-OneDrivePinnedFolders`, if
present, to avoid duplicate launches. Other startup entries are untouched.
The task action uses Windows PowerShell with a process-scoped
`-ExecutionPolicy Bypass`. This does not override enforced Group Policy or
application control. If script signing is required, adapt and sign the generated
file through your approved workflow instead of weakening host policy.

## Add and use the artifact

Copy this reference to the git-ignored customer folder before customizing:

```powershell
Copy-Item -Recurse `
    -Path '.\customer-examples\artifacts\Configure-OneDrivePinnedFolders' `
    -Destination '.\customer\artifacts\Configure-OneDrivePinnedFolders'
```

All payload code is embedded in the root script. **No installer, download URL,
downloads.json entry or external PowerShell module is required.** For offline
transfer, stage this complete folder or its approved ZIP. OneDrive pinning itself
still requires the user's supported OneDrive service connectivity; this is not
an air-gapped OneDrive solution.

Run directly on an approved elevated test host:

```powershell
.\customer\artifacts\Configure-OneDrivePinnedFolders\Configure-OneDrivePinnedFolders.ps1 `
    -Folders @('Documents\jsignout', 'Documents\cspid', 'Shared Documents\Reports') `
    -WaitTimeoutSeconds 900 -RetryIntervalSeconds 10
```

After packaging/uploading with `Update-ImageArtifacts.ps1`, use the same array
syntax in an image-build `customizations` or standard host-pool
`sessionHostCustomizations` entry:

```json
{
  "name": "Configure-OneDrivePinnedFolders",
  "blobNameOrUri": "Configure-OneDrivePinnedFolders.zip",
  "arguments": "-Folders @('Documents\\jsignout', 'Documents\\cspid') -WaitTimeoutSeconds 900 -RetryIntervalSeconds 10",
  "successExitCodes": "0"
}
```

Nested paths are relative to the OneDrive root: `Documents\jsignout` targets
`<OneDrive root>\Documents\jsignout`. Use a single backslash in PowerShell and
escape it as `\\` inside a JSON string.

Use this as image/provisioning configuration, not a VM Application. See the
[artifact argument contract](../../../docs/artifacts-guide.md#key-implementation-details).

## Verification and removal

On a test host, inspect the staged script and task definition as administrator:

```powershell
Get-ScheduledTask -TaskName 'OneDrivePinnedFolders' -TaskPath '\'
Get-ScheduledTaskInfo -TaskName 'OneDrivePinnedFolders' -TaskPath '\'
Export-ScheduledTask -TaskName 'OneDrivePinnedFolders' -TaskPath '\'
```

Confirm the exported definition has a logon trigger with `PT60S` delay, a Users
group principal with limited privileges, parallel instances, `PT30M` execution
limit, and restart-on-failure count `3` with interval `PT1M`.

Then sign in as a **standard user**, wait for the delay, check the per-user log
and use `attrib` or OneDrive's status column to verify pinning. Test two concurrent
standard users and confirm each process uses the correct user's identity,
HKCU, OneDrive root and temp directory. Also test first sign-in, delayed account
setup, empty/nested folders, repeated sign-ins and a missing folder. On an isolated
test host, force a failure and an overlong attempt to verify retry timing,
the three-retry limit and 30-minute termination, including scheduler behavior
after a forced timeout. Check actual disk use and download completion, not just
exit code. Offline tests validate the definition, not these live behaviors.

To disable future launches, run this elevated on the target host:

```powershell
Unregister-ScheduledTask -TaskName 'OneDrivePinnedFolders' -TaskPath '\' `
    -Confirm:$false -ErrorAction Stop
Remove-Item -LiteralPath "$env:ProgramData\Scripts\Pin-OneDriveFolders.ps1" -ErrorAction Stop
```

Do not delete the shared `Scripts` directory. Removal does not stop existing
processes, remove user logs, or unpin previously pinned content. Unpinning is a
separate user-data decision.

## Microsoft references

- [Logon triggers and group principals](https://learn.microsoft.com/windows/win32/taskschd/logontrigger).
- [Logon trigger delay](https://learn.microsoft.com/windows/win32/taskschd/logontrigger-delay).
- [Task settings, execution limits and failure retries](https://learn.microsoft.com/powershell/module/scheduledtasks/new-scheduledtasksettingsset).
- [Set Files On-Demand states in Windows](https://learn.microsoft.com/sharepoint/files-on-demand-windows).
- [attrib command](https://learn.microsoft.com/windows-server/administration/windows-commands/attrib).
