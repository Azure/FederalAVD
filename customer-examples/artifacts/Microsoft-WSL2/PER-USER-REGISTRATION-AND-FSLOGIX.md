# WSL Per-User Registration and FSLogix Notes

## Support position

A WSL distribution must be registered in each Windows user's context. FSLogix does not change
that requirement. WSL stores a user's distribution registration under:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss
```

Each WSL 2 distribution also has a user-specific Linux filesystem stored in an `ext4.vhdx` file.
Running a distribution registration command as SYSTEM, the image-build account, or another
administrator does not register that distribution for AVD users.

Microsoft documents WSL per-user distributions and FSLogix profile containers separately. It does
not currently document roaming a WSL `ext4.vhdx` inside an FSLogix Profile Container as a supported
scenario. Treat that combination as unvalidated until it passes customer testing and an applicable
Microsoft support statement is available.

## Registration and storage are separate concerns

WSL distribution state consists of two related parts:

1. The user's WSL registration metadata in `HKCU`.
2. The distribution filesystem, normally an `ext4.vhdx` beneath a user-specific location.

These parts must remain consistent. Do not roam the `HKCU` registration while leaving its
`BasePath` on a different session host. This can make the distribution appear registered even
though its filesystem is unavailable. Likewise, a local VHDX without matching registration
metadata is not a usable registered distribution.

When importing a custom distribution with a command such as:

```powershell
wsl.exe --import AlmaLinux-9 "$env:LOCALAPPDATA\WSL\AlmaLinux-9" $tarballPath --version 2
```

both the registration and selected install location belong to the user executing the command.

## Recommended support boundaries

| Host design | Recommended position |
| --- | --- |
| Persistent personal host without FSLogix | Preferred initial configuration. Register the distribution per user and store it locally under `%LOCALAPPDATA%`. |
| Persistent personal host with FSLogix | Possible, but FSLogix adds little value for WSL persistence when the user remains on one VM. Pilot before allowing the WSL VHDX into the container. |
| Pooled hosts without FSLogix | Treat the distribution as disposable. Reimport it when the user reaches a new or reimaged host. |
| Pooled hosts with FSLogix | Experimental until validated. Do not claim that WSL distribution state roams reliably or is Microsoft-supported. |
| Multi-session pooled hosts | Highest risk. Evaluate concurrent WSL resource use, profile growth, sign-out delays, VHD detach behavior, and user concurrency. |

The safest initial product boundary is persistent personal hosts. Pooled hosts should use disposable
distributions unless a controlled FSLogix pilot proves that the required roaming behavior is
reliable.

## FSLogix considerations

A full FSLogix Profile Container normally captures most content under the user's profile and the
user's registry hive. If a WSL distribution is imported beneath `%LOCALAPPDATA%`, the registration
metadata and `ext4.vhdx` might therefore be included in the profile container.

Inclusion does not establish support or reliability. An FSLogix Profile Container is itself a
VHD/VHDX mounted from remote storage, while WSL adds a dynamically expanding `ext4.vhdx` inside
that profile. Validate at least these risks:

- WSL must fully close the Linux VHD before FSLogix detaches the profile.
- A disconnected or terminated session might leave WSL processes active.
- A host crash or forced sign-out might leave the Linux filesystem requiring repair.
- FSLogix compaction, backup, restore, and profile replication must preserve the nested VHDX.
- Profile attach, detach, sign-in, and sign-out durations can increase as the distro grows.
- Antivirus, DLP, or backup products might scan or lock either VHDX.
- The same user must not mount the same WSL distribution from concurrent sessions on different hosts.
- The WSL registration `BasePath` must remain valid after moving between hosts.
- Storage capacity and IOPS must account for realistic Linux development workloads.

Do not interpret a successful FSLogix profile attachment or `wsl.exe --list` result as proof that
the Linux filesystem roamed safely. A validation must launch the distribution, exercise file I/O,
and check filesystem integrity after host transitions and failure scenarios.

## Active Setup behavior

Active Setup is useful for initial registration because it runs after the user's profile is loaded
and executes in that user's context. It is not sufficient by itself for a host-local, disposable
distribution design.

For example:

1. The user signs in to host A and Active Setup imports the distribution.
2. Active Setup records completion in the user's profile.
3. The user signs in to host B with the same roaming profile.
4. Active Setup does not rerun, but a host-local distribution from host A is unavailable on host B.

For pooled hosts with host-local storage, use an idempotent per-logon check instead of relying only
on Active Setup. At each sign-in, verify:

- The expected distribution appears in `wsl.exe --list --quiet`.
- Its registered `BasePath` exists on the current host.
- The expected `ext4.vhdx` exists.
- The distribution starts successfully.

If validation fails, the process should safely remove stale registration, clean an abandoned install
location when appropriate, and import the approved image again. A failed Active Setup registration
also needs a retry mechanism because Active Setup can record completion even when its command fails.

## Recommended deployment pattern

1. Install the WSL platform in the gold image using the `EnablePlatform` phase.
2. Restart before distribution provisioning.
3. Stage the approved distribution image under a protected `C:\ProgramData\WSL` directory.
4. Grant Users read and execute access only; retain full control for SYSTEM and Administrators.
5. Register or import the distribution as the signed-in user, never as SYSTEM.
6. Keep registration metadata and the Linux filesystem together under one defined persistence model.
7. Configure retry and idempotent validation for first-logon failures.
8. Patch Linux user space separately from Windows Update.
9. Document whether the distribution is persistent, disposable, or customer-validated with FSLogix.

Do not commit customer distribution images, credentials, activation keys, or exported Linux
filesystems to this repository. Copy and customize this example under the git-ignored
`customer\artifacts\Microsoft-WSL2` directory.

## FSLogix pilot test plan

Use nonproduction hosts and realistic distribution sizes. Test at least:

1. First sign-in and distribution import on host A.
2. Clean distribution shutdown and Windows sign-out.
3. Sign-in and distribution launch on host B.
4. Return to host A and confirm file and registration consistency.
5. Disconnect followed by administrative logoff.
6. Session host restart after WSL activity.
7. Forced session termination and simulated host failure.
8. FSLogix VHD compaction.
9. Profile backup and restore.
10. Profile-container storage failover when applicable.
11. Same-user concurrent-session prevention.
12. Distro growth to a representative production size.
13. Antivirus, Defender, DLP, and backup interaction.
14. Linux package update and repository access behavior.
15. Sign-in, sign-out, profile attach, and profile detach duration.
16. Linux file creation, modification, restart, and checksum verification across hosts.
17. Filesystem checks after interrupted or failed sessions.

Record the Windows version, WSL version, FSLogix version and settings, VM size, security type,
profile storage type, distribution image hash, test results, and failure-recovery steps. Until this
pilot succeeds and supportability is established, describe FSLogix roaming as experimental rather
than supported.

## References

- <https://learn.microsoft.com/windows/wsl/enterprise>
- <https://learn.microsoft.com/windows/wsl/basic-commands>
- <https://learn.microsoft.com/windows/wsl/disk-space>
- <https://learn.microsoft.com/fslogix/concepts-container-types>
- <https://learn.microsoft.com/fslogix/concepts-vhd-disk-compaction>
- <https://learn.microsoft.com/fslogix/troubleshooting-known-issues>
