# Microsoft WSL 2

## Overview

This customer-example artifact prepares a Windows 11 Azure Virtual Desktop image for Microsoft
Windows Subsystem for Linux (WSL) 2 and provisions one selected Linux distribution for all users.
It is designed as a two-phase image-build customization because the Windows features required by
WSL 2 must be enabled before a restart and distribution provisioning.

The supported distribution values are:

| `Distribution` value | Distribution package |
| --- | --- |
| `Ubuntu-24.04` | Ubuntu 24.04 LTS |
| `Ubuntu-22.04` | Ubuntu 22.04 LTS |
| `Debian` | Debian GNU/Linux |
| `Kali-Linux` | Kali Linux Rolling |
| `Rocky-Linux-9` | Rocky Linux 9 |

The artifact installs the current stable Microsoft WSL x64 MSI, enables
`Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform`, provisions the selected
distribution package with `-Regions all`, or stages the official Rocky Linux 9 `.wsl` image under
`C:\ProgramData\WSL`. It configures WSL 2 as the default for each Windows user through
Active Setup. For Rocky Linux, the same Active Setup component automatically runs the offline
`wsl.exe --install --from-file` registration for each user without launching the distribution.
Active Setup applies when each user next signs in; it does not modify an already-running session
or register Rocky Linux under the image-build SYSTEM account.

> **Per-user boundary:** AppX distributions provide a launcher to every user and complete personal
> registration and initialization on first launch. Rocky Linux has no AppX launcher in this
> artifact, so its official `.wsl` image is registered automatically for the current Windows user
> at first sign-in. Each user receives an independent Linux filesystem. The Rocky image uses its
> image-defined initial account behavior; this artifact does not create a shared Linux account or
> embed a password in the image.

## Supported configurations

| Configuration | Status | Notes |
| --- | --- | --- |
| Windows 11 Enterprise, x64, version 22H2 or later | Supported | Microsoft enterprise guidance requires Windows 11 22H2 or later for current WSL enterprise networking and security controls. |
| Windows 11 Enterprise multi-session | Supported | AppX packages are provisioned for all users. Rocky Linux is registered from the staged image at each user's first sign-in. Each user receives an independent WSL registration and Linux filesystem. Size CPU, memory, and storage for concurrent WSL utility VMs. |
| Personal host pool / single-session | Supported | Recommended when users need persistent, stateful Linux development environments. |
| Pooled host pool / multi-session | Supported with design constraints | The platform and launcher are supported. User distro state must be treated as per-user data and concurrency can substantially increase host resource consumption. |
| FSLogix Profile Container | Platform supported; distro-state roaming not validated | WSL distribution data normally resides under the user profile as an `ext4.vhdx`. Microsoft does not document roaming that nested virtual disk between AVD hosts as an FSLogix-supported WSL scenario. Rocky registration also records per-user state. Validate Active Setup, attach, detach, compaction, sign-out, and host failover before production use. Do not claim WSL distro persistence based only on the FSLogix profile attaching successfully. |
| Local Windows profiles on persistent personal hosts | Supported | The per-user WSL distribution remains on the persistent OS disk unless the user unregisters it. |
| Nonpersistent pooled hosts without profile persistence | Not suitable for persistent distro state | Users repeat first-launch initialization when assigned to a fresh host. Use WSL only for disposable workloads or provide a separately tested persistence design. |
| Windows 10 multi-session | Not supported by this example | Windows 10 Enterprise reached end of support before this example was published. |
| Windows Server session hosts | Not supported by this example | Microsoft supports WSL on current Windows Server releases, but this artifact's all-user AppX provisioning path is scoped and tested for Windows 11 AVD images. |
| Arm64 session hosts | Not supported | Azure Virtual Desktop session hosts and this package use x64 content. |
| VM Applications | Not supported | WSL is an OS feature with a required restart and per-user state, not an independently removable VM Application. |
| Session-host-only customization on a marketplace image | Not supported | The host-pool customization path cannot restart between phases. Bake WSL into a custom image. |
| Azure Government Secret / Top Secret | Supported only with pre-staged payloads and validated VM capability | Transfer the MSI and selected distribution package through the approved cross-domain process. No runtime public download is required. |

## Azure VM requirements

WSL 2 runs a lightweight virtual machine. Azure session hosts therefore require an x64 VM size
that exposes nested virtualization. VM capabilities and regional availability change over time;
verify the selected SKU instead of relying on a static family list. Also validate the chosen
security type with the selected SKU. Do not use a confidential VM configuration unless Azure
explicitly reports the required nested virtualization capability for that combination.

For pooled or multi-session hosts, include concurrent WSL workloads in capacity planning. Each
active user can start a separate distribution while the WSL utility VM consumes host CPU, memory,
and OS-disk I/O. A minimum VM size is intentionally not hard-coded because the correct size depends
on user density and Linux workload.

## Setup

### 1. Copy the artifact

```powershell
Copy-Item -Recurse -Path "customer-examples\artifacts\Microsoft-WSL2" `
    -Destination "customer\artifacts\"
```

### 2. Add the download definitions

Copy the complete example when a customer downloads file does not exist:

```powershell
New-Item -Path "customer\parameters\imageManagement" -ItemType Directory -Force | Out-Null
Copy-Item -Path "customer-examples\parameters\imageManagement\downloads.json" `
    -Destination "customer\parameters\imageManagement\downloads.json"
```

If the customer file already exists, merge these keys from the example:

- `MicrosoftWSL2`
- One distribution key: `WSLUbuntu2404`, `WSLUbuntu2204`, `WSLDebian`, `WSLKaliLinux`, or
    `WSLRockyLinux9`

Remove the other WSL distribution entries so the update process downloads only the selected
payload. `DestinationFileName` and `DestinationFolders` must remain unchanged.

### 3. Package and upload

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
```

The resulting blob is `Microsoft-WSL2.zip`.

### 4. Add both image-build phases

Add the following adjacent entries to the image build `customizations` array. Replace the
`Distribution` value in the second entry when selecting a different supported distribution.

```json
[
    {
        "name": "Microsoft-WSL2-Platform",
        "blobNameOrUri": "Microsoft-WSL2.zip",
        "arguments": "-Phase EnablePlatform",
        "restart": true
    },
    {
        "name": "Microsoft-WSL2-Distribution",
        "blobNameOrUri": "Microsoft-WSL2.zip",
        "arguments": "-Phase ProvisionDistribution -Distribution Ubuntu-24.04",
        "restart": false
    }
]
```

The entries must remain in this order. Do not put them in `vdiCustomizations`: that phase does not
support a restart. The first phase fails when `WSL-x64.msi` is absent. The second phase fails when
the selected distribution package is absent or the optional features are not fully enabled.

## Connected download sources

The source definitions in `downloads.json` automate these downloads. The WSL entry resolves the
latest stable x64 MSI from the official `microsoft/WSL` GitHub release. AppX distribution links are
from Microsoft's WSL installation documentation. The Rocky Linux image is from Rocky Linux's
official download service.

| Payload | Authoritative source | Artifact destination |
| --- | --- | --- |
| WSL x64 MSI | <https://github.com/microsoft/WSL/releases> | `Microsoft-WSL2\WSL-x64.msi` |
| Ubuntu 24.04 LTS | <https://learn.microsoft.com/windows/wsl/install-manual#downloading-distributions> | `Microsoft-WSL2\DistributionPackages\Ubuntu-24.04\Ubuntu-24.04.AppxBundle` |
| Ubuntu 22.04 LTS | <https://aka.ms/wslubuntu2204> | `Microsoft-WSL2\DistributionPackages\Ubuntu-22.04\Ubuntu-22.04.AppxBundle` |
| Debian GNU/Linux | <https://aka.ms/wsl-debian-gnulinux> | `Microsoft-WSL2\DistributionPackages\Debian\Debian.AppxBundle` |
| Kali Linux Rolling | <https://aka.ms/wsl-kali-linux-new> | `Microsoft-WSL2\DistributionPackages\Kali-Linux\Kali-Linux.AppxBundle` |
| Rocky Linux 9 | <https://download.rockylinux.org/pub/rocky/9/images/x86_64/> | `Microsoft-WSL2\DistributionPackages\Rocky-Linux-9\Rocky-9-WSL-Base.latest.x86_64.wsl` |

To stage the WSL MSI manually on a connected workstation while retaining latest-release behavior:

```powershell
$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/WSL/releases/latest'
$asset = $release.assets | Where-Object { $_.name -like 'wsl.*.x64.msi' } | Select-Object -First 1
Invoke-WebRequest -Uri $asset.browser_download_url `
    -OutFile '.\customer\artifacts\Microsoft-WSL2\WSL-x64.msi'
```

Stage only the selected distribution. For example, Ubuntu 24.04:

```powershell
Invoke-WebRequest `
    -Uri 'https://wslstorestorage.blob.core.windows.net/wslblob/Ubuntu2404-240425.AppxBundle' `
    -OutFile '.\customer\artifacts\Microsoft-WSL2\DistributionPackages\Ubuntu-24.04\Ubuntu-24.04.AppxBundle'
```

For Debian:

```powershell
Invoke-WebRequest -Uri 'https://aka.ms/wsl-debian-gnulinux' `
    -OutFile '.\customer\artifacts\Microsoft-WSL2\DistributionPackages\Debian\Debian.AppxBundle'
```

For Rocky Linux 9:

```powershell
$rockyImageUrl = 'https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-WSL-Base.latest.x86_64.wsl'
$rockyImagePath = '.\customer\artifacts\Microsoft-WSL2\DistributionPackages\Rocky-Linux-9\Rocky-9-WSL-Base.latest.x86_64.wsl'
Invoke-WebRequest `
    -Uri $rockyImageUrl `
    -OutFile $rockyImagePath

$checksumText = Invoke-RestMethod -Uri "$rockyImageUrl.CHECKSUM"
$expectedHash = [regex]::Match(
    $checksumText,
    '(?im)^SHA256 \([^)]+\) = ([0-9a-f]{64})$'
).Groups[1].Value
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $rockyImagePath).Hash
if (-not $expectedHash -or $actualHash -ne $expectedHash) {
    throw "Rocky Linux image hash verification failed. Expected '$expectedHash'; found '$actualHash'."
}
```

The `latest` URL intentionally refreshes to Rocky Linux's current 9.x WSL image. For a controlled
release process, select an immutable versioned `.wsl` file from the same official directory and
update both `DownloadUrl` and `DestinationFileName`, or manually stage that file as the only `.wsl`
file in the Rocky package folder. Record the selected source URL and verify its adjacent
`.CHECKSUM` file before approving the payload.

## Air-gapped preparation

On a connected workstation, copy the artifact folder, run the documented download commands for the
WSL MSI and exactly one distribution, and package locally:

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
    -PackageOnly `
    -OutputPath 'C:\AirGapTransfer'
```

Transfer `Microsoft-WSL2.zip` through the approved process, then upload it to the disconnected
image-management artifacts container. In the disconnected environment, use
`-SkipDownloadingNewSources`; neither image build phase nor Rocky's per-user registration downloads
from the internet. Rocky registration reads the staged `.wsl` image from `C:\ProgramData`.

Record and verify SHA-256 hashes before and after transfer:

```powershell
Get-FileHash -Algorithm SHA256 'C:\AirGapTransfer\Microsoft-WSL2.zip'
```

## Validation after deployment

After an AppX distribution user completes the first-launch prompts, or after Rocky registration
completes at first sign-in, run:

```powershell
wsl.exe --version
wsl.exe --status
wsl.exe --list --verbose
```

The selected distribution should report version `2`. Validate with at least two different users on
a multi-session host. For FSLogix pilots, also validate the same user across two different session
hosts and after container compaction before classifying distro-state roaming as supported.

Rocky registration logs to
`%LOCALAPPDATA%\FederalAVD\Logs\Register-Rocky-Linux-9.log`. A failed registration creates a
per-user Run entry and retries at the next sign-in. The registration is idempotent and does not
replace an existing distribution named `Rocky-Linux-9`.

## Security and operations

- Review WSL enterprise controls for Group Policy or Intune, Hyper-V firewall, DNS tunneling,
  proxy behavior, and Microsoft Defender for Endpoint integration.
- Linux package lifecycle is separate from Windows Update. Use a Linux configuration-management
  process to patch distribution packages and applications.
- Users with access to WSL control their own distribution, including Linux root. WSL does not make
  a standard Windows user a Windows administrator, but Linux-to-Windows interoperability and file
  access must be included in the security design.
- Do not use a shared distribution filesystem for multiple concurrently signed-in users.

## References

- <https://learn.microsoft.com/windows/wsl/install>
- <https://learn.microsoft.com/windows/wsl/install-manual>
- <https://learn.microsoft.com/windows/wsl/enterprise>
- <https://learn.microsoft.com/windows/wsl/faq#can-i-run-wsl-2-in-a-virtual-machine>
- <https://learn.microsoft.com/windows/wsl/basic-commands>
- <https://docs.rockylinux.org/guides/interoperability/import_rocky_to_wsl/>
