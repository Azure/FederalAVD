# Configure desktop background

This artifact includes nine FederalAVD MissionReady desktop backgrounds.
**Federal Generic is the default.** Review the selected artwork against your
organization's approval, branding, usage-rights, and accessibility requirements
before deployment.

The script copies **one explicitly selected JPEG** into
`%SystemRoot%\Web\Wallpaper\Custom\` and retains the existing local User Group
Policy configuration. No LGPO.exe, image-generation service, or internet access
is used at deployment time.

## Included backgrounds

| File | Artwork | Use |
| --- | --- | --- |
| [FederalAVD_Federal_Generic_MissionReady_4K.jpg](FederalAVD_Federal_Generic_MissionReady_4K.jpg) | Federal Generic | **Default** |
| [FederalAVD_Air_Force_MissionReady_4K.jpg](FederalAVD_Air_Force_MissionReady_4K.jpg) | Air Force | Alternative |
| [FederalAVD_Army_MissionReady_4K.jpg](FederalAVD_Army_MissionReady_4K.jpg) | Army | Alternative |
| [FederalAVD_Civilian_Missions_MissionReady_4K.jpg](FederalAVD_Civilian_Missions_MissionReady_4K.jpg) | Civilian Missions | Alternative |
| [FederalAVD_Coast_Guard_MissionReady_4K.jpg](FederalAVD_Coast_Guard_MissionReady_4K.jpg) | Coast Guard | Alternative |
| [FederalAVD_Intelligence_MissionReady_4K.jpg](FederalAVD_Intelligence_MissionReady_4K.jpg) | Intelligence | Alternative |
| [FederalAVD_Marine_Corps_MissionReady_4K.jpg](FederalAVD_Marine_Corps_MissionReady_4K.jpg) | Marine Corps | Alternative |
| [FederalAVD_Navy_MissionReady_4K.jpg](FederalAVD_Navy_MissionReady_4K.jpg) | Navy | Alternative |
| [FederalAVD_Space_Force_MissionReady_4K.jpg](FederalAVD_Space_Force_MissionReady_4K.jpg) | Space Force | Alternative |

All nine JPEGs are **3840 x 2160 (16:9)**, approximately **1.6-2.2 MB** each
and below 3 MB. These are the dimensions of the supplied files; the `4K` filename
does not establish the original source resolution or whether artwork was upscaled.

## Resolution and display guidance

Microsoft's [background configuration guidance][background] recommends designing
for **16:9**, with critical text kept inside the central **4:3** region for
cross-display compatibility. Check the selected image's text, symbols, and focal
points for clipping when using a display with a different aspect ratio.

- **3840 x 2160** is a useful UHD / 16:9 deployment canvas, not a mandatory
  Microsoft policy resolution.
- Custom wallpapers do not need to match the dimensions of the built-in Windows
  wallpaper. Choose an aspect ratio suited to your displays.
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

These files are individual wallpapers, not a Windows theme or theme pack.
The script does not configure slideshow rotation: it copies one selected image
and enforces that fixed wallpaper. A rotating theme requires a separate per-user
configuration without conflicting fixed-wallpaper enforcement.

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
# Default: Federal Generic.
.\customer\artifacts\Configure-DesktopBackground\Set-DesktopBackground.ps1

# Select an alternative.
.\customer\artifacts\Configure-DesktopBackground\Set-DesktopBackground.ps1 `
    -ImageFile 'FederalAVD_Army_MissionReady_4K.jpg'

.\customer\artifacts\Configure-DesktopBackground\Set-DesktopBackground.ps1 `
    -ImageFile 'FederalAVD_Navy_MissionReady_4K.jpg'
```

For image-build or session-host customization, select the image through the
customization's `arguments` property:

```json
{
  "name": "Configure-DesktopBackground",
  "blobNameOrUri": "Configure-DesktopBackground.zip",
  "arguments": "-ImageFile FederalAVD_Army_MissionReady_4K.jpg"
}
```

Omit arguments to use `FederalAVD_Federal_Generic_MissionReady_4K.jpg`.
The script does not select the first enumerated JPEG: adding another image cannot
change the default.
A missing selected file produces an error; it never silently chooses another.

For your own artwork, replace `FederalAVD_Federal_Generic_MissionReady_4K.jpg`
in your **customer copy**, or add a JPEG beside the script and pass its filename
with `-ImageFile`. Only `.jpg` filenames in that directory are accepted, not paths
or wildcards. Existing customer packages with a differently named JPEG must
either pass its name or use the new default filename. Update customization
arguments that reference images removed from this example.

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
