# Microsoft-AVD-Multimedia-Redirection

> **Azure Commercial only:** Microsoft doesn't support Azure Virtual Desktop multimedia
> redirection in Azure US Government. Do not use this artifact for Government, GCC, GCC High,
> or DoD deployments.
>
> **Before you start:** Copy this folder to
> `customer/artifacts/Microsoft-AVD-Multimedia-Redirection/`. Add the
> `AVDMultimediaRedirection` entry from
> [`customer-examples/parameters/imageManagement/downloads.json`](../../../customer-examples/parameters/imageManagement/downloads.json)
> to `customer/parameters/imageManagement/downloads.json`, then run
> `Update-ImageArtifacts.ps1`.

Installs the latest Microsoft Remote Desktop Multimedia Redirection Service and browser
extension components on Azure Virtual Desktop session hosts. By default, the script also
configures the Microsoft Edge and Google Chrome extension force-install policies so users don't
need to enable the extension manually.

## Prerequisites

- Azure Virtual Desktop in Azure Commercial.
- The latest Microsoft Edge or Google Chrome on the session host.
- Microsoft Visual C++ Redistributable 2015-2022 version 14.32.31332.0 or later on the session
  host and each local Windows endpoint. The
  [Microsoft-VCRedistributable](../Microsoft-VCRedistributable/) example installs the session-host
  x64 runtime.
- Windows App on Windows 2.0.297.0 or later, or Remote Desktop client 1.2.5709 or later.
- Access from the session host to the applicable browser extension store when centrally enabling
  the extension. The extension updates separately from the host service.

See [Multimedia redirection for video playback and calls](https://learn.microsoft.com/azure/virtual-desktop/multimedia-redirection-video-playback-calls)
for the current client versions, supported sites, and endpoint requirements.

## Parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `InstallEdgeExtension` | `bool` | `$true` | Force-install and enable the Microsoft Edge extension. |
| `InstallChromeExtension` | `bool` | `$true` | Force-install and enable the Google Chrome extension. |
| `SuccessExitCodes` | `int[]` | `0, 3010` | MSI exit codes treated as success. |

Disable a browser policy when that browser isn't deployed or its extensions are managed by a
different enterprise policy. For example:

```powershell
./Install-MicrosoftAVDMultimediaRedirection.ps1 -InstallChromeExtension $false
```

## Folder contents

```plaintext
Microsoft-AVD-Multimedia-Redirection/
    Install-MicrosoftAVDMultimediaRedirection.ps1
    MsMMRHostInstaller_x64.msi
```

The MSI is optional for connected image builds because the script downloads it if it isn't
present. Pre-stage the MSI when the image build VM can't reach the Microsoft download endpoint.

## Stage the installer

Add this entry to `customer/parameters/imageManagement/downloads.json`:

```json
"AVDMultimediaRedirection": {
    "Description": "Microsoft AVD Multimedia Redirection Service x64 MSI. Azure Commercial only.",
    "DownloadUrl": "https://aka.ms/avdmmr/msi",
    "DestinationFileName": "MsMMRHostInstaller_x64.msi",
    "DestinationFolders": [
        "Microsoft-AVD-Multimedia-Redirection"
    ]
}
```

Run the artifact update from the repository root:

```powershell
./deployments/Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId '<artifactsStorageAccountResourceId>'
```

For a disconnected management environment, download the payload on an internet-connected
machine and transfer the artifact folder through your approved process:

```powershell
Invoke-WebRequest 'https://aka.ms/avdmmr/msi' `
    -OutFile 'MsMMRHostInstaller_x64.msi'
```

The install script verifies that the MSI has a valid Microsoft signature before running it.

## What the script does

1. Uses `MsMMRHostInstaller_x64.msi` from the artifact folder, or downloads the current MSI.
2. Verifies the MSI Authenticode signature is valid and issued to Microsoft Corporation.
3. Confirms Microsoft Edge and Google Chrome aren't running.
4. Installs the MSI silently with `msiexec /quiet /norestart`.
5. Optionally adds the official MMR extension to the Edge and Chrome force-install policies.

The MSI installs both the host service and browser extension components. The script preserves
existing force-installed extensions and adds MMR only when it isn't already listed.

## Logs and updates

Script logs are written to
`C:\Windows\Logs\Install-MicrosoftAVDMultimediaRedirection-<timestamp>.log`. Detailed MSI output
is written to `C:\Windows\Logs\Install-MicrosoftAVDMultimediaRedirection-msiexec.log`.

The service doesn't update automatically. Re-run `Update-ImageArtifacts.ps1` before each image
build and rebuild the image to pick up the current release. Installing a newer MSI automatically
replaces the previous version.
