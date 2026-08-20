# Configure-AVDSessionHostPolicy

> **Before you start:** Copy this folder to
> `customer/artifacts/Configure-AVDSessionHostPolicy/`. Add the
> `AVDAdministrativeTemplates` entry from
> [`customer-examples/parameters/imageManagement/downloads.json`](../../../customer-examples/parameters/imageManagement/downloads.json)
> to `customer/parameters/imageManagement/downloads.json`, then run
> `Update-ImageArtifacts.ps1`.

Configures Azure Virtual Desktop session-host settings through Local Group Policy without
requiring LGPO.exe. The artifact covers all policies in Microsoft's current
`terminalserver-avd.admx` template and the related inbox clipboard policies, including separate
session-host-to-client and client-to-session-host content restrictions.

All policy parameters default to `NotConfigured`. Running the artifact with defaults installs the
AVD administrative template for Local Group Policy Editor visibility and removes these settings
from the local policy. Domain Group Policy and Intune can still apply settings with higher
precedence.

## Policy areas

- Clipboard redirection and directional content restrictions
- Screen capture protection
- Watermarking
- HEVC/H.265 hardware encoding
- Connection graphics data logging
- RDP Shortpath listener, client port range, and network paths

## Administrative template

`InstallAdministrativeTemplate` defaults to `$true`. The script installs
`terminalserver-avd.admx` and all included ADML languages under
`C:\Windows\PolicyDefinitions`. The template makes AVD settings visible in Local Group Policy
Editor, but the Group Policy client does not require ADMX or ADML files to process `Registry.pol`.

If `AVDGPTemplate.cab` is present beside the script, the artifact uses that file. Otherwise, it
downloads the current package from `https://aka.ms/avdgpo` during execution.

## Parameters

### Clipboard

| Parameter | Default | Values |
| --- | --- | --- |
| `ClipboardRedirection` | `NotConfigured` | `NotConfigured`, `Allow`, `Block` |
| `ServerToClientClipboard` | `NotConfigured` | `NotConfigured`, `Disabled`, `PlainText`, `PlainTextAndImages`, `PlainTextImagesAndRtf`, `PlainTextImagesRtfAndHtml` |
| `ClientToServerClipboard` | `NotConfigured` | Same values as `ServerToClientClipboard` |

Directional clipboard values map to the following DWORD data:

| Value | DWORD | Allowed content |
| --- | ---: | --- |
| `Disabled` | `0` | Nothing |
| `PlainText` | `1` | Plain text |
| `PlainTextAndImages` | `2` | Plain text and images |
| `PlainTextImagesAndRtf` | `3` | Plain text, images, and Rich Text Format |
| `PlainTextImagesRtfAndHtml` | `4` | Plain text, images, Rich Text Format, and HTML |

When either directional parameter is configured, the script sets `fDisableClip = 0` so the
session-host policy permits clipboard redirection. `ClipboardRedirection Block` can't be combined
with directional settings.

The host pool must also permit clipboard redirection:

```text
redirectclipboard:i:1
```

The most restrictive host-pool, Local Group Policy, domain Group Policy, or Intune setting wins.
Directional clipboard control requires one of the following session-host operating systems:

- Windows 11 Enterprise or Enterprise multi-session 22H2 or 23H2 with KB5039212 or later.
- Windows 11 Enterprise or Enterprise multi-session 21H2 with KB5039213 or later.
- Windows Server 2022 with KB5040437 or later.

### Security and graphics

| Parameter | Default | Values or range |
| --- | --- | --- |
| `ScreenCaptureProtection` | `NotConfigured` | `NotConfigured`, `Disabled`, `ClientOnly`, `ClientAndServer` |
| `Watermarking` | `NotConfigured` | `NotConfigured`, `Enabled`, `Disabled` |
| `WatermarkingQrScale` | `4` | `1-10` |
| `WatermarkingOpacity` | `2000` | `100-9999` |
| `WatermarkingWidthFactor` | `320` | `100-1000` |
| `WatermarkingHeightFactor` | `180` | `100-1000` |
| `WatermarkingContent` | `ConnectionId` | `ConnectionId`, `DeviceId` |
| `HevcHardwareEncoding` | `NotConfigured` | `NotConfigured`, `Enabled`, `Disabled` |
| `GraphicsDataLogging` | `NotConfigured` | `NotConfigured`, `Enabled`, `Disabled` |

Screen capture protection can block connections from unsupported clients. Watermarking requires a
supported client and Azure Virtual Desktop Insights to resolve a Connection ID. `DeviceId` content
is intended for personal host pools with Entra joined or hybrid joined session hosts.

HEVC hardware encoding is only appropriate for supported GPU session hosts and compatible Windows
clients. It requires a desktop application group, is not supported for RemoteApp, and can't be
used with multimedia redirection. Do not enable `HevcHardwareEncoding` on an image containing the
`Microsoft-AVD-Multimedia-Redirection` artifact.

### RDP Shortpath

| Parameter | Default | Values or range |
| --- | --- | --- |
| `ManagedShortpathListener` | `NotConfigured` | `NotConfigured`, `Enabled`, `Disabled` |
| `ManagedShortpathPort` | `3390` | `1024-65535` |
| `ShortpathClientPortRange` | `NotConfigured` | `NotConfigured`, `Enabled`, `Disabled` |
| `ShortpathClientPortBase` | `38300` | `1024-49151` |
| `ShortpathClientPortCount` | `1000` | `100-64512`; the effective maximum also depends on the base port, and the resulting range can't exceed port `65535` |
| `ShortpathDirect` | `NotConfigured` | `NotConfigured`, `Enabled`, `Disabled` |
| `ShortpathPublic` | `NotConfigured` | `NotConfigured`, `Enabled`, `Disabled` |
| `ShortpathRelay` | `NotConfigured` | `NotConfigured`, `Enabled`, `Disabled` |

`ManagedShortpathListener` only configures the session-host listener. The matching Windows
Firewall, NSG, routing, and host-pool settings must also allow the selected port. FederalAVD's
Networking deployment exposes `rdpShortpathManagedNetworks` for the corresponding NSG rule.

Public STUN and TURN paths also require outbound UDP connectivity and compatible host-pool
networking settings. TURN is available in Azure Commercial but not Azure Government. Keep TURN
enabled in supported environments unless you have a specific troubleshooting or policy reason to
disable it.

The three Shortpath network-path policies use Microsoft's ADMX encoding: `Enabled` writes DWORD
`1`, `Disabled` writes DWORD `2`, and `NotConfigured` removes the local policy value. This differs
from the other enabled/disabled policies in this artifact, which use DWORD `1` and `0`.

## Examples

### Restrict clipboard to plain text

This permits plain text in both directions while blocking images, RTF, HTML, and clipboard file
transfer:

```powershell
./Configure-AVDSessionHostPolicy.ps1 `
    -ClipboardRedirection Allow `
    -ServerToClientClipboard PlainText `
    -ClientToServerClipboard PlainText
```

The corresponding customization argument string is:

```text
-ClipboardRedirection Allow -ServerToClientClipboard PlainText -ClientToServerClipboard PlainText
```

### Protect a sensitive desktop

```powershell
./Configure-AVDSessionHostPolicy.ps1 `
    -ClipboardRedirection Block `
    -ScreenCaptureProtection ClientAndServer `
    -Watermarking Enabled
```

### Enable managed-network Shortpath

```powershell
./Configure-AVDSessionHostPolicy.ps1 `
    -ManagedShortpathListener Enabled `
    -ManagedShortpathPort 3390
```

Deploy the matching networking controls before using this example.

### Constrain STUN and TURN client ports

```powershell
./Configure-AVDSessionHostPolicy.ps1 `
    -ShortpathClientPortRange Enabled `
    -ShortpathClientPortBase 38300 `
    -ShortpathClientPortCount 1000
```

## Stage the administrative template

Add this entry to `customer/parameters/imageManagement/downloads.json`:

```json
"AVDAdministrativeTemplates": {
    "Description": "Azure Virtual Desktop Group Policy administrative templates.",
    "DownloadUrl": "https://aka.ms/avdgpo",
    "DestinationFileName": "AVDGPTemplate.cab",
    "DestinationFolders": [
        "Configure-AVDSessionHostPolicy"
    ]
}
```

Run the artifact update from the repository root:

```powershell
./deployments/Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId '<artifactsStorageAccountResourceId>'
```

For a disconnected management environment, download the CAB on an internet-connected machine and
transfer the artifact folder through your approved process:

```powershell
Invoke-WebRequest 'https://aka.ms/avdgpo' -OutFile 'AVDGPTemplate.cab'
```

Place `AVDGPTemplate.cab` beside `Configure-AVDSessionHostPolicy.ps1` before packaging. No internet
access is then required during image build or session-host customization.

## Policy processing

The script writes machine settings directly to
`C:\Windows\System32\GroupPolicy\Machine\Registry.pol`, preserves unrelated policy entries, and
updates `gpt.ini`. `NotConfigured` writes the standard Group Policy deletion marker so a setting
previously managed by this artifact is removed from the live registry on the next policy refresh.

The script doesn't run `gpupdate` during image build. Windows processes the local policy at startup.
Domain Group Policy and Intune can override local settings.

Logs are written to `C:\Windows\Logs\Configure-AVDSessionHostPolicy-<timestamp>.log`.

## References

- [Azure Virtual Desktop administrative template](https://learn.microsoft.com/azure/virtual-desktop/administrative-template)
- [Clipboard redirection](https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-clipboard)
- [Clipboard transfer direction](https://learn.microsoft.com/azure/virtual-desktop/clipboard-transfer-direction-data-types)
- [Screen capture protection](https://learn.microsoft.com/azure/virtual-desktop/screen-capture-protection)
- [Watermarking](https://learn.microsoft.com/azure/virtual-desktop/watermarking)
- [RDP Shortpath configuration](https://learn.microsoft.com/azure/virtual-desktop/configure-rdp-shortpath)
- [GPU acceleration](https://learn.microsoft.com/azure/virtual-desktop/graphics-enable-gpu-acceleration)
