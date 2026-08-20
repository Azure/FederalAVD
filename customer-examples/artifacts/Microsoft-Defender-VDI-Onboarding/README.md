# Microsoft Defender for Endpoint VDI Onboarding

Stages Microsoft's tenant-specific non-persistent VDI onboarding package in the image and
registers a one-time scheduled task. The task runs as `SYSTEM` at startup, waits for Microsoft's
single-entry onboarding PowerShell script to finish, and checks local Defender registration.
Only after registration is confirmed does it remove the staged package contents and delete
itself.

The artifact does not onboard, offboard, or alter Defender for Endpoint state on the image-builder
VM. Configure the environment so temporary image-build VMs are not onboarded. It is intended for
non-persistent Windows 10 or Windows 11 session hosts that should retain one Microsoft Defender
portal device entry when a host is recreated with the same name.

## Get the tenant package

The onboarding package is specific to both the tenant and its cloud. It requires an authenticated
Microsoft Defender portal session and cannot be represented by a public `downloads.json` URL.

| Cloud | Defender portal |
| --- | --- |
| Azure Commercial | `https://security.microsoft.com` |
| Azure Government | `https://security.microsoft.us` |
| Air-gapped clouds | Use the Defender portal inside the target cloud when the service and VDI onboarding package are available. |

1. Open the Microsoft Defender portal for the target tenant and cloud.
2. Open **Settings** > **Endpoints** > **Device management** > **Onboarding**.
3. Under the Step 1. Select an operating system to start deployment, select **Windows 10 and 11** or **Windows Server 2019, 2022, and 2025** depending on your image operating system.
4. Select **Streamlined** for Connectivity type.
5. Select **VDI onboarding scripts for non-persistent endpoints** as the deployment method.
6. Download `GatewayWindowsDefenderATPOnboardingPackage.zip`.
7. For image pre-staging, copy this example folder to
   `customer/artifacts/Microsoft-Defender-VDI-Onboarding/`.
8. Place the downloaded ZIP beside `Install-MDEVDIOnboarding.ps1` in that customer copy.

Do not add the tenant onboarding ZIP or its extracted contents to source control. The
`customer/` directory is Git-ignored by this repository.

Do not transfer a package downloaded from one tenant, network, or cloud into another environment.
For an air-gapped cloud, obtain the package directly from that cloud's Defender portal when it is
available, then place it in the customer artifact folder within that same environment.

## Option 1: Pre-stage in the image

Use this artifact through the image build solution's `vdiCustomizations` parameter. This is the
appropriate image-build phase because VDI customizations run after the normal customization
restart and after ordinary application customizations. Image optimization, cleanup, and manifest
steps still run before Sysprep, but the image build does not reboot after `vdiCustomizations`, so
the `ONSTART` task remains dormant in the captured image.

During image build, the artifact:

1. Finds exactly one ZIP beside `Install-MDEVDIOnboarding.ps1`.
2. Extracts the complete archive to `C:\ProgramData\MDEVDIOnboarding`, finds exactly one PowerShell
  entry point in the extracted package, and records its full path in the generated task runner.
3. Restricts the staging folder to `SYSTEM` and local Administrators.
4. Registers `MDE-VDI-Onboarding` as a `SYSTEM` startup task that repeats every 60 minutes by
  default until registration succeeds.

The image-build Sysprep script logs a warning when it detects active onboarding or local Defender
device identity. It does not fail the build or attempt offboarding. See
[Prevent image-builder MDE onboarding](../../../docs/image-build.md#prevent-image-builder-mde-onboarding)
for environment configuration guidance.

At startup, the generated runner launches Microsoft's PowerShell script with Windows PowerShell
5.1 and `-ExecutionPolicy Bypass`. Invocation is synchronous. After it exits successfully, the
runner waits for local registration confirmation: `OnboardingState` must be `1` and the `Sense`
service must be running. The runner then deletes its scheduled task and removes the staging
folder. Output is retained in `C:\Windows\Logs\MDEVDIOnboarding.log`.

Microsoft's `Onboard-NonPersistentMachine.ps1` also writes its own trace to
`C:\Windows\Temp\VDIlog.txt` and emits MDE ETW events. The FederalAVD log records local state before
and after onboarding, whether a `senseGuid` is present, and the Microsoft script's process exit
code. Nonblank Microsoft console output is written as timestamped `Microsoft:` entries. The tenant
CMD intentionally redirects most console output to `NUL`, so use both log files when
troubleshooting.

If the onboarding script fails or local registration is not confirmed before the timeout, the
task and staged files remain in place. The startup trigger repeats every 60 minutes by default,
so onboarding is retried without requiring another reboot. Each later boot also starts a new
repetition window after the configured startup delay. `MultipleInstances` is set to `IgnoreNew`,
which prevents a retry from overlapping an existing run. Portal inventory is not used as the
cleanup gate because first appearance can lag by three to four hours and requires cloud-specific
authenticated access.

The Microsoft script derives `senseGuid` deterministically from the tenant organization ID and the
VM's final computer name. Running Microsoft's script directly more than once is not generally
idempotent: if `senseGuid` is populated while `Sense` is running, the script exits with code `4`.
The FederalAVD runner avoids that path in three ways:

- It skips the Microsoft script when local registration is already confirmed.
- It waits without reinvoking the script when `Sense` is running with a populated `senseGuid` but
  `OnboardingState` is not yet `1`.
- The task uses `IgnoreNew` to prevent overlapping runs and deletes itself after successful local
  registration.

If registration remains pending, the task retains its files and checks again at the configured
retry interval. Do not manually rerun `Onboard-NonPersistentMachine.ps1` on an already onboarded
host.

## Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `StartupDelayMinutes` | `2` | Startup delay from 0 through 30 minutes. The delay helps ensure the clone has its final hostname and has completed provisioning. |
| `RegistrationTimeoutMinutes` | `10` | Time from 1 through 30 minutes that each run waits for local registration confirmation. |
| `RetryIntervalMinutes` | `60` | Interval from 15 through 1440 minutes between task runs until registration is confirmed. |

After copying the example into `customer/artifacts`, staging the tenant ZIP beside its script,
and uploading the artifacts, add this object to `vdiCustomizations`:

```json
{
  "name": "Microsoft-Defender-VDI-Onboarding",
  "blobNameOrUri": "Microsoft-Defender-VDI-Onboarding.zip",
  "arguments": "-StartupDelayMinutes 2 -RegistrationTimeoutMinutes 10 -RetryIntervalMinutes 60"
}
```

Do not place this artifact in the image build `customizations` array because that phase can be
followed by a restart. Make it the last `vdiCustomizations` entry. A future image-build change or
customization that restarts the image-builder VM after this entry would trigger onboarding on the
source image and must not be used.

## Option 2: Onboard during session-host deployment

If onboarding does not need to be pre-staged in the image, do not use this artifact wrapper.
Instead, place the tenant's original `GatewayWindowsDefenderATPOnboardingPackage.zip` directly in the
root of `customer/artifacts`:

```text
customer/
  artifacts/
    GatewayWindowsDefenderATPOnboardingPackage.zip
```

`Update-ImageArtifacts.ps1` copies root artifact files directly to the artifacts container rather
than wrapping them in another ZIP. Upload it with the other customer artifacts, then reference the
original ZIP in the host pool deployment's `sessionHostCustomizations` parameter:

```json
{
  "name": "Microsoft-Defender-VDI-Onboarding",
  "blobNameOrUri": "GatewayWindowsDefenderATPOnboardingPackage.zip"
}
```

This path downloads and executes the PowerShell script from the onboarding ZIP directly on each
deployed session host. It does not create the `MDE-VDI-Onboarding` scheduled task or stage files
under `C:\ProgramData`. Session-host customizations run after VM provisioning and domain or Entra
join extensions, but before `Initialize-SessionHost.ps1` registers the VM with the AVD host pool.
The VM name is final at this point.

The onboarding ZIP must expose `Onboard-NonPersistentMachine.ps1` at the archive root so
FederalAVD's ZIP customization handler can discover it. Verify the package layout from the target
cloud before upload; if the portal package wraps the scripts in a directory, extract that
directory and create a ZIP whose root contains the PowerShell and CMD files.

## Important limitations

- This artifact implements Microsoft's **single entry for each device** method. The recreated
  session host must receive the same final hostname before the task runs.
- Do not use it for persistent VDI. Persistent devices use the standard Defender for Endpoint
  onboarding methods.
- Do not use it for the legacy Windows Server 2012 R2 or Windows Server 2016 onboarding flow;
  those operating systems require separate preparation.
- The onboarding package's PowerShell script is unsigned. The task uses Microsoft's documented
  execution-policy bypass approach; confirm that this is permitted by organizational policy.
- The task execution limit is `RegistrationTimeoutMinutes` plus 10 minutes, leaving time for
  Microsoft's onboarding script and runner cleanup around the registration polling window.

## Validation

Deploy one session host from the image. The scheduled task starts after the configured startup
delay and writes both runner messages and Microsoft's onboarding-script output to a persistent
log:

```powershell
Get-Content 'C:\Windows\Logs\MDEVDIOnboarding.log' -Tail 100
Get-Content 'C:\Windows\Temp\VDIlog.txt' -Tail 100 -ErrorAction SilentlyContinue

$task = Get-ScheduledTask -TaskName 'MDE-VDI-Onboarding' -ErrorAction SilentlyContinue
if ($task) {
  $task | Get-ScheduledTaskInfo |
    Format-List LastRunTime, LastTaskResult, NextRunTime
}

Test-Path 'C:\ProgramData\MDEVDIOnboarding'
```

`LastTaskResult` value `0` indicates that the runner completed successfully. Value `1` indicates
that the onboarding script failed or local registration was not confirmed; the task and staged
files remain for the next retry. If the task is absent and the staging path returns `False`, the
runner confirmed registration and deleted both as designed. The log remains after successful
cleanup.

Confirm local registration independently:

```powershell
$status = Get-ItemProperty `
  -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' `
  -ErrorAction SilentlyContinue
$sense = Get-Service -Name Sense -ErrorAction SilentlyContinue

$status.OnboardingState
$sense.Status
```

Successful local registration has `OnboardingState` value `1` and a running `Sense` service. If
the task never appears to run, inspect **Event Viewer** > **Applications and Services Logs** >
**Microsoft** > **Windows** > **TaskScheduler** > **Operational** for events containing
`MDE-VDI-Onboarding`. Microsoft notes that a newly onboarded VDI device can take approximately
three to four hours to first appear in the Defender portal, so portal visibility is not the local
success test.

## Reference

- [Onboard non-persistent VDI devices](https://learn.microsoft.com/defender-endpoint/configure-endpoints-vdi)
