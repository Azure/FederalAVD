# Configure desktop background

This artifact includes three original, AI-generated desktop backgrounds inspired by
FederalAVD: blue cloud landscapes, quiet space for desktop icons, and no text,
logos, government seals, or official branding. Review artwork against your
organization's approval and accessibility requirements before deployment.

The script copies **one explicitly selected JPEG** into
`%SystemRoot%\Web\Wallpaper\Custom\` and retains the existing local User Group
Policy configuration. No LGPO.exe, image-generation service, or internet access
is used at deployment time.

## Included backgrounds

| File | Artwork | Use |
| --- | --- | --- |
| [SunRise.jpg](SunRise.jpg) | **Connected Horizons**: mountains, clouds, sunrise, and subtle connectivity arcs | Default; replaces the previous image while retaining its filename |
| [QuietSunrise.jpg](QuietSunrise.jpg) | **Quiet Sunrise**: layered blue mountains and a warm sunrise | Natural landscape alternative |
| [CloudHorizon.jpg](CloudHorizon.jpg) | **Cloud Horizon**: translucent blue ribbons above clouds | Abstract alternative |

All three JPEGs are **3840 x 2160 (16:9)** and less than 1 MB each. They were
recreated for a landscape desktop composition, then exported with high-quality,
aspect-preserving resampling and a minimal edge crop:

| Artwork | Generated source | Packaged export |
| --- | --- | --- |
| Connected Horizons | 1672 x 940 | 3840 x 2160 JPEG |
| Quiet Sunrise | 1672 x 941 | 3840 x 2160 JPEG |
| Cloud Horizon | 1672 x 941 | 3840 x 2160 JPEG |

These are **upscaled UHD-sized exports, not native-detail 4K artwork**. Upscaling
does not add detail. Use an approved native-resolution replacement if your
environment requires native 4K imagery.

## Resolution and display guidance

Microsoft's [background configuration guidance][background] recommends designing
for **16:9**, with critical text kept inside the central **4:3** region for
cross-display compatibility. These images contain no text and use generous
negative space to reduce the impact of cropping.

- **3840 x 2160** is a useful UHD / 16:9 deployment canvas, not a mandatory
  Microsoft policy resolution.
- The previous bundled image and the installed Windows 11 default wallpapers
  inspected during this update were **3840 x 2400 (16:10)**. Windows does not
  require custom wallpapers to match those dimensions.
- **3840 x 2560 is 3:2**, not the previous image's dimensions or a required
  wallpaper size.
- At **1920 x 1080** or **3840 x 2160**, the bundled images match the display
  ratio. At **1920 x 1200** or **3840 x 2400**, Fill crops the sides.
- Ultrawide, portrait, and mixed-monitor layouts need separate visual checks.
  Keep any added organizational text or required notices away from the edges.
  Do not rely on wallpaper alone to deliver a mandatory notice.
- Prefer sRGB JPEGs and keep custom files below 5 MB when practical.

The existing policy uses **Fill**, which preserves proportions and crops to
cover the screen. **Fit** preserves the entire image but can leave borders;
**Stretch** can distort the image. This script does not add a style parameter
or change the existing style. If your organization manages presentation through
central policy, validate that policy's effective settings and precedence.

## Stage and select an image

Copy the **complete folder** into the git-ignored customer area before changing it:

```powershell
New-Item -ItemType Directory -Path '.\customer\artifacts' -Force | Out-Null
Copy-Item -LiteralPath '.\customer-examples\artifacts\Configure-DesktopBackground' `
    -Destination '.\customer\artifacts' -Recurse
```

For manual configuration on an approved test session host, run as Administrator
or SYSTEM with Windows PowerShell 5.1 or later:

```powershell
# Default: Connected Horizons, retained as SunRise.jpg.
.\customer\artifacts\Configure-DesktopBackground\Set-DesktopBackground.ps1

# Select an alternative.
.\customer\artifacts\Configure-DesktopBackground\Set-DesktopBackground.ps1 `
    -ImageFile 'CloudHorizon.jpg'

.\customer\artifacts\Configure-DesktopBackground\Set-DesktopBackground.ps1 `
    -ImageFile 'QuietSunrise.jpg'
```

For image-build or session-host customization, select the image through the
customization's `arguments` property:

```json
{
  "name": "Configure-DesktopBackground",
  "blobNameOrUri": "Configure-DesktopBackground.zip",
  "arguments": "-ImageFile CloudHorizon.jpg"
}
```

Omit arguments to use `SunRise.jpg`. The script no longer selects the first
enumerated JPEG: adding another image cannot change the default.
A missing selected file produces an error; it never silently chooses another.

For your own artwork, replace `SunRise.jpg` in your **customer copy**, or add a
JPEG beside the script and pass its filename with `-ImageFile`. Only `.jpg`
filenames in that directory are accepted, not paths or wildcards. Existing
customer packages with a differently named single JPEG must now either pass its
name or rename it to `SunRise.jpg`.

Package and upload the customer folder using the
[artifact workflow](../../../docs/artifacts-guide.md) and
[Update-ImageArtifacts guide](../../../docs/update-image-artifacts.md).
The images are already bundled: no download command, external source URL, or
`downloads.json` entry is needed. For disconnected deployments, transfer the
approved complete package through your normal low-to-high process. Runtime
configuration uses the pre-staged local image only.

## Policy configuration and limitations

The following existing values are written to
`%SystemRoot%\System32\GroupPolicy\User\Registry.pol`:

| Policy key, relative to HKCU | Value | Type | Data |
| --- | --- | --- | --- |
| `Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop` | `NoChangingWallPaper` | DWORD | `1` |
| `Software\Microsoft\Windows\CurrentVersion\Policies\System` | `Wallpaper` | REG_SZ | Full path to the copied JPEG |
| `Software\Microsoft\Windows\CurrentVersion\Policies\System` | `WallpaperStyle` | REG_SZ | `4` (**Fill**) |

`Desktop.admx` / matching `en-US\Desktop.adml` define the Desktop Wallpaper policy
under **User Configuration > Administrative Templates > Desktop > Desktop**.
Its style values are `0=Center`, `1=Tile`, `2=Stretch`, `3=Fit`, `4=Fill`,
`5=Span`. Do not substitute the different `Control Panel\Desktop` registry
encodings such as `10` or `22`.

`ControlPanelDisplay.admx` / matching ADML define **Prevent changing desktop
background** under **User Configuration > Administrative Templates > Control
Panel > Personalization**. These mappings were checked against Windows 11 build
26100 templates and the official [Desktop Wallpaper][wallpaper] and
[Prevent changing desktop background][prevent] references. The references list
User scope and Pro, Enterprise, Education, and IoT Enterprise editions, not Home.

> **AVD / remote-session validation required:** Microsoft's Desktop Wallpaper
> policy explanation explicitly says it does not apply to remote desktop server
> sessions. This update preserves the existing policy mechanism; it does not
> resolve that documented limitation or prove behavior on Windows Enterprise
> multi-session. Validate on your exact session-host build and connection type.
> Remote-session background suppression and higher-precedence domain/MDM policy
> can also affect the result.

The script updates `gpt.ini`; it does not call `gpupdate` or immediately refresh
an existing desktop. Test policy processing at the next user sign-in, including
both fresh and existing user profiles.

## Verification and troubleshooting

Logs are written under `%SystemRoot%\Logs\Configuration\` with the prefix
`Configure-DesktopWallpaper-`.

On a representative test host:

1. Confirm the selected JPEG was copied to
   `%SystemRoot%\Web\Wallpaper\Custom\<selected-file>.jpg`.
2. Confirm User `Registry.pol` exists. Generate a report with
   `gpresult /h "$env:TEMP\wallpaper-gpresult.html"` in the target user's context.
3. Check effective user values:

   ```powershell
   Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System' `
       -Name Wallpaper, WallpaperStyle
   Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop' `
       -Name NoChangingWallPaper
   ```

4. Sign out and back in. Check the actual AVD session, not only the console:
   selected artwork, icon contrast, crop, taskbar/Start readability, multiple
   monitors, and whether wallpaper changes are prevented.
5. If the background is missing, check the selected filename, package contents,
   log, effective policies, and client/session background settings. Offline file
   and policy-write checks do not prove that a remote session will render it.

## References

- [Microsoft: Configure desktop and lock screen backgrounds][background]
- [Microsoft: Windows 11 wallpaper composition](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/wallpaper-and-themes-windows-11)
- [Microsoft: Desktop Wallpaper policy][wallpaper]
- [Microsoft: Prevent changing desktop background][prevent]

[background]: https://learn.microsoft.com/en-us/windows/configuration/background/
[wallpaper]: https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-desktop#wallpaper
[prevent]: https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-controlpaneldisplay#cpl-personalization-nodesktopbackgroundui
